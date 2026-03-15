///! REST API route handlers.
///!
///! Endpoints:
///!   GET /api/health       → {"status": "ok"}
///!   GET /api/config       → App configuration (sanitized, no tokens)
///!   GET /api/ha/states    → Proxy to Home Assistant states API
///!   POST /api/ha/services → Proxy to Home Assistant services API

const std = @import("std");
const zap = @import("zap");

const Config = @import("main.zig").Config;

pub fn handleApi(r: zap.Request, config: *const Config) !void {
    const path = r.path orelse return;

    if (std.mem.eql(u8, path, "/api/health")) {
        return handleHealth(r);
    }

    if (std.mem.eql(u8, path, "/api/config")) {
        return handleConfig(r, config);
    }

    if (std.mem.startsWith(u8, path, "/api/ha/")) {
        return handleHaProxy(r, path, config);
    }

    r.setStatus(.not_found);
    try r.sendBody("{\"error\":\"not found\"}");
}

fn handleHealth(r: zap.Request) void {
    r.setStatus(.ok);
    r.setHeader("Content-Type", "application/json") catch {};
    r.sendBody("{\"status\":\"ok\",\"service\":\"lvgl-dashboard\"}") catch {};
}

fn handleConfig(r: zap.Request, config: *const Config) void {
    _ = config;
    r.setStatus(.ok);
    r.setHeader("Content-Type", "application/json") catch {};
    r.sendBody(
        \\{"display":{"width":1280,"height":720},"version":"0.1.0"}
    ) catch {};
}

fn handleHaProxy(r: zap.Request, path: []const u8, config: *const Config) void {
    const token = config.supervisor_token orelse {
        r.setStatus(.service_unavailable);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"no supervisor token available\"}") catch {};
        return;
    };

    // Map /api/ha/* to HA API path
    const ha_path = path[7..]; // Strip "/api/ha"
    _ = ha_path;
    _ = token;

    // TODO: Implement HTTP client proxy to HA API
    // For now, return a placeholder
    r.setStatus(.ok);
    r.setHeader("Content-Type", "application/json") catch {};
    r.sendBody("{\"message\":\"HA API proxy not yet implemented\"}") catch {};
}
