//! Tests of the logarithmic and symmetric log scales, against values that
//! `scripts/chart-scales-golden.mjs` generated from d3-scale 4.0.2.
const std = @import("std");
const scale = @import("scale.zig");
const log = @import("log.zig");

const testing = std.testing;
const Tick = scale.Tick;
const Log = log.Log;
const SymLog = log.SymLog;

const Case = struct {
    kind: []const u8,
    domain: [2]f64,
    parameter: f64,
    count: usize,
    clamp: bool,
    values: []const f64,
    positions: []const f64,
    fractions: []const f64,
    inversions: []const f64,
    ticks: []const f64,
    nice: [2]f64,
};
const Golden = struct { version: []const u8, cases: []const Case };

fn near(a: f64, b: f64) bool {
    return @abs(a - b) <= @max(4 * std.math.floatTrueMin(f64), 1e-9 * @abs(b));
}

test "log and symlog scales place, invert, tick and round their domains as d3-scale does" {
    const gz = @embedFile("testdata/log_scales.json.gz");
    var in: std.Io.Reader = .fixed(gz);
    const window = try testing.allocator.alloc(u8, std.compress.flate.max_window_len);
    defer testing.allocator.free(window);
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, window);
    const text = try decompress.reader.allocRemaining(testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(Golden, testing.allocator, text, .{});
    defer parsed.deinit();
    const golden = parsed.value;
    try testing.expectEqualStrings("4.0.2", golden.version);
    try testing.expect(golden.cases.len > 1000);
    var buffer: [4096]Tick = undefined;
    for (golden.cases, 0..) |c, index| {
        errdefer std.debug.print("case {d}: {s} {any} parameter {d} count {d} clamp {}\n", .{ index, c.kind, c.domain, c.parameter, c.count, c.clamp });
        const is_log = std.mem.eql(u8, c.kind, "log");
        var lg: Log = .{ .lo = c.domain[0], .hi = c.domain[1], .base = c.parameter, .clamp = c.clamp };
        var sl: SymLog = .{ .lo = c.domain[0], .hi = c.domain[1], .constant = c.parameter, .clamp = c.clamp };
        for (c.values, c.positions) |v, want| {
            const got: f64 = if (is_log) lg.at(v) else sl.at(v);
            if (!std.math.isFinite(got) or @abs(got - want) > 2e-6) {
                std.debug.print("at({d}) = {d}, want {d}\n", .{ v, got, want });
                return error.Position;
            }
        }
        for (c.fractions, c.inversions) |f, want| {
            const got = if (is_log) lg.invert(@floatCast(f)) else sl.invert(@floatCast(f));
            if (!near(got, want)) {
                std.debug.print("invert({d}) = {d}, want {d}\n", .{ f, got, want });
                return error.Inversion;
            }
        }
        const ticks = if (is_log) try lg.ticks(c.count, &buffer) else try sl.ticks(c.count, &buffer);
        // d3-scale gives a domain of one value no tick for a base that is
        // not whole; the scale keeps that value, as the other scales do.
        const one: [1]f64 = .{c.domain[0]};
        const want_ticks = if (is_log and c.domain[0] == c.domain[1] and c.ticks.len == 0) one[0..] else c.ticks;
        if (ticks.len != want_ticks.len) {
            std.debug.print("{d} ticks, want {any}\n", .{ ticks.len, want_ticks });
            return error.TickCount;
        }
        for (ticks, want_ticks) |tick, want| if (!near(tick.value, want)) {
            std.debug.print("tick {d}, want {d}\n", .{ tick.value, want });
            return error.Tick;
        };
        const nice: [2]f64 = if (is_log) blk: {
            lg = lg.nice();
            break :blk .{ lg.lo, lg.hi };
        } else blk: {
            sl = sl.nice(c.count);
            break :blk .{ sl.lo, sl.hi };
        };
        for (nice, c.nice) |got, want| if (!near(got, want)) {
            std.debug.print("nice {any}, want {any}\n", .{ nice, c.nice });
            return error.Nice;
        };
    }
}

test "equal ratios lie equal distances apart, and minor ticks lose their labels when crowded" {
    const latency = Log.init(0.01, 1000);
    try testing.expectApproxEqAbs(@as(f32, 0.2), latency.at(0.1), 1e-6);
    try testing.expectApproxEqRel(@as(f64, 3.1622776601683795), latency.invert(0.5), 1e-6);
    var buffer: [64]Tick = undefined;
    const ticks = try Log.init(1, 1000).ticks(10, &buffer);
    try testing.expectEqual(@as(usize, 28), ticks.len);
    try testing.expectEqualStrings("1", ticks[0].label());
    try testing.expectEqualStrings("2", ticks[1].label());
    try testing.expectEqualStrings("10", ticks[9].label());
    try testing.expectEqualStrings("1000", ticks[27].label());
    // Crowded: only the powers keep labels.
    const crowded = try Log.init(1, 1e6).ticks(5, &buffer);
    for (crowded) |tick| {
        const power = tick.value == 1 or tick.value == 10 or tick.value == 100 or tick.value == 1e3 or tick.value == 1e4 or tick.value == 1e5 or tick.value == 1e6;
        try testing.expectEqual(power, tick.label().len > 0);
    }
    try testing.expectEqualStrings("1e+06", crowded[crowded.len - 1].label());
    try testing.expect(std.math.isNan(latency.at(-1)));
    try testing.expect(std.math.isNan(Log.init(-1, 1).at(0.5)));
    try testing.expectEqual(@as(usize, 0), (try Log.init(0, 10).ticks(5, &buffer)).len);
    var clamped = latency;
    clamped.clamp = true;
    try testing.expectEqual(@as(f32, 0), clamped.at(0));
}

test "a symmetric log scale places zero and both signs, nearly linear around zero" {
    var changes = SymLog.init(-1000, 1000);
    changes.constant = 10;
    try testing.expectEqual(@as(f32, 0.5), changes.at(0));
    const bar = changes.span(0, -100);
    try testing.expectEqual(@as(f32, 0.5), bar.lo);
    try testing.expect(bar.hi < 0.5 and bar.hi > 0);
    try testing.expectApproxEqAbs(changes.at(1) - 0.5, 0.5 - changes.at(-1), 1e-6);
    var buffer: [32]Tick = undefined;
    const ticks = try changes.ticks(5, &buffer);
    try testing.expectEqualStrings("-1000", ticks[0].label());
    try testing.expectEqualStrings("0", ticks[ticks.len / 2].label());
    try testing.expectEqual(@as(f32, 0.5), ticks[ticks.len / 2].at);
}

test "significant digits as tick labels" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("0.001", log.formatSignificant(&buffer, 0.001, 6));
    try testing.expectEqualStrings("1000", log.formatSignificant(&buffer, 1000, 6));
    try testing.expectEqualStrings("100000", log.formatSignificant(&buffer, 1e5, 6));
    try testing.expectEqualStrings("1e+06", log.formatSignificant(&buffer, 1e6, 6));
    try testing.expectEqualStrings("1e-05", log.formatSignificant(&buffer, 1e-5, 6));
    try testing.expectEqualStrings("3.16228", log.formatSignificant(&buffer, 3.16227766, 6));
    try testing.expectEqualStrings("-0.25", log.formatSignificant(&buffer, -0.25, 6));
    try testing.expectEqualStrings("1e+06", log.formatSignificant(&buffer, 999999.7, 6));
}
