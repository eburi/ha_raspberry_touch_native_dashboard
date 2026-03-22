///! Multi-page LVGL dashboard with right-side icon navigation.
///!
///! Layout (1280x720):
///!   [   Page Content (90%)   ][ Nav Bar (10%) ]
///!
///! Pages:
///!   0 — Logbook:      Position + 24h log sensor cards
///!   1 — Anchor Alarm: Anchor watch with map, alarm ring, and controls
///!   2 — Sails:        Main sail, jib & code 0 configuration
///!   3 — Settings:     Power off with long-press animation
///!
///! This file is the coordinator — it delegates to sub-modules for each
///! page and the navigation bar, while preserving the public API surface.
const lv = @import("lv");

// Sub-modules
const theme = @import("dashboard/theme.zig");
const navbar = @import("dashboard/navbar.zig");
const logbook = @import("dashboard/logbook.zig");
const anchor = @import("dashboard/anchor.zig");
const sails = @import("dashboard/sails.zig");
const settings = @import("dashboard/settings.zig");

// Re-export sensor ID constants (used by wasm/main.zig and native/main.zig)
pub const SENSOR_ID_LATITUDE = logbook.SENSOR_ID_LATITUDE;
pub const SENSOR_ID_LONGITUDE = logbook.SENSOR_ID_LONGITUDE;
pub const SENSOR_ID_LOG = logbook.SENSOR_ID_LOG;
pub const SENSOR_ID_HDG = logbook.SENSOR_ID_HDG;
pub const SENSOR_ID_STW = logbook.SENSOR_ID_STW;
pub const SENSOR_ID_SOG = logbook.SENSOR_ID_SOG;
pub const SENSOR_ID_COG = logbook.SENSOR_ID_COG;
pub const SENSOR_ID_AWS = logbook.SENSOR_ID_AWS;
pub const SENSOR_ID_AWA = logbook.SENSOR_ID_AWA;
pub const SENSOR_ID_TWS = logbook.SENSOR_ID_TWS;
pub const SENSOR_ID_TWD = logbook.SENSOR_ID_TWD;
pub const SENSOR_ID_BARO = logbook.SENSOR_ID_BARO;
pub const SENSOR_ID_DISTANCE_24H = logbook.SENSOR_ID_DISTANCE_24H;
pub const SENSOR_ID_SPEED_24H = logbook.SENSOR_ID_SPEED_24H;
pub const SENSOR_ID_DATETIME = logbook.SENSOR_ID_DATETIME;

// Re-export entity constants
pub const ENTITY_SAIL_MAIN = sails.ENTITY_SAIL_MAIN;
pub const ENTITY_SAIL_JIB = sails.ENTITY_SAIL_JIB;
pub const ENTITY_CODE0 = sails.ENTITY_CODE0;
pub const ENTITY_COUNT = sails.ENTITY_COUNT;

// Re-export anchor connection state constants
pub const ANCHOR_CONN_ESTABLISH = anchor.ANCHOR_CONN_ESTABLISH;
pub const ANCHOR_CONN_STREAMING = anchor.ANCHOR_CONN_STREAMING;
pub const ANCHOR_CONN_STALE = anchor.ANCHOR_CONN_STALE;

// ============================================================
// Module state
// ============================================================
var screen_w: u32 = 1280;
var screen_h: u32 = 720;
var nav_w: u32 = 128;
var page_w: u32 = 1152;

// Platform callbacks — injected by the platform layer (WASM, native, etc.)
// These decouple the dashboard from any specific runtime environment.
pub const PlatformCallbacks = struct {
    /// Called when a sail config select option changes.
    /// entity: HA entity ID, option: selected option label.
    sail_config_changed: ?*const fn (entity_ptr: [*]const u8, entity_len: i32, option_ptr: [*]const u8, option_len: i32) void = null,
    /// Called when a sail boolean toggle changes.
    /// entity: HA entity ID, state: 1=on, 0=off.
    sail_toggle_changed: ?*const fn (entity_ptr: [*]const u8, entity_len: i32, state: i32) void = null,
    /// Called when an anchor control button is pressed.
    /// action: action name string, value: numeric parameter.
    anchor_action: ?*const fn (action_ptr: [*]const u8, action_len: i32, value: f64) void = null,
    /// Called when the power off long-press completes.
    power_off: ?*const fn () void = null,
};

pub fn setPlatformCallbacks(callbacks: PlatformCallbacks) void {
    // Distribute callbacks to sub-modules
    sails.setSailCallbacks(callbacks.sail_config_changed, callbacks.sail_toggle_changed);
    anchor.setAnchorActionCallback(callbacks.anchor_action);
    settings.setPowerOffCallback(callbacks.power_off);
}

// ============================================================
// Public API
// ============================================================

pub fn init(w: u32, h: u32) void {
    screen_w = w;
    screen_h = h;
    nav_w = w * theme.NAV_WIDTH_PCT / 100;
    page_w = w - nav_w;
}

pub fn create() void {
    const screen = lv.lv_screen_active();
    if (screen == null) return;

    // Screen background
    lv.lv_obj_set_style_bg_color(screen, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(screen, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(screen, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Create the page content area (left 90%)
    createPages(screen);

    // Create the navigation bar (right 10%)
    navbar.create(screen, nav_w, screen_h);

    // Show the first page
    navbar.showPage(theme.PAGE_LOGBOOK);
}

/// Set a configurable entity ID at runtime.
///   slot: 0=sail_main, 1=sail_jib, 2=sail_code0
pub fn setEntityId(slot: i32, ptr: [*]const u8, len: i32) void {
    sails.setEntityId(slot, ptr, len);
}

// ============================================================
// State update functions (delegated to sub-modules)
// ============================================================

pub fn update_sensor(sensor_id: i32, value_ptr: [*]const u8, value_len: i32) void {
    logbook.update_sensor(sensor_id, value_ptr, value_len);
}

pub fn update_sail_main(value_ptr: [*]const u8, value_len: i32) void {
    sails.update_sail_main(value_ptr, value_len);
}

pub fn update_sail_jib(value_ptr: [*]const u8, value_len: i32) void {
    sails.update_sail_jib(value_ptr, value_len);
}

pub fn update_code0(value_ptr: [*]const u8, value_len: i32) void {
    sails.update_code0(value_ptr, value_len);
}

pub fn update_anchor_connection_state(state: i32) void {
    anchor.update_connection_state(state);
}

pub fn update_anchor_loader_rotation(deg10: i32) void {
    anchor.update_loader_rotation(deg10);
}

pub fn update_anchor_status(value_ptr: [*]const u8, value_len: i32) void {
    anchor.update_status(value_ptr, value_len);
}

pub fn update_anchor_info(value_ptr: [*]const u8, value_len: i32) void {
    anchor.update_info(value_ptr, value_len);
}

pub fn update_anchor_mode(is_set: i32) void {
    anchor.update_mode(is_set);
}

pub fn update_anchor_ring_px(diameter_px: i32) void {
    anchor.update_ring_px(diameter_px);
}

pub fn update_anchor_anchor_px(x: i32, y: i32) void {
    anchor.update_anchor_px(x, y);
}

pub fn update_anchor_boat_px(x: i32, y: i32, heading_deg10: i32) void {
    anchor.update_boat_px(x, y, heading_deg10);
}

pub fn update_anchor_line_point(index: i32, x: i32, y: i32, visible: i32) void {
    anchor.update_line_point(index, x, y, visible);
}

pub fn update_anchor_track_point(index: i32, x: i32, y: i32, visible: i32) void {
    anchor.update_track_point(index, x, y, visible);
}

pub fn update_anchor_other_boat(index: i32, x: i32, y: i32, visible: i32, heading_deg10: i32) void {
    anchor.update_other_boat(index, x, y, visible, heading_deg10);
}

pub fn update_anchor_other_track_point(vessel_index: i32, point_index: i32, x: i32, y: i32, visible: i32) void {
    anchor.update_other_track_point(vessel_index, point_index, x, y, visible);
}

// ============================================================
// Page containers
// ============================================================

fn createPages(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    for (0..theme.PAGE_COUNT) |i| {
        const container = lv.lv_obj_create(parent);
        if (container == null) continue;

        lv.lv_obj_set_size(container, @intCast(page_w), @intCast(screen_h));
        lv.lv_obj_align(container, lv.LV_ALIGN_TOP_LEFT, 0, 0);
        lv.lv_obj_set_style_bg_opa(container, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(container, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_radius(container, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_all(container, if (i == theme.PAGE_ANCHOR) 0 else 20, lv.LV_PART_MAIN);
        lv.lv_obj_remove_flag(container, lv.LV_OBJ_FLAG_SCROLLABLE);

        // Start hidden (showPage will reveal the active one)
        lv.lv_obj_add_flag(container, lv.LV_OBJ_FLAG_HIDDEN);

        // Register the container with the navbar for show/hide
        navbar.setPageContainer(i, container);

        // Populate page content
        switch (i) {
            theme.PAGE_LOGBOOK => logbook.create(container, page_w, screen_h),
            theme.PAGE_ANCHOR => anchor.create(container, page_w, screen_h),
            theme.PAGE_SAILS => sails.create(container, page_w, screen_h),
            theme.PAGE_SETTINGS => settings.create(container),
            else => {},
        }
    }
}
