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

    // Check for input devices (touch/mouse)
    // In a real implementation, we'd parse /proc/bus/input/devices
    // to find the actual touch device
    const input_paths = [_][]const u8{
        "/dev/input/event0",
        "/dev/input/event1",
        "/dev/input/event2",
    };
    for (input_paths) |path| {
        if (std.fs.accessAbsolute(path, .{})) |_| {
            info.input_device_path = path;
            info.has_touch = true;
            std.log.info("Found input device: {s}", .{path});
            break;
        } else |_| {}
    }

    if (!info.has_display) {
        std.log.warn("No framebuffer found — running in web-only mode", .{});
    }

    return info;
}
