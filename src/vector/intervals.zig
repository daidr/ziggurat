const std = @import("std");
const api = @import("root.zig");
pub const Range = struct { start: f64, end: f64 };
pub const Work = struct {
    used: u64 = 0,
    options: api.PrepareOptions,
    pub fn step(self: *Work) !void {
        if (self.used == self.options.limits.stroke_steps) return error.StrokeBudgetExceeded;
        self.used += 1;
        if (self.used % 256 == 0) try self.options.check();
    }
};

/// Monotonic, allocation-free iteration over SVG dash positions, intersected
/// with an explicit local-length trim. Zero-length on dashes remain visible to
/// the stroker so round/square caps can draw dots.
pub const Iterator = struct {
    stroke: api.Stroke,
    length: f64,
    index: usize = 0,
    count: usize = 0,
    position: f64 = 0,
    remaining: f64 = 0,
    started: bool = false,
    solid: bool = false,
    pending: ?Range = null,
    pub fn init(stroke: api.Stroke, length: f64, work: *Work) !Iterator {
        var result: Iterator = .{ .stroke = stroke, .length = length };
        result.count = stroke.dashes.len * (if (stroke.dashes.len % 2 == 1) @as(usize, 2) else 1);
        var sum: f64 = 0;
        for (0..result.count) |index| {
            const value = stroke.dashes[index % stroke.dashes.len];
            if (value > 0 and sum + value == sum) return error.UnsupportedStrokePrecision;
            sum += value;
        }
        if (sum == 0) {
            result.solid = true;
            return result;
        }
        var offset = @mod(stroke.dash_offset, sum);
        // The boundary belongs to the preceding dash, including a zero on
        // dash at the origin. This preserves the SVG cap at that position.
        while (true) {
            try work.step();
            if (result.index == result.count) return error.UnsupportedStrokePrecision;
            const value = stroke.dashes[result.index % stroke.dashes.len];
            if (offset <= value) {
                result.remaining = value - offset;
                break;
            }
            if (value > 0 and offset - value == offset) return error.UnsupportedStrokePrecision;
            offset -= value;
            result.index += 1;
        }
        return result;
    }
    fn raw(self: *Iterator, work: *Work) !?Range {
        if (self.solid) {
            if (self.started) return null;
            self.started = true;
            return .{ .start = 0, .end = self.length };
        }
        while (true) {
            try work.step();
            if (self.started) {
                if (self.position >= self.length) return null;
                self.index = (self.index + 1) % self.count;
                self.remaining = self.stroke.dashes[self.index % self.stroke.dashes.len];
            }
            self.started = true;
            const start = self.position;
            const distance = @min(self.remaining, self.length - start);
            const end = start + distance;
            if (distance > 0 and end == start) return error.UnsupportedStrokePrecision;
            self.position = end;
            if (self.index % 2 == 0) return .{ .start = start, .end = end };
        }
    }
    pub fn next(self: *Iterator, work: *Work) !?Range {
        if (self.pending) |range| {
            self.pending = null;
            return range;
        }
        const trim = self.stroke.trim;
        if (trim.start == trim.end) return null;
        while (try self.raw(work)) |range| {
            if (trim.start == 0 and trim.end == 1) return range;
            if (trim.start < trim.end) {
                if (intersect(range, .{ .start = trim.start * self.length, .end = trim.end * self.length })) |clipped| return clipped;
            } else {
                const first = intersect(range, .{ .start = 0, .end = trim.end * self.length });
                const last = intersect(range, .{ .start = trim.start * self.length, .end = self.length });
                if (first) |clipped| {
                    self.pending = last;
                    return clipped;
                }
                if (last) |clipped| return clipped;
            }
        }
        return null;
    }
};
fn intersect(a: Range, b: Range) ?Range {
    if (b.start == b.end) return null;
    const start = @max(a.start, b.start);
    const end = @min(a.end, b.end);
    if (end < start or (end == start and a.start != a.end)) return null;
    return .{ .start = start, .end = end };
}
