///! WASM entry point — exports functions that JavaScript calls.
///!
///! This is the WASM platform layer. It:
///!   - Wraps JS extern fns into PlatformCallbacks for the shared dashboard module
///!   - Re-exports dashboard update functions as WASM export fns for JS
///!   - Manages LVGL lifecycle (init, tick) and display/input drivers
///!
///! Exports (for JS):
///!   init(width, height)         — Initialize LVGL, display, input, and dashboard
///!   tick(dt_ms)                 — Advance LVGL timers (call from rAF loop)
///!   set_input(x, y, pressed)   — Push pointer state from JS mouse/touch events
///!   get_framebuffer() → [*]u8  — Get pointer to RGBA framebuffer for Canvas
///!   get_framebuffer_size() → i32 — Get framebuffer size in bytes
///!   update_*                    — Dashboard state update functions (re-exported)
///!
///! Imports (from JS environment):
///!   js_flush(x, y, w, h)       — Notify JS that a display region was updated
///!   js_get_time() → f64        — Get current time in ms (performance.now())
///!   js_sail_config_changed      — Notify JS of sail config select change
///!   js_sail_toggle_changed      — Notify JS of sail boolean toggle change
///!   js_anchor_action            — Notify JS of anchor control button press
const display = @import("display.zig");
const input = @import("input");
const dashboard = @import("dashboard");
const lv = @import("lv");

// Force libc.zig exports to be included in the WASM binary
comptime {
    _ = @import("libc.zig");
}

/// JS import: get current time in milliseconds
extern fn js_get_time() f64;

// JS callbacks — these are the platform-specific implementations
// that bridge dashboard actions to the JavaScript environment.
extern fn js_sail_config_changed(entity_ptr: [*]const u8, entity_len: i32, option_ptr: [*]const u8, option_len: i32) void;
extern fn js_sail_toggle_changed(entity_ptr: [*]const u8, entity_len: i32, state: i32) void;
extern fn js_anchor_action(action_ptr: [*]const u8, action_len: i32, value: f64) void;

// Zig-calling-convention wrappers for the JS extern fns.
// PlatformCallbacks uses Zig function pointers; extern fns have C/WASM calling convention.
fn wasmSailConfigChanged(entity_ptr: [*]const u8, entity_len: i32, option_ptr: [*]const u8, option_len: i32) void {
    js_sail_config_changed(entity_ptr, entity_len, option_ptr, option_len);
}
fn wasmSailToggleChanged(entity_ptr: [*]const u8, entity_len: i32, state: i32) void {
    js_sail_toggle_changed(entity_ptr, entity_len, state);
}
fn wasmAnchorAction(action_ptr: [*]const u8, action_len: i32, value: f64) void {
    js_anchor_action(action_ptr, action_len, value);
}

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

    // Inject WASM platform callbacks into the shared dashboard
    dashboard.setPlatformCallbacks(.{
        .sail_config_changed = &wasmSailConfigChanged,
        .sail_toggle_changed = &wasmSailToggleChanged,
        .anchor_action = &wasmAnchorAction,
    });

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

// ============================================================
// Re-export dashboard update functions as WASM exports for JS
// ============================================================

export fn update_sensor(sensor_id: i32, value_ptr: [*]const u8, value_len: i32) void {
    dashboard.update_sensor(sensor_id, value_ptr, value_len);
}

export fn update_sail_main(value_ptr: [*]const u8, value_len: i32) void {
    dashboard.update_sail_main(value_ptr, value_len);
}

export fn update_sail_jib(value_ptr: [*]const u8, value_len: i32) void {
    dashboard.update_sail_jib(value_ptr, value_len);
}

export fn update_code0(value_ptr: [*]const u8, value_len: i32) void {
    dashboard.update_code0(value_ptr, value_len);
}

export fn update_anchor_connection_state(state: i32) void {
    dashboard.update_anchor_connection_state(state);
}

export fn update_anchor_loader_rotation(deg10: i32) void {
    dashboard.update_anchor_loader_rotation(deg10);
}

export fn update_anchor_status(value_ptr: [*]const u8, value_len: i32) void {
    dashboard.update_anchor_status(value_ptr, value_len);
}

export fn update_anchor_info(value_ptr: [*]const u8, value_len: i32) void {
    dashboard.update_anchor_info(value_ptr, value_len);
}

export fn update_anchor_mode(is_set: i32) void {
    dashboard.update_anchor_mode(is_set);
}

export fn update_anchor_ring_px(diameter_px: i32) void {
    dashboard.update_anchor_ring_px(diameter_px);
}

export fn update_anchor_anchor_px(x: i32, y: i32) void {
    dashboard.update_anchor_anchor_px(x, y);
}

export fn update_anchor_boat_px(x: i32, y: i32, heading_deg10: i32) void {
    dashboard.update_anchor_boat_px(x, y, heading_deg10);
}

export fn update_anchor_line_point(index: i32, x: i32, y: i32, visible: i32) void {
    dashboard.update_anchor_line_point(index, x, y, visible);
}

export fn update_anchor_track_point(index: i32, x: i32, y: i32, visible: i32) void {
    dashboard.update_anchor_track_point(index, x, y, visible);
}

export fn update_anchor_other_boat(index: i32, x: i32, y: i32, visible: i32, heading_deg10: i32) void {
    dashboard.update_anchor_other_boat(index, x, y, visible, heading_deg10);
}

export fn update_anchor_other_track_point(vessel_index: i32, point_index: i32, x: i32, y: i32, visible: i32) void {
    dashboard.update_anchor_other_track_point(vessel_index, point_index, x, y, visible);
}
