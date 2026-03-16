///! REST API route handlers.
///!
///! Endpoints:
///!   GET  /api/health       -> {"status": "ok"}
///!   GET  /api/config       -> App configuration (sanitized, no tokens)
///!   GET  /api/ha/states    -> Proxy to Home Assistant states API
///!   POST /api/ha/services  -> Proxy to Home Assistant services API
///!   *    /api/ha/*         -> Generic proxy to HA REST API

const std = @import("std");
const zap = @import("zap");

const Config = @import("main.zig").Config;
const ha_client = @import("ha_client.zig");

var allocator: std.mem.Allocator = undefined;

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;
}

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
    if (config.supervisor_token == null) {
        r.setStatus(.service_unavailable);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"no supervisor token available\"}") catch {};
        return;
    }

    // Map /api/ha/* to HA API path: /api/ha/states -> /states
    const ha_path = path[7..]; // Strip "/api/ha"

    // Determine method from request
    const method = r.method orelse "GET";

    if (std.mem.eql(u8, method, "GET")) {
        const body = ha_client.proxyGet(ha_path) catch |err| {
            std.log.err("HA proxy GET {s} failed: {}", .{ ha_path, err });
            r.setStatus(.bad_gateway);
            r.setHeader("Content-Type", "application/json") catch {};
            r.sendBody("{\"error\":\"HA proxy request failed\"}") catch {};
            return;
        };
        defer allocator.free(body);

        r.setStatus(.ok);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody(body) catch {};
    } else if (std.mem.eql(u8, method, "POST")) {
        const request_body = r.body orelse "{}";

        const body = ha_client.proxyPost(ha_path, request_body) catch |err| {
            std.log.err("HA proxy POST {s} failed: {}", .{ ha_path, err });
            r.setStatus(.bad_gateway);
            r.setHeader("Content-Type", "application/json") catch {};
            r.sendBody("{\"error\":\"HA proxy request failed\"}") catch {};
            return;
        };
        defer allocator.free(body);

        r.setStatus(.ok);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody(body) catch {};
    } else {
        r.setStatus(.method_not_allowed);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"method not allowed\"}") catch {};
    }
}
