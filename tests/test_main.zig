const std = @import("std");

comptime {
    _ = @import("native/probe_test.zig");
    _ = @import("native/fbdev_test.zig");
    _ = @import("native/evdev_test.zig");
    _ = @import("server/ha_client_test.zig");
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
