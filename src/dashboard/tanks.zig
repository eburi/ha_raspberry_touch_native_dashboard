///! Page 1: Tanks — Four vertical tank level indicators with percentage labels.
const std = @import("std");
const lv = @import("lv");
const theme = @import("theme.zig");

// ============================================================
// Tank sensor ID constants (continue from logbook's 0–14)
// ============================================================
pub const SENSOR_ID_TANK_FUEL: i32 = 15;
pub const SENSOR_ID_TANK_WATER_PORT: i32 = 16;
pub const SENSOR_ID_TANK_WATER_STBD: i32 = 17;
pub const SENSOR_ID_TANK_WATER_STBD_AFT: i32 = 18;

pub const TANK_COUNT: usize = 4;

// ============================================================
// Module state
// ============================================================

/// Bar widgets for each tank (filled bottom-to-top).
var tank_bars: [TANK_COUNT]?*lv.lv_obj_t = .{ null, null, null, null };

/// Percentage labels centered inside each tank bar.
var tank_pct_labels: [TANK_COUNT]?*lv.lv_obj_t = .{ null, null, null, null };

const tank_names = [TANK_COUNT][*:0]const u8{
    "Fuel",
    "Water Port",
    "Water Stbd",
    "Water\nStbd Aft",
};

const tank_sensor_ids = [TANK_COUNT]i32{
    SENSOR_ID_TANK_FUEL,
    SENSOR_ID_TANK_WATER_PORT,
    SENSOR_ID_TANK_WATER_STBD,
    SENSOR_ID_TANK_WATER_STBD_AFT,
};

// ============================================================
// Public API
// ============================================================

pub fn create(parent: ?*lv.lv_obj_t, page_w: u32, screen_h: u32) void {
    if (parent == null) return;

    theme.createPageTitle(parent, "Tanks", theme.PAGE_TANKS);

    // Content area below title
    const content = lv.lv_obj_create(parent);
    if (content == null) return;

    const content_w: i32 = @intCast(page_w - 40); // account for page padding
    const content_h: i32 = @intCast(screen_h - 90);
    lv.lv_obj_set_size(content, content_w, content_h);
    lv.lv_obj_align(content, lv.LV_ALIGN_TOP_LEFT, 0, theme.PAGE_TITLE_H);
    lv.lv_obj_set_style_bg_opa(content, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(content, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Row container for tanks — evenly spaced horizontally
    const row = lv.lv_obj_create(content);
    if (row == null) return;

    lv.lv_obj_set_size(row, content_w, content_h);
    lv.lv_obj_align(row, lv.LV_ALIGN_TOP_LEFT, 0, 0);
    lv.lv_obj_set_style_bg_opa(row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_column(row, 20, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(row, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(row, lv.LV_FLEX_ALIGN_SPACE_EVENLY, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(row, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Tank dimensions
    const tank_w: i32 = 160;
    const label_h: i32 = 50; // space for name label below tank
    const tank_h: i32 = content_h - label_h - 10;

    for (0..TANK_COUNT) |i| {
        createTank(row, tank_w, tank_h, label_h, i);
    }
}

/// Update a tank level by tank index.
/// value_ptr/value_len contain the HA sensor state string (e.g. "75.3").
pub fn update_tank_level(tank_index: i32, value_ptr: [*]const u8, value_len: i32) void {
    const idx: usize = @intCast(tank_index);
    if (idx >= TANK_COUNT) return;

    const value_slice = value_ptr[0..@intCast(value_len)];

    // Parse the numeric value (percentage 0–100)
    const pct = std.fmt.parseFloat(f64, value_slice) catch 0.0;
    const clamped: i32 = @intFromFloat(@min(100.0, @max(0.0, pct)));

    // Update the bar
    if (tank_bars[idx]) |bar| {
        lv.lv_bar_set_value(bar, clamped, lv.LV_ANIM_OFF);
    }

    // Update the percentage label — format as "XX%"
    if (tank_pct_labels[idx]) |lbl| {
        var buf: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}%", .{clamped}) catch return;
        // Null-terminate for LVGL
        if (text.len < buf.len) {
            buf[text.len] = 0;
            lv.lv_label_set_text(lbl, @ptrCast(buf[0..text.len :0]));
        }
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn createTank(parent: ?*lv.lv_obj_t, tank_w: i32, tank_h: i32, label_h: i32, index: usize) void {
    if (parent == null) return;

    // Column container for tank bar + name label
    const col = lv.lv_obj_create(parent);
    if (col == null) return;

    lv.lv_obj_set_size(col, tank_w, tank_h + label_h);
    lv.lv_obj_set_style_bg_opa(col, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(col, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(col, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_row(col, 6, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(col, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_flex_align(col, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(col, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Tank card — a rounded rectangle with a vertical bar inside
    const card = lv.lv_obj_create(col);
    if (card == null) return;

    lv.lv_obj_set_size(card, tank_w, tank_h);
    lv.lv_obj_set_style_bg_color(card, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(card, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(card, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(card, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(card, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(card, 6, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(card, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Vertical bar inside the card — fills bottom to top
    // LVGL bars become vertical when width < height
    const bar_w: i32 = tank_w - 16; // card padding * 2 + border
    const bar_h: i32 = tank_h - 16;
    const bar = lv.lv_bar_create(card);
    if (bar) |b| {
        tank_bars[index] = b;
        lv.lv_obj_set_size(b, bar_w, bar_h);
        lv.lv_obj_center(b);
        lv.lv_bar_set_range(b, 0, 100);
        lv.lv_bar_set_value(b, 0, lv.LV_ANIM_OFF);

        // Main part (background of bar)
        lv.lv_obj_set_style_bg_color(b, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_bg_opa(b, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_radius(b, 8, lv.LV_PART_MAIN);

        // Indicator part (filled portion)
        lv.lv_obj_set_style_bg_color(b, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_INDICATOR);
        lv.lv_obj_set_style_bg_opa(b, lv.LV_OPA_COVER, lv.LV_PART_INDICATOR);
        lv.lv_obj_set_style_radius(b, 8, lv.LV_PART_INDICATOR);

        // Make bar non-clickable
        lv.lv_obj_remove_flag(b, lv.LV_OBJ_FLAG_CLICKABLE);
    }

    // Percentage label centered inside the card (on top of the bar)
    const pct_lbl = lv.lv_label_create(card);
    if (pct_lbl) |l| {
        tank_pct_labels[index] = l;
        lv.lv_label_set_text(l, "--%");
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_28, lv.LV_PART_MAIN);
        lv.lv_obj_center(l);
    }

    // Name label below the tank
    const name_lbl = lv.lv_label_create(col);
    if (name_lbl) |l| {
        lv.lv_label_set_text(l, tank_names[index]);
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_TEXT), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_align(l, lv.LV_TEXT_ALIGN_CENTER, lv.LV_PART_MAIN);
        lv.lv_obj_set_width(l, tank_w);
    }
}
