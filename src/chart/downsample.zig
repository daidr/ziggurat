//! Reduction of dense lines to the points a plot can show.
const std = @import("std");

fn finite(v: f32) bool {
    return std.math.isFinite(v);
}

/// Output of `minMax`: the kept points, NaN between runs.
pub const Reduced = struct { xs: []f32, ys: []f32 };

/// Reduce a line of many points to the lowest and highest of each pixel
/// column of the plot, in their order, and the ends of each run of defined
/// points, so that a line through them looks the same and narrow spikes
/// still show. `xs` and `ys` are fractions; `xs` must not decrease. A NaN or
/// infinite value breaks the line. Points left or right of the plot go, but
/// for the nearest one on each side. `pixel_width` is the plot's width in
/// physical pixels.
///
/// The result is written to `dst_x` and `dst_y`, which must not share memory
/// with the input; keeping them lets a live view reduce every frame without
/// allocating. Twice the pixel width plus four points per run always fits.
pub fn minMax(dst_x: []f32, dst_y: []f32, xs: []const f32, ys: []const f32, pixel_width: usize) error{OutputTooSmall}!Reduced {
    var out: Writer = .{ .xs = dst_x, .ys = dst_y };
    if (pixel_width == 0) return out.result();
    const n = @min(xs.len, ys.len);
    const width: f64 = @floatFromInt(pixel_width);
    var from: ?usize = null;
    var index: usize = 0;
    while (index <= n) : (index += 1) {
        if (index < n and finite(xs[index]) and finite(ys[index])) {
            if (from == null) from = index;
            continue;
        }
        const start = from orelse continue;
        from = null;
        const to = index;
        // Binary search leaves at most one point beyond either visible edge.
        var lo = start + firstIndex(xs[start..to], 0, false);
        if (lo == to) continue;
        var hi = start + firstIndex(xs[start..to], 1, true);
        if (lo == start and lo == hi) continue;
        if (lo > start) lo -= 1;
        if (hi < to) hi += 1;
        if (out.len > 0) try out.append(std.math.nan(f32), std.math.nan(f32));
        var last: ?usize = null;
        try out.emit(xs, ys, lo, &last);
        var i = lo;
        while (i < hi) {
            const bucket = @floor(@as(f64, xs[i]) * width);
            var low = i;
            var high = i;
            i += 1;
            while (i < hi and xs[i] >= 0 and xs[i] <= 1 and bucket == @floor(@as(f64, xs[i]) * width)) : (i += 1) {
                if (ys[i] < ys[low]) low = i;
                if (ys[i] > ys[high]) high = i;
            }
            try out.emit(xs, ys, @min(low, high), &last);
            try out.emit(xs, ys, @max(low, high), &last);
        }
        try out.emit(xs, ys, hi - 1, &last);
    }
    return out.result();
}

/// The first index whose value is at least `bound` (or above it when
/// `strict`), in ascending values.
fn firstIndex(values: []const f32, bound: f32, strict: bool) usize {
    var lo: usize = 0;
    var hi: usize = values.len;
    while (lo < hi) {
        const m = (lo + hi) / 2;
        const past = if (strict) values[m] > bound else values[m] >= bound;
        if (past) hi = m else lo = m + 1;
    }
    return lo;
}

const Writer = struct {
    xs: []f32,
    ys: []f32,
    len: usize = 0,
    fn append(self: *Writer, px: f32, py: f32) error{OutputTooSmall}!void {
        if (self.len >= self.xs.len or self.len >= self.ys.len) return error.OutputTooSmall;
        self.xs[self.len] = px;
        self.ys[self.len] = py;
        self.len += 1;
    }
    fn emit(self: *Writer, xs: []const f32, ys: []const f32, i: usize, last: *?usize) error{OutputTooSmall}!void {
        if (last.* == i) return;
        try self.append(xs[i], ys[i]);
        last.* = i;
    }
    fn result(self: Writer) Reduced {
        return .{ .xs = self.xs[0..self.len], .ys = self.ys[0..self.len] };
    }
};
