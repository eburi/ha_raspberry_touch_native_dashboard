const std = @import("std");
const probe = @import("probe");

test "HwInfo defaults are unset" {
    const info = probe.HwInfo{};

    try std.testing.expectEqual(@as(?[]const u8, null), info.framebuffer_path);
    try std.testing.expectEqual(@as(?[]const u8, null), info.input_device_path);
    try std.testing.expectEqual(false, info.has_display);
    try std.testing.expectEqual(false, info.has_touch);
}

test "probe result keeps invariant with detected paths" {
    const info = probe.probe();

    if (info.has_display) {
        try std.testing.expect(info.framebuffer_path != null);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), info.framebuffer_path);
    }

    if (info.has_touch) {
        try std.testing.expect(info.input_device_path != null);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), info.input_device_path);
    }
}
