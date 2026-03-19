const std = @import("std");
const fbdev = @import("fbdev");

test "fbdev default state is uninitialized" {
    const device = fbdev.Fbdev{};

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
    try std.testing.expectEqual(@as(u32, 0), device.width);
    try std.testing.expectEqual(@as(u32, 0), device.height);
    try std.testing.expectEqual(@as(u32, 0), device.bits_per_pixel);
    try std.testing.expectEqual(@as(u32, 0), device.line_length);
    try std.testing.expectEqual(@as(u32, 0), device.fb_size);
    try std.testing.expect(device.fb_mem == null);
    try std.testing.expect(device.display == null);
    try std.testing.expect(device.draw_buf == null);
}

test "fbdev deinit is safe when unopened" {
    var device = fbdev.Fbdev{};
    device.deinit();

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
    try std.testing.expect(device.fb_mem == null);
}

test "fbdev error set includes expected variants" {
    // Verify the error set contains the expected variants by comparing them
    try std.testing.expectEqual(@as(fbdev.FbdevError, error.OpenFailed), error.OpenFailed);
    try std.testing.expectEqual(@as(fbdev.FbdevError, error.IoctlFailed), error.IoctlFailed);
    try std.testing.expectEqual(@as(fbdev.FbdevError, error.MmapFailed), error.MmapFailed);
}
