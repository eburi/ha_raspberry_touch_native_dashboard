///! Input event driver for native RPi target.
///! Reads touch/mouse events from /dev/input/event* using Linux evdev.
///!
///! Runs a background thread that reads input_event structs and updates
///! the shared input module's pointer state. LVGL polls this state via
///! the input driver's read callback.
const std = @import("std");
const input = @import("input");

const log = std.log.scoped(.evdev);

/// Linux input event types and codes (from <linux/input-event-codes.h>)
const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_ABS: u16 = 0x03;

const ABS_X: u16 = 0x00;
const ABS_Y: u16 = 0x01;
const ABS_MT_POSITION_X: u16 = 0x35;
const ABS_MT_POSITION_Y: u16 = 0x36;
const ABS_MT_TRACKING_ID: u16 = 0x39;

const BTN_TOUCH: u16 = 0x14a;

/// Linux input_event structure (matches kernel struct input_event)
const InputEvent = extern struct {
    tv_sec: isize,
    tv_usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

/// EVIOCGABS ioctl to get axis info — ioctl number = _IOR('E', 0x40 + axis, input_absinfo)
/// For the _IOR macro on Linux: dir=2, size=sizeof(input_absinfo)=24, type='E'=0x45, nr=0x40+axis
fn eviocgabs(axis: u16) u32 {
    // _IOR('E', 0x40 + axis, struct input_absinfo)
    // _IOR = (2 << 30) | (size << 16) | (type << 8) | nr
    const dir: u32 = 2 << 30;
    const size: u32 = @sizeOf(InputAbsinfo) << 16;
    const typ: u32 = 'E' << 8;
    const nr: u32 = 0x40 + @as(u32, axis);
    return dir | size | typ | nr;
}

/// struct input_absinfo — axis calibration data
const InputAbsinfo = extern struct {
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
};

pub const Evdev = struct {
    fd: ?std.posix.fd_t = null,
    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Touch state (updated by reader thread)
    abs_x: i32 = 0,
    abs_y: i32 = 0,
    pressed: bool = false,

    // Axis calibration (from EVIOCGABS)
    x_min: i32 = 0,
    x_max: i32 = 0,
    y_min: i32 = 0,
    y_max: i32 = 0,

    // Display dimensions for coordinate scaling
    display_w: u32 = 0,
    display_h: u32 = 0,

    pub fn init(path: []const u8, display_w: u32, display_h: u32) !Evdev {
        var self = Evdev{};
        self.display_w = display_w;
        self.display_h = display_h;

        // Open the input device
        const fd = std.posix.open(
            path,
            .{ .ACCMODE = .RDONLY, .NONBLOCK = true },
            0,
        ) catch |err| {
            log.err("Failed to open {s}: {}", .{ path, err });
            return error.OpenFailed;
        };
        self.fd = fd;

        // Try to get axis calibration data
        self.queryAxisInfo(fd);

        log.info("Input device opened: {s} (X: {d}..{d}, Y: {d}..{d})", .{
            path, self.x_min, self.x_max, self.y_min, self.y_max,
        });

        return self;
    }

    /// Start the background thread that reads input events.
    pub fn start(self: *Evdev) !void {
        self.should_stop.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
    }

    pub fn deinit(self: *Evdev) void {
        self.should_stop.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.fd) |fd| {
            std.posix.close(fd);
            self.fd = null;
        }
    }

    fn queryAxisInfo(self: *Evdev, fd: std.posix.fd_t) void {
        // Query ABS_X range
        var x_info: InputAbsinfo = undefined;
        const x_result = std.os.linux.ioctl(
            @intCast(fd),
            eviocgabs(ABS_X),
            @intFromPtr(&x_info),
        );
        if (x_result == 0) {
            self.x_min = x_info.minimum;
            self.x_max = x_info.maximum;
        }

        // Query ABS_Y range
        var y_info: InputAbsinfo = undefined;
        const y_result = std.os.linux.ioctl(
            @intCast(fd),
            eviocgabs(ABS_Y),
            @intFromPtr(&y_info),
        );
        if (y_result == 0) {
            self.y_min = y_info.minimum;
            self.y_max = y_info.maximum;
        }

        // If ranges are zero, try multitouch axes
        if (self.x_max == 0) {
            var mt_x_info: InputAbsinfo = undefined;
            const mt_x_result = std.os.linux.ioctl(
                @intCast(fd),
                eviocgabs(ABS_MT_POSITION_X),
                @intFromPtr(&mt_x_info),
            );
            if (mt_x_result == 0 and mt_x_info.maximum > 0) {
                self.x_min = mt_x_info.minimum;
                self.x_max = mt_x_info.maximum;
            }
        }
        if (self.y_max == 0) {
            var mt_y_info: InputAbsinfo = undefined;
            const mt_y_result = std.os.linux.ioctl(
                @intCast(fd),
                eviocgabs(ABS_MT_POSITION_Y),
                @intFromPtr(&mt_y_info),
            );
            if (mt_y_result == 0 and mt_y_info.maximum > 0) {
                self.y_min = mt_y_info.minimum;
                self.y_max = mt_y_info.maximum;
            }
        }

        // Fallback: assume 1:1 pixel mapping
        if (self.x_max == 0) {
            self.x_max = @intCast(self.display_w);
        }
        if (self.y_max == 0) {
            self.y_max = @intCast(self.display_h);
        }
    }

    /// Scale raw absolute coordinate to display pixel coordinate.
    fn scaleCoord(raw: i32, min: i32, max: i32, display_size: u32) i32 {
        if (max <= min) return raw;
        const clamped = std.math.clamp(raw, min, max);
        const normalized: i64 = @as(i64, clamped - min) * @as(i64, display_size);
        const range: i64 = @as(i64, max - min);
        return @intCast(@divTrunc(normalized, range));
    }

    /// Background thread: read input events and update pointer state.
    fn readLoop(self: *Evdev) void {
        const fd = self.fd orelse return;

        // Use poll to wait for data with timeout (so we can check should_stop)
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        while (!self.should_stop.load(.acquire)) {
            // Poll with 100ms timeout
            const poll_result = std.posix.poll(&poll_fds, 100) catch |err| {
                log.err("poll error: {}", .{err});
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            };

            if (poll_result == 0) continue; // timeout, loop to check should_stop

            // Read available events
            var buf: [@sizeOf(InputEvent) * 64]u8 = undefined;
            const bytes_read = std.posix.read(fd, &buf) catch |err| {
                if (err == error.WouldBlock) continue;
                log.err("read error: {}", .{err});
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            };

            const event_count = bytes_read / @sizeOf(InputEvent);
            const events: [*]const InputEvent = @ptrCast(@alignCast(&buf));

            var i: usize = 0;
            while (i < event_count) : (i += 1) {
                const ev = events[i];
                self.handleEvent(ev);
            }
        }
    }

    fn handleEvent(self: *Evdev, ev: InputEvent) void {
        switch (ev.type) {
            EV_ABS => {
                switch (ev.code) {
                    ABS_X, ABS_MT_POSITION_X => {
                        self.abs_x = ev.value;
                    },
                    ABS_Y, ABS_MT_POSITION_Y => {
                        self.abs_y = ev.value;
                    },
                    ABS_MT_TRACKING_ID => {
                        // tracking_id >= 0 means finger down, -1 means finger up
                        self.pressed = (ev.value >= 0);
                    },
                    else => {},
                }
            },
            EV_KEY => {
                if (ev.code == BTN_TOUCH) {
                    self.pressed = (ev.value != 0);
                }
            },
            EV_SYN => {
                // Sync event — push accumulated state to the input module
                const px = scaleCoord(self.abs_x, self.x_min, self.x_max, self.display_w);
                const py = scaleCoord(self.abs_y, self.y_min, self.y_max, self.display_h);
                input.setInput(px, py, self.pressed);
            },
            else => {},
        }
    }
};
