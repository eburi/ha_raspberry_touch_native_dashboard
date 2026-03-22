///! Page 1: Anchor Alarm — Anchor watch with map, alarm ring, and controls.
const std = @import("std");
const lv = @import("lv");
const theme = @import("theme.zig");

// ============================================================
// Constants
// ============================================================
const ANCHOR_TRACK_POINTS = 48;
const ANCHOR_LINE_POINTS = 40;
const ANCHOR_MAX_OTHER = 6;
const ANCHOR_OTHER_TRACK_POINTS = 20;

pub const ANCHOR_CONN_ESTABLISH: i32 = 0;
pub const ANCHOR_CONN_STREAMING: i32 = 1;
pub const ANCHOR_CONN_STALE: i32 = 2;

const ANCHOR_ACTION_RADIUS_DEC = "radius_dec";
const ANCHOR_ACTION_RADIUS_INC = "radius_inc";
const ANCHOR_ACTION_DROP_RAISE = "drop_or_raise";
const ANCHOR_ACTION_ZOOM_DEC = "zoom_dec";
const ANCHOR_ACTION_ZOOM_INC = "zoom_inc";

const ANCHOR_BTN_RADIUS_DEC: usize = 1;
const ANCHOR_BTN_TOGGLE: usize = 2;
const ANCHOR_BTN_RADIUS_INC: usize = 3;
const ANCHOR_BTN_ZOOM_DEC: usize = 4;
const ANCHOR_BTN_ZOOM_INC: usize = 5;

// ============================================================
// Module state
// ============================================================
var anchor_root: ?*lv.lv_obj_t = null;
var anchor_controls_bar: ?*lv.lv_obj_t = null;
var anchor_connection_screen: ?*lv.lv_obj_t = null;
var anchor_connection_title: ?*lv.lv_obj_t = null;
var anchor_connection_status: ?*lv.lv_obj_t = null;
var anchor_data_icon: ?*lv.lv_obj_t = null;
var anchor_map: ?*lv.lv_obj_t = null;
var anchor_ring: ?*lv.lv_obj_t = null;
var anchor_icon: ?*lv.lv_obj_t = null;
var anchor_boat: ?*lv.lv_obj_t = null;
var anchor_info: ?*lv.lv_obj_t = null;
var anchor_zoom_lbl: ?*lv.lv_obj_t = null;
var anchor_action_btn_label: ?*lv.lv_obj_t = null;
var anchor_is_set: bool = false;
var anchor_ring_diameter_px: i32 = 380;
var anchor_center_x_px: i32 = 0;
var anchor_center_y_px: i32 = 0;

var anchor_line_dots: [ANCHOR_LINE_POINTS]?*lv.lv_obj_t = .{null} ** ANCHOR_LINE_POINTS;
var anchor_track_dots: [ANCHOR_TRACK_POINTS]?*lv.lv_obj_t = .{null} ** ANCHOR_TRACK_POINTS;
var anchor_other_boats: [ANCHOR_MAX_OTHER]?*lv.lv_obj_t = .{null} ** ANCHOR_MAX_OTHER;
var anchor_other_tracks: [ANCHOR_MAX_OTHER][ANCHOR_OTHER_TRACK_POINTS]?*lv.lv_obj_t = [_][ANCHOR_OTHER_TRACK_POINTS]?*lv.lv_obj_t{.{null} ** ANCHOR_OTHER_TRACK_POINTS} ** ANCHOR_MAX_OTHER;

/// Platform callback for anchor actions — set by the coordinator.
var anchor_action_cb: ?*const fn (action_ptr: [*]const u8, action_len: i32, value: f64) void = null;

// ============================================================
// Public API
// ============================================================

pub fn setAnchorActionCallback(cb: ?*const fn (action_ptr: [*]const u8, action_len: i32, value: f64) void) void {
    anchor_action_cb = cb;
}

pub fn create(parent: ?*lv.lv_obj_t, page_w: u32, screen_h: u32) void {
    if (parent == null) return;

    theme.createPageTitle(parent, "Anchor Alarm", theme.PAGE_ANCHOR);

    const data_icon = lv.lv_image_create(parent);
    if (data_icon) |im| {
        anchor_data_icon = im;
        lv.lv_image_set_src(im, &lv.tabler_icon_loader_2_P);
        lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(im, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_align(im, lv.LV_ALIGN_TOP_RIGHT, -2, 4);
        lv.lv_obj_add_flag(im, lv.LV_OBJ_FLAG_HIDDEN);
    }

    const compass_icon = lv.lv_image_create(parent);
    if (compass_icon) |im| {
        lv.lv_image_set_src(im, &lv.tabler_icon_assets_compass_north_svgrepo_com_svg_N);
        lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(im, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_align(im, lv.LV_ALIGN_TOP_LEFT, 0, theme.PAGE_TITLE_H + 8);
    }

    const root = lv.lv_obj_create(parent);
    if (root == null) return;
    anchor_root = root;

    const root_h: i32 = @intCast(screen_h - theme.PAGE_TITLE_H);
    lv.lv_obj_set_size(root, @intCast(page_w), root_h);
    lv.lv_obj_align(root, lv.LV_ALIGN_TOP_LEFT, 0, theme.PAGE_TITLE_H);
    lv.lv_obj_set_style_bg_color(root, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(root, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(root, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(root, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(root, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(root, lv.LV_OBJ_FLAG_SCROLLABLE);

    const map_h: i32 = root_h - 120;
    const map = lv.lv_obj_create(root);
    if (map == null) return;
    anchor_map = map;
    lv.lv_obj_set_size(map, lv.LV_PCT(100), map_h);
    lv.lv_obj_align(map, lv.LV_ALIGN_TOP_LEFT, 0, 0);
    lv.lv_obj_set_style_bg_color(map, lv.lv_color_hex(0x000000), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(map, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(map, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(map, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(map, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Radius ring around fixed anchor position.
    const ring = lv.lv_obj_create(map);
    if (ring) |r| {
        anchor_ring = r;
        lv.lv_obj_set_size(r, 380, 380);
        lv.lv_obj_set_style_bg_opa(r, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(r, 2, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_color(r, lv.lv_color_hex(0x3CAEA3), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_radius(r, 190, lv.LV_PART_MAIN);
        lv.lv_obj_align(r, lv.LV_ALIGN_CENTER, 0, 0);
    }

    // Anchor icon in map center.
    const anchor_img = lv.lv_image_create(map);
    if (anchor_img) |im| {
        anchor_icon = im;
        lv.lv_image_set_src(im, &lv.tabler_icon_anchor_S);
        lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(0xFFD166), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(im, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_align(im, lv.LV_ALIGN_CENTER, 0, 0);
    }

    const boat_img = lv.lv_image_create(map);
    if (boat_img) |im| {
        anchor_boat = im;
        lv.lv_image_set_src(im, &lv.tabler_icon_triangle_filled_S);
        lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(im, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_image_set_pivot(im, 12, 12);
        lv.lv_image_set_rotation(im, 0);
        lv.lv_obj_align(im, lv.LV_ALIGN_CENTER, 0, 0);
    }

    // Self track dots
    for (0..ANCHOR_TRACK_POINTS) |i| {
        const d = lv.lv_obj_create(map);
        if (d) |dot| {
            anchor_track_dots[i] = dot;
            lv.lv_obj_set_size(dot, 2, 2);
            lv.lv_obj_set_style_radius(dot, 1, lv.LV_PART_MAIN);
            lv.lv_obj_set_style_bg_color(dot, lv.lv_color_hex(0x5DADE2), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_bg_opa(dot, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
            lv.lv_obj_set_style_border_width(dot, 0, lv.LV_PART_MAIN);
            lv.lv_obj_add_flag(dot, lv.LV_OBJ_FLAG_HIDDEN);
        }
    }

    // Anchor-to-boat line dots
    for (0..ANCHOR_LINE_POINTS) |i| {
        const d = lv.lv_obj_create(map);
        if (d) |dot| {
            anchor_line_dots[i] = dot;
            lv.lv_obj_set_size(dot, 2, 2);
            lv.lv_obj_set_style_radius(dot, 1, lv.LV_PART_MAIN);
            lv.lv_obj_set_style_bg_color(dot, lv.lv_color_hex(0xE0E0E0), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_bg_opa(dot, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
            lv.lv_obj_set_style_border_width(dot, 0, lv.LV_PART_MAIN);
            lv.lv_obj_add_flag(dot, lv.LV_OBJ_FLAG_HIDDEN);
        }
    }

    // Other vessels and their simplified tracks
    for (0..ANCHOR_MAX_OTHER) |i| {
        const other = lv.lv_image_create(map);
        if (other) |im| {
            anchor_other_boats[i] = im;
            lv.lv_image_set_src(im, &lv.tabler_icon_triangle_filled_S);
            lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_image_recolor_opa(im, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
            lv.lv_image_set_pivot(im, 12, 12);
            lv.lv_image_set_rotation(im, 0);
            lv.lv_obj_add_flag(im, lv.LV_OBJ_FLAG_HIDDEN);
        }

        for (0..ANCHOR_OTHER_TRACK_POINTS) |j| {
            const td = lv.lv_obj_create(map);
            if (td) |dot| {
                anchor_other_tracks[i][j] = dot;
                lv.lv_obj_set_size(dot, 1, 1);
                lv.lv_obj_set_style_radius(dot, 1, lv.LV_PART_MAIN);
                lv.lv_obj_set_style_bg_color(dot, lv.lv_color_hex(0x666666), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_bg_opa(dot, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
                lv.lv_obj_set_style_border_width(dot, 0, lv.LV_PART_MAIN);
                lv.lv_obj_add_flag(dot, lv.LV_OBJ_FLAG_HIDDEN);
            }
        }
    }

    createAnchorControls(root);

    const conn = lv.lv_obj_create(root);
    if (conn) |cs| {
        anchor_connection_screen = cs;
        lv.lv_obj_set_size(cs, lv.LV_PCT(100), map_h);
        lv.lv_obj_align(cs, lv.LV_ALIGN_TOP_LEFT, 0, 0);
        lv.lv_obj_set_style_bg_color(cs, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_bg_opa(cs, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(cs, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_all(cs, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_flex_flow(cs, lv.LV_FLEX_FLOW_COLUMN);
        lv.lv_obj_set_flex_align(cs, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
        lv.lv_obj_set_style_pad_row(cs, 10, lv.LV_PART_MAIN);
        lv.lv_obj_remove_flag(cs, lv.LV_OBJ_FLAG_SCROLLABLE);

        anchor_connection_title = lv.lv_label_create(cs);
        if (anchor_connection_title) |lbl| {
            lv.lv_label_set_text(lbl, "Status");
            lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lbl, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        }

        anchor_connection_status = lv.lv_label_create(cs);
        if (anchor_connection_status) |lbl| {
            lv.lv_label_set_text(lbl, "Detecting SignalK...");
            lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_TEXT), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lbl, lv.lv_font_montserrat_24, lv.LV_PART_MAIN);
        }
    }

    anchor_info = null;
    setAnchorConnectionUi(ANCHOR_CONN_ESTABLISH);
}

// ============================================================
// State update functions
// ============================================================

pub fn update_connection_state(state: i32) void {
    setAnchorConnectionUi(state);
}

pub fn update_loader_rotation(deg10: i32) void {
    if (anchor_data_icon) |icon| {
        lv.lv_image_set_rotation(icon, deg10);
    }
}

pub fn update_status(value_ptr: [*]const u8, value_len: i32) void {
    _ = value_len;
    if (anchor_connection_status) |lbl| {
        lv.lv_label_set_text(lbl, @ptrCast(value_ptr));
    }
}

pub fn update_info(value_ptr: [*]const u8, value_len: i32) void {
    _ = value_len;
    if (anchor_info) |lbl| {
        lv.lv_label_set_text(lbl, @ptrCast(value_ptr));
    }
}

pub fn update_mode(is_set: i32) void {
    anchor_is_set = is_set != 0;
    if (anchor_action_btn_label) |lbl| {
        lv.lv_label_set_text(lbl, if (anchor_is_set) "Raise Anchor" else "Drop Anchor");
    }

    if (anchor_ring) |ring| {
        const color: u32 = if (anchor_is_set) 0x2A9D8F else 0x3A86FF;
        lv.lv_obj_set_style_border_color(ring, lv.lv_color_hex(color), lv.LV_PART_MAIN);
    }
}

pub fn update_ring_px(diameter_px: i32) void {
    anchor_ring_diameter_px = std.math.clamp(diameter_px, 40, 1200);
    updateAnchorRingGeometry();
}

pub fn update_anchor_px(x: i32, y: i32) void {
    anchor_center_x_px = x;
    anchor_center_y_px = y;
    if (anchor_icon) |anchor| {
        lv.lv_obj_set_pos(anchor, x - 12, y - 12);
    }
    updateAnchorRingGeometry();
}

pub fn update_boat_px(x: i32, y: i32, heading_deg10: i32) void {
    if (anchor_boat) |boat| {
        lv.lv_obj_set_pos(boat, x - 12, y - 12);
        lv.lv_image_set_rotation(boat, heading_deg10);
    }
}

pub fn update_line_point(index: i32, x: i32, y: i32, visible: i32) void {
    if (index < 0 or index >= ANCHOR_LINE_POINTS) return;
    updatePoint(anchor_line_dots[@intCast(index)], x, y, visible != 0);
}

pub fn update_track_point(index: i32, x: i32, y: i32, visible: i32) void {
    if (index < 0 or index >= ANCHOR_TRACK_POINTS) return;
    updatePoint(anchor_track_dots[@intCast(index)], x, y, visible != 0);
}

pub fn update_other_boat(index: i32, x: i32, y: i32, visible: i32, heading_deg10: i32) void {
    if (index < 0 or index >= ANCHOR_MAX_OTHER) return;
    const idx: usize = @intCast(index);
    if (anchor_other_boats[idx]) |boat| {
        lv.lv_obj_set_pos(boat, x - 8, y - 8);
        lv.lv_image_set_rotation(boat, heading_deg10);
        if (visible != 0) {
            lv.lv_obj_remove_flag(boat, lv.LV_OBJ_FLAG_HIDDEN);
        } else {
            lv.lv_obj_add_flag(boat, lv.LV_OBJ_FLAG_HIDDEN);
        }
    }
}

pub fn update_other_track_point(vessel_index: i32, point_index: i32, x: i32, y: i32, visible: i32) void {
    if (vessel_index < 0 or vessel_index >= ANCHOR_MAX_OTHER) return;
    if (point_index < 0 or point_index >= ANCHOR_OTHER_TRACK_POINTS) return;
    updatePoint(anchor_other_tracks[@intCast(vessel_index)][@intCast(point_index)], x, y, visible != 0);
}

// ============================================================
// Internal helpers
// ============================================================

fn updatePoint(obj: ?*lv.lv_obj_t, x: i32, y: i32, visible: bool) void {
    if (obj) |dot| {
        lv.lv_obj_set_pos(dot, x, y);
        if (visible) {
            lv.lv_obj_remove_flag(dot, lv.LV_OBJ_FLAG_HIDDEN);
        } else {
            lv.lv_obj_add_flag(dot, lv.LV_OBJ_FLAG_HIDDEN);
        }
    }
}

fn updateAnchorRingGeometry() void {
    if (anchor_ring) |ring| {
        lv.lv_obj_set_size(ring, anchor_ring_diameter_px, anchor_ring_diameter_px);
        lv.lv_obj_set_style_radius(ring, @divTrunc(anchor_ring_diameter_px, 2), lv.LV_PART_MAIN);
        lv.lv_obj_set_pos(
            ring,
            anchor_center_x_px - @divTrunc(anchor_ring_diameter_px, 2),
            anchor_center_y_px - @divTrunc(anchor_ring_diameter_px, 2),
        );
    }
}

fn setAnchorConnectionUi(state: i32) void {
    if (anchor_data_icon) |icon| {
        if (state == ANCHOR_CONN_STREAMING) {
            lv.lv_image_set_src(icon, &lv.tabler_icon_loader_2_P);
            lv.lv_obj_set_style_image_recolor(icon, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
            lv.lv_obj_remove_flag(icon, lv.LV_OBJ_FLAG_HIDDEN);
        } else if (state == ANCHOR_CONN_STALE) {
            lv.lv_image_set_src(icon, &lv.tabler_icon_alert_square_rounded_P);
            lv.lv_obj_set_style_image_recolor(icon, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
            lv.lv_obj_remove_flag(icon, lv.LV_OBJ_FLAG_HIDDEN);
        } else {
            lv.lv_obj_add_flag(icon, lv.LV_OBJ_FLAG_HIDDEN);
        }
    }

    if (state == ANCHOR_CONN_ESTABLISH) {
        if (anchor_connection_screen) |obj| lv.lv_obj_remove_flag(obj, lv.LV_OBJ_FLAG_HIDDEN);
        if (anchor_map) |obj| lv.lv_obj_add_flag(obj, lv.LV_OBJ_FLAG_HIDDEN);
        if (anchor_controls_bar) |obj| lv.lv_obj_add_flag(obj, lv.LV_OBJ_FLAG_HIDDEN);
    } else {
        if (anchor_connection_screen) |obj| lv.lv_obj_add_flag(obj, lv.LV_OBJ_FLAG_HIDDEN);
        if (anchor_map) |obj| lv.lv_obj_remove_flag(obj, lv.LV_OBJ_FLAG_HIDDEN);
        if (anchor_controls_bar) |obj| lv.lv_obj_remove_flag(obj, lv.LV_OBJ_FLAG_HIDDEN);
    }
}

fn createAnchorControls(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    const bar = lv.lv_obj_create(parent);
    if (bar == null) return;
    anchor_controls_bar = bar;

    lv.lv_obj_set_size(bar, lv.LV_PCT(100), 120);
    lv.lv_obj_align(bar, lv.LV_ALIGN_BOTTOM_MID, 0, 0);
    lv.lv_obj_set_style_bg_color(bar, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(bar, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(bar, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_left(bar, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_right(bar, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_top(bar, 8, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_bottom(bar, 8, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_column(bar, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(bar, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(bar, lv.LV_FLEX_ALIGN_SPACE_BETWEEN, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(bar, lv.LV_OBJ_FLAG_SCROLLABLE);

    const left = lv.lv_obj_create(bar);
    if (left) |l| {
        lv.lv_obj_set_size(l, lv.LV_SIZE_CONTENT, lv.LV_SIZE_CONTENT);
        lv.lv_obj_set_style_bg_opa(l, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(l, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_all(l, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_column(l, 8, lv.LV_PART_MAIN);
        lv.lv_obj_set_flex_flow(l, lv.LV_FLEX_FLOW_ROW);
        lv.lv_obj_set_flex_align(l, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
        lv.lv_obj_remove_flag(l, lv.LV_OBJ_FLAG_SCROLLABLE);

        _ = createAnchorBtn(l, "-", 100, ANCHOR_BTN_RADIUS_DEC, false);
        anchor_action_btn_label = createAnchorBtn(l, "Drop Anchor", 300, ANCHOR_BTN_TOGGLE, true);
        _ = createAnchorBtn(l, "+", 100, ANCHOR_BTN_RADIUS_INC, false);
    }

    const right = lv.lv_obj_create(bar);
    if (right) |r| {
        lv.lv_obj_set_size(r, lv.LV_SIZE_CONTENT, lv.LV_SIZE_CONTENT);
        lv.lv_obj_set_style_bg_opa(r, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(r, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_all(r, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_column(r, 8, lv.LV_PART_MAIN);
        lv.lv_obj_set_flex_flow(r, lv.LV_FLEX_FLOW_ROW);
        lv.lv_obj_set_flex_align(r, lv.LV_FLEX_ALIGN_END, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
        lv.lv_obj_remove_flag(r, lv.LV_OBJ_FLAG_SCROLLABLE);

        _ = createAnchorBtn(r, "-", 100, ANCHOR_BTN_ZOOM_DEC, false);
        _ = createAnchorBtn(r, "+", 100, ANCHOR_BTN_ZOOM_INC, false);
    }
}

fn createAnchorBtn(parent: ?*lv.lv_obj_t, text: [*:0]const u8, width: i32, id: usize, keep_label: bool) ?*lv.lv_obj_t {
    if (parent == null) return null;
    const btn = lv.lv_button_create(parent);
    if (btn == null) return null;

    lv.lv_obj_set_size(btn, width, 100);
    lv.lv_obj_set_style_radius(btn, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(btn, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_shadow_width(btn, 0, lv.LV_PART_MAIN);

    const lbl = lv.lv_label_create(btn);
    var out: ?*lv.lv_obj_t = null;
    if (lbl) |l| {
        lv.lv_label_set_text(l, text);
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_28, lv.LV_PART_MAIN);
        lv.lv_obj_center(l);
        if (keep_label) out = l;
    }

    const user_data: ?*anyopaque = @ptrFromInt(id);
    _ = lv.lv_obj_add_event_cb(btn, anchorButtonCb, lv.LV_EVENT_CLICKED, user_data);
    return out;
}

fn anchorButtonCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    const cb = anchor_action_cb orelse return;
    const user_data = lv.lv_event_get_user_data(e);
    const id: usize = @intFromPtr(user_data);

    switch (id) {
        ANCHOR_BTN_RADIUS_DEC => cb(ANCHOR_ACTION_RADIUS_DEC.ptr, ANCHOR_ACTION_RADIUS_DEC.len, 0),
        ANCHOR_BTN_RADIUS_INC => cb(ANCHOR_ACTION_RADIUS_INC.ptr, ANCHOR_ACTION_RADIUS_INC.len, 0),
        ANCHOR_BTN_TOGGLE => cb(ANCHOR_ACTION_DROP_RAISE.ptr, ANCHOR_ACTION_DROP_RAISE.len, 0),
        ANCHOR_BTN_ZOOM_DEC => cb(ANCHOR_ACTION_ZOOM_DEC.ptr, ANCHOR_ACTION_ZOOM_DEC.len, 0),
        ANCHOR_BTN_ZOOM_INC => cb(ANCHOR_ACTION_ZOOM_INC.ptr, ANCHOR_ACTION_ZOOM_INC.len, 0),
        else => {},
    }
}
