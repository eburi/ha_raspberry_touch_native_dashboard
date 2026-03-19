///! Home Assistant WebSocket API client.
///!
///! Connects to the HA WebSocket API (ws://supervisor/core/websocket),
///! authenticates with the Supervisor token, subscribes to state changes,
///! and relays them to browser clients via the websocket module.
///!
///! Also provides a REST proxy for calling HA services and fetching states.
///!
///! HA WebSocket API protocol:
///!   1. Server sends:   {"type": "auth_required", "ha_version": "..."}
///!   2. Client sends:   {"type": "auth", "access_token": "..."}
///!   3. Server sends:   {"type": "auth_ok", ...} or {"type": "auth_invalid", ...}
///!   4. Client sends:   {"id": N, "type": "subscribe_events", "event_type": "state_changed"}
///!   5. Server sends:   {"id": N, "type": "result", "success": true}
///!   6. Server sends:   {"id": N, "type": "event", "event": {"event_type": "state_changed", ...}}
///!   7. Client sends:   {"id": N, "type": "get_states"} for initial state fetch
const std = @import("std");
const websocket = @import("websocket.zig");

const log = std.log.scoped(.ha_client);

/// HA client configuration.
pub const HaConfig = struct {
    /// The HA API base URL (e.g., "http://supervisor/core/api")
    ha_url: []const u8 = "http://supervisor/core/api",
    /// The supervisor/long-lived access token
    token: ?[]const u8 = null,
};

var config: HaConfig = .{};
var allocator: std.mem.Allocator = undefined;

/// Cached entity states: entity_id -> state string
var state_cache: std.StringHashMap([]const u8) = undefined;
var state_cache_mutex: std.Thread.Mutex = .{};

/// Next message ID for HA WebSocket API
var next_msg_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

/// Track the subscription ID for state_changed events
var subscribe_event_id: u32 = 0;

/// Track the entity registry request ID
var entity_registry_id: u32 = 0;

/// Counter for state_changed events (for periodic logging)
var state_change_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// The HA WebSocket connection thread
var ha_ws_thread: ?std.Thread = null;

/// Flag to stop the connection thread
var should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Initialize the HA client module.
pub fn init(alloc: std.mem.Allocator, ha_config: HaConfig) void {
    allocator = alloc;
    config = ha_config;
    state_cache = std.StringHashMap([]const u8).init(alloc);
}

/// Start the background thread that maintains the HA WebSocket connection.
pub fn start() !void {
    if (config.token == null) {
        log.warn("No HA token configured — HA integration disabled", .{});
        return;
    }

    should_stop.store(false, .release);
    ha_ws_thread = try std.Thread.spawn(.{}, haConnectionLoop, .{});
}

/// Stop the HA client and clean up.
pub fn stop() void {
    should_stop.store(true, .release);
    if (ha_ws_thread) |thread| {
        thread.join();
        ha_ws_thread = null;
    }
}

/// Release all resources owned by the HA client module.
/// Must be called after stop() and before the allocator is torn down.
pub fn deinit() void {
    // Free cached bulk states JSON
    {
        cached_states_mutex.lock();
        defer cached_states_mutex.unlock();
        if (cached_states_json) |json| {
            allocator.free(json);
            cached_states_json = null;
        }
    }

    // Free cached entity registry JSON
    {
        cached_entity_registry_mutex.lock();
        defer cached_entity_registry_mutex.unlock();
        if (cached_entity_registry_json) |json| {
            allocator.free(json);
            cached_entity_registry_json = null;
        }
    }

    // Free all entries in the state cache
    {
        state_cache_mutex.lock();
        defer state_cache_mutex.unlock();

        var it = state_cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        state_cache.deinit();
    }
}

/// The main connection loop — connects, authenticates, subscribes, and
/// processes messages. Reconnects on failure with exponential backoff.
fn haConnectionLoop() void {
    var backoff_ms: u64 = 1000;
    const max_backoff_ms: u64 = 30000;

    while (!should_stop.load(.acquire)) {
        log.info("Connecting to Home Assistant...", .{});

        haSession() catch |err| {
            log.err("HA session error: {}", .{err});
        };

        if (should_stop.load(.acquire)) break;

        log.info("Reconnecting in {d}ms...", .{backoff_ms});
        std.time.sleep(backoff_ms * std.time.ns_per_ms);
        backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
    }
}

/// Run a single HA WebSocket session: connect, auth, subscribe, read loop.
fn haSession() !void {
    // Derive WebSocket URL from ha_url
    // e.g., "http://supervisor/core/api" -> "ws://supervisor/core/websocket"
    const ws_url = deriveWsUrl(config.ha_url) catch |err| {
        log.err("Failed to derive WS URL from {s}: {}", .{ config.ha_url, err });
        return err;
    };
    defer allocator.free(ws_url);

    log.info("Connecting to HA WebSocket at {s}", .{ws_url});

    // Parse the URL
    const uri = std.Uri.parse(ws_url) catch |err| {
        log.err("Failed to parse WS URL: {}", .{err});
        return err;
    };

    // Determine host and port
    const host_component = uri.host orelse {
        log.err("No host in WS URL", .{});
        return error.InvalidUrl;
    };
    const host = switch (host_component) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };

    const is_https = std.mem.eql(u8, uri.scheme, "wss") or std.mem.eql(u8, uri.scheme, "https");
    _ = is_https;
    const port: u16 = if (uri.port) |p| p else if (std.mem.eql(u8, uri.scheme, "wss") or std.mem.eql(u8, uri.scheme, "https")) 443 else 80;

    // Build the path
    const path = switch (uri.path) {
        .raw => |v| if (v.len > 0) v else "/",
        .percent_encoded => |v| if (v.len > 0) v else "/",
    };

    // Use std.http.Client for the HTTP upgrade
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // We need to use a raw TCP connection + manual WebSocket handshake
    // because std.http.Client doesn't directly support WebSocket upgrade.
    // Use std.net for the TCP connection.
    const addr = std.net.Address.resolveIp(host, port) catch blk: {
        // Try DNS resolution
        const list = try std.net.getAddressList(allocator, host, port);
        defer list.deinit();
        if (list.addrs.len == 0) return error.DnsResolutionFailed;
        break :blk list.addrs[0];
    };

    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    // Perform WebSocket handshake manually
    const ws_key = "dGhlIHNhbXBsZSBub25jZQ=="; // base64 of a fixed nonce (fine for local use)

    var handshake_buf: [2048]u8 = undefined;
    const handshake = std.fmt.bufPrint(
        &handshake_buf,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{ path, host, port, ws_key },
    ) catch return error.HandshakeBufferTooSmall;

    _ = try stream.write(handshake);

    // Read the HTTP response (looking for 101 Switching Protocols)
    var resp_buf: [4096]u8 = undefined;
    const resp_len = try stream.read(&resp_buf);
    if (resp_len == 0) return error.ConnectionClosed;

    const resp = resp_buf[0..resp_len];
    if (!std.mem.startsWith(u8, resp, "HTTP/1.1 101")) {
        log.err("HA WebSocket handshake failed: {s}", .{resp[0..@min(resp.len, 100)]});
        return error.HandshakeFailed;
    }

    log.info("HA WebSocket handshake successful", .{});

    // Now we have a raw WebSocket connection. Run the message loop.
    try wsMessageLoop(stream);
}

/// WebSocket message loop — handle framing, auth, subscriptions.
fn wsMessageLoop(stream: std.net.Stream) !void {
    // Authentication state
    var authenticated = false;
    var subscribed = false;
    var last_summary_time: i64 = std.time.timestamp();

    while (!should_stop.load(.acquire)) {
        // Read a WebSocket frame (heap-allocated for large payloads)
        const frame = readWsFrame(stream) catch |err| {
            if (err == error.ConnectionClosed or err == error.WouldBlock) {
                log.info("HA WebSocket connection closed", .{});
                return err;
            }
            log.err("WS frame read error: {}", .{err});
            return err;
        };
        defer allocator.free(frame.payload);

        switch (frame.opcode) {
            0x1, 0x2 => { // Text or Binary frame
                handleHaMessage(frame.payload, stream, &authenticated, &subscribed) catch |err| {
                    log.err("HA message handling error: {}", .{err});
                };
            },
            0x8 => { // Close
                log.info("HA WebSocket received close frame", .{});
                return error.ConnectionClosed;
            },
            0x9 => { // Ping
                // Send pong
                sendWsFrame(stream, 0xA, frame.payload) catch |err| {
                    log.err("Failed to send pong: {}", .{err});
                };
            },
            0xA => { // Pong — ignore
            },
            else => {
                log.warn("Unknown WS opcode: {d}", .{frame.opcode});
            },
        }

        // Periodic summary log (every 60 seconds)
        const now = std.time.timestamp();
        if (now - last_summary_time >= 60) {
            const count = state_change_count.swap(0, .monotonic);
            if (count > 0) {
                log.info("HA: relayed {d} state changes in the last {d}s", .{ count, now - last_summary_time });
            }
            last_summary_time = now;
        }
    }
}

const WsFrame = struct {
    opcode: u4,
    /// Heap-allocated payload — caller must free with allocator.free().
    payload: []u8,
};

/// Maximum payload size we'll accept (4 MB — HA get_states can be large).
const MAX_PAYLOAD_SIZE: usize = 4 * 1024 * 1024;

/// Read a single WebSocket frame from the stream.
/// Returns a heap-allocated payload that the caller must free.
fn readWsFrame(stream: std.net.Stream) !WsFrame {
    // Read the first 2 bytes (FIN, opcode, MASK, payload length)
    var header: [2]u8 = undefined;
    try readExact(stream, &header);

    const opcode: u4 = @truncate(header[0] & 0x0F);
    const masked = (header[1] & 0x80) != 0;
    var payload_len: u64 = header[1] & 0x7F;

    // Extended payload length
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }

    // Masking key (server-to-client messages should not be masked, but handle it)
    var mask_key: [4]u8 = undefined;
    if (masked) {
        try readExact(stream, &mask_key);
    }

    // Sanity check payload size
    if (payload_len > MAX_PAYLOAD_SIZE) {
        log.err("WS frame payload too large: {d} bytes (max {d})", .{ payload_len, MAX_PAYLOAD_SIZE });
        return error.PayloadTooLarge;
    }
    const len: usize = @intCast(payload_len);

    // Heap-allocate the payload buffer
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    // Read payload fully
    var total_read: usize = 0;
    while (total_read < len) {
        const r = try stream.read(buf[total_read..len]);
        if (r == 0) return error.ConnectionClosed;
        total_read += r;
    }

    // Unmask if needed
    if (masked) {
        for (0..len) |i| {
            buf[i] ^= mask_key[i % 4];
        }
    }

    return .{
        .opcode = opcode,
        .payload = buf,
    };
}

/// Read exactly `buf.len` bytes from the stream, or return ConnectionClosed.
fn readExact(stream: std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

/// Send a WebSocket frame. Client-to-server frames MUST be masked.
fn sendWsFrame(stream: std.net.Stream, opcode: u8, payload: []const u8) !void {
    var frame_buf: [65546]u8 = undefined; // max payload + 14 bytes header
    var pos: usize = 0;

    // FIN bit + opcode
    frame_buf[pos] = 0x80 | @as(u8, opcode);
    pos += 1;

    // Mask bit (1 for client) + payload length
    const mask_bit: u8 = 0x80;
    if (payload.len < 126) {
        frame_buf[pos] = mask_bit | @as(u8, @intCast(payload.len));
        pos += 1;
    } else if (payload.len <= 65535) {
        frame_buf[pos] = mask_bit | 126;
        pos += 1;
        std.mem.writeInt(u16, frame_buf[pos..][0..2], @intCast(payload.len), .big);
        pos += 2;
    } else {
        frame_buf[pos] = mask_bit | 127;
        pos += 1;
        std.mem.writeInt(u64, frame_buf[pos..][0..8], @intCast(payload.len), .big);
        pos += 8;
    }

    // Masking key (use a simple key for local HA communication)
    const mask_key = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    @memcpy(frame_buf[pos..][0..4], &mask_key);
    pos += 4;

    // Masked payload
    if (payload.len + pos > frame_buf.len) return error.PayloadTooLarge;
    for (0..payload.len) |i| {
        frame_buf[pos + i] = payload[i] ^ mask_key[i % 4];
    }
    pos += payload.len;

    // Write entire frame
    var total_written: usize = 0;
    while (total_written < pos) {
        const written = try stream.write(frame_buf[total_written..pos]);
        if (written == 0) return error.ConnectionClosed;
        total_written += written;
    }
}

/// Handle a message received from Home Assistant's WebSocket API.
fn handleHaMessage(message: []const u8, stream: std.net.Stream, authenticated: *bool, subscribed: *bool) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch |err| {
        log.warn("HA: invalid JSON: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    const msg_type_val = root.object.get("type") orelse return;
    if (msg_type_val != .string) return;
    const msg_type = msg_type_val.string;

    if (std.mem.eql(u8, msg_type, "auth_required")) {
        // Send authentication
        log.info("HA: auth_required, sending token...", .{});
        const token = config.token orelse return error.NoToken;
        const auth_msg = std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"auth\",\"access_token\":\"{s}\"}}",
            .{token},
        ) catch return;
        defer allocator.free(auth_msg);
        try sendWsFrame(stream, 0x1, auth_msg);
    } else if (std.mem.eql(u8, msg_type, "auth_ok")) {
        log.info("HA: authenticated successfully", .{});
        authenticated.* = true;

        // Fetch initial states
        const states_id = next_msg_id.fetchAdd(1, .monotonic);
        const states_msg = std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"type\":\"get_states\"}}",
            .{states_id},
        ) catch return;
        defer allocator.free(states_msg);
        try sendWsFrame(stream, 0x1, states_msg);

        // Subscribe to state_changed events
        subscribe_event_id = next_msg_id.fetchAdd(1, .monotonic);
        const sub_msg = std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"type\":\"subscribe_events\",\"event_type\":\"state_changed\"}}",
            .{subscribe_event_id},
        ) catch return;
        defer allocator.free(sub_msg);
        try sendWsFrame(stream, 0x1, sub_msg);

        // Fetch entity registry for display precision
        entity_registry_id = next_msg_id.fetchAdd(1, .monotonic);
        const reg_msg = std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"type\":\"config/entity_registry/list_for_display\"}}",
            .{entity_registry_id},
        ) catch return;
        defer allocator.free(reg_msg);
        try sendWsFrame(stream, 0x1, reg_msg);
    } else if (std.mem.eql(u8, msg_type, "auth_invalid")) {
        log.err("HA: authentication failed — check SUPERVISOR_TOKEN", .{});
        return error.AuthFailed;
    } else if (std.mem.eql(u8, msg_type, "result")) {
        // Response to a command (get_states, subscribe_events, entity_registry)
        const success = if (root.object.get("success")) |v| (v == .bool and v.bool) else false;
        if (!success) {
            log.warn("HA: command failed: {s}", .{message[0..@min(message.len, 200)]});
            return;
        }

        // Check the message ID to route to the right handler
        const msg_id: u32 = if (root.object.get("id")) |v| switch (v) {
            .integer => |i| if (i >= 0) @intCast(i) else 0,
            else => 0,
        } else 0;

        if (msg_id == entity_registry_id and entity_registry_id != 0) {
            // Entity registry response
            if (root.object.get("result")) |result_val| {
                if (result_val == .object) {
                    handleEntityRegistryResult(result_val.object);
                }
            }
        } else if (root.object.get("result")) |result_val| {
            // Check if this is the get_states result
            if (result_val == .array) {
                handleStatesResult(result_val.array);
                subscribed.* = true;
            }
        }
    } else if (std.mem.eql(u8, msg_type, "event")) {
        // State change event
        if (root.object.get("event")) |event_val| {
            if (event_val == .object) {
                handleStateChangedEvent(event_val.object);
            }
        }
    } else if (std.mem.eql(u8, msg_type, "pong")) {
        // Response to ping — ignore
    } else {
        log.debug("HA: unhandled message type: {s}", .{msg_type});
    }
}

/// Process the result of a get_states call — cache all entity states
/// and broadcast them to browser clients.
fn handleStatesResult(states: std.json.Array) void {
    var states_json = std.ArrayList(u8).init(allocator);
    defer states_json.deinit();

    states_json.appendSlice("{\"type\":\"states\",\"data\":[") catch return;
    var first = true;

    for (states.items) |item| {
        if (item != .object) continue;

        const entity_id_val = item.object.get("entity_id") orelse continue;
        if (entity_id_val != .string) continue;
        const entity_id = entity_id_val.string;

        const state_val = item.object.get("state") orelse continue;
        if (state_val != .string) continue;
        const state = state_val.string;

        // Update cache
        cacheState(entity_id, state);

        // Add to bulk message — serialize the full state object
        if (!first) states_json.append(',') catch continue;
        first = false;

        std.json.stringify(item, .{}, states_json.writer()) catch continue;
    }

    states_json.appendSlice("]}") catch return;

    // Cache the full JSON for new clients
    cacheStatesJson(states_json.items);

    // Broadcast to all connected browser clients
    websocket.broadcastStates(states_json.items);

    log.info("HA: received {d} entity states", .{states.items.len});
}

/// Process the result of a config/entity_registry/list_for_display call.
/// Extracts display precision (dp) for each entity and builds a compact
/// JSON message: {"type":"entity_registry","data":{"entity_id":dp,...}}
fn handleEntityRegistryResult(result: std.json.ObjectMap) void {
    const entities_val = result.get("entities") orelse {
        log.warn("HA: entity registry result has no 'entities' field", .{});
        return;
    };
    if (entities_val != .array) return;
    const entities = entities_val.array;

    // Build a compact JSON with just entity_id -> display_precision mapping
    var json_buf = std.ArrayList(u8).init(allocator);
    defer json_buf.deinit();

    json_buf.appendSlice("{\"type\":\"entity_registry\",\"data\":{") catch return;
    var first = true;
    var count: usize = 0;

    for (entities.items) |item| {
        if (item != .object) continue;

        // "ei" = entity_id (abbreviated key from HA)
        const ei_val = item.object.get("ei") orelse continue;
        if (ei_val != .string) continue;
        const entity_id = ei_val.string;

        // "dp" = display_precision (abbreviated key from HA)
        const dp_val = item.object.get("dp") orelse continue;
        const dp: i64 = switch (dp_val) {
            .integer => |i| i,
            else => continue,
        };

        if (!first) json_buf.append(',') catch continue;
        first = false;

        std.fmt.format(json_buf.writer(), "\"{s}\":{d}", .{ entity_id, dp }) catch continue;
        count += 1;
    }

    json_buf.appendSlice("}}") catch return;

    // Cache for new clients
    cacheEntityRegistryJson(json_buf.items);

    // Broadcast to all connected browser clients
    websocket.broadcastRaw(json_buf.items);

    log.info("HA: entity registry received, {d} entities with display precision", .{count});
}

/// Process a single state_changed event from HA.
fn handleStateChangedEvent(event: std.json.ObjectMap) void {
    const data = event.get("data") orelse return;
    if (data != .object) return;

    const new_state = data.object.get("new_state") orelse return;
    if (new_state != .object) return;

    const entity_id_val = new_state.object.get("entity_id") orelse return;
    if (entity_id_val != .string) return;
    const entity_id = entity_id_val.string;

    const state_val = new_state.object.get("state") orelse return;
    if (state_val != .string) return;
    const state = state_val.string;

    // Update cache
    cacheState(entity_id, state);

    // Serialize the new_state object to JSON for the browser
    var json_buf = std.ArrayList(u8).init(allocator);
    defer json_buf.deinit();
    std.json.stringify(std.json.Value{ .object = new_state.object }, .{}, json_buf.writer()) catch |err| {
        log.err("HA: failed to serialize new_state: {}", .{err});
        return;
    };

    // Broadcast to all connected browser clients
    websocket.broadcastStateChange(entity_id, json_buf.items);

    _ = state_change_count.fetchAdd(1, .monotonic);
    log.debug("HA: state_changed {s} = {s}", .{ entity_id, state });
}

/// Cache an entity state (thread-safe).
fn cacheState(entity_id: []const u8, state: []const u8) void {
    state_cache_mutex.lock();
    defer state_cache_mutex.unlock();

    // Free old state if present
    if (state_cache.getEntry(entity_id)) |entry| {
        allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = allocator.dupe(u8, state) catch return;
    } else {
        const key = allocator.dupe(u8, entity_id) catch return;
        const val = allocator.dupe(u8, state) catch {
            allocator.free(key);
            return;
        };
        state_cache.put(key, val) catch {
            allocator.free(key);
            allocator.free(val);
        };
    }
}

/// Cached bulk states JSON (for sending to newly connected clients).
var cached_states_json: ?[]const u8 = null;
var cached_states_mutex: std.Thread.Mutex = .{};

fn cacheStatesJson(json: []const u8) void {
    cached_states_mutex.lock();
    defer cached_states_mutex.unlock();

    if (cached_states_json) |old| {
        allocator.free(old);
    }
    cached_states_json = allocator.dupe(u8, json) catch null;
}

/// Get the cached bulk states JSON. Returns null if no states are cached yet.
pub fn getCachedStatesJson() ?[]const u8 {
    cached_states_mutex.lock();
    defer cached_states_mutex.unlock();
    return cached_states_json;
}

/// Cached entity registry JSON (for sending to newly connected clients).
var cached_entity_registry_json: ?[]const u8 = null;
var cached_entity_registry_mutex: std.Thread.Mutex = .{};

fn cacheEntityRegistryJson(json: []const u8) void {
    cached_entity_registry_mutex.lock();
    defer cached_entity_registry_mutex.unlock();

    if (cached_entity_registry_json) |old| {
        allocator.free(old);
    }
    cached_entity_registry_json = allocator.dupe(u8, json) catch null;
}

/// Get the cached entity registry JSON. Returns null if not yet fetched.
pub fn getCachedEntityRegistryJson() ?[]const u8 {
    cached_entity_registry_mutex.lock();
    defer cached_entity_registry_mutex.unlock();
    return cached_entity_registry_json;
}

/// Call an HA service via the REST API.
pub fn callService(domain: []const u8, service: []const u8, service_data: ?std.json.Value) !void {
    const token = config.token orelse return error.NoToken;

    // Build the URL: {ha_url}/services/{domain}/{service}
    const url_str = try std.fmt.allocPrint(
        allocator,
        "{s}/services/{s}/{s}",
        .{ config.ha_url, domain, service },
    );
    defer allocator.free(url_str);

    const uri = try std.Uri.parse(url_str);

    // Build request body
    var body_buf = std.ArrayList(u8).init(allocator);
    defer body_buf.deinit();

    if (service_data) |data| {
        std.json.stringify(data, .{}, body_buf.writer()) catch {
            try body_buf.appendSlice("{}");
        };
    } else {
        try body_buf.appendSlice("{}");
    }

    // Make HTTP request using std.http.Client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build auth header value
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var server_header_buf: [8192]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body_buf.items.len };
    try req.send();
    try req.writer().writeAll(body_buf.items);
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        log.err("HA service call failed with status: {}", .{req.response.status});
        return error.ServiceCallFailed;
    }

    log.info("HA: service call {s}.{s} succeeded", .{ domain, service });
}

/// Proxy an arbitrary GET request to the HA API and return the response body.
pub fn proxyGet(path: []const u8) ![]const u8 {
    const token = config.token orelse return error.NoToken;

    const url_str = try std.fmt.allocPrint(allocator, "{s}{s}", .{ config.ha_url, path });
    defer allocator.free(url_str);

    const uri = try std.Uri.parse(url_str);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var server_header_buf: [8192]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
        },
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        log.err("HA proxy GET {s} failed with status: {}", .{ path, req.response.status });
        return error.ProxyRequestFailed;
    }

    // Read response body
    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try req.reader().read(&buf);
        if (n == 0) break;
        try body.appendSlice(buf[0..n]);
    }

    return body.toOwnedSlice();
}

/// Proxy an arbitrary POST request to the HA API.
pub fn proxyPost(path: []const u8, request_body: []const u8) ![]const u8 {
    const token = config.token orelse return error.NoToken;

    const url_str = try std.fmt.allocPrint(allocator, "{s}{s}", .{ config.ha_url, path });
    defer allocator.free(url_str);

    const uri = try std.Uri.parse(url_str);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var server_header_buf: [8192]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = request_body.len };
    try req.send();
    try req.writer().writeAll(request_body);
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        log.err("HA proxy POST {s} failed with status: {}", .{ path, req.response.status });
        return error.ProxyRequestFailed;
    }

    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try req.reader().read(&buf);
        if (n == 0) break;
        try body.appendSlice(buf[0..n]);
    }

    return body.toOwnedSlice();
}

/// Derive the WebSocket URL from the HA REST API URL.
/// e.g., "http://supervisor/core/api" -> "ws://supervisor/core/websocket"
fn deriveWsUrl(ha_url: []const u8) ![]const u8 {
    // Replace "http://" with "ws://" or "https://" with "wss://"
    var scheme: []const u8 = "ws://";
    var rest: []const u8 = ha_url;

    if (std.mem.startsWith(u8, ha_url, "https://")) {
        scheme = "wss://";
        rest = ha_url[8..];
    } else if (std.mem.startsWith(u8, ha_url, "http://")) {
        scheme = "ws://";
        rest = ha_url[7..];
    } else {
        return error.InvalidScheme;
    }

    // Strip trailing "/api" if present and replace with "/websocket"
    if (std.mem.endsWith(u8, rest, "/api")) {
        const base = rest[0 .. rest.len - 4];
        return std.fmt.allocPrint(allocator, "{s}{s}/websocket", .{ scheme, base });
    }

    // Otherwise just append /websocket
    return std.fmt.allocPrint(allocator, "{s}{s}/websocket", .{ scheme, rest });
}
