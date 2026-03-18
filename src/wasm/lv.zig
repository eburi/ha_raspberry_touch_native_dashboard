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
pub const lv_style_t = c.lv_style_t;
pub const lv_event_code_t = c.lv_event_code_t;

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

// --- Screen management ---
pub const lv_screen_active = c.lv_screen_active;
pub const lv_obj_create = c.lv_obj_create;
pub const lv_obj_delete = c.lv_obj_delete;
pub const lv_obj_clean = c.lv_obj_clean;
pub const lv_screen_load = c.lv_screen_load;
pub const lv_screen_load_anim = c.lv_screen_load_anim;

// --- Object sizing and positioning ---
pub const lv_obj_set_size = c.lv_obj_set_size;
pub const lv_obj_set_pos = c.lv_obj_set_pos;
pub const lv_obj_set_width = c.lv_obj_set_width;
pub const lv_obj_set_height = c.lv_obj_set_height;
pub const lv_obj_align = c.lv_obj_align;
pub const lv_obj_align_to = c.lv_obj_align_to;
pub const lv_obj_center = c.lv_obj_center;
pub const lv_obj_set_flex_flow = c.lv_obj_set_flex_flow;
pub const lv_obj_set_flex_align = c.lv_obj_set_flex_align;
pub const lv_obj_set_flex_grow = c.lv_obj_set_flex_grow;

// --- Object flags ---
pub const lv_obj_remove_flag = c.lv_obj_remove_flag;
pub const lv_obj_add_flag = c.lv_obj_add_flag;
pub const lv_obj_has_flag = c.lv_obj_has_flag;
pub const LV_OBJ_FLAG_SCROLLABLE = c.LV_OBJ_FLAG_SCROLLABLE;
pub const LV_OBJ_FLAG_CLICKABLE = c.LV_OBJ_FLAG_CLICKABLE;
pub const LV_OBJ_FLAG_HIDDEN = c.LV_OBJ_FLAG_HIDDEN;
pub const LV_OBJ_FLAG_CHECKABLE = c.LV_OBJ_FLAG_CHECKABLE;

// --- Object state ---
pub const lv_obj_add_state = c.lv_obj_add_state;
pub const lv_obj_remove_state = c.lv_obj_remove_state;
pub const lv_obj_has_state = c.lv_obj_has_state;
pub const LV_STATE_DEFAULT = c.LV_STATE_DEFAULT;
pub const LV_STATE_CHECKED = c.LV_STATE_CHECKED;
pub const LV_STATE_PRESSED = c.LV_STATE_PRESSED;
pub const LV_STATE_FOCUSED = c.LV_STATE_FOCUSED;
pub const LV_STATE_DISABLED = c.LV_STATE_DISABLED;

// --- Styling ---
pub const lv_obj_set_style_bg_color = c.lv_obj_set_style_bg_color;
pub const lv_obj_set_style_bg_opa = c.lv_obj_set_style_bg_opa;
pub const lv_obj_set_style_text_color = c.lv_obj_set_style_text_color;
pub const lv_obj_set_style_text_font = c.lv_obj_set_style_text_font;
pub const lv_obj_set_style_radius = c.lv_obj_set_style_radius;
pub const lv_obj_set_style_pad_all = c.lv_obj_set_style_pad_all;
pub const lv_obj_set_style_pad_top = c.lv_obj_set_style_pad_top;
pub const lv_obj_set_style_pad_bottom = c.lv_obj_set_style_pad_bottom;
pub const lv_obj_set_style_pad_left = c.lv_obj_set_style_pad_left;
pub const lv_obj_set_style_pad_right = c.lv_obj_set_style_pad_right;
pub const lv_obj_set_style_pad_row = c.lv_obj_set_style_pad_row;
pub const lv_obj_set_style_pad_column = c.lv_obj_set_style_pad_column;
pub const lv_obj_set_style_pad_gap = c.lv_obj_set_style_pad_gap;
pub const lv_obj_set_style_border_width = c.lv_obj_set_style_border_width;
pub const lv_obj_set_style_border_color = c.lv_obj_set_style_border_color;
pub const lv_obj_set_style_border_opa = c.lv_obj_set_style_border_opa;
pub const lv_obj_set_style_border_side = c.lv_obj_set_style_border_side;
pub const LV_BORDER_SIDE_LEFT = c.LV_BORDER_SIDE_LEFT;
pub const lv_obj_set_style_outline_width = c.lv_obj_set_style_outline_width;
pub const lv_obj_set_style_outline_color = c.lv_obj_set_style_outline_color;
pub const lv_obj_set_style_shadow_width = c.lv_obj_set_style_shadow_width;
pub const lv_obj_set_style_text_align = c.lv_obj_set_style_text_align;
pub const lv_obj_set_style_text_opa = c.lv_obj_set_style_text_opa;
pub const lv_obj_set_style_opa = c.lv_obj_set_style_opa;

// --- Events ---
pub const lv_obj_add_event_cb = c.lv_obj_add_event_cb;
pub const lv_event_get_code = c.lv_event_get_code;
pub const lv_event_get_target = c.lv_event_get_target;
pub const lv_event_get_user_data = c.lv_event_get_user_data;
pub const LV_EVENT_CLICKED = c.LV_EVENT_CLICKED;
pub const LV_EVENT_VALUE_CHANGED = c.LV_EVENT_VALUE_CHANGED;
pub const LV_EVENT_PRESSED = c.LV_EVENT_PRESSED;
pub const LV_EVENT_RELEASED = c.LV_EVENT_RELEASED;

// --- Label ---
pub const lv_label_create = c.lv_label_create;
pub const lv_label_set_text = c.lv_label_set_text;
pub const lv_label_set_long_mode = c.lv_label_set_long_mode;
pub const lv_label_set_text_static = c.lv_label_set_text_static;
pub const LV_LABEL_LONG_WRAP = c.LV_LABEL_LONG_WRAP;
pub const LV_LABEL_LONG_CLIP = c.LV_LABEL_LONG_CLIP;
pub const LV_LABEL_LONG_SCROLL = c.LV_LABEL_LONG_SCROLL;

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
pub const lv_color_mix = c.lv_color_mix;

// --- Alignment constants ---
pub const LV_ALIGN_CENTER = c.LV_ALIGN_CENTER;
pub const LV_ALIGN_TOP_LEFT = c.LV_ALIGN_TOP_LEFT;
pub const LV_ALIGN_TOP_MID = c.LV_ALIGN_TOP_MID;
pub const LV_ALIGN_TOP_RIGHT = c.LV_ALIGN_TOP_RIGHT;
pub const LV_ALIGN_BOTTOM_LEFT = c.LV_ALIGN_BOTTOM_LEFT;
pub const LV_ALIGN_BOTTOM_MID = c.LV_ALIGN_BOTTOM_MID;
pub const LV_ALIGN_BOTTOM_RIGHT = c.LV_ALIGN_BOTTOM_RIGHT;
pub const LV_ALIGN_LEFT_MID = c.LV_ALIGN_LEFT_MID;
pub const LV_ALIGN_RIGHT_MID = c.LV_ALIGN_RIGHT_MID;

// --- Size / layout constants ---
pub const LV_SIZE_CONTENT = c.LV_SIZE_CONTENT;
pub const LV_PCT = c.lv_pct;
pub const LV_OPA_COVER = c.LV_OPA_COVER;
pub const LV_OPA_TRANSP = c.LV_OPA_TRANSP;
pub const LV_OPA_50 = c.LV_OPA_50;
pub const LV_PART_MAIN = c.LV_PART_MAIN;
pub const LV_PART_ITEMS = c.LV_PART_ITEMS;
pub const LV_ANIM_OFF = c.LV_ANIM_OFF;
pub const LV_TEXT_ALIGN_LEFT = c.LV_TEXT_ALIGN_LEFT;
pub const LV_TEXT_ALIGN_CENTER = c.LV_TEXT_ALIGN_CENTER;
pub const LV_TEXT_ALIGN_RIGHT = c.LV_TEXT_ALIGN_RIGHT;

// --- Flex layout ---
pub const LV_FLEX_FLOW_ROW = c.LV_FLEX_FLOW_ROW;
pub const LV_FLEX_FLOW_COLUMN = c.LV_FLEX_FLOW_COLUMN;
pub const LV_FLEX_FLOW_ROW_WRAP = c.LV_FLEX_FLOW_ROW_WRAP;
pub const LV_FLEX_ALIGN_START = c.LV_FLEX_ALIGN_START;
pub const LV_FLEX_ALIGN_END = c.LV_FLEX_ALIGN_END;
pub const LV_FLEX_ALIGN_CENTER = c.LV_FLEX_ALIGN_CENTER;
pub const LV_FLEX_ALIGN_SPACE_EVENLY = c.LV_FLEX_ALIGN_SPACE_EVENLY;
pub const LV_FLEX_ALIGN_SPACE_BETWEEN = c.LV_FLEX_ALIGN_SPACE_BETWEEN;
pub const LV_FLEX_ALIGN_SPACE_AROUND = c.LV_FLEX_ALIGN_SPACE_AROUND;

// --- Screen load animation ---
pub const LV_SCR_LOAD_ANIM_NONE = c.LV_SCR_LOAD_ANIM_NONE;
pub const LV_SCR_LOAD_ANIM_MOVE_LEFT = c.LV_SCR_LOAD_ANIM_MOVE_LEFT;
pub const LV_SCR_LOAD_ANIM_MOVE_RIGHT = c.LV_SCR_LOAD_ANIM_MOVE_RIGHT;
pub const LV_SCR_LOAD_ANIM_FADE_IN = c.LV_SCR_LOAD_ANIM_FADE_IN;

// --- Fonts ---
pub const lv_font_montserrat_14 = &c.lv_font_montserrat_14;
pub const lv_font_montserrat_16 = &c.lv_font_montserrat_16;
pub const lv_font_montserrat_20 = &c.lv_font_montserrat_20;
pub const lv_font_montserrat_24 = &c.lv_font_montserrat_24;
pub const lv_font_montserrat_28 = &c.lv_font_montserrat_28;
pub const lv_font_montserrat_32 = &c.lv_font_montserrat_32;

// --- Built-in symbols (FontAwesome subset in Montserrat fonts) ---
pub const LV_SYMBOL_GPS = c.LV_SYMBOL_GPS; // location arrow — Logbook
pub const LV_SYMBOL_WARNING = c.LV_SYMBOL_WARNING; // triangle exclamation — Anchor Alarm
pub const LV_SYMBOL_EJECT = c.LV_SYMBOL_EJECT; // upward triangle — Sails
pub const LV_SYMBOL_HOME = c.LV_SYMBOL_HOME;
pub const LV_SYMBOL_SETTINGS = c.LV_SYMBOL_SETTINGS;
pub const LV_SYMBOL_LIST = c.LV_SYMBOL_LIST;
pub const LV_SYMBOL_FILE = c.LV_SYMBOL_FILE;
pub const LV_SYMBOL_OK = c.LV_SYMBOL_OK;
pub const LV_SYMBOL_CLOSE = c.LV_SYMBOL_CLOSE;
pub const LV_SYMBOL_REFRESH = c.LV_SYMBOL_REFRESH;
pub const LV_SYMBOL_EDIT = c.LV_SYMBOL_EDIT;
pub const LV_SYMBOL_BELL = c.LV_SYMBOL_BELL;
pub const LV_SYMBOL_TINT = c.LV_SYMBOL_TINT;
pub const LV_SYMBOL_UP = c.LV_SYMBOL_UP;
pub const LV_SYMBOL_DOWN = c.LV_SYMBOL_DOWN;
pub const LV_SYMBOL_LEFT = c.LV_SYMBOL_LEFT;
pub const LV_SYMBOL_RIGHT = c.LV_SYMBOL_RIGHT;

// --- Custom FontAwesome 6 icon fonts (generated via lv_font_conv) ---
extern const fa_icons_28: lv_font_t;
extern const fa_icons_20: lv_font_t;

// FontAwesome 6 icon codepoints (UTF-8 encoded strings for LVGL labels)
// Nav icons
pub const FA_BOOK = "\xef\x80\xad"; // U+F02D book (Logbook)
pub const FA_ANCHOR = "\xef\x84\xbd"; // U+F13D anchor (Anchor Alarm)
pub const FA_SAILBOAT = "\xef\x9b\xbc"; // U+F6FC sailboat (Sails)
// Sailing / weather
pub const FA_WIND = "\xef\x9c\xae"; // U+F72E wind
pub const FA_CLOUD = "\xef\x83\x82"; // U+F0C2 cloud
pub const FA_WATER = "\xef\x96\xa0"; // U+F5A0 water/waves
pub const FA_SHIP = "\xef\x88\x9a"; // U+F21A ship
pub const FA_GAUGE = "\xef\x80\xa3"; // U+F023 gauge
// General
pub const FA_LOCATION_ARROW = "\xef\x84\xa4"; // U+F124 location-arrow
pub const FA_LOCATION_DOT = "\xef\x8f\x85"; // U+F3C5 location-dot
pub const FA_WARNING = "\xef\x81\xb1"; // U+F071 triangle-exclamation
pub const FA_HOME = "\xef\x80\x95"; // U+F015 home
pub const FA_COG = "\xef\x80\x93"; // U+F013 cog/settings
pub const FA_CHECK = "\xef\x80\x8c"; // U+F00C check
pub const FA_XMARK = "\xef\x80\x8d"; // U+F00D xmark/close
pub const FA_REFRESH = "\xef\x80\xa1"; // U+F021 arrows-rotate
pub const FA_BELL = "\xef\x83\xb3"; // U+F0F3 bell
pub const FA_ARROW_UP = "\xef\x81\xa2"; // U+F062 arrow-up
pub const FA_ARROW_DOWN = "\xef\x81\xa3"; // U+F063 arrow-down
pub const FA_ARROW_LEFT = "\xef\x81\xa0"; // U+F060 arrow-left
pub const FA_ARROW_RIGHT = "\xef\x81\xa1"; // U+F061 arrow-right
pub const FA_CLOCK = "\xef\x80\x97"; // U+F017 clock
pub const FA_BOLT = "\xef\x88\x85"; // U+F205 bolt
pub const FA_THERMOMETER = "\xef\x8b\x89"; // U+F2C9 thermometer-half
pub const FA_DROPLET = "\xef\x81\x83"; // U+F043 droplet
pub const FA_ANCHOR_CHECK = "\xee\x93\xa6"; // U+E4E6 anchor-circle-check
pub const FA_GLOBE = "\xef\x82\xac"; // U+F0AC globe

// --- Palette ---
pub const LV_PALETTE_BLUE = c.LV_PALETTE_BLUE;
pub const LV_PALETTE_RED = c.LV_PALETTE_RED;
pub const LV_PALETTE_GREEN = c.LV_PALETTE_GREEN;
pub const LV_PALETTE_ORANGE = c.LV_PALETTE_ORANGE;
pub const LV_PALETTE_GREY = c.LV_PALETTE_GREY;
pub const LV_PALETTE_YELLOW = c.LV_PALETTE_YELLOW;
pub const LV_PALETTE_CYAN = c.LV_PALETTE_CYAN;
