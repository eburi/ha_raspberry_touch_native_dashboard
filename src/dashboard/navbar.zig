///! Navigation bar (right side, 10% width) and page switching logic.
const lv = @import("lv");
const theme = @import("theme.zig");

// ============================================================
// Module state
// ============================================================

/// Page container objects (one per page, shown/hidden).
var page_containers: [theme.PAGE_COUNT]?*lv.lv_obj_t = .{ null, null, null, null };

/// Nav icon button objects (for highlight tracking).
var nav_buttons: [theme.PAGE_COUNT]?*lv.lv_obj_t = .{ null, null, null, null };

var current_page: usize = theme.PAGE_LOGBOOK;

// ============================================================
// Public API
// ============================================================

/// Store a page container reference (called during page creation).
pub fn setPageContainer(index: usize, container: ?*lv.lv_obj_t) void {
    if (index < theme.PAGE_COUNT) {
        page_containers[index] = container;
    }
}

/// Create the navigation bar on the right side of the screen.
pub fn create(parent: ?*lv.lv_obj_t, nav_w: u32, screen_h: u32) void {
    if (parent == null) return;

    const bar = lv.lv_obj_create(parent);
    if (bar == null) return;

    lv.lv_obj_set_size(bar, @intCast(nav_w), @intCast(screen_h));
    lv.lv_obj_align(bar, lv.LV_ALIGN_TOP_RIGHT, 0, 0);
    lv.lv_obj_set_style_bg_color(bar, lv.lv_color_hex(theme.COL_NAV_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(bar, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(bar, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(bar, 1, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(bar, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_side(bar, lv.LV_BORDER_SIDE_LEFT, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(bar, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(bar, lv.LV_OBJ_FLAG_SCROLLABLE);

    // Layout: column, evenly spaced
    lv.lv_obj_set_flex_flow(bar, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_flex_align(bar, lv.LV_FLEX_ALIGN_SPACE_EVENLY, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);

    const page_indices = [theme.PAGE_COUNT]usize{ theme.PAGE_LOGBOOK, theme.PAGE_ANCHOR, theme.PAGE_SAILS, theme.PAGE_SETTINGS };

    for (0..theme.PAGE_COUNT) |i| {
        nav_buttons[i] = createNavButton(bar, nav_w, page_indices[i]);
    }
}

/// Switch to the given page index, updating visibility and nav highlight.
pub fn showPage(index: usize) void {
    if (index >= theme.PAGE_COUNT) return;
    current_page = index;

    // Show/hide page containers
    for (0..theme.PAGE_COUNT) |i| {
        if (page_containers[i]) |container| {
            if (i == index) {
                lv.lv_obj_remove_flag(container, lv.LV_OBJ_FLAG_HIDDEN);
            } else {
                lv.lv_obj_add_flag(container, lv.LV_OBJ_FLAG_HIDDEN);
            }
        }
    }

    // Update nav button highlight
    for (0..theme.PAGE_COUNT) |i| {
        if (nav_buttons[i]) |btn| {
            // Get the image child (first child of button)
            const child = lv.c.lv_obj_get_child(btn, 0);
            if (child) |img| {
                if (i == index) {
                    // Active: bright foreground color + accent background
                    lv.lv_obj_set_style_image_recolor(img, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_image_recolor_opa(img, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
                } else {
                    // Inactive: dim
                    lv.lv_obj_set_style_image_recolor(img, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_image_recolor_opa(img, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_NAV_BG), lv.LV_PART_MAIN);
                }
            }
        }
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn createNavButton(parent: ?*lv.lv_obj_t, nav_w: u32, page_index: usize) ?*lv.lv_obj_t {
    if (parent == null) return null;

    const btn = lv.lv_button_create(parent);
    if (btn == null) return null;

    const btn_size: i32 = @intCast(nav_w - 16);
    lv.lv_obj_set_size(btn, btn_size, btn_size);
    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_NAV_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_radius(btn, 12, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(btn, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_shadow_width(btn, 0, lv.LV_PART_MAIN);

    const icon_dsc = theme.navIconForPage(page_index);
    const img = lv.lv_image_create(btn);
    if (img) |image| {
        lv.lv_image_set_src(image, icon_dsc);
        lv.lv_obj_set_style_image_recolor(image, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
        lv.lv_obj_set_style_image_recolor_opa(image, lv.LV_OPA_COVER, lv.LV_PART_MAIN);
        lv.lv_obj_center(image);
    }

    // Store page index as user_data for the click handler
    const user_data: ?*anyopaque = @ptrFromInt(page_index);
    _ = lv.lv_obj_add_event_cb(btn, navClickCb, lv.LV_EVENT_CLICKED, user_data);

    return btn;
}

fn navClickCb(e: ?*lv.lv_event_t) callconv(.C) void {
    if (e == null) return;
    const user_data = lv.lv_event_get_user_data(e);
    const page_index: usize = @intFromPtr(user_data);
    if (page_index < theme.PAGE_COUNT) {
        showPage(page_index);
    }
}
