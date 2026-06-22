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
const native_display = @import("native_display");

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

    if (std.mem.eql(u8, path, "/api/brightness")) {
        return handleBrightnessGet(r);
    }

    if (std.mem.eql(u8, path, "/api/brightness/set")) {
        return handleBrightnessSet(r);
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
    var buf: [4096]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"display":{{"width":1280,"height":720}},"version":"0.7.1","entities":{s}}}
    , .{config.entity_config_json}) catch {
        r.setStatus(.internal_server_error);
        r.sendBody("{\"error\":\"config too large\"}") catch {};
        return;
    };
    r.setStatus(.ok);
    r.setHeader("Content-Type", "application/json") catch {};
    r.sendBody(json) catch {};
}

fn handleBrightnessGet(r: zap.Request) void {
    const state = native_display.getBrightnessState();

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"available\":{s},\"percent\":{d}}}",
        .{ if (state.available) "true" else "false", state.percent },
    ) catch {
        r.setStatus(.internal_server_error);
        r.sendBody("{\"error\":\"brightness response too large\"}") catch {};
        return;
    };

    r.setStatus(.ok);
    r.setHeader("Content-Type", "application/json") catch {};
    r.sendBody(json) catch {};
}

fn handleBrightnessSet(r: zap.Request) void {
    const method = r.method orelse "GET";
    if (!std.mem.eql(u8, method, "POST")) {
        r.setStatus(.method_not_allowed);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const body = r.body orelse "{}";
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        r.setStatus(.bad_request);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"invalid json\"}") catch {};
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        r.setStatus(.bad_request);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"invalid payload\"}") catch {};
        return;
    }

    const percent_val = parsed.value.object.get("percent") orelse {
        r.setStatus(.bad_request);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"missing percent\"}") catch {};
        return;
    };

    const percent = parsePercent(percent_val) orelse {
        r.setStatus(.bad_request);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"percent must be 0..100\"}") catch {};
        return;
    };

    native_display.setBrightnessPercent(percent) catch |err| {
        std.log.warn("API brightness set failed: {}", .{err});
        r.setStatus(.service_unavailable);
        r.setHeader("Content-Type", "application/json") catch {};
        r.sendBody("{\"error\":\"brightness unavailable\"}") catch {};
        return;
    };

    const state = native_display.getBrightnessState();
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"available\":{s},\"percent\":{d}}}",
        .{ if (state.available) "true" else "false", state.percent },
    ) catch {
        r.setStatus(.internal_server_error);
        r.sendBody("{\"error\":\"brightness response too large\"}") catch {};
        return;
    };

    r.setStatus(.ok);
    r.setHeader("Content-Type", "application/json") catch {};
    r.sendBody(json) catch {};
}

fn parsePercent(v: std.json.Value) ?u8 {
    const n: i32 = switch (v) {
        .integer => |i| std.math.cast(i32, i) orelse return null,
        .float => |f| blk: {
            if (!std.math.isFinite(f)) return null;
            break :blk @intFromFloat(@round(f));
        },
        else => return null,
    };

    if (n < 0 or n > 100) return null;
    return @intCast(n);
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
