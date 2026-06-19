///! Hardware probe — detect framebuffer and input devices at startup.
///! If hardware is present, native LVGL can run on the physical display.
///! If absent, the server runs in web-only mode.
const std = @import("std");

pub const HwInfo = struct {
    framebuffer_path: ?[]const u8 = null,
    input_device_path: ?[]const u8 = null,
    has_display: bool = false,
    has_touch: bool = false,
};

const known_input_paths = [_][]const u8{
    "/dev/input/event0",
    "/dev/input/event1",
    "/dev/input/event2",
    "/dev/input/event3",
    "/dev/input/event4",
    "/dev/input/event5",
    "/dev/input/event6",
    "/dev/input/event7",
    "/dev/input/event8",
    "/dev/input/event9",
    "/dev/input/event10",
    "/dev/input/event11",
    "/dev/input/event12",
    "/dev/input/event13",
    "/dev/input/event14",
    "/dev/input/event15",
};

/// Probe for framebuffer and input devices
pub fn probe() HwInfo {
    var info = HwInfo{};

    // Check for framebuffer devices
    const fb_paths = [_][]const u8{ "/dev/fb0", "/dev/fb1" };
    for (fb_paths) |path| {
        if (std.fs.accessAbsolute(path, .{})) |_| {
            info.framebuffer_path = path;
            info.has_display = true;
            std.log.info("Found framebuffer: {s}", .{path});
            break;
        } else |_| {}
    }

    // Prefer a touch-capable event device from /proc/bus/input/devices.
    if (findTouchInputPath()) |path| {
        info.input_device_path = path;
        info.has_touch = true;
        std.log.info("Found touch input device: {s}", .{path});
    } else {
        // Fallback: first available event device.
        for (known_input_paths) |path| {
            if (std.fs.accessAbsolute(path, .{})) |_| {
                info.input_device_path = path;
                info.has_touch = true;
                std.log.info("Found input device (fallback): {s}", .{path});
                break;
            } else |_| {}
        }
    }

    if (!info.has_display) {
        std.log.warn("No framebuffer found — running in web-only mode", .{});
    }

    return info;
}

fn findTouchInputPath() ?[]const u8 {
    const proc_path = "/proc/bus/input/devices";
    const data = std.fs.cwd().readFileAlloc(std.heap.page_allocator, proc_path, 128 * 1024) catch return null;
    defer std.heap.page_allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    var block_name: []const u8 = "";
    var block_handlers: []const u8 = "";
    var block_has_abs = false;

    while (lines.next()) |line| {
        if (line.len == 0) {
            if (isLikelyTouchBlock(block_name, block_handlers, block_has_abs)) {
                if (extractEventPath(block_handlers)) |path| return path;
            }
            block_name = "";
            block_handlers = "";
            block_has_abs = false;
            continue;
        }

        if (std.mem.startsWith(u8, line, "N: Name=")) {
            block_name = line[8..];
            continue;
        }
        if (std.mem.startsWith(u8, line, "H: Handlers=")) {
            block_handlers = line[12..];
            continue;
        }
        if (std.mem.startsWith(u8, line, "B: ABS=")) {
            block_has_abs = true;
            continue;
        }
    }

    if (isLikelyTouchBlock(block_name, block_handlers, block_has_abs)) {
        return extractEventPath(block_handlers);
    }
    return null;
}

fn isLikelyTouchBlock(name: []const u8, handlers: []const u8, has_abs: bool) bool {
    if (!has_abs) return false;
    if (handlers.len == 0) return false;
    if (std.mem.indexOf(u8, handlers, "event") == null) return false;

    return containsIgnoreCase(name, "touch") or
        containsIgnoreCase(name, "raspberrypi-touchscreen") or
        containsIgnoreCase(name, "ft5406") or
        containsIgnoreCase(name, "goodix") or
        containsIgnoreCase(name, "edt-ft") or
        containsIgnoreCase(name, "waveshare");
}

fn extractEventPath(handlers: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeScalar(u8, handlers, ' ');
    while (tokens.next()) |token| {
        if (!std.mem.startsWith(u8, token, "event")) continue;
        const num_txt = token[5..];
        const idx = std.fmt.parseUnsigned(usize, num_txt, 10) catch continue;
        if (idx < known_input_paths.len) {
            const path = known_input_paths[idx];
            if (std.fs.accessAbsolute(path, .{})) |_| {
                return path;
            } else |_| {}
        }
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) break;
        }
        if (i == needle.len) return true;
    }
    return false;
}
