//! A time scale whose ticks fall on round calendar times.
const std = @import("std");
const zio = @import("ziggurat_io");
const scale = @import("scale.zig");
const Span = scale.Span;
const Tick = scale.Tick;

const ms_second: i64 = 1000;
const ms_minute: i64 = 60 * ms_second;
const ms_hour: i64 = 60 * ms_minute;
const ms_day: i64 = 24 * ms_hour;
const ms_week: i64 = 7 * ms_day;
const ms_month: i64 = 30 * ms_day;
const ms_year: i64 = 365 * ms_day;

/// A broken-down civil time in a fixed offset from UTC.
pub const Civil = struct {
    year: i64,
    /// 1 to 12.
    month: u8,
    /// 1 to 31.
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
    /// 0 is Sunday.
    weekday: u8,
    /// 1 to 366.
    year_day: u16,
};

/// Days from 1970-01-01 to the first of `month` (1-based, any integer) of `year`.
fn daysFromCivil(year_in: i64, month_in: i64) i64 {
    const months = year_in * 12 + (month_in - 1);
    const y0 = @divFloor(months, 12);
    const m: i64 = @mod(months, 12) + 1;
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5);
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Milliseconds since the Unix epoch of a civil time `offset` minutes east
/// of UTC. Fields out of range carry into the next, as day 0 is the last
/// day of the previous month.
pub fn fromCivil(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, millisecond: i64, offset: i32) i64 {
    const days = daysFromCivil(year, month) + day - 1;
    return days * ms_day + hour * ms_hour + minute * ms_minute + second * ms_second + millisecond - @as(i64, offset) * ms_minute;
}

/// The civil time of `ms` since the Unix epoch, `offset` minutes east of UTC.
pub fn toCivil(ms: i64, offset: i32) Civil {
    const local = ms + @as(i64, offset) * ms_minute;
    const days = @divFloor(local, ms_day);
    const rest = local - days * ms_day;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{
        .year = y,
        .month = @intCast(zio.asUnsigned(m)),
        .day = @intCast(zio.asUnsigned(d)),
        .hour = @intCast(zio.asUnsigned(@divFloor(rest, ms_hour))),
        .minute = @intCast(zio.asUnsigned(@divFloor(@mod(rest, ms_hour), ms_minute))),
        .second = @intCast(zio.asUnsigned(@divFloor(@mod(rest, ms_minute), ms_second))),
        .millisecond = @intCast(zio.asUnsigned(@mod(rest, ms_second))),
        .weekday = @intCast(zio.asUnsigned(@mod(days + 4, 7))),
        .year_day = @intCast(zio.asUnsigned(days - daysFromCivil(y, 1) + 1)),
    };
}

const Unit = enum { millisecond, second, minute, hour, day, week, month, year };

/// A step of ticks: every `n` units, about `ms` long.
const Interval = struct { unit: Unit, n: i64, ms: i64 };

/// Tick intervals by their length.
const intervals = [_]Interval{
    .{ .unit = .second, .n = 1, .ms = ms_second },       .{ .unit = .second, .n = 5, .ms = 5 * ms_second },
    .{ .unit = .second, .n = 15, .ms = 15 * ms_second }, .{ .unit = .second, .n = 30, .ms = 30 * ms_second },
    .{ .unit = .minute, .n = 1, .ms = ms_minute },       .{ .unit = .minute, .n = 5, .ms = 5 * ms_minute },
    .{ .unit = .minute, .n = 15, .ms = 15 * ms_minute }, .{ .unit = .minute, .n = 30, .ms = 30 * ms_minute },
    .{ .unit = .hour, .n = 1, .ms = ms_hour },           .{ .unit = .hour, .n = 3, .ms = 3 * ms_hour },
    .{ .unit = .hour, .n = 6, .ms = 6 * ms_hour },       .{ .unit = .hour, .n = 12, .ms = 12 * ms_hour },
    .{ .unit = .day, .n = 1, .ms = ms_day },             .{ .unit = .day, .n = 2, .ms = 2 * ms_day },
    .{ .unit = .week, .n = 1, .ms = ms_week },           .{ .unit = .month, .n = 1, .ms = ms_month },
    .{ .unit = .month, .n = 3, .ms = 3 * ms_month },     .{ .unit = .year, .n = 1, .ms = ms_year },
};

/// The interval of about `count` ticks from `lo` to `hi`: the one closest
/// to the span over count, in years beyond them and milliseconds below them.
fn tickInterval(lo: i64, hi: i64, count: usize, offset: i32) Interval {
    const target = @as(f64, @floatFromInt(hi - lo)) / @as(f64, @floatFromInt(@max(1, count)));
    var i: usize = 0;
    while (i < intervals.len and !(@as(f64, @floatFromInt(intervals[i].ms)) > target)) i += 1;
    if (i == intervals.len) {
        const a = toCivil(lo, offset);
        const b = toCivil(hi, offset);
        const n = scale.tickStep(@floatFromInt(a.year), @as(f64, @floatFromInt(b.year)) + @as(f64, @floatFromInt(b.year_day)) / 366, @floatFromInt(count));
        return .{ .unit = .year, .n = @max(1, @as(i64, @intFromFloat(@round(n)))), .ms = ms_year };
    }
    if (i == 0) {
        const n = scale.tickStep(0, @floatFromInt(hi - lo), @floatFromInt(count));
        return .{ .unit = .millisecond, .n = @max(1, @as(i64, @intFromFloat(@round(n)))), .ms = 1 };
    }
    const before: f64 = @floatFromInt(intervals[i - 1].ms);
    const after: f64 = @floatFromInt(intervals[i].ms);
    return if (target / before < after / target) intervals[i - 1] else intervals[i];
}

/// The latest round time of the interval at or before `t`.
fn floor(iv: Interval, t: i64, offset: i32) i64 {
    const c = toCivil(t, offset);
    const n = iv.n;
    return switch (iv.unit) {
        .millisecond => fromCivil(c.year, c.month, c.day, c.hour, c.minute, c.second, c.millisecond - @mod(@as(i64, c.millisecond), n), offset),
        .second => fromCivil(c.year, c.month, c.day, c.hour, c.minute, c.second - @mod(@as(i64, c.second), n), 0, offset),
        .minute => fromCivil(c.year, c.month, c.day, c.hour, c.minute - @mod(@as(i64, c.minute), n), 0, 0, offset),
        .hour => fromCivil(c.year, c.month, c.day, c.hour - @mod(@as(i64, c.hour), n), 0, 0, 0, offset),
        .day => fromCivil(c.year, c.month, c.day - @mod(@as(i64, c.day) - 1, n), 0, 0, 0, 0, offset),
        // Weeks start on Sunday.
        .week => fromCivil(c.year, c.month, @as(i64, c.day) - c.weekday, 0, 0, 0, 0, offset),
        .month => blk: {
            const m: i64 = @as(i64, c.month) - 1;
            break :blk fromCivil(c.year, m - @mod(m, n) + 1, 1, 0, 0, 0, 0, offset);
        },
        .year => fromCivil(c.year - @mod(c.year, n), 1, 1, 0, 0, 0, 0, offset),
    };
}

/// The round time of the interval after `t`, a round time.
fn next(iv: Interval, t: i64, offset: i32) i64 {
    const c = toCivil(t, offset);
    return switch (iv.unit) {
        .millisecond => t + iv.n,
        .second, .minute => t + iv.ms,
        .hour => fromCivil(c.year, c.month, c.day, @as(i64, c.hour) + iv.n, 0, 0, 0, offset),
        .day => blk: {
            const candidate = fromCivil(c.year, c.month, @as(i64, c.day) + iv.n, 0, 0, 0, 0, offset);
            const after = toCivil(candidate, offset);
            // Days of a month count from its first.
            if (after.month != c.month) break :blk fromCivil(after.year, after.month, 1, 0, 0, 0, 0, offset);
            break :blk candidate;
        },
        .week => fromCivil(c.year, c.month, @as(i64, c.day) + 7 * iv.n, 0, 0, 0, 0, offset),
        .month => fromCivil(c.year, @as(i64, c.month) + iv.n, 1, 0, 0, 0, 0, offset),
        .year => fromCivil(c.year + iv.n, 1, 1, 0, 0, 0, 0, offset),
    };
}

/// Labels a time tick: write into `buffer` and return the written part.
pub const TimeFormat = struct {
    context: ?*const anyopaque = null,
    call: *const fn (context: ?*const anyopaque, ms: i64, offset: i32, buffer: []u8) []const u8,
};

/// Maps times, in milliseconds since the Unix epoch, from `from` to `to`
/// onto the plot. Ticks fall on round times `offset` minutes east of UTC: a
/// second, a quarter of an hour, a midnight, a Sunday, the first of a month,
/// chosen for the span.
pub const Time = struct {
    from: i64,
    to: i64,
    /// The fixed UTC offset of the times' location, in minutes.
    offset: i32 = 0,
    /// Labels the ticks; null labels each with the finest unit it is not
    /// round in: "2026", "Mar", "Mar 5", "14:00", "14:05", ":30", ".250".
    format: ?TimeFormat = null,

    pub fn init(from: i64, to: i64) Time {
        return .{ .from = from, .to = to };
    }

    pub fn at(self: Time, t: i64) f32 {
        const length = self.to - self.from;
        if (length == 0) return 0.5;
        return @floatCast(@as(f64, @floatFromInt(t - self.from)) / @as(f64, @floatFromInt(length)));
    }

    pub fn span(self: Time, a: i64, b: i64) Span {
        return .{ .lo = self.at(a), .hi = self.at(b) };
    }

    pub fn invert(self: Time, f: f32) i64 {
        return self.from + @as(i64, @intFromFloat(@round(@as(f64, f) * @as(f64, @floatFromInt(self.to - self.from)))));
    }

    /// About `count` round times within the domain, written to `out`.
    pub fn ticks(self: Time, count: usize, out: []Tick) scale.Error![]Tick {
        var lo = self.from;
        var hi = self.to;
        if (hi < lo) std.mem.swap(i64, &lo, &hi);
        if (count == 0 or !(lo < hi)) return out[0..0];
        const iv = tickInterval(lo, hi, count, self.offset);
        var buffer: [64]u8 = undefined;
        var len: usize = 0;
        var t = floor(iv, lo, self.offset);
        var steps: usize = 0;
        while (t <= hi and steps < 1000) : (steps += 1) {
            if (t >= lo) {
                if (len == out.len) return error.TooManyTicks;
                out[len] = .{ .at = self.at(t), .value = @floatFromInt(t) };
                const text = if (self.format) |format| format.call(format.context, t, self.offset, &buffer) else formatTime(&buffer, t, self.offset);
                out[len].setLabel(text);
                len += 1;
            }
            t = next(iv, t, self.offset);
        }
        if (self.to < self.from) std.mem.reverse(Tick, out[0..len]);
        return out[0..len];
    }
};

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Label a time with the finest unit it is not round in.
pub fn formatTime(buffer: []u8, ms: i64, offset: i32) []const u8 {
    const c = toCivil(ms, offset);
    const result = if (c.millisecond != 0)
        std.fmt.bufPrint(buffer, ".{d:0>3}", .{c.millisecond})
    else if (c.second != 0)
        std.fmt.bufPrint(buffer, ":{d:0>2}", .{c.second})
    else if (c.minute != 0)
        std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{ c.hour, c.minute })
    else if (c.hour != 0)
        std.fmt.bufPrint(buffer, "{d:0>2}:00", .{c.hour})
    else if (c.day != 1)
        std.fmt.bufPrint(buffer, "{s} {d}", .{ month_names[c.month - 1], c.day })
    else if (c.month != 1)
        std.fmt.bufPrint(buffer, "{s}", .{month_names[c.month - 1]})
    else if (c.year >= 0)
        std.fmt.bufPrint(buffer, "{d:0>4}", .{@as(u64, @intCast(c.year))})
    else
        std.fmt.bufPrint(buffer, "{d}", .{c.year});
    return result catch buffer[0..0];
}
