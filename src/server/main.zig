///! Zap web server — serves the WASM dashboard, REST API, and WebSocket.
///!
///! Routes:
///!   GET /              → web/index.html
///!   GET /*.js|css|wasm → static files from web/
///!   GET /api/health    → health check
///!   GET /api/config    → app configuration
///!   GET /api/ha/states → proxy to HA REST API
///!   WS  /ws            → WebSocket for real-time HA state relay

const std = @import("std");
const zap = @import("zap");
const routes = @import("routes.zig");
const websocket = @import("websocket.zig");

/// Server configuration
pub const Config = struct {
    port: u16 = 8765,
    web_root: []const u8 = "web",
    ha_url: []const u8 = "http://supervisor/core/api",
    supervisor_token: ?[]const u8 = null,
};

var config: Config = .{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read configuration
    config = readConfig();

    std.log.info("LVGL Dashboard Server starting on port {d}", .{config.port});
    if (config.supervisor_token != null) {
        std.log.info("Home Assistant Supervisor token found", .{});
    } else {
        std.log.warn("No SUPERVISOR_TOKEN — HA API proxy will be unavailable", .{});
    }

    // Initialize WebSocket handler
    websocket.init(allocator);

    // Register custom MIME types (must happen before listen)
    // .wasm → application/wasm (required for WebAssembly.instantiateStreaming)
    const fio = zap.fio;
    const wasm_mime = fio.fiobj_str_new("application/wasm", 16);
    fio.http_mimetype_register(@constCast("wasm"), 4, wasm_mime);

    // Set up the Zap listener
    var listener = zap.HttpListener.init(.{
        .port = @as(usize, config.port),
        .on_request = onRequest,
        .on_response = null,
        .log = false,
        .max_clients = @as(isize, 100),
        .public_folder = config.web_root,
    });

    try listener.listen();

    std.log.info("Listening on http://0.0.0.0:{d}", .{config.port});
    std.log.info("Serving static files from: {s}", .{config.web_root});

    // Run the event loop (blocks)
    zap.start(.{
        .threads = 2,
        .workers = 1,
    });
}

fn onRequest(r: zap.Request) anyerror!void {
    const path = r.path orelse "/";

    // WebSocket upgrade
    if (std.mem.eql(u8, path, "/ws")) {
        websocket.handleUpgrade(r) catch |err| {
            std.log.err("WebSocket upgrade failed: {}", .{err});
            r.setStatus(.bad_request);
            r.sendBody("WebSocket upgrade failed") catch {};
        };
        return;
    }

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
        r.sendFile("web/index.html") catch {
            r.setStatus(.not_found);
            r.sendBody("Not found") catch {};
        };
        return;
    }

    // Static files are handled by Zap's public_folder automatically
    // If we get here, the file wasn't found
    r.setStatus(.not_found);
    r.sendBody("Not found") catch {};
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

    return cfg;
}
