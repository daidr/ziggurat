//! Stacking of series, as stacked bars and areas show them.
const std = @import("std");

/// A value's stretch in a stack, from `lo` up to `hi`.
pub const Segment = struct { lo: f64, hi: f64 };

pub const Stacking = enum {
    /// Pile values up from 0, and negative values down from it.
    standard,
    /// Pile them up as `standard` does, in shares of the sum of their sizes:
    /// stacks of positive values go from 0 to 1.
    normalized,
    /// Pile them up around 0, as a streamgraph.
    center,
};

/// Pile `series` up: `series[s][i]` is the i-th value of the s-th series,
/// and `out[s][i]` receives where it goes in the stack of the i-th values,
/// the s-th from the bottom. NaN values and values past a shorter series
/// take no room. `out` needs one slice per series, each at least as long as
/// the longest series; the stack count is returned.
pub fn stack(series: []const []const f64, how: Stacking, out: []const []Segment) error{OutputTooSmall}!usize {
    var n: usize = 0;
    for (series) |s| n = @max(n, s.len);
    if (out.len < series.len) return error.OutputTooSmall;
    for (out[0..series.len]) |o| if (o.len < n) return error.OutputTooSmall;
    for (0..n) |i| {
        var up: f64 = 0;
        var down: f64 = 0;
        var total: f64 = 0;
        for (series, 0..) |s, k| {
            const v = if (i >= s.len or std.math.isNan(s[i])) 0 else s[i];
            total += @abs(v);
            if (how == .center or v >= 0) {
                out[k][i] = .{ .lo = up, .hi = up + v };
                up += v;
            } else {
                out[k][i] = .{ .lo = down + v, .hi = down };
                down += v;
            }
        }
        var shift: f64 = 0;
        var factor: f64 = 1;
        switch (how) {
            .center => shift = -up / 2,
            .normalized => if (total > 0) {
                factor = 1 / total;
            },
            .standard => {},
        }
        for (0..series.len) |k| {
            const seg = &out[k][i];
            seg.* = .{ .lo = (seg.lo + shift) * factor, .hi = (seg.hi + shift) * factor };
        }
    }
    return n;
}
