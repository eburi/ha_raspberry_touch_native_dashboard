const std = @import("std");
const evdev = @import("evdev");

test "evdev default state is uninitialized" {
    const device = evdev.Evdev{};

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
    try std.testing.expect(device.thread == null);
    try std.testing.expectEqual(false, device.pressed);
    try std.testing.expectEqual(@as(i32, 0), device.abs_x);
    try std.testing.expectEqual(@as(i32, 0), device.abs_y);
    try std.testing.expectEqual(@as(u32, 0), device.display_w);
    try std.testing.expectEqual(@as(u32, 0), device.display_h);
}

test "evdev deinit is safe when unopened" {
    var device = evdev.Evdev{};
    device.deinit();

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
    try std.testing.expect(device.thread == null);
}
