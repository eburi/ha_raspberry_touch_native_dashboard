///! WebSocket handler for real-time Home Assistant state relay.
///!
///! Protocol:
///!   Client → Server: { "type": "get_states" }
///!   Client → Server: { "type": "subscribe", "entity_ids": ["light.living_room"] }
///!   Server → Client: { "type": "state_changed", "entity_id": "...", "state": "..." }
///!   Server → Client: { "type": "states", "data": [...] }

const std = @import("std");
const zap = @import("zap");

var allocator: std.mem.Allocator = undefined;

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;
}

pub fn handleUpgrade(r: zap.Request) !void {
    // For now, just log the upgrade attempt
    // Full WebSocket implementation requires Zap's WebSocket API
    std.log.info("WebSocket upgrade requested from {s}", .{r.path orelse "unknown"});

    // TODO: Implement WebSocket upgrade using Zap's facilities
    // For the initial version, we'll use a simple polling approach via REST
    r.setStatus(.switching_protocols);
    r.setHeader("Upgrade", "websocket") catch {};
    r.setHeader("Connection", "Upgrade") catch {};
    r.sendBody("") catch {};
}
