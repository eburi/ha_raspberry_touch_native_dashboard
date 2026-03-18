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
    // Verify the error set contains the expected variants by comparing them
    try std.testing.expectEqual(@as(fbdev.FbdevError, error.OpenFailed), error.OpenFailed);
    try std.testing.expectEqual(@as(fbdev.FbdevError, error.IoctlFailed), error.IoctlFailed);
    try std.testing.expectEqual(@as(fbdev.FbdevError, error.MmapFailed), error.MmapFailed);
}
