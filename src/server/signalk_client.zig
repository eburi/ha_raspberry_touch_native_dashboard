const std = @import("std");

const log = std.log.scoped(.signalk_client);

const STATE_FILE_ENV = "SIGNALK_STATE_FILE";

const AuthState = enum {
    detecting,
    not_found,
    requesting,
    waiting_approval,
    approved,
    denied,
    connected,
    error_state,
};

const PersistentState = struct {
    client_id: ?[]u8 = null,
    request_href: ?[]u8 = null,
    token: ?[]u8 = null,
    base_url: ?[]u8 = null,
};

var allocator: std.mem.Allocator = undefined;
var worker_thread: ?std.Thread = null;
var should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var state_mutex: std.Thread.Mutex = .{};
var auth_state: AuthState = .detecting;
var status_message: []const u8 = "Detecting SignalK...";

var persist_mutex: std.Thread.Mutex = .{};
var persistent: PersistentState = .{};
var state_file_path: []const u8 = "signalk_auth.json";
var broadcaster: ?*const fn ([]const u8) void = null;

pub fn setBroadcaster(cb: *const fn ([]const u8) void) void {
    broadcaster = cb;
}

const DISCOVERY_URLS = [_][]const u8{
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://signalk:3000",
};

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;

    const env_path = std.process.getEnvVarOwned(allocator, STATE_FILE_ENV) catch null;
    if (env_path) |p| {
        state_file_path = p;
    } else {
        // Try HA app data dir first
        if (std.fs.openDirAbsolute("/data", .{})) |d| {
            var dir = d;
            dir.close();
            state_file_path = allocator.dupe(u8, "/data/signalk_auth.json") catch "signalk_auth.json";
        } else |_| {
            state_file_path = "signalk_auth.json";
        }
    }

    loadPersistentState();
    publishStatus(.detecting, "Detecting SignalK...");
}

pub fn start() !void {
    should_stop.store(false, .release);
    worker_thread = try std.Thread.spawn(.{}, workerLoop, .{});
}

pub fn stop() void {
    should_stop.store(true, .release);
    if (worker_thread) |thread| {
        thread.join();
        worker_thread = null;
    }
}

pub fn deinit() void {
    persist_mutex.lock();
    defer persist_mutex.unlock();

    if (persistent.client_id) |v| allocator.free(v);
    if (persistent.request_href) |v| allocator.free(v);
    if (persistent.token) |v| allocator.free(v);
    if (persistent.base_url) |v| allocator.free(v);

    if (state_file_path.len > 0 and !std.mem.eql(u8, state_file_path, "signalk_auth.json")) {
        if (!std.mem.eql(u8, state_file_path, "/data/signalk_auth.json")) {
            allocator.free(state_file_path);
        }
    }
}

pub fn handleAction(action: []const u8, maybe_value: ?f64) ![]const u8 {
    const token = getToken() orelse return error.NotConnected;
    const base = getBaseUrl() orelse return error.NoBaseUrl;
    defer allocator.free(token);
    defer allocator.free(base);

    if (std.mem.eql(u8, action, "radius_dec") or std.mem.eql(u8, action, "radius_inc")) {
        const nav_json = try getWithToken(base, token, "/signalk/v1/api/vessels/self/navigation");
        defer allocator.free(nav_json);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, nav_json, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        var radius: f64 = 50;
        if (parsed.value == .object) {
            if (parsed.value.object.get("anchor")) |anchor_v| {
                if (anchor_v == .object) {
                    if (anchor_v.object.get("maxRadius")) |mr| {
                        if (mr == .object) {
                            if (mr.object.get("value")) |rv| {
                                switch (rv) {
                                    .float => |f| radius = f,
                                    .integer => |i| radius = @floatFromInt(i),
                                    else => {},
                                }
                            }
                        }
                    }
                }
            }
        }

        const delta: f64 = if (std.mem.eql(u8, action, "radius_inc")) 5 else -5;
        var next = radius + delta;
        if (next < 5) next = 5;
        if (next > 1000) next = 1000;

        const plugin_payload = std.fmt.allocPrint(allocator, "{{\"radius\":{d}}}", .{@as(i32, @intFromFloat(next))}) catch return error.OutOfMemory;
        defer allocator.free(plugin_payload);

        const plugin_result = postWithToken(base, token, "/plugins/hoekens-anchor-alarm/setRadius", plugin_payload) catch null;
        if (plugin_result) |res| {
            allocator.free(res);
            return std.fmt.allocPrint(allocator, "{{\"ok\":true,\"radius\":{d}}}", .{@as(i32, @intFromFloat(next))});
        }

        const put_payload = std.fmt.allocPrint(allocator, "{d}", .{@as(i32, @intFromFloat(next))}) catch return error.OutOfMemory;
        defer allocator.free(put_payload);
        const put_res = try putWithToken(base, token, "/signalk/v1/api/vessels/self/navigation/anchor/maxRadius", put_payload);
        allocator.free(put_res);

        return std.fmt.allocPrint(allocator, "{{\"ok\":true,\"radius\":{d}}}", .{@as(i32, @intFromFloat(next))});
    }

    if (std.mem.eql(u8, action, "drop_or_raise")) {
        const nav_json = try getWithToken(base, token, "/signalk/v1/api/vessels/self/navigation");
        defer allocator.free(nav_json);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, nav_json, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        var anchored = false;
        var lat: f64 = 0;
        var lon: f64 = 0;
        var radius: f64 = 50;

        if (parsed.value == .object) {
            if (parsed.value.object.get("anchor")) |anchor_v| {
                if (anchor_v == .object) {
                    if (anchor_v.object.get("state")) |st| {
                        if (st == .object) {
                            if (st.object.get("value")) |v| {
                                if (v == .string and std.mem.eql(u8, v.string, "on")) anchored = true;
                            }
                        }
                    }
                    if (anchor_v.object.get("maxRadius")) |mr| {
                        if (mr == .object) {
                            if (mr.object.get("value")) |rv| {
                                switch (rv) {
                                    .float => |f| radius = f,
                                    .integer => |i| radius = @floatFromInt(i),
                                    else => {},
                                }
                            }
                        }
                    }
                }
            }
            if (parsed.value.object.get("position")) |pos| {
                if (pos == .object) {
                    if (pos.object.get("value")) |pval| {
                        if (pval == .object) {
                            if (pval.object.get("latitude")) |la| {
                                switch (la) {
                                    .float => |f| lat = f,
                                    .integer => |i| lat = @floatFromInt(i),
                                    else => {},
                                }
                            }
                            if (pval.object.get("longitude")) |lo| {
                                switch (lo) {
                                    .float => |f| lon = f,
                                    .integer => |i| lon = @floatFromInt(i),
                                    else => {},
                                }
                            }
                        }
                    }
                }
            }
        }

        if (anchored) {
            const plugin_res = postWithToken(base, token, "/plugins/hoekens-anchor-alarm/raiseAnchor", "{}") catch null;
            if (plugin_res) |res| allocator.free(res) else {
                const put_res = try putWithToken(base, token, "/signalk/v1/api/vessels/self/navigation/anchor/position", "null");
                allocator.free(put_res);
            }
            return allocator.dupe(u8, "{\"ok\":true,\"anchored\":false}");
        }

        const radius_to_set = if (maybe_value) |v| v else radius;
        const drop_payload = std.fmt.allocPrint(allocator, "{{\"position\":{{\"latitude\":{d},\"longitude\":{d}}},\"radius\":{d}}}", .{ lat, lon, @as(i32, @intFromFloat(radius_to_set)) }) catch return error.OutOfMemory;
        defer allocator.free(drop_payload);

        const plugin_drop = postWithToken(base, token, "/plugins/hoekens-anchor-alarm/dropAnchor", drop_payload) catch null;
        if (plugin_drop) |res| {
            allocator.free(res);
        } else {
            const pos_payload = std.fmt.allocPrint(allocator, "{{\"latitude\":{d},\"longitude\":{d}}}", .{ lat, lon }) catch return error.OutOfMemory;
            defer allocator.free(pos_payload);
            const put_pos = try putWithToken(base, token, "/signalk/v1/api/vessels/self/navigation/anchor/position", pos_payload);
            allocator.free(put_pos);

            const rad_payload = std.fmt.allocPrint(allocator, "{d}", .{@as(i32, @intFromFloat(radius_to_set))}) catch return error.OutOfMemory;
            defer allocator.free(rad_payload);
            const put_rad = try putWithToken(base, token, "/signalk/v1/api/vessels/self/navigation/anchor/maxRadius", rad_payload);
            allocator.free(put_rad);
        }

        return allocator.dupe(u8, "{\"ok\":true,\"anchored\":true}");
    }

    return error.UnsupportedAction;
}

fn workerLoop() void {
    while (!should_stop.load(.acquire)) {
        const base = ensureBaseUrl() catch |err| {
            log.warn("SignalK discovery error: {}", .{err});
            publishStatus(.not_found, "SignalK app not detected");
            std.time.sleep(5 * std.time.ns_per_s);
            continue;
        };
        defer allocator.free(base);

        ensureAuthAndPoll(base) catch |err| {
            log.warn("SignalK auth/poll error: {}", .{err});
            publishStatus(.error_state, "SignalK connection error");
            std.time.sleep(3 * std.time.ns_per_s);
        };
    }
}

fn ensureBaseUrl() ![]u8 {
    if (getBaseUrl()) |saved| {
        defer allocator.free(saved);
        if (checkSignalKAvailable(saved)) {
            return allocator.dupe(u8, saved);
        }
    }

    publishStatus(.detecting, "Detecting SignalK...");

    for (DISCOVERY_URLS) |url| {
        if (checkSignalKAvailable(url)) {
            setBaseUrl(url);
            savePersistentState();
            publishStatus(.requesting, "SignalK detected");
            return allocator.dupe(u8, url);
        }
    }

    return error.SignalKNotFound;
}

fn ensureAuthAndPoll(base: []const u8) !void {
    const token_existing = getToken();
    if (token_existing) |tok| {
        defer allocator.free(tok);
        if (try fetchAndBroadcast(base, tok)) {
            publishStatus(.connected, "SignalK connected");
            std.time.sleep(1 * std.time.ns_per_s);
            return;
        }
        clearToken();
    }

    const request_href = getRequestHref();
    defer if (request_href) |v| allocator.free(v);

    if (request_href == null) {
        publishStatus(.requesting, "Requesting SignalK device auth...");
        const cid = ensureClientId();
        defer allocator.free(cid);

        const payload = std.fmt.allocPrint(allocator, "{{\"clientId\":\"{s}\",\"description\":\"Raspberry Pi Touchscreen native Dashboard for HAOS Anchor Alarm\"}}", .{cid}) catch return error.OutOfMemory;
        defer allocator.free(payload);

        const resp = postNoToken(base, "/signalk/v1/access/requests", payload) catch |err| {
            log.warn("Access request failed: {}", .{err});
            publishStatus(.error_state, "SignalK auth request failed");
            return err;
        };
        defer allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const href_val = parsed.value.object.get("href") orelse return error.InvalidResponse;
        if (href_val != .string) return error.InvalidResponse;

        setRequestHref(href_val.string);
        savePersistentState();
        publishStatus(.waiting_approval, "approve auth request");
        return;
    }

    publishStatus(.waiting_approval, "approve auth request");

    const poll = try getNoToken(base, request_href.?);
    defer allocator.free(poll);

    const parsed_poll = std.json.parseFromSlice(std.json.Value, allocator, poll, .{}) catch return error.InvalidResponse;
    defer parsed_poll.deinit();

    if (parsed_poll.value != .object) return;

    const state_val = parsed_poll.value.object.get("state");
    if (state_val) |sv| {
        if (sv == .string and std.mem.eql(u8, sv.string, "PENDING")) {
            publishStatus(.waiting_approval, "approve auth request");
            std.time.sleep(2 * std.time.ns_per_s);
            return;
        }
    }

    const ar = parsed_poll.value.object.get("accessRequest") orelse return;
    if (ar != .object) return;
    const perm = ar.object.get("permission") orelse return;
    if (perm != .string) return;

    if (std.mem.eql(u8, perm.string, "APPROVED")) {
        const token_val = ar.object.get("token") orelse return;
        if (token_val != .string) return;
        setToken(token_val.string);
        clearRequestHref();
        savePersistentState();
        publishStatus(.approved, "SignalK auth approved");
        return;
    }

    if (std.mem.eql(u8, perm.string, "DENIED")) {
        publishStatus(.denied, "SignalK auth request denied");
        std.time.sleep(3 * std.time.ns_per_s);
    }
}

fn fetchAndBroadcast(base: []const u8, token: []const u8) !bool {
    const self_json = getWithToken(base, token, "/signalk/v1/api/vessels/self") catch return false;
    defer allocator.free(self_json);

    const vessels_json = getWithToken(base, token, "/signalk/v1/api/vessels") catch return false;
    defer allocator.free(vessels_json);

    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"signalk_data\",\"self\":{s},\"vessels\":{s}}}",
        .{ self_json, vessels_json },
    ) catch return false;
    defer allocator.free(payload);

    broadcast(payload);
    return true;
}

fn checkSignalKAvailable(base: []const u8) bool {
    const result = getNoToken(base, "/signalk/v1/api/") catch return false;
    defer allocator.free(result);
    return result.len > 0;
}

fn publishStatus(state: AuthState, msg: []const u8) void {
    state_mutex.lock();
    auth_state = state;
    status_message = msg;
    state_mutex.unlock();

    const state_text = switch (state) {
        .detecting => "detecting",
        .not_found => "not_found",
        .requesting => "requesting",
        .waiting_approval => "waiting_approval",
        .approved => "approved",
        .denied => "denied",
        .connected => "connected",
        .error_state => "error",
    };

    const json = std.fmt.allocPrint(allocator, "{{\"type\":\"signalk_status\",\"state\":\"{s}\",\"message\":\"{s}\"}}", .{ state_text, msg }) catch return;
    defer allocator.free(json);
    broadcast(json);
}

fn broadcast(json: []const u8) void {
    if (broadcaster) |cb| {
        cb(json);
    }
}

fn getNoToken(base: []const u8, path: []const u8) ![]u8 {
    return request(.GET, base, path, null, null);
}

fn postNoToken(base: []const u8, path: []const u8, body: []const u8) ![]u8 {
    return request(.POST, base, path, null, body);
}

fn getWithToken(base: []const u8, token: []const u8, path: []const u8) ![]u8 {
    return request(.GET, base, path, token, null);
}

fn postWithToken(base: []const u8, token: []const u8, path: []const u8, body: []const u8) ![]u8 {
    return request(.POST, base, path, token, body);
}

fn putWithToken(base: []const u8, token: []const u8, path: []const u8, body: []const u8) ![]u8 {
    return request(.PUT, base, path, token, body);
}

fn request(method: std.http.Method, base: []const u8, path: []const u8, maybe_token: ?[]const u8, maybe_body: ?[]const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path });
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var header_buf: [8192]u8 = undefined;
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var extra_headers: [2]std.http.Header = undefined;
    var header_count: usize = 0;

    if (maybe_token) |token| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        extra_headers[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }

    if (maybe_body != null) {
        extra_headers[header_count] = .{ .name = "Content-Type", .value = "application/json" };
        header_count += 1;
    }

    const headers_slice = extra_headers[0..header_count];

    var req = try client.open(method, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = headers_slice,
    });
    defer req.deinit();

    if (maybe_body) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
    }

    try req.send();
    if (maybe_body) |body| {
        try req.writer().writeAll(body);
    }
    try req.finish();
    try req.wait();

    if (req.response.status != .ok and req.response.status != .accepted and req.response.status != .created) {
        return error.HttpError;
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try req.reader().read(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }

    return out.toOwnedSlice();
}

fn ensureClientId() []u8 {
    if (getClientId()) |existing| {
        return existing;
    }

    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const id = std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        },
    ) catch return allocator.dupe(u8, "00000000-0000-4000-8000-000000000000") catch unreachable;

    setClientId(id);
    savePersistentState();
    return id;
}

fn loadPersistentState() void {
    const file = blk: {
        if (std.fs.path.isAbsolute(state_file_path)) {
            break :blk std.fs.openFileAbsolute(state_file_path, .{}) catch return;
        }
        break :blk std.fs.cwd().openFile(state_file_path, .{}) catch return;
    };
    defer file.close();

    const raw = file.readToEndAlloc(allocator, 16 * 1024) catch return;
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    if (parsed.value.object.get("client_id")) |v| {
        if (v == .string) setClientId(v.string);
    }
    if (parsed.value.object.get("request_href")) |v| {
        if (v == .string) setRequestHref(v.string);
    }
    if (parsed.value.object.get("token")) |v| {
        if (v == .string) setToken(v.string);
    }
    if (parsed.value.object.get("base_url")) |v| {
        if (v == .string) setBaseUrl(v.string);
    }
}

fn savePersistentState() void {
    persist_mutex.lock();
    defer persist_mutex.unlock();

    const PersistJson = struct {
        client_id: ?[]const u8,
        request_href: ?[]const u8,
        token: ?[]const u8,
        base_url: ?[]const u8,
    };

    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    std.json.stringify(PersistJson{
        .client_id = if (persistent.client_id) |v| v else null,
        .request_href = if (persistent.request_href) |v| v else null,
        .token = if (persistent.token) |v| v else null,
        .base_url = if (persistent.base_url) |v| v else null,
    }, .{}, list.writer()) catch return;
    const json = list.items;

    const file = blk: {
        if (std.fs.path.isAbsolute(state_file_path)) {
            break :blk std.fs.createFileAbsolute(state_file_path, .{ .truncate = true }) catch return;
        }
        break :blk std.fs.cwd().createFile(state_file_path, .{ .truncate = true }) catch return;
    };
    defer file.close();
    _ = file.writeAll(json) catch {};
}

fn setClientId(v: []const u8) void {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.client_id) |old| allocator.free(old);
    persistent.client_id = allocator.dupe(u8, v) catch persistent.client_id;
}

fn setRequestHref(v: []const u8) void {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.request_href) |old| allocator.free(old);
    persistent.request_href = allocator.dupe(u8, v) catch persistent.request_href;
}

fn clearRequestHref() void {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.request_href) |old| allocator.free(old);
    persistent.request_href = null;
}

fn setToken(v: []const u8) void {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.token) |old| allocator.free(old);
    persistent.token = allocator.dupe(u8, v) catch persistent.token;
}

fn clearToken() void {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.token) |old| allocator.free(old);
    persistent.token = null;
}

fn setBaseUrl(v: []const u8) void {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.base_url) |old| allocator.free(old);
    persistent.base_url = allocator.dupe(u8, v) catch persistent.base_url;
}

fn getClientId() ?[]u8 {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.client_id) |v| return allocator.dupe(u8, v) catch null;
    return null;
}

fn getRequestHref() ?[]u8 {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.request_href) |v| return allocator.dupe(u8, v) catch null;
    return null;
}

fn getToken() ?[]u8 {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.token) |v| return allocator.dupe(u8, v) catch null;
    return null;
}

fn getBaseUrl() ?[]u8 {
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (persistent.base_url) |v| return allocator.dupe(u8, v) catch null;
    return null;
}
