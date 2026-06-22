const std = @import("std");

const log = std.log.scoped(.backlight);

pub const BacklightError = error{
    NotFound,
    InvalidSysfsValue,
    PermissionDenied,
    ReadOnlyFilesystem,
};

pub const Backlight = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    brightness_path: []const u8,
    max_brightness_path: []const u8,
    /// Override for the max raw value to write to sysfs.
    /// If 0 or negative, the value from max_brightness is used.
    /// Set this to cap the brightness curve (e.g., many displays show no visual
    /// change above raw=100 even when max_brightness is 255).
    max_raw_override: i32 = 0,

    pub fn discover(allocator: std.mem.Allocator, preferred_dir: ?[]const u8) !Backlight {
        if (preferred_dir) |dir| {
            return try initFromDir(allocator, dir);
        }

        const fixed = [_][]const u8{
            "/sys/class/backlight/rpi_backlight",
            "/sys/class/backlight/10-0045",
            "/sys/class/backlight/backlight",
        };

        for (fixed) |candidate| {
            const found = initFromDir(allocator, candidate) catch continue;
            return found;
        }

        var cls_dir = std.fs.openDirAbsolute("/sys/class/backlight", .{ .iterate = true }) catch {
            return BacklightError.NotFound;
        };
        defer cls_dir.close();

        var it = cls_dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            const dir = std.fmt.allocPrint(allocator, "/sys/class/backlight/{s}", .{entry.name}) catch continue;
            errdefer allocator.free(dir);
            const found = initFromDir(allocator, dir) catch {
                allocator.free(dir);
                continue;
            };
            allocator.free(dir);
            return found;
        }

        return BacklightError.NotFound;
    }

    pub fn deinit(self: *Backlight) void {
        self.allocator.free(self.dir_path);
        self.allocator.free(self.brightness_path);
        self.allocator.free(self.max_brightness_path);
    }

    fn getMaxRaw(self: *const Backlight) !i32 {
        if (self.max_raw_override > 0) return self.max_raw_override;
        const raw = try readSysfsInt(self.max_brightness_path);
        if (raw <= 0) return BacklightError.InvalidSysfsValue;
        return raw;
    }

    pub fn getPercent(self: *const Backlight) !u8 {
        const max_raw = try self.getMaxRaw();

        const raw = try readSysfsInt(self.brightness_path);
        if (raw <= 0) return 0;

        const pct = @as(u32, @intCast(@divTrunc(raw * 100, max_raw)));
        return @intCast(@min(pct, 100));
    }

    pub fn setMaxRawOverride(self: *Backlight, max_raw: i32) void {
        self.max_raw_override = max_raw;
    }

    pub fn setPercent(self: *const Backlight, percent: u8) !void {
        const max_raw = try self.getMaxRaw();

        const clamped: u8 = @min(percent, 100);
        const raw: i32 = @intCast(@divTrunc(@as(i64, clamped) * max_raw, 100));

        var buf: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}\n", .{raw}) catch return BacklightError.InvalidSysfsValue;

        var file = std.fs.openFileAbsolute(self.brightness_path, .{ .mode = .write_only }) catch |err| {
            return mapIoError(err);
        };
        defer file.close();

        file.writeAll(text) catch |err| {
            return mapIoError(err);
        };
    }

    fn initFromDir(allocator: std.mem.Allocator, dir_path: []const u8) !Backlight {
        const brightness_path = try std.fmt.allocPrint(allocator, "{s}/brightness", .{dir_path});
        errdefer allocator.free(brightness_path);

        const max_brightness_path = try std.fmt.allocPrint(allocator, "{s}/max_brightness", .{dir_path});
        errdefer allocator.free(max_brightness_path);

        _ = readSysfsInt(max_brightness_path) catch |err| {
            return err;
        };
        _ = readSysfsInt(brightness_path) catch |err| {
            return err;
        };

        const dir_copy = try allocator.dupe(u8, dir_path);

        log.info("Backlight sysfs selected: {s}", .{dir_copy});
        return .{
            .allocator = allocator,
            .dir_path = dir_copy,
            .brightness_path = brightness_path,
            .max_brightness_path = max_brightness_path,
        };
    }
};

fn readSysfsInt(path: []const u8) !i32 {
    var buf: [64]u8 = undefined;
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
        return mapIoError(err);
    };
    defer file.close();

    const n = file.readAll(&buf) catch |err| {
        return mapIoError(err);
    };
    const bytes = buf[0..n];
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return BacklightError.InvalidSysfsValue;
    return std.fmt.parseInt(i32, trimmed, 10) catch BacklightError.InvalidSysfsValue;
}

fn mapIoError(err: anyerror) BacklightError {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.PathAlreadyExists => BacklightError.NotFound,
        error.AccessDenied, error.PermissionDenied => BacklightError.PermissionDenied,
        error.ReadOnlyFileSystem => BacklightError.ReadOnlyFilesystem,
        else => BacklightError.InvalidSysfsValue,
    };
}
