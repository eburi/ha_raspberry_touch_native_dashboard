///! WASM entry point — exports functions that JavaScript calls.
///!
///! Exports:
///!   init(width, height)         — Initialize LVGL, display, input, and dashboard
///!   tick(dt_ms)                 — Advance LVGL timers (call from rAF loop)
///!   set_input(x, y, pressed)   — Push pointer state from JS mouse/touch events
///!   get_framebuffer() → [*]u8  — Get pointer to RGBA framebuffer for Canvas
///!   get_framebuffer_size() → i32 — Get framebuffer size in bytes
///!
///! Imports (from JS environment):
///!   js_flush(x, y, w, h)       — Notify JS that a display region was updated
///!   js_get_time() → f64        — Get current time in ms (performance.now())

const display = @import("display.zig");
const input = @import("input.zig");
const dashboard = @import("dashboard.zig");
const lv = @import("lv.zig");

// Force libc.zig exports to be included in the WASM binary
comptime {
    _ = @import("libc.zig");
}

/// JS import: get current time in milliseconds
extern fn js_get_time() f64;

/// Tick callback for LVGL — returns elapsed ms since start
var start_time: f64 = 0;
var time_initialized: bool = false;

fn tickCb() callconv(.C) u32 {
    const now = js_get_time();
    if (!time_initialized) {
        start_time = now;
        time_initialized = true;
    }
    return @intFromFloat(now - start_time);
}

/// Initialize LVGL and create the dashboard UI
export fn init(width: i32, height: i32) void {
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);

    // Initialize LVGL core
    lv.lv_init();

    // Set tick source
    lv.lv_tick_set_cb(&tickCb);

    // Initialize display driver (creates LVGL display + framebuffer)
    display.init(w, h);

    // Initialize input driver
    input.init(null); // Will use the default display

    // Create dashboard UI
    dashboard.init(w, h);
    dashboard.create();
}

/// Advance LVGL by dt_ms milliseconds. Call from requestAnimationFrame loop.
export fn tick(dt_ms: u32) void {
    _ = dt_ms;
    // lv_timer_handler processes pending timers, animations, and redraws
    _ = lv.lv_timer_handler();
}

/// Push pointer input from JS mouse/touch events
export fn set_input(x: i32, y: i32, pressed: i32) void {
    input.setInput(x, y, pressed != 0);
}

/// Get pointer to the RGBA framebuffer (for JS to read via WASM memory)
export fn get_framebuffer() ?[*]u8 {
    return display.getFramebuffer();
}

/// Get framebuffer size in bytes
export fn get_framebuffer_size() i32 {
    return display.getFramebufferSize();
}
