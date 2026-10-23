// TikTok LIVE chat reader in Zig. No Python, no browser automation for the chat path.
// Usage: ./live-chat <signed-wss-url-file> [room_id]
// Cookies read from /tmp/tt_cookies.json (grabbed via Lightpanda).
const std = @import("std");
const xg = @import("xgorgon.zig");
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("zlib.h");
});

fn fail(msg: []const u8) noreturn {
    std.debug.print("FAIL: {s}\n", .{msg});
    std.process.exit(1);
}

// ---------- HTTPS GET (for cookies) ----------
fn httpsGet(alloc: std.mem.Allocator, host: []const u8, path: []const u8) ![]u8 {
    const host_z = try alloc.dupeZ(u8, host);
    defer alloc.free(host_z);
    // via SNI forwarder
    const stream = try std.net.tcpConnectToHost(alloc, "127.0.0.1", 443);
    defer stream.close();
    const fd = stream.handle;
    const ctx = c.SSL_CTX_new(c.TLS_client_method()) orelse return error.Tls;
    defer c.SSL_CTX_free(ctx);
    const ssl = c.SSL_new(ctx) orelse return error.Tls;
    defer c.SSL_free(ssl);
    _ = c.SSL_set_tlsext_host_name(ssl, host_z.ptr);
    if (c.SSL_set_fd(ssl, fd) != 1) return error.Tls;
    if (c.SSL_connect(ssl) != 1) return error.Tls;
    const req = try std.fmt.allocPrint(alloc,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\nConnection: close\r\n\r\n",
        .{ path, host });
    defer alloc.free(req);
    var w: usize = 0;
    while (w < req.len) {
        const n = c.SSL_write(ssl, req.ptr + w, @intCast(req.len - w));
        if (n <= 0) return error.Write;
        w += @intCast(n);
    }
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.SSL_read(ssl, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(alloc);
}

// ---------- Signed HTTPS GET (X-Gorgon) for TikTok API ----------
fn httpsGetSigned(alloc: std.mem.Allocator, host: []const u8, path_with_params: []const u8) ![]u8 {
    // split path and query for signing (sign the query string)
    const qpos = std.mem.indexOf(u8, path_with_params, "?");
    const query = if (qpos) |p| path_with_params[p + 1 ..] else "";
    const sig = try xg.getXG(alloc, query, "", "");
    const host_z = try alloc.dupeZ(u8, host);
    defer alloc.free(host_z);
    const stream = try std.net.tcpConnectToHost(alloc, "127.0.0.1", 443);
    defer stream.close();
    const fd = stream.handle;
    const ctx = c.SSL_CTX_new(c.TLS_client_method()) orelse return error.Tls;
    defer c.SSL_CTX_free(ctx);
    const ssl = c.SSL_new(ctx) orelse return error.Tls;
    defer c.SSL_free(ssl);
    _ = c.SSL_set_tlsext_host_name(ssl, host_z.ptr);
    if (c.SSL_set_fd(ssl, fd) != 1) return error.Tls;
    if (c.SSL_connect(ssl) != 1) return error.Tls;
    const khronos_str = try std.fmt.allocPrint(alloc, "{d}", .{sig.khronos});
    defer alloc.free(khronos_str);
    const req = try std.fmt.allocPrint(alloc,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\nX-Gorgon: {s}\r\nX-Khronos: {s}\r\nConnection: close\r\n\r\n",
        .{ path_with_params, host, sig.gorgon, khronos_str });
    defer alloc.free(req);
    var w: usize = 0;
    while (w < req.len) {
        const n = c.SSL_write(ssl, req.ptr + w, @intCast(req.len - w));
        if (n <= 0) return error.Write;
        w += @intCast(n);
    }
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.SSL_read(ssl, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(alloc);
}

// ---------- minimal protobuf wire reader ----------
const PbReader = struct {
    data: []const u8,
    pos: usize = 0,
    fn eof(self: *@This()) bool {
        return self.pos >= self.data.len;
    }
    fn readVarint(self: *@This()) !u64 {
        var shift: u6 = 0;
        var result: u64 = 0;
        while (self.pos < self.data.len) {
            const b = self.data[self.pos];
            self.pos += 1;
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) return result;
            shift += 7;
            if (shift > 63) return error.VarintOverflow;
        }
        return error.Truncated;
    }
    // returns field number, wire type, and raw value bytes (for len-delimited) or varint
    const Field = struct {
        num: u32,
        wire: u3,
        varint_val: u64 = 0,
        bytes_val: []const u8 = &.{},
    };
    fn next(self: *@This()) !?Field {
        if (self.eof()) return null;
        const tag = try self.readVarint();
        const num: u32 = @intCast(tag >> 3);
        const wire: u3 = @intCast(tag & 7);
        var f = Field{ .num = num, .wire = wire };
        switch (wire) {
            0 => f.varint_val = try self.readVarint(),
            2 => {
                const len = try self.readVarint();
                if (self.pos + len > self.data.len) return error.Truncated;
                f.bytes_val = self.data[self.pos .. self.pos + @as(usize, @intCast(len))];
                self.pos += @as(usize, @intCast(len));
            },
            5 => {
                if (self.pos + 4 > self.data.len) return error.Truncated;
                self.pos += 4;
            },
            1 => {
                if (self.pos + 8 > self.data.len) return error.Truncated;
                self.pos += 8;
            },
            else => return error.BadWireType,
        }
        return f;
    }
};

// ---------- gzip via zlib ----------
fn gunzip(alloc: std.mem.Allocator, in: []const u8) ![]u8 {
    var strm: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.inflateInit2_(&strm, 31, c.ZLIB_VERSION, @sizeOf(c.z_stream)) != c.Z_OK) return error.InflateInit;
    defer _ = c.inflateEnd(&strm);
    strm.next_in = @constCast(in.ptr);
    strm.avail_in = @intCast(in.len);
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        strm.next_out = &buf;
        strm.avail_out = buf.len;
        const ret = c.inflate(&strm, c.Z_NO_FLUSH);
        const have = buf.len - strm.avail_out;
        try out.appendSlice(alloc, buf[0..have]);
        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) return error.Inflate;
        if (have == 0) break;
    }
    return out.toOwnedSlice(alloc);
}

// ---------- protobuf writer (for enter_room) ----------
const PbWriter = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    fn init(a: std.mem.Allocator) @This() {
        return .{ .buf = .{}, .alloc = a };
    }
    fn deinit(self: *@This()) void {
        self.buf.deinit(self.alloc);
    }
    fn rawVarint(self: *@This(), v: u64) !void {
        var x = v;
        while (x >= 0x80) {
            try self.buf.append(self.alloc, @intCast((x & 0x7F) | 0x80));
            x >>= 7;
        }
        try self.buf.append(self.alloc, @intCast(x));
    }
    fn varint(self: *@This(), field: u32, v: u64) !void {
        try self.buf.append(self.alloc, @intCast((field << 3) | 0));
        try self.rawVarint(v);
    }
    fn string(self: *@This(), field: u32, s: []const u8) !void {
        try self.buf.append(self.alloc, @intCast((field << 3) | 2));
        try self.rawVarint(s.len);
        try self.buf.appendSlice(self.alloc, s);
    }
};

fn sendWs(ssl: ?*c.SSL, payload: []const u8) !void {
    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);
    var hdr: [14]u8 = undefined;
    var hlen: usize = 2;
    hdr[0] = 0x82;
    if (payload.len < 126) {
        hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len < 65536) {
        hdr[1] = 0x80 | 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
        hlen = 4;
    } else {
        hdr[1] = 0x80 | 127;
        std.mem.writeInt(u64, hdr[2..10], @intCast(payload.len), .big);
        hlen = 10;
    }
    @memcpy(hdr[hlen .. hlen + 4], &mask);
    hlen += 4;
    var w: usize = 0;
    while (w < hlen) {
        const n = c.SSL_write(ssl, hdr[w..hlen].ptr, @intCast(hlen - w));
        if (n <= 0) return error.WriteFail;
        w += @intCast(n);
    }
    var mbuf: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const chunk = @min(mbuf.len, payload.len - off);
        for (payload[off .. off + chunk], 0..) |b, i| mbuf[i] = b ^ mask[(off + i) % 4];
        var cw: usize = 0;
        while (cw < chunk) {
            const n = c.SSL_write(ssl, mbuf[cw..chunk].ptr, @intCast(chunk - cw));
            if (n <= 0) return error.WriteFail;
            cw += @intCast(n);
        }
        off += chunk;
    }
}

fn sslReadAll(ssl: ?*c.SSL, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.SSL_read(ssl, buf[total..].ptr, @intCast(buf.len - total));
        if (n <= 0) {
            if (total == 0) return error.Closed;
            break;
        }
        total += @intCast(n);
    }
    return total;
}

// Extract nickname + content from a WebcastChatMessage payload.
// WebcastChatMessage: field 2 = user (msg), field 3 = content (string)
// User: field 3 = nickname (string)
fn printChat(payload: []const u8) void {
    var r = PbReader{ .data = payload };
    var nickname: []const u8 = "?";
    var content: []const u8 = "";
    while (r.next() catch null) |f| {
        if (f.wire != 2) continue;
        if (f.num == 2) {
            var sub = PbReader{ .data = f.bytes_val };
            while (sub.next() catch null) |sf| {
                if (sf.num == 3 and sf.wire == 2 and sf.bytes_val.len > 0) {
                    nickname = sf.bytes_val;
                    break;
                }
            }
        }
        if (f.num == 3 and f.bytes_val.len > 0) {
            content = f.bytes_val;
        }
    }
    if (content.len > 0) {
        std.debug.print("CHAT {s}: {s}\n", .{ nickname, content });
    }
}

// ---------- reusable websocket connect ----------
// A connected TikTok live room: TCP -> TLS (via SNI forwarder) -> native
// cookie fetch -> HTTP upgrade -> im_enter_room. Shared by the normal chat
// reader and --fuzz-ws so both use one handshake implementation.
const WsConn = struct {
    stream: std.net.Stream,
    ssl: *c.SSL,
    ctx: *c.SSL_CTX,
    fn close(self: *@This()) void {
        c.SSL_free(self.ssl);
        c.SSL_CTX_free(self.ctx);
        self.stream.close();
    }
};

fn buildWsUrl(alloc: std.mem.Allocator, room_id: u64) ![]u8 {
    // param template derived from working URLs; wrss value is not validated
    return std.fmt.allocPrint(alloc,
        "wss://webcast-ws.tiktok.com/webcast/im/ws_proxy/ws_reuse_supplement/?" ++
            "aid=1988&app_language=en-US&app_name=tiktok_web&browser_language=en-US&" ++
            "browser_name=Mozilla&browser_online=true&browser_platform=Win32&" ++
            "browser_version=5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20Chrome%2F120.0.0.0%20Safari%2F537.36&" ++
            "client_enter=1&compress=gzip&cookie_enabled=true&device_platform=web&did_rule=3&" ++
            "heartbeat_duration=15000&history_comment_count=50&identity=audience&" ++
            "last_rtt=0&live_id=12&resp_content_type=protobuf&room_id={d}&" ++
            "screen_height=1080&screen_width=1920&sup_ws_ds_opt=1&tz_name=America%2FPhoenix&" ++
            "update_version_code=270000&version_code=270000&webcast_language=en&" ++
            "wrss=dummy&ws_direct=true",
        .{room_id});
}

fn connectRoom(alloc: std.mem.Allocator, room_id: u64) !WsConn {
    const ws_url = try buildWsUrl(alloc, room_id);
    defer alloc.free(ws_url);
    const url_raw = ws_url;

    const url = if (std.mem.startsWith(u8, url_raw, "wss://")) url_raw[6..] else return error.BadUrl;
    const slash = std.mem.indexOfScalar(u8, url, '/') orelse return error.BadUrl;
    const host = url[0..slash];
    const path = url[slash..];
    const host_z = try alloc.dupeZ(u8, host);
    defer alloc.free(host_z);

    const stream = try std.net.tcpConnectToHost(alloc, "127.0.0.1", 443);
    errdefer stream.close();
    const fd = stream.handle;
    _ = c.OPENSSL_init_ssl(0, null);
    const ctx = c.SSL_CTX_new(c.TLS_client_method()) orelse return error.Tls;
    errdefer c.SSL_CTX_free(ctx);
    _ = c.SSL_CTX_set_cipher_list(ctx, "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305");
    const ssl = c.SSL_new(ctx) orelse return error.Tls;
    errdefer c.SSL_free(ssl);
    _ = c.SSL_set_tlsext_host_name(ssl, host_z.ptr);
    if (c.SSL_set_fd(ssl, fd) != 1) return error.Tls;
    if (c.SSL_connect(ssl) != 1) return error.Tls;
    std.debug.print("TLS ok\n", .{});

    // cookies: fetch natively via HTTPS (no JS needed for ttwid/csrf/chain_token)
    var cookie_header: std.ArrayList(u8) = .{};
    defer cookie_header.deinit(alloc);
    {
        const resp = httpsGet(alloc, "www.tiktok.com", "/") catch |e| {
            std.debug.print("cookie fetch failed: {}\n", .{e});
            return error.NoCookies;
        };
        defer alloc.free(resp);
        var first = true;
        var lines = std.mem.splitSequence(u8, resp, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) break; // end of headers
            if (std.ascii.startsWithIgnoreCase(line, "set-cookie:")) {
                const kv = std.mem.trim(u8, line["set-cookie:".len..], " ");
                const semi = std.mem.indexOfScalar(u8, kv, ';') orelse kv.len;
                if (!first) try cookie_header.appendSlice(alloc, "; ");
                first = false;
                try cookie_header.appendSlice(alloc, kv[0..semi]);
            }
        }
    }
    std.debug.print("cookies: {d} bytes\n", .{cookie_header.items.len});
    if (cookie_header.items.len == 0) return error.NoCookies;

    var key_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&key_bytes);
    var key_buf: [32]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

    const req = try std.fmt.allocPrint(alloc,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" ++
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Protocol: echo-protocol\r\n" ++
            "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\n" ++
            "Origin: https://www.tiktok.com\r\nAccept-Language: en-US,en;q=0.9\r\nCookie: {s}\r\n\r\n",
        .{ path, host, key, cookie_header.items });
    defer alloc.free(req);
    var w: usize = 0;
    while (w < req.len) {
        const n = c.SSL_write(ssl, req.ptr + w, @intCast(req.len - w));
        if (n <= 0) return error.WriteReq;
        w += @intCast(n);
    }
    var resp_buf: [8192]u8 = undefined;
    var rlen: usize = 0;
    while (rlen < resp_buf.len) {
        const n = c.SSL_read(ssl, resp_buf[rlen..].ptr, @intCast(resp_buf.len - rlen));
        if (n <= 0) break;
        rlen += @intCast(n);
        if (std.mem.indexOf(u8, resp_buf[0..rlen], "\r\n\r\n") != null) break;
    }
    var got101 = false;
    var it = std.mem.splitSequence(u8, resp_buf[0..rlen], "\r\n");
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "101") != null and std.mem.indexOf(u8, line, "HTTP/") != null) got101 = true;
        if (line.len == 0) break;
    }
    if (!got101) {
        std.debug.print("no 101. resp:\n{s}\n", .{resp_buf[0..@min(rlen, 600)]});
        return error.No101;
    }
    std.debug.print("connected. entering room {d}\n", .{room_id});

    // im_enter_room
    {
        var inner = PbWriter.init(alloc);
        defer inner.deinit();
        try inner.varint(1, room_id);
        try inner.varint(4, 12);
        try inner.string(5, "audience");
        try inner.string(9, "0");
        var frame = PbWriter.init(alloc);
        defer frame.deinit();
        try frame.string(6, "pb");
        try frame.string(7, "im_enter_room");
        try frame.string(8, inner.buf.items);
        try sendWs(ssl, frame.buf.items);
    }

    return WsConn{ .stream = stream, .ssl = ssl, .ctx = ctx };
}

// One binary websocket PushFrame: field 7 (method) + field 8 (payload).
// method/pdata borrow from the owned `payload` slice; free it when done.
const WsFrame = struct {
    method: []const u8,
    pdata: []const u8,
    payload: []u8,
};

fn readPushFrame(alloc: std.mem.Allocator, ssl: *c.SSL) !?WsFrame {
    while (true) {
        var hdr: [2]u8 = undefined;
        if ((sslReadAll(ssl, &hdr) catch return null) != 2) return null;
        const opcode = hdr[0] & 0x0F;
        if (opcode == 0x8) return null; // close
        if (opcode == 0x9) { // ping -> pong
            var pong_hdr = [2]u8{ 0x8A, 0x00 };
            _ = c.SSL_write(ssl, &pong_hdr, 2);
            continue;
        }
        var plen: u64 = hdr[1] & 0x7F;
        if (plen == 126) {
            var ext: [2]u8 = undefined;
            if ((sslReadAll(ssl, &ext) catch return null) != 2) return null;
            plen = std.mem.readInt(u16, &ext, .big);
        } else if (plen == 127) {
            var ext: [8]u8 = undefined;
            if ((sslReadAll(ssl, &ext) catch return null) != 8) return null;
            plen = std.mem.readInt(u64, &ext, .big);
        }
        if (plen > 10 * 1024 * 1024) return error.FrameTooBig;
        const payload = try alloc.alloc(u8, @intCast(plen));
        errdefer alloc.free(payload);
        if ((sslReadAll(ssl, payload) catch return null) != payload.len) {
            alloc.free(payload);
            return null;
        }
        if (opcode != 0x2) {
            alloc.free(payload);
            continue;
        }
        var fr = PbReader{ .data = payload };
        var method: []const u8 = "";
        var pdata: []const u8 = &.{};
        while (fr.next() catch null) |f| {
            if (f.wire != 2) continue;
            if (f.num == 7) method = f.bytes_val;
            if (f.num == 8) pdata = f.bytes_val;
        }
        return WsFrame{ .method = method, .pdata = pdata, .payload = payload };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    if (args.len < 2) fail("usage: live-chat <username> | live-chat --history <room_id> | live-chat --fuzz-ws <room_id> <payload_type>");
    // fuzz-ws mode: probe a websocket method name against a live room, report responses.
    // Any method that returns a non-empty payload is a HIT candidate for the history mechanism.
    if (std.mem.eql(u8, args[1], "--fuzz-ws")) {
        if (args.len < 4) fail("usage: live-chat --fuzz-ws <room_id> <method>");
        const room_id = std.fmt.parseInt(u64, args[2], 10) catch fail("bad room id");
        const method = args[3];
        std.debug.print("fuzz-ws: room {d}, method '{s}'\n", .{ room_id, method });
        var conn = try connectRoom(alloc, room_id);
        defer conn.close();
        // probe frame: WebcastPushFrame {6:"pb", 7: method, 8: empty inner}
        {
            var frame = PbWriter.init(alloc);
            defer frame.deinit();
            try frame.string(6, "pb");
            try frame.string(7, method);
            try frame.string(8, "");
            try sendWs(conn.ssl, frame.buf.items);
        }
        std.debug.print("probe sent, reading 20s...\n", .{});
        var hits: usize = 0;
        var frames: usize = 0;
        const deadline = std.time.milliTimestamp() + 20000;
        while (std.time.milliTimestamp() < deadline) {
            const fr = readPushFrame(alloc, conn.ssl) catch break;
            const f = fr orelse break;
            defer alloc.free(f.payload);
            frames += 1;
            const gzipped = f.pdata.len > 2 and f.pdata[0] == 0x1f and f.pdata[1] == 0x8b;
            std.debug.print("frame {d}: method='{s}' payload={d} bytes{s}\n", .{ frames, f.method, f.pdata.len, if (gzipped) " (gzip)" else "" });
            if (f.pdata.len > 0) {
                hits += 1;
                std.debug.print("  HIT: first bytes: ", .{});
                for (f.pdata[0..@min(f.pdata.len, 48)]) |b| std.debug.print("{x:0>2} ", .{b});
                std.debug.print("\n", .{});
            }
        }
        std.debug.print("fuzz-ws done: {d} frames, {d} hits\n", .{ frames, hits });
        return;
    }
    // field-dump mode: decode EVERY field of every incoming frame instead of
    // only the fields the chat reader knows about. This is the history hunt:
    // the connect URL asks for history_comment_count=50, so a cursor/history
    // field (if one exists on the wire) shows up here on im_enter_room_resp
    // or on "msg" WebcastResponse frames. Prints field num, wire type, and a
    // value preview; gunzips gzipped payloads first.
    // Usage: live-chat --field-dump <room_id>   (get room_id from: live-chat <username>)
    if (std.mem.eql(u8, args[1], "--field-dump")) {
        if (args.len < 3) fail("usage: live-chat --field-dump <room_id>");
        const room_id = std.fmt.parseInt(u64, args[2], 10) catch fail("bad room id");
        std.debug.print("field-dump: room {d}, reading 30s...\n", .{room_id});
        var conn = try connectRoom(alloc, room_id);
        defer conn.close();
        const deadline = std.time.milliTimestamp() + 30000;
        var frames: usize = 0;
        while (std.time.milliTimestamp() < deadline) {
            const fr = readPushFrame(alloc, conn.ssl) catch break;
            const f = fr orelse break;
            defer alloc.free(f.payload);
            frames += 1;
            var decoded: []const u8 = f.pdata;
            var owned: ?[]u8 = null;
            defer if (owned) |o| alloc.free(o);
            if (f.pdata.len > 2 and f.pdata[0] == 0x1f and f.pdata[1] == 0x8b) {
                owned = gunzip(alloc, f.pdata) catch {
                    std.debug.print("frame {d}: method='{s}' gzip-decode FAILED ({d} bytes)\n", .{ frames, f.method, f.pdata.len });
                    continue;
                };
                decoded = owned.?;
            }
            std.debug.print("frame {d}: method='{s}' raw={d} decoded={d}\n", .{ frames, f.method, f.pdata.len, decoded.len });
            var r = PbReader{ .data = decoded };
            while (r.next()) |mf| {
                const fld = mf orelse break;
                if (fld.wire == 0) {
                    std.debug.print("  field {d} varint = {d}\n", .{ fld.num, fld.varint_val });
                } else if (fld.wire == 2) {
                    const b = fld.bytes_val;
                    const pl = @min(b.len, 48);
                    std.debug.print("  field {d} bytes[{d}]: ", .{ fld.num, b.len });
                    for (b[0..pl]) |byte| std.debug.print("{x:0>2} ", .{byte});
                    var printable = true;
                    for (b[0..pl]) |byte| {
                        if (byte < 0x20 or byte > 0x7e) { printable = false; break; }
                    }
                    if (printable and pl > 0) std.debug.print(" \"{s}\"", .{b[0..pl]});
                    std.debug.print("\n", .{});
                } else {
                    std.debug.print("  field {d} wire {d}\n", .{ fld.num, fld.wire });
                }
            } else |_| {}
        }
        std.debug.print("field-dump done: {d} frames\n", .{frames});
        return;
    }
    // history test mode: signed fetch against webcast API
    if (std.mem.eql(u8, args[1], "--history")) {
        if (args.len < 3) fail("usage: live-chat --history <room_id>");
        const room_id = args[2];
        const path = try std.fmt.allocPrint(alloc, "/webcast/im/fetch/?aid=1233&room_id={s}&cursor=0", .{room_id});
        defer alloc.free(path);
        const resp = httpsGetSigned(alloc, "webcast.tiktok.com", path) catch |e| {
            std.debug.print("signed fetch failed: {}\n", .{e});
            std.process.exit(1);
        };
        defer alloc.free(resp);
        // print body after headers
        if (std.mem.indexOf(u8, resp, "\r\n\r\n")) |hi| {
            const body = resp[hi + 4 ..];
            const print_len = @min(body.len, 2000);
            std.debug.print("signed fetch OK, body ({d} bytes):\n{s}\n", .{ body.len, body[0..print_len] });
        } else {
            std.debug.print("no body separator found\n", .{});
        }
        return;
    }
    const username = args[1];

    // get room_id natively from the live page HTML
    var room_id: u64 = 0;
    {
        const live_path = try std.fmt.allocPrint(alloc, "/@{s}/live", .{username});
        defer alloc.free(live_path);
        const html = httpsGet(alloc, "www.tiktok.com", live_path) catch fail("room lookup");
        defer alloc.free(html);
        // find "roomId":"<digits>" in SIGI_STATE JSON
        const needle = "\"roomId\":\"";
        if (std.mem.indexOf(u8, html, needle)) |idx| {
            const start = idx + needle.len;
            var end = start;
            while (end < html.len and html[end] >= '0' and html[end] <= '9') : (end += 1) {}
            room_id = std.fmt.parseInt(u64, html[start..end], 10) catch fail("bad room id");
        } else fail("roomId not found (user offline?)");
    }
    std.debug.print("room {d} for @{s}\n", .{ room_id, username });

    var conn = try connectRoom(alloc, room_id);
    defer conn.close();
    const ssl = conn.ssl;

    // read loop
    var nchat: usize = 0;
    const deadline = std.time.milliTimestamp() + 120000;
    while (std.time.milliTimestamp() < deadline) {
        var hdr: [2]u8 = undefined;
        if ((sslReadAll(ssl, &hdr) catch break) != 2) break;
        const opcode = hdr[0] & 0x0F;
        if (opcode == 0x8) break; // close
        if (opcode == 0x9) { // ping -> pong
            var pong_hdr = [2]u8{ 0x8A, 0x00 };
            _ = c.SSL_write(ssl, &pong_hdr, 2);
            continue;
        }
        var plen: u64 = hdr[1] & 0x7F;
        if (plen == 126) {
            var ext: [2]u8 = undefined;
            _ = sslReadAll(ssl, &ext) catch break;
            plen = std.mem.readInt(u16, &ext, .big);
        } else if (plen == 127) {
            var ext: [8]u8 = undefined;
            _ = sslReadAll(ssl, &ext) catch break;
            plen = std.mem.readInt(u64, &ext, .big);
        }
        if (plen > 10 * 1024 * 1024) break;
        const payload = try alloc.alloc(u8, @intCast(plen));
        defer alloc.free(payload);
        _ = sslReadAll(ssl, payload) catch break;
        if (opcode != 0x2) continue;

        // parse WebcastPushFrame
        var fr = PbReader{ .data = payload };
        var ptype: []const u8 = "";
        var pdata: []const u8 = &.{};
        while (fr.next()) |mf| {
            const f = mf orelse break;
            if (f.wire != 2) continue;
            if (f.num == 7) ptype = f.bytes_val; // payload_type
            if (f.num == 8) pdata = f.bytes_val; // payload
        } else |_| continue;
        if (pdata.len == 0) continue;

        // gunzip if gzipped
        var decoded: []const u8 = pdata;
        var owned: ?[]u8 = null;
        defer if (owned) |o| alloc.free(o);
        if (pdata.len > 2 and pdata[0] == 0x1f and pdata[1] == 0x8b) {
            owned = gunzip(alloc, pdata) catch continue;
            decoded = owned.?;
        }

        if (std.mem.eql(u8, ptype, "msg")) {
            // WebcastResponse: field 1 repeated = messages
            var rr = PbReader{ .data = decoded };
            while (rr.next()) |mmf| {
                const mf2 = mmf orelse break;
                if (mf2.wire != 2 or mf2.num != 1) continue;
                // WebcastMessage: field 1 = method, field 2 = payload
                var mr = PbReader{ .data = mf2.bytes_val };
                var method: []const u8 = "";
                var mdata: []const u8 = &.{};
                while (mr.next()) |mmmf| {
                    const f3 = mmmf orelse break;
                    if (f3.wire != 2) continue;
                    if (f3.num == 1) method = f3.bytes_val;
                    if (f3.num == 2) mdata = f3.bytes_val;
                } else |_| continue;
                if (std.mem.eql(u8, method, "WebcastChatMessage") and mdata.len > 0) {
                    printChat(mdata);
                    nchat += 1;
                }
            } else |_| {}
        }
    }
    std.debug.print("done, {d} chat messages\n", .{nchat});
}
