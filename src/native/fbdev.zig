///! Framebuffer display driver for native RPi target.
///! Renders LVGL to /dev/fb* via mmap.
///! Not yet implemented — placeholder for future development.

const std = @import("std");

pub const FbdevError = error{
    OpenFailed,
    IoctlFailed,
    MmapFailed,
};

pub const Fbdev = struct {
    fd: ?std.posix.fd_t = null,
    width: u32 = 0,
    height: u32 = 0,
    // Future: mmap pointer, stride, etc.

    pub fn init(path: []const u8) !Fbdev {
        _ = path;
        // TODO: open /dev/fb*, ioctl FBIOGET_VSCREENINFO, mmap
        std.log.info("fbdev: not yet implemented", .{});
        return .{};
    }

    pub fn deinit(self: *Fbdev) void {
        if (self.fd) |fd| {
            std.posix.close(fd);
            self.fd = null;
        }
    }
};
