const std = @import("std");
const evdev = @import("evdev");

test "evdev init returns placeholder state" {
    const device = try evdev.Evdev.init("/dev/input/event0");

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
}

test "evdev deinit is safe when unopened" {
    var device = evdev.Evdev{};
    device.deinit();

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
}
