const std = @import("std");
const api = @import("root.zig");
const g = api.geometry;
const allocator = std.testing.allocator;

fn differential(data: []const u8, style: api.Style, transform: api.Transform, scale: f32) !void {
    const path = try api.Path.parseData(allocator, data, .{});
    defer path.close() catch unreachable;
    const old = try path.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 69, .height = 41 }, .scale = scale, .style = style, .transform = transform, .retain_samples = true });
    defer old.close() catch unreachable;
    const geometry = try g.compile(path, allocator, .{ .style = style, .transform = transform, .scale = scale });
    defer geometry.close() catch unreachable;
    const rows = try g.Rows.create(allocator, &.{geometry}, 8 * 1024 * 1024);
    defer rows.close() catch unreachable;
    var work: g.Work = .{};
    var output: [32]u16 = undefined;
    for (0..old.coverage.height) |y| {
        const row = try rows.prepare(0, @intCast(y), &work, null);
        const used = work.scan_tests;
        var x: usize = 0;
        while (x < old.coverage.width) {
            const count = @min(output.len, old.coverage.width - x);
            try row.writeSamples(@intCast(x), output[0..count], &work);
            // Geometry is independent of an output viewport. Apply that
            // separate clip in sample space before comparing the old raster.
            for (output[0..count], 0..) |*bits, column| {
                var clip: u16 = 0;
                for (0..4) |sy| for (0..4) |sx| {
                    const px = @as(f64, @floatFromInt(x + column)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4;
                    const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4;
                    if (px < 69 * @as(f64, scale) and py < 41 * @as(f64, scale)) clip |= @as(u16, 1) << @intCast(sy * 4 + sx);
                };
                bits.* &= clip;
            }
            try std.testing.expectEqualSlices(u16, old.samples[y * old.coverage.stride + x ..][0..count], output[0..count]);
            x += count;
        }
        _ = try rows.prepare(0, @intCast(y), &work, null);
        try std.testing.expectEqual(used, work.scan_tests);
    }
}

test "geometry_private coverage matches existing curves arcs holes and stroked cuts" {
    const inputs = [_][]const u8{
        "M.5 .25H67.75V39.5H.5Z M12 8H55V32H12Z",
        "M-4 10C80-8-12 55 67 23Q32 60 5 16Z",
        "M3 20A28 13 31 1 1 60 21A16 8 60 0 0 11 30Z",
        "M1 2H65V38H3Z M8 9L60 29L2 34Z M31 12L31 12",
    };
    const styles = [_]api.Style{
        .{ .fill = .nonzero },
        .{ .fill = .even_odd },
        .{ .stroke = .{ .width = 3.25, .cap = .round, .join = .round, .dashes = &.{ 3, 2, 1 }, .dash_offset = -2, .trim = .{ .start = 0.1, .end = 0.9 } } },
        .{ .stroke = .{ .width = 2.5, .cap = .square, .join = .miter } },
    };
    for (inputs) |input| for (styles) |style| for ([_]api.Transform{ .{}, .{ .xx = -0.85, .xy = 0.13, .yx = -0.1, .yy = 0.8, .x0 = 64, .y0 = 5 } }) |transform| for ([_]f32{ 1, 1.5, 2 }) |scale| try differential(input, style, transform, scale);
}

test "geometry_private manual sample oracle covers fractional edges and off-left winding" {
    const path = try api.Path.parseData(allocator, "M-50 .5H70.5V2.5H-50Z M2 .5H3V2.5H2Z", .{});
    defer path.close() catch unreachable;
    const geometry = try g.compile(path, allocator, .{ .style = .{ .fill = .even_odd } });
    defer geometry.close() catch unreachable;
    const rows = try g.Rows.create(allocator, &.{geometry}, 4096);
    defer rows.close() catch unreachable;
    var work: g.Work = .{};
    var samples: [73]u16 = undefined;
    for (0..4) |y| {
        const row = try rows.prepare(0, @intCast(y), &work, null);
        try row.writeSamples(-1, &samples, &work);
        for (samples, 0..) |actual, column| {
            var expected: u16 = 0;
            for (0..4) |sy| for (0..4) |sx| {
                const px = @as(f64, @floatFromInt(column)) - 1 + (@as(f64, @floatFromInt(sx)) + 0.5) / 4;
                const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4;
                const inside = px >= -50 and px < 70.5 and py >= 0.5 and py < 2.5 and !(px >= 2 and px < 3);
                if (inside) expected |= @as(u16, 1) << @intCast(sy * 4 + sx);
            };
            try std.testing.expectEqual(expected, actual);
        }
    }
}

fn windingOracle(points: []const api.Point, point: api.Point) i32 {
    var winding: i32 = 0;
    for (points, 0..) |a, index| {
        const b = points[(index + 1) % points.len];
        const side = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y);
        if (a.y <= point.y and b.y > point.y and side > 0) winding += 1;
        if (a.y > point.y and b.y <= point.y and side < 0) winding -= 1;
    }
    return winding;
}
fn exactlyOnEdge(points: []const api.Point, point: api.Point) bool {
    for (points, 0..) |a, index| {
        const b = points[(index + 1) % points.len];
        const side = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y);
        if (side == 0 and point.x >= @min(a.x, b.x) and point.x <= @max(a.x, b.x) and point.y >= @min(a.y, b.y) and point.y <= @max(a.y, b.y)) return true;
    }
    return false;
}
test "geometry_private random self-intersections match independent point winding" {
    var random: std.Random.DefaultPrng = .init(0x8a13c7);
    const rng = random.random();
    var points: [13]api.Point = undefined;
    var commands: [14]api.Command = undefined;
    for (0..40) |_| {
        for (&points) |*point| point.* = .{ .x = @as(f64, @floatFromInt(rng.intRangeAtMost(i32, -24, 64))) / 4, .y = @as(f64, @floatFromInt(rng.intRangeAtMost(i32, -24, 64))) / 4 };
        commands[0] = .{ .move = points[0] };
        for (points[1..], commands[1..13]) |point, *command| command.* = .{ .line = point };
        commands[13] = .close;
        const path = try api.Path.create(allocator, &commands, .{});
        defer path.close() catch unreachable;
        for ([_]api.FillRule{ .nonzero, .even_odd }) |rule| {
            const geometry = try g.compile(path, allocator, .{ .style = .{ .fill = rule } });
            defer geometry.close() catch unreachable;
            const rows = try g.Rows.create(allocator, &.{geometry}, 16384);
            defer rows.close() catch unreachable;
            var work: g.Work = .{};
            var actual: [17]u16 = undefined;
            for (0..17) |y| {
                const row = try rows.prepare(0, @as(i32, @intCast(y)) - 1, &work, null);
                try row.writeSamples(-1, &actual, &work);
                for (actual, 0..) |bits, x| {
                    var expected: u16 = 0;
                    var boundary: u16 = 0;
                    for (0..4) |sy| for (0..4) |sx| {
                        const point: api.Point = .{ .x = @as(f64, @floatFromInt(x)) - 1 + (@as(f64, @floatFromInt(sx)) + 0.5) / 4, .y = @as(f64, @floatFromInt(y)) - 1 + (@as(f64, @floatFromInt(sy)) + 0.5) / 4 };
                        const winding = windingOracle(&points, point);
                        if (if (rule == .even_odd) @mod(winding, 2) != 0 else winding != 0) expected |= @as(u16, 1) << @intCast(sy * 4 + sx);
                        if (exactlyOnEdge(&points, point)) boundary |= @as(u16, 1) << @intCast(sy * 4 + sx);
                    };
                    // Oblique intersections can round either side of an
                    // exactly coincident sample in f64. The analytic oracle
                    // excludes only those exact boundary bits, with no epsilon.
                    // The differential matrix separately fixes legacy ties.
                    try std.testing.expectEqual(expected & ~boundary, bits & ~boundary);
                }
            }
        }
    }
}

test "geometry_private all scene row scratch is charged and all entries retain geometry" {
    const path = try api.Path.parseData(allocator, "M0 0H8V8H0Z", .{});
    defer path.close() catch unreachable;
    const first = try g.compile(path, allocator, .{});
    defer first.close() catch unreachable;
    const second = try g.compile(path, allocator, .{ .transform = .{ .x0 = 20 } });
    defer second.close() catch unreachable;
    const rows = try g.Rows.create(allocator, &.{ first, second }, 4096);
    const bytes = try rows.stats();
    try std.testing.expectEqual((first.edges.len + second.edges.len) * 4, rows.scratch.len);
    try std.testing.expectEqual(@sizeOf(g.Rows) + rows.entries.len * @sizeOf(@TypeOf(rows.entries[0])) + rows.scratch.len * @sizeOf(g.Crossing), bytes);
    try std.testing.expectError(error.ResourceInUse, first.close());
    try std.testing.expectError(error.ResourceInUse, second.close());
    try std.testing.expectError(error.CapacityExceeded, g.Rows.create(allocator, &.{ first, second }, bytes - 1));
    try std.testing.expectEqual(@as(usize, 1), first.row_users);
    try std.testing.expectEqual(@as(usize, 1), second.row_users);
    var work: g.Work = .{ .scan_limit = @intCast((first.edges.len + second.edges.len) * 4) };
    _ = try rows.prepare(0, 2, &work, null);
    _ = try rows.prepare(1, 2, &work, null);
    try std.testing.expectEqual(work.scan_limit, work.scan_tests);
    try std.testing.expectError(error.ScanBudgetExceeded, rows.prepare(0, 3, &work, null));
    _ = try rows.prepare(0, 2, &work, null);
    try rows.close();
    try std.testing.expectEqual(@as(usize, 0), first.row_users);
    try std.testing.expectEqual(@as(usize, 0), second.row_users);
}

fn allocationCase(a: std.mem.Allocator) !void {
    const path = try api.Path.parseData(a, "M1 2C7 0 12 12 17 5A3 4 20 1 0 28 11Z", .{});
    defer path.close() catch unreachable;
    const geometry = try g.compile(path, a, .{ .style = .{ .stroke = .{ .width = 3, .cap = .round, .dashes = &.{ 3, 2 } } } });
    defer geometry.close() catch unreachable;
    const rows = try g.Rows.create(a, &.{ geometry, geometry }, 1024 * 1024);
    defer rows.close() catch unreachable;
    var work: g.Work = .{};
    const row = try rows.prepare(0, 5, &work, null);
    var samples: [32]u16 = undefined;
    try row.writeSamples(0, &samples, &work);
}
test "geometry_private every allocation failure rolls back candidate edges and row pins" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
}

test "geometry_private source can close before rows and queries make no allocations" {
    var failure = std.testing.FailingAllocator.init(allocator, .{});
    const a = failure.allocator();
    const path = try api.Path.parseData(a, "M0 0H96V32H0Z", .{});
    const geometry = try g.compile(path, a, .{});
    defer geometry.close() catch unreachable;
    try path.close();
    const rows = try g.Rows.create(a, &.{geometry}, 4096);
    defer rows.close() catch unreachable;
    const allocations = failure.alloc_index;
    failure.fail_index = allocations;
    var work: g.Work = .{};
    var samples: [32]u16 = undefined;
    for (0..32) |y| {
        const row = try rows.prepare(0, @intCast(y), &work, null);
        for (0..3) |tile| {
            try row.writeSamples(@intCast(tile * 32), &samples, &work);
            for (samples) |sample| try std.testing.expectEqual(@as(u16, 0xffff), sample);
        }
    }
    try std.testing.expectEqual(allocations, failure.alloc_index);
}

test "geometry_private rejection cancellation and sample budget do not publish output" {
    const path = try api.Path.parseData(allocator, "M0 0H8V8H0Z", .{});
    defer path.close() catch unreachable;
    try std.testing.expectError(error.InvalidScale, g.compile(path, allocator, .{ .scale = 1e30 }));
    try std.testing.expectError(error.CapacityExceeded, g.compile(path, allocator, .{ .limits = .{ .bytes = 1 } }));
    var cancellation: api.Cancellation = .{};
    cancellation.request();
    try std.testing.expectError(error.Cancelled, g.compile(path, allocator, .{ .cancellation = &cancellation }));
    const geometry = try g.compile(path, allocator, .{});
    defer geometry.close() catch unreachable;
    const rows = try g.Rows.create(allocator, &.{geometry}, 4096);
    defer rows.close() catch unreachable;
    var work: g.Work = .{ .sample_limit = 17 * 8 - 1 };
    try std.testing.expectError(error.Cancelled, rows.prepare(0, 2, &work, &cancellation));
    const row = try rows.prepare(0, 2, &work, null);
    var samples: [8]u16 = @splat(0x1234);
    try std.testing.expectError(error.SampleWorkExceeded, row.writeSamples(0, &samples, &work));
    for (samples) |sample| try std.testing.expectEqual(@as(u16, 0x1234), sample);
    try std.testing.expectEqual(@as(u64, 0), work.sample_work);
    try std.testing.expectError(error.InvalidGeometryIndex, rows.prepare(1, 0, &work, null));
    work.sort_limit = work.sort_tests;
    try std.testing.expectError(error.SortBudgetExceeded, rows.prepare(0, 3, &work, null));
    try std.testing.expectEqual(null, rows.entries[0].y);
    work.sort_limit = 128;
    _ = try rows.prepare(0, 3, &work, null);
    const scans = work.scan_tests;
    const outside = try rows.prepare(0, 20, &work, null);
    try std.testing.expectEqual(scans, work.scan_tests);
    work.sample_limit = 1024;
    try outside.writeSamples(0, &samples, &work);
    for (samples) |sample| try std.testing.expectEqual(@as(u16, 0), sample);
}

test "geometry_private origin keeps large physical coordinates local without changing samples" {
    const path = try api.Path.parseData(allocator, "M900000000.5 900000000.5h4v4h-4Z", .{});
    defer path.close() catch unreachable;
    const geometry = try g.compile(path, allocator, .{ .origin_x = 900000000, .origin_y = 900000000 });
    defer geometry.close() catch unreachable;
    const rows = try g.Rows.create(allocator, &.{geometry}, 4096);
    defer rows.close() catch unreachable;
    var work: g.Work = .{};
    var samples: [6]u16 = undefined;
    const row = try rows.prepare(0, 0, &work, null);
    try row.writeSamples(0, &samples, &work);
    try std.testing.expectEqualSlices(u16, &.{ 0xcc00, 0xff00, 0xff00, 0xff00, 0x3300, 0 }, &samples);
}

test "geometry_private owner checks precede cache and argument inspection" {
    const path = try api.Path.parseData(allocator, "M0 0H8V8H0Z", .{});
    defer path.close() catch unreachable;
    const geometry = try g.compile(path, allocator, .{});
    defer geometry.close() catch unreachable;
    const rows = try g.Rows.create(allocator, &.{geometry}, 4096);
    defer rows.close() catch unreachable;
    var work: g.Work = .{};
    const row = try rows.prepare(0, 0, &work, null);
    const Probe = struct {
        geometry: *g.Geometry,
        rows: *g.Rows,
        row: g.Row,
        wrong: usize = 0,
        fn worker(self: *@This()) void {
            self.geometry.close() catch |err| {
                if (err == error.WrongThread) self.wrong += 1;
            };
            _ = self.geometry.stats() catch |err| blk: {
                if (err == error.WrongThread) self.wrong += 1;
                break :blk undefined;
            };
            var local_work: g.Work = .{};
            _ = self.rows.prepare(std.math.maxInt(usize), 0, &local_work, null) catch |err| blk: {
                if (err == error.WrongThread) self.wrong += 1;
                break :blk undefined;
            };
            self.rows.close() catch |err| {
                if (err == error.WrongThread) self.wrong += 1;
            };
            var output: [1]u16 = undefined;
            self.row.writeSamples(0, &output, &local_work) catch |err| {
                if (err == error.WrongThread) self.wrong += 1;
            };
        }
    };
    var probe: Probe = .{ .geometry = geometry, .rows = rows, .row = row };
    const thread = try std.Thread.spawn(.{}, Probe.worker, .{&probe});
    thread.join();
    try std.testing.expectEqual(@as(usize, 5), probe.wrong);
}
