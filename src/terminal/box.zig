//! Characters of box drawing, blocks, legacy-computing sextants and
//! Powerline's separators, drawn rather than taken from the font: fonts
//! leave gaps between the lines of cells taller than their glyphs, and many
//! lack the separators and the sextants. Shapes are
//! rectangles on device pixels, so lines of neighboring cells meet exactly;
//! curves, diagonals and Powerline's shapes are scanned row by row into
//! spans whose edge pixels take partial coverage.
const std = @import("std");

/// A rectangle in device pixels, with its coverage.
pub const Fill = struct { x0: f32, y0: f32, x1: f32, y1: f32, alpha: f32 = 1 };

/// Weights of the arms of box drawing characters.
const arm_none = 0;
const arm_light = 1;
const arm_heavy = 2;
const arm_double = 3;

/// The arms of U+2500 to U+257F, from their Unicode names: the weights of
/// up, right, down and left, a digit each; "" for those drawn otherwise
/// (arcs, diagonals) or by the font (dashes).
const box_arms = [128][]const u8{
    "0101", "0202", "1010", "2020", "",     "",     "",     "",     "",     "",     "",     "",     "0110", "0210", "0120", "0220",
    "0011", "0012", "0021", "0022", "1100", "1200", "2100", "2200", "1001", "1002", "2001", "2002", "1110", "1210", "2110", "1120",
    "2120", "2210", "1220", "2220", "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022", "0111", "0112", "0211", "0212",
    "0121", "0122", "0221", "0222", "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202", "1111", "1112", "1211", "1212",
    "2111", "1121", "2121", "2112", "2211", "1122", "1221", "2212", "1222", "2122", "2221", "2222", "",     "",     "",     "",
    "0303", "3030", "0310", "0130", "0330", "0013", "0031", "0033", "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130",
    "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303", "3101", "3303", "1313", "3131", "3333", "",     "",     "",
    "",     "",     "",     "",     "0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020", "0201", "1020", "0102", "2010",
};

/// Whether the terminal draws `cp` itself.
pub fn drawn(cp: u21) bool {
    return switch (cp) {
        0x2500...0x257f => box_arms[cp - 0x2500].len != 0 or (cp >= 0x256d and cp <= 0x2573),
        0x2580...0x259f, 0x1fb00...0x1fb3b, 0xe0b0...0xe0b7 => true,
        else => false,
    };
}

/// Whether `cp` is scanned row by row rather than drawn with a few
/// rectangles, so it takes many more drawing commands.
pub fn scanned(cp: u21) bool {
    return (cp >= 0x256d and cp <= 0x2573) or (cp >= 0xe0b0 and cp <= 0xe0b7);
}

/// Draw `cp` in the cell `x0, y0` to `x1, y1`, whole device pixels, whose
/// display scale is `scale`, as rectangles passed to `sink.fill(Fill)`.
pub fn draw(cp: u21, x0: f32, y0: f32, x1: f32, y1: f32, scale: f32, sink: anytype) void {
    const w = x1 - x0;
    const h = y1 - y0;
    if (w <= 0 or h <= 0) return;
    const light = @max(1, @round(scale));
    switch (cp) {
        0x2580...0x259f => return drawBlock(cp, x0, y0, w, h, sink),
        0x1fb00...0x1fb3b => return drawSextant(cp, x0, y0, w, h, sink),
        0xe0b0...0xe0b3 => {
            // Powerline's triangles: filled, or their outline.
            const ym = y0 + h / 2;
            const right = cp == 0xe0b0 or cp == 0xe0b1;
            const base = if (right) x0 else x1;
            const tip = if (right) x1 else x0;
            if (cp == 0xe0b0 or cp == 0xe0b2) {
                scanFill(sink, x0, y0, x1, y1, Triangle{ .base = base, .tip = tip, .ym = ym, .half = h / 2 });
            } else {
                stroke(sink, &.{ .{ base, y0 }, .{ tip, ym }, .{ base, y1 } }, light, x0, y0, x1, y1);
            }
            return;
        },
        0xe0b4...0xe0b7 => {
            // Powerline's rounded caps: half an ellipse spanning the cell, as
            // the triangles do.
            const ym = y0 + h / 2;
            const right = cp <= 0xe0b5;
            const flat = if (right) x0 else x1;
            const tip = if (right) x1 else x0;
            if (cp == 0xe0b4 or cp == 0xe0b6) {
                scanFill(sink, x0, y0, x1, y1, HalfEllipse{ .flat = flat, .rx = tip - flat, .ym = ym, .ry = h / 2 });
            } else {
                var points: [arc_steps * 2 + 1][2]f32 = undefined;
                for (&points, 0..) |*p, i| {
                    const a = std.math.pi * (@as(f32, @floatFromInt(i)) / (arc_steps * 2) - 0.5);
                    p.* = .{ flat + (tip - flat) * @cos(a), ym + h / 2 * @sin(a) };
                }
                stroke(sink, &points, light, x0, y0, x1, y1);
            }
            return;
        },
        else => {},
    }
    const cx = x0 + @floor((w - light) / 2);
    const cy = y0 + @floor((h - light) / 2);
    const mx = cx + light / 2;
    const my = cy + light / 2;
    switch (cp) {
        0x256d...0x2570 => {
            // Rounded corners: a line from the cell's edge, a quadratic curve
            // around the corner and a line to the other edge.
            const rad = @min(w, h) / 2;
            const sx: f32 = if (cp == 0x256d or cp == 0x2570) 1 else -1;
            const sy: f32 = if (cp == 0x256d or cp == 0x256e) 1 else -1;
            const ey = if (sy > 0) y1 else y0;
            const ex = if (sx > 0) x1 else x0;
            var points: [arc_steps + 3][2]f32 = undefined;
            points[0] = .{ mx, ey };
            for (0..arc_steps + 1) |i| {
                const t = @as(f32, @floatFromInt(i)) / arc_steps;
                // From (mx, my + rad) to (mx + rad, my), around (mx, my).
                points[i + 1] = .{ mx + sx * rad * t * t, my + sy * rad * (1 - t) * (1 - t) };
            }
            points[arc_steps + 2] = .{ ex, my };
            stroke(sink, &points, light, x0, y0, x1, y1);
        },
        0x2571 => stroke(sink, &.{ .{ x1, y0 }, .{ x0, y1 } }, light, x0, y0, x1, y1),
        0x2572 => stroke(sink, &.{ .{ x0, y0 }, .{ x1, y1 } }, light, x0, y0, x1, y1),
        0x2573 => {
            stroke(sink, &.{ .{ x1, y0 }, .{ x0, y1 } }, light, x0, y0, x1, y1);
            stroke(sink, &.{ .{ x0, y0 }, .{ x1, y1 } }, light, x0, y0, x1, y1);
        },
        0x2500...0x256c, 0x2574...0x257f => {
            const arms = box_arms[cp - 0x2500];
            if (arms.len == 0) return;
            drawArms(sink, .{ arms[0] - '0', arms[1] - '0', arms[2] - '0', arms[3] - '0' }, x0, y0, x1, y1, mx, my, light);
        },
        else => {},
    }
}

/// Fill the rectangle from `ax, ay` to `bx, by` when it is not empty.
fn fill(sink: anytype, ax: f32, ay: f32, bx: f32, by: f32) void {
    if (bx > ax and by > ay) sink.fill(.{ .x0 = ax, .y0 = ay, .x1 = bx, .y1 = by });
}

/// Draw the arms of a box drawing character (up, right, down, left) in the
/// cell from `x0, y0` to `x1, y1`, whose lines cross at `mx, my`, `light`
/// pixels wide. Light and heavy arms are lines; a double arm is two light
/// lines, a light line apart, which turn into the arm across them as a
/// corner does, or go through.
fn drawArms(sink: anytype, a: [4]u8, x0: f32, y0: f32, x1: f32, y1: f32, mx: f32, my: f32, light: f32) void {
    const up = a[0];
    const right = a[1];
    const down = a[2];
    const left = a[3];
    const off = light; // from the middle to each line of a double arm
    const v_double = up == arm_double or down == arm_double;
    const h_double = left == arm_double or right == arm_double;
    const thick = struct {
        fn of(weight: u8, l: f32, o: f32) f32 {
            return switch (weight) {
                arm_heavy => 2 * l,
                arm_double => 2 * o + l,
                else => l,
            };
        }
    }.of;
    const single = struct {
        fn is(weight: u8) bool {
            return weight == arm_light or weight == arm_heavy;
        }
    }.is;
    // The joint is as wide as the widest arm across.
    const hw = @max(thick(left, light, off), thick(right, light, off));
    const vw = @max(thick(up, light, off), thick(down, light, off));
    if (single(up)) {
        const t = thick(up, light, off);
        const end = if (h_double and down == arm_none) my - off + light / 2 else my + hw / 2;
        fill(sink, mx - t / 2, y0, mx + t / 2, end);
    }
    if (single(down)) {
        const t = thick(down, light, off);
        const start = if (h_double and up == arm_none) my + off - light / 2 else my - hw / 2;
        fill(sink, mx - t / 2, start, mx + t / 2, y1);
    }
    if (single(left)) {
        const t = thick(left, light, off);
        const end = if (v_double and right == arm_none) mx - off + light / 2 else mx + vw / 2;
        fill(sink, x0, my - t / 2, end, my + t / 2);
    }
    if (single(right)) {
        const t = thick(right, light, off);
        const start = if (v_double and left == arm_none) mx + off - light / 2 else mx - vw / 2;
        fill(sink, start, my - t / 2, x1, my + t / 2);
    }
    // The lines of double arms. The one on a side with a double arm across
    // is inside the corner it turns, and the other outside.
    for ([_]f32{ -1, 1 }) |side| {
        if (v_double) {
            const lx = mx + side * off - light / 2;
            const across = if (side > 0) right else left;
            if (up == arm_double and down == arm_double and across != arm_double) {
                fill(sink, lx, y0, lx + light, y1);
            } else {
                // Where the line meets the arms across: inside or outside
                // their double lines, or at their single line.
                var out = my + off + light / 2;
                if (across == arm_double) out = my - off + light / 2 else if (!h_double) out = my + light / 2;
                if (up == arm_double) fill(sink, lx, y0, lx + light, out);
                out = my - off - light / 2;
                if (across == arm_double) out = my + off - light / 2 else if (!h_double) out = my - light / 2;
                if (down == arm_double) fill(sink, lx, out, lx + light, y1);
            }
        }
        if (h_double) {
            const ly = my + side * off - light / 2;
            const across = if (side > 0) down else up;
            if (left == arm_double and right == arm_double and across != arm_double) {
                fill(sink, x0, ly, x1, ly + light);
            } else {
                var out = mx + off + light / 2;
                if (across == arm_double) out = mx - off + light / 2 else if (!v_double) out = mx + light / 2;
                if (left == arm_double) fill(sink, x0, ly, out, ly + light);
                out = mx - off - light / 2;
                if (across == arm_double) out = mx + off - light / 2 else if (!v_double) out = mx - light / 2;
                if (right == arm_double) fill(sink, out, ly, x1, ly + light);
            }
        }
    }
}

/// Draw a block element (U+2580 to U+259F).
fn drawBlock(cp: u21, x0: f32, y0: f32, w: f32, h: f32, sink: anytype) void {
    const x1 = x0 + w;
    const y1 = y0 + h;
    const rx = struct {
        fn at(o: f32, size: f32, f: f32) f32 {
            return o + @round(size * f);
        }
    }.at;
    switch (cp) {
        0x2580 => fill(sink, x0, y0, x1, rx(y0, h, 0.5)),
        0x2581...0x2588 => fill(sink, x0, rx(y0, h, 1 - @as(f32, @floatFromInt(cp - 0x2580)) / 8), x1, y1),
        0x2589...0x258f => fill(sink, x0, y0, rx(x0, w, @as(f32, @floatFromInt(0x2590 - cp)) / 8), y1),
        0x2590 => fill(sink, rx(x0, w, 0.5), y0, x1, y1),
        0x2591...0x2593 => sink.fill(.{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .alpha = @as(f32, @floatFromInt(cp - 0x2590)) / 4 }),
        0x2594 => fill(sink, x0, y0, x1, rx(y0, h, 1.0 / 8.0)),
        0x2595 => fill(sink, rx(x0, w, 7.0 / 8.0), y0, x1, y1),
        else => {
            // Quadrants: upper left, upper right, lower left, lower right.
            const q: u4 = switch (cp) {
                0x2596 => 0b0010,
                0x2597 => 0b0001,
                0x2598 => 0b1000,
                0x2599 => 0b1011,
                0x259a => 0b1001,
                0x259b => 0b1110,
                0x259c => 0b1101,
                0x259d => 0b0100,
                0x259e => 0b0110,
                0x259f => 0b0111,
                else => 0,
            };
            const mx = rx(x0, w, 0.5);
            const my = rx(y0, h, 0.5);
            if (q & 0b1000 != 0) fill(sink, x0, y0, mx, my);
            if (q & 0b0100 != 0) fill(sink, mx, y0, x1, my);
            if (q & 0b0010 != 0) fill(sink, x0, my, mx, y1);
            if (q & 0b0001 != 0) fill(sink, mx, my, x1, y1);
        },
    }
}

/// Draw one of U+1FB00 to U+1FB3B across the whole cell. The sixty
/// patterns are the six-bit masks except 0, 21, 42 and 63, which are a
/// space, ▌, ▐ and █. Bit 0 is the upper left, then across and down;
/// neighbors share an edge, as the quadrants of `drawBlock` do.
fn drawSextant(cp: u21, x0: f32, y0: f32, w: f32, h: f32, sink: anytype) void {
    const index: u32 = cp - 0x1fb00;
    const pattern = index + index / 20 + 1;
    const xs = [3]f32{ x0, x0 + @round(w * 0.5), x0 + w };
    const ys = [4]f32{ y0, y0 + @round(h / 3), y0 + @round(h * 2 / 3), y0 + h };
    for (0..6) |bit| {
        if (pattern & (@as(u32, 1) << @intCast(bit)) == 0) continue;
        const column = bit % 2;
        const row = bit / 2;
        fill(sink, xs[column], ys[row], xs[column + 1], ys[row + 1]);
    }
}

/// Points along a curve, per quarter turn.
const arc_steps = 12;

const Span = struct { a: f32, b: f32 };

/// Powerline's filled triangle, its base on one side of the cell and its
/// tip in the middle of the other.
const Triangle = struct {
    base: f32,
    tip: f32,
    ym: f32,
    half: f32,
    fn span(self: Triangle, y: f32) ?Span {
        const reach = (self.tip - self.base) * @max(0, 1 - @abs(y - self.ym) / self.half);
        return ordered(self.base, self.base + reach);
    }
};

/// Powerline's filled cap: half an ellipse from its flat side.
const HalfEllipse = struct {
    flat: f32,
    rx: f32,
    ym: f32,
    ry: f32,
    fn span(self: HalfEllipse, y: f32) ?Span {
        const t = (y - self.ym) / self.ry;
        if (@abs(t) >= 1) return null;
        return ordered(self.flat, self.flat + self.rx * @sqrt(1 - t * t));
    }
};

fn ordered(a: f32, b: f32) ?Span {
    if (a == b) return null;
    return .{ .a = @min(a, b), .b = @max(a, b) };
}

/// Fill a shape row by row, with `shape.span(y)` the shape's extent across
/// the middle of each row, clipped to the cell.
fn scanFill(sink: anytype, x0: f32, y0: f32, x1: f32, y1: f32, shape: anytype) void {
    var y = y0;
    while (y < y1) : (y += 1) {
        if (shape.span(y + 0.5)) |s| emitSpan(sink, y, @max(s.a, x0), @min(s.b, x1));
    }
}

/// Stroke the line through `points`, `width` pixels wide with round joins,
/// clipped to the cell: on each row, the extent of the segments' capsules
/// across the row's middle. Every row of the shapes drawn this way crosses
/// the line once, so the extent is the row's whole span.
fn stroke(sink: anytype, points: []const [2]f32, width: f32, x0: f32, y0: f32, x1: f32, y1: f32) void {
    const r = width / 2;
    var y = y0;
    while (y < y1) : (y += 1) {
        const yc = y + 0.5;
        var lo = std.math.inf(f32);
        var hi = -std.math.inf(f32);
        for (points, 0..) |p, i| {
            // The round end at each point.
            const dy = yc - p[1];
            if (@abs(dy) <= r) {
                const dx = @sqrt(r * r - dy * dy);
                lo = @min(lo, p[0] - dx);
                hi = @max(hi, p[0] + dx);
            }
            if (i + 1 == points.len) break;
            // The band along the segment to the next point.
            const q = points[i + 1];
            const len = std.math.hypot(q[0] - p[0], q[1] - p[1]);
            if (len == 0) continue;
            const nx = -(q[1] - p[1]) / len * r;
            const ny = (q[0] - p[0]) / len * r;
            const corners = [4][2]f32{ .{ p[0] + nx, p[1] + ny }, .{ q[0] + nx, q[1] + ny }, .{ q[0] - nx, q[1] - ny }, .{ p[0] - nx, p[1] - ny } };
            for (corners, 0..) |c, k| {
                const d = corners[(k + 1) % 4];
                if ((c[1] - yc) * (d[1] - yc) > 0 or c[1] == d[1]) continue;
                const x = c[0] + (yc - c[1]) / (d[1] - c[1]) * (d[0] - c[0]);
                lo = @min(lo, x);
                hi = @max(hi, x);
            }
        }
        if (hi > lo) emitSpan(sink, y, @max(lo, x0), @min(hi, x1));
    }
}

/// One row's span from `a` to `b`: whole pixels inside it, and the pixels
/// it partly covers at either end with that coverage.
fn emitSpan(sink: anytype, y: f32, a: f32, b: f32) void {
    if (b <= a) return;
    const ia = @ceil(a);
    const ib = @floor(b);
    if (ib < ia) {
        // Within one pixel.
        partial(sink, @floor(a), y, b - a);
        return;
    }
    if (ia > a) partial(sink, ia - 1, y, ia - a);
    fill(sink, ia, y, ib, y + 1);
    if (b > ib) partial(sink, ib, y, b - ib);
}

fn partial(sink: anytype, x: f32, y: f32, coverage: f32) void {
    if (coverage < 1.0 / 64.0) return;
    sink.fill(.{ .x0 = x, .y0 = y, .x1 = x + 1, .y1 = y + 1, .alpha = @min(coverage, 1) });
}

/// Collects fills for tests, merging nothing.
const Recorder = struct {
    fills: [512]Fill = undefined,
    len: usize = 0,
    fn fill(self: *Recorder, f: Fill) void {
        self.fills[self.len] = f;
        self.len += 1;
    }
    fn covers(self: *const Recorder, x: f32, y: f32) f32 {
        var sum: f32 = 0;
        for (self.fills[0..self.len]) |f| {
            if (x >= f.x0 and x < f.x1 and y >= f.y0 and y < f.y1) sum += f.alpha;
        }
        return sum;
    }
};

test "which characters are drawn" {
    try std.testing.expect(drawn(0x2500)); // ─
    try std.testing.expect(drawn(0x256d)); // ╭
    try std.testing.expect(drawn(0x2573)); // ╳
    try std.testing.expect(!drawn(0x2504)); // ┄, the font's
    try std.testing.expect(!drawn(0x254c));
    try std.testing.expect(drawn(0x2588)); // █
    try std.testing.expect(drawn(0xe0b0));
    try std.testing.expect(!drawn(0xe0b8));
    try std.testing.expect(!drawn('A'));
    try std.testing.expect(scanned(0xe0b4) and scanned(0x2570) and !scanned(0x2500));
}

test "lines meet at the cell's edges and cross in its middle" {
    // A cell of 9 by 18 at scale 1: lines one pixel wide, at x 4 and y 8.
    var r: Recorder = .{};
    draw(0x253c, 0, 0, 9, 18, 1, &r); // ┼
    try std.testing.expectEqual(@as(f32, 1), r.covers(4, 0));
    try std.testing.expectEqual(@as(f32, 1), r.covers(4, 17));
    try std.testing.expect(r.covers(0, 8) >= 1);
    try std.testing.expect(r.covers(8, 8) >= 1);
    try std.testing.expectEqual(@as(f32, 0), r.covers(3, 7));
    // Heavy lines are two light lines wide; at scale 2, light is 2 pixels.
    r = .{};
    draw(0x2501, 0, 0, 18, 36, 2, &r); // ━
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqual(@as(f32, 0), r.covers(0, 15));
    try std.testing.expectEqual(@as(f32, 1), r.covers(0, 16));
    try std.testing.expectEqual(@as(f32, 1), r.covers(17, 19));
    try std.testing.expectEqual(@as(f32, 0), r.covers(0, 20));
}

test "double lines turn corners and go through" {
    var r: Recorder = .{};
    draw(0x2550, 0, 0, 9, 18, 1, &r); // ═: two lines across, a line apart
    try std.testing.expectEqual(@as(f32, 1), r.covers(0, 7));
    try std.testing.expectEqual(@as(f32, 0), r.covers(0, 8));
    try std.testing.expectEqual(@as(f32, 1), r.covers(8, 9));
    r = .{};
    draw(0x2554, 0, 0, 9, 18, 1, &r); // ╔
    // The outer line turns at the top left of the inner one's corner.
    try std.testing.expect(r.covers(3, 7) >= 1);
    try std.testing.expectEqual(@as(f32, 1), r.covers(8, 7));
    try std.testing.expectEqual(@as(f32, 1), r.covers(3, 17));
    try std.testing.expect(r.covers(5, 9) >= 1);
    try std.testing.expectEqual(@as(f32, 0), r.covers(4, 8));
    try std.testing.expectEqual(@as(f32, 0), r.covers(5, 8));
    try std.testing.expectEqual(@as(f32, 0), r.covers(1, 9));
}

test "blocks fill their part of the cell, shades a fraction" {
    var r: Recorder = .{};
    draw(0x2584, 0, 0, 10, 20, 1, &r); // ▄
    try std.testing.expectEqual(@as(f32, 0), r.covers(5, 9));
    try std.testing.expectEqual(@as(f32, 1), r.covers(5, 10));
    r = .{};
    draw(0x258c, 0, 0, 10, 20, 1, &r); // ▌
    try std.testing.expectEqual(@as(f32, 1), r.covers(4, 19));
    try std.testing.expectEqual(@as(f32, 0), r.covers(5, 0));
    r = .{};
    draw(0x2592, 0, 0, 10, 20, 1, &r); // ▒
    try std.testing.expectEqual(@as(f32, 0.5), r.covers(9, 19));
    r = .{};
    draw(0x259a, 0, 0, 10, 20, 1, &r); // ▚
    try std.testing.expectEqual(@as(f32, 1), r.covers(0, 0));
    try std.testing.expectEqual(@as(f32, 0), r.covers(9, 0));
    try std.testing.expectEqual(@as(f32, 1), r.covers(9, 19));
}

test "sextants fill their sixths of the cell, solid between neighbors" {
    try std.testing.expect(drawn(0x1fb00) and drawn(0x1fb3b) and !drawn(0x1fb3c));
    var r: Recorder = .{};
    draw(0x1fb00, 0, 0, 10, 21, 1, &r); // 🬀: upper left only
    try std.testing.expectEqual(@as(f32, 1), r.covers(0, 0));
    try std.testing.expectEqual(@as(f32, 1), r.covers(4, 6));
    try std.testing.expectEqual(@as(f32, 0), r.covers(5, 0));
    try std.testing.expectEqual(@as(f32, 0), r.covers(0, 7));
    // U+1FB14 follows the skipped mask 21 (▌): it is mask 22, upper right,
    // middle left and lower left.
    r = .{};
    draw(0x1fb14, 0, 0, 10, 21, 1, &r);
    try std.testing.expectEqual(@as(f32, 0), r.covers(0, 0));
    try std.testing.expectEqual(@as(f32, 1), r.covers(9, 0));
    try std.testing.expectEqual(@as(f32, 1), r.covers(0, 10));
    try std.testing.expectEqual(@as(f32, 0), r.covers(9, 10));
    try std.testing.expectEqual(@as(f32, 1), r.covers(0, 20));
    // U+1FB3B, the last, is mask 62: everything but the upper left, with
    // no gaps or overlaps where the sixths meet.
    r = .{};
    draw(0x1fb3b, 0, 0, 10, 21, 1, &r);
    try std.testing.expectEqual(@as(f32, 0), r.covers(4, 6));
    var y: f32 = 7;
    while (y < 21) : (y += 1) {
        var x: f32 = 0;
        while (x < 10) : (x += 1) try std.testing.expectEqual(@as(f32, 1), r.covers(x, y));
    }
}

test "curves, diagonals and Powerline's shapes cover their rows smoothly" {
    var r: Recorder = .{};
    draw(0xe0b0, 0, 0, 10, 20, 1, &r);
    // Full at the middle row, across the cell; a sliver at the top.
    try std.testing.expectEqual(@as(f32, 1), r.covers(0, 9));
    try std.testing.expect(r.covers(9, 9) > 0.4);
    try std.testing.expect(r.covers(0, 0) > 0 and r.covers(0, 0) < 1);
    try std.testing.expectEqual(@as(f32, 0), r.covers(9, 0));
    r = .{};
    draw(0x256d, 0, 0, 10, 20, 1, &r); // ╭
    // The line leaves at the bottom, in the middle, and to the right.
    try std.testing.expect(r.covers(4, 19) > 0.4);
    try std.testing.expect(r.covers(9, 9) > 0.4);
    try std.testing.expectEqual(@as(f32, 0), r.covers(0, 0));
    try std.testing.expectEqual(@as(f32, 0), r.covers(9, 19));
    r = .{};
    draw(0x2572, 0, 0, 10, 10, 1, &r); // ╲
    try std.testing.expect(r.covers(5, 5) > 0.4);
    try std.testing.expectEqual(@as(f32, 0), r.covers(9, 0));
    for (r.fills[0..r.len]) |f| try std.testing.expect(f.x0 >= 0 and f.x1 <= 10 and f.alpha > 0 and f.alpha <= 1);
}
