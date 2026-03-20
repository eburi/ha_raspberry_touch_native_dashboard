///! Multi-page LVGL dashboard with right-side icon navigation.
///!
///! Layout (1280x720):
///!   [   Page Content (90%)   ][ Nav Bar (10%) ]
///!
///! Pages:
///!   0 — Logbook:      Position + 24h log sensor cards
///!   1 — Anchor Alarm: Anchor watch with map, alarm ring, and controls
///!   2 — Sails:        Main sail, jib & code 0 configuration
///!
///! Color palette (dark nautical theme):
///!   BG_DARK    #220901  — screen / deepest background
///!   BG_MID     #621708  — card backgrounds
///!   ACCENT_1   #941B0C  — borders, inactive elements
///!   ACCENT_2   #BC3908  — active nav icon, highlights
///!   FOREGROUND #F6AA1C  — text, values, active buttons
const std = @import("std");
const lv = @import("lv");

// ============================================================
// Color palette
// ============================================================
const COL_BG_DARK = 0x180600;
const COL_BG_MID = 0x621708;
const COL_ACCENT_1 = 0x941B0C;
const COL_ACCENT_2 = 0xBC3908;
const COL_FG = 0xF6AA1C;
const COL_TEXT = 0xF6AA1C;
const COL_TEXT_DIM = 0x944A10; // dimmed text (derived: midpoint FG/BG)
const COL_NAV_BG = 0x180600; // slightly darker than BG_DARK for nav bar
const COL_CARD_BG = 0x3A0E04; // card background (between BG_DARK and BG_MID)
const COL_CARD_BORDER = 0x621708;

// ============================================================
// Layout constants (1280x720)
// ============================================================
const NAV_WIDTH_PCT = 10; // right-side nav bar = 10% of screen width
const PAGE_TITLE_H = 48; // page title row height

// ============================================================
// Page indices
// ============================================================
const PAGE_LOGBOOK: usize = 0;
const PAGE_ANCHOR: usize = 1;
const PAGE_SAILS: usize = 2;
const PAGE_COUNT: usize = 3;

// ============================================================
// Module state
// ============================================================
var screen_w: u32 = 1280;
var screen_h: u32 = 720;
var nav_w: u32 = 128;
var page_w: u32 = 1152;

var current_page: usize = PAGE_LOGBOOK;

// Page container objects (one per page, shown/hidden)
var page_containers: [PAGE_COUNT]?*lv.lv_obj_t = .{ null, null, null };

// Nav icon button objects (for highlight tracking)
var nav_buttons: [PAGE_COUNT]?*lv.lv_obj_t = .{ null, null, null };

// --- Logbook page sensor labels (updated via platform state callbacks) ---
const SENSOR_ID_LATITUDE: i32 = 0;
const SENSOR_ID_LONGITUDE: i32 = 1;
const SENSOR_ID_LOG: i32 = 2;
const SENSOR_ID_HDG: i32 = 3;
const SENSOR_ID_STW: i32 = 4;
const SENSOR_ID_SOG: i32 = 5;
const SENSOR_ID_COG: i32 = 6;
const SENSOR_ID_AWS: i32 = 7;
const SENSOR_ID_AWA: i32 = 8;
const SENSOR_ID_TWS: i32 = 9;
const SENSOR_ID_TWD: i32 = 10;
const SENSOR_ID_BARO: i32 = 11;
const SENSOR_ID_DISTANCE_24H: i32 = 12;
const SENSOR_ID_SPEED_24H: i32 = 13;
const SENSOR_ID_DATETIME: i32 = 14;

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

// --- Anchor page objects ---
const ANCHOR_TRACK_POINTS = 48;
const ANCHOR_LINE_POINTS = 40;
const ANCHOR_MAX_OTHER = 6;
const ANCHOR_OTHER_TRACK_POINTS = 20;

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

const ANCHOR_CONN_ESTABLISH: i32 = 0;
const ANCHOR_CONN_STREAMING: i32 = 1;
const ANCHOR_CONN_STALE: i32 = 2;

const ANCHOR_ACTION_RADIUS_DEC = "radius_dec";
const ANCHOR_ACTION_RADIUS_INC = "radius_inc";
const ANCHOR_ACTION_DROP_RAISE = "drop_or_raise";
const ANCHOR_ACTION_ZOOM_DEC = "zoom_dec";
const ANCHOR_ACTION_ZOOM_INC = "zoom_inc";

// --- Sails page button references ---
const SAIL_MAIN_OPTIONS = 5;
const sail_main_labels = [SAIL_MAIN_OPTIONS][*:0]const u8{
    "0%",
    "100%",
    "Reef 1",
    "Reef 2",
    "Reef 3",
};
var sail_main_btns: [SAIL_MAIN_OPTIONS]?*lv.lv_obj_t = .{ null, null, null, null, null };
var sail_main_current: usize = 0; // index of currently active option

const SAIL_JIB_OPTIONS = 6;
const sail_jib_labels = [SAIL_JIB_OPTIONS][*:0]const u8{
    "0%",
    "100%",
    "75%",
    "60%",
    "40%",
    "25%",
};
var sail_jib_btns: [SAIL_JIB_OPTIONS]?*lv.lv_obj_t = .{ null, null, null, null, null, null };
var sail_jib_current: usize = 0; // index of currently active jib option

// Code 0 toggle
var code0_btn: ?*lv.lv_obj_t = null;
var code0_active: bool = false;

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
};

var platform_callbacks: PlatformCallbacks = .{};

pub fn setPlatformCallbacks(callbacks: PlatformCallbacks) void {
    platform_callbacks = callbacks;
}

// HA entity IDs — runtime-configurable from the platform layer.
// Defaults match the original hardcoded values. Overridden via
// setEntityId() from the platform (WASM or native) when config arrives.
const MAX_ENTITY_ID_LEN = 128;

const ENTITY_SAIL_MAIN: usize = 0;
const ENTITY_SAIL_JIB: usize = 1;
const ENTITY_CODE0: usize = 2;
const ENTITY_COUNT: usize = 3;

const EntityBuf = struct {
    buf: [MAX_ENTITY_ID_LEN]u8 = undefined,
    len: usize = 0,
};

var entity_ids: [ENTITY_COUNT]EntityBuf = init_entity_ids();

fn init_entity_ids() [ENTITY_COUNT]EntityBuf {
    var ids: [ENTITY_COUNT]EntityBuf = .{EntityBuf{}} ** ENTITY_COUNT;
    const defaults = [ENTITY_COUNT][]const u8{
        "input_select.sail_configuration_main",
        "input_select.sail_configuration_jib",
        "input_boolean.sail_configuration_code_0_set",
    };
    for (0..ENTITY_COUNT) |i| {
        @memcpy(ids[i].buf[0..defaults[i].len], defaults[i]);
        ids[i].len = defaults[i].len;
    }
    return ids;
}

fn getEntitySlice(index: usize) []const u8 {
    if (index >= ENTITY_COUNT) return "";
    return entity_ids[index].buf[0..entity_ids[index].len];
}

/// Set a configurable entity ID at runtime.
///   slot: 0=sail_main, 1=sail_jib, 2=sail_code0
pub fn setEntityId(slot: i32, ptr: [*]const u8, len: i32) void {
    const s: usize = if (slot >= 0 and slot < ENTITY_COUNT) @intCast(slot) else return;
    const l: usize = if (len > 0 and len <= MAX_ENTITY_ID_LEN) @intCast(len) else return;
    @memcpy(entity_ids[s].buf[0..l], ptr[0..l]);
    entity_ids[s].len = l;
}

// ============================================================
// Public API
// ============================================================

pub fn init(w: u32, h: u32) void {
    screen_w = w;
    screen_h = h;
    nav_w = w * NAV_WIDTH_PCT / 100;
    page_w = w - nav_w;
}

pub fn create() void {
    const screen = lv.lv_screen_active();
    if (screen == null) return;

    // Screen background
    lv.lv_obj_set_style_bg_color(screen, lv.lv_color_hex(COL_BG_DARK), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(screen, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(screen, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Create the page content area (left 90%)
    createPages(screen);

    // Create the navigation bar (right 10%)
    createNavBar(screen);

    // Show the first page
    showPage(PAGE_LOGBOOK);
}

pub fn update_anchor_connection_state(state: i32) void {
    setAnchorConnectionUi(state);
}

pub fn update_anchor_loader_rotation(deg10: i32) void {
    if (anchor_data_icon) |icon| {
        lv.lv_image_set_rotation(icon, deg10);
    }
}

// ============================================================
// Navigation bar (right side, 10% width)
// ============================================================

fn createNavBar(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    const bar = lv.lv_obj_create(parent);
    if (bar == null) return;

    lv.lv_obj_set_size(bar, @intCast(nav_w), @intCast(screen_h));
    lv.lv_obj_align(bar, lv.LV_ALIGN_TOP_RIGHT, 0, 0);
    lv.lv_obj_set_style_bg_color(bar, lv.lv_color_hex(COL_NAV_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(bar, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(bar, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(bar, 1, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(bar, lv.lv_color_hex(COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_side(bar, lv.LV_BORDER_SIDE_LEFT, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(bar, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(bar, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Layout: column, evenly spaced
    lv.lv_obj_set_flex_flow(bar, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_flex_align(bar, lv.LV_FLEX_ALIGN_SPACE_EVENLY, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);

    const page_indices = [PAGE_COUNT]usize{ PAGE_LOGBOOK, PAGE_ANCHOR, PAGE_SAILS };

    for (0..PAGE_COUNT) |i| {
        nav_buttons[i] = createNavButton(bar, page_indices[i]);
    }
}

fn navIconForPage(page_index: usize) *const anyopaque {
    return switch (page_index) {
        PAGE_LOGBOOK => &lv.tabler_icon_api_book_N,
        PAGE_ANCHOR => &lv.tabler_icon_anchor_N,
        PAGE_SAILS => &lv.tabler_icon_sailboat_N,
        else => &lv.tabler_icon_api_book_N,
    };
}

fn titleIconForPage(page_index: usize) *const anyopaque {
    return switch (page_index) {
        PAGE_LOGBOOK => &lv.tabler_icon_api_book_P,
        PAGE_ANCHOR => &lv.tabler_icon_anchor_P,
        PAGE_SAILS => &lv.tabler_icon_sailboat_P,
        else => &lv.tabler_icon_api_book_P,
    };
}

fn createNavButton(parent: ?*lv.lv_obj_t, page_index: usize) ?*lv.lv_obj_t {
    if (parent == null) return null;

    const btn = lv.lv_button_create(parent);
    if (btn == null) return null;

    const btn_size: i32 = @intCast(nav_w - 16);
    lv.lv_obj_set_size(btn, btn_size, btn_size);
    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_NAV_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(btn, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(btn, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_shadow_width(btn, 0, lv.LV_PART_MAIN);

    const icon_dsc = navIconForPage(page_index);
    const img = lv.lv_image_create(btn);
    if (img) |image| {
        lv.lv_image_set_src(image, icon_dsc);
        lv.lv_obj_set_style_image_recolor(image, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(image, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_center(image);
    }

    // Store page index as user_data for the click handler
    // We encode the page index as a pointer-sized integer
    const user_data: ?*anyopaque = @ptrFromInt(page_index);
    _ = lv.lv_obj_add_event_cb(btn, navClickCb, lv.LV_EVENT_CLICKED, user_data);

    return btn;
}

fn navClickCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    const user_data = lv.lv_event_get_user_data(e);
    const page_index: usize = @intFromPtr(user_data);
    if (page_index < PAGE_COUNT) {
        showPage(page_index);
    }
}

fn showPage(index: usize) void {
    if (index >= PAGE_COUNT) return;
    current_page = index;

    // Show/hide page containers
    for (0..PAGE_COUNT) |i| {
        if (page_containers[i]) |container| {
            if (i == index) {
                lv.lv_obj_remove_flag(container, lv.LV_OBJ_FLAG_HIDDEN);
            } else {
                lv.lv_obj_add_flag(container, lv.LV_OBJ_FLAG_HIDDEN);
            }
        }
    }

    // Update nav button highlight
    for (0..PAGE_COUNT) |i| {
        if (nav_buttons[i]) |btn| {
            // Get the image child (first child of button)
            const child = lv.c.lv_obj_get_child(btn, 0);
            if (child) |img| {
                if (i == index) {
                    // Active: bright foreground color + accent background
                    lv.lv_obj_set_style_image_recolor(img, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_image_recolor_opa(img, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_ACCENT_1), lv.LV_PART_MAIN);
                } else {
                    // Inactive: dim
                    lv.lv_obj_set_style_image_recolor(img, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_image_recolor_opa(img, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_NAV_BG), lv.LV_PART_MAIN);
                }
            }
        }
    }
}

// ============================================================
// Page containers
// ============================================================

fn createPages(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    for (0..PAGE_COUNT) |i| {
        const container = lv.lv_obj_create(parent);
        if (container == null) continue;

        lv.lv_obj_set_size(container, @intCast(page_w), @intCast(screen_h));
        lv.lv_obj_align(container, lv.LV_ALIGN_TOP_LEFT, 0, 0);
        lv.lv_obj_set_style_bg_opa(container, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_border_width(container, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_radius(container, 0, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_pad_all(container, if (i == PAGE_ANCHOR) 0 else 20, lv.LV_PART_MAIN);
        lv.lv_obj_remove_flag(container, lv.LV_OBJ_FLAG_SCROLLABLE);

        // Start hidden (showPage will reveal the active one)
        lv.lv_obj_add_flag(container, lv.LV_OBJ_FLAG_HIDDEN);

        page_containers[i] = container;

        // Populate page content
        switch (i) {
            PAGE_LOGBOOK => createLogbookPage(container),
            PAGE_ANCHOR => createAnchorPage(container),
            PAGE_SAILS => createSailsPage(container),
            else => {},
        }
    }
}

// ============================================================
// Page title helper
// ============================================================

fn createPageTitle(parent: ?*lv.lv_obj_t, text: [*:0]const u8, page_index: usize) void {
    if (parent == null) return;

    // Row container: icon on left, title label on right
    const row = lv.lv_obj_create(parent);
    if (row == null) return;

    lv.lv_obj_set_size(row, lv.LV_SIZE_CONTENT, lv.LV_SIZE_CONTENT);
    lv.lv_obj_align(row, lv.LV_ALIGN_TOP_LEFT, 0, 0);
    lv.lv_obj_set_style_bg_opa(row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_column(row, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(row, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(row, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(row, lv.LV_OBJ_FLAG_SCROLLABLE);

    const icon_dsc = titleIconForPage(page_index);
    const img = lv.lv_image_create(row);
    if (img) |im| {
        lv.lv_image_set_src(im, icon_dsc);
        lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(im, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    }

    const lbl = lv.lv_label_create(row);
    if (lbl) |l| {
        lv.lv_label_set_text(l, text);
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_28, lv.LV_PART_MAIN);
    }
}

// ============================================================
// Sensor card helper
// ============================================================

/// Creates a sensor card with a small label (title) and a large value label.
/// Returns the value label pointer so it can be updated later.
fn createSensorCard(
    parent: ?*lv.lv_obj_t,
    card_w: i32,
    card_h: i32,
    title: [*:0]const u8,
    initial_value: [*:0]const u8,
) ?*lv.lv_obj_t {
    if (parent == null) return null;

    const card = lv.lv_obj_create(parent);
    if (card == null) return null;

    lv.lv_obj_set_size(card, card_w, card_h);
    lv.lv_obj_set_style_bg_color(card, lv.lv_color_hex(COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(card, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(card, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(card, 1, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(card, lv.lv_color_hex(COL_CARD_BORDER), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(card, 16, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(card, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Column layout
    lv.lv_obj_set_flex_flow(card, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_row(card, 4, lv.LV_PART_MAIN);

    // Title label (small, dimmed)
    const title_lbl = lv.lv_label_create(card);
    if (title_lbl) |tl| {
        lv.lv_label_set_text(tl, title);
        lv.lv_obj_set_style_text_color(tl, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(tl, lv.lv_font_montserrat_14, lv.LV_PART_MAIN);
    }

    // Value label (large, bright)
    const value_lbl = lv.lv_label_create(card);
    if (value_lbl) |vl| {
        lv.lv_label_set_text(vl, initial_value);
        lv.lv_obj_set_style_text_color(vl, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(vl, lv.lv_font_montserrat_24, lv.LV_PART_MAIN);
        return vl;
    }

    return null;
}

const GpsCardLabels = struct {
    latitude: ?*lv.lv_obj_t,
    longitude: ?*lv.lv_obj_t,
};

fn createGpsCard(parent: ?*lv.lv_obj_t, card_w: i32, card_h: i32, title: [*:0]const u8) GpsCardLabels {
    if (parent == null) return .{ .latitude = null, .longitude = null };

    const card = lv.lv_obj_create(parent);
    if (card == null) return .{ .latitude = null, .longitude = null };

    lv.lv_obj_set_size(card, card_w, card_h);
    lv.lv_obj_set_style_bg_color(card, lv.lv_color_hex(COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(card, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(card, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(card, 1, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(card, lv.lv_color_hex(COL_CARD_BORDER), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(card, 14, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(card, lv.LV_OBJ_FLAG_SCROLLABLE);
    lv.lv_obj_set_flex_flow(card, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_row(card, 6, lv.LV_PART_MAIN);

    const title_lbl = lv.lv_label_create(card);
    if (title_lbl) |tl| {
        lv.lv_label_set_text(tl, title);
        lv.lv_obj_set_style_text_color(tl, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
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

        const lat_key = lv.lv_label_create(row);
        if (lat_key) |lk| {
            lv.lv_label_set_text(lk, "Lat");
            lv.lv_obj_set_width(lk, 34);
            lv.lv_obj_set_style_text_color(lk, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lk, lv.lv_font_montserrat_14, lv.LV_PART_MAIN);
        }

        const lat_val = lv.lv_label_create(row);
        if (lat_val) |lvv| {
            lv.lv_label_set_text(lvv, "--");
            lv.lv_obj_set_style_text_color(lvv, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
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

        const lon_key = lv.lv_label_create(row);
        if (lon_key) |lk| {
            lv.lv_label_set_text(lk, "Lon");
            lv.lv_obj_set_width(lk, 34);
            lv.lv_obj_set_style_text_color(lk, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lk, lv.lv_font_montserrat_14, lv.LV_PART_MAIN);
        }

        const lon_val = lv.lv_label_create(row);
        if (lon_val) |lvv| {
            lv.lv_label_set_text(lvv, "--");
            lv.lv_obj_set_style_text_color(lvv, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lvv, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
            out.longitude = lvv;
        }
    }

    return out;
}

// ============================================================
// Page 0: Logbook
// ============================================================

fn createLogbookPage(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    createPageTitle(parent, "Logbook", PAGE_LOGBOOK);

    lbl_logbook_datetime = lv.lv_label_create(parent);
    if (lbl_logbook_datetime) |dt| {
        lv.lv_label_set_text(dt, "--:-- --.--.---- (UTC+0)");
        lv.lv_obj_set_style_text_color(dt, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(dt, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(dt, lv.LV_ALIGN_TOP_RIGHT, -2, 4);
    }

    // Content area below title
    const content = lv.lv_obj_create(parent);
    if (content == null) return;

    const content_w = page_w - 40; // account for page padding
    const content_w_i32: i32 = @intCast(content_w);
    lv.lv_obj_set_size(content, content_w_i32, @intCast(screen_h - 90));
    lv.lv_obj_align(content, lv.LV_ALIGN_TOP_LEFT, 0, PAGE_TITLE_H);
    lv.lv_obj_set_style_bg_opa(content, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(content, lv.LV_OBJ_FLAG_SCROLLABLE);

    // --- Row 1: Vessel section ---
    const section_label_1 = lv.lv_label_create(content);
    if (section_label_1) |sl| {
        lv.lv_label_set_text(sl, "Vessel");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 0);
    }

    const vessel_gap: i32 = 10;
    const vessel_cols: i32 = 6;
    const vessel_card_w: i32 = @divTrunc(content_w_i32 - vessel_gap * (vessel_cols - 1), vessel_cols);
    const card_h: i32 = 110;
    const row1 = createCardRow(content, 30, 120, vessel_gap);

    const gps = createGpsCard(row1, vessel_card_w, card_h, "GPS Position");
    lbl_latitude = gps.latitude;
    lbl_longitude = gps.longitude;
    lbl_vessel_log = createSensorCard(row1, vessel_card_w, card_h, "Log", "--");
    lbl_vessel_hdg = createSensorCard(row1, vessel_card_w, card_h, "HDG", "--");
    lbl_vessel_stw = createSensorCard(row1, vessel_card_w, card_h, "STW", "--");
    lbl_vessel_sog = createSensorCard(row1, vessel_card_w, card_h, "SOG", "--");
    lbl_vessel_cog = createSensorCard(row1, vessel_card_w, card_h, "COG", "--");

    // --- Row 2: Environment section ---
    const section_label_2 = lv.lv_label_create(content);
    if (section_label_2) |sl| {
        lv.lv_label_set_text(sl, "Environment");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 160);
    }

    const env_gap: i32 = 12;
    const env_cols: i32 = 5;
    const env_card_w: i32 = @divTrunc(content_w_i32 - env_gap * (env_cols - 1), env_cols);
    const row2 = createCardRow(content, 190, 120, env_gap);

    lbl_env_aws = createSensorCard(row2, env_card_w, card_h, "AWS", "--");
    lbl_env_awa = createSensorCard(row2, env_card_w, card_h, "AWA", "--");
    lbl_env_tws = createSensorCard(row2, env_card_w, card_h, "TWS", "--");
    lbl_env_twd = createSensorCard(row2, env_card_w, card_h, "TWD", "--");
    lbl_env_baro = createSensorCard(row2, env_card_w, card_h, "Baro", "--");

    // --- Row 3: Last 24h section ---
    const section_label_3 = lv.lv_label_create(content);
    if (section_label_3) |sl| {
        lv.lv_label_set_text(sl, "Last 24h");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 320);
    }

    const row3 = createCardRow(content, 350, 120, 15);
    const card_w_24h: i32 = @divTrunc(content_w_i32 - 15, 2);

    lbl_distance_24h = createSensorCard(row3, card_w_24h, card_h, "Distance", "--");
    lbl_speed_24h = createSensorCard(row3, card_w_24h, card_h, "Avg Speed", "--");
}

fn createCardRow(parent: ?*lv.lv_obj_t, y_offset: i32, row_h: i32, gap: i32) ?*lv.lv_obj_t {
    if (parent == null) return null;

    const row = lv.lv_obj_create(parent);
    if (row == null) return null;

    const content_w = page_w - 40;
    lv.lv_obj_set_size(row, @intCast(content_w), row_h);
    lv.lv_obj_align(row, lv.LV_ALIGN_TOP_LEFT, 0, y_offset);
    lv.lv_obj_set_style_bg_opa(row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_column(row, gap, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(row, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(row, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_START);
    lv.lv_obj_remove_flag(row, lv.LV_OBJ_FLAG_SCROLLABLE);

    return row;
}

// ============================================================
// Page 1: Anchor Alarm
// ============================================================

fn createAnchorPage(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    createPageTitle(parent, "Anchor Alarm", PAGE_ANCHOR);

    const data_icon = lv.lv_image_create(parent);
    if (data_icon) |im| {
        anchor_data_icon = im;
        lv.lv_image_set_src(im, &lv.tabler_icon_loader_2_P);
        lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(im, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_align(im, lv.LV_ALIGN_TOP_RIGHT, -2, 4);
        lv.lv_obj_add_flag(im, lv.LV_OBJ_FLAG_HIDDEN);
    }

    const compass_icon = lv.lv_image_create(parent);
    if (compass_icon) |im| {
        lv.lv_image_set_src(im, &lv.tabler_icon_assets_compass_north_svgrepo_com_svg_N);
        lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(im, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_align(im, lv.LV_ALIGN_TOP_LEFT, 0, PAGE_TITLE_H + 8);
    }

    const root = lv.lv_obj_create(parent);
    if (root == null) return;
    anchor_root = root;

    const root_h: i32 = @intCast(screen_h - PAGE_TITLE_H);
    lv.lv_obj_set_size(root, @intCast(page_w), root_h);
    lv.lv_obj_align(root, lv.LV_ALIGN_TOP_LEFT, 0, PAGE_TITLE_H);
    lv.lv_obj_set_style_bg_color(root, lv.lv_color_hex(COL_BG_DARK), lv.LV_PART_MAIN);
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

    // Anchor icon in map center (minus navbar by page layout).
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
        lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
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
            lv.lv_obj_set_style_image_recolor(im, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
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
        lv.lv_obj_set_style_bg_color(cs, lv.lv_color_hex(COL_BG_DARK), lv.LV_PART_MAIN);
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
            lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lbl, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        }

        anchor_connection_status = lv.lv_label_create(cs);
        if (anchor_connection_status) |lbl| {
            lv.lv_label_set_text(lbl, "Detecting SignalK...");
            lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_TEXT), lv.LV_PART_MAIN);
            lv.lv_obj_set_style_text_font(lbl, lv.lv_font_montserrat_24, lv.LV_PART_MAIN);
        }
    }

    anchor_info = null;
    setAnchorConnectionUi(ANCHOR_CONN_ESTABLISH);
}

const ANCHOR_BTN_RADIUS_DEC: usize = 1;
const ANCHOR_BTN_TOGGLE: usize = 2;
const ANCHOR_BTN_RADIUS_INC: usize = 3;
const ANCHOR_BTN_ZOOM_DEC: usize = 4;
const ANCHOR_BTN_ZOOM_INC: usize = 5;

fn createAnchorControls(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    const bar = lv.lv_obj_create(parent);
    if (bar == null) return;
    anchor_controls_bar = bar;

    lv.lv_obj_set_size(bar, lv.LV_PCT(100), 120);
    lv.lv_obj_align(bar, lv.LV_ALIGN_BOTTOM_MID, 0, 0);
    lv.lv_obj_set_style_bg_color(bar, lv.lv_color_hex(COL_BG_DARK), lv.LV_PART_MAIN);
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
    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(btn, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_shadow_width(btn, 0, lv.LV_PART_MAIN);

    const lbl = lv.lv_label_create(btn);
    var out: ?*lv.lv_obj_t = null;
    if (lbl) |l| {
        lv.lv_label_set_text(l, text);
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
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
    const cb = platform_callbacks.anchor_action orelse return;
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

fn setAnchorConnectionUi(state: i32) void {
    if (anchor_data_icon) |icon| {
        if (state == ANCHOR_CONN_STREAMING) {
            lv.lv_image_set_src(icon, &lv.tabler_icon_loader_2_P);
            lv.lv_obj_set_style_image_recolor(icon, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
            lv.lv_obj_remove_flag(icon, lv.LV_OBJ_FLAG_HIDDEN);
        } else if (state == ANCHOR_CONN_STALE) {
            lv.lv_image_set_src(icon, &lv.tabler_icon_alert_square_rounded_P);
            lv.lv_obj_set_style_image_recolor(icon, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
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

// ============================================================
// Page 2: Sails
// ============================================================

fn createSailsPage(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    createPageTitle(parent, "Sail Configuration", PAGE_SAILS);

    // Content area below title
    const content = lv.lv_obj_create(parent);
    if (content == null) return;

    const content_w = page_w - 40;
    lv.lv_obj_set_size(content, @intCast(content_w), @intCast(screen_h - 90));
    lv.lv_obj_align(content, lv.LV_ALIGN_TOP_LEFT, 0, PAGE_TITLE_H);
    lv.lv_obj_set_style_bg_opa(content, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(content, lv.LV_OBJ_FLAG_SCROLLABLE);

    // --- Main Sail row ---
    const sail_label = lv.lv_label_create(content);
    if (sail_label) |sl| {
        lv.lv_label_set_text(sl, "Main Sail");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 0);
    }

    const main_btn_row = lv.lv_obj_create(content);
    if (main_btn_row == null) return;

    lv.lv_obj_set_size(main_btn_row, @intCast(content_w), 80);
    lv.lv_obj_align(main_btn_row, lv.LV_ALIGN_TOP_LEFT, 0, 30);
    lv.lv_obj_set_style_bg_opa(main_btn_row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(main_btn_row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(main_btn_row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_column(main_btn_row, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(main_btn_row, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(main_btn_row, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(main_btn_row, lv.LV_OBJ_FLAG_SCROLLABLE);

    for (0..SAIL_MAIN_OPTIONS) |i| {
        sail_main_btns[i] = createSailButton(main_btn_row, sail_main_labels[i], i, sailMainClickCb);
    }

    // Highlight the default (first option)
    updateSailMainHighlight(0);

    // --- Jib row ---
    const jib_y: i32 = 130;
    const jib_label = lv.lv_label_create(content);
    if (jib_label) |jl| {
        lv.lv_label_set_text(jl, "Jib");
        lv.lv_obj_set_style_text_color(jl, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(jl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(jl, lv.LV_ALIGN_TOP_LEFT, 0, jib_y);
    }

    const jib_btn_row = lv.lv_obj_create(content);
    if (jib_btn_row == null) return;

    lv.lv_obj_set_size(jib_btn_row, @intCast(content_w), 80);
    lv.lv_obj_align(jib_btn_row, lv.LV_ALIGN_TOP_LEFT, 0, jib_y + 30);
    lv.lv_obj_set_style_bg_opa(jib_btn_row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(jib_btn_row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(jib_btn_row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_column(jib_btn_row, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(jib_btn_row, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(jib_btn_row, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(jib_btn_row, lv.LV_OBJ_FLAG_SCROLLABLE);

    for (0..SAIL_JIB_OPTIONS) |i| {
        sail_jib_btns[i] = createSailButton(jib_btn_row, sail_jib_labels[i], i, sailJibClickCb);
    }

    // Highlight the default (first option)
    updateSailJibHighlight(0);

    // --- Code 0 toggle ---
    const code0_y: i32 = 260;
    const code0_label = lv.lv_label_create(content);
    if (code0_label) |cl| {
        lv.lv_label_set_text(cl, "Code 0");
        lv.lv_obj_set_style_text_color(cl, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(cl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(cl, lv.LV_ALIGN_TOP_LEFT, 0, code0_y);
    }

    const code0_row = lv.lv_obj_create(content);
    if (code0_row == null) return;

    lv.lv_obj_set_size(code0_row, @intCast(content_w), 80);
    lv.lv_obj_align(code0_row, lv.LV_ALIGN_TOP_LEFT, 0, code0_y + 30);
    lv.lv_obj_set_style_bg_opa(code0_row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(code0_row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(code0_row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(code0_row, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(code0_row, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_remove_flag(code0_row, lv.LV_OBJ_FLAG_SCROLLABLE);

    code0_btn = createToggleButton(code0_row, false);
}

fn createSailButton(parent: ?*lv.lv_obj_t, text: [*:0]const u8, option_index: usize, cb: lv.c.lv_event_cb_t) ?*lv.lv_obj_t {
    if (parent == null) return null;

    const btn = lv.lv_button_create(parent);
    if (btn == null) return null;

    lv.lv_obj_set_size(btn, 180, 60);
    lv.lv_obj_set_style_radius(btn, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(btn, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_shadow_width(btn, 0, lv.LV_PART_MAIN);

    // Default: inactive style
    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);

    const lbl = lv.lv_label_create(btn);
    if (lbl) |l| {
        lv.lv_label_set_text(l, text);
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        lv.lv_obj_center(l);
    }

    const user_data: ?*anyopaque = @ptrFromInt(option_index);
    _ = lv.lv_obj_add_event_cb(btn, cb, lv.LV_EVENT_CLICKED, user_data);

    return btn;
}

fn sailMainClickCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    const user_data = lv.lv_event_get_user_data(e);
    const option_index: usize = @intFromPtr(user_data);
    if (option_index < SAIL_MAIN_OPTIONS) {
        updateSailMainHighlight(option_index);
        if (platform_callbacks.sail_config_changed) |cb| {
            const opt = sail_main_labels[option_index];
            const entity = getEntitySlice(ENTITY_SAIL_MAIN);
            cb(
                entity.ptr,
                @intCast(entity.len),
                opt,
                @intCast(std.mem.len(opt)),
            );
        }
    }
}

fn sailJibClickCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    const user_data = lv.lv_event_get_user_data(e);
    const option_index: usize = @intFromPtr(user_data);
    if (option_index < SAIL_JIB_OPTIONS) {
        updateSailJibHighlight(option_index);
        if (platform_callbacks.sail_config_changed) |cb| {
            const opt = sail_jib_labels[option_index];
            const entity = getEntitySlice(ENTITY_SAIL_JIB);
            cb(
                entity.ptr,
                @intCast(entity.len),
                opt,
                @intCast(std.mem.len(opt)),
            );
        }
    }
}

fn code0ClickCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    code0_active = !code0_active;
    updateCode0Style();
    if (platform_callbacks.sail_toggle_changed) |cb| {
        const entity = getEntitySlice(ENTITY_CODE0);
        cb(
            entity.ptr,
            @intCast(entity.len),
            if (code0_active) @as(i32, 1) else @as(i32, 0),
        );
    }
}

fn updateSailMainHighlight(active_index: usize) void {
    sail_main_current = active_index;
    updateSailButtonRow(&sail_main_btns, SAIL_MAIN_OPTIONS, active_index);
}

fn updateSailJibHighlight(active_index: usize) void {
    sail_jib_current = active_index;
    updateSailButtonRow(&sail_jib_btns, SAIL_JIB_OPTIONS, active_index);
}

/// Generic helper to highlight one button in a row of sail option buttons.
fn updateSailButtonRow(btns: anytype, count: usize, active_index: usize) void {
    for (0..count) |i| {
        if (btns[i]) |btn| {
            const child = lv.c.lv_obj_get_child(btn, 0);
            if (child) |lbl| {
                if (i == active_index) {
                    // Active: bright FG text + accent bg + bright border
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_BG_DARK), lv.LV_PART_MAIN);
                } else {
                    // Inactive: dark bg + dim border + dim text
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_CARD_BG), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(COL_ACCENT_1), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
                }
            }
        }
    }
}

/// Create a large toggle button for Code 0 (on/off).
fn createToggleButton(parent: ?*lv.lv_obj_t, initial_state: bool) ?*lv.lv_obj_t {
    if (parent == null) return null;

    const btn = lv.lv_button_create(parent);
    if (btn == null) return null;

    lv.lv_obj_set_size(btn, 180, 60);
    lv.lv_obj_set_style_radius(btn, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(btn, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_shadow_width(btn, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);

    const lbl = lv.lv_label_create(btn);
    if (lbl) |l| {
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        lv.lv_obj_center(l);
    }

    code0_active = initial_state;
    _ = lv.lv_obj_add_event_cb(btn, code0ClickCb, lv.LV_EVENT_CLICKED, null);

    // Apply initial style (will set label text + colors)
    code0_btn = btn;
    updateCode0Style();

    return btn;
}

/// Update Code 0 button style based on current state.
fn updateCode0Style() void {
    if (code0_btn) |btn| {
        const child = lv.c.lv_obj_get_child(btn, 0);
        if (child) |lbl| {
            if (code0_active) {
                lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_BG_DARK), lv.LV_PART_MAIN);
                lv.lv_label_set_text(lbl, "SET");
            } else {
                lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_CARD_BG), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(COL_ACCENT_1), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
                lv.lv_label_set_text(lbl, "NOT SET");
            }
        }
    }
}

// ============================================================
// State update functions
// (called from platform layer when HA state changes arrive)
// ============================================================

/// Update a sensor value label by sensor ID.
/// sensor_id mapping:
///   0  = latitude
///   1  = longitude
///   2  = vessel log
///   3  = heading true
///   4  = stw
///   5  = sog
///   6  = cog
///   7  = aws
///   8  = awa
///   9  = tws (15m)
///   10 = twd (15m)
///   11 = barometric pressure
///   12 = 24h distance
///   13 = 24h average speed
///   14 = formatted date/time header
pub fn update_sensor(sensor_id: i32, value_ptr: [*]const u8, value_len: i32) void {
    const value: [*:0]const u8 = @ptrCast(value_ptr);
    _ = value_len; // text is null-terminated via the Zig/LVGL label API

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

/// Update the main sail selection from HA state.
/// Called with the raw HA state string (e.g. "Reef 1", "100%").
pub fn update_sail_main(value_ptr: [*]const u8, value_len: i32) void {
    const value = value_ptr[0..@intCast(value_len)];
    for (0..SAIL_MAIN_OPTIONS) |i| {
        const label = sail_main_labels[i];
        const label_slice = label[0..std.mem.len(label)];
        if (std.mem.eql(u8, value, label_slice)) {
            updateSailMainHighlight(i);
            return;
        }
    }
}

/// Update the jib selection from HA state.
/// Called with the raw HA state string (e.g. "75%", "100%").
pub fn update_sail_jib(value_ptr: [*]const u8, value_len: i32) void {
    const value = value_ptr[0..@intCast(value_len)];
    for (0..SAIL_JIB_OPTIONS) |i| {
        const label = sail_jib_labels[i];
        const label_slice = label[0..std.mem.len(label)];
        if (std.mem.eql(u8, value, label_slice)) {
            updateSailJibHighlight(i);
            return;
        }
    }
}

/// Update the Code 0 toggle from HA state.
/// Called with the raw HA state string ("on" or "off").
pub fn update_code0(value_ptr: [*]const u8, value_len: i32) void {
    const value = value_ptr[0..@intCast(value_len)];
    code0_active = std.mem.eql(u8, value, "on");
    updateCode0Style();
}

pub fn update_anchor_status(value_ptr: [*]const u8, value_len: i32) void {
    _ = value_len;
    if (anchor_connection_status) |lbl| {
        lv.lv_label_set_text(lbl, @ptrCast(value_ptr));
    }
}

pub fn update_anchor_info(value_ptr: [*]const u8, value_len: i32) void {
    _ = value_len;
    if (anchor_info) |lbl| {
        lv.lv_label_set_text(lbl, @ptrCast(value_ptr));
    }
}

pub fn update_anchor_mode(is_set: i32) void {
    anchor_is_set = is_set != 0;
    if (anchor_action_btn_label) |lbl| {
        lv.lv_label_set_text(lbl, if (anchor_is_set) "Raise Anchor" else "Drop Anchor");
    }

    if (anchor_ring) |ring| {
        const color: u32 = if (anchor_is_set) 0x2A9D8F else 0x3A86FF;
        lv.lv_obj_set_style_border_color(ring, lv.lv_color_hex(color), lv.LV_PART_MAIN);
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

pub fn update_anchor_ring_px(diameter_px: i32) void {
    anchor_ring_diameter_px = std.math.clamp(diameter_px, 40, 1200);
    updateAnchorRingGeometry();
}

pub fn update_anchor_anchor_px(x: i32, y: i32) void {
    anchor_center_x_px = x;
    anchor_center_y_px = y;
    if (anchor_icon) |anchor| {
        lv.lv_obj_set_pos(anchor, x - 12, y - 12);
    }
    updateAnchorRingGeometry();
}

pub fn update_anchor_boat_px(x: i32, y: i32, heading_deg10: i32) void {
    if (anchor_boat) |boat| {
        lv.lv_obj_set_pos(boat, x - 12, y - 12);
        lv.lv_image_set_rotation(boat, heading_deg10);
    }
}

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

pub fn update_anchor_line_point(index: i32, x: i32, y: i32, visible: i32) void {
    if (index < 0 or index >= ANCHOR_LINE_POINTS) return;
    updatePoint(anchor_line_dots[@intCast(index)], x, y, visible != 0);
}

pub fn update_anchor_track_point(index: i32, x: i32, y: i32, visible: i32) void {
    if (index < 0 or index >= ANCHOR_TRACK_POINTS) return;
    updatePoint(anchor_track_dots[@intCast(index)], x, y, visible != 0);
}

pub fn update_anchor_other_boat(index: i32, x: i32, y: i32, visible: i32, heading_deg10: i32) void {
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

pub fn update_anchor_other_track_point(vessel_index: i32, point_index: i32, x: i32, y: i32, visible: i32) void {
    if (vessel_index < 0 or vessel_index >= ANCHOR_MAX_OTHER) return;
    if (point_index < 0 or point_index >= ANCHOR_OTHER_TRACK_POINTS) return;
    updatePoint(anchor_other_tracks[@intCast(vessel_index)][@intCast(point_index)], x, y, visible != 0);
}
