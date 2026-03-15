///! Zig bridge to LVGL C API.
///! This module imports the LVGL C headers via @cImport and re-exports
///! the symbols that our Zig code needs. All WASM modules import this
///! instead of using @cImport directly, keeping the C boundary in one place.

pub const c = @cImport({
    @cDefine("LV_CONF_INCLUDE_SIMPLE", "1");
    @cInclude("lvgl.h");
});

// --- Types ---
pub const lv_display_t = c.lv_display_t;
pub const lv_area_t = c.lv_area_t;
pub const lv_indev_t = c.lv_indev_t;
pub const lv_indev_data_t = c.lv_indev_data_t;
pub const lv_obj_t = c.lv_obj_t;
pub const lv_event_t = c.lv_event_t;
pub const lv_color_t = c.lv_color_t;
pub const lv_font_t = c.lv_font_t;

// --- Display ---
pub const lv_display_create = c.lv_display_create;
pub const lv_display_set_flush_cb = c.lv_display_set_flush_cb;
pub const lv_display_set_buffers = c.lv_display_set_buffers;
pub const lv_display_set_render_mode = c.lv_display_set_render_mode;
pub const lv_display_set_color_format = c.lv_display_set_color_format;
pub const lv_display_flush_ready = c.lv_display_flush_ready;
pub const LV_DISPLAY_RENDER_MODE_FULL = c.LV_DISPLAY_RENDER_MODE_FULL;

// --- Input device ---
pub const lv_indev_create = c.lv_indev_create;
pub const lv_indev_set_type = c.lv_indev_set_type;
pub const lv_indev_set_read_cb = c.lv_indev_set_read_cb;
pub const lv_indev_set_display = c.lv_indev_set_display;
pub const LV_INDEV_TYPE_POINTER = c.LV_INDEV_TYPE_POINTER;
pub const LV_INDEV_STATE_PRESSED = c.LV_INDEV_STATE_PRESSED;
pub const LV_INDEV_STATE_RELEASED = c.LV_INDEV_STATE_RELEASED;

// --- Core ---
pub const lv_init = c.lv_init;
pub const lv_timer_handler = c.lv_timer_handler;
pub const lv_tick_set_cb = c.lv_tick_set_cb;

// --- Memory ---
pub const lv_malloc = c.lv_malloc;
pub const lv_free = c.lv_free;
pub const lv_memset = c.lv_memset;

// --- Object / widget creation ---
pub const lv_screen_active = c.lv_screen_active;
pub const lv_obj_create = c.lv_obj_create;
pub const lv_obj_set_size = c.lv_obj_set_size;
pub const lv_obj_set_pos = c.lv_obj_set_pos;
pub const lv_obj_align = c.lv_obj_align;
pub const lv_obj_center = c.lv_obj_center;
pub const lv_obj_set_style_bg_color = c.lv_obj_set_style_bg_color;
pub const lv_obj_set_style_bg_opa = c.lv_obj_set_style_bg_opa;
pub const lv_obj_set_style_text_color = c.lv_obj_set_style_text_color;
pub const lv_obj_set_style_text_font = c.lv_obj_set_style_text_font;
pub const lv_obj_set_style_radius = c.lv_obj_set_style_radius;
pub const lv_obj_set_style_pad_all = c.lv_obj_set_style_pad_all;
pub const lv_obj_set_flex_flow = c.lv_obj_set_flex_flow;
pub const lv_obj_set_flex_align = c.lv_obj_set_flex_align;
pub const lv_obj_set_width = c.lv_obj_set_width;
pub const lv_obj_set_height = c.lv_obj_set_height;
pub const lv_obj_remove_flag = c.lv_obj_remove_flag;
pub const lv_obj_add_flag = c.lv_obj_add_flag;

// --- Label ---
pub const lv_label_create = c.lv_label_create;
pub const lv_label_set_text = c.lv_label_set_text;
pub const lv_label_set_long_mode = c.lv_label_set_long_mode;

// --- Button ---
pub const lv_button_create = c.lv_button_create;

// --- Switch ---
pub const lv_switch_create = c.lv_switch_create;

// --- Slider ---
pub const lv_slider_create = c.lv_slider_create;
pub const lv_slider_set_value = c.lv_slider_set_value;
pub const lv_slider_set_range = c.lv_slider_set_range;

// --- Spinner ---
pub const lv_spinner_create = c.lv_spinner_create;

// --- Bar ---
pub const lv_bar_create = c.lv_bar_create;
pub const lv_bar_set_value = c.lv_bar_set_value;
pub const lv_bar_set_range = c.lv_bar_set_range;

// --- LED ---
pub const lv_led_create = c.lv_led_create;
pub const lv_led_set_color = c.lv_led_set_color;
pub const lv_led_on = c.lv_led_on;
pub const lv_led_off = c.lv_led_off;

// --- Color helpers ---
pub const lv_color_hex = c.lv_color_hex;
pub const lv_color_white = c.lv_color_white;
pub const lv_color_black = c.lv_color_black;
pub const lv_palette_main = c.lv_palette_main;

// --- Constants ---
pub const LV_ALIGN_CENTER = c.LV_ALIGN_CENTER;
pub const LV_ALIGN_TOP_LEFT = c.LV_ALIGN_TOP_LEFT;
pub const LV_ALIGN_TOP_MID = c.LV_ALIGN_TOP_MID;
pub const LV_ALIGN_TOP_RIGHT = c.LV_ALIGN_TOP_RIGHT;
pub const LV_ALIGN_BOTTOM_LEFT = c.LV_ALIGN_BOTTOM_LEFT;
pub const LV_ALIGN_BOTTOM_MID = c.LV_ALIGN_BOTTOM_MID;
pub const LV_ALIGN_BOTTOM_RIGHT = c.LV_ALIGN_BOTTOM_RIGHT;
pub const LV_ALIGN_LEFT_MID = c.LV_ALIGN_LEFT_MID;
pub const LV_ALIGN_RIGHT_MID = c.LV_ALIGN_RIGHT_MID;

pub const LV_SIZE_CONTENT = c.LV_SIZE_CONTENT;
pub const LV_PCT = c.lv_pct;
pub const LV_OPA_COVER = c.LV_OPA_COVER;
pub const LV_OPA_TRANSP = c.LV_OPA_TRANSP;
pub const LV_PART_MAIN = c.LV_PART_MAIN;
pub const LV_STATE_DEFAULT = c.LV_STATE_DEFAULT;
pub const LV_ANIM_OFF = c.LV_ANIM_OFF;

pub const LV_FLEX_FLOW_ROW = c.LV_FLEX_FLOW_ROW;
pub const LV_FLEX_FLOW_COLUMN = c.LV_FLEX_FLOW_COLUMN;
pub const LV_FLEX_FLOW_ROW_WRAP = c.LV_FLEX_FLOW_ROW_WRAP;
pub const LV_FLEX_ALIGN_START = c.LV_FLEX_ALIGN_START;
pub const LV_FLEX_ALIGN_CENTER = c.LV_FLEX_ALIGN_CENTER;
pub const LV_FLEX_ALIGN_SPACE_EVENLY = c.LV_FLEX_ALIGN_SPACE_EVENLY;
pub const LV_FLEX_ALIGN_SPACE_BETWEEN = c.LV_FLEX_ALIGN_SPACE_BETWEEN;

pub const LV_OBJ_FLAG_SCROLLABLE = c.LV_OBJ_FLAG_SCROLLABLE;

// --- Fonts ---
pub const lv_font_montserrat_14 = &c.lv_font_montserrat_14;
pub const lv_font_montserrat_20 = &c.lv_font_montserrat_20;

// --- Palette ---
pub const LV_PALETTE_BLUE = c.LV_PALETTE_BLUE;
pub const LV_PALETTE_RED = c.LV_PALETTE_RED;
pub const LV_PALETTE_GREEN = c.LV_PALETTE_GREEN;
pub const LV_PALETTE_ORANGE = c.LV_PALETTE_ORANGE;
pub const LV_PALETTE_GREY = c.LV_PALETTE_GREY;
pub const LV_PALETTE_YELLOW = c.LV_PALETTE_YELLOW;
pub const LV_PALETTE_CYAN = c.LV_PALETTE_CYAN;
