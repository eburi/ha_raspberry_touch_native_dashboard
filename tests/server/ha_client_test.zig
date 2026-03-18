const std = @import("std");
const ha_client = @import("ha_client");

test "ha_client starts disabled without token" {
    const alloc = std.testing.allocator;

    ha_client.init(alloc, .{
        .ha_url = "http://example.invalid/api",
        .token = null,
    });

    try ha_client.start();
    ha_client.stop();
}

test "ha_client has no cached states before receiving data" {
    const alloc = std.testing.allocator;

    ha_client.init(alloc, .{
        .ha_url = "http://example.invalid/api",
        .token = null,
    });

    try std.testing.expectEqual(@as(?[]const u8, null), ha_client.getCachedStatesJson());
}

test "ha_client REST helpers return NoToken without token" {
    const alloc = std.testing.allocator;

    ha_client.init(alloc, .{
        .ha_url = "http://example.invalid/api",
        .token = null,
    });

    try std.testing.expectError(error.NoToken, ha_client.callService("light", "turn_on", null));
    try std.testing.expectError(error.NoToken, ha_client.proxyGet("/states"));
    try std.testing.expectError(error.NoToken, ha_client.proxyPost("/services/light/turn_on", "{}"));
}
