// X-Gorgon / X-Khronos signature generator, ported from tikvues/tiktok-signatures
// Generates the X-Gorgon header for TikTok API requests.
const std = @import("std");

fn hexString(buf: []u8, num: u8) []u8 {
    const digits = "0123456789abcdef";
    buf[0] = digits[num >> 4];
    buf[1] = digits[num & 0x0f];
    return buf[0..2];
}

fn reverseNibbles(num: u8) u8 {
    return (num << 4) | (num >> 4);
}

fn rbit(num: u8) u8 {
    var v = num;
    v = ((v & 0x55) << 1) | ((v & 0xAA) >> 1);
    v = ((v & 0x33) << 2) | ((v & 0xCC) >> 2);
    v = (v << 4) | (v >> 4);
    return v;
}

pub const XGorgon = struct {
    debug: [20]u8,
    hex_ce0: [8]u8,
    length: usize = 0x14,

    pub fn init(debug: [20]u8, rand: std.Random) XGorgon {
        return .{
            .debug = debug,
            .hex_ce0 = .{
                0x05, 0x00, 0x50,
                rand.int(u8),
                0x47, 0x1E, 0x00,
                @as(u8, @intCast(8 * rand.intRangeAtMost(u8, 0, 0x1E))),
            },
        };
    }

    fn addrBA8(self: *XGorgon, out: *[256]u8) void {
        for (0..256) |i| out[i] = @intCast(i);
        var tmp: u16 = 0;
        var tmp_is_set = false;
        for (0..256) |i| {
            const a: u8 = if (i != 0) out[i - 1] else 0;
            const b: u8 = self.hex_ce0[i % 8];
            var av: u16 = a;
            if (a == 0x05 and i != 1) {
                if (!tmp_is_set or tmp != 0x05) av = 0;
            }
            const c: usize = @intCast((av + i + b) % 256);
            if (c < i) {
                tmp = @intCast(c);
                tmp_is_set = true;
            } else {
                tmp_is_set = false;
            }
            out[i] = out[c];
        }
    }

    fn initial(self: *XGorgon, hex_ba8: [256]u8) void {
        var tmp_hex = hex_ba8;
        var tmp_add: [20]u8 = undefined;
        var tmp_len: usize = 0;
        for (0..self.length) |i| {
            const a = self.debug[i];
            const b: u8 = if (tmp_len > 0) tmp_add[tmp_len - 1] else 0;
            const c: usize = @intCast((@as(usize, hex_ba8[i + 1]) + b) % 256);
            tmp_add[tmp_len] = @intCast(c);
            tmp_len += 1;
            const d = tmp_hex[c];
            tmp_hex[i + 1] = d;
            const e: usize = @intCast((@as(usize, d) * 2) % 256);
            const f = tmp_hex[e];
            self.debug[i] = a ^ f;
        }
    }

    fn calculate(self: *XGorgon) void {
        for (0..self.length) |i| {
            const a = self.debug[i];
            const b = reverseNibbles(a);
            const c = self.debug[(i + 1) % self.length];
            const d: u8 = b ^ c;
            const e = rbit(d);
            const f: u8 = e ^ @as(u8, @intCast(self.length));
            const g: u32 = ~@as(u32, f);
            self.debug[i] = @intCast(g & 0xff);
        }
    }

    /// Writes the 52-char X-Gorgon hex string into out (must be >= 52 bytes).
    /// Returns the timestamp used (X-Khronos).
    pub fn generate(self: *XGorgon, out: *[52]u8) u64 {
        var ba8: [256]u8 = undefined;
        self.addrBA8(&ba8);
        self.initial(ba8);
        self.calculate();
        var pos: usize = 0;
        const prefix = "8402";
        @memcpy(out[pos..][0..4], prefix);
        pos += 4;
        for ([_]u8{ self.hex_ce0[7], self.hex_ce0[3], self.hex_ce0[1], self.hex_ce0[6] }) |v| {
            var hb: [2]u8 = undefined;
            _ = hexString(&hb, v);
            out[pos] = hb[0];
            out[pos + 1] = hb[1];
            pos += 2;
        }
        for (self.debug) |v| {
            var hb: [2]u8 = undefined;
            _ = hexString(&hb, v);
            out[pos] = hb[0];
            out[pos + 1] = hb[1];
            pos += 2;
        }
        return 0; // timestamp returned separately
    }
};

/// Build the 20-byte debug array from params/stub/cookie, then generate signature.
/// Returns X-Gorgon string (52 chars) and X-Khronos timestamp.
pub fn getXG(alloc: std.mem.Allocator, params: []const u8, stub: []const u8, cookie: []const u8) !struct { gorgon: [52]u8, khronos: u64 } {
    _ = alloc;
    var debug: [20]u8 = undefined;

    var h = std.crypto.hash.Md5.init(.{});
    h.update(params);
    var d1: [16]u8 = undefined;
    h.final(&d1);
    @memcpy(debug[0..4], d1[0..4]);

    if (stub.len > 0) {
        var h2 = std.crypto.hash.Md5.init(.{});
        h2.update(stub);
        var d2: [16]u8 = undefined;
        h2.final(&d2);
        @memcpy(debug[4..8], d2[0..4]);
    } else {
        @memset(debug[4..8], 0);
    }

    if (cookie.len > 0) {
        var h3 = std.crypto.hash.Md5.init(.{});
        h3.update(cookie);
        var d3: [16]u8 = undefined;
        h3.final(&d3);
        @memcpy(debug[8..12], d3[0..4]);
    } else {
        @memset(debug[8..12], 0);
    }

    debug[12] = 0x00;
    debug[13] = 0x08;
    debug[14] = 0x10;
    debug[15] = 0x09;

    const ttime: u64 = @intCast(std.time.timestamp());
    const hex_t = std.fmt.hex(ttime);
    _ = hex_t;
    // timestamp as 4 bytes big-endian hex parsed
    var ts_buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&ts_buf, "{x:0>8}", .{ttime}) catch unreachable;
    for (0..4) |i| {
        debug[16 + i] = std.fmt.parseInt(u8, ts_buf[i * 2 .. i * 2 + 2], 16) catch 0;
    }

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    var xg = XGorgon.init(debug, prng.random());
    var out: [52]u8 = undefined;
    _ = xg.generate(&out);
    return .{ .gorgon = out, .khronos = ttime };
}
