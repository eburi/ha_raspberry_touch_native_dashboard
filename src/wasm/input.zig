///! LVGL input device driver for WASM target.
///! JS calls set_input(x, y, pressed) to push pointer state.
///! LVGL polls via the read callback registered here.

const lv = @import("lv.zig");

/// Current pointer state (written by JS via exported set_input)
var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var pointer_pressed: bool = false;

/// LVGL indev handle
var indev: ?*lv.lv_indev_t = null;

pub fn init(disp: ?*lv.lv_display_t) void {
    indev = lv.lv_indev_create();
    if (indev) |dev| {
        lv.lv_indev_set_type(dev, lv.LV_INDEV_TYPE_POINTER);
        lv.lv_indev_set_read_cb(dev, readCb);
        if (disp) |d| {
            lv.lv_indev_set_display(dev, d);
        }
    }
}

/// Called from JS (via exported WASM function) to update pointer state
pub fn setInput(x: i32, y: i32, pressed: bool) void {
    pointer_x = x;
    pointer_y = y;
    pointer_pressed = pressed;
}

/// LVGL indev read callback — returns current pointer state
fn readCb(_: ?*lv.lv_indev_t, data: ?*lv.lv_indev_data_t) callconv(.C) void {
    if (data) |d| {
        d.point.x = pointer_x;
        d.point.y = pointer_y;
        d.state = if (pointer_pressed) lv.LV_INDEV_STATE_PRESSED else lv.LV_INDEV_STATE_RELEASED;
    }
}
