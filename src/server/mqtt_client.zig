///! Minimal MQTT v3.1.1 client for HA light entity discovery.
///!
///! Supports CONNECT, PUBLISH, SUBSCRIBE, PINGREQ, and automatic
///! reconnection with exponential backoff. Not a general-purpose client.
const std = @import("std");

const log = std.log.scoped(.mqtt);

pub const MqttConfig = struct {
    host: []const u8 = "core-mosquitto",
    port: u16 = 1883,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    client_id: []const u8 = "ha_raspberry_touch_dashboard",
};

const RX_BUF_SIZE: usize = 4096;

pub const MqttClient = struct {
    allocator: std.mem.Allocator,
    config: MqttConfig,

    on_connect: ?*const fn () void = null,
    on_message: ?*const fn (topic: []const u8, payload: []const u8) void = null,

    stream: ?std.net.Stream = null,
    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, config: MqttConfig) MqttClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn start(self: *MqttClient) !void {
        self.should_stop.store(false, .release);
        const ptr = @intFromPtr(self);
        self.thread = try std.Thread.spawn(.{}, connectionLoop, .{ptr});
    }

    pub fn stop(self: *MqttClient) void {
        self.should_stop.store(true, .release);
        if (self.stream) |s| s.close();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn publish(self: *MqttClient, topic: []const u8, payload: []const u8, retain: bool) !void {
        const s = self.stream orelse return error.NotConnected;
        if (!self.connected.load(.acquire)) return error.NotConnected;

        var buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        // Topic (2-byte length + data)
        try w.writeInt(u16, @intCast(topic.len), .big);
        try w.writeAll(topic);
        // Payload
        try w.writeAll(payload);

        const body = fbs.getWritten();
        var flags: u8 = 0x30;
        if (retain) flags |= 1;

        var hdr: [5]u8 = undefined;
        const header = encodeHeader(flags, body.len, &hdr);

        s.writeAll(header) catch {
            self.connected.store(false, .release);
            return error.WriteFailed;
        };
        s.writeAll(body) catch {
            self.connected.store(false, .release);
            return error.WriteFailed;
        };
    }

    pub fn subscribe(self: *MqttClient, topic_filter: []const u8) !void {
        const s = self.stream orelse return error.NotConnected;
        if (!self.connected.load(.acquire)) return error.NotConnected;

        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        // Packet ID (1)
        try w.writeInt(u16, 1, .big);
        // Topic filter (2-byte length + data)
        try w.writeInt(u16, @intCast(topic_filter.len), .big);
        try w.writeAll(topic_filter);
        // QoS (0)
        try w.writeByte(0);

        const body = fbs.getWritten();
        var hdr: [5]u8 = undefined;
        const header = encodeHeader(0x82, body.len, &hdr);

        s.writeAll(header) catch {
            self.connected.store(false, .release);
            return error.WriteFailed;
        };
        s.writeAll(body) catch {
            self.connected.store(false, .release);
            return error.WriteFailed;
        };
    }
};

fn connectionLoop(ptr: usize) void {
    const self = @as(*MqttClient, @ptrFromInt(ptr));
    var backoff_ms: u64 = 1000;
    const max_backoff: u64 = 30000;

    while (!self.should_stop.load(.acquire)) {
        log.info("Connecting to MQTT broker at {s}:{d}...", .{ self.config.host, self.config.port });

        runSession(self) catch |err| {
            log.err("MQTT session error: {}", .{err});
        };

        self.connected.store(false, .release);

        if (self.should_stop.load(.acquire)) break;

        log.info("MQTT reconnecting in {d}ms...", .{backoff_ms});
        var elapsed: u64 = 0;
        while (elapsed < backoff_ms) {
            if (self.should_stop.load(.acquire)) return;
            std.time.sleep(100 * std.time.ns_per_ms);
            elapsed += 100;
        }
        backoff_ms = @min(backoff_ms * 2, max_backoff);
    }
}

fn runSession(self: *MqttClient) !void {
    const addr = std.net.Address.resolveIp(self.config.host, self.config.port) catch {
        return error.DnsFailed;
    };

    const stream = try std.net.tcpConnectToAddress(addr);
    errdefer stream.close();

    try sendConnect(self, stream);

    // Read CONNACK using raw stream
    var rx_buf: [RX_BUF_SIZE]u8 = undefined;
    var rx_len: usize = 0;

    // Read at least 4 bytes for CONNACK
    while (rx_len < 4) {
        const n = try stream.read(rx_buf[rx_len..]);
        if (n == 0) return error.ConnectionClosed;
        rx_len += n;
    }

    if (rx_len < 2) return error.InvalidConnack;
    if (rx_buf[0] != 0x20) return error.ExpectedConnack;
    var pos: usize = 2;
    // Skip remaining length byte(s)
    while (pos < rx_len and (rx_buf[pos - 1] & 0x80) != 0) pos += 1;
    if (rx_len < pos + 2) return error.InvalidConnack;
    const ret_code = rx_buf[pos + 1];
    if (ret_code != 0) {
        log.err("MQTT connection rejected: code {d}", .{ret_code});
        return switch (ret_code) {
            1 => error.UnacceptableProtocolVersion,
            2 => error.IdentifierRejected,
            3 => error.ServerUnavailable,
            4 => error.BadUsernameOrPassword,
            5 => error.NotAuthorized,
            else => error.ConnectionRejected,
        };
    }

    self.stream = stream;
    self.connected.store(true, .release);

    log.info("MQTT connected to {s}:{d}", .{ self.config.host, self.config.port });

    if (self.on_connect) |cb| cb();

    try readLoop(self, stream, &rx_buf, &rx_len);
}

fn sendConnect(self: *MqttClient, stream: std.net.Stream) !void {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    // Protocol name + level
    try w.writeAll("MQTT");
    try w.writeByte(4);

    // Connect flags
    var flags: u8 = 0;
    if (self.config.username != null and self.config.password != null) {
        flags = 0xC0;
    } else if (self.config.username != null) {
        flags = 0x80;
    }
    try w.writeByte(flags);

    // Keepalive (60 seconds)
    try w.writeInt(u16, 60, .big);

    // Client ID (2-byte length + data)
    try w.writeInt(u16, @intCast(self.config.client_id.len), .big);
    try w.writeAll(self.config.client_id);

    // Username
    if (self.config.username) |u| {
        try w.writeInt(u16, @intCast(u.len), .big);
        try w.writeAll(u);
    }

    // Password
    if (self.config.password) |p| {
        try w.writeInt(u16, @intCast(p.len), .big);
        try w.writeAll(p);
    }

    const payload = fbs.getWritten();
    var hdr: [5]u8 = undefined;
    const header = encodeHeader(0x10, payload.len, &hdr);

    try stream.writeAll(header);
    try stream.writeAll(payload);
}

fn readLoop(self: *MqttClient, stream: std.net.Stream, rx_buf: *[RX_BUF_SIZE]u8, rx_len: *usize) !void {
    var last_ping = std.time.milliTimestamp();

    while (!self.should_stop.load(.acquire)) {
        var pollable = [1]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const rc = std.posix.poll(pollable[0..], 100) catch |err| {
            if (err == error.INTR) continue;
            return error.PollFailed;
        };

        if (rc == 0) {
            const now = std.time.milliTimestamp();
            if (now - last_ping >= 25000) {
                try sendPing(self, stream);
                last_ping = now;
            }
            continue;
        }

        if (pollable[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
            return error.ConnectionClosed;
        }

        if (pollable[0].revents & std.posix.POLL.IN == 0) continue;

        // Read available data
        while (rx_len.* < RX_BUF_SIZE) {
            const n = stream.read(rx_buf[rx_len.*..]) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            rx_len.* += n;
        }

        // Try to parse and dispatch packets
        var processed: usize = 0;
        while (processed < rx_len.*) {
            const consumed = try dispatchPacket(self, rx_buf.*[processed..rx_len.*]);
            if (consumed == 0) break;
            processed += consumed;
        }

        // Move remaining data to front
        if (processed > 0 and processed < rx_len.*) {
            std.mem.copyForwards(u8, rx_buf[0 .. rx_len.* - processed], rx_buf[processed..rx_len.*]);
        }
        rx_len.* -= processed;
    }
}

fn dispatchPacket(self: *MqttClient, data: []const u8) !usize {
    if (data.len < 2) return 0;

    const msg_type = data[0] & 0xF0;

    // Decode remaining length
    var remaining: usize = 0;
    var multiplier: usize = 1;
    var hdr_len: usize = 1;
    var i: usize = 1;
    while (i < data.len and i < 5) {
        remaining += (data[i] & 0x7F) * multiplier;
        multiplier *= 128;
        hdr_len += 1;
        if ((data[i] & 0x80) == 0) break;
        i += 1;
    } else {
        if (i >= 5) return 0; // malformed
    }

    if (data.len < hdr_len + remaining) return 0; // incomplete

    const body = data[hdr_len .. hdr_len + remaining];

    switch (msg_type) {
        0x30 => { // PUBLISH
            if (body.len < 2) return hdr_len;
            const topic_len = std.mem.readInt(u16, body[0..2], .big);
            if (body.len < 2 + topic_len) return hdr_len;
            const topic = body[2..][0..topic_len];
            const payload = body[2 + topic_len ..];
            if (self.on_message) |cb| cb(topic, payload);
        },
        0x40, 0x50, 0x60, 0x70 => {}, // PUBACK, PUBREC, PUBREL, PUBCOMP
        0x90 => { // SUBACK
            log.debug("MQTT SUBACK", .{});
        },
        0xD0 => { // PINGRESP
            log.debug("MQTT PINGRESP", .{});
        },
        else => {
            log.debug("MQTT unhandled type 0x{X}", .{msg_type});
        },
    }

    return hdr_len + remaining;
}

fn sendPing(self: *MqttClient, stream: std.net.Stream) !void {
    const ping = [2]u8{ 0xC0, 0x00 };
    stream.writeAll(&ping) catch {
        self.connected.store(false, .release);
        return error.WriteFailed;
    };
    log.debug("MQTT PINGREQ sent", .{});
}

fn encodeHeader(msg_type: u8, remaining_len: usize, buf: *[5]u8) []const u8 {
    buf[0] = msg_type;
    var pos: usize = 1;
    var len = remaining_len;
    while (pos < 5) {
        var byte: u8 = @truncate(@as(u32, @intCast(len)) % 128);
        len /= 128;
        if (len > 0) byte |= 0x80;
        buf[pos] = byte;
        pos += 1;
        if (len == 0) break;
    }
    return buf[0..pos];
}
