//! Paths of lines, areas and pie slices in a plot's box, written into
//! caller-owned command storage so a warm chart builds them without
//! allocating.
const std = @import("std");

/// A box in DIPs, with the fields of the UI layer's rectangles.
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Point = struct { x: f32 = 0, y: f32 = 0 };

/// The x of `f`, a fraction along the width of `r`.
pub fn x(r: Rect, f: f32) f32 {
    return r.x + f * r.width;
}
/// The y of `f`, a fraction up the height of `r`: 0 is its bottom.
pub fn y(r: Rect, f: f32) f32 {
    return r.y + (1 - f) * r.height;
}

pub const Command = union(enum) {
    move: Point,
    line: Point,
    cubic: struct { c1: Point, c2: Point, to: Point },
    close,
};

/// A path over caller-owned command storage. Reset reuses it.
pub const Path = struct {
    commands: []Command,
    len: usize = 0,

    pub const Error = error{PathFull};

    pub fn init(storage: []Command) Path {
        return .{ .commands = storage };
    }
    pub fn reset(self: *Path) void {
        self.len = 0;
    }
    pub fn items(self: *const Path) []const Command {
        return self.commands[0..self.len];
    }
    fn push(self: *Path, command: Command) Error!void {
        if (self.len == self.commands.len) return error.PathFull;
        self.commands[self.len] = command;
        self.len += 1;
    }
    pub fn moveTo(self: *Path, p: Point) Error!void {
        try self.push(.{ .move = p });
    }
    pub fn lineTo(self: *Path, p: Point) Error!void {
        try self.push(.{ .line = p });
    }
    pub fn cubicTo(self: *Path, c1: Point, c2: Point, to: Point) Error!void {
        try self.push(.{ .cubic = .{ .c1 = c1, .c2 = c2, .to = to } });
    }
    pub fn close(self: *Path) Error!void {
        try self.push(.close);
    }
};

/// How a line goes from one point to the next.
pub const Curve = enum {
    /// Straight lines.
    linear,
    /// A smooth curve that keeps between the values of each two points,
    /// never going past them (Steffen's method).
    monotone,
    /// Keep a point's value until the next point.
    step_after,
    /// Take on a point's value from the point before it.
    step_before,
    /// Change the value halfway between points.
    step,
};

/// A piece of a line, from where the one before ended to `to`: straight
/// unless cubic, with the control points `c1` and `c2`.
pub const Segment = struct {
    cubic: bool = false,
    c1: Point = .{},
    c2: Point = .{},
    to: Point,
};

/// Points of one defined run of a line, read on demand from fractions.
const Run = struct {
    r: Rect = .{},
    xs: []const f32 = &.{},
    ys: ?[]const f32 = null,
    /// Points already in DIPs, read instead of the fractions when set.
    points: ?[]const Point = null,
    from: usize = 0,
    len: usize,
    fn point(self: Run, i: usize) Point {
        const k = self.from + i;
        if (self.points) |points| return points[k];
        return .{ .x = x(self.r, self.xs[k]), .y = y(self.r, if (self.ys) |ys| ys[k] else 0) };
    }
    /// The slope at point `i` of a monotone curve.
    fn slope(self: Run, i: usize) f32 {
        const n = self.len;
        if (i == 0) return endSlope(self.point(0), self.point(1), monotoneSlope(self.point(0), self.point(1), self.point(2)));
        if (i == n - 1) return endSlope(self.point(n - 2), self.point(n - 1), monotoneSlope(self.point(n - 3), self.point(n - 2), self.point(n - 1)));
        return monotoneSlope(self.point(i - 1), self.point(i), self.point(i + 1));
    }
    /// The segments from point `i` to point `i + 1`.
    fn segments(self: Run, i: usize, k: Curve, out: *[3]Segment) []const Segment {
        const p0 = self.point(i);
        const p1 = self.point(i + 1);
        switch (k) {
            .monotone => if (self.len >= 3) {
                const dx = (p1.x - p0.x) / 3;
                out[0] = .{ .cubic = true, .c1 = .{ .x = p0.x + dx, .y = p0.y + dx * self.slope(i) }, .c2 = .{ .x = p1.x - dx, .y = p1.y - dx * self.slope(i + 1) }, .to = p1 };
                return out[0..1];
            },
            .step_after => {
                out[0] = .{ .to = .{ .x = p1.x, .y = p0.y } };
                out[1] = .{ .to = p1 };
                return out[0..2];
            },
            .step_before => {
                out[0] = .{ .to = .{ .x = p0.x, .y = p1.y } };
                out[1] = .{ .to = p1 };
                return out[0..2];
            },
            .step => {
                const middle = (p0.x + p1.x) / 2;
                out[0] = .{ .to = .{ .x = middle, .y = p0.y } };
                out[1] = .{ .to = .{ .x = middle, .y = p1.y } };
                out[2] = .{ .to = p1 };
                return out[0..3];
            },
            .linear => {},
        }
        out[0] = .{ .to = p1 };
        return out[0..1];
    }
};

/// The segments of a curve through `points`, after the first, appended to
/// `out`; returns how many were written.
pub fn curve(points: []const Point, k: Curve, out: []Segment) error{OutputTooSmall}!usize {
    if (points.len < 2) return 0;
    const run = Run{ .points = points, .len = points.len };
    var len: usize = 0;
    var buffer: [3]Segment = undefined;
    for (0..points.len - 1) |i| {
        for (run.segments(i, k, &buffer)) |s| {
            if (len == out.len) return error.OutputTooSmall;
            out[len] = s;
            len += 1;
        }
    }
    return len;
}

/// The slope at `b` between `a` and `c` (Steffen).
fn monotoneSlope(a: Point, b: Point, c: Point) f32 {
    const h0 = b.x - a.x;
    const h1 = c.x - b.x;
    if (h0 == 0 or h1 == 0) return 0;
    const s0 = (b.y - a.y) / h0;
    const s1 = (c.y - b.y) / h1;
    const p = (s0 * h1 + s1 * h0) / (h0 + h1);
    if (std.math.signbit(s0) != std.math.signbit(s1) or s0 == 0 or s1 == 0) return 0;
    const m = @min(@abs(s0), @abs(s1), 0.5 * @abs(p));
    return if (s0 < 0) -2 * m else 2 * m;
}

/// The slope at an end of a line, from the slope `t` at its neighbor.
fn endSlope(a: Point, b: Point, t: f32) f32 {
    const h = b.x - a.x;
    if (h == 0) return t;
    return (3 * (b.y - a.y) / h - t) / 2;
}

fn defined(v: f32) bool {
    return !std.math.isNan(v);
}

/// Calls `visit(context, from, to)` for each run of indices below `n`
/// whose values are all defined.
fn runs(n: usize, context: anytype, comptime ok: fn (@TypeOf(context), usize) bool, visitor: anytype) !void {
    var from: ?usize = null;
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        if (i < n and ok(context, i)) {
            if (from == null) from = i;
            continue;
        }
        if (from) |start| {
            try visitor.visit(start, i);
            from = null;
        }
    }
}

const LineData = struct {
    xs: []const f32,
    ys: []const f32,
    fn ok(self: LineData, i: usize) bool {
        return defined(self.xs[i]) and defined(self.ys[i]);
    }
};

/// Replace `path` with a line through the points at `xs` and `ys`,
/// fractions along and up the plot whose box is `r`, joined as `k` says.
/// A NaN value breaks the line there.
pub fn line(path: *Path, r: Rect, xs: []const f32, ys: []const f32, k: Curve) Path.Error!void {
    path.reset();
    const n = @min(xs.len, ys.len);
    const data = LineData{ .xs = xs, .ys = ys };
    const Visitor = struct {
        path: *Path,
        r: Rect,
        data: LineData,
        k: Curve,
        fn visit(self: @This(), from: usize, to: usize) Path.Error!void {
            const run = Run{ .r = self.r, .xs = self.data.xs, .ys = self.data.ys, .from = from, .len = to - from };
            try self.path.moveTo(run.point(0));
            try addRun(self.path, run, self.k);
        }
    };
    try runs(n, data, LineData.ok, Visitor{ .path = path, .r = r, .data = data, .k = k });
}

fn addRun(path: *Path, run: Run, k: Curve) Path.Error!void {
    var buffer: [3]Segment = undefined;
    if (run.len < 2) return;
    for (0..run.len - 1) |i| for (run.segments(i, k, &buffer)) |s| try addSegment(path, s);
}

fn addSegment(path: *Path, s: Segment) Path.Error!void {
    if (s.cubic) try path.cubicTo(s.c1, s.c2, s.to) else try path.lineTo(s.to);
}

const AreaData = struct {
    xs: []const f32,
    lo: ?[]const f32,
    hi: []const f32,
    fn ok(self: AreaData, i: usize) bool {
        return defined(self.xs[i]) and defined(self.hi[i]) and (if (self.lo) |lo| defined(lo[i]) else true);
    }
};

/// Replace `path` with the area between two lines through the points at
/// `xs`, `lo` below and `hi` above, joined as `k` says, for areas, bands and
/// the layers of a stack. Null `lo` puts the bottom line at the bottom of the
/// plot. A NaN value breaks the area there.
pub fn area(path: *Path, r: Rect, xs: []const f32, lo: ?[]const f32, hi: []const f32, k: Curve) Path.Error!void {
    path.reset();
    var n = @min(xs.len, hi.len);
    if (lo) |values| n = @min(n, values.len);
    const data = AreaData{ .xs = xs, .lo = lo, .hi = hi };
    const Visitor = struct {
        path: *Path,
        r: Rect,
        data: AreaData,
        k: Curve,
        fn visit(self: @This(), from: usize, to: usize) Path.Error!void {
            const top = Run{ .r = self.r, .xs = self.data.xs, .ys = self.data.hi, .from = from, .len = to - from };
            const bottom = Run{ .r = self.r, .xs = self.data.xs, .ys = self.data.lo, .from = from, .len = to - from };
            try self.path.moveTo(top.point(0));
            try addRun(self.path, top, self.k);
            // Back along the bottom line, the same curve the other way.
            try self.path.lineTo(bottom.point(bottom.len - 1));
            var buffer: [3]Segment = undefined;
            var i = bottom.len - 1;
            while (i > 0) {
                i -= 1;
                const segs = bottom.segments(i, self.k, &buffer);
                var j = segs.len;
                while (j > 0) {
                    j -= 1;
                    const target = if (j > 0) segs[j - 1].to else bottom.point(i);
                    const s = segs[j];
                    if (s.cubic) try self.path.cubicTo(s.c2, s.c1, target) else try self.path.lineTo(target);
                }
            }
            try self.path.close();
        }
    };
    try runs(n, data, AreaData.ok, Visitor{ .path = path, .r = r, .data = data, .k = k });
}

/// The index of the value of `xs`, in ascending order, nearest `f`, or null
/// for none: the point of a line under the pointer.
pub fn nearest(xs: []const f32, f: f32) ?usize {
    if (xs.len == 0) return null;
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        const m = (lo + hi) / 2;
        if (xs[m] < f) lo = m + 1 else hi = m;
    }
    if (lo == xs.len) return lo - 1;
    if (lo > 0 and f - xs[lo - 1] <= xs[lo] - f) return lo - 1;
    return lo;
}

/// A value's part of a pie, from the angle `start` to `end`, in radians
/// clockwise from twelve o'clock. `pad` is the gap `sector` leaves after it.
pub const Slice = struct {
    start: f64,
    end: f64,
    pad: f64 = 0,
    pub fn mid(self: Slice) f64 {
        return (self.start + self.end) / 2;
    }
};

/// Divide a circle among `values`, in their order from twelve o'clock, each
/// slice as large as its share of their sum, with `pad` radians between
/// slices. Values below 0, and NaN, take no room. `out` needs one slice per
/// value.
pub fn pie(values: []const f64, pad_in: f64, out: []Slice) error{OutputTooSmall}![]Slice {
    if (out.len < values.len) return error.OutputTooSmall;
    var sum: f64 = 0;
    for (values) |v| if (v > 0) {
        sum += v;
    };
    const n: f64 = @floatFromInt(values.len);
    const pad = @max(0, @min(pad_in, 2 * std.math.pi / @max(n, 1)));
    const k: f64 = if (sum > 0) (2 * std.math.pi - n * pad) / sum else 0;
    var a: f64 = 0;
    for (values, 0..) |v, i| {
        var end = a + pad;
        if (v > 0) end += v * k;
        out[i] = .{ .start = a, .end = end, .pad = pad };
        a = end;
    }
    return out[0..values.len];
}

/// The point at angle `a`, `radius` from the center `c`.
pub fn polar(c: Point, radius: f32, a: f64) Point {
    return .{ .x = c.x + radius * @as(f32, @floatCast(@sin(a))), .y = c.y - radius * @as(f32, @floatCast(@cos(a))) };
}

/// Replace `path` with a slice between the radii `inner` and `outer` around
/// `c`: a wedge of a pie with inner 0, of a donut otherwise. The slice's pad
/// keeps a gap of the same width along it.
pub fn sector(path: *Path, c: Point, inner_in: f32, outer: f32, s: Slice) Path.Error!void {
    path.reset();
    if (outer <= 0 or s.end <= s.start) return;
    const inner = @max(0, @min(inner_in, outer));
    // The gap's width, at the radius between the two.
    const gap = s.pad * @sqrt(@as(f64, inner * inner + outer * outer));
    const Angles = struct { a0: f64, a1: f64 };
    const angles = struct {
        fn of(slice: Slice, g: f64, radius: f32) Angles {
            if (g > 0 and radius > 0) {
                const d = std.math.asin(@min(1, g / 2 / @as(f64, radius)));
                if (slice.end - slice.start > 2 * d) return .{ .a0 = slice.start + d, .a1 = slice.end - d };
                const m = slice.mid();
                return .{ .a0 = m, .a1 = m };
            }
            return .{ .a0 = slice.start, .a1 = slice.end };
        }
    }.of;
    const outer_angles = angles(s, gap, outer);
    try path.moveTo(polar(c, outer, outer_angles.a0));
    try arc(path, c, outer, outer_angles.a0, outer_angles.a1);
    if (inner > 0) {
        const inner_angles = angles(s, gap, inner);
        try path.lineTo(polar(c, inner, inner_angles.a1));
        try arc(path, c, inner, inner_angles.a1, inner_angles.a0);
    } else try path.lineTo(c);
    try path.close();
}

/// Add an arc of `radius` around `c` from angle `a0` to `a1`, in cubic
/// curves of up to a quarter turn.
fn arc(path: *Path, c: Point, radius: f32, a0: f64, a1: f64) Path.Error!void {
    const n: usize = @intFromFloat(@ceil(@abs(a1 - a0) / (std.math.pi / 2.0)));
    if (n == 0) return;
    const step = (a1 - a0) / @as(f64, @floatFromInt(n));
    const k: f32 = @floatCast(4.0 / 3.0 * @tan(step / 4));
    for (0..n) |i| {
        const b0 = a0 + @as(f64, @floatFromInt(i)) * step;
        const b1 = a0 + @as(f64, @floatFromInt(i + 1)) * step;
        const p0 = polar(c, radius, b0);
        const p1 = polar(c, radius, b1);
        // The tangent at angle a, going clockwise, is (cos a, sin a).
        const t0: Point = .{ .x = @floatCast(@cos(b0)), .y = @floatCast(@sin(b0)) };
        const t1: Point = .{ .x = @floatCast(@cos(b1)), .y = @floatCast(@sin(b1)) };
        try path.cubicTo(
            .{ .x = p0.x + k * radius * t0.x, .y = p0.y + k * radius * t0.y },
            .{ .x = p1.x - k * radius * t1.x, .y = p1.y - k * radius * t1.y },
            p1,
        );
    }
}

/// The slice at `p`, relative to the center of a pie whose slices go from
/// `inner` to `outer`, or null: the slice under the pointer.
pub fn sliceAt(slices: []const Slice, p: Point, inner: f32, outer: f32) ?usize {
    const d = std.math.hypot(p.x, p.y);
    if (d < inner or d > outer) return null;
    var a = std.math.atan2(@as(f64, p.x), -@as(f64, p.y));
    if (a < 0) a += 2 * std.math.pi;
    for (slices, 0..) |s, i| if (a >= s.start and a < s.end) return i;
    return null;
}
