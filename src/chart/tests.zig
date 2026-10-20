//! Expected values are those of the common web charting scales for the same
//! input; times are in UTC unless an offset is given.
const std = @import("std");
const chart = @import("root.zig");
const testing = std.testing;

fn collect(values: chart.TickValues, out: []f64) []f64 {
    var it = values;
    var i: usize = 0;
    while (it.next()) |v| : (i += 1) out[i] = v;
    return out[0..i];
}

test "linear ticks are 1, 2 or 5 times a power of ten apart" {
    const cases = [_]struct { lo: f64, hi: f64, count: f64, want: []const f64 }{
        .{ .lo = 0, .hi = 1, .count = 10, .want = &.{ 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1 } },
        .{ .lo = 0, .hi = 100, .count = 5, .want = &.{ 0, 20, 40, 60, 80, 100 } },
        .{ .lo = 0, .hi = 87, .count = 5, .want = &.{ 0, 20, 40, 60, 80 } },
        .{ .lo = -3.2, .hi = 7.9, .count = 6, .want = &.{ -2, 0, 2, 4, 6 } },
        .{ .lo = 0.0012, .hi = 0.0047, .count = 5, .want = &.{ 0.0015, 0.002, 0.0025, 0.003, 0.0035, 0.004, 0.0045 } },
        .{ .lo = 1e6, .hi = 3.4e6, .count = 4, .want = &.{ 1e6, 1.5e6, 2e6, 2.5e6, 3e6 } },
        .{ .lo = 10, .hi = 0, .count = 5, .want = &.{ 10, 8, 6, 4, 2, 0 } },
        .{ .lo = 0.1, .hi = 0.9, .count = 3, .want = &.{ 0.2, 0.4, 0.6, 0.8 } },
        .{ .lo = 1, .hi = 1, .count = 5, .want = &.{1} },
        .{ .lo = 0, .hi = 1, .count = 1, .want = &.{ 0, 1 } },
    };
    var buffer: [32]f64 = undefined;
    for (cases) |case| try testing.expectEqualSlices(f64, case.want, collect(chart.tickValues(case.lo, case.hi, case.count), &buffer));
    try testing.expectEqual(@as(usize, 0), collect(chart.tickValues(0, std.math.nan(f64), 5), &buffer).len);
}

test "nice rounds the domain out to round ticks" {
    const cases = [_]struct { lo: f64, hi: f64, count: usize, want: [2]f64 }{
        .{ .lo = 0, .hi = 87, .count = 5, .want = .{ 0, 100 } },
        .{ .lo = 0, .hi = 87, .count = 10, .want = .{ 0, 90 } },
        .{ .lo = 0, .hi = 87, .count = 2, .want = .{ 0, 100 } },
        .{ .lo = -3.2, .hi = 7.9, .count = 6, .want = .{ -4, 8 } },
        .{ .lo = 0.0012, .hi = 0.0047, .count = 5, .want = .{ 0.001, 0.005 } },
        .{ .lo = 13, .hi = 1042, .count = 10, .want = .{ 0, 1100 } },
        .{ .lo = 90, .hi = 3, .count = 5, .want = .{ 100, 0 } },
    };
    for (cases) |case| {
        const s = chart.Linear.init(case.lo, case.hi).nice(case.count);
        try testing.expectEqual(case.want, [2]f64{ s.lo, s.hi });
    }
}

fn joinLabels(ticks: []const chart.Tick, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (ticks, 0..) |*tick, i| {
        if (i > 0) {
            buffer[len] = ' ';
            len += 1;
        }
        @memcpy(buffer[len..][0..tick.label().len], tick.label());
        len += tick.label().len;
    }
    return buffer[0..len];
}

fn constantLabel(_: ?*const anyopaque, _: f64, buffer: []u8) []const u8 {
    buffer[0] = 'x';
    return buffer[0..1];
}

test "tick labels carry the decimals their step needs" {
    const cases = [_]struct { s: chart.Linear, count: usize, want: []const u8 }{
        .{ .s = chart.Linear.init(0, 1), .count = 5, .want = "0.0 0.2 0.4 0.6 0.8 1.0" },
        .{ .s = chart.Linear.init(0, 100), .count = 5, .want = "0 20 40 60 80 100" },
        .{ .s = chart.Linear.init(0.0012, 0.0047), .count = 5, .want = "0.0015 0.0020 0.0025 0.0030 0.0035 0.0040 0.0045" },
        .{ .s = chart.Linear.init(-1, 1), .count = 4, .want = "-1.0 -0.5 0.0 0.5 1.0" },
        .{ .s = .{ .lo = 0, .hi = 1, .format = .{ .call = constantLabel } }, .count = 1, .want = "x x" },
        .{ .s = chart.Linear.init(1e6, 3.4e6), .count = 4, .want = "1000000 1500000 2000000 2500000 3000000" },
    };
    var ticks: [16]chart.Tick = undefined;
    var text: [256]u8 = undefined;
    for (cases) |case| try testing.expectEqualStrings(case.want, joinLabels(try case.s.ticks(case.count, &ticks), &text));
    const half = try chart.Linear.init(0, 200).ticks(2, &ticks);
    try testing.expectEqual(@as(f32, 0.5), half[1].at);
    try testing.expectEqual(@as(f64, 100), half[1].value);
    var few: [2]chart.Tick = undefined;
    try testing.expectError(error.TooManyTicks, chart.Linear.init(0, 1).ticks(10, &few));
}

test "long tick labels are cut at a character boundary" {
    var tick = chart.Tick.init(0, 0, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u{00e9}");
    try testing.expectEqual(@as(usize, 31), tick.label().len);
    tick.setLabel("short");
    try testing.expectEqualStrings("short", tick.label());
}

test "linear scales map, invert, clamp and find the extent" {
    var s = chart.Linear.init(-10, 30);
    try testing.expectEqual(@as(f32, 0.25), s.at(0));
    try testing.expectEqual(@as(f64, 20), s.invert(0.75));
    try testing.expectEqual(chart.Span{ .lo = 0.25, .hi = 0.5 }, s.span(0, 10));
    s.clamp = true;
    try testing.expectEqual(@as(f32, 1), s.at(50));
    try testing.expectEqual(@as(f64, -10), s.invert(-1));
    try testing.expectEqual(@as(f32, 0.5), chart.Linear.init(3, 3).at(3));
    const e = chart.extent(&.{ 4, std.math.nan(f64), -2, 9 });
    try testing.expectEqual(@as(f64, -2), e.lo);
    try testing.expectEqual(@as(f64, 9), e.hi);
    const none = chart.extent(&.{});
    try testing.expectEqual(@as(f64, 1), none.hi);
}

test "band scales place padded bands and find the band of a fraction" {
    const labels = [_][]const u8{ "a", "b", "c", "d" };
    const b = chart.Band.init(&labels).padding(0.2, 0.1);
    for ([_]f32{ 0.025, 0.275, 0.525, 0.775 }, 0..) |want, i| try testing.expectApproxEqAbs(want, b.band(i).lo, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), b.width(), 1e-6);
    const cases = [_]struct { f: f32, i: ?usize }{
        .{ .f = 0.01, .i = 0 }, .{ .f = 0.1, .i = 0 },      .{ .f = 0.249, .i = 0 },   .{ .f = 0.251, .i = 1 },
        .{ .f = 0.99, .i = 3 }, .{ .f = -0.01, .i = null }, .{ .f = 1.01, .i = null },
    };
    for (cases) |case| try testing.expectEqual(case.i, b.index(case.f));
    var ticks: [4]chart.Tick = undefined;
    const t = try b.ticks(&ticks);
    try testing.expectEqual(@as(usize, 4), t.len);
    try testing.expectEqualStrings("c", t[2].label());
    try testing.expectEqual(b.at(2), t[2].at);
}

fn parseUtc(text: []const u8) i64 {
    // YYYY-MM-DDTHH:MM:SS(.mmm)?Z
    const n = struct {
        fn int(s: []const u8) i64 {
            return std.fmt.parseInt(i64, s, 10) catch unreachable;
        }
    }.int;
    const ms: i64 = if (text.len > 20) n(text[20..23]) else 0;
    return chart.fromCivil(n(text[0..4]), n(text[5..7]), n(text[8..10]), n(text[11..13]), n(text[14..16]), n(text[17..19]), ms, 0);
}

test "civil conversion round-trips and normalizes" {
    try testing.expectEqual(@as(i64, 0), chart.fromCivil(1970, 1, 1, 0, 0, 0, 0, 0));
    const c = chart.toCivil(parseUtc("2026-03-05T09:13:07.250Z"), 0);
    try testing.expectEqual(@as(i64, 2026), c.year);
    try testing.expectEqual(@as(u8, 3), c.month);
    try testing.expectEqual(@as(u8, 5), c.day);
    try testing.expectEqual(@as(u8, 4), c.weekday);
    try testing.expectEqual(@as(u16, 64), c.year_day);
    try testing.expectEqual(@as(u16, 250), c.millisecond);
    // Day 0 is the last day of the previous month, month 13 next January.
    try testing.expectEqual(parseUtc("2024-02-29T00:00:00Z"), chart.fromCivil(2024, 3, 0, 0, 0, 0, 0, 0));
    try testing.expectEqual(parseUtc("2027-01-01T00:00:00Z"), chart.fromCivil(2026, 13, 1, 0, 0, 0, 0, 0));
    const before = chart.toCivil(-1, 0);
    try testing.expectEqual(@as(i64, 1969), before.year);
    try testing.expectEqual(@as(u8, 23), before.hour);
}

test "time ticks fall on round calendar times" {
    const cases = [_]struct { from: []const u8, to: []const u8, count: usize, want: []const []const u8, labels: []const u8 }{
        .{ .from = "2026-01-01T00:00:00Z", .to = "2026-12-31T00:00:00Z", .count = 6, .want = &.{ "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z", "2026-07-01T00:00:00Z", "2026-10-01T00:00:00Z" }, .labels = "2026 Apr Jul Oct" },
        .{ .from = "2026-03-01T00:00:00Z", .to = "2026-03-08T00:00:00Z", .count = 7, .want = &.{ "2026-03-01T00:00:00Z", "2026-03-02T00:00:00Z", "2026-03-03T00:00:00Z", "2026-03-04T00:00:00Z", "2026-03-05T00:00:00Z", "2026-03-06T00:00:00Z", "2026-03-07T00:00:00Z", "2026-03-08T00:00:00Z" }, .labels = "Mar Mar 2 Mar 3 Mar 4 Mar 5 Mar 6 Mar 7 Mar 8" },
        .{ .from = "2026-03-05T09:13:00Z", .to = "2026-03-05T17:40:00Z", .count = 5, .want = &.{ "2026-03-05T10:00:00Z", "2026-03-05T11:00:00Z", "2026-03-05T12:00:00Z", "2026-03-05T13:00:00Z", "2026-03-05T14:00:00Z", "2026-03-05T15:00:00Z", "2026-03-05T16:00:00Z", "2026-03-05T17:00:00Z" }, .labels = "10:00 11:00 12:00 13:00 14:00 15:00 16:00 17:00" },
        .{ .from = "2026-03-05T09:13:07Z", .to = "2026-03-05T09:14:51Z", .count = 6, .want = &.{ "2026-03-05T09:13:15Z", "2026-03-05T09:13:30Z", "2026-03-05T09:13:45Z", "2026-03-05T09:14:00Z", "2026-03-05T09:14:15Z", "2026-03-05T09:14:30Z", "2026-03-05T09:14:45Z" }, .labels = ":15 :30 :45 09:14 :15 :30 :45" },
        .{ .from = "2010-06-01T00:00:00Z", .to = "2026-06-01T00:00:00Z", .count = 5, .want = &.{ "2015-01-01T00:00:00Z", "2020-01-01T00:00:00Z", "2025-01-01T00:00:00Z" }, .labels = "2015 2020 2025" },
        .{ .from = "2026-01-29T00:00:00Z", .to = "2026-02-12T00:00:00Z", .count = 8, .want = &.{ "2026-01-29T00:00:00Z", "2026-01-31T00:00:00Z", "2026-02-01T00:00:00Z", "2026-02-03T00:00:00Z", "2026-02-05T00:00:00Z", "2026-02-07T00:00:00Z", "2026-02-09T00:00:00Z", "2026-02-11T00:00:00Z" }, .labels = "Jan 29 Jan 31 Feb Feb 3 Feb 5 Feb 7 Feb 9 Feb 11" },
        .{ .from = "2026-03-01T00:00:00Z", .to = "2026-03-29T00:00:00Z", .count = 4, .want = &.{ "2026-03-01T00:00:00Z", "2026-03-08T00:00:00Z", "2026-03-15T00:00:00Z", "2026-03-22T00:00:00Z", "2026-03-29T00:00:00Z" }, .labels = "Mar Mar 8 Mar 15 Mar 22 Mar 29" },
        .{ .from = "2026-01-01T00:00:00.120Z", .to = "2026-01-01T00:00:00.870Z", .count = 5, .want = &.{ "2026-01-01T00:00:00.200Z", "2026-01-01T00:00:00.400Z", "2026-01-01T00:00:00.600Z", "2026-01-01T00:00:00.800Z" }, .labels = ".200 .400 .600 .800" },
    };
    var ticks: [64]chart.Tick = undefined;
    var text: [512]u8 = undefined;
    for (cases) |case| {
        const s = chart.Time.init(parseUtc(case.from), parseUtc(case.to));
        const got = try s.ticks(case.count, &ticks);
        try testing.expectEqual(case.want.len, got.len);
        for (case.want, got) |want, tick| try testing.expectEqual(@as(f64, @floatFromInt(parseUtc(want))), tick.value);
        try testing.expectEqualStrings(case.labels, joinLabels(got, &text));
    }
    // Ticks fall on round times of the times' offset.
    const tokyo = 9 * 60;
    const s: chart.Time = .{ .from = chart.fromCivil(2026, 3, 1, 0, 0, 0, 0, tokyo), .to = chart.fromCivil(2026, 3, 4, 0, 0, 0, 0, tokyo), .offset = tokyo };
    const got = try s.ticks(3, &ticks);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("Mar 2", got[1].label());
    // A reversed domain lists its ticks from `from`.
    const reversed = chart.Time.init(parseUtc("2026-03-08T00:00:00Z"), parseUtc("2026-03-01T00:00:00Z"));
    const back = try reversed.ticks(7, &ticks);
    try testing.expectEqualStrings("Mar 8", back[0].label());
    try testing.expectApproxEqAbs(@as(f32, 0), back[0].at, 1e-6);
    try testing.expectEqual(@as(f32, 0.5), chart.Time.init(5, 5).at(5));
    try testing.expectEqual(@as(i64, 7), chart.Time.init(0, 10).invert(0.7));
}

fn expectStack(got: []const []const chart.Segment, want: []const []const [2]f64) !void {
    for (want, 0..) |series, s| for (series, 0..) |w, i| {
        try testing.expectApproxEqAbs(w[0], got[s][i].lo, 1e-9);
        try testing.expectApproxEqAbs(w[1], got[s][i].hi, 1e-9);
    };
}

test "stacks pile standard, normalized and centered" {
    var storage: [3][3]chart.Segment = undefined;
    const out = [_][]chart.Segment{ &storage[0], &storage[1], &storage[2] };
    _ = try chart.stack(&.{ &.{ 3, -1, 2 }, &.{ 4, 2, -5 }, &.{ 1, 1, 1 } }, .standard, &out);
    try expectStack(&out, &.{ &.{ .{ 0, 3 }, .{ -1, 0 }, .{ 0, 2 } }, &.{ .{ 3, 7 }, .{ 0, 2 }, .{ -5, 0 } }, &.{ .{ 7, 8 }, .{ 2, 3 }, .{ 2, 3 } } });
    const positive: []const []const f64 = &.{ &.{ 3, 1, 2 }, &.{ 4, 2, 5 }, &.{ 1, 1, 1 } };
    _ = try chart.stack(positive, .normalized, &out);
    try expectStack(&out, &.{ &.{ .{ 0, 0.375 }, .{ 0, 0.25 }, .{ 0, 0.25 } }, &.{ .{ 0.375, 0.875 }, .{ 0.25, 0.75 }, .{ 0.25, 0.875 } }, &.{ .{ 0.875, 1 }, .{ 0.75, 1 }, .{ 0.875, 1 } } });
    _ = try chart.stack(positive, .center, &out);
    try expectStack(&out, &.{ &.{ .{ -4, -1 }, .{ -2, -1 }, .{ -4, -2 } }, &.{ .{ -1, 3 }, .{ -1, 1 }, .{ -2, 3 } }, &.{ .{ 3, 4 }, .{ 1, 2 }, .{ 3, 4 } } });
    // Shorter series and NaN take no room.
    const n = try chart.stack(&.{ &.{ 1, std.math.nan(f64) }, &.{2} }, .standard, out[0..2]);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(chart.Segment{ .lo = 0, .hi = 0 }, out[0][1]);
    try testing.expectEqual(chart.Segment{ .lo = 0, .hi = 0 }, out[1][1]);
    try testing.expectEqual(chart.Segment{ .lo = 1, .hi = 3 }, out[1][0]);
    var short: [1]chart.Segment = undefined;
    try testing.expectError(error.OutputTooSmall, chart.stack(&.{&.{ 1, 2 }}, .standard, &.{&short}));
}

test "pies divide the circle and find the slice under a point" {
    const want = [_][2]f64{ .{ 0, 0.6383185307179586 }, .{ 0.6383185307179586, 1.8949555921538759 }, .{ 1.8949555921538759, 3.7699111843077517 }, .{ 3.7699111843077517, 3.7899111843077518 }, .{ 3.7899111843077518, 6.283185307179586 } };
    var storage: [5]chart.Slice = undefined;
    const got = try chart.pie(&.{ 1, 2, 3, 0, 4 }, 0.02, &storage);
    for (want, got) |w, s| {
        try testing.expectApproxEqAbs(w[0], s.start, 1e-9);
        try testing.expectApproxEqAbs(w[1], s.end, 1e-9);
    }
    const quarters = try chart.pie(&.{ 1, 1, 1, 1 }, 0, &storage);
    // Twelve o'clock, three, six and nine.
    for ([_]chart.Point{ .{ .x = 1, .y = -10 }, .{ .x = 10, .y = 1 }, .{ .x = -1, .y = 10 }, .{ .x = -10, .y = -1 } }, 0..) |p, i| try testing.expectEqual(@as(?usize, i), chart.sliceAt(quarters, p, 5, 20));
    try testing.expectEqual(@as(?usize, null), chart.sliceAt(quarters, .{ .x = 1, .y = 1 }, 5, 20));
    const p = chart.polar(.{}, 10, std.math.pi / 2.0);
    try testing.expectApproxEqAbs(@as(f32, 10), p.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), p.y, 1e-5);
}

test "nearest finds the point under the pointer" {
    const xs = [_]f32{ 0, 0.25, 0.5, 1 };
    const cases = [_][2]f32{ .{ -1, 0 }, .{ 0.1, 0 }, .{ 0.125, 0 }, .{ 0.2, 1 }, .{ 0.4, 2 }, .{ 0.8, 3 }, .{ 2, 3 } };
    for (cases) |case| try testing.expectEqual(@as(?usize, @intFromFloat(case[1])), chart.nearest(&xs, case[0]));
    try testing.expectEqual(@as(?usize, null), chart.nearest(&.{}, 0.5));
}

test "curves join points straight, monotone or in steps" {
    const pts = [_]chart.Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 10 }, .{ .x = 30, .y = 0 } };
    var segs: [9]chart.CurveSegment = undefined;
    // Monotone never goes past the values of the points it joins: at the
    // flat stretch, the control points stay at its height.
    var n = try chart.curve(&pts, .monotone, &segs);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(segs[1].cubic and segs[1].c1.y == 10 and segs[1].c2.y == 10);
    n = try chart.curve(&pts, .step_after, &segs);
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqual(chart.Point{ .x = 10, .y = 0 }, segs[0].to);
    _ = try chart.curve(&pts, .step_before, &segs);
    try testing.expectEqual(chart.Point{ .x = 0, .y = 10 }, segs[0].to);
    n = try chart.curve(&pts, .step, &segs);
    try testing.expectEqual(@as(usize, 9), n);
    try testing.expectEqual(chart.Point{ .x = 5, .y = 0 }, segs[0].to);
    try testing.expectEqual(chart.Point{ .x = 5, .y = 10 }, segs[1].to);
    n = try chart.curve(pts[0..2], .monotone, &segs);
    try testing.expect(n == 1 and !segs[0].cubic);
    try testing.expectError(error.OutputTooSmall, chart.curve(&pts, .step, segs[0..3]));
}

test "lines break at NaN and areas close back along their base" {
    var storage: [32]chart.Command = undefined;
    var path = chart.Path.init(&storage);
    const r: chart.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try chart.line(&path, r, &.{ 0, 0.25, 0.5, 0.75 }, &.{ 0, 1, std.math.nan(f32), 1 }, .linear);
    try testing.expectEqual(@as(usize, 3), path.len);
    try testing.expect(path.items()[0] == .move and path.items()[1] == .line and path.items()[2] == .move);
    try testing.expectEqual(chart.Point{ .x = 25, .y = 0 }, path.items()[1].line);
    try chart.area(&path, r, &.{ 0, 0.5, 1 }, null, &.{ 0.5, 0.75, 1 }, .linear);
    const items = path.items();
    try testing.expectEqual(chart.Point{ .x = 0, .y = 50 }, items[0].move);
    try testing.expectEqual(chart.Point{ .x = 100, .y = 0 }, items[2].line);
    try testing.expectEqual(chart.Point{ .x = 100, .y = 100 }, items[3].line);
    try testing.expectEqual(chart.Point{ .x = 0, .y = 100 }, items[5].line);
    try testing.expect(items[items.len - 1] == .close);
    // A monotone area returns along the reversed bottom cubic.
    try chart.area(&path, r, &.{ 0, 0.5, 1 }, &.{ 0, 0.1, 0 }, &.{ 0.5, 0.9, 0.5 }, .monotone);
    var cubics: usize = 0;
    for (path.items()) |command| if (command == .cubic) {
        cubics += 1;
    };
    try testing.expectEqual(@as(usize, 4), cubics);
    var tiny: [2]chart.Command = undefined;
    var full = chart.Path.init(&tiny);
    try testing.expectError(error.PathFull, chart.line(&full, r, &.{ 0, 0.5, 1 }, &.{ 0, 1, 0 }, .linear));
}

test "sectors of donuts start at twelve o'clock and keep their pad" {
    var storage: [32]chart.Command = undefined;
    var path = chart.Path.init(&storage);
    try chart.sector(&path, .{ .x = 50, .y = 50 }, 20, 40, .{ .start = 0, .end = std.math.pi });
    const items = path.items();
    try testing.expectApproxEqAbs(@as(f32, 50), items[0].move.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), items[0].move.y, 1e-4);
    // Two quarter turns outside, a line in, two quarter turns back, close.
    try testing.expectEqual(@as(usize, 7), items.len);
    try testing.expectApproxEqAbs(@as(f32, 70), items[3].line.y, 1e-4);
    try chart.sector(&path, .{}, 0, 10, .{ .start = 0, .end = 1, .pad = 0.1 });
    try testing.expect(path.items()[0].move.x > 0);
    try chart.sector(&path, .{}, 0, 10, .{ .start = 1, .end = 1 });
    try testing.expectEqual(@as(usize, 0), path.len);
}

test "min-max reduction keeps extremes, edges and breaks" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const cases = [_]struct { xs: []const f32, ys: []const f32, width: usize, indices: []const i32 }{
        .{ .xs = &.{ 0, 0.01, 0.02, 0.03, 0.04, 0.05, 0.06 }, .ys = &.{ 3, 8, 2, 9, 0, 4, 5 }, .width = 1, .indices = &.{ 0, 3, 4, 6 } },
        .{ .xs = &.{ 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9 }, .ys = &.{ 2, 0, 4, 3, 2, 2, 0, 4, 3, 2 }, .width = 2, .indices = &.{ 0, 1, 2, 6, 7, 9 } },
        .{ .xs = &.{ 0, 0.3, 0.6, 1 }, .ys = &.{ 1, 2, 3, 4 }, .width = 100, .indices = &.{ 0, 1, 2, 3 } },
        .{ .xs = &.{ 0.5, 0.5, 0.5, 0.5, 0.5 }, .ys = &.{ 2, 0, 3, 1, 2 }, .width = 10, .indices = &.{ 0, 1, 2, 4 } },
        .{ .xs = &.{ -2, -1, 0, 0.5, 1, 2, 3 }, .ys = &.{ 0, 1, 2, 3, 4, 5, 6 }, .width = 10, .indices = &.{ 1, 2, 3, 4, 5 } },
        .{ .xs = &.{ -2, -1, 2, 3 }, .ys = &.{ 0, 1, 2, 3 }, .width = 10, .indices = &.{ 1, 2 } },
        .{ .xs = &.{ -2, -1 }, .ys = &.{ 0, 1 }, .width = 10, .indices = &.{} },
        .{ .xs = &.{ 2, 3 }, .ys = &.{ 0, 1 }, .width = 10, .indices = &.{} },
        .{ .xs = &.{}, .ys = &.{}, .width = 10, .indices = &.{} },
        .{ .xs = &.{0}, .ys = &.{0}, .width = 0, .indices = &.{} },
        .{ .xs = &.{ 0, 0.5, 1 }, .ys = &.{ 1, 2 }, .width = 10, .indices = &.{ 0, 1 } },
        .{ .xs = &.{ 0, 0.01, 0.02, 0.03 }, .ys = &.{ 1, 1, 1, 1 }, .width = 1, .indices = &.{ 0, 3 } },
        .{ .xs = &.{ 0, 0.1, 0.2, 0.3, 0.4 }, .ys = &.{ 1, 2, nan, 3, 4 }, .width = 1, .indices = &.{ 0, 1, -1, 3, 4 } },
        .{ .xs = &.{ 0, 0.1, 0.2 }, .ys = &.{ 1, inf, 2 }, .width = 1, .indices = &.{ 0, -1, 2 } },
    };
    var dx: [32]f32 = undefined;
    var dy: [32]f32 = undefined;
    for (cases) |case| {
        const got = try chart.minMax(&dx, &dy, case.xs, case.ys, case.width);
        try testing.expectEqual(case.indices.len, got.xs.len);
        for (case.indices, 0..) |i, j| {
            if (i < 0) {
                try testing.expect(std.math.isNan(got.xs[j]) and std.math.isNan(got.ys[j]));
                continue;
            }
            try testing.expectEqual(case.xs[@intCast(i)], got.xs[j]);
            try testing.expectEqual(case.ys[@intCast(i)], got.ys[j]);
        }
    }
    try testing.expectError(error.OutputTooSmall, chart.minMax(dx[0..1], dy[0..1], &.{ 0, 0.5, 1 }, &.{ 0, 1, 2 }, 100));
}

test "min-max density follows the pixel width" {
    var xs: [15000]f32 = undefined;
    var ys: [15000]f32 = undefined;
    for (&xs, &ys, 0..) |*px, *py, i| {
        px.* = @as(f32, @floatFromInt(i)) / 14999;
        py.* = @floatCast(@sin(@as(f64, @floatFromInt(i))));
    }
    var dx: [15000]f32 = undefined;
    var dy: [15000]f32 = undefined;
    const coarse = (try chart.minMax(&dx, &dy, &xs, &ys, 1280)).xs.len;
    const fine = (try chart.minMax(&dx, &dy, &xs, &ys, 2560)).xs.len;
    try testing.expect(fine > coarse and fine <= 2 * 2560 + 3);
}

fn fixedMeasure(_: ?*anyopaque, text: []const u8) chart.Size {
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 8, .height = 16 };
}

test "plots give the axes the room their labels need" {
    const labels = [_][]const u8{ "Mon", "Tue", "Wed", "Thu" };
    const xb = chart.Band.init(&labels).padding(0.2, 0);
    const ys = chart.Linear.init(0, 100);
    var left_storage: [8]chart.Tick = undefined;
    var bottom_storage: [4]chart.Tick = undefined;
    const axes: chart.Axes = .{ .left = try ys.ticks(2, &left_storage), .bottom = try xb.ticks(&bottom_storage) };
    const measure: chart.Measure = .{ .call = fixedMeasure };
    const l = chart.layout(.{ .x = 20, .y = 20, .width = 400, .height = 200 }, axes, 6, measure);
    // "100" is 24 wide, and the gap keeps the labels away from the area.
    try testing.expectEqual(@as(f32, 20 + 24 + 6), l.area.x);
    try testing.expectEqual(@as(f32, 20), l.area.y);
    try testing.expectEqual(@as(f32, 200 - 16 - 6), l.area.height);
    const top_label = l.label(.left, axes.left[2], fixedMeasure(null, axes.left[2].label()), 6).?;
    try testing.expectEqual(@as(f32, 20), top_label.x);
    try testing.expectEqual(l.area.y, top_label.y + top_label.height / 2);
    const mon = l.label(.bottom, axes.bottom[0], fixedMeasure(null, "Mon"), 6).?;
    try testing.expectApproxEqAbs(chart.x(l.area, xb.band(0).mid()), mon.x + mon.width / 2, 1e-4);
    try testing.expectEqual(l.area.y + l.area.height + 6, mon.y);
    try testing.expectEqual(@as(?chart.Rect, null), l.label(.bottom, chart.Tick.init(1.5, 0, "x"), .{}, 6));

    const bar = chart.rect(l.area, xb.band(1), ys.span(0, 50));
    try testing.expectApproxEqAbs(l.area.y + l.area.height / 2, bar.y, 1e-4);
    try testing.expectApproxEqAbs(l.area.height / 2, bar.height, 1e-4);
    const dot = chart.point(l.area, 0.5, 0.5, 10, 10);
    try testing.expectEqual(l.area.x + l.area.width / 2, dot.x + 5);
    const rule = chart.ruleY(l.area, 1, 2);
    try testing.expectEqual(l.area.y - 1, rule.y);
    try testing.expectEqual(l.area.width, rule.width);
    const corner = chart.anchor(l.area, 1, 0, .end, .end, .{ .width = 30, .height = 10 });
    try testing.expectEqual(l.area.x + l.area.width, corner.x + corner.width);
    try testing.expectEqual(l.area.y + l.area.height, corner.y + corner.height);
}

test "legends wrap their entries in rows" {
    const items = [_]chart.LegendItem{ .{ .label = "Search", .color = 0xff0000 }, .{ .label = "Direct", .color = 0x00ff00 }, .{ .label = "Referral", .color = 0x0000ff } };
    var slots: [3]chart.LegendSlot = undefined;
    const size = try chart.legend(.{ .x = 10, .y = 5, .width = 150, .height = 100 }, &items, .{}, .{ .call = fixedMeasure }, &slots);
    // Each entry is 10 + 6 + 48 wide; two fit with the 16 gap, the third wraps.
    try testing.expectEqual(@as(f32, 10), slots[0].swatch.x);
    try testing.expectEqual(@as(f32, 10 + 64 + 16), slots[1].swatch.x);
    try testing.expectEqual(@as(f32, 10), slots[2].swatch.x);
    try testing.expectEqual(@as(f32, 5 + 16 + 4), slots[2].label.y);
    try testing.expectEqual(@as(f32, 16 + 4 + 16), size.height);
    try testing.expectEqual(@as(f32, 5 + 3), slots[0].swatch.y);
}

test "selections follow the pointer and the keys" {
    const xs = [_]f32{ 0.1, 0.5, 0.9 };
    var s: chart.Selection = .{};
    var changes: usize = 0;
    if (s.pointer(0.475, &xs).changed) changes += 1;
    try testing.expectEqual(@as(?usize, 1), s.index);
    if (s.pointer(0.95, &xs).changed) changes += 1;
    try testing.expectEqual(@as(?usize, 2), s.index);
    if (s.pointer(null, &xs).changed) changes += 1;
    try testing.expectEqual(@as(?usize, null), s.index);
    try testing.expectEqual(@as(usize, 3), changes);
    var announced: [8]usize = undefined;
    var count: usize = 0;
    for ([_]chart.Key{ .right, .right, .end, .right, .home }) |k| {
        const change = s.key(k, xs.len);
        if (change.announce) {
            announced[count] = s.index.?;
            count += 1;
        }
    }
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 0 }, announced[0..count]);
    try testing.expect(s.key(.escape, xs.len).changed);
    try testing.expectEqual(@as(?usize, null), s.index);
    _ = s.key(.left, xs.len);
    try testing.expectEqual(@as(?usize, 2), s.index);
    // A choice past the points left is dropped.
    try testing.expect(s.key(.home, 2).changed == true);
    s.index = 5;
    try testing.expect(s.key(.escape, 3).changed == false);
    // The pointer resting in place leaves the keyboard's choice alone.
    _ = s.pointer(0.1, &xs);
    _ = s.key(.end, xs.len);
    _ = s.pointer(0.1, &xs);
    try testing.expectEqual(@as(?usize, 2), s.index);
}

test "a zoom keeps the point it zooms around in place and stays within the plot" {
    var zoom: chart.Zoom = .{};
    try testing.expect(zoom.whole());
    // Zooming in by 2 around a quarter of the way keeps that point there.
    try testing.expect(zoom.zoomAt(.x, 2, .{ .x = 0.25, .y = 0.5 }, 0.01));
    try testing.expectApproxEqAbs(@as(f32, 0.125), zoom.x.lo, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.625), zoom.x.hi, 1e-6);
    try testing.expectEqual(chart.Span{ .lo = 0, .hi = 1 }, zoom.y);
    try testing.expectApproxEqAbs(@as(f32, 0.25), zoom.shownX(0.25), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), zoom.wholeX(zoom.shownX(0.25)), 1e-6);
    // Panning holds the span within the whole plot.
    try testing.expect(zoom.pan(.xy, 10, 0));
    try testing.expectApproxEqAbs(@as(f32, 1), zoom.x.hi, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), zoom.x.lo, 1e-6);
    try testing.expect(!zoom.pan(.xy, 1, 0));
    // Zooming stops at the closest span, and zooming out at the whole plot.
    _ = zoom.zoomAt(.xy, 1000, .{ .x = 0.5, .y = 0.5 }, 0.05);
    try testing.expectApproxEqAbs(@as(f32, 0.05), zoom.x.hi - zoom.x.lo, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.05), zoom.y.hi - zoom.y.lo, 1e-6);
    _ = zoom.zoomAt(.xy, 0.0001, .{ .x = 0.5, .y = 0.5 }, 0.05);
    try testing.expect(zoom.whole());
    try testing.expect(!zoom.zoomAt(.xy, std.math.nan(f32), .{}, 0.05));
    // A brush in what shows selects that part of it.
    _ = zoom.zoomAt(.x, 2, .{ .x = 0, .y = 0 }, 0.01);
    try testing.expect(zoom.select(.x, .{ .lo = 0.8, .hi = 0.2 }, .{ .lo = 0, .hi = 0.5 }, 0.01));
    try testing.expectApproxEqAbs(@as(f32, 0.1), zoom.x.lo, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), zoom.x.hi, 1e-6);
    try testing.expectEqual(chart.Span{ .lo = 0, .hi = 1 }, zoom.y);
    // A box shows the whole plot's box placed for the zoom.
    const placed = zoom.place(.{ .x = 10, .y = 20, .width = 300, .height = 100 });
    try testing.expectApproxEqAbs(@as(f32, 1000), placed.width, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 10 - 100), placed.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 10), chart.x(placed, 0.1), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 120), chart.y(placed, 0), 1e-3);
    try testing.expect(zoom.reset());
    try testing.expect(!zoom.reset());
    // A selection narrower than the closest span widens around its middle.
    try testing.expect(zoom.select(.x, .{ .lo = 0.999, .hi = 1 }, .{ .lo = 0, .hi = 1 }, 0.1));
    try testing.expectApproxEqAbs(@as(f32, 0.9), zoom.x.lo, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), zoom.x.hi, 1e-6);
}

test "ticks picked for what a zoom shows move to fractions of the whole plot" {
    const whole = chart.Linear.init(0, 100);
    const shown: chart.Span = .{ .lo = 0.2, .hi = 0.4 };
    const part = chart.Linear.init(whole.invert(shown.lo), whole.invert(shown.hi));
    var storage: [16]chart.Tick = undefined;
    const ticks = try part.ticks(4, &storage);
    chart.rebase(ticks, shown);
    try testing.expect(ticks.len >= 3);
    for (ticks) |tick| {
        try testing.expectApproxEqAbs(whole.at(tick.value), tick.at, 1e-5);
        try testing.expect(tick.value >= 19.99 and tick.value <= 40.01);
    }
}
