///! Framebuffer display driver for native RPi target.
///! Renders LVGL output to /dev/fb* via mmap.
///!
///! Linux framebuffer with RPi Touch Display 2 uses XRGB8888, which matches
///! LVGL's native 32-bit format — no pixel conversion is needed.
///! The flush callback copies the LVGL draw buffer directly to the mmap'd region.
const std = @import("std");
const lv = @import("lv");

const log = std.log.scoped(.fbdev);

pub const FbdevError = error{
    OpenFailed,
    IoctlFailed,
    MmapFailed,
};

/// Linux framebuffer ioctl constants and structures.
/// These match the kernel's <linux/fb.h> definitions.
const FBIOGET_VSCREENINFO = 0x4600;
const FBIOGET_FSCREENINFO = 0x4602;

/// fb_var_screeninfo (variable screen info) — partial, fields we need
const FbVarScreeninfo = extern struct {
    xres: u32,
    yres: u32,
    xres_virtual: u32,
    yres_virtual: u32,
    xoffset: u32,
    yoffset: u32,
    bits_per_pixel: u32,
    grayscale: u32,
    // Color bitfield offsets/lengths (red, green, blue, transp)
    red_offset: u32,
    red_length: u32,
    red_msb_right: u32,
    green_offset: u32,
    green_length: u32,
    green_msb_right: u32,
    blue_offset: u32,
    blue_length: u32,
    blue_msb_right: u32,
    transp_offset: u32,
    transp_length: u32,
    transp_msb_right: u32,
    nonstd: u32,
    activate: u32,
    height_mm: u32,
    width_mm: u32,
    accel_flags: u32,
    // Timing (we don't need these but they're part of the struct)
    pixclock: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: u32,
    vmode: u32,
    rotate: u32,
    colorspace: u32,
    reserved: [4]u32,
};

/// fb_fix_screeninfo — partial, we only need smem_len and line_length
const FbFixScreeninfo = extern struct {
    id: [16]u8,
    smem_start: usize,
    smem_len: u32,
    fb_type: u32,
    type_aux: u32,
    visual: u32,
    xpanstep: u16,
    ypanstep: u16,
    ywrapstep: u16,
    _pad0: u16, // alignment padding
    line_length: u32,
    mmio_start: usize,
    mmio_len: u32,
    accel: u32,
    capabilities: u16,
    reserved: [2]u16,
};

pub const Fbdev = struct {
    fd: ?std.posix.fd_t = null,
    width: u32 = 0,
    height: u32 = 0,
    bits_per_pixel: u32 = 0,
    line_length: u32 = 0,
    fb_size: u32 = 0,
    fb_mem: ?[]align(std.heap.page_size_min) u8 = null,

    /// LVGL display handle
    display: ?*lv.lv_display_t = null,
    /// LVGL draw buffer
    draw_buf: ?[*]u8 = null,

    /// Open the framebuffer device, query screen info, and mmap.
    pub fn init(path: []const u8) !Fbdev {
        var self = Fbdev{};

        // Open the framebuffer device
        const fd = std.posix.open(
            path,
            .{ .ACCMODE = .RDWR },
            0,
        ) catch |err| {
            log.err("Failed to open {s}: {}", .{ path, err });
            return FbdevError.OpenFailed;
        };
        self.fd = fd;

        // Get variable screen info (resolution, bpp)
        var vinfo: FbVarScreeninfo = undefined;
        const vinfo_result = std.os.linux.ioctl(
            @intCast(fd),
            FBIOGET_VSCREENINFO,
            @intFromPtr(&vinfo),
        );
        if (vinfo_result != 0) {
            log.err("FBIOGET_VSCREENINFO ioctl failed", .{});
            self.deinit();
            return FbdevError.IoctlFailed;
        }

        self.width = vinfo.xres;
        self.height = vinfo.yres;
        self.bits_per_pixel = vinfo.bits_per_pixel;

        log.info("Framebuffer: {d}x{d}, {d}bpp", .{ self.width, self.height, self.bits_per_pixel });

        // Get fixed screen info (line_length, smem_len)
        var finfo: FbFixScreeninfo = undefined;
        const finfo_result = std.os.linux.ioctl(
            @intCast(fd),
            FBIOGET_FSCREENINFO,
            @intFromPtr(&finfo),
        );
        if (finfo_result != 0) {
            log.err("FBIOGET_FSCREENINFO ioctl failed", .{});
            self.deinit();
            return FbdevError.IoctlFailed;
        }

        self.line_length = finfo.line_length;
        self.fb_size = finfo.smem_len;

        log.info("Framebuffer: line_length={d}, total_size={d}", .{ self.line_length, self.fb_size });

        // mmap the framebuffer
        const mem = std.posix.mmap(
            null,
            self.fb_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.err("mmap failed: {}", .{err});
            self.deinit();
            return FbdevError.MmapFailed;
        };
        self.fb_mem = mem;

        return self;
    }

    /// Set up LVGL display with this framebuffer as the rendering target.
    pub fn initDisplay(self: *Fbdev) void {
        const buf_size = self.width * self.height * 4; // XRGB8888

        // Allocate LVGL draw buffer
        self.draw_buf = @ptrCast(lv.lv_malloc(buf_size));

        // Create the LVGL display
        self.display = lv.lv_display_create(@intCast(self.width), @intCast(self.height));
        if (self.display) |disp| {
            // Store self pointer so the flush callback can access our mmap'd memory
            lv.lv_display_set_user_data(disp, self);
            lv.lv_display_set_flush_cb(disp, flushCb);
            lv.lv_display_set_buffers(
                disp,
                self.draw_buf,
                null, // Single buffer
                buf_size,
                lv.LV_DISPLAY_RENDER_MODE_FULL,
            );
        }
    }

    pub fn deinit(self: *Fbdev) void {
        if (self.fb_mem) |mem| {
            std.posix.munmap(mem);
            self.fb_mem = null;
        }
        if (self.fd) |fd| {
            std.posix.close(fd);
            self.fd = null;
        }
    }

    /// LVGL flush callback — copy draw buffer directly to the mmap'd framebuffer.
    /// LVGL renders XRGB8888, which is the native format for RPi framebuffer,
    /// so no pixel conversion is needed (unlike the WASM path which converts to RGBA).
    fn flushCb(disp: ?*lv.lv_display_t, area: ?*const lv.lv_area_t, px_map: ?[*]u8) callconv(.C) void {
        const d = disp orelse return;
        const a = area orelse return;
        const src = px_map orelse return;

        const self: *Fbdev = @ptrCast(@alignCast(lv.lv_display_get_user_data(d) orelse return));
        const fb = self.fb_mem orelse return;

        const x1: u32 = @intCast(a.x1);
        const y1: u32 = @intCast(a.y1);
        const x2: u32 = @intCast(a.x2);
        const y2: u32 = @intCast(a.y2);
        const w = x2 - x1 + 1;

        const src_stride = self.width * 4; // LVGL full-screen buffer stride
        const dst_stride = self.line_length; // Framebuffer line_length (may differ)

        var row: u32 = 0;
        const h = y2 - y1 + 1;
        while (row < h) : (row += 1) {
            const src_offset = row * src_stride + x1 * 4;
            const dst_offset = (y1 + row) * dst_stride + x1 * 4;
            const copy_len = w * 4;

            if (dst_offset + copy_len <= fb.len) {
                @memcpy(
                    fb[dst_offset..][0..copy_len],
                    src[src_offset..][0..copy_len],
                );
            }
        }

        lv.lv_display_flush_ready(d);
    }
};
