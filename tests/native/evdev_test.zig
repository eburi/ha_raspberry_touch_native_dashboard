const std = @import("std");
const evdev = @import("evdev");

test "evdev default state is uninitialized" {
    const device = evdev.Evdev{};

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
    try std.testing.expect(device.thread == null);
    try std.testing.expectEqual(false, device.pressed);
    try std.testing.expectEqual(@as(i32, 0), device.abs_x);
    try std.testing.expectEqual(@as(i32, 0), device.abs_y);
    try std.testing.expectEqual(@as(u32, 0), device.physical_w);
    try std.testing.expectEqual(@as(u32, 0), device.physical_h);
    try std.testing.expectEqual(@as(u32, 0), device.logical_w);
    try std.testing.expectEqual(@as(u32, 0), device.logical_h);
}

test "evdev deinit is safe when unopened" {
    var device = evdev.Evdev{};
    device.deinit();

    try std.testing.expectEqual(@as(?std.posix.fd_t, null), device.fd);
    try std.testing.expect(device.thread == null);
}

test "physical to logical mapping handles rotation 0" {
    const p = evdev.Evdev.mapPhysicalToLogical(evdev.ROT_0, 1280, 720, 100, 200);
    try std.testing.expectEqual(@as(i32, 100), p.x);
    try std.testing.expectEqual(@as(i32, 200), p.y);
}

test "physical to logical mapping handles rotation 90" {
    const p = evdev.Evdev.mapPhysicalToLogical(evdev.ROT_90, 720, 1280, 100, 200);
    try std.testing.expectEqual(@as(i32, 200), p.x);
    try std.testing.expectEqual(@as(i32, 1179), p.y);
}

test "physical to logical mapping handles rotation 180" {
    const p = evdev.Evdev.mapPhysicalToLogical(evdev.ROT_180, 1280, 720, 100, 200);
    try std.testing.expectEqual(@as(i32, 1179), p.x);
    try std.testing.expectEqual(@as(i32, 519), p.y);
}

test "physical to logical mapping handles rotation 270" {
    const p = evdev.Evdev.mapPhysicalToLogical(evdev.ROT_270, 720, 1280, 100, 200);
    try std.testing.expectEqual(@as(i32, 519), p.x);
    try std.testing.expectEqual(@as(i32, 100), p.y);
}
