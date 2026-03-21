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
var state_file_path_allocated: bool = false;
var broadcaster: ?*const fn ([]const u8) void = null;
var base_url_override: ?[]u8 = null;

pub fn setBroadcaster(cb: *const fn ([]const u8) void) void {
    broadcaster = cb;
}

const DISCOVERY_URLS = [_][]const u8{
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://signalk:3000",
};

pub fn setBaseUrlOverride(maybe_url: ?[]const u8) void {
    persist_mutex.lock();
    defer persist_mutex.unlock();

    if (base_url_override) |old| {
        allocator.free(old);
        base_url_override = null;
    }

    if (maybe_url) |url| {
        if (url.len > 0) {
            base_url_override = allocator.dupe(u8, url) catch null;
        }
    }
}

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;

    const env_path = std.process.getEnvVarOwned(allocator, STATE_FILE_ENV) catch null;
    if (env_path) |p| {
        state_file_path = p;
        state_file_path_allocated = true;
    } else {
        // Try HA app data dir first
        if (std.fs.openDirAbsolute("/data", .{})) |d| {
            var dir = d;
            dir.close();
            state_file_path = allocator.dupe(u8, "/data/signalk_auth.json") catch "signalk_auth.json";
            state_file_path_allocated = !std.mem.eql(u8, state_file_path, "signalk_auth.json");
        } else |_| {
            state_file_path = "signalk_auth.json";
            state_file_path_allocated = false;
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
    if (base_url_override) |v| allocator.free(v);

    if (state_file_path_allocated) {
        allocator.free(state_file_path);
        state_file_path_allocated = false;
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
    if (base_url_override) |override| {
        log.debug("Trying configured SignalK URL: {s}", .{override});
        if (checkSignalKAvailable(override)) {
            setBaseUrl(override);
            savePersistentState();
            publishStatus(.requesting, "SignalK detected");
            return allocator.dupe(u8, override);
        }
        log.warn("Configured SignalK URL is unreachable: {s}", .{override});
    }

    if (getBaseUrl()) |saved| {
        defer allocator.free(saved);
        log.debug("Trying persisted SignalK URL: {s}", .{saved});
        if (checkSignalKAvailable(saved)) {
            return allocator.dupe(u8, saved);
        }
    }

    publishStatus(.detecting, "Detecting SignalK...");

    if (discoverSignalKViaMdns()) |url| {
        defer allocator.free(url);
        setBaseUrl(url);
        savePersistentState();
        publishStatus(.requesting, "SignalK detected via mDNS");
        return allocator.dupe(u8, url);
    }

    for (DISCOVERY_URLS) |url| {
        log.debug("Trying SignalK discovery URL: {s}", .{url});
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
        log.debug("Saved token invalid, cleared", .{});
    }

    const request_href = getRequestHref();
    defer if (request_href) |v| allocator.free(v);

    if (request_href) |href| {
        log.debug("Found persisted request_href: {s}", .{href});
    }

    if (request_href == null) {
        publishStatus(.requesting, "Requesting SignalK device auth...");
        const cid = ensureClientId();
        defer allocator.free(cid);

        const payload = std.fmt.allocPrint(allocator, "{{\"clientId\":\"{s}\",\"description\":\"Raspberry Pi Touchscreen native Dashboard for HAOS Anchor Alarm\",\"permissions\":\"readwrite\"}}", .{cid}) catch return error.OutOfMemory;
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

    const poll = getNoToken(base, request_href.?) catch |err| {
        log.warn("Polling access request failed ({s}): {} — clearing stale request", .{ request_href.?, err });
        clearRequestHref();
        savePersistentState();
        return err;
    };
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
    const result = getNoToken(base, "/signalk/v1/api/") catch |err| {
        log.debug("SignalK probe failed at {s}: {}", .{ base, err });
        return false;
    };
    defer allocator.free(result);
    log.debug("SignalK probe succeeded at {s}", .{base});
    return result.len > 0;
}

/// Discover SignalK via mDNS by querying for _signalk-http._tcp.local.
/// SignalK servers advertise themselves on this service type.
/// Returns an allocated URL string like "http://172.30.33.4:3000" or null.
fn discoverSignalKViaMdns() ?[]u8 {
    const service_types = [_][]const u8{
        "_signalk-http._tcp.local.",
        "_signalk-ws._tcp.local.",
    };

    for (service_types) |service| {
        log.debug("mDNS: querying for {s}", .{service});
        const result = mdnsQuery(service) catch |err| {
            log.debug("mDNS query failed for {s}: {}", .{ service, err });
            continue;
        };

        if (result) |r| {
            const base = std.fmt.allocPrint(
                allocator,
                "http://{d}.{d}.{d}.{d}:{d}",
                .{ r.addr[0], r.addr[1], r.addr[2], r.addr[3], r.port },
            ) catch continue;

            if (!checkSignalKAvailable(base)) {
                log.debug("mDNS-discovered SignalK URL not reachable: {s}", .{base});
                allocator.free(base);
                continue;
            }

            log.info("SignalK discovered via mDNS: {s}", .{base});
            return base;
        }
    }

    return null;
}

const MdnsResult = struct {
    addr: [4]u8,
    port: u16,
};

/// Send an mDNS PTR query and parse the response for A and SRV records.
fn mdnsQuery(service_name: []const u8) !?MdnsResult {
    const posix = std.posix;

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    // Set receive timeout to 2 seconds
    const timeout = posix.timeval{ .sec = 2, .usec = 0 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

    // Build DNS query packet for PTR record
    var query_buf: [512]u8 = undefined;
    const query_len = buildDnsQuery(&query_buf, service_name) catch |err| {
        log.debug("mDNS: failed to build query for {s}: {}", .{ service_name, err });
        return err;
    };

    // Send to mDNS multicast address 224.0.0.251:5353
    const mdns_addr = posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, 5353),
        .addr = std.mem.nativeToBig(u32, (224 << 24) | (0 << 16) | (0 << 8) | 251),
    };

    _ = try posix.sendto(sock, query_buf[0..query_len], 0, @ptrCast(&mdns_addr), @sizeOf(posix.sockaddr.in));

    // Wait for response(s) — try up to 5 reads within the timeout
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var resp_buf: [4096]u8 = undefined;
        const resp_len = posix.recvfrom(sock, &resp_buf, 0, null, null) catch |err| {
            if (err == error.WouldBlock) break; // timeout
            return err;
        };
        if (resp_len < 12) continue;

        if (parseMdnsResponse(resp_buf[0..resp_len])) |result| {
            return result;
        }
    }

    return null;
}

/// Build a DNS PTR query packet for the given service name.
fn buildDnsQuery(buf: []u8, name: []const u8) !usize {
    if (buf.len < 12 + name.len + 2 + 4) return error.BufferTooSmall;

    var pos: usize = 0;

    // Transaction ID
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;
    // Flags: standard query
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;
    // Questions: 1
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;
    // Answer/Authority/Additional RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Encode the query name (e.g. "_signalk-http._tcp.local.")
    pos = try encodeDnsName(buf, pos, name);

    // Type: PTR (12)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x0C;
    pos += 2;
    // Class: IN (1) with unicast-response bit clear
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    return pos;
}

/// Encode a dotted DNS name into wire format (length-prefixed labels).
fn encodeDnsName(buf: []u8, offset: usize, name: []const u8) !usize {
    var pos = offset;
    var remaining = name;

    // Strip trailing dot if present
    if (remaining.len > 0 and remaining[remaining.len - 1] == '.') {
        remaining = remaining[0 .. remaining.len - 1];
    }

    while (remaining.len > 0) {
        const dot_idx = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        if (dot_idx == 0 or dot_idx > 63) return error.InvalidDnsName;
        if (pos + 1 + dot_idx > buf.len) return error.BufferTooSmall;

        buf[pos] = @intCast(dot_idx);
        pos += 1;
        @memcpy(buf[pos .. pos + dot_idx], remaining[0..dot_idx]);
        pos += dot_idx;

        if (dot_idx < remaining.len) {
            remaining = remaining[dot_idx + 1 ..];
        } else {
            remaining = remaining[remaining.len..];
        }
    }

    // Null terminator
    if (pos >= buf.len) return error.BufferTooSmall;
    buf[pos] = 0x00;
    pos += 1;

    return pos;
}

/// Parse an mDNS response packet looking for SRV and A records.
fn parseMdnsResponse(pkt: []const u8) ?MdnsResult {
    if (pkt.len < 12) return null;

    // Read header counts (big-endian)
    const qdcount = readU16(pkt, 4);
    const ancount = readU16(pkt, 6);
    const nscount = readU16(pkt, 8);
    const arcount = readU16(pkt, 10);
    const total_rr = ancount + nscount + arcount;

    if (total_rr == 0) return null;

    // Skip question section
    var pos: usize = 12;
    var q: u16 = 0;
    while (q < qdcount) : (q += 1) {
        pos = skipDnsName(pkt, pos) orelse return null;
        if (pos + 4 > pkt.len) return null;
        pos += 4; // skip type + class
    }

    // Parse answer/authority/additional sections
    var found_addr: ?[4]u8 = null;
    var found_port: ?u16 = null;

    var rr: u16 = 0;
    while (rr < total_rr) : (rr += 1) {
        // Skip RR name
        pos = skipDnsName(pkt, pos) orelse return null;
        if (pos + 10 > pkt.len) return null;

        const rr_type = readU16(pkt, pos);
        pos += 2;
        // skip class
        pos += 2;
        // skip TTL
        pos += 4;
        const rdlength = readU16(pkt, pos);
        pos += 2;

        if (pos + rdlength > pkt.len) return null;

        if (rr_type == 1 and rdlength == 4) {
            // A record — IPv4 address
            found_addr = .{ pkt[pos], pkt[pos + 1], pkt[pos + 2], pkt[pos + 3] };
        } else if (rr_type == 33 and rdlength >= 6) {
            // SRV record — priority(2) + weight(2) + port(2) + target
            found_port = readU16(pkt, pos + 4);
        }

        pos += rdlength;
    }

    if (found_addr) |addr| {
        const port = found_port orelse 3000;
        return MdnsResult{ .addr = addr, .port = port };
    }

    return null;
}

fn readU16(buf: []const u8, offset: usize) u16 {
    return (@as(u16, buf[offset]) << 8) | @as(u16, buf[offset + 1]);
}

/// Skip over a DNS name in wire format (handles compression pointers).
fn skipDnsName(pkt: []const u8, offset: usize) ?usize {
    var pos = offset;
    while (pos < pkt.len) {
        const len_byte = pkt[pos];
        if (len_byte == 0) {
            // End of name
            return pos + 1;
        }
        if ((len_byte & 0xC0) == 0xC0) {
            // Compression pointer — 2 bytes total
            return pos + 2;
        }
        // Regular label
        pos += 1 + @as(usize, len_byte);
    }
    return null;
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
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
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
