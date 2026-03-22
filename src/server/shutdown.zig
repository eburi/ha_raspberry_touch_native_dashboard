///! Host shutdown via D-Bus — bypasses the HA Supervisor API for speed.
///!
///! Calls systemd's PowerOff directly over D-Bus, matching the approach
///! from custom-poweroff.sh. This completes in ~15-20 seconds vs 40+
///! seconds via the Supervisor's sequential container teardown — critical
///! when running on supercap power.
///!
///! Sequence:
///!   1. sync — flush filesystem buffers to disk
///!   2. dbus-send PowerOff — tell systemd to shut down immediately
const std = @import("std");

const log = std.log.scoped(.shutdown);

/// Whether a shutdown is already in progress (prevent duplicate calls).
var shutdown_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Initiate a host shutdown via D-Bus.
/// Spawns a background thread so it doesn't block the caller (LVGL loop
/// or WebSocket handler). Safe to call multiple times — only the first
/// call takes effect.
pub fn initiate() void {
    // Prevent duplicate shutdown sequences
    if (shutdown_in_progress.swap(true, .acq_rel)) {
        log.info("Shutdown already in progress — ignoring duplicate request", .{});
        return;
    }

    log.info("=== POWER OFF REQUESTED — initiating host shutdown ===", .{});

    // Run in a background thread so we don't block the caller
    const thread = std.Thread.spawn(.{}, shutdownSequence, .{}) catch |err| {
        log.err("Failed to spawn shutdown thread: {}", .{err});
        // Try inline as fallback
        shutdownSequence();
        return;
    };
    thread.detach();
}

/// Execute the shutdown sequence: sync + dbus-send PowerOff.
fn shutdownSequence() void {
    // Step 1: Flush filesystem buffers
    log.info("Flushing filesystem buffers (sync)...", .{});
    runCommand(&.{"sync"});
    log.info("Sync completed", .{});

    // Step 2: Send PowerOff via D-Bus to systemd
    log.info("Sending PowerOff via D-Bus to systemd...", .{});
    runCommand(&.{
        "dbus-send",
        "--system",
        "--print-reply",
        "--dest=org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager.PowerOff",
        "boolean:false",
    });
    log.info("PowerOff command sent. Waiting for systemd to shut down...", .{});
}

/// Run a command, logging any errors.
fn runCommand(argv: []const []const u8) void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        log.err("Failed to spawn '{s}': {}", .{ argv[0], err });
        return;
    };

    const result = child.wait() catch |err| {
        log.err("Failed to wait for '{s}': {}", .{ argv[0], err });
        return;
    };

    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                // Read stderr for diagnostics
                if (child.stderr) |stderr| {
                    var buf: [512]u8 = undefined;
                    const n = stderr.read(&buf) catch 0;
                    if (n > 0) {
                        log.err("'{s}' exited with code {d}: {s}", .{ argv[0], code, buf[0..n] });
                        return;
                    }
                }
                log.err("'{s}' exited with code {d}", .{ argv[0], code });
            }
        },
        else => {
            log.err("'{s}' terminated abnormally", .{argv[0]});
        },
    }
}
