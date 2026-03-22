///! Page 3: Settings — Power off with long-press animation.
const lv = @import("lv");
const theme = @import("theme.zig");

// ============================================================
// Module state
// ============================================================
var power_off_bar: ?*lv.lv_obj_t = null;
var power_off_anim_running: bool = false;

// lv_anim_t is opaque to Zig (C struct with bitfields/union), so we use a
// raw byte buffer as backing storage. 256 bytes is generous enough for both
// 32-bit (WASM) and 64-bit (native) targets.
var power_off_anim_storage: [256]u8 align(@alignOf(*anyopaque)) = undefined;

/// Platform callback for power off — set by the coordinator.
var power_off_cb: ?*const fn () void = null;

// ============================================================
// Public API
// ============================================================

pub fn setPowerOffCallback(cb: ?*const fn () void) void {
    power_off_cb = cb;
}

pub fn create(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    theme.createPageTitle(parent, "Settings", theme.PAGE_SETTINGS);

    // "Power off" button — positioned in the lower-left, aligned with the title icon
    const btn = lv.lv_button_create(parent);
    if (btn == null) return;

    lv.lv_obj_set_size(btn, 240, 60);
    lv.lv_obj_align(btn, lv.LV_ALIGN_BOTTOM_LEFT, 0, 0);
    lv.lv_obj_set_style_radius(btn, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(btn, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_shadow_width(btn, 0, lv.LV_PART_MAIN);

    const lbl = lv.lv_label_create(btn);
    if (lbl) |l| {
        lv.lv_label_set_text(l, "Power off");
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        lv.lv_obj_center(l);
    }

    // Progress bar overlaid on the button (fills as user holds)
    const bar = lv.lv_bar_create(btn);
    if (bar) |b| {
        power_off_bar = b;
        lv.lv_obj_set_size(b, 236, 56);
        lv.lv_obj_center(b);
        lv.lv_bar_set_range(b, 0, 100);
        lv.lv_bar_set_value(b, 0, lv.LV_ANIM_OFF);
        lv.lv_obj_set_style_bg_opa(b, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_radius(b, 10, lv.LV_PART_MAIN);
        // Indicator (filled part)
        lv.lv_obj_set_style_bg_color(b, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_INDICATOR);
        lv.lv_obj_set_style_bg_opa(b, lv.LV_OPA_50, lv.LV_PART_INDICATOR);
        lv.lv_obj_set_style_radius(b, 10, lv.LV_PART_INDICATOR);
        // Make bar non-clickable so events pass through to the button
        lv.lv_obj_remove_flag(b, lv.LV_OBJ_FLAG_CLICKABLE);
    }

    // Register PRESSED and RELEASED events for long-press animation
    _ = lv.lv_obj_add_event_cb(btn, powerOffPressedCb, lv.LV_EVENT_PRESSED, null);
    _ = lv.lv_obj_add_event_cb(btn, powerOffReleasedCb, lv.LV_EVENT_RELEASED, null);
}

// ============================================================
// Internal helpers
// ============================================================

fn getAnimPtr() ?*lv.lv_anim_t {
    return @ptrCast(&power_off_anim_storage);
}

/// Exec callback for the bar animation — called by LVGL to update bar value.
fn powerOffAnimExecCb(obj: ?*anyopaque, value: i32) callconv(.C) void {
    if (obj) |o| {
        const bar: *lv.lv_obj_t = @ptrCast(@alignCast(o));
        lv.lv_bar_set_value(bar, value, lv.LV_ANIM_OFF);
    }
}

/// Completed callback — fires when the 3s animation reaches 100%.
fn powerOffAnimCompletedCb(anim: ?*lv.lv_anim_t) callconv(.C) void {
    _ = anim;
    power_off_anim_running = false;

    // Trigger the power_off platform callback
    if (power_off_cb) |cb| {
        cb();
    }

    // Show the shutdown screen
    showShutdownScreen();
}

/// PRESSED event — start the 3-second animation on the bar.
fn powerOffPressedCb(e: ?*lv.lv_event_t) callconv(.C) void {
    _ = e;
    const bar = power_off_bar orelse return;

    // Reset bar to 0
    lv.lv_bar_set_value(bar, 0, lv.LV_ANIM_OFF);

    const anim_ptr = getAnimPtr();
    lv.lv_anim_init(anim_ptr);
    lv.lv_anim_set_var(anim_ptr, bar);
    lv.lv_anim_set_exec_cb(anim_ptr, &powerOffAnimExecCb);
    lv.lv_anim_set_values(anim_ptr, 0, 100);
    lv.lv_anim_set_duration(anim_ptr, 3000);
    lv.lv_anim_set_path_cb(anim_ptr, &lv.lv_anim_path_linear);
    lv.lv_anim_set_completed_cb(anim_ptr, &powerOffAnimCompletedCb);
    _ = lv.lv_anim_start(anim_ptr);
    power_off_anim_running = true;
}

/// RELEASED event — cancel the animation if it hasn't completed.
fn powerOffReleasedCb(e: ?*lv.lv_event_t) callconv(.C) void {
    _ = e;
    if (!power_off_anim_running) return;
    const bar = power_off_bar orelse return;

    // Cancel the running animation
    _ = lv.lv_anim_delete(bar, &powerOffAnimExecCb);
    power_off_anim_running = false;

    // Reset bar to 0
    lv.lv_bar_set_value(bar, 0, lv.LV_ANIM_OFF);
}

/// Show the shutdown screen — all black with centered text.
fn showShutdownScreen() void {
    const scr = lv.lv_obj_create(null);
    if (scr == null) return;

    lv.lv_obj_set_style_bg_color(scr, lv.lv_color_black(), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(scr, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(scr, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Container for centered text
    const container = lv.lv_obj_create(scr);
    if (container == null) {
        lv.lv_screen_load(scr);
        return;
    }

    lv.lv_obj_set_size(container, lv.LV_SIZE_CONTENT, lv.LV_SIZE_CONTENT);
    lv.lv_obj_center(container);
    lv.lv_obj_set_style_bg_opa(container, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(container, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(container, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_row(container, 16, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(container, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_flex_align(container, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(container, lv.LV_OBJ_FLAG_SCROLLABLE);

    // "Shutting down"
    const line1 = lv.lv_label_create(container);
    if (line1) |l| {
        lv.lv_label_set_text(l, "Shutting down");
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_32, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_align(l, lv.LV_TEXT_ALIGN_CENTER, lv.LV_PART_MAIN);
    }

    // "Please wait before you turn off the power."
    const line2 = lv.lv_label_create(container);
    if (line2) |l| {
        lv.lv_label_set_text(l, "Please wait before you turn off the power.");
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_align(l, lv.LV_TEXT_ALIGN_CENTER, lv.LV_PART_MAIN);
    }

    lv.lv_screen_load(scr);
}
