///! Native display module — drives LVGL on a physical framebuffer + touchscreen.
///!
///! When hardware is detected (via probe), this module:
///!   1. Opens the framebuffer device and mmap's it
///!   2. Opens the touch input device
///!   3. Initializes LVGL with the framebuffer as display target
///!   4. Creates the dashboard UI
///!   5. Runs the LVGL timer loop in a background thread
///!
///! The server calls start()/stop() to manage the native display lifecycle.
///! If no hardware is present, start() is simply never called.
const std = @import("std");
const lv = @import("lv");
const input = @import("input");
const dashboard = @import("dashboard");
const Fbdev = @import("fbdev").Fbdev;
const Evdev = @import("evdev").Evdev;
const probe_mod = @import("probe");

const log = std.log.scoped(.native);

/// Default display dimensions for RPi Touch Display 2
const DEFAULT_WIDTH: u32 = 1280;
const DEFAULT_HEIGHT: u32 = 720;

/// Native display state
var fbdev: Fbdev = .{};
var evdev: Evdev = .{};
var lvgl_thread: ?std.Thread = null;
var should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var is_running: bool = false;

/// Callback for HA service calls — will be set by the server before start()
var ha_call_service_fn: ?*const fn (domain: []const u8, service: []const u8, entity_id: []const u8, extra_json: ?[]const u8) void = null;

/// Entity config JSON (kept for the LVGL thread to parse during init)
var entity_config_json: []const u8 = "{}";

/// Set the function used to call HA services.
/// Must be called before start() so platform callbacks can reach HA.
pub fn setHaCallService(func: *const fn (domain: []const u8, service: []const u8, entity_id: []const u8, extra_json: ?[]const u8) void) void {
    ha_call_service_fn = func;
}

/// Set the entity configuration JSON. Must be called before start().
/// The JSON is parsed during LVGL init to configure sail entity IDs.
pub fn setEntityConfig(json: []const u8) void {
    entity_config_json = json;
}

/// Probe for hardware and start the native display if found.
/// Returns true if native display was started, false if no hardware.
pub fn start() !bool {
    const hw = probe_mod.probe();

    if (!hw.has_display) {
        log.info("No display hardware — native rendering disabled", .{});
        return false;
    }

    const fb_path = hw.framebuffer_path orelse "/dev/fb0";
    fbdev = Fbdev.init(fb_path) catch |err| {
        log.err("Failed to initialize framebuffer {s}: {}", .{ fb_path, err });
        return false;
    };

    const width = if (fbdev.width > 0) fbdev.width else DEFAULT_WIDTH;
    const height = if (fbdev.height > 0) fbdev.height else DEFAULT_HEIGHT;

    // Initialize touch input if available
    if (hw.has_touch) {
        const input_path = hw.input_device_path orelse "/dev/input/event0";
        if (Evdev.init(input_path, width, height)) |ev| {
            evdev = ev;
        } else |err| {
            log.warn("Failed to initialize touch input {s}: {} — continuing without touch", .{ input_path, err });
            // Non-fatal: display still works, just no touch
        }
    }

    // Start the LVGL thread
    should_stop.store(false, .release);
    lvgl_thread = try std.Thread.spawn(.{}, lvglLoop, .{ width, height });
    is_running = true;

    log.info("Native display started: {d}x{d}", .{ width, height });
    return true;
}

/// Stop the native display and clean up.
pub fn stop() void {
    if (!is_running) return;

    should_stop.store(true, .release);
    if (lvgl_thread) |thread| {
        thread.join();
        lvgl_thread = null;
    }

    evdev.deinit();
    fbdev.deinit();
    is_running = false;

    log.info("Native display stopped", .{});
}

/// LVGL main loop — runs in a dedicated thread.
fn lvglLoop(width: u32, height: u32) void {
    // Initialize LVGL
    lv.lv_init();

    // Set tick source — use monotonic clock
    var start_time: ?i64 = null;
    _ = &start_time; // suppress unused warning — used by tickCb closure below

    lv.lv_tick_set_cb(&tickCb);

    // Initialize framebuffer display
    fbdev.initDisplay();

    // Initialize LVGL input driver
    input.init(fbdev.display);

    // Start evdev reader thread (feeds input.setInput)
    evdev.start() catch |err| {
        log.warn("Failed to start input reader: {} — continuing without touch", .{err});
    };

    // Set up platform callbacks for native HA communication
    dashboard.setPlatformCallbacks(.{
        .sail_config_changed = &nativeSailConfigChanged,
        .sail_toggle_changed = &nativeSailToggleChanged,
        .anchor_action = &nativeAnchorAction,
    });

    // Apply entity config from server config (sail entity IDs)
    applyEntityConfig();

    // Create the dashboard
    dashboard.init(width, height);
    dashboard.create();

    log.info("LVGL initialized, entering render loop", .{});

    // Main render loop — call lv_timer_handler at ~30fps
    while (!should_stop.load(.acquire)) {
        _ = lv.lv_timer_handler();
        std.time.sleep(33 * std.time.ns_per_ms); // ~30fps
    }

    log.info("LVGL render loop exiting", .{});
}

/// Tick callback for LVGL — returns milliseconds since LVGL init.
var tick_start: ?i128 = null;

fn tickCb() callconv(.C) u32 {
    const now = std.time.nanoTimestamp();
    if (tick_start == null) {
        tick_start = now;
    }
    const elapsed_ns = now - tick_start.?;
    const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
    return @intCast(@min(elapsed_ms, std.math.maxInt(u32)));
}

// ============================================================
// Native platform callbacks — call HA services directly
// ============================================================

fn nativeSailConfigChanged(entity_ptr: [*]const u8, entity_len: i32, option_ptr: [*]const u8, option_len: i32) void {
    const entity_id = entity_ptr[0..@intCast(entity_len)];
    const option = option_ptr[0..@intCast(option_len)];

    log.info("Sail config: {s} -> {s}", .{ entity_id, option });

    if (ha_call_service_fn) |callService| {
        // Build extra JSON with the option value
        var buf: [256]u8 = undefined;
        const extra = std.fmt.bufPrint(&buf, "\"option\":\"{s}\"", .{option}) catch return;
        callService("input_select", "select_option", entity_id, extra);
    }
}

fn nativeSailToggleChanged(entity_ptr: [*]const u8, entity_len: i32, state: i32) void {
    const entity_id = entity_ptr[0..@intCast(entity_len)];
    const service = if (state != 0) "turn_on" else "turn_off";

    log.info("Toggle: {s} -> {s}", .{ entity_id, service });

    if (ha_call_service_fn) |callService| {
        callService("input_boolean", service, entity_id, null);
    }
}

fn nativeAnchorAction(action_ptr: [*]const u8, action_len: i32, value: f64) void {
    const action = action_ptr[0..@intCast(action_len)];

    // Zoom actions are client-side only (no HA call needed for native)
    // The native display handles its own zoom state
    if (std.mem.eql(u8, action, "zoom_inc") or std.mem.eql(u8, action, "zoom_dec")) {
        log.debug("Anchor zoom: {s}", .{action});
        // TODO: implement native zoom state management
        return;
    }

    log.info("Anchor action: {s} (value={d:.1})", .{ action, value });

    if (ha_call_service_fn) |callService| {
        var buf: [256]u8 = undefined;
        const extra = std.fmt.bufPrint(&buf, "\"action\":\"{s}\",\"value\":{d:.1}", .{ action, value }) catch return;
        callService("script", action, "", extra);
    }
}

// ============================================================
// Entity config parsing
// ============================================================

/// Parse the entity_config_json and push sail entity IDs into dashboard.
fn applyEntityConfig() void {
    const json = entity_config_json;
    if (json.len <= 2) return; // "{}" or empty

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch |err| {
        log.warn("Failed to parse ENTITY_CONFIG JSON: {} — using defaults", .{err});
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    // Slot mapping: 0=sail_main, 1=sail_jib, 2=sail_code0
    const keys = [_][]const u8{ "sail_main", "sail_jib", "sail_code0" };
    for (keys, 0..) |key, slot| {
        if (obj.get(key)) |val| {
            switch (val) {
                .string => |s| {
                    if (s.len > 0) {
                        dashboard.setEntityId(@intCast(slot), s.ptr, @intCast(s.len));
                        log.info("Entity {s} = {s}", .{ key, s });
                    }
                },
                else => {},
            }
        }
    }
}
