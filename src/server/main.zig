///! Zap web server — serves the WASM dashboard, REST API, WebSocket,
///! and drives the native framebuffer display when hardware is present.
///!
///! Routes:
///!   GET /              -> web/index.html
///!   GET /*.js|css|wasm -> static files from web/
///!   GET /api/health    -> health check
///!   GET /api/config    -> app configuration
///!   GET /api/ha/*      -> proxy to HA REST API
///!   WS  /ws            -> WebSocket for real-time HA state relay
///!
///! NOTE: We do NOT use facil.io's `public_folder` for static file serving.
///! Instead, all files are served explicitly in onRequest with proper Content-Type
///! headers. This is necessary because:
///!   1. facil.io's public_folder bypasses onRequest entirely for matched files,
///!      preventing us from adding custom headers.
///!   2. We need guaranteed Content-Type headers for HA ingress to work
///!      (without Content-Type, the iframe triggers a download instead of rendering).
const std = @import("std");
const zap = @import("zap");
const routes = @import("routes.zig");
const websocket = @import("websocket.zig");
const ha_client = @import("ha_client.zig");
const signalk_client = @import("signalk_client.zig");
const native_display = @import("native_display");

var runtime_log_level: std.log.Level = .info;
var runtime_log_mutex: std.Thread.Mutex = .{};

pub const std_options: std.Options = .{
    .log_level = .debug,

    .logFn = struct {
        fn logFn(
            comptime message_level: std.log.Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (!shouldLog(message_level)) return;

            const level_text = switch (message_level) {
                .err => "error",
                .warn => "warning",
                .info => "info",
                .debug => "debug",
            };

            const scope_text = @tagName(scope);

            var buf: [2048]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, format, args) catch "log formatting failed";

            runtime_log_mutex.lock();
            defer runtime_log_mutex.unlock();

            if (std.mem.eql(u8, scope_text, "default")) {
                std.debug.print("{s}: {s}\n", .{ level_text, msg });
            } else {
                std.debug.print("{s}({s}): {s}\n", .{ level_text, scope_text, msg });
            }
        }
    }.logFn,
};

/// Server configuration
pub const Config = struct {
    port: u16 = 8765,
    web_root: []const u8 = "web",
    ha_url: []const u8 = "http://supervisor/core/api",
    supervisor_token: ?[]const u8 = null,
    signalk_url: ?[]const u8 = null,
    log_level: std.log.Level = .info,
};

var config: Config = .{};

/// MIME type lookup by file extension
fn getMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".json")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}

/// Serve a static file with the correct Content-Type header.
/// Returns true if the file was found and sent, false otherwise.
fn serveStaticFile(r: zap.Request, file_path: []const u8) bool {
    r.setHeader("content-type", getMimeType(file_path)) catch {};
    r.sendFile(file_path) catch return false;
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read configuration
    config = readConfig();
    runtime_log_level = config.log_level;

    std.log.info("Raspberry Pi Touchscreen native Dashboard for HAOS server starting on port {d}", .{config.port});
    std.log.info("Log level set to {s}", .{@tagName(config.log_level)});
    if (config.supervisor_token != null) {
        std.log.info("Home Assistant Supervisor token found", .{});
    } else {
        std.log.warn("No SUPERVISOR_TOKEN — HA API proxy will be unavailable", .{});
    }
    if (config.signalk_url) |url| {
        std.log.info("SignalK URL override configured: {s}", .{url});
    }

    // Initialize modules
    websocket.init(allocator);
    routes.init(allocator);
    signalk_client.init(allocator);
    signalk_client.setBaseUrlOverride(config.signalk_url);
    signalk_client.setSupervisorToken(config.supervisor_token);
    signalk_client.setBroadcaster(websocket.broadcastRaw);
    ha_client.init(allocator, .{
        .ha_url = config.ha_url,
        .token = config.supervisor_token,
    });

    // Start the HA client background connection (connects to HA WebSocket API)
    ha_client.start() catch |err| {
        std.log.err("Failed to start HA client: {}", .{err});
        // Non-fatal — server still works, just no live HA data
    };

    signalk_client.start() catch |err| {
        std.log.err("Failed to start SignalK client: {}", .{err});
        // Non-fatal — anchor page can still show status + retries
    };

    // Start native display if hardware is present (framebuffer + touch)
    native_display.setHaCallService(&haCallServiceBridge);
    const has_native = native_display.start() catch |err| blk: {
        std.log.err("Failed to start native display: {}", .{err});
        break :blk false;
    };
    if (has_native) {
        std.log.info("Native framebuffer display active", .{});
    }

    // Set up the Zap listener — NO public_folder (we serve files manually)
    // on_upgrade handles WebSocket upgrade requests via facil.io's protocol
    var listener = zap.HttpListener.init(.{
        .port = @as(usize, config.port),
        .on_request = onRequest,
        .on_response = null,
        .on_upgrade = onUpgrade,
        .log = false,
        .max_clients = @as(isize, 100),
        .public_folder = null,
    });

    try listener.listen();

    std.log.info("Listening on http://0.0.0.0:{d}", .{config.port});
    std.log.info("Serving static files from: {s}", .{config.web_root});

    // Run the event loop (blocks)
    zap.start(.{
        .threads = 2,
        .workers = 1,
    });

    // Cleanup on shutdown
    native_display.stop();
    signalk_client.stop();
    signalk_client.deinit();
    ha_client.stop();
    ha_client.deinit();
}

/// Handle WebSocket upgrade requests. facil.io routes upgrade requests
/// here instead of to onRequest.
fn onUpgrade(r: zap.Request, target_protocol: []const u8) anyerror!void {
    if (std.mem.eql(u8, target_protocol, "websocket")) {
        const raw_path = r.path orelse "/";

        // Normalize path (same as onRequest)
        var path = raw_path;
        while (path.len > 1 and path[0] == '/' and path[1] == '/') {
            path = path[1..];
        }

        if (std.mem.eql(u8, path, "/ws")) {
            websocket.handleUpgrade(r);
            return;
        }
    }

    // Not a WebSocket upgrade we handle — reject
    r.setStatus(.bad_request);
    r.sendBody("400 - Bad Request") catch {};
}

fn onRequest(r: zap.Request) anyerror!void {
    const path = r.path orelse "/";

    // Log request for debugging
    std.log.info("Request: {s}", .{path});

    // API routes
    if (std.mem.startsWith(u8, path, "/api/")) {
        routes.handleApi(r, &config) catch |err| {
            std.log.err("API error: {}", .{err});
            r.setStatus(.internal_server_error);
            r.sendBody("{\"error\":\"internal server error\"}") catch {};
        };
        return;
    }

    // Serve index.html for root path
    if (std.mem.eql(u8, path, "/")) {
        var buf: [512]u8 = undefined;
        const index_path = std.fmt.bufPrint(&buf, "{s}/index.html", .{config.web_root}) catch "web/index.html";
        if (!serveStaticFile(r, index_path)) {
            r.setStatus(.not_found);
            r.sendBody("Not found") catch {};
        }
        return;
    }

    // Static file serving: map URL path to web_root filesystem path
    // Path starts with "/" — strip it and join with web_root
    if (path.len > 1 and path[0] == '/') {
        const rel_path = path[1..];

        // Security: reject paths with ".." to prevent directory traversal
        if (std.mem.indexOf(u8, rel_path, "..") != null) {
            r.setStatus(.forbidden);
            r.sendBody("Forbidden") catch {};
            return;
        }

        var buf: [512]u8 = undefined;
        const file_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ config.web_root, rel_path }) catch {
            r.setStatus(.internal_server_error);
            r.sendBody("Path too long") catch {};
            return;
        };

        if (serveStaticFile(r, file_path)) {
            return;
        }
    }

    // Nothing matched
    r.setStatus(.not_found);
    r.sendBody("Not found") catch {};
}

/// Bridge function: native display callbacks -> HA REST API.
/// Translates the simple (domain, service, entity_id, extra_json) signature
/// into ha_client.callService(domain, service, std.json.Value).
fn haCallServiceBridge(domain: []const u8, service: []const u8, entity_id: []const u8, extra_json: ?[]const u8) void {
    // Build a JSON body string: {"entity_id": "...", ...extra}
    var buf: [512]u8 = undefined;
    var body: []const u8 = undefined;

    if (entity_id.len > 0 and extra_json != null) {
        body = std.fmt.bufPrint(&buf, "{{\"entity_id\":\"{s}\",{s}}}", .{ entity_id, extra_json.? }) catch return;
    } else if (entity_id.len > 0) {
        body = std.fmt.bufPrint(&buf, "{{\"entity_id\":\"{s}\"}}", .{entity_id}) catch return;
    } else if (extra_json) |extra| {
        body = std.fmt.bufPrint(&buf, "{{{s}}}", .{extra}) catch return;
    } else {
        body = "{}";
    }

    // Parse the JSON body into a std.json.Value for ha_client.callService
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch |err| {
        std.log.err("Failed to parse service data JSON: {}", .{err});
        return;
    };
    defer parsed.deinit();

    ha_client.callService(domain, service, parsed.value) catch |err| {
        std.log.err("HA service call {s}.{s} failed: {}", .{ domain, service, err });
    };
}

/// Read configuration from environment (HA app) and /data/options.json
fn readConfig() Config {
    var cfg = Config{};

    // Port from HA options or env
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "PORT")) |port_str| {
        cfg.port = std.fmt.parseInt(u16, port_str, 10) catch 8765;
        std.heap.page_allocator.free(port_str);
    } else |_| {}

    // Supervisor token
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "SUPERVISOR_TOKEN")) |token| {
        cfg.supervisor_token = token;
        // Note: intentionally not freeing — we keep it for the lifetime of the process
    } else |_| {}

    // HA URL override
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "HA_URL")) |url| {
        cfg.ha_url = url;
    } else |_| {}

    // Web root override
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "WEB_ROOT")) |root| {
        cfg.web_root = root;
    } else |_| {}

    // SignalK URL override
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "SIGNALK_URL")) |url| {
        if (url.len > 0) {
            cfg.signalk_url = url;
        } else {
            std.heap.page_allocator.free(url);
        }
    } else |_| {}

    // Runtime log level
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "LOG_LEVEL")) |lvl| {
        cfg.log_level = parseLogLevel(lvl);
        std.heap.page_allocator.free(lvl);
    } else |_| {}

    return cfg;
}

fn parseLogLevel(level: []const u8) std.log.Level {
    if (std.ascii.eqlIgnoreCase(level, "error") or std.ascii.eqlIgnoreCase(level, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(level, "warning") or std.ascii.eqlIgnoreCase(level, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(level, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(level, "debug") or std.ascii.eqlIgnoreCase(level, "trace")) return .debug;
    return .info;
}

fn shouldLog(level: std.log.Level) bool {
    return logLevelRank(level) <= logLevelRank(runtime_log_level);
}

fn logLevelRank(level: std.log.Level) u8 {
    return switch (level) {
        .err => 0,
        .warn => 1,
        .info => 2,
        .debug => 3,
    };
}
