///! Home Assistant light entity integration via MQTT discovery.
///!
///! Creates a `light.dashboard_brightness` entity in HA using MQTT
///! discovery. Brightness changes from the dashboard (native or WebSocket)
///! are published as MQTT state updates. Commands received from HA via MQTT
///! are forwarded to the native display brightness control.
const std = @import("std");
const mqtt_client = @import("mqtt_client");

const log = std.log.scoped(.ha_light);

const DISCOVERY_TOPIC = "homeassistant/light/ha_raspberry_touch_dashboard/dashboard_brightness/config";
const COMMAND_TOPIC = "ha_dashboard/light/dashboard_brightness/set";
const STATE_TOPIC = "ha_dashboard/light/dashboard_brightness/state";

/// Callback set by main.zig to set native brightness.
var set_brightness_fn: ?*const fn (percent: u8) void = null;

/// Callback set by main.zig to get native brightness state.
var get_brightness_fn: ?*const fn () u8 = null;

/// The MQTT client instance (owned by this module).
var mqtt: ?*mqtt_client.MqttClient = null;

/// Whether MQTT discovery has been published on this connection.
var discovery_published: bool = false;

/// Current brightness state for publishing.
var current_percent: u8 = 100;

/// Module allocator.
var allocator: std.mem.Allocator = undefined;

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;
}

pub fn setCallbacks(
    set_fn: *const fn (percent: u8) void,
    get_fn: *const fn () u8,
) void {
    set_brightness_fn = set_fn;
    get_brightness_fn = get_fn;
}

pub fn start(config: mqtt_client.MqttConfig) !void {
    if (mqtt != null) return;

    const client = try allocator.create(mqtt_client.MqttClient);
    client.* = mqtt_client.MqttClient.init(allocator, config);
    client.on_connect = onMqttConnect;
    client.on_message = onMqttMessage;
    mqtt = client;
    try mqtt.?.start();
}

pub fn stop() void {
    if (mqtt) |client| {
        client.stop();
        allocator.destroy(client);
        mqtt = null;
    }
}

fn onMqttConnect() void {
    log.info("MQTT connected — publishing light discovery", .{});
    discovery_published = false;

    const client = mqtt orelse return;

    // Publish discovery config
    publishDiscovery(client);
    discovery_published = true;

    // Subscribe to command topic
    client.subscribe(COMMAND_TOPIC) catch |err| {
        log.warn("Failed to subscribe to MQTT command topic: {}", .{err});
        return;
    };

    // Publish current state
    if (get_brightness_fn) |get| {
        current_percent = get();
    }
    publishState(client, current_percent);
}

fn onMqttMessage(topic: []const u8, payload: []const u8) void {
    log.debug("MQTT message received on {s}: {s}", .{ topic, payload });

    // Parse JSON command
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| {
        log.warn("MQTT command parse error: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    const state_val = root.object.get("state") orelse return;
    if (state_val != .string) return;
    const state = state_val.string;

    var percent: u8 = 0;

    if (std.ascii.eqlIgnoreCase(state, "on")) {
        percent = 100;
        if (root.object.get("brightness")) |b| {
            var ha_brightness: f64 = 255.0;
            switch (b) {
                .integer => |i| ha_brightness = @floatFromInt(i),
                .float => |f| ha_brightness = f,
                else => {},
            }
            const pct = @as(i32, @intFromFloat(@round(ha_brightness * 100.0 / 255.0)));
            percent = @intCast(@max(0, @min(100, pct)));
        }
    } else if (std.ascii.eqlIgnoreCase(state, "off")) {
        percent = 0;
    } else {
        log.warn("MQTT unknown light state: {s}", .{state});
        return;
    }

    current_percent = percent;

    if (set_brightness_fn) |set| {
        set(percent);
    }
}

fn publishDiscovery(client: *mqtt_client.MqttClient) void {
    const config_json =
        \\{"name":"Dashboard Brightness","unique_id":"ha_raspberry_touch_dashboard_brightness","cmd_t":"ha_dashboard/light/dashboard_brightness/set","stat_t":"ha_dashboard/light/dashboard_brightness/state","brightness":true,"schema":"json","device":{"name":"Raspberry Pi Dashboard","identifiers":["ha_raspberry_touch_dashboard"]}}
    ;

    client.publish(DISCOVERY_TOPIC, config_json, true) catch |err| {
        log.warn("Failed to publish MQTT discovery: {}", .{err});
    };
}

fn publishState(client: *mqtt_client.MqttClient, percent: u8) void {
    var buf: [128]u8 = undefined;
    const ha_brightness: u16 = if (percent >= 100) 255 else @intCast(@divTrunc(@as(u32, percent) * 255, 100));
    const json = if (percent == 0)
        "{\"state\":\"OFF\"}"
    else
        std.fmt.bufPrint(&buf, "{{\"state\":\"ON\",\"brightness\":{d}}}", .{ha_brightness}) catch return;

    client.publish(STATE_TOPIC, json, false) catch |err| {
        log.warn("Failed to publish MQTT state: {}", .{err});
    };
}

/// Notify the HA light entity that brightness has changed.
/// Called from main.zig when native/WS brightness changes.
pub fn notifyBrightness(percent: u8) void {
    current_percent = percent;
    if (!discovery_published) return;
    const client = mqtt orelse return;
    if (!client.connected.load(.acquire)) return;
    publishState(client, percent);
}

pub fn isConnected() bool {
    const client = mqtt orelse return false;
    return client.connected.load(.acquire) and discovery_published;
}
