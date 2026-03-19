///! LVGL display driver for WASM target.
///! Sets up an LVGL display that renders to a framebuffer in WASM memory.
///! The JS host reads the framebuffer and blits it to an HTML Canvas.
///!
///! LVGL with LV_COLOR_DEPTH=32 uses XRGB8888 (little-endian: B,G,R,X in memory).
///! HTML Canvas ImageData expects RGBA (R,G,B,A in memory).
///! The flush callback swaps R<->B and sets A=0xFF.
const lv = @import("lv");

/// JS import: notify the host that a region has been flushed
extern fn js_flush(x: i32, y: i32, w: i32, h: i32) void;

/// Framebuffer — allocated once during init
var framebuffer: ?[*]u8 = null;
var fb_width: u32 = 0;
var fb_height: u32 = 0;

/// LVGL display handle
var display: ?*lv.lv_display_t = null;

/// Draw buffer (LVGL-managed, full screen)
var draw_buf: ?[*]u8 = null;

pub fn init(width: u32, height: u32) void {
    fb_width = width;
    fb_height = height;

    const fb_size = width * height * 4; // XRGB8888 = 4 bytes per pixel

    // Allocate the output framebuffer (what JS reads)
    framebuffer = @ptrCast(lv.lv_malloc(fb_size));
    if (framebuffer) |fb| {
        lv.lv_memset(fb, 0, fb_size);
    }

    // Allocate LVGL draw buffer
    draw_buf = @ptrCast(lv.lv_malloc(fb_size));

    // Create the display
    display = lv.lv_display_create(@intCast(width), @intCast(height));
    if (display) |disp| {
        lv.lv_display_set_flush_cb(disp, flushCb);
        lv.lv_display_set_buffers(
            disp,
            draw_buf,
            null, // No second buffer
            fb_size,
            lv.LV_DISPLAY_RENDER_MODE_FULL,
        );
    }
}

/// Get pointer to the output framebuffer (for JS to read)
pub fn getFramebuffer() ?[*]u8 {
    return framebuffer;
}

/// Get framebuffer size in bytes
pub fn getFramebufferSize() i32 {
    return @intCast(fb_width * fb_height * 4);
}

/// LVGL flush callback: copy draw buffer → output framebuffer with XRGB→RGBA conversion
fn flushCb(disp: ?*lv.lv_display_t, area: ?*const lv.lv_area_t, px_map: ?[*]u8) callconv(.C) void {
    const fb = framebuffer orelse return;
    const a = area orelse return;
    const src = px_map orelse return;

    const x1: u32 = @intCast(a.x1);
    const y1: u32 = @intCast(a.y1);
    const x2: u32 = @intCast(a.x2);
    const y2: u32 = @intCast(a.y2);
    const w = x2 - x1 + 1;
    const h = y2 - y1 + 1;

    // In FULL render mode, the entire screen is in px_map
    // Source stride = screen width * 4
    const src_stride = fb_width * 4;
    const dst_stride = fb_width * 4;

    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const src_row_start = (row) * src_stride + x1 * 4;
        const dst_row_start = (y1 + row) * dst_stride + x1 * 4;

        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const si = src_row_start + col * 4;
            const di = dst_row_start + col * 4;

            // LVGL XRGB8888 in memory (little-endian): B, G, R, X
            // Canvas RGBA in memory:                   R, G, B, A
            const b = src[si + 0];
            const g = src[si + 1];
            const r = src[si + 2];
            // X byte ignored

            fb[di + 0] = r;
            fb[di + 1] = g;
            fb[di + 2] = b;
            fb[di + 3] = 0xFF; // Full alpha
        }
    }

    // Notify JS about the flushed area
    js_flush(@intCast(x1), @intCast(y1), @intCast(w), @intCast(h));

    // Tell LVGL flushing is done
    lv.lv_display_flush_ready(disp);
}
