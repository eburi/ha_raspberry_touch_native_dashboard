///! WebSocket handler for real-time Home Assistant state relay.
///!
///! Uses Zap's WebSockets.Handler API (backed by facil.io) for the
///! server↔browser WebSocket connections. Uses facil.io pub/sub channels
///! to broadcast HA state changes to all connected browser clients.
///!
///! Protocol (browser ↔ server):
///!   Client → Server: { "type": "subscribe", "entities": ["sensor.foo", ...] }
///!   Client → Server: { "type": "get_states" }
///!   Client → Server: { "type": "call_service", "domain": "...", "service": "...", "service_data": {...} }
///!   Server → Client: { "type": "state_changed", "entity_id": "...", "state": "..." }
///!   Server → Client: { "type": "states", "data": [{...}, ...] }

const std = @import("std");
const zap = @import("zap");

const ha_client = @import("ha_client.zig");

/// The WsHandle type from Zap's WebSocket module.
const WsHandle = zap.WebSockets.WsHandle;

/// Per-connection context stored in facil.io's udata.
const ClientContext = struct {
    allocator: std.mem.Allocator,
    settings: WsHandler.WebSocketSettings,
    handle: WsHandle = null,
};

/// Instantiate Zap's WebSocket handler with our context type.
const WsHandler = zap.WebSockets.Handler(ClientContext);

/// Module-level allocator, set by init().
var allocator: std.mem.Allocator = undefined;

/// facil.io pub/sub channel name for broadcasting state changes to all clients.
const BROADCAST_CHANNEL = "ha_states";

/// Initialize the WebSocket module.
pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;
}

/// Called from the HTTP on_upgrade callback in main.zig when a WebSocket
/// upgrade is detected on /ws.
pub fn handleUpgrade(r: zap.Request) void {
    // Create per-connection context (heap-allocated, freed in on_close)
    var context = allocator.create(ClientContext) catch |err| {
        std.log.err("WS: failed to allocate client context: {}", .{err});
        r.setStatus(.internal_server_error);
        r.sendBody("Internal server error") catch {};
        return;
    };

    context.* = .{
        .allocator = allocator,
        .settings = .{
            .on_open = onOpen,
            .on_message = onMessage,
            .on_close = onClose,
            .context = context,
        },
    };

    WsHandler.upgrade(r.h, &context.settings) catch |err| {
        std.log.err("WS: upgrade failed: {}", .{err});
        allocator.destroy(context);
        r.setStatus(.bad_request);
        r.sendBody("WebSocket upgrade failed") catch {};
    };
}

/// Called when a new WebSocket connection is established.
fn onOpen(context: ?*ClientContext, handle: WsHandle) anyerror!void {
    if (context) |ctx| {
        ctx.handle = handle;
        std.log.info("WS: client connected", .{});

        // Subscribe to broadcast channel using facil.io pub/sub.
        // When on_message is null, messages are forwarded directly to the client.
        var sub_args = WsHandler.SubscribeArgs{
            .channel = BROADCAST_CHANNEL,
            .force_text = true,
        };
        _ = WsHandler.subscribe(handle, &sub_args) catch |err| {
            std.log.err("WS: failed to subscribe to broadcast channel: {}", .{err});
        };
    }
}

/// Called when a message is received from a browser client.
fn onMessage(context: ?*ClientContext, handle: WsHandle, message: []const u8, is_text: bool) anyerror!void {
    _ = is_text;
    _ = context;

    // Parse JSON message
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch |err| {
        std.log.warn("WS: invalid JSON from client: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    const msg_type = root.object.get("type") orelse return;
    if (msg_type != .string) return;

    const type_str = msg_type.string;

    if (std.mem.eql(u8, type_str, "get_states")) {
        handleGetStates(handle);
    } else if (std.mem.eql(u8, type_str, "subscribe")) {
        // Client wants to subscribe to specific entities.
        // For now, all clients get all state changes via the broadcast channel.
        // The client-side JS already filters by entity_id.
        std.log.info("WS: client subscribed to entities", .{});

        // Send current states immediately
        handleGetStates(handle);
    } else if (std.mem.eql(u8, type_str, "call_service")) {
        handleCallService(root.object);
    } else {
        std.log.warn("WS: unknown message type: {s}", .{type_str});
    }
}

/// Called when a WebSocket connection is closed.
fn onClose(context: ?*ClientContext, uuid: isize) anyerror!void {
    _ = uuid;
    if (context) |ctx| {
        std.log.info("WS: client disconnected", .{});
        ctx.allocator.destroy(ctx);
    }
}

/// Handle "get_states" — send current cached states to this client.
fn handleGetStates(handle: WsHandle) void {
    const states_json = ha_client.getCachedStatesJson() orelse {
        // No states available yet — send empty
        const empty = "{\"type\":\"states\",\"data\":[]}";
        WsHandler.write(handle, empty, true) catch |err| {
            std.log.err("WS: failed to send empty states: {}", .{err});
        };
        return;
    };

    WsHandler.write(handle, states_json, true) catch |err| {
        std.log.err("WS: failed to send states: {}", .{err});
    };
}

/// Handle "call_service" — forward to HA via the HA client.
fn handleCallService(obj: std.json.ObjectMap) void {
    const domain = if (obj.get("domain")) |v| (if (v == .string) v.string else null) else null;
    const service = if (obj.get("service")) |v| (if (v == .string) v.string else null) else null;

    if (domain == null or service == null) {
        std.log.warn("WS: call_service missing domain or service", .{});
        return;
    }

    // Extract service_data
    const service_data = obj.get("service_data");

    std.log.info("WS: call_service {s}.{s}", .{ domain.?, service.? });

    ha_client.callService(domain.?, service.?, service_data) catch |err| {
        std.log.err("WS: call_service failed: {}", .{err});
    };
}

/// Broadcast a state_changed message to ALL connected WebSocket clients.
/// Called by the HA client module when it receives a state change from HA.
/// `new_state_json` is the full serialized new_state object from HA.
pub fn broadcastStateChange(entity_id: []const u8, new_state_json: []const u8) void {
    // Build JSON: {"type":"state_changed","entity_id":"...","data":<new_state_json>}
    const json = std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"state_changed\",\"entity_id\":\"{s}\",\"data\":{s}}}",
        .{ entity_id, new_state_json },
    ) catch |err| {
        std.log.err("WS: failed to format state_changed JSON: {}", .{err});
        return;
    };
    defer allocator.free(json);

    // Publish to the facil.io channel — all subscribed clients receive it
    WsHandler.publish(.{
        .channel = BROADCAST_CHANNEL,
        .message = json,
    });
}

/// Broadcast a bulk states message to all clients.
pub fn broadcastStates(json: []const u8) void {
    WsHandler.publish(.{
        .channel = BROADCAST_CHANNEL,
        .message = json,
    });
}
