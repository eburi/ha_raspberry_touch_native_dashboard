///! Page 0: Logbook — Position + 24h log sensor cards.
const std = @import("std");
const lv = @import("lv");
const theme = @import("theme.zig");

// ============================================================
// Sensor ID constants
// ============================================================
pub const SENSOR_ID_LATITUDE: i32 = 0;
pub const SENSOR_ID_LONGITUDE: i32 = 1;
pub const SENSOR_ID_LOG: i32 = 2;
pub const SENSOR_ID_HDG: i32 = 3;
pub const SENSOR_ID_STW: i32 = 4;
pub const SENSOR_ID_SOG: i32 = 5;
pub const SENSOR_ID_COG: i32 = 6;
pub const SENSOR_ID_AWS: i32 = 7;
pub const SENSOR_ID_AWA: i32 = 8;
pub const SENSOR_ID_TWS: i32 = 9;
pub const SENSOR_ID_TWD: i32 = 10;
pub const SENSOR_ID_BARO: i32 = 11;
pub const SENSOR_ID_DISTANCE_24H: i32 = 12;
pub const SENSOR_ID_SPEED_24H: i32 = 13;
pub const SENSOR_ID_DATETIME: i32 = 14;

// ============================================================
// Sensor label references (updated via platform state callbacks)
// ============================================================
var lbl_logbook_datetime: ?*lv.lv_obj_t = null;
var lbl_latitude: ?*lv.lv_obj_t = null;
var lbl_longitude: ?*lv.lv_obj_t = null;
var lbl_vessel_log: ?*lv.lv_obj_t = null;
var lbl_vessel_hdg: ?*lv.lv_obj_t = null;
var lbl_vessel_stw: ?*lv.lv_obj_t = null;
var lbl_vessel_sog: ?*lv.lv_obj_t = null;
var lbl_vessel_cog: ?*lv.lv_obj_t = null;
var lbl_env_aws: ?*lv.lv_obj_t = null;
var lbl_env_awa: ?*lv.lv_obj_t = null;
var lbl_env_tws: ?*lv.lv_obj_t = null;
var lbl_env_twd: ?*lv.lv_obj_t = null;
var lbl_env_baro: ?*lv.lv_obj_t = null;
var lbl_distance_24h: ?*lv.lv_obj_t = null;
var lbl_speed_24h: ?*lv.lv_obj_t = null;

// ============================================================
// Public API
// ============================================================

pub fn create(parent: ?*lv.lv_obj_t, page_w: u32, screen_h: u32) void {
    if (parent == null) return;

    theme.createPageTitle(parent, "Logbook", theme.PAGE_LOGBOOK);

    lbl_logbook_datetime = lv.lv_label_create(parent);
    if (lbl_logbook_datetime) |dt| {
        lv.lv_label_set_text(dt, "--:-- --.--.---- (UTC+0)");
        lv.lv_obj_set_style_text_color(dt, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(dt, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(dt, lv.LV_ALIGN_TOP_RIGHT, -2, 4);
    }

    // Content area below title
    const content = lv.lv_obj_create(parent);
    if (content == null) return;

    const content_w = page_w - 40; // account for page padding
    const content_w_i32: i32 = @intCast(content_w);
    lv.lv_obj_set_size(content, content_w_i32, @intCast(screen_h - 90));
    lv.lv_obj_align(content, lv.LV_ALIGN_TOP_LEFT, 0, theme.PAGE_TITLE_H);
    lv.lv_obj_set_style_bg_opa(content, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(content, lv.LV_OBJ_FLAG_SCROLLABLE);

    // --- Row 1: Vessel section ---
    const section_label_1 = lv.lv_label_create(content);
    if (section_label_1) |sl| {
        lv.lv_label_set_text(sl, "Vessel");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 0);
    }

    const vessel_gap: i32 = 10;
    const vessel_cols: i32 = 6;
    const vessel_card_w: i32 = @divTrunc(content_w_i32 - vessel_gap * (vessel_cols - 1), vessel_cols);
    const card_h: i32 = 110;
    const row1 = theme.createCardRow(content, page_w, 30, 120, vessel_gap);

    const gps = createGpsCard(row1, vessel_card_w, card_h, "GPS Position");
    lbl_latitude = gps.latitude;
    lbl_longitude = gps.longitude;
    lbl_vessel_log = theme.createSensorCard(row1, vessel_card_w, card_h, "Log", "--");
    lbl_vessel_hdg = theme.createSensorCard(row1, vessel_card_w, card_h, "HDG", "--");
    lbl_vessel_stw = theme.createSensorCard(row1, vessel_card_w, card_h, "STW", "--");
    lbl_vessel_sog = theme.createSensorCard(row1, vessel_card_w, card_h, "SOG", "--");
    lbl_vessel_cog = theme.createSensorCard(row1, vessel_card_w, card_h, "COG", "--");

    // --- Row 2: Environment section ---
    const section_label_2 = lv.lv_label_create(content);
    if (section_label_2) |sl| {
        lv.lv_label_set_text(sl, "Environment");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 160);
    }

    const env_gap: i32 = 12;
    const env_cols: i32 = 5;
    const env_card_w: i32 = @divTrunc(content_w_i32 - env_gap * (env_cols - 1), env_cols);
    const row2 = theme.createCardRow(content, page_w, 190, 120, env_gap);

    lbl_env_aws = theme.createSensorCard(row2, env_card_w, card_h, "AWS", "--");
    lbl_env_awa = theme.createSensorCard(row2, env_card_w, card_h, "AWA", "--");
    lbl_env_tws = theme.createSensorCard(row2, env_card_w, card_h, "TWS", "--");
    lbl_env_twd = theme.createSensorCard(row2, env_card_w, card_h, "TWD", "--");
    lbl_env_baro = theme.createSensorCard(row2, env_card_w, card_h, "Baro", "--");

    // --- Row 3: Last 24h section ---
    const section_label_3 = lv.lv_label_create(content);
    if (section_label_3) |sl| {
        lv.lv_label_set_text(sl, "Last 24h");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 320);
    }

    const row3 = theme.createCardRow(content, page_w, 350, 120, 15);
    const card_w_24h: i32 = @divTrunc(content_w_i32 - 15, 2);

    lbl_distance_24h = theme.createSensorCard(row3, card_w_24h, card_h, "Distance", "--");
    lbl_speed_24h = theme.createSensorCard(row3, card_w_24h, card_h, "Avg Speed", "--");
}

/// Update a sensor value label by sensor ID.
pub fn update_sensor(sensor_id: i32, value_ptr: [*]const u8, value_len: i32) void {
    const value: [*:0]const u8 = @ptrCast(value_ptr);
    _ = value_len;

    const label: ?*lv.lv_obj_t = switch (sensor_id) {
        SENSOR_ID_LATITUDE => lbl_latitude,
        SENSOR_ID_LONGITUDE => lbl_longitude,
        SENSOR_ID_LOG => lbl_vessel_log,
        SENSOR_ID_HDG => lbl_vessel_hdg,
        SENSOR_ID_STW => lbl_vessel_stw,
        SENSOR_ID_SOG => lbl_vessel_sog,
        SENSOR_ID_COG => lbl_vessel_cog,
        SENSOR_ID_AWS => lbl_env_aws,
        SENSOR_ID_AWA => lbl_env_awa,
        SENSOR_ID_TWS => lbl_env_tws,
        SENSOR_ID_TWD => lbl_env_twd,
        SENSOR_ID_BARO => lbl_env_baro,
        SENSOR_ID_DISTANCE_24H => lbl_distance_24h,
        SENSOR_ID_SPEED_24H => lbl_speed_24h,
        SENSOR_ID_DATETIME => lbl_logbook_datetime,
        else => null,
    };

    if (label) |lbl| {
        lv.lv_label_set_text(lbl, value);
    }
}

// ============================================================
// GPS card (special two-line card)
// ============================================================

const GpsCardLabels = struct {
    latitude: ?*lv.lv_obj_t,
    longitude: ?*lv.lv_obj_t,
};

fn createGpsCard(parent: ?*lv.lv_obj_t, card_w: i32, card_h: i32, title: [*:0]const u8) GpsCardLabels {
    if (parent == null) return .{ .latitude = null, .longitude = null };

    const card = lv.lv_obj_create(parent);
    if (card == null) return .{ .latitude = null, .longitude = null };

    lv.lv_obj_set_size(card, card_w, card_h);
    lv.lv_obj_set_style_bg_color(card, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(card, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(card, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(card, 1, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(card, lv.lv_color_hex(theme.COL_CARD_BORDER), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(card, 14, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(card, lv.LV_OBJ_FLAG_SCROLLABLE);
    lv.lv_obj_set_flex_flow(card, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_row(card, 6, lv.LV_PART_MAIN);

    const title_lbl = lv.lv_label_create(card);
    if (title_lbl) |tl| {
        lv.lv_label_set_text(tl, title);
        lv.lv_obj_set_style_text_color(tl, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(tl, lv.lv_font_montserrat_14, lv.LV_PART_MAIN);
    }

    var out = GpsCardLabels{ .latitude = null, .longitude = null };

    const lat_row = lv.lv_obj_create(card);
    if (lat_row) |row| {
        lv.lv_obj_set_size(row, lv.LV_PCT(100), lv.LV_SIZE_CONTENT);
        lv.lv_obj_set_style_bg_opa(row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(row, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_all(row, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_column(row, 8, lv.LV_PART_MAIN);
        lv.lv_obj_set_flex_flow(row, lv.LV_FLEX_FLOW_ROW);
        lv.lv_obj_set_flex_align(row, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
        lv.lv_obj_remove_flag(row, lv.LV_OBJ_FLAG_SCROLLABLE);

        const lat_val = lv.lv_label_create(row);
        if (lat_val) |lvv| {
            lv.lv_label_set_text(lvv, "--");
            lv.lv_obj_set_style_text_color(lvv, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lvv, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
            out.latitude = lvv;
        }
    }

    const lon_row = lv.lv_obj_create(card);
    if (lon_row) |row| {
        lv.lv_obj_set_size(row, lv.LV_PCT(100), lv.LV_SIZE_CONTENT);
        lv.lv_obj_set_style_bg_opa(row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(row, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_all(row, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_column(row, 8, lv.LV_PART_MAIN);
        lv.lv_obj_set_flex_flow(row, lv.LV_FLEX_FLOW_ROW);
        lv.lv_obj_set_flex_align(row, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
        lv.lv_obj_remove_flag(row, lv.LV_OBJ_FLAG_SCROLLABLE);

        const lon_val = lv.lv_label_create(row);
        if (lon_val) |lvv| {
            lv.lv_label_set_text(lvv, "--");
            lv.lv_obj_set_style_text_color(lvv, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lvv, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
            out.longitude = lvv;
        }
    }

    return out;
}
