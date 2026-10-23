const std = @import("std");

const HOST = "127.0.0.1";
const PORT = 9222;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stream = try std.net.tcpConnectToHost(alloc, HOST, PORT);
    defer stream.close();
    var ws = WsConn{ .stream = stream, .alloc = alloc };

    try ws.handshake("/");
    std.debug.print("websocket handshake ok\n", .{});

    var id: u32 = 0;

    // Target.createTarget
    id += 1;
    try ws.sendJson(id, "Target.createTarget", "{\"url\":\"about:blank\"}", null);
    const t1 = try ws.recvForId(alloc, id);
    defer alloc.free(t1);
    const target_id = try extractString(alloc, t1, "targetId");
    defer alloc.free(target_id);
    std.debug.print("target: {s}\n", .{target_id});

    // Target.attachToTarget
    id += 1;
    const attach_params = try std.fmt.allocPrint(alloc, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{target_id});
    defer alloc.free(attach_params);
    try ws.sendJson(id, "Target.attachToTarget", attach_params, null);
    const t2 = try ws.recvForId(alloc, id);
    defer alloc.free(t2);
    const session_id = try extractString(alloc, t2, "sessionId");
    defer alloc.free(session_id);
    std.debug.print("session: {s}\n", .{session_id});

    // Page.navigate to the game
    id += 1;
    try ws.sendJson(id, "Page.navigate", "{\"url\":\"http://127.0.0.1:8124/neon-swarm.html\"}", session_id);
    const t3 = try ws.recvForId(alloc, id);
    defer alloc.free(t3);
    std.debug.print("navigated\n", .{});
    std.Thread.sleep(4 * std.time.ns_per_s);

    // Page.captureScreenshot
    id += 1;
    try ws.sendJson(id, "Page.captureScreenshot", "{\"format\":\"png\"}", session_id);
    const t4 = try ws.recvForId(alloc, id);
    defer alloc.free(t4);

    const b64data = try extractString(alloc, t4, "data");
    defer alloc.free(b64data);
    std.debug.print("got {d} base64 chars\n", .{b64data.len});

    // strip data URI prefix if present
    var b64 = b64data;
    if (std.mem.indexOf(u8, b64, ",")) |idx| {
        if (std.mem.startsWith(u8, b64, "data:")) b64 = b64[idx + 1 ..];
    }

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, b64);

    const out = try std.fs.cwd().createFile("zig-shot.png", .{});
    defer out.close();
    try out.writeAll(decoded);
    std.debug.print("wrote zig-shot.png ({d} bytes)\n", .{decoded.len});
}

const WsConn = struct {
    stream: std.net.Stream,
    alloc: std.mem.Allocator,

    fn handshake(self: *WsConn, path: []const u8) !void {
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(self.alloc);
        try req.writer(self.alloc).print(
            "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, HOST, PORT, key_b64 },
        );
        try self.stream.writeAll(req.items);

        // read until end of headers
        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(self.alloc);
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = try self.stream.read(buf[0..]);
            if (n == 0) return error.Closed;
            try resp.appendSlice(self.alloc, buf[0..n]);
            if (std.mem.indexOf(u8, resp.items, "\r\n\r\n") != null) break;
            if (resp.items.len > 8192) return error.HeadersTooBig;
        }
        if (!std.mem.startsWith(u8, resp.items, "HTTP/1.1 101")) return error.HandshakeFailed;
    }

    fn sendJson(self: *WsConn, id: u32, method: []const u8, params_json: []const u8, session: ?[]const u8) !void {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.alloc);
        if (session) |s| {
            try msg.writer(self.alloc).print("{{\"id\":{d},\"method\":\"{s}\",\"params\":{s},\"sessionId\":\"{s}\"}}", .{ id, method, params_json, s });
        } else {
            try msg.writer(self.alloc).print("{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json });
        }
        try self.sendFrame(msg.items);
    }

    fn sendFrame(self: *WsConn, payload: []const u8) !void {
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(self.alloc);
        // FIN + text opcode, MASK set
        try hdr.append(self.alloc, 0x81);
        if (payload.len < 126) {
            try hdr.append(self.alloc, 0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len < 65536) {
            try hdr.append(self.alloc, 0x80 | 126);
            try hdr.append(self.alloc, @as(u8, @intCast(payload.len >> 8)));
            try hdr.append(self.alloc, @as(u8, @intCast(payload.len & 0xff)));
        } else {
            try hdr.append(self.alloc, 0x80 | 127);
            const len64: u64 = payload.len;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                try hdr.append(self.alloc, @as(u8, @intCast((len64 >> @intCast((7 - i) * 8)) & 0xff)));
            }
        }
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        try hdr.appendSlice(self.alloc, &mask);
        try self.stream.writeAll(hdr.items);
        // masked payload
        var i: usize = 0;
        var chunk: [4096]u8 = undefined;
        while (i < payload.len) {
            const n = @min(chunk.len, payload.len - i);
            for (0..n) |j| chunk[j] = payload[i + j] ^ mask[(i + j) % 4];
            try self.stream.writeAll(chunk[0..n]);
            i += n;
        }
    }

    fn recvFrame(self: *WsConn, alloc: std.mem.Allocator) ![]u8 {
        var hb: [2]u8 = undefined;
        try readFull(self.stream, &hb);
        const opcode = hb[0] & 0x0f;
        const masked = (hb[1] & 0x80) != 0;
        var plen: u64 = hb[1] & 0x7f;
        if (plen == 126) {
            var eb: [2]u8 = undefined;
            try readFull(self.stream, &eb);
            plen = (@as(u64, eb[0]) << 8) | eb[1];
        } else if (plen == 127) {
            var eb: [8]u8 = undefined;
            try readFull(self.stream, &eb);
            plen = std.mem.readInt(u64, &eb, .big);
        }
        var mask: [4]u8 = undefined;
        if (masked) try readFull(self.stream, &mask);
        const data = try alloc.alloc(u8, plen);
        errdefer alloc.free(data);
        try readFull(self.stream, data);
        if (masked) {
            for (data, 0..) |*b, i| b.* ^= mask[i % 4];
        }
        if (opcode == 0x8) {
            alloc.free(data);
            return error.WsClosed;
        }
        return data;
    }

    fn recvForId(self: *WsConn, alloc: std.mem.Allocator, want: u32) ![]u8 {
        while (true) {
            const frame = try self.recvFrame(alloc);
            errdefer alloc.free(frame);
            // quick check: does it contain "\"id\":<want>
            var needle: [32]u8 = undefined;
            const ns = try std.fmt.bufPrint(&needle, "\"id\":{d}", .{want});
            if (std.mem.indexOf(u8, frame, ns) != null) return frame;
            alloc.free(frame);
        }
    }
};

fn readFull(stream: std.net.Stream, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try stream.read(buf[off..]);
        if (n == 0) return error.Closed;
        off += n;
    }
}

// extract result.<field> string value from a CDP JSON response (minimal)
fn extractString(alloc: std.mem.Allocator, json_text: []const u8, field: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NoResult;
    const v = result.object.get(field) orelse return error.NoField;
    return try alloc.dupe(u8, v.string);
}
