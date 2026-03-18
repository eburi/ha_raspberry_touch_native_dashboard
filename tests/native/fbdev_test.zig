const std = @import("std");
const fbdev = @import("fbdev");

test "fbdev init returns placeholder state" {
    const device = try fbdev.Fbdev.init("/dev/fb0");

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
    try std.testing.expectEqual(@as(u32, 0), device.width);
    try std.testing.expectEqual(@as(u32, 0), device.height);
}

test "fbdev deinit is safe when unopened" {
    var device = fbdev.Fbdev{};
    device.deinit();

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
}

test "fbdev error set includes expected variants" {
    const open_failed: fbdev.FbdevError = error.OpenFailed;
    const ioctl_failed: fbdev.FbdevError = error.IoctlFailed;
    const mmap_failed: fbdev.FbdevError = error.MmapFailed;

    _ = open_failed;
    _ = ioctl_failed;
    _ = mmap_failed;

    try std.testing.expect(true);
}
