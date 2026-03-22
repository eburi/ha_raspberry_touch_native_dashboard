///! Shared color palette and layout constants for the dashboard.
///!
///! Color palette (dark nautical theme):
///!   BG_DARK    #220901  — screen / deepest background
///!   BG_MID     #621708  — card backgrounds
///!   ACCENT_1   #941B0C  — borders, inactive elements
///!   ACCENT_2   #BC3908  — active nav icon, highlights
///!   FOREGROUND #F6AA1C  — text, values, active buttons
const lv = @import("lv");

// ============================================================
// Color palette
// ============================================================
pub const COL_BG_DARK = 0x180600;
pub const COL_BG_MID = 0x621708;
pub const COL_ACCENT_1 = 0x941B0C;
pub const COL_ACCENT_2 = 0xBC3908;
pub const COL_FG = 0xF6AA1C;
pub const COL_TEXT = 0xF6AA1C;
pub const COL_TEXT_DIM = 0x944A10; // dimmed text (derived: midpoint FG/BG)
pub const COL_NAV_BG = 0x180600; // slightly darker than BG_DARK for nav bar
pub const COL_CARD_BG = 0x3A0E04; // card background (between BG_DARK and BG_MID)
pub const COL_CARD_BORDER = 0x621708;

// ============================================================
// Layout constants (1280x720)
// ============================================================
pub const NAV_WIDTH_PCT = 10; // right-side nav bar = 10% of screen width
pub const PAGE_TITLE_H = 48; // page title row height

// ============================================================
// Page indices
// ============================================================
pub const PAGE_LOGBOOK: usize = 0;
pub const PAGE_ANCHOR: usize = 1;
pub const PAGE_SAILS: usize = 2;
pub const PAGE_SETTINGS: usize = 3;
pub const PAGE_COUNT: usize = 4;

// ============================================================
// UI helpers
// ============================================================

/// Creates a page title row with an icon and label.
pub fn createPageTitle(parent: ?*lv.lv_obj_t, text: [*:0]const u8, page_index: usize) void {
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

/// Creates a sensor card with a small label (title) and a large value label.
/// Returns the value label pointer so it can be updated later.
pub fn createSensorCard(
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

/// Creates a card row container at a given y offset.
pub fn createCardRow(parent: ?*lv.lv_obj_t, page_w: u32, y_offset: i32, row_h: i32, gap: i32) ?*lv.lv_obj_t {
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
// Icon lookup helpers
// ============================================================

pub fn navIconForPage(page_index: usize) *const anyopaque {
    return switch (page_index) {
        PAGE_LOGBOOK => &lv.tabler_icon_api_book_N,
        PAGE_ANCHOR => &lv.tabler_icon_anchor_N,
        PAGE_SAILS => &lv.tabler_icon_sailboat_N,
        PAGE_SETTINGS => &lv.tabler_icon_settings_N,
        else => &lv.tabler_icon_api_book_N,
    };
}

pub fn titleIconForPage(page_index: usize) *const anyopaque {
    return switch (page_index) {
        PAGE_LOGBOOK => &lv.tabler_icon_api_book_P,
        PAGE_ANCHOR => &lv.tabler_icon_anchor_P,
        PAGE_SAILS => &lv.tabler_icon_sailboat_P,
        PAGE_SETTINGS => &lv.tabler_icon_settings_P,
        else => &lv.tabler_icon_api_book_P,
    };
}
