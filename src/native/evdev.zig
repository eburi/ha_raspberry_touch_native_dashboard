///! Input event driver for native RPi target.
///! Reads touch/mouse events from /dev/input/event*.
///! Not yet implemented — placeholder for future development.

const std = @import("std");

pub const Evdev = struct {
    fd: ?std.posix.fd_t = null,

    pub fn init(path: []const u8) !Evdev {
        _ = path;
        // TODO: open device, read input_event structs in a thread
        std.log.info("evdev: not yet implemented", .{});
        return .{};
    }

    pub fn deinit(self: *Evdev) void {
        if (self.fd) |fd| {
            std.posix.close(fd);
            self.fd = null;
        }
    }
};
