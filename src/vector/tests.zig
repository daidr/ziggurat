const std = @import("std");
const api = @import("root.zig");
const allocator = std.testing.allocator;
const intervals = @import("intervals.zig");
const square = [_]api.Command{
    .{ .move = .{ .x = 2, .y = 2 } },   .{ .line = .{ .x = 10, .y = 2 } },
    .{ .line = .{ .x = 10, .y = 10 } }, .{ .line = .{ .x = 2, .y = 10 } },
    .close,
};
fn options() api.PrepareOptions {
    return .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 16, .height = 16 } };
}

fn compareStroke(data: []const u8, expected_data: []const u8, stroke: api.Stroke, transform: api.Transform) !void {
    const source = try api.Path.parseData(allocator, data, .{});
    defer source.close() catch unreachable;
    const expected = try api.Path.parseData(allocator, expected_data, .{});
    defer expected.close() catch unreachable;
    var o = options();
    o.transform = transform;
    o.style = .{ .stroke = stroke };
    const actual_mask = try source.prepare(allocator, o);
    defer actual_mask.close() catch unreachable;
    var solid = stroke;
    solid.dashes = &.{};
    solid.trim = .{};
    o.style = .{ .stroke = solid };
    const expected_mask = try expected.prepare(allocator, o);
    defer expected_mask.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, (try expected_mask.view()).coverage.pixels, (try actual_mask.view()).coverage.pixels);
}

test "dash intervals repeat odd patterns preserve zero dots and normalize signed offset" {
    const cases = [_]struct { stroke: api.Stroke, expected: []const intervals.Range }{
        .{ .stroke = .{ .dashes = &.{ 3, 2 } }, .expected = &.{ .{ .start = 0, .end = 3 }, .{ .start = 5, .end = 8 }, .{ .start = 10, .end = 12 } } },
        .{ .stroke = .{ .dashes = &.{3} }, .expected = &.{ .{ .start = 0, .end = 3 }, .{ .start = 6, .end = 9 } } },
        .{ .stroke = .{ .dashes = &.{ 3, 2 }, .dash_offset = -1 }, .expected = &.{ .{ .start = 1, .end = 4 }, .{ .start = 6, .end = 9 }, .{ .start = 11, .end = 12 } } },
        .{ .stroke = .{ .dashes = &.{ 0, 4 } }, .expected = &.{ .{ .start = 0, .end = 0 }, .{ .start = 4, .end = 4 }, .{ .start = 8, .end = 8 } } },
        .{ .stroke = .{ .dashes = &.{ 0, 0, 0 } }, .expected = &.{.{ .start = 0, .end = 12 }} },
        .{ .stroke = .{ .dashes = &.{ 3, 2 }, .trim = .{ .start = 0.25, .end = 0.75 } }, .expected = &.{.{ .start = 5, .end = 8 }} },
        .{ .stroke = .{ .trim = .{ .start = 0.75, .end = 0.25 } }, .expected = &.{ .{ .start = 0, .end = 3 }, .{ .start = 9, .end = 12 } } },
    };
    for (cases) |case| {
        var work: intervals.Work = .{ .options = options() };
        var iterator = try intervals.Iterator.init(case.stroke, 12, &work);
        for (case.expected) |range| try std.testing.expectEqual(range, (try iterator.next(&work)).?);
        try std.testing.expectEqual(null, try iterator.next(&work));
    }
}

test "dashed and trimmed strokes agree with independently split paths" {
    for ([_]api.Cap{ .butt, .square, .round }) |cap| for ([_]api.Transform{ .{}, .{ .xx = -0.8, .xy = 0.2, .yy = 0.7, .x0 = 14 } }) |transform| {
        try compareStroke("M2 6H14", "M2 6H5 M7 6H10 M12 6H14", .{ .width = 2, .cap = cap, .dashes = &.{ 3, 2 } }, transform);
        try compareStroke("M2 6H14", "M7 6H10", .{ .width = 2, .cap = cap, .dashes = &.{ 3, 2 }, .trim = .{ .start = 0.25, .end = 0.75 } }, transform);
        try compareStroke("M2 6H14", "M2 6H5 M11 6H14", .{ .width = 2, .cap = cap, .trim = .{ .start = 0.75, .end = 0.25 } }, transform);
        try compareStroke("M2 6H14 M2 10H14", "M2 6H5 M7 6H10 M12 6H14 M2 10H5 M7 10H10 M12 10H14", .{ .width = 2, .cap = cap, .dashes = &.{ 3, 2 } }, transform);
        try compareStroke("M2 6H14", "M2 6L2 6 M6 6L6 6 M10 6L10 6", .{ .width = 2, .cap = cap, .dashes = &.{ 0, 4 } }, transform);
        try compareStroke("M2 6H14", "M2 6H14", .{ .width = 2, .cap = cap, .dashes = &.{ 0, 0 } }, transform);
    };
    for ([_]api.Join{ .miter, .round, .bevel }) |join| {
        // The wrap crosses the closed seam and needs a join there, with caps
        // only at the two cut endpoints.
        try compareStroke("M4 4H12V12H4Z", "M4 12V4H12", .{ .width = 3, .join = join, .cap = .square, .trim = .{ .start = 0.75, .end = 0.25 } }, .{});
        try compareStroke("M4 4H12V12H4Z", "M4 4H12V12H4Z", .{ .width = 3, .join = join, .dashes = &.{ 64, 1 } }, .{});
        try compareStroke("M2 6H6V12", "M2 6H6V10", .{ .width = 2, .join = join, .dashes = &.{ 8, 8 } }, .{});
    }
}

test "closed zero-length segments receive caps and cut work has an independent bound" {
    try compareStroke("M6 6Z", "M6 6L6 6", .{ .width = 4, .cap = .round }, .{});
    const path = try api.Path.parseData(allocator, "M2 6H14", .{});
    defer path.close() catch unreachable;
    var o = options();
    o.style = .{ .stroke = .{ .dashes = &.{ 1e-9, 1e-9 } } };
    o.transform = .{ .xx = 0, .yy = 0 };
    o.limits.stroke_steps = 128;
    try std.testing.expectError(error.StrokeBudgetExceeded, path.prepare(allocator, o));
    o.style.stroke.dashes = &.{-1};
    try std.testing.expectError(error.InvalidDash, path.prepare(allocator, o));
    o.style.stroke.dashes = &.{};
    o.style.stroke.trim = .{ .start = 0, .end = 2 };
    try std.testing.expectError(error.InvalidTrim, path.prepare(allocator, o));
    o.style.stroke.trim = .{ .start = 0.5, .end = 0.5 };
    const empty = try path.prepare(allocator, o);
    defer empty.close() catch unreachable;
    for ((try empty.view()).coverage.pixels) |value| try std.testing.expectEqual(0, value);
    o.style.stroke.trim = .{};
    o.style.stroke.dashes = &.{ 1e9, 1e-300 };
    try std.testing.expectError(error.UnsupportedStrokePrecision, path.prepare(allocator, o));
}

test "random dash phase and trim agree with an independent periodic sample oracle" {
    var random: std.Random.DefaultPrng = .init(0x8a7d6042);
    const rng = random.random();
    const path = try api.Path.parseData(allocator, "M2 5H14", .{});
    defer path.close() catch unreachable;
    for (0..80) |_| {
        var pattern: [5]f64 = undefined;
        const size = rng.intRangeAtMost(usize, 1, pattern.len);
        for (pattern[0..size]) |*value| value.* = @floatFromInt(rng.intRangeAtMost(u8, 0, 4));
        const offset: f64 = @floatFromInt(rng.intRangeAtMost(i8, -15, 15));
        const trim: api.Trim = if (rng.boolean()) .{ .start = 0.25, .end = 0.75 } else .{ .start = 0.75, .end = 0.25 };
        var o = options();
        o.style = .{ .stroke = .{ .width = 2, .dashes = pattern[0..size], .dash_offset = offset, .trim = trim } };
        const mask = try path.prepare(allocator, o);
        defer mask.close() catch unreachable;
        const view = (try mask.view()).coverage;
        const count = size * (if (size % 2 == 1) @as(usize, 2) else 1);
        var period: f64 = 0;
        for (0..count) |i| period += pattern[i % size];
        for (0..16) |y| for (0..16) |x| {
            var hits: u32 = 0;
            for (0..4) |sy| for (0..4) |sx| {
                const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4;
                const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4;
                if (px < 2 or px >= 14 or py < 4 or py >= 6) continue;
                const distance = px - 2;
                const fraction = distance / 12;
                const retained = if (trim.start < trim.end) fraction >= trim.start and fraction < trim.end else fraction < trim.end or fraction >= trim.start;
                if (!retained) continue;
                var painted = period == 0;
                if (period > 0) {
                    const phase = @mod(distance + offset, period);
                    var prefix: f64 = 0;
                    for (0..count) |i| {
                        const next = prefix + pattern[i % size];
                        if (phase >= prefix and phase < next) painted = i % 2 == 0;
                        prefix = next;
                    }
                }
                if (painted) hits += 1;
            };
            try std.testing.expectEqual(@as(u8, @intCast((hits * 255 + 8) / 16)), view.pixels[y * view.stride + x]);
        };
    }
    const curve = try api.Path.parseData(allocator, "M2 2Q14 14 2 14", .{});
    defer curve.close() catch unreachable;
    var o = options();
    o.style = .{ .stroke = .{ .width = 1, .dashes = &.{ 1, 1 } } };
    o.transform = .{ .xx = 0, .yy = 0 };
    const flat = try curve.prepare(allocator, o);
    defer flat.close() catch unreachable;
    try std.testing.expect((try flat.stats()).vertices > 8);
}

test "path owns commands and prepared mask owns coverage independent of source" {
    var input = square;
    const path = try api.Path.create(allocator, &input, .{});
    input[1] = .{ .line = .{} };
    const prepared = try path.prepare(allocator, options());
    defer prepared.close() catch unreachable;
    try path.close();
    const view = try prepared.view();
    try view.validate();
    for (0..16) |y| for (0..16) |x| try std.testing.expectEqual(@as(u8, if (x >= 2 and x < 10 and y >= 2 and y < 10) 255 else 0), view.coverage.pixels[y * 16 + x]);
    try view.lease.acquire();
    try std.testing.expectError(error.ResourceInUse, prepared.close());
    view.lease.release();
    const stats = try prepared.stats();
    try std.testing.expectEqual(2, stats.edges);
    try std.testing.expectEqual(128, stats.scan_tests);
    try std.testing.expect(stats.prepare_peak_bytes > stats.owned_bytes);
}

test "nonzero orientation and even odd holes including reflected affine paths" {
    var input: [10]api.Command = undefined;
    @memcpy(input[0..5], &square);
    input[5..].* = .{ .{ .move = .{ .x = 4, .y = 4 } }, .{ .line = .{ .x = 8, .y = 4 } }, .{ .line = .{ .x = 8, .y = 8 } }, .{ .line = .{ .x = 4, .y = 8 } }, .close };
    const path = try api.Path.create(allocator, &input, .{});
    defer path.close() catch unreachable;
    for ([_]api.FillRule{ .nonzero, .even_odd }) |rule| {
        var o = options();
        o.style = .{ .fill = rule };
        o.transform = .{ .xx = -1, .x0 = 12 };
        const prepared = try path.prepare(allocator, o);
        defer prepared.close() catch unreachable;
        const c = (try prepared.view()).coverage;
        try std.testing.expectEqual(@as(u8, if (rule == .nonzero) 255 else 0), c.pixels[6 * c.stride + 6]);
        try std.testing.expectEqual(255, c.pixels[3 * c.stride + 3]);
    }
    std.mem.swap(api.Command, &input[6], &input[8]);
    const reversed = try api.Path.create(allocator, &input, .{});
    defer reversed.close() catch unreachable;
    const prepared = try reversed.prepare(allocator, options());
    defer prepared.close() catch unreachable;
    try std.testing.expectEqual(0, (try prepared.view()).coverage.pixels[6 * 16 + 6]);
}

test "curve subdivision captures collinear reversal and degenerate chords" {
    const path = try api.Path.create(allocator, &.{ .{ .move = .{ .x = 3, .y = 3 } }, .{ .cubic = .{ .first = .{ .x = 18, .y = 3 }, .second = .{ .x = 18, .y = 3 }, .end = .{ .x = 3, .y = 3 } } } }, .{});
    defer path.close() catch unreachable;
    var o = options();
    o.style = .{ .stroke = .{ .width = 2, .cap = .round, .join = .round } };
    const prepared = try path.prepare(allocator, o);
    defer prepared.close() catch unreachable;
    const coverage = (try prepared.view()).coverage;
    try std.testing.expect(coverage.pixels[3 * 16 + 12] > 0);
    try std.testing.expect((try prepared.stats()).vertices > 2);
}

test "centered strokes use local widths under nonuniform transforms and explicit caps" {
    const path = try api.Path.create(allocator, &.{ .{ .move = .{ .x = 3, .y = 4 } }, .{ .line = .{ .x = 5, .y = 4 } } }, .{});
    defer path.close() catch unreachable;
    for ([_]api.Cap{ .butt, .square, .round }) |cap| {
        var o = options();
        o.style = .{ .stroke = .{ .width = 2, .cap = cap } };
        o.transform = .{ .xx = 2 };
        const prepared = try path.prepare(allocator, o);
        defer prepared.close() catch unreachable;
        const coverage = (try prepared.view()).coverage;
        try std.testing.expectEqual(255, coverage.pixels[4 * 16 + 7]);
        try std.testing.expectEqual(0, coverage.pixels[2 * 16 + 7]);
        if (cap == .butt) try std.testing.expectEqual(0, coverage.pixels[4 * 16 + 5]) else try std.testing.expect(coverage.pixels[4 * 16 + 5] > 0);
    }
}

test "fractional viewport and geometry use bounded 4x4 coverage" {
    const path = try api.Path.create(allocator, &.{ .{ .move = .{} }, .{ .line = .{ .x = 4 } }, .{ .line = .{ .x = 4, .y = 4 } }, .{ .line = .{ .y = 4 } }, .close }, .{});
    defer path.close() catch unreachable;
    var o = options();
    o.viewport = .{ .x = 0.25, .y = 0.25, .width = 2, .height = 2 };
    const prepared = try path.prepare(allocator, o);
    defer prepared.close() catch unreachable;
    const c = (try prepared.view()).coverage;
    try std.testing.expectEqual(4, c.stride);
    try std.testing.expectEqualSlices(u8, &.{ 143, 191, 48, 0, 191, 255, 64, 0, 48, 64, 16, 0 }, c.pixels);
}

test "all allocation failures and hard budgets leave source reusable" {
    const Run = struct {
        fn run(a: std.mem.Allocator) !void {
            const path = try api.Path.create(a, &square, .{});
            defer path.close() catch unreachable;
            const prepared = try path.prepare(a, options());
            defer prepared.close() catch unreachable;
            try (try prepared.view()).validate();
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Run.run, .{});
    const path = try api.Path.create(allocator, &square, .{});
    defer path.close() catch unreachable;
    var o = options();
    o.limits.bytes = 1;
    try std.testing.expectError(error.CapacityExceeded, path.prepare(allocator, o));
    o = options();
    o.limits.vertices = 2;
    try std.testing.expectError(error.VerticesFull, path.prepare(allocator, o));
    o = options();
    o.limits.scan_tests = 1;
    try std.testing.expectError(error.ScanBudgetExceeded, path.prepare(allocator, o));
    var cancel: api.Cancellation = .{};
    cancel.request();
    o = options();
    o.cancellation = &cancel;
    try std.testing.expectError(error.Cancelled, path.prepare(std.testing.failing_allocator, o));
    o = options();
    const prepared = try path.prepare(allocator, o);
    try prepared.close();
}

test "invalid path and transform fail before allocation" {
    try std.testing.expectError(error.MoveRequired, api.Path.create(std.testing.failing_allocator, &.{.{ .line = .{} }}, .{}));
    try std.testing.expectError(error.InvalidGeometry, api.Path.create(std.testing.failing_allocator, &.{.{ .move = .{ .x = std.math.nan(f64) } }}, .{}));
    const path = try api.Path.create(allocator, &square, .{});
    defer path.close() catch unreachable;
    var o = options();
    o.transform.xx = std.math.inf(f64);
    try std.testing.expectError(error.InvalidTransform, path.prepare(std.testing.failing_allocator, o));
}

test "scan conversion agrees with angle winding oracle on transformed compound polygons" {
    var random: std.Random.DefaultPrng = .init(0x1aa2f3a8);
    const rng = random.random();
    for (0..64) |iteration| {
        var commands: [18]api.Command = undefined;
        var polygons: [2][8]api.Point = undefined;
        for (&polygons, 0..) |*polygon, contour| {
            for (polygon) |*p| p.* = .{ .x = rng.float(f64) * 16, .y = rng.float(f64) * 16 };
            for (polygon, 0..) |point, i| commands[contour * 9 + i] = if (i == 0) .{ .move = point } else .{ .line = point };
            commands[contour * 9 + 8] = .close;
        }
        const path = try api.Path.create(allocator, &commands, .{});
        defer path.close() catch unreachable;
        var o = options();
        o.style = .{ .fill = if (iteration % 2 == 0) .nonzero else .even_odd };
        o.transform = .{ .xx = 0.7, .xy = 0.2, .yx = -0.1, .yy = 0.8, .x0 = 1, .y0 = 2 };
        const prepared = try path.prepare(allocator, o);
        defer prepared.close() catch unreachable;
        const coverage = (try prepared.view()).coverage;
        for (0..16) |y| for (0..16) |x| {
            var count: u16 = 0;
            for (0..4) |sy| for (0..4) |sx| {
                const sample: api.Point = .{ .x = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4, .y = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4 };
                var winding: i32 = 0;
                for (polygons) |polygon| {
                    var angle: f64 = 0;
                    for (polygon, 0..) |point, i| {
                        const p = o.transform.apply(point);
                        const q = o.transform.apply(polygon[(i + 1) % polygon.len]);
                        const a: api.Point = .{ .x = p.x - sample.x, .y = p.y - sample.y };
                        const b: api.Point = .{ .x = q.x - sample.x, .y = q.y - sample.y };
                        angle += std.math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y);
                    }
                    winding += @intFromFloat(@round(angle / (2 * std.math.pi)));
                }
                if (if (o.style.fill == .even_odd) @mod(winding, 2) != 0 else winding != 0) count += 1;
            };
            try std.testing.expectEqual(@as(u8, @intCast((count * 255 + 8) / 16)), coverage.pixels[y * coverage.stride + x]);
        };
    }
}

test "owner checks and explicit worker handoff preserve exclusive resource ownership" {
    const main_thread = std.Thread.getCurrentId();
    const path = try api.Path.create(allocator, &square, .{});
    defer path.close() catch unreachable;
    const Handoff = struct {
        path: *api.Path,
        main_thread: std.Thread.Id,
        prepared: ?*api.Prepared = null,
        failure: ?anyerror = null,
        fn worker(self: *@This()) void {
            self.run() catch |err| {
                self.failure = err;
            };
        }
        fn run(self: *@This()) !void {
            try std.testing.expectError(error.WrongThread, self.path.prepare(std.testing.failing_allocator, options()));
            try std.testing.expectError(error.WrongThread, self.path.close());
            const owned = try api.Path.create(allocator, &square, .{});
            defer owned.close() catch unreachable;
            var o = options();
            o.main_thread = self.main_thread;
            const prepared = try owned.prepare(allocator, o);
            errdefer prepared.close() catch unreachable;
            try std.testing.expectError(error.NotAdopted, prepared.view());
            try std.testing.expectError(error.WrongThread, prepared.adopt());
            self.prepared = prepared;
        }
    };
    var handoff: Handoff = .{ .path = path, .main_thread = main_thread };
    const worker = try std.Thread.spawn(.{}, Handoff.worker, .{&handoff});
    worker.join();
    if (handoff.failure) |err| return err;
    const prepared = handoff.prepared.?;
    try std.testing.expectError(error.WrongThread, prepared.view());
    try prepared.adopt();
    defer prepared.close() catch unreachable;
    try (try prepared.view()).validate();
    try std.testing.expectError(error.AlreadyAdopted, prepared.adopt());
}

test "SVG path data expands relative smooth and implicit commands with strict separators" {
    const path = try api.Path.parseData(allocator, "m1 2 3 4h2v-1q1 2 3 4t3 4c1 2 3 4 5 6s3 4 5 6z l1 2 M1e1.5 A2,3,45,0114,15", .{});
    defer path.close() catch unreachable;
    const commands = path.commands;
    try std.testing.expectEqual(13, commands.len);
    try std.testing.expectEqualDeep((api.Point{ .x = 4, .y = 6 }), commands[1].line);
    try std.testing.expectEqualDeep((api.Point{ .x = 6, .y = 5 }), commands[3].line);
    try std.testing.expectEqualDeep((api.Point{ .x = 11, .y = 11 }), commands[5].quadratic.control);
    try std.testing.expectEqualDeep((api.Point{ .x = 19, .y = 21 }), commands[7].cubic.first);
    try std.testing.expectEqualDeep((api.Point{ .x = 1, .y = 2 }), commands[9].move);
    try std.testing.expectEqualDeep((api.Point{ .x = 2, .y = 4 }), commands[10].line);
    try std.testing.expectEqual(10, commands[11].move.x);
    try std.testing.expectEqual(0.5, commands[11].move.y);
    try std.testing.expect(!commands[12].arc.large and commands[12].arc.sweep);
    try std.testing.expectEqualDeep((api.Point{ .x = 14, .y = 15 }), commands[12].arc.end);
    const bad = [_][]const u8{ "M,0 0", "M0,,0", "M0 0,", "M0 0L,1 2", "M0 0z1", "M0 0M", "M0e 0", "M0 0A1 2 0 2 0 2 2", "M0 0A1 2 0 0.0 2 2", "M0 0R1 2", "Mnan 0", "M0 0\x00", "M0\x0b0" };
    for (bad) |value| try std.testing.expectError(error.InvalidPathData, api.Path.parseData(std.testing.failing_allocator, value, .{}));
    try std.testing.expectError(error.MoveRequired, api.Path.parseData(std.testing.failing_allocator, "L0 0", .{}));
    try std.testing.expectError(error.CapacityExceeded, api.Path.parseData(std.testing.failing_allocator, "M0 0L1 1", .{ .limits = .{ .commands = 1 } }));
    try std.testing.expectError(error.UnsupportedNumberPrecision, api.Path.parseData(std.testing.failing_allocator, "M0 0A1e-999 1 0 0 0 1 1", .{}));
    const zero = try api.Path.parseData(allocator, "M-0e-999 0e999", .{});
    try zero.close();
}

test "elliptical arcs match analytic circle within explicit flattening tolerance" {
    const path = try api.Path.parseData(allocator, "M14 8 A6 6 0 0 1 8 14 A6 6 0 0 1 2 8 A6 6 0 0 1 8 2 A6 6 0 0 1 14 8 Z", .{});
    defer path.close() catch unreachable;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var o = options();
        o.scale = scale;
        o.transform = .{ .xx = -1, .x0 = 16 };
        const prepared = try path.prepare(allocator, o);
        defer prepared.close() catch unreachable;
        const coverage = (try prepared.view()).coverage;
        for (0..coverage.height) |y| for (0..coverage.width) |x| {
            var lower: u16 = 0;
            var upper: u16 = 0;
            for (0..4) |sy| for (0..4) |sx| {
                const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4 - 8 * scale;
                const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4 - 8 * scale;
                const distance = @sqrt(px * px + py * py);
                if (distance < 6 * scale - o.tolerance) lower += 1;
                if (distance < 6 * scale + o.tolerance) upper += 1;
            };
            const actual = coverage.pixels[y * coverage.stride + x];
            try std.testing.expect(actual >= (lower * 255 + 8) / 16 and actual <= (upper * 255 + 8) / 16);
        };
    }
    // A zero radius is a line, coincident endpoints omit the arc, and too-small
    // radii expand before the same ellipse sampling rather than becoming lines.
    const corrected = try api.Path.parseData(allocator, "M2 8A-1 -1 0 0 1 14 8A1 1 0 0 1 2 8Z M0 0A0 1 0 0 1 1 1A1 1 0 1 1 1 1", .{});
    defer corrected.close() catch unreachable;
    const prepared = try corrected.prepare(allocator, options());
    defer prepared.close() catch unreachable;
    try std.testing.expectEqual(255, (try prepared.view()).coverage.pixels[8 * 16 + 8]);
}

test "shared arc conversion rejects nonfinite tiny-lambda coefficients" {
    const arcs = @import("arc.zig");
    for ([_]api.Point{ .{ .x = 1e-160 }, .{ .y = -1e-160 }, .{ .x = 1e-160, .y = 1e-160 } }) |end| {
        for ([_]bool{ false, true }) |large| for ([_]bool{ false, true }) |sweep| {
            try std.testing.expectError(error.UnsupportedArcPrecision, arcs.resolve(.{}, .{ .radius = .{ .x = 1, .y = 1 }, .end = end, .large = large, .sweep = sweep }));
        };
    }
}

test "bounds and both flatten consumers propagate shared arc precision rejection" {
    const Run = struct {
        fn coverage(path: *const api.Path) !void {
            const prepared = try path.prepare(allocator, options());
            defer prepared.close() catch unreachable;
        }
        fn compiled(path: *const api.Path) !void {
            const geometry = try api.geometry.compile(path, allocator, .{});
            defer geometry.close() catch unreachable;
        }
    };
    for ([_][]const u8{ "M0 0A1 1 0 0 1 1e-160 0", "M0 0A1 1 0 1 0 0 -1e-160" }) |source| {
        const path = try api.Path.parseData(allocator, source, .{});
        defer path.close() catch unreachable;
        const bounds_result = path.bounds(.{}, null);
        const coverage_result = Run.coverage(path);
        const compiled_result = Run.compiled(path);
        std.debug.print("arc precision consumers: bounds={s} coverage={s} compiled={s}\n", .{
            if (bounds_result) |_| "success" else |err| @errorName(err),
            if (coverage_result) |_| "success" else |err| @errorName(err),
            if (compiled_result) |_| "success" else |err| @errorName(err),
        });
        try std.testing.expectError(error.UnsupportedArcPrecision, bounds_result);
        try std.testing.expectError(error.UnsupportedArcPrecision, coverage_result);
        try std.testing.expectError(error.UnsupportedArcPrecision, compiled_result);
    }
}

test "successful shared arc ellipse values stay finite across ordinary and extreme scales" {
    const arcs = @import("arc.zig");
    const cases = [_]struct { start: api.Point = .{}, value: api.Arc, allow_precision_rejection: bool = false }{
        .{ .start = .{ .x = 14, .y = 8 }, .value = .{ .radius = .{ .x = 6, .y = 6 }, .end = .{ .x = 8, .y = 14 } } },
        .{ .start = .{ .x = 2, .y = 8 }, .value = .{ .radius = .{ .x = -1, .y = -1 }, .end = .{ .x = 14, .y = 8 } } },
        .{ .start = .{ .x = -1e9 }, .value = .{ .radius = .{ .x = 1e9, .y = 1e9 }, .end = .{ .x = 1e9 } }, .allow_precision_rejection = true },
        .{ .value = .{ .radius = .{ .x = 1, .y = 1 }, .end = .{ .x = 1e-150 } } },
        .{ .value = .{ .radius = .{ .x = 1e-150, .y = 1e-150 }, .end = .{ .x = 1e-150 } } },
        .{ .value = .{ .radius = .{ .x = 1e9, .y = 1 }, .end = .{ .x = 1 } } },
    };
    for (cases) |case| for ([_]f64{ 0, 45, 90, 1e9 }) |rotation| {
        for ([_]bool{ false, true }) |large| for ([_]bool{ false, true }) |sweep| {
            var value = case.value;
            value.rotation = rotation;
            value.large = large;
            value.sweep = sweep;
            // Rotation can make the 1e9-boundary case need larger radii.
            const resolved = arcs.resolve(case.start, value) catch |err| {
                try std.testing.expect(case.allow_precision_rejection);
                try std.testing.expectEqual(error.UnsupportedArcPrecision, err);
                continue;
            };
            try std.testing.expect(resolved == .ellipse);
            const ellipse = resolved.ellipse;
            inline for (.{ ellipse.center, ellipse.x_axis, ellipse.y_axis }) |point| {
                try std.testing.expect(std.math.isFinite(point.x) and std.math.isFinite(point.y));
            }
            try std.testing.expect(std.math.isFinite(ellipse.start) and std.math.isFinite(ellipse.sweep));
        };
    };
}

fn expectArcDirection(actual: api.Point, expected: api.Point) !void {
    try std.testing.expect(std.math.isFinite(actual.x) and std.math.isFinite(actual.y));
    const scale = @max(@abs(actual.x), @abs(actual.y));
    try std.testing.expect(scale > 0);
    const x = actual.x / scale;
    const y = actual.y / scale;
    try std.testing.expectApproxEqAbs(@as(f64, 0), x * expected.y - y * expected.x, 1e-12);
    try std.testing.expect(x * expected.x + y * expected.y > 0);
}
test "arc endpoint directions use independent analytic flag and rotated ellipse limits" {
    const cases = [_]struct { large: bool, sweep: bool, first: api.Point, last: api.Point }{
        .{ .large = false, .sweep = true, .first = .{ .y = 1 }, .last = .{ .x = -1 } },
        .{ .large = false, .sweep = false, .first = .{ .x = -1 }, .last = .{ .y = 1 } },
        .{ .large = true, .sweep = false, .first = .{ .y = -1 }, .last = .{ .x = 1 } },
        .{ .large = true, .sweep = true, .first = .{ .x = 1 }, .last = .{ .y = -1 } },
    };
    for (cases) |case| {
        const value: api.Arc = .{ .radius = .{ .x = 6, .y = 6 }, .end = .{ .x = 8, .y = 14 }, .large = case.large, .sweep = case.sweep };
        const actual = (try value.endpointDirections(.{ .x = 14, .y = 8 })).?;
        try expectArcDirection(actual.outgoing, case.first);
        try expectArcDirection(actual.incoming, case.last);
    }
    const rotated: api.Arc = .{ .radius = .{ .x = 8, .y = 4 }, .rotation = 90, .end = .{ .x = 12, .y = 16 }, .sweep = true };
    const actual = (try rotated.endpointDirections(.{ .x = 16, .y = 24 })).?;
    try expectArcDirection(actual.outgoing, .{ .x = -1 });
    try expectArcDirection(actual.incoming, .{ .y = -1 });
    // Known center(8,12), X=(4sqrt(3),4), Y=(-2,2sqrt(3)), quarter sweep.
    const root_three = @sqrt(@as(f64, 3));
    const tilted: api.Arc = .{ .radius = .{ .x = 8, .y = 4 }, .rotation = 30, .end = .{ .x = 6, .y = 12 + 2 * root_three }, .sweep = true };
    const limits = (try tilted.endpointDirections(.{ .x = 8 + 4 * root_three, .y = 16 })).?;
    try expectArcDirection(limits.outgoing, .{ .x = -1 / root_three, .y = 1 });
    try expectArcDirection(limits.incoming, .{ .x = -1, .y = -1 / root_three });
}
test "arc endpoint directions retain omitted line corrected and signed radius semantics" {
    for ([_]api.Point{ .{ .x = 1, .y = 2 }, .{}, .{ .x = -1, .y = -2 } }) |radius| {
        const omitted: api.Arc = .{ .radius = radius, .end = .{ .x = 2, .y = 3 }, .large = true, .sweep = true };
        try std.testing.expectEqual(null, try omitted.endpointDirections(.{ .x = 2, .y = 3 }));
    }
    for ([_]api.Point{ .{ .y = 1 }, .{ .x = 1 }, .{} }) |radius| {
        const line: api.Arc = .{ .radius = radius, .end = .{ .x = 4, .y = 5 }, .rotation = 270, .large = true };
        const actual = (try line.endpointDirections(.{})).?;
        try expectArcDirection(actual.outgoing, .{ .x = 0.8, .y = 1 });
        try std.testing.expectEqualDeep(actual.outgoing, actual.incoming);
    }
    const reference: api.Arc = .{ .radius = .{ .x = 6, .y = 6 }, .end = .{ .x = 14, .y = 8 }, .sweep = true };
    const expected = try reference.endpointDirections(.{ .x = 2, .y = 8 });
    for ([_]f64{ 1, -1, 6, -6 }) |radius| for ([_]f64{ 0, 360, -360 }) |rotation| {
        const corrected: api.Arc = .{ .radius = .{ .x = radius, .y = radius }, .end = reference.end, .rotation = rotation, .large = true, .sweep = true };
        try std.testing.expectEqualDeep(expected, try corrected.endpointDirections(.{ .x = 2, .y = 8 }));
    };
    const tiny: api.Arc = .{ .radius = .{ .x = 1e-150, .y = 1e-150 }, .end = .{ .x = 1e-150 } };
    const tiny_directions = (try tiny.endpointDirections(.{})).?;
    try std.testing.expect(std.math.isFinite(tiny_directions.outgoing.x) and std.math.isFinite(tiny_directions.incoming.y));
}
test "arc endpoint query validates the same input boundary before degeneracy and rejects precision loss" {
    const valid: api.Arc = .{ .radius = .{ .x = 1, .y = 1 }, .end = .{ .x = 1 } };
    for ([_]api.Point{ .{ .x = std.math.nan(f64) }, .{ .y = std.math.inf(f64) }, .{ .x = 1e9 + 1 } }) |start| {
        try std.testing.expectError(error.InvalidGeometry, valid.endpointDirections(start));
    }
    const invalid = [_]api.Arc{
        .{ .radius = .{ .x = std.math.nan(f64) }, .end = .{} },
        .{ .radius = .{ .y = std.math.inf(f64) }, .end = .{} },
        .{ .radius = .{ .x = 1e9 + 1 }, .end = .{} },
        .{ .radius = .{}, .end = .{ .x = std.math.inf(f64) } },
        .{ .radius = .{}, .end = .{ .y = -1e9 - 1 } },
        .{ .radius = .{}, .end = .{}, .rotation = std.math.nan(f64) },
        .{ .radius = .{}, .end = .{}, .rotation = std.math.inf(f64) },
        .{ .radius = .{}, .end = .{}, .rotation = -1e9 - 1 },
    };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidGeometry, value.endpointDirections(.{}));
        try std.testing.expectError(error.InvalidGeometry, api.Path.create(allocator, &.{ .{ .move = .{} }, .{ .arc = value } }, .{}));
    }
    for ([_]api.Arc{
        .{ .radius = .{ .x = 1, .y = 1 }, .end = .{ .x = 1e-160 } },
        .{ .radius = .{ .x = 1e-320, .y = 1 }, .end = .{ .x = 1 } },
        .{ .radius = .{ .x = 1e-150, .y = 1 }, .end = .{ .x = 1 } },
    }) |value| try std.testing.expectError(error.UnsupportedArcPrecision, value.endpointDirections(.{}));
    std.debug.print("arc_direction_sizes arc={d} ellipse={d} result={d} directions={d} path={d}\n", .{ @sizeOf(api.Arc), @sizeOf(@import("arc.zig").Ellipse), @sizeOf(@import("arc.zig").Result), @sizeOf(api.Arc.Directions), @sizeOf(api.Path) });
}

test "path-data allocation failure and fixed-seed mutations preserve bounded ownership" {
    const Run = struct {
        fn run(a: std.mem.Allocator) !void {
            const path = try api.Path.parseData(a, "M1 1C2 3 4 5 6 7A3 4 45 0 1 10 12Z", .{});
            defer path.close() catch unreachable;
            const prepared = try path.prepare(a, options());
            defer prepared.close() catch unreachable;
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Run.run, .{});
    var prng: std.Random.DefaultPrng = .init(0x884312);
    const random = prng.random();
    const original = "M1 1C2 3 4 5 6 7A3 4 45 0 1 10 12Z";
    var bytes: [original.len]u8 = undefined;
    for (0..4000) |_| {
        @memcpy(&bytes, original);
        bytes[random.uintLessThan(usize, bytes.len)] = random.int(u8);
        const path = api.Path.parseData(allocator, bytes[0..random.uintLessThan(usize, bytes.len + 1)], .{ .limits = .{ .commands = 64 } }) catch continue;
        defer path.close() catch unreachable;
        var o = options();
        o.limits.vertices = 1024;
        o.limits.edges = 4096;
        const prepared = path.prepare(allocator, o) catch continue;
        defer prepared.close() catch unreachable;
        try (try prepared.view()).validate();
    }
}

test "lone moveto is unpainted while an explicit zero-length line receives caps" {
    for ([_]api.Cap{ .butt, .square, .round }) |cap| for ([_]bool{ false, true }) |line| {
        const path = try api.Path.parseData(allocator, if (line) "M4 4L4 4" else "M4 4", .{});
        defer path.close() catch unreachable;
        var o = options();
        o.style = .{ .stroke = .{ .width = 4, .cap = cap } };
        const prepared = try path.prepare(allocator, o);
        defer prepared.close() catch unreachable;
        const pixels = (try prepared.view()).coverage.pixels;
        var nonzero = false;
        for (pixels) |pixel| if (pixel != 0) {
            nonzero = true;
            break;
        };
        try std.testing.expectEqual(line and cap != .butt, nonzero);
    };
}

test "degenerate stroke geometry cannot evade the generation work budget" {
    var commands: [101]api.Command = undefined;
    commands[0] = .{ .move = .{ .x = 2, .y = 2 } };
    for (commands[1..], 0..) |*command, index| command.* = .{ .line = .{ .x = @floatFromInt(3 + index), .y = @floatFromInt(2 + index % 3) } };
    const path = try api.Path.create(allocator, &commands, .{});
    defer path.close() catch unreachable;
    var o = options();
    o.transform.yy = 0;
    o.style = .{ .stroke = .{ .width = 1e6, .cap = .round, .join = .round } };
    o.limits.edges = 1;
    o.limits.scan_tests = 1;
    o.limits.edge_attempts = 1024;
    try std.testing.expectError(error.GeometryBudgetExceeded, path.prepare(allocator, o));
    // Work also counts horizontal fill edges, even if none reach scan conversion.
    o.style = .{ .fill = .nonzero };
    o.limits.edge_attempts = 10;
    try std.testing.expectError(error.GeometryBudgetExceeded, path.prepare(allocator, o));
}

test "analytic bounds include curve extrema and affine ellipses without rasterizing" {
    const cases = [_]struct { data: []const u8, expected: api.Bounds }{
        .{ .data = "M0 0Q8 16 16 0", .expected = .{ .x = 0, .y = 0, .width = 16, .height = 8 } },
        .{ .data = "M0 0C0 16 16 16 16 0", .expected = .{ .x = 0, .y = 0, .width = 16, .height = 12 } },
        .{ .data = "M2 3L2 8", .expected = .{ .x = 2, .y = 3, .width = 0, .height = 5 } },
    };
    for (cases) |case| {
        const path = try api.Path.parseData(allocator, case.data, .{});
        defer path.close() catch unreachable;
        try std.testing.expectEqualDeep(case.expected, (try path.bounds(.{}, null)).?);
    }
    const curve = try api.Path.parseData(allocator, "M0 0C0 16 16 16 16 0", .{});
    defer curve.close() catch unreachable;
    const transformed = (try curve.bounds(.{ .xx = 0, .xy = -2, .yx = 3, .yy = 0, .x0 = 40, .y0 = 10 }, null)).?;
    try std.testing.expectEqualDeep(api.Bounds{ .x = 16, .y = 10, .width = 24, .height = 48 }, transformed);
    const rx: f64 = 6;
    const ry: f64 = 2;
    const angle: f64 = std.math.pi / 6.0;
    const a: api.Point = .{ .x = 8 + rx * @cos(angle), .y = 8 + rx * @sin(angle) };
    const b: api.Point = .{ .x = 8 - rx * @cos(angle), .y = 8 - rx * @sin(angle) };
    const ellipse = try api.Path.create(allocator, &.{ .{ .move = a }, .{ .arc = .{ .radius = .{ .x = rx, .y = ry }, .rotation = 30, .sweep = true, .end = b } }, .{ .arc = .{ .radius = .{ .x = rx, .y = ry }, .rotation = 30, .sweep = true, .end = a } } }, .{});
    defer ellipse.close() catch unreachable;
    const box = (try ellipse.bounds(.{}, null)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2 * @sqrt(28.0)), box.width, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2 * @sqrt(12.0)), box.height, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8), box.x + box.width / 2, 1e-6);
    const empty = try api.Path.parseData(allocator, "M2 3", .{});
    defer empty.close() catch unreachable;
    try std.testing.expectEqual(@as(?api.Bounds, null), try empty.bounds(.{}, null));
    var cancel: api.Cancellation = .{};
    cancel.request();
    try std.testing.expectError(error.Cancelled, curve.bounds(.{}, &cancel));
}

test "cubic analytic bounds contain independent dense polynomial samples" {
    var random = std.Random.DefaultPrng.init(0x675ee2);
    for (0..40) |_| {
        var points: [4]api.Point = undefined;
        for (&points) |*point| point.* = .{ .x = random.random().float(f64) * 64 - 32, .y = random.random().float(f64) * 64 - 32 };
        const path = try api.Path.create(allocator, &.{ .{ .move = points[0] }, .{ .cubic = .{ .first = points[1], .second = points[2], .end = points[3] } } }, .{});
        defer path.close() catch unreachable;
        const box = (try path.bounds(.{}, null)).?;
        var low: api.Point = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
        var high: api.Point = .{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) };
        for (0..2001) |sample| {
            const t = @as(f64, @floatFromInt(sample)) / 2000;
            const u = 1 - t;
            inline for (.{ "x", "y" }) |axis| {
                const value = u * u * u * @field(points[0], axis) + 3 * u * u * t * @field(points[1], axis) + 3 * u * t * t * @field(points[2], axis) + t * t * t * @field(points[3], axis);
                @field(low, axis) = @min(@field(low, axis), value);
                @field(high, axis) = @max(@field(high, axis), value);
                const minimum = if (axis[0] == 'x') box.x else box.y;
                const maximum = minimum + (if (axis[0] == 'x') box.width else box.height);
                try std.testing.expect(value >= minimum - 1e-10 and value <= maximum + 1e-10);
            }
        }
        try std.testing.expectApproxEqAbs(low.x, box.x, 1e-4);
        try std.testing.expectApproxEqAbs(low.y, box.y, 1e-4);
        try std.testing.expectApproxEqAbs(high.x, box.x + box.width, 1e-4);
        try std.testing.expectApproxEqAbs(high.y, box.y + box.height, 1e-4);
    }
}

test "optional sample bits preserve exact geometric union and aligned row accounting" {
    const first = try api.Path.parseData(allocator, "M.25 .25H4.75V3.75H.25Z", .{});
    defer first.close() catch unreachable;
    const second = try api.Path.parseData(allocator, "M.25 .25V3.75H4.75V.25Z", .{});
    defer second.close() catch unreachable;
    var o = options();
    o.viewport = .{ .width = 7, .height = 5 };
    o.retain_samples = true;
    const a = try first.prepare(allocator, o);
    defer a.close() catch unreachable;
    const b = try second.prepare(allocator, o);
    defer b.close() catch unreachable;
    try std.testing.expectEqualSlices(u16, a.samples, b.samples);
    try std.testing.expectEqual(@as(usize, a.coverage.stride * a.coverage.height), a.samples.len);
    for (a.samples, b.samples, a.coverage.pixels) |x, y, alpha| {
        try std.testing.expectEqual(x, x | y);
        try std.testing.expectEqual(x, x & y);
        try std.testing.expectEqual(@as(u8, @intCast((@as(u16, @popCount(x)) * 255 + 8) / 16)), alpha);
    }
    o.retain_samples = false;
    const plain = try first.prepare(allocator, o);
    defer plain.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), plain.samples.len);
    try std.testing.expectEqual((try plain.stats()).owned_bytes + a.samples.len * 2, (try a.stats()).owned_bytes);
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a1: std.mem.Allocator) !void {
            const path = try api.Path.parseData(a1, "M1 1H5V5H1Z", .{});
            defer path.close() catch unreachable;
            var setting = options();
            setting.retain_samples = true;
            const image = try path.prepare(a1, setting);
            try image.close();
        }
    }.run, .{});
}
