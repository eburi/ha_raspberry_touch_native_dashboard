///! Page 3: Settings — Power off with long-press animation.
const std = @import("std");
const lv = @import("lv");
const theme = @import("theme.zig");

// ============================================================
// Module state
// ============================================================
var power_off_bar: ?*lv.lv_obj_t = null;
var power_off_anim_running: bool = false;
var power_off_confirm_dialog: ?*lv.lv_obj_t = null;
var power_off_confirm_visible: bool = false;
var brightness_slider: ?*lv.lv_obj_t = null;
var brightness_value_label: ?*lv.lv_obj_t = null;
var suppress_brightness_event: bool = false;

// lv_anim_t is opaque to Zig (C struct with bitfields/union), so we use a
// raw byte buffer as backing storage. 256 bytes is generous enough for both
// 32-bit (WASM) and 64-bit (native) targets.
var power_off_anim_storage: [256]u8 align(@alignOf(*anyopaque)) = undefined;

/// Platform callback for power off — set by the coordinator.
var power_off_cb: ?*const fn () void = null;
var brightness_changed_cb: ?*const fn (percent: i32) void = null;

// ============================================================
// Public API
// ============================================================

pub fn setPowerOffCallback(cb: ?*const fn () void) void {
    power_off_cb = cb;
}

pub fn setBrightnessChangedCallback(cb: ?*const fn (percent: i32) void) void {
    brightness_changed_cb = cb;
}

pub fn create(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    theme.createPageTitle(parent, "Settings", theme.PAGE_SETTINGS);

    createBrightnessControls(parent);

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

pub fn updateBrightness(percent: i32) void {
    const slider = brightness_slider orelse return;
    const clamped: i32 = @max(0, @min(100, percent));
    suppress_brightness_event = true;
    lv.lv_slider_set_value(slider, clamped, lv.LV_ANIM_OFF);
    suppress_brightness_event = false;
    updateBrightnessLabel(clamped);
}

// ============================================================
// Internal helpers
// ============================================================

fn getAnimPtr() ?*lv.lv_anim_t {
    return @ptrCast(&power_off_anim_storage);
}

fn createBrightnessControls(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    const card = lv.lv_obj_create(parent);
    if (card == null) return;

    lv.lv_obj_set_size(card, 280, 560);
    lv.lv_obj_align(card, lv.LV_ALIGN_TOP_LEFT, 0, theme.PAGE_TITLE_H + 12);
    lv.lv_obj_set_style_bg_color(card, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(card, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(card, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(card, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(card, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(card, 14, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_row(card, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(card, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_flex_align(card, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(card, lv.LV_OBJ_FLAG_SCROLLABLE);

    const title = lv.lv_label_create(card);
    if (title) |lbl| {
        lv.lv_label_set_text(lbl, "Brightness");
        lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(lbl, lv.lv_font_montserrat_24, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_align(lbl, lv.LV_TEXT_ALIGN_CENTER, lv.LV_PART_MAIN);
        lv.lv_obj_set_width(lbl, 252);
    }

    const slider_card = lv.lv_obj_create(card);
    if (slider_card == null) return;

    lv.lv_obj_set_size(slider_card, 220, 430);
    lv.lv_obj_set_style_bg_color(slider_card, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(slider_card, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(slider_card, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(slider_card, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(slider_card, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(slider_card, 14, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(slider_card, lv.LV_OBJ_FLAG_SCROLLABLE);

    const slider = lv.lv_slider_create(slider_card);
    if (slider) |s| {
        brightness_slider = s;
        lv.lv_obj_set_size(s, 120, 388);
        lv.lv_obj_align(s, lv.LV_ALIGN_CENTER, 0, 0);
        lv.lv_slider_set_range(s, 0, 100);
        lv.lv_slider_set_value(s, 100, lv.LV_ANIM_OFF);

        lv.lv_obj_set_style_bg_color(s, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_bg_opa(s, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_radius(s, 10, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(s, 1, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_color(s, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);

        lv.lv_obj_set_style_bg_color(s, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_INDICATOR);
        lv.lv_obj_set_style_bg_opa(s, lv.LV_OPA_COVER, lv.LV_PART_INDICATOR);
        lv.lv_obj_set_style_radius(s, 10, lv.LV_PART_INDICATOR);

        lv.lv_obj_set_style_bg_color(s, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_KNOB);
        lv.lv_obj_set_style_bg_opa(s, lv.LV_OPA_COVER, lv.LV_PART_KNOB);
        lv.lv_obj_set_style_radius(s, 8, lv.LV_PART_KNOB);
        lv.lv_obj_set_style_pad_all(s, 10, lv.LV_PART_KNOB);

        _ = lv.lv_obj_add_event_cb(s, brightnessChangedCb, lv.LV_EVENT_VALUE_CHANGED, null);
        updateBrightnessLabel(100);
    }

    const value = lv.lv_label_create(card);
    if (value) |lbl| {
        brightness_value_label = lbl;
        lv.lv_label_set_text(lbl, "100%");
        lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(lbl, lv.lv_font_montserrat_32, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_align(lbl, lv.LV_TEXT_ALIGN_CENTER, lv.LV_PART_MAIN);
        lv.lv_obj_set_width(lbl, 252);
    }
}

fn updateBrightnessLabel(percent: i32) void {
    const label = brightness_value_label orelse return;

    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}%", .{percent}) catch return;
    if (text.len < buf.len) {
        buf[text.len] = 0;
        lv.lv_label_set_text(label, @ptrCast(buf[0..text.len :0]));
    }
}

fn brightnessChangedCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    if (suppress_brightness_event) return;
    const target_raw = lv.lv_event_get_target(e) orelse return;
    const target: *lv.lv_obj_t = @ptrCast(@alignCast(target_raw));
    const value = lv.lv_slider_get_value(target);
    updateBrightnessLabel(value);
    if (brightness_changed_cb) |cb| {
        cb(value);
    }
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

    // Open confirmation dialog after successful long-press.
    showPowerOffConfirmDialog();
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

fn showPowerOffConfirmDialog() void {
    if (power_off_confirm_visible) return;

    const root = lv.lv_screen_active() orelse return;
    const overlay = lv.lv_obj_create(root);
    if (overlay == null) return;

    power_off_confirm_dialog = overlay;
    power_off_confirm_visible = true;

    lv.lv_obj_set_size(overlay, lv.LV_PCT(100), lv.LV_PCT(100));
    lv.lv_obj_align(overlay, lv.LV_ALIGN_CENTER, 0, 0);
    lv.lv_obj_set_style_bg_color(overlay, lv.lv_color_black(), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(overlay, lv.LV_OPA_50, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(overlay, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(overlay, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(overlay, lv.LV_OBJ_FLAG_SCROLLABLE);

    const panel = lv.lv_obj_create(overlay);
    if (panel == null) {
        closePowerOffConfirmDialog();
        return;
    }
    lv.lv_obj_set_size(panel, 500, 260);
    lv.lv_obj_align(panel, lv.LV_ALIGN_CENTER, 0, 0);
    lv.lv_obj_set_style_bg_color(panel, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(panel, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(panel, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(panel, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(panel, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_left(panel, 20, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_right(panel, 20, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_top(panel, 18, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_bottom(panel, 18, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_row(panel, 16, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(panel, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_flex_align(panel, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(panel, lv.LV_OBJ_FLAG_SCROLLABLE);

    const title = lv.lv_label_create(panel);
    if (title) |lbl| {
        lv.lv_label_set_text(lbl, "Confirm power off");
        lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(lbl, lv.lv_font_montserrat_28, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_align(lbl, lv.LV_TEXT_ALIGN_CENTER, lv.LV_PART_MAIN);
        lv.lv_obj_set_width(lbl, 460);
    }

    const body = lv.lv_label_create(panel);
    if (body) |lbl| {
        lv.lv_label_set_text(lbl, "Do you really want to shut down the host system?");
        lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_TEXT), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(lbl, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_align(lbl, lv.LV_TEXT_ALIGN_CENTER, lv.LV_PART_MAIN);
        lv.lv_obj_set_width(lbl, 460);
    }

    const row = lv.lv_obj_create(panel);
    if (row == null) {
        closePowerOffConfirmDialog();
        return;
    }
    lv.lv_obj_set_size(row, lv.LV_PCT(100), lv.LV_SIZE_CONTENT);
    lv.lv_obj_set_style_bg_opa(row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_column(row, 14, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(row, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(row, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(row, lv.LV_OBJ_FLAG_SCROLLABLE);

    const cancel_btn = lv.lv_button_create(row);
    if (cancel_btn) |btn| {
        lv.lv_obj_set_size(btn, 180, 58);
        lv.lv_obj_set_style_radius(btn, 10, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(btn, 2, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
        const lbl = lv.lv_label_create(btn);
        if (lbl) |l| {
            lv.lv_label_set_text(l, "Cancel");
            lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
            lv.lv_obj_center(l);
        }
        _ = lv.lv_obj_add_event_cb(btn, powerOffConfirmCancelCb, lv.LV_EVENT_CLICKED, null);
    }

    const confirm_btn = lv.lv_button_create(row);
    if (confirm_btn) |btn| {
        lv.lv_obj_set_size(btn, 180, 58);
        lv.lv_obj_set_style_radius(btn, 10, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(btn, 2, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        const lbl = lv.lv_label_create(btn);
        if (lbl) |l| {
            lv.lv_label_set_text(l, "Power off");
            lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
            lv.lv_obj_center(l);
        }
        _ = lv.lv_obj_add_event_cb(btn, powerOffConfirmAcceptCb, lv.LV_EVENT_CLICKED, null);
    }
}

fn closePowerOffConfirmDialog() void {
    if (power_off_confirm_dialog) |dlg| {
        lv.lv_obj_delete(dlg);
    }
    power_off_confirm_dialog = null;
    power_off_confirm_visible = false;

    if (power_off_bar) |bar| {
        lv.lv_bar_set_value(bar, 0, lv.LV_ANIM_OFF);
    }
}

fn powerOffConfirmCancelCb(e: ?*lv.lv_event_t) callconv(.C) void {
    _ = e;
    closePowerOffConfirmDialog();
}

fn powerOffConfirmAcceptCb(e: ?*lv.lv_event_t) callconv(.C) void {
    _ = e;
    closePowerOffConfirmDialog();

    if (power_off_cb) |cb| {
        cb();
    }

    showShutdownScreen();
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
