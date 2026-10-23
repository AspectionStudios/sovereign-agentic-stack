const std = @import("std");
const z2d = @import("z2d");

const W = 1920;
const H = 1080;

const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

const SavedState = struct {
    transform: z2d.Transformation,
    fill: Rgba,
    stroke: Rgba,
    alpha: f64,
    line_width: f64,
    font_size: f64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // black background
    var sfc = try z2d.Surface.initPixel(.{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, alloc, W, H);
    defer sfc.deinit(alloc);

    var ctx = z2d.Context.init(alloc, &sfc);
    defer ctx.deinit();
    ctx.setAntiAliasingMode(.default);

    // font for fillText
    ctx.setFontToFile("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf") catch |e| {
        std.debug.print("font load failed: {}\n", .{e});
    };

    const data = try std.fs.cwd().readFileAlloc(alloc, "calls.json", 100 * 1024 * 1024);
    defer alloc.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    const calls = parsed.value.array.items;
    std.debug.print("replaying {d} calls\n", .{calls.len});

    var state = SavedState{
        .transform = z2d.Transformation.identity,
        .fill = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .stroke = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .alpha = 1.0,
        .line_width = 1.0,
        .font_size = 14,
    };
    var stack = std.ArrayList(SavedState).empty;
    defer stack.deinit(alloc);

    var n: usize = 0;
    for (calls) |call| {
        const obj = call.object;
        if (obj.get("m")) |m| {
            const name = m.string;
            const args = obj.get("a").?.array.items;
            try doMethod(&ctx, alloc, name, args, &state, &stack);
        } else if (obj.get("p")) |p| {
            const name = p.string;
            const v = obj.get("v").?.string;
            doProp(&state, name, v);
        }
        n += 1;
        if (n % 40000 == 0) std.debug.print("  {d}/{d}\n", .{ n, calls.len });
    }

    try z2d.png_exporter.writeToPNGFile(sfc, "replay.png", .{});
    std.debug.print("wrote replay.png\n", .{});
}

fn applyFill(ctx: *z2d.Context, s: *SavedState) void {
    const a: u8 = @intFromFloat(@as(f64, @floatFromInt(s.fill.a)) * s.alpha);
    ctx.setSourceToPixel(.{ .rgba = .{ .r = s.fill.r, .g = s.fill.g, .b = s.fill.b, .a = a } });
}

fn applyStroke(ctx: *z2d.Context, s: *SavedState) void {
    const a: u8 = @intFromFloat(@as(f64, @floatFromInt(s.stroke.a)) * s.alpha);
    ctx.setSourceToPixel(.{ .rgba = .{ .r = s.stroke.r, .g = s.stroke.g, .b = s.stroke.b, .a = a } });
    ctx.setLineWidth(s.line_width);
}

fn num(args: []std.json.Value, i: usize) f64 {
    if (i >= args.len) return 0;
    const s = args[i].string;
    return std.fmt.parseFloat(f64, s) catch 0;
}

fn str(args: []std.json.Value, i: usize) []const u8 {
    if (i >= args.len) return "";
    return args[i].string;
}

fn doMethod(
    ctx: *z2d.Context,
    alloc: std.mem.Allocator,
    name: []const u8,
    args: []std.json.Value,
    s: *SavedState,
    stack: *std.ArrayList(SavedState),
) !void {
    if (std.mem.eql(u8, name, "beginPath")) {
        ctx.resetPath();
    } else if (std.mem.eql(u8, name, "moveTo")) {
        try ctx.moveTo(num(args, 0), num(args, 1));
    } else if (std.mem.eql(u8, name, "lineTo")) {
        try ctx.lineTo(num(args, 0), num(args, 1));
    } else if (std.mem.eql(u8, name, "arc")) {
        try ctx.arc(num(args, 0), num(args, 1), num(args, 2), num(args, 3), num(args, 4));
    } else if (std.mem.eql(u8, name, "closePath")) {
        try ctx.closePath();
    } else if (std.mem.eql(u8, name, "fill")) {
        applyFill(ctx, s);
        ctx.fill() catch {};
    } else if (std.mem.eql(u8, name, "stroke")) {
        applyStroke(ctx, s);
        ctx.stroke() catch {};
    } else if (std.mem.eql(u8, name, "fillRect")) {
        const x = num(args, 0);
        const y = num(args, 1);
        const w = num(args, 2);
        const h = num(args, 3);
        ctx.resetPath();
        try ctx.moveTo(x, y);
        try ctx.lineTo(x + w, y);
        try ctx.lineTo(x + w, y + h);
        try ctx.lineTo(x, y + h);
        try ctx.closePath();
        applyFill(ctx, s);
        ctx.fill() catch {};
    } else if (std.mem.eql(u8, name, "clearRect")) {
        // treat as fill with transparent black (approx: skip)
    } else if (std.mem.eql(u8, name, "fillText")) {
        const text = str(args, 0);
        const x = num(args, 1);
        const y = num(args, 2);
        applyFill(ctx, s);
        ctx.setFontSize(s.font_size);
        ctx.showText(text, x, y) catch {};
    } else if (std.mem.eql(u8, name, "save")) {
        s.transform = ctx.getTransformation();
        try stack.append(alloc, s.*);
    } else if (std.mem.eql(u8, name, "restore")) {
        if (stack.pop()) |prev| {
            s.* = prev;
            ctx.setTransformation(s.transform);
        }
    } else if (std.mem.eql(u8, name, "translate")) {
        ctx.translate(num(args, 0), num(args, 1));
    } else if (std.mem.eql(u8, name, "rotate")) {
        ctx.rotate(num(args, 0));
    } else if (std.mem.eql(u8, name, "scale")) {
        ctx.scale(num(args, 0), num(args, 1));
    } else if (std.mem.eql(u8, name, "setTransform")) {
        ctx.setTransformation(.{
            .ax = num(args, 0),
            .by = num(args, 1),
            .cx = num(args, 2),
            .dy = num(args, 3),
            .tx = num(args, 4),
            .ty = num(args, 5),
        });
    }
}

fn doProp(s: *SavedState, name: []const u8, v: []const u8) void {
    if (std.mem.eql(u8, name, "fillStyle")) {
        s.fill = parseColor(v) orelse s.fill;
    } else if (std.mem.eql(u8, name, "strokeStyle")) {
        s.stroke = parseColor(v) orelse s.stroke;
    } else if (std.mem.eql(u8, name, "globalAlpha")) {
        s.alpha = std.fmt.parseFloat(f64, v) catch 1.0;
    } else if (std.mem.eql(u8, name, "lineWidth")) {
        s.line_width = std.fmt.parseFloat(f64, v) catch 1.0;
    } else if (std.mem.eql(u8, name, "font")) {
        // "700 14px system-ui" -> 14
        var it = std.mem.tokenizeScalar(u8, v, ' ');
        while (it.next()) |tok| {
            if (std.mem.endsWith(u8, tok, "px")) {
                s.font_size = std.fmt.parseFloat(f64, tok[0 .. tok.len - 2]) catch s.font_size;
                break;
            }
        }
    }
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseColor(v: []const u8) ?Rgba {
    if (v.len == 0) return null;
    if (v[0] == '#') {
        const h = v[1..];
        if (h.len == 6) {
            const r = hexVal(h[0]) orelse return null;
            const r2 = hexVal(h[1]) orelse return null;
            const g = hexVal(h[2]) orelse return null;
            const g2 = hexVal(h[3]) orelse return null;
            const b = hexVal(h[4]) orelse return null;
            const b2 = hexVal(h[5]) orelse return null;
            return .{ .r = r * 16 + r2, .g = g * 16 + g2, .b = b * 16 + b2, .a = 255 };
        } else if (h.len == 3) {
            const r = hexVal(h[0]) orelse return null;
            const g = hexVal(h[1]) orelse return null;
            const b = hexVal(h[2]) orelse return null;
            return .{ .r = r * 16 + r, .g = g * 16 + g, .b = b * 16 + b, .a = 255 };
        }
        return null;
    }
    if (std.mem.startsWith(u8, v, "rgba(") or std.mem.startsWith(u8, v, "rgb(")) {
        const inner = v[std.mem.indexOfScalar(u8, v, '(').? + 1 .. v.len - 1];
        var it = std.mem.tokenizeAny(u8, inner, ", ");
        const r = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        const g = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        const b = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        var a: u8 = 255;
        if (it.next()) |as| {
            const af = std.fmt.parseFloat(f64, as) catch 1.0;
            a = @intFromFloat(@round(af * 255));
        }
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    return null;
}
