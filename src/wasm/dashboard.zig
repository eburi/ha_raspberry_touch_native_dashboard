///! Placeholder dashboard UI.
///! Creates a simple Home Assistant-style dashboard with:
///! - Header with title
///! - Grid of cards showing entity states
///! This will be replaced with a pluggable module system later.

const lv = @import("lv.zig");

/// Screen dimensions (set during init)
var screen_w: u32 = 1280;
var screen_h: u32 = 720;

pub fn init(w: u32, h: u32) void {
    screen_w = w;
    screen_h = h;
}

pub fn create() void {
    const screen = lv.lv_screen_active();
    if (screen == null) return;

    // Dark background for the screen
    lv.lv_obj_set_style_bg_color(screen, lv.lv_color_hex(0x1a1a2e), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(screen, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(screen, lv.LV_OBJ_FLAG_SCROLLABLE);

    // --- Header bar ---
    const header = lv.lv_obj_create(screen);
    if (header == null) return;

    lv.lv_obj_set_size(header, @intCast(screen_w), 56);
    lv.lv_obj_align(header, lv.LV_ALIGN_TOP_LEFT, 0, 0);
    lv.lv_obj_set_style_bg_color(header, lv.lv_color_hex(0x16213e), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(header, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(header, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(header, lv.LV_OBJ_FLAG_SCROLLABLE);

    const title = lv.lv_label_create(header);
    if (title) |t| {
        lv.lv_label_set_text(t, "LVGL Dashboard");
        lv.lv_obj_set_style_text_color(t, lv.lv_color_hex(0xe0e0e0), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(t, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
        lv.lv_obj_align(t, lv.LV_ALIGN_LEFT_MID, 20, 0);
    }

    const subtitle = lv.lv_label_create(header);
    if (subtitle) |s| {
        lv.lv_label_set_text(s, "Home Assistant");
        lv.lv_obj_set_style_text_color(s, lv.lv_color_hex(0x888888), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(s, lv.lv_font_montserrat_14, lv.LV_PART_MAIN);
        lv.lv_obj_align(s, lv.LV_ALIGN_RIGHT_MID, -20, 0);
    }

    // --- Card grid container ---
    const grid = lv.lv_obj_create(screen);
    if (grid == null) return;

    lv.lv_obj_set_size(grid, @intCast(screen_w - 40), @intCast(screen_h - 76));
    lv.lv_obj_align(grid, lv.LV_ALIGN_TOP_LEFT, 20, 66);
    lv.lv_obj_set_style_bg_opa(grid, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(grid, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(grid, lv.LV_FLEX_FLOW_ROW_WRAP);
    lv.lv_obj_set_flex_align(grid, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_START);
    lv.lv_obj_set_style_pad_all(grid, 10, lv.LV_PART_MAIN);

    // --- Sample cards ---
    createCard(grid, "Living Room", "Light", "ON", 0x4ecca3);
    createCard(grid, "Bedroom", "Light", "OFF", 0xe74c3c);
    createCard(grid, "Thermostat", "Climate", "21.5\xc2\xb0" ++ "C", 0xf39c12);
    createCard(grid, "Front Door", "Lock", "Locked", 0x3498db);
    createCard(grid, "Kitchen", "Light", "ON", 0x4ecca3);
    createCard(grid, "Motion", "Sensor", "Clear", 0x95a5a6);
    createCard(grid, "Garage", "Cover", "Closed", 0x9b59b6);
    createCard(grid, "Energy", "Sensor", "1.2 kW", 0xe67e22);
}

fn createCard(parent: ?*lv.lv_obj_t, name: [*:0]const u8, entity_type: [*:0]const u8, state: [*:0]const u8, color: u32) void {
    if (parent == null) return;

    const card = lv.lv_obj_create(parent);
    if (card == null) return;

    lv.lv_obj_set_size(card, 280, 140);
    lv.lv_obj_set_style_bg_color(card, lv.lv_color_hex(0x202040), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(card, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(card, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_flex_flow(card, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_all(card, 16, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(card, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Entity type label (small, grey)
    const type_label = lv.lv_label_create(card);
    if (type_label) |tl| {
        lv.lv_label_set_text(tl, entity_type);
        lv.lv_obj_set_style_text_color(tl, lv.lv_color_hex(0x888888), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(tl, lv.lv_font_montserrat_14, lv.LV_PART_MAIN);
    }

    // Entity name (medium, white)
    const name_label = lv.lv_label_create(card);
    if (name_label) |nl| {
        lv.lv_label_set_text(nl, name);
        lv.lv_obj_set_style_text_color(nl, lv.lv_color_hex(0xe0e0e0), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(nl, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
    }

    // State value (colored)
    const state_label = lv.lv_label_create(card);
    if (state_label) |sl| {
        lv.lv_label_set_text(sl, state);
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(color), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_text_font(sl, lv.lv_font_montserrat_20, lv.LV_PART_MAIN);
    }
}
