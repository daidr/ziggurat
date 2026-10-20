//! Scales map data onto a plot as fractions of it and pick round ticks.
const std = @import("std");

/// A stretch of a plot along one axis, in fractions of it: from the left
/// edge (0) to the right (1) along x, and from the bottom (0) to the top (1)
/// along y, the way values grow.
pub const Span = struct {
    lo: f32,
    hi: f32,
    pub fn mid(self: Span) f32 {
        return (self.lo + self.hi) / 2;
    }
};

/// Longest tick label kept inline, in bytes; longer labels are cut at a
/// UTF-8 boundary.
pub const max_label = 32;

/// A value a scale marks along an axis: where it is, in a fraction of the
/// plot, and its label, stored inline so ticks need no allocation.
pub const Tick = struct {
    at: f32,
    value: f64,
    label_bytes: [max_label]u8 = undefined,
    label_len: u8 = 0,

    pub fn init(at: f32, value: f64, text: []const u8) Tick {
        var tick: Tick = .{ .at = at, .value = value };
        tick.setLabel(text);
        return tick;
    }
    pub fn label(self: *const Tick) []const u8 {
        return self.label_bytes[0..self.label_len];
    }
    pub fn setLabel(self: *Tick, text: []const u8) void {
        var len = @min(text.len, max_label);
        while (len > 0 and len < text.len and text[len] & 0xc0 == 0x80) len -= 1;
        std.mem.copyForwards(u8, self.label_bytes[0..len], text[0..len]);
        self.label_len = @intCast(len);
    }
};

/// Labels a tick: write the label into `buffer` and return the written part.
pub const Format = struct {
    context: ?*const anyopaque = null,
    call: *const fn (context: ?*const anyopaque, value: f64, buffer: []u8) []const u8,
};

pub const Error = error{TooManyTicks};

/// Maps numbers from `lo` to `hi` onto the plot, `lo` at its start. Values
/// outside the domain land outside the plot unless `clamp` is set.
pub const Linear = struct {
    lo: f64,
    hi: f64,
    /// Keep values outside the domain at its ends.
    clamp: bool = false,
    /// Labels the ticks; null labels them with as many decimals as their
    /// step needs.
    format: ?Format = null,

    pub fn init(lo: f64, hi: f64) Linear {
        return .{ .lo = lo, .hi = hi };
    }

    /// Where `v` is along the plot.
    pub fn at(self: Linear, v: f64) f32 {
        if (self.hi == self.lo) return 0.5;
        var f = (v - self.lo) / (self.hi - self.lo);
        if (self.clamp) f = @max(0, @min(1, f));
        return @floatCast(f);
    }

    /// The stretch from `a` to `b`, as a bar's from 0 to its value.
    pub fn span(self: Linear, a: f64, b: f64) Span {
        return .{ .lo = self.at(a), .hi = self.at(b) };
    }

    /// The value at `f` along the plot, as under the pointer.
    pub fn invert(self: Linear, f: f32) f64 {
        var v = self.lo + @as(f64, f) * (self.hi - self.lo);
        if (self.clamp) v = @max(@min(self.lo, self.hi), @min(@max(self.lo, self.hi), v));
        return v;
    }

    /// Extend the domain to the round values of about `count` ticks: 0 to
    /// 87 becomes 0 to 90 for 10 ticks, and 0 to 100 for 5.
    pub fn nice(self: Linear, count: usize) Linear {
        var lo = self.lo;
        var hi = self.hi;
        const reverse = hi < lo;
        if (reverse) std.mem.swap(f64, &lo, &hi);
        var prev: f64 = 0;
        for (0..10) |_| {
            const step = tickIncrement(lo, hi, @floatFromInt(count));
            if (step == prev) break;
            if (step > 0) {
                lo = @floor(lo / step) * step;
                hi = @ceil(hi / step) * step;
            } else if (step < 0) {
                lo = @ceil(lo * step) / step;
                hi = @floor(hi * step) / step;
            } else return self;
            prev = step;
        }
        if (reverse) std.mem.swap(f64, &lo, &hi);
        var out = self;
        out.lo = lo;
        out.hi = hi;
        return out;
    }

    /// About `count` round values within the domain, 1, 2 or 5 times a power
    /// of ten apart, written to `out`: 0, 20, 40, 60, 80 and 100 for 0 to
    /// 100 and 5.
    pub fn ticks(self: Linear, count: usize, out: []Tick) Error![]Tick {
        var spec = tickValues(self.lo, self.hi, @floatFromInt(count));
        if (spec.len > out.len) return error.TooManyTicks;
        const decimals = labelDecimals(self.lo, self.hi, count);
        var buffer: [64]u8 = undefined;
        var i: usize = 0;
        while (spec.next()) |v| : (i += 1) {
            out[i] = .{ .at = self.at(v), .value = v };
            const text = if (self.format) |format| format.call(format.context, v, &buffer) else formatFixed(&buffer, v, decimals);
            out[i].setLabel(text);
        }
        return out[0..i];
    }
};

/// The smallest and largest of `values`, ignoring NaN; 0 and 1 for none.
pub fn extent(values: []const f64) struct { lo: f64, hi: f64 } {
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (values) |v| {
        if (std.math.isNan(v)) continue;
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    if (lo > hi) return .{ .lo = 0, .hi = 1 };
    return .{ .lo = lo, .hi = hi };
}

fn labelDecimals(lo: f64, hi: f64, count: usize) usize {
    const step = @abs(tickStep(lo, hi, @floatFromInt(count)));
    if (!(step > 0 and step < 1)) return 0;
    var decimals: usize = @intFromFloat(@max(0, -@floor(std.math.log10(step) + 1e-9)));
    const scaled = step * std.math.pow(f64, 10, @floatFromInt(decimals));
    if (scaled != @round(scaled)) decimals += 1;
    return decimals;
}

pub fn formatFixed(buffer: []u8, value: f64, decimals: usize) []const u8 {
    const v = if (value == 0) 0 else value; // no -0
    return std.fmt.bufPrint(buffer, "{d:.[1]}", .{ v, decimals }) catch buffer[0..0];
}

const e10 = @sqrt(50.0);
const e5 = @sqrt(10.0);
const e2 = @sqrt(2.0);

const Spec = struct { i1: f64, i2: f64, inc: f64 };

/// The first and last tick's index and the step between ticks, negative for
/// the inverse of the step below 1, so that ticks such as 0.3 come out exact.
fn tickSpec(lo: f64, hi: f64, count: f64) Spec {
    const step = (hi - lo) / @max(0, count);
    const power = @floor(std.math.log10(step));
    const e = step / std.math.pow(f64, 10, power);
    const factor: f64 = if (e >= e10) 10 else if (e >= e5) 5 else if (e >= e2) 2 else 1;
    var first: f64 = undefined;
    var last: f64 = undefined;
    var inc: f64 = undefined;
    if (power < 0) {
        inc = std.math.pow(f64, 10, -power) / factor;
        first = @round(lo * inc);
        last = @round(hi * inc);
        if (first / inc < lo) first += 1;
        if (last / inc > hi) last -= 1;
        inc = -inc;
    } else {
        inc = std.math.pow(f64, 10, power) * factor;
        first = @round(lo / inc);
        last = @round(hi / inc);
        if (first * inc < lo) first += 1;
        if (last * inc > hi) last -= 1;
    }
    if (last < first and 0.5 <= count and count < 2) return tickSpec(lo, hi, count * 2);
    return .{ .i1 = first, .i2 = last, .inc = inc };
}

/// The round values between `lo` and `hi`, in their order, without storage.
pub const TickValues = struct {
    i1: f64 = 0,
    inc: f64 = 1,
    len: usize = 0,
    index: usize = 0,
    reverse: bool = false,
    single: ?f64 = null,

    pub fn next(self: *TickValues) ?f64 {
        if (self.index >= self.len) return null;
        defer self.index += 1;
        if (self.single) |v| return v;
        const k: f64 = @floatFromInt(if (self.reverse) self.len - 1 - self.index else self.index);
        return if (self.inc < 0) (self.i1 + k) / -self.inc else (self.i1 + k) * self.inc;
    }
};

pub fn tickValues(lo_in: f64, hi_in: f64, count: f64) TickValues {
    if (!(count > 0) or !std.math.isFinite(lo_in) or !std.math.isFinite(hi_in)) return .{};
    if (lo_in == hi_in) return .{ .len = 1, .single = lo_in };
    var lo = lo_in;
    var hi = hi_in;
    const reverse = hi < lo;
    if (reverse) std.mem.swap(f64, &lo, &hi);
    const spec = tickSpec(lo, hi, count);
    if (!(spec.i2 >= spec.i1) or !std.math.isFinite(spec.inc)) return .{};
    const n = spec.i2 - spec.i1 + 1;
    if (n > 1e6) return .{};
    return .{ .i1 = spec.i1, .inc = spec.inc, .len = @intFromFloat(n), .reverse = reverse };
}

/// The step between ticks, or its negative inverse below 1.
pub fn tickIncrement(lo: f64, hi: f64, count: f64) f64 {
    return tickSpec(lo, hi, count).inc;
}

/// The step between ticks, signed as `hi - lo`.
pub fn tickStep(lo_in: f64, hi_in: f64, count: f64) f64 {
    var lo = lo_in;
    var hi = hi_in;
    const reverse = hi < lo;
    if (reverse) std.mem.swap(f64, &lo, &hi);
    var inc = tickIncrement(lo, hi, count);
    if (inc < 0) inc = 1 / -inc;
    return if (reverse) -inc else inc;
}

/// Divides the plot into a band for each of its labels: the bars of a bar
/// chart, one for each month. Labels are borrowed.
pub const Band = struct {
    labels: []const []const u8,
    /// Room between bands, and before the first and after the last, in
    /// fractions of a band's step.
    inner: f32 = 0,
    outer: f32 = 0,
    /// Where the bands sit in the room the outer padding leaves: 0 at the
    /// start, 0.5 in the middle, 1 at the end.
    alignment: f32 = 0.5,

    pub fn init(labels: []const []const u8) Band {
        return .{ .labels = labels };
    }

    /// Set the room between bands and around them, in fractions of a step.
    pub fn padding(self: Band, inner: f32, outer: f32) Band {
        var out = self;
        out.inner = @max(0, @min(1, inner));
        out.outer = @max(0, outer);
        return out;
    }

    fn step(self: Band) struct { step: f32, start: f32 } {
        const n: f32 = @floatFromInt(self.labels.len);
        const s = 1 / @max(1, n - self.inner + 2 * self.outer);
        return .{ .step = s, .start = (1 - s * (n - self.inner)) * self.alignment };
    }

    /// The stretch of the `i`-th band.
    pub fn band(self: Band, i: usize) Span {
        const s = self.step();
        const lo = s.start + s.step * @as(f32, @floatFromInt(i));
        return .{ .lo = lo, .hi = lo + self.width() };
    }

    /// The width of a band, in a fraction of the plot.
    pub fn width(self: Band) f32 {
        return self.step().step * (1 - self.inner);
    }

    /// The middle of the `i`-th band.
    pub fn at(self: Band, i: usize) f32 {
        return self.band(i).mid();
    }

    /// The band whose step holds `f`, so that the room between bars belongs
    /// to a bar; null outside every band's step.
    pub fn index(self: Band, f: f32) ?usize {
        if (self.labels.len == 0) return null;
        const s = self.step();
        // A band's step starts half the inner padding before it.
        const k = (f - s.start + s.step * self.inner / 2) / s.step;
        if (!(k >= 0) or k >= @as(f32, @floatFromInt(self.labels.len))) return null;
        return @intFromFloat(k);
    }

    /// A tick in the middle of each band, labeled with its label.
    pub fn ticks(self: Band, out: []Tick) Error![]Tick {
        if (self.labels.len > out.len) return error.TooManyTicks;
        for (self.labels, 0..) |text, i| out[i] = Tick.init(self.at(i), @floatFromInt(i), text);
        return out[0..self.labels.len];
    }
};
