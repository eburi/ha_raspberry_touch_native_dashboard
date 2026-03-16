///! Multi-page LVGL dashboard with right-side icon navigation.
///!
///! Layout (1280x720):
///!   [   Page Content (90%)   ][ Nav Bar (10%) ]
///!
///! Pages:
///!   0 — Logbook:      Position + 24h log sensor cards
///!   1 — Anchor Alarm: (placeholder)
///!   2 — Sails:        Main sail, jib & code 0 configuration
///!
///! Color palette (dark nautical theme):
///!   BG_DARK    #220901  — screen / deepest background
///!   BG_MID     #621708  — card backgrounds
///!   ACCENT_1   #941B0C  — borders, inactive elements
///!   ACCENT_2   #BC3908  — active nav icon, highlights
///!   FOREGROUND #F6AA1C  — text, values, active buttons

const std = @import("std");
const lv = @import("lv.zig");

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

// --- Logbook page sensor labels (updated via WASM export) ---
var lbl_latitude: ?*lv.lv_obj_t = null;
var lbl_longitude: ?*lv.lv_obj_t = null;
var lbl_distance_24h: ?*lv.lv_obj_t = null;
var lbl_speed_24h: ?*lv.lv_obj_t = null;

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

// JS callbacks for sail config changes
// js_sail_config_changed: passes entity_id string ptr/len + option value string ptr/len
extern fn js_sail_config_changed(entity_ptr: [*]const u8, entity_len: i32, option_ptr: [*]const u8, option_len: i32) void;
extern fn js_sail_toggle_changed(entity_ptr: [*]const u8, entity_len: i32, state: i32) void;

// HA entity IDs (null-terminated for convenience, length excludes sentinel)
const HA_ENTITY_SAIL_MAIN = "input_select.sail_configuration_main";
const HA_ENTITY_SAIL_JIB = "input_select.sail_configuration_jib";
const HA_ENTITY_CODE0 = "input_boolean.sail_configuration_code_0_set";

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

    // Nav buttons with FontAwesome 6 icons
    // FA_BOOK      = book icon        (Logbook)
    // FA_ANCHOR    = anchor icon      (Anchor Alarm)
    // FA_SAILBOAT  = sailboat icon    (Sails)
    const icons = [PAGE_COUNT][*:0]const u8{
        lv.FA_BOOK,
        lv.FA_ANCHOR,
        lv.FA_SAILBOAT,
    };
    const page_indices = [PAGE_COUNT]usize{ PAGE_LOGBOOK, PAGE_ANCHOR, PAGE_SAILS };

    for (0..PAGE_COUNT) |i| {
        nav_buttons[i] = createNavButton(bar, icons[i], page_indices[i]);
    }
}

fn createNavButton(parent: ?*lv.lv_obj_t, icon: [*:0]const u8, page_index: usize) ?*lv.lv_obj_t {
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

    // Icon label (using FontAwesome 6 icon font)
    const label = lv.lv_label_create(btn);
    if (label) |lbl| {
        lv.lv_label_set_text(lbl, icon);
        lv.lv_obj_set_style_text_font(lbl, lv.fa_icons_28, lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_center(lbl);
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
            // Get the label child (first child of button)
            const child = lv.c.lv_obj_get_child(btn, 0);
            if (child) |lbl| {
                if (i == index) {
                    // Active: bright foreground color + accent background
                    lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(COL_ACCENT_1), lv.LV_PART_MAIN);
                } else {
                    // Inactive: dim
                    lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
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
        lv.lv_obj_set_style_pad_all(container, 20, lv.LV_PART_MAIN);
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

fn createPageTitle(parent: ?*lv.lv_obj_t, text: [*:0]const u8) void {
    if (parent == null) return;
    const lbl = lv.lv_label_create(parent);
    if (lbl) |l| {
        lv.lv_label_set_text(l, text);
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(COL_FG), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(l, lv.lv_font_montserrat_28, lv.LV_PART_MAIN);
        lv.lv_obj_align(l, lv.LV_ALIGN_TOP_LEFT, 0, 0);
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

// ============================================================
// Page 0: Logbook
// ============================================================

fn createLogbookPage(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    createPageTitle(parent, "Logbook");

    // Content area below title
    const content = lv.lv_obj_create(parent);
    if (content == null) return;

    const content_w = page_w - 40; // account for page padding
    lv.lv_obj_set_size(content, @intCast(content_w), @intCast(screen_h - 90));
    lv.lv_obj_align(content, lv.LV_ALIGN_TOP_LEFT, 0, PAGE_TITLE_H);
    lv.lv_obj_set_style_bg_opa(content, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(content, lv.LV_OBJ_FLAG_SCROLLABLE);

    // --- Row 1: Position section ---
    const section_label_1 = lv.lv_label_create(content);
    if (section_label_1) |sl| {
        lv.lv_label_set_text(sl, "Position");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 0);
    }

    const row1 = createCardRow(content, 30);
    const card_w: i32 = @intCast((content_w - 30) / 2); // two cards per row with gap
    const card_h: i32 = 110;

    lbl_latitude = createSensorCard(row1, card_w, card_h, "Latitude", "--");
    lbl_longitude = createSensorCard(row1, card_w, card_h, "Longitude", "--");

    // --- Row 2: Last 24h section ---
    const section_label_2 = lv.lv_label_create(content);
    if (section_label_2) |sl| {
        lv.lv_label_set_text(sl, "Last 24h");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(COL_ACCENT_2), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_16, lv.LV_PART_MAIN);
        lv.lv_obj_align(sl, lv.LV_ALIGN_TOP_LEFT, 0, 160);
    }

    const row2 = createCardRow(content, 190);

    lbl_distance_24h = createSensorCard(row2, card_w, card_h, "Distance", "--");
    lbl_speed_24h = createSensorCard(row2, card_w, card_h, "Avg Speed", "--");
}

fn createCardRow(parent: ?*lv.lv_obj_t, y_offset: i32) ?*lv.lv_obj_t {
    if (parent == null) return null;

    const row = lv.lv_obj_create(parent);
    if (row == null) return null;

    const content_w = page_w - 40;
    lv.lv_obj_set_size(row, @intCast(content_w), 120);
    lv.lv_obj_align(row, lv.LV_ALIGN_TOP_LEFT, 0, y_offset);
    lv.lv_obj_set_style_bg_opa(row, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(row, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_column(row, 15, lv.LV_PART_MAIN);
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

    createPageTitle(parent, "Anchor Alarm");

    // Placeholder content
    const placeholder = lv.lv_label_create(parent);
    if (placeholder) |p| {
        lv.lv_label_set_text(p, "Anchor watch configuration\ncoming soon...");
        lv.lv_obj_set_style_text_color(p, lv.lv_color_hex(COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(p, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        lv.lv_obj_align(p, lv.LV_ALIGN_CENTER, 0, 0);
    }
}

// ============================================================
// Page 2: Sails
// ============================================================

fn createSailsPage(parent: ?*lv.lv_obj_t) void {
    if (parent == null) return;

    createPageTitle(parent, "Sail Configuration");

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
        const opt = sail_main_labels[option_index];
        js_sail_config_changed(
            HA_ENTITY_SAIL_MAIN.ptr,
            HA_ENTITY_SAIL_MAIN.len,
            opt,
            @intCast(std.mem.len(opt)),
        );
    }
}

fn sailJibClickCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    const user_data = lv.lv_event_get_user_data(e);
    const option_index: usize = @intFromPtr(user_data);
    if (option_index < SAIL_JIB_OPTIONS) {
        updateSailJibHighlight(option_index);
        const opt = sail_jib_labels[option_index];
        js_sail_config_changed(
            HA_ENTITY_SAIL_JIB.ptr,
            HA_ENTITY_SAIL_JIB.len,
            opt,
            @intCast(std.mem.len(opt)),
        );
    }
}

fn code0ClickCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    code0_active = !code0_active;
    updateCode0Style();
    js_sail_toggle_changed(
        HA_ENTITY_CODE0.ptr,
        HA_ENTITY_CODE0.len,
        if (code0_active) @as(i32, 1) else @as(i32, 0),
    );
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
// WASM-exported state update functions
// (called from JS when HA state changes arrive via WebSocket)
// ============================================================

/// Update a sensor value label by sensor ID.
/// sensor_id mapping:
///   0 = latitude
///   1 = longitude
///   2 = distance_24h
///   3 = speed_24h
export fn update_sensor(sensor_id: i32, value_ptr: [*]const u8, value_len: i32) void {
    const value: [*:0]const u8 = @ptrCast(value_ptr);
    _ = value_len; // text is null-terminated via the Zig/LVGL label API

    const label: ?*lv.lv_obj_t = switch (sensor_id) {
        0 => lbl_latitude,
        1 => lbl_longitude,
        2 => lbl_distance_24h,
        3 => lbl_speed_24h,
        else => null,
    };

    if (label) |lbl| {
        lv.lv_label_set_text(lbl, value);
    }
}

/// Update the main sail selection from HA state.
/// Called from JS with the raw HA state string (e.g. "Reef 1", "100%").
export fn update_sail_main(value_ptr: [*]const u8, value_len: i32) void {
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
/// Called from JS with the raw HA state string (e.g. "75%", "100%").
export fn update_sail_jib(value_ptr: [*]const u8, value_len: i32) void {
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
/// Called from JS with the raw HA state string ("on" or "off").
export fn update_code0(value_ptr: [*]const u8, value_len: i32) void {
    const value = value_ptr[0..@intCast(value_len)];
    code0_active = std.mem.eql(u8, value, "on");
    updateCode0Style();
}
