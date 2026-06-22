///! Native display module — drives LVGL on a physical framebuffer + touchscreen.
///!
///! When hardware is detected (via probe), this module:
///!   1. Opens the framebuffer device and mmap's it
///!   2. Opens the touch input device
///!   3. Initializes LVGL with the framebuffer as display target
///!   4. Creates the dashboard UI
///!   5. Runs the LVGL timer loop in a background thread
///!
///! The server calls start()/stop() to manage the native display lifecycle.
///! If no hardware is present, start() is simply never called.
const std = @import("std");
const lv = @import("lv");
const input = @import("input");
const dashboard = @import("dashboard");
const Fbdev = @import("fbdev").Fbdev;
const Evdev = @import("evdev").Evdev;
const probe_mod = @import("probe");
const Backlight = @import("backlight").Backlight;

const log = std.log.scoped(.native);

/// Default display dimensions for RPi Touch Display 2
const DEFAULT_WIDTH: u32 = 1280;
const DEFAULT_HEIGHT: u32 = 720;
const MAX_ENTITY_ID_LEN: usize = 128;
const MAX_STATE_LEN: usize = 192;
const MAX_PENDING_UPDATES: usize = 512;

const SENSOR_COUNT: usize = 15;
const TANK_COUNT: usize = 4;

const EntityBuf = struct {
    buf: [MAX_ENTITY_ID_LEN]u8 = undefined,
    len: usize = 0,
};

const PendingUpdate = struct {
    entity: [MAX_ENTITY_ID_LEN]u8 = undefined,
    entity_len: u16 = 0,
    state: [MAX_STATE_LEN]u8 = undefined,
    state_len: u16 = 0,
};

/// Native display state
var fbdev: Fbdev = .{};
var evdev: Evdev = .{};
var lvgl_thread: ?std.Thread = null;
var should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var is_running: bool = false;
var configured_rotation_degrees: u16 = 270;
var configured_backlight_path: ?[]const u8 = null;
var configured_backlight_max_raw: i32 = 0;

var backlight: ?Backlight = null;
var backlight_percent: u8 = 100;
var backlight_mutex: std.Thread.Mutex = .{};

var pending_brightness_percent: ?u8 = null;
var pending_brightness_mutex: std.Thread.Mutex = .{};

var pending_updates: [MAX_PENDING_UPDATES]PendingUpdate = undefined;
var pending_head: usize = 0;
var pending_tail: usize = 0;
var pending_count: usize = 0;
var pending_mutex: std.Thread.Mutex = .{};
var queue_full_warned: bool = false;

/// Callback for HA service calls — will be set by the server before start()
var ha_call_service_fn: ?*const fn (domain: []const u8, service: []const u8, entity_id: []const u8, extra_json: ?[]const u8) void = null;

/// Callback for host shutdown — will be set by the server before start()
var shutdown_fn: ?*const fn () void = null;
var brightness_changed_fn: ?*const fn (percent: u8) void = null;

/// Entity config JSON (kept for the LVGL thread to parse during init)
var entity_config_json: []const u8 = "{}";

var sensor_entities: [SENSOR_COUNT]EntityBuf = initDefaultSensorEntities();
var tank_entities: [TANK_COUNT]EntityBuf = initDefaultTankEntities();
var sail_entities: [dashboard.ENTITY_COUNT]EntityBuf = initDefaultSailEntities();
var brightness_entity: EntityBuf = initDefaultBrightnessEntity();

/// Set the function used to call HA services.
/// Must be called before start() so platform callbacks can reach HA.
pub fn setHaCallService(func: *const fn (domain: []const u8, service: []const u8, entity_id: []const u8, extra_json: ?[]const u8) void) void {
    ha_call_service_fn = func;
}

/// Set the function used to initiate a host shutdown.
/// Must be called before start().
pub fn setShutdownFn(func: *const fn () void) void {
    shutdown_fn = func;
}

/// Set a callback that receives brightness changes from native controls.
pub fn setBrightnessChangedFn(func: *const fn (percent: u8) void) void {
    brightness_changed_fn = func;
}

pub const BrightnessState = struct {
    available: bool,
    percent: u8,
};

pub fn getBrightnessState() BrightnessState {
    backlight_mutex.lock();
    defer backlight_mutex.unlock();

    return .{
        .available = backlight != null,
        .percent = backlight_percent,
    };
}

/// Configure a specific backlight sysfs directory (e.g. /sys/class/backlight/rpi_backlight).
pub fn setBacklightPath(path: ?[]const u8) void {
    configured_backlight_path = path;
}

/// Set the maximum raw value to write to sysfs brightness.
/// 0 means use the hardware max_brightness value.
/// Values ~100 often give the full visual range on RPi displays.
pub fn setBacklightMaxRaw(max_raw: i32) void {
    configured_backlight_max_raw = max_raw;
}

/// Set brightness from non-LVGL threads (REST/API).
pub fn setBrightnessPercent(percent: u8) !void {
    try setBrightnessPercentInternal(percent, true, true);
}

fn setBrightnessFromHaState(percent: u8) !void {
    try setBrightnessPercentInternal(percent, false, true);
}

fn setBrightnessPercentInternal(percent: u8, sync_to_ha: bool, queue_ui_update: bool) !void {
    const clamped: u8 = @min(percent, 100);

    {
        backlight_mutex.lock();
        defer backlight_mutex.unlock();

        const bl = backlight orelse return error.BacklightUnavailable;
        try bl.setPercent(clamped);
        backlight_percent = clamped;
    }

    if (queue_ui_update) {
        pending_brightness_mutex.lock();
        pending_brightness_percent = clamped;
        pending_brightness_mutex.unlock();
    }

    if (sync_to_ha) {
        syncBrightnessToHa(clamped);
    }

    notifyBrightnessChanged(clamped);
}

/// Set the entity configuration JSON. Must be called before start().
/// The JSON is parsed during LVGL init to configure sail entity IDs.
pub fn setEntityConfig(json: []const u8) void {
    entity_config_json = json;
}

/// Enqueue a Home Assistant state update for application on the LVGL thread.
/// This can be called from non-LVGL threads (e.g., HA client thread).
pub fn enqueueStateUpdate(entity_id: []const u8, state: []const u8) void {
    if (entity_id.len == 0 or state.len == 0) return;
    if (entity_id.len > MAX_ENTITY_ID_LEN or state.len > MAX_STATE_LEN) return;

    pending_mutex.lock();
    defer pending_mutex.unlock();

    if (pending_count >= MAX_PENDING_UPDATES) {
        if (!queue_full_warned) {
            log.warn("State update queue full ({d}) — dropping updates", .{MAX_PENDING_UPDATES});
            queue_full_warned = true;
        }
        return;
    }

    var item = &pending_updates[pending_tail];
    @memcpy(item.entity[0..entity_id.len], entity_id);
    @memcpy(item.state[0..state.len], state);
    item.entity_len = @intCast(entity_id.len);
    item.state_len = @intCast(state.len);

    pending_tail = (pending_tail + 1) % MAX_PENDING_UPDATES;
    pending_count += 1;
    queue_full_warned = false;
}

/// Handle raw Home Assistant state updates that should bypass display formatting.
/// Used for entities like light.dashboard_brightness where the canonical state
/// needs to be interpreted directly.
pub fn handleHaRawStateUpdate(entity_id: []const u8, state: []const u8) void {
    if (!entityEquals(brightness_entity, entity_id)) return;

    if (parseBrightnessState(state)) |percent| {
        setBrightnessFromHaState(percent) catch |err| {
            log.warn("Failed to apply raw brightness state from HA: {}", .{err});
        };
    }
}

/// Set display rotation in degrees (valid values: 0, 90, 180, 270).
/// Invalid values fall back to 270.
pub fn setDisplayRotationDegrees(deg: u16) void {
    configured_rotation_degrees = switch (deg) {
        0, 90, 180, 270 => deg,
        else => 270,
    };
}

fn rotationFromDegrees(deg: u16) u32 {
    return switch (deg) {
        90 => lv.LV_DISPLAY_ROTATION_90,
        180 => lv.LV_DISPLAY_ROTATION_180,
        270 => lv.LV_DISPLAY_ROTATION_270,
        else => lv.LV_DISPLAY_ROTATION_0,
    };
}

/// Probe for hardware and start the native display if found.
/// Returns true if native display was started, false if no hardware.
pub fn start() !bool {
    resetPendingQueue();

    const hw = probe_mod.probe();

    if (!hw.has_display) {
        log.info("No display hardware — native rendering disabled", .{});
        return false;
    }

    const fb_path = hw.framebuffer_path orelse "/dev/fb0";
    fbdev = Fbdev.init(fb_path) catch |err| {
        log.err("Failed to initialize framebuffer {s}: {}", .{ fb_path, err });
        return false;
    };

    const physical_width = if (fbdev.width > 0) fbdev.width else DEFAULT_WIDTH;
    const physical_height = if (fbdev.height > 0) fbdev.height else DEFAULT_HEIGHT;

    fbdev.rotation = rotationFromDegrees(configured_rotation_degrees);

    initBacklight();

    var ui_width = physical_width;
    var ui_height = physical_height;
    if (configured_rotation_degrees == 90 or configured_rotation_degrees == 270) {
        ui_width = physical_height;
        ui_height = physical_width;
    }

    log.info("Display rotation: {d} degrees, physical={d}x{d}, ui={d}x{d}", .{
        configured_rotation_degrees,
        physical_width,
        physical_height,
        ui_width,
        ui_height,
    });

    // Initialize touch input if available
    if (hw.has_touch) {
        const input_path = hw.input_device_path orelse "/dev/input/event0";
        if (Evdev.init(input_path, physical_width, physical_height, ui_width, ui_height, fbdev.rotation)) |ev| {
            evdev = ev;
        } else |err| {
            log.warn("Failed to initialize touch input {s}: {} — continuing without touch", .{ input_path, err });
            // Non-fatal: display still works, just no touch
        }
    }

    // Start the LVGL thread
    should_stop.store(false, .release);
    lvgl_thread = try std.Thread.spawn(.{}, lvglLoop, .{ ui_width, ui_height });
    is_running = true;

    log.info("Native display started: physical={d}x{d}, ui={d}x{d}", .{ physical_width, physical_height, ui_width, ui_height });
    return true;
}

/// Stop the native display and clean up.
pub fn stop() void {
    if (!is_running) return;

    should_stop.store(true, .release);
    if (lvgl_thread) |thread| {
        thread.join();
        lvgl_thread = null;
    }

    evdev.deinit();
    fbdev.deinit();
    deinitBacklight();
    is_running = false;
    resetPendingQueue();

    log.info("Native display stopped", .{});
}

/// LVGL main loop — runs in a dedicated thread.
fn lvglLoop(width: u32, height: u32) void {
    // Initialize LVGL
    lv.lv_init();

    // Set tick source — use monotonic clock
    var start_time: ?i64 = null;
    _ = &start_time; // suppress unused warning — used by tickCb closure below

    lv.lv_tick_set_cb(&tickCb);

    // Initialize framebuffer display
    fbdev.initDisplay();

    // Initialize LVGL input driver
    input.init(fbdev.display);

    // Start evdev reader thread (feeds input.setInput)
    evdev.start() catch |err| {
        log.warn("Failed to start input reader: {} — continuing without touch", .{err});
    };

    // Set up platform callbacks for native HA communication
    dashboard.setPlatformCallbacks(.{
        .sail_config_changed = &nativeSailConfigChanged,
        .sail_toggle_changed = &nativeSailToggleChanged,
        .anchor_action = &nativeAnchorAction,
        .power_off = &nativePowerOff,
        .brightness_changed = &nativeBrightnessChanged,
    });

    // Apply entity config from server config (sail entity IDs)
    applyEntityConfig();

    // Create the dashboard
    dashboard.init(width, height);
    dashboard.create();
    dashboard.update_brightness(@intCast(backlight_percent));

    log.info("LVGL initialized, entering render loop", .{});

    // Main render loop — call lv_timer_handler at ~30fps
    while (!should_stop.load(.acquire)) {
        applyPendingBrightnessUpdate();
        applyPendingStateUpdates();
        _ = lv.lv_timer_handler();
        std.time.sleep(33 * std.time.ns_per_ms); // ~30fps
    }

    log.info("LVGL render loop exiting", .{});
}

/// Tick callback for LVGL — returns milliseconds since LVGL init.
var tick_start: ?i128 = null;

fn tickCb() callconv(.C) u32 {
    const now = std.time.nanoTimestamp();
    if (tick_start == null) {
        tick_start = now;
    }
    const elapsed_ns = now - tick_start.?;
    const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
    return @intCast(@min(elapsed_ms, std.math.maxInt(u32)));
}

// ============================================================
// Native platform callbacks — call HA services directly
// ============================================================

fn nativeSailConfigChanged(entity_ptr: [*]const u8, entity_len: i32, option_ptr: [*]const u8, option_len: i32) void {
    const entity_id = entity_ptr[0..@intCast(entity_len)];
    const option = option_ptr[0..@intCast(option_len)];

    log.info("Sail config: {s} -> {s}", .{ entity_id, option });

    if (ha_call_service_fn) |callService| {
        // Build extra JSON with the option value
        var buf: [256]u8 = undefined;
        const extra = std.fmt.bufPrint(&buf, "\"option\":\"{s}\"", .{option}) catch return;
        callService("input_select", "select_option", entity_id, extra);
    }
}

fn nativeSailToggleChanged(entity_ptr: [*]const u8, entity_len: i32, state: i32) void {
    const entity_id = entity_ptr[0..@intCast(entity_len)];
    const service = if (state != 0) "turn_on" else "turn_off";

    log.info("Toggle: {s} -> {s}", .{ entity_id, service });

    if (ha_call_service_fn) |callService| {
        callService("input_boolean", service, entity_id, null);
    }
}

fn nativeAnchorAction(action_ptr: [*]const u8, action_len: i32, value: f64) void {
    const action = action_ptr[0..@intCast(action_len)];

    // Zoom actions are client-side only (no HA call needed for native)
    // The native display handles its own zoom state
    if (std.mem.eql(u8, action, "zoom_inc") or std.mem.eql(u8, action, "zoom_dec")) {
        log.debug("Anchor zoom: {s}", .{action});
        // TODO: implement native zoom state management
        return;
    }

    log.info("Anchor action: {s} (value={d:.1})", .{ action, value });

    if (ha_call_service_fn) |callService| {
        var buf: [256]u8 = undefined;
        const extra = std.fmt.bufPrint(&buf, "\"action\":\"{s}\",\"value\":{d:.1}", .{ action, value }) catch return;
        callService("script", action, "", extra);
    }
}

fn nativePowerOff() void {
    log.info("Power off requested — initiating host shutdown", .{});
    if (shutdown_fn) |doShutdown| {
        doShutdown();
    } else {
        log.warn("No shutdown function set — power off ignored", .{});
    }
}

fn nativeBrightnessChanged(percent: i32) void {
    const clamped: u8 = @intCast(@max(0, @min(100, percent)));

    setBrightnessPercent(clamped) catch |err| {
        log.warn("Failed to set backlight brightness to {d}%: {}", .{ clamped, err });
        return;
    };
}

fn notifyBrightnessChanged(percent: u8) void {
    if (brightness_changed_fn) |cb| {
        cb(percent);
    }
}

fn syncBrightnessToHa(percent: u8) void {
    const entity_id = brightness_entity.buf[0..brightness_entity.len];
    if (entity_id.len == 0) return;

    if (ha_call_service_fn) |callService| {
        if (percent == 0) {
            callService("light", "turn_off", entity_id, null);
        } else {
            var buf: [64]u8 = undefined;
            const extra = std.fmt.bufPrint(&buf, "\"brightness_pct\":{d}", .{percent}) catch return;
            callService("light", "turn_on", entity_id, extra);
        }
    }
}

fn initBacklight() void {
    backlight_mutex.lock();
    defer backlight_mutex.unlock();

    if (backlight != null) return;

    backlight = Backlight.discover(std.heap.page_allocator, configured_backlight_path) catch |err| {
        log.warn("Backlight discovery failed: {}", .{err});
        return;
    };

    if (backlight) |*bl| {
        if (configured_backlight_max_raw > 0) {
            bl.setMaxRawOverride(configured_backlight_max_raw);
            log.info("Backlight max_raw override set to {d}", .{configured_backlight_max_raw});
        }
        backlight_percent = bl.getPercent() catch |err| blk: {
            log.warn("Failed to read initial backlight brightness: {}", .{err});
            break :blk 100;
        };
        log.info("Backlight initialized at {d}%", .{backlight_percent});
    }
}

fn deinitBacklight() void {
    backlight_mutex.lock();
    defer backlight_mutex.unlock();

    if (backlight) |*bl| {
        bl.deinit();
    }
    backlight = null;
}

fn applyPendingBrightnessUpdate() void {
    pending_brightness_mutex.lock();
    const maybe_percent = pending_brightness_percent;
    pending_brightness_percent = null;
    pending_brightness_mutex.unlock();

    if (maybe_percent) |percent| {
        dashboard.update_brightness(@intCast(percent));
    }
}

// ============================================================
// Entity config parsing
// ============================================================

/// Parse the entity_config_json and push sail entity IDs into dashboard.
fn applyEntityConfig() void {
    const json = entity_config_json;
    if (json.len <= 2) return; // "{}" or empty

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch |err| {
        log.warn("Failed to parse ENTITY_CONFIG JSON: {} — using defaults", .{err});
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    applyDefaultEntityMappings();

    const sensor_keys = [_][]const u8{
        "latitude",
        "longitude",
        "log",
        "heading",
        "stw",
        "sog",
        "cog",
        "aws",
        "awa",
        "tws",
        "twd",
        "barometric_pressure",
        "distance_24h",
        "speed_24h",
        "datetime",
    };
    for (sensor_keys, 0..) |key, idx| {
        if (obj.get(key)) |val| {
            switch (val) {
                .string => |s| {
                    if (s.len > 0) {
                        setEntityBuf(&sensor_entities[idx], s);
                        log.info("Entity {s} = {s}", .{ key, s });
                    }
                },
                else => {},
            }
        }
    }

    const tank_keys = [_][]const u8{
        "tank_fuel",
        "tank_water_port",
        "tank_water_stbd",
        "tank_water_stbd_aft",
    };
    for (tank_keys, 0..) |key, idx| {
        if (obj.get(key)) |val| {
            switch (val) {
                .string => |s| {
                    if (s.len > 0) {
                        setEntityBuf(&tank_entities[idx], s);
                        log.info("Entity {s} = {s}", .{ key, s });
                    }
                },
                else => {},
            }
        }
    }

    const sail_keys = [_][]const u8{ "sail_main", "sail_jib", "sail_code0" };
    for (sail_keys, 0..) |key, slot| {
        if (obj.get(key)) |val| {
            switch (val) {
                .string => |s| {
                    if (s.len > 0) {
                        setEntityBuf(&sail_entities[slot], s);
                        dashboard.setEntityId(@intCast(slot), s.ptr, @intCast(s.len));
                        log.info("Entity {s} = {s}", .{ key, s });
                    }
                },
                else => {},
            }
        }
    }

    if (obj.get("brightness")) |val| {
        switch (val) {
            .string => |s| {
                if (s.len > 0) {
                    setEntityBuf(&brightness_entity, s);
                    log.info("Entity brightness = {s}", .{s});
                }
            },
            else => {},
        }
    }
}

fn applyDefaultEntityMappings() void {
    sensor_entities = initDefaultSensorEntities();
    tank_entities = initDefaultTankEntities();
    sail_entities = initDefaultSailEntities();
    brightness_entity = initDefaultBrightnessEntity();

    for (0..dashboard.ENTITY_COUNT) |slot| {
        const entity = sail_entities[slot].buf[0..sail_entities[slot].len];
        dashboard.setEntityId(@intCast(slot), entity.ptr, @intCast(entity.len));
    }
}

fn setEntityBuf(dst: *EntityBuf, src: []const u8) void {
    if (src.len == 0 or src.len > MAX_ENTITY_ID_LEN) return;
    @memcpy(dst.buf[0..src.len], src);
    dst.len = src.len;
}

fn entityEquals(buf: EntityBuf, entity_id: []const u8) bool {
    if (buf.len == 0) return false;
    return std.mem.eql(u8, buf.buf[0..buf.len], entity_id);
}

fn applyPendingStateUpdates() void {
    var local: [64]PendingUpdate = undefined;
    var local_count: usize = 0;

    pending_mutex.lock();
    while (pending_count > 0 and local_count < local.len) {
        local[local_count] = pending_updates[pending_head];
        pending_head = (pending_head + 1) % MAX_PENDING_UPDATES;
        pending_count -= 1;
        local_count += 1;
    }
    pending_mutex.unlock();

    for (0..local_count) |i| {
        const item = local[i];
        const entity_id = item.entity[0..item.entity_len];
        const state = item.state[0..item.state_len];
        applyNativeState(entity_id, state);
    }
}

fn applyNativeState(entity_id: []const u8, state: []const u8) void {
    for (sensor_entities, 0..) |buf, idx| {
        if (entityEquals(buf, entity_id)) {
            var tmp: [MAX_STATE_LEN + 1]u8 = undefined;
            @memcpy(tmp[0..state.len], state);
            tmp[state.len] = 0;
            dashboard.update_sensor(@intCast(idx), tmp[0..state.len].ptr, @intCast(state.len));
            return;
        }
    }

    for (tank_entities, 0..) |buf, idx| {
        if (entityEquals(buf, entity_id)) {
            dashboard.update_tank_level(@intCast(idx), state.ptr, @intCast(state.len));
            return;
        }
    }

    if (entityEquals(sail_entities[dashboard.ENTITY_SAIL_MAIN], entity_id)) {
        dashboard.update_sail_main(state.ptr, @intCast(state.len));
        return;
    }
    if (entityEquals(sail_entities[dashboard.ENTITY_SAIL_JIB], entity_id)) {
        dashboard.update_sail_jib(state.ptr, @intCast(state.len));
        return;
    }
    if (entityEquals(sail_entities[dashboard.ENTITY_CODE0], entity_id)) {
        dashboard.update_code0(state.ptr, @intCast(state.len));
        return;
    }
}

fn parseBrightnessState(state: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, state, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed.len > 2 and trimmed[trimmed.len - 1] == '%') {
        const no_pct = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
        if (no_pct.len > 0) {
            if (std.fmt.parseInt(i32, no_pct, 10)) |n_pct| {
                return @intCast(@max(0, @min(100, n_pct)));
            } else |_| {}
            if (std.fmt.parseFloat(f64, no_pct)) |f_pct| {
                if (std.math.isFinite(f_pct)) {
                    const n_pct: i32 = @intFromFloat(@round(f_pct));
                    return @intCast(@max(0, @min(100, n_pct)));
                }
            } else |_| {}
        }
    }

    if (std.ascii.eqlIgnoreCase(trimmed, "on")) return 100;
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) return 0;

    if (std.fmt.parseInt(i32, trimmed, 10)) |n| {
        return @intCast(@max(0, @min(100, n)));
    } else |_| {}

    if (std.fmt.parseFloat(f64, trimmed)) |f| {
        if (!std.math.isFinite(f)) return null;
        const n: i32 = @intFromFloat(@round(f));
        return @intCast(@max(0, @min(100, n)));
    } else |_| {}

    return null;
}

fn initDefaultSensorEntities() [SENSOR_COUNT]EntityBuf {
    var ids: [SENSOR_COUNT]EntityBuf = .{EntityBuf{}} ** SENSOR_COUNT;
    const defaults = [SENSOR_COUNT][]const u8{
        "sensor.primrose_latitude",
        "sensor.primrose_longitude",
        "sensor.primrose_log",
        "sensor.primrose_heading_true",
        "sensor.primrose_stw",
        "sensor.primrose_sog",
        "sensor.primrose_cog",
        "sensor.primrose_aws",
        "sensor.primrose_awa",
        "sensor.tws_mean_15min",
        "sensor.twd_mean_15min",
        "sensor.barometric_pressure",
        "sensor.primrose_log_change_24h",
        "sensor.average_speed_over_24h",
        "sensor.date_time_iso",
    };
    for (0..SENSOR_COUNT) |i| {
        setEntityBuf(&ids[i], defaults[i]);
    }
    return ids;
}

fn initDefaultTankEntities() [TANK_COUNT]EntityBuf {
    var ids: [TANK_COUNT]EntityBuf = .{EntityBuf{}} ** TANK_COUNT;
    const defaults = [TANK_COUNT][]const u8{
        "sensor.victron_mqtt_tank_23_tank_level",
        "sensor.victron_mqtt_tank_21_tank_level",
        "sensor.victron_mqtt_tank_22_tank_level",
        "sensor.safiery_starlink_tank_sensor_id_26_level",
    };
    for (0..TANK_COUNT) |i| {
        setEntityBuf(&ids[i], defaults[i]);
    }
    return ids;
}

fn initDefaultSailEntities() [dashboard.ENTITY_COUNT]EntityBuf {
    var ids: [dashboard.ENTITY_COUNT]EntityBuf = .{EntityBuf{}} ** dashboard.ENTITY_COUNT;
    const defaults = [dashboard.ENTITY_COUNT][]const u8{
        "input_select.sail_configuration_main",
        "input_select.sail_configuration_jib",
        "input_boolean.sail_configuration_code_0_set",
    };
    for (0..dashboard.ENTITY_COUNT) |i| {
        setEntityBuf(&ids[i], defaults[i]);
    }
    return ids;
}

fn initDefaultBrightnessEntity() EntityBuf {
    var id = EntityBuf{};
    setEntityBuf(&id, "light.dashboard_brightness");
    return id;
}

fn resetPendingQueue() void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_head = 0;
    pending_tail = 0;
    pending_count = 0;
    queue_full_warned = false;
}
