///! Page 2: Sails — Main sail, jib & code 0 configuration.
const std = @import("std");
const lv = @import("lv");
const theme = @import("theme.zig");

// ============================================================
// Constants
// ============================================================
const SAIL_MAIN_OPTIONS = 5;
const sail_main_labels = [SAIL_MAIN_OPTIONS][*:0]const u8{
    "0%",
    "100%",
    "Reef 1",
    "Reef 2",
    "Reef 3",
};

const SAIL_JIB_OPTIONS = 6;
const sail_jib_labels = [SAIL_JIB_OPTIONS][*:0]const u8{
    "0%",
    "100%",
    "75%",
    "60%",
    "40%",
    "25%",
};

// ============================================================
// Entity ID management
// ============================================================
const MAX_ENTITY_ID_LEN = 128;

pub const ENTITY_SAIL_MAIN: usize = 0;
pub const ENTITY_SAIL_JIB: usize = 1;
pub const ENTITY_CODE0: usize = 2;
pub const ENTITY_COUNT: usize = 3;

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
// Module state
// ============================================================
var sail_main_btns: [SAIL_MAIN_OPTIONS]?*lv.lv_obj_t = .{ null, null, null, null, null };
var sail_main_current: usize = 0;

var sail_jib_btns: [SAIL_JIB_OPTIONS]?*lv.lv_obj_t = .{ null, null, null, null, null, null };
var sail_jib_current: usize = 0;

var code0_btn: ?*lv.lv_obj_t = null;
var code0_active: bool = false;

/// Platform callbacks — set by the coordinator.
var sail_config_changed_cb: ?*const fn (entity_ptr: [*]const u8, entity_len: i32, option_ptr: [*]const u8, option_len: i32) void = null;
var sail_toggle_changed_cb: ?*const fn (entity_ptr: [*]const u8, entity_len: i32, state: i32) void = null;

// ============================================================
// Public API
// ============================================================

pub fn setSailCallbacks(
    config_changed: ?*const fn (entity_ptr: [*]const u8, entity_len: i32, option_ptr: [*]const u8, option_len: i32) void,
    toggle_changed: ?*const fn (entity_ptr: [*]const u8, entity_len: i32, state: i32) void,
) void {
    sail_config_changed_cb = config_changed;
    sail_toggle_changed_cb = toggle_changed;
}

pub fn create(parent: ?*lv.lv_obj_t, page_w: u32, screen_h: u32) void {
    if (parent == null) return;

    theme.createPageTitle(parent, "Sail Configuration", theme.PAGE_SAILS);

    // Content area below title
    const content = lv.lv_obj_create(parent);
    if (content == null) return;

    const content_w = page_w - 40;
    lv.lv_obj_set_size(content, @intCast(content_w), @intCast(screen_h - 90));
    lv.lv_obj_align(content, lv.LV_ALIGN_TOP_LEFT, 0, theme.PAGE_TITLE_H);
    lv.lv_obj_set_style_bg_opa(content, lv.LV_OPA_TRANSP, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_pad_all(content, 0, lv.LV_PART_MAIN);
    lv.lv_obj_remove_flag(content, lv.LV_OBJ_FLAG_SCROLLABLE);

    // --- Main Sail row ---
    const sail_label = lv.lv_label_create(content);
    if (sail_label) |sl| {
        lv.lv_label_set_text(sl, "Main Sail");
        lv.lv_obj_set_style_text_color(sl, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
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

    updateSailMainHighlight(0);

    // --- Jib row ---
    const jib_y: i32 = 130;
    const jib_label = lv.lv_label_create(content);
    if (jib_label) |jl| {
        lv.lv_label_set_text(jl, "Jib");
        lv.lv_obj_set_style_text_color(jl, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
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

    updateSailJibHighlight(0);

    // --- Code 0 toggle ---
    const code0_y: i32 = 260;
    const code0_label = lv.lv_label_create(content);
    if (code0_label) |cl| {
        lv.lv_label_set_text(cl, "Code 0");
        lv.lv_obj_set_style_text_color(cl, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
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

// ============================================================
// State update functions
// ============================================================

/// Update the main sail selection from HA state.
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
pub fn update_code0(value_ptr: [*]const u8, value_len: i32) void {
    const value = value_ptr[0..@intCast(value_len)];
    code0_active = std.mem.eql(u8, value, "on");
    updateCode0Style();
}

// ============================================================
// Internal helpers
// ============================================================

fn createSailButton(parent: ?*lv.lv_obj_t, text: [*:0]const u8, option_index: usize, cb: lv.c.lv_event_cb_t) ?*lv.lv_obj_t {
    if (parent == null) return null;

    const btn = lv.lv_button_create(parent);
    if (btn == null) return null;

    lv.lv_obj_set_size(btn, 180, 60);
    lv.lv_obj_set_style_radius(btn, 10, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_width(btn, 2, lv.LV_PART_MAIN);
    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_shadow_width(btn, 0, lv.LV_PART_MAIN);

    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
    lv.lv_obj_set_style_bg_opa(btn, lv.LV_OPA_COVER, lv.LV_PART_MAIN);

    const lbl = lv.lv_label_create(btn);
    if (lbl) |l| {
        lv.lv_label_set_text(l, text);
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
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
        if (sail_config_changed_cb) |cb| {
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
        if (sail_config_changed_cb) |cb| {
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
    if (sail_toggle_changed_cb) |cb| {
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

fn updateSailButtonRow(btns: anytype, count: usize, active_index: usize) void {
    for (0..count) |i| {
        if (btns[i]) |btn| {
            const child = lv.c.lv_obj_get_child(btn, 0);
            if (child) |lbl| {
                if (i == active_index) {
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
                } else {
                    lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
                    lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
                }
            }
        }
    }
}

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

    code0_btn = btn;
    updateCode0Style();

    return btn;
}

fn updateCode0Style() void {
    if (code0_btn) |btn| {
        const child = lv.c.lv_obj_get_child(btn, 0);
        if (child) |lbl| {
            if (code0_active) {
                lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_ACCENT_2), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_FG), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_BG_DARK), lv.LV_PART_MAIN);
                lv.lv_label_set_text(lbl, "SET");
            } else {
                lv.lv_obj_set_style_bg_color(btn, lv.lv_color_hex(theme.COL_CARD_BG), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_border_color(btn, lv.lv_color_hex(theme.COL_ACCENT_1), lv.LV_PART_MAIN);
                lv.lv_obj_set_style_text_color(lbl, lv.lv_color_hex(theme.COL_TEXT_DIM), lv.LV_PART_MAIN);
                lv.lv_label_set_text(lbl, "NOT SET");
            }
        }
    }
}
