const std = @import("std");
const v = @import("ziggurat_vector");
const s = @import("scene.zig");
const allocator = std.testing.allocator;
fn geometry(data: []const u8) !*v.geometry.Geometry {
    return scaledGeometry(data, 1);
}
fn scaledGeometry(data: []const u8, scale: f32) !*v.geometry.Geometry {
    const path = try v.Path.parseData(allocator, data, .{});
    defer path.close() catch unreachable;
    return v.geometry.compile(path, allocator, .{ .scale = scale });
}
fn byte(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}
test "scene_private strict group clip and stripe tail match an independent rectangle oracle" {
    const fill = try geometry("M0 0H70V5H0Z");
    defer fill.close() catch unreachable;
    const clip = try geometry("M.5 .5H69.5V4.5H.5Z");
    defer clip.close() catch unreachable;
    const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{ fill, clip }, .brushes = &.{ .{ .solid = .{ 0, 0, 1, 1 } }, .{ .solid = .{ 1, 0, 0, 1 } } }, .clips = &.{.{ .geometry = 1 }}, .nodes = &.{ .{ .paint = .{ .geometry = 0, .brush = 0 } }, .{ .paint = .{ .geometry = 0, .brush = 1 } }, .{ .group = .{ .children = .{ .len = 2 }, .clip = 0 } } }, .children = &.{ 0, 1 }, .roots = &.{2} };
    var work: s.Work = .{};
    const raster = try s.Raster.create(allocator, program, .{}, &work);
    defer raster.close() catch unreachable;
    var output: [70 * 5 * 4]u8 = undefined;
    try raster.render(&output, 70, 5, &work, null);
    for (0..5) |y| for (0..70) |x| {
        var covered: u32 = 0;
        for (0..4) |sy| for (0..4) |sx| {
            const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4;
            const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4;
            if (px >= 0.5 and px < 69.5 and py >= 0.5 and py < 4.5) covered += 1;
        };
        const alpha: u8 = @intCast((covered * 255 + 8) / 16);
        try std.testing.expectEqualSlices(u8, &.{ alpha, 0, 0, alpha }, output[(y * 70 + x) * 4 ..][0..4]);
    };
    // Both paints and every horizontal tile reuse the same physical row cache.
    try std.testing.expectEqual(@as(u64, (fill.edges.len + clip.edges.len) * 4 * 5), work.geometry.scan_tests);
}

test "scene_private transparent gradient uses one pixel-center color for every covered lane" {
    const fill = try geometry("M.5 0H69.5V1H.5Z");
    defer fill.close() catch unreachable;
    var gradient: s.Gradient = .{ .count = 2, .inverse = .{}, .kind = .{ .linear = .{ .start = .{}, .delta = .{ .x = 70 }, .denominator = 4900 } } };
    gradient.stops[0] = .{ .offset = 0, .channels = .{ 0, 0, 1, 0 } };
    gradient.stops[1] = .{ .offset = 1, .channels = .{ 1, 0, 0, 1 } };
    const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .gradient = 0 }}, .gradients = &.{gradient}, .nodes = &.{.{ .paint = .{ .geometry = 0, .brush = 0 } }}, .children = &.{}, .roots = &.{0} };
    var work: s.Work = .{};
    const raster = try s.Raster.create(allocator, program, .{}, &work);
    defer raster.close() catch unreachable;
    var output: [70 * 4]u8 = undefined;
    try raster.render(&output, 70, 1, &work, null);
    for (0..70) |x| {
        const t = (@as(f64, @floatFromInt(x)) + 0.5) / 70;
        const coverage: f64 = if (x == 0 or x == 69) 0.5 else 1;
        const expected = [_]u8{ byte(t * t * coverage), 0, byte((1 - t) * t * coverage), byte(t * coverage) };
        try std.testing.expectEqualSlices(u8, &expected, output[x * 4 ..][0..4]);
    }
}

test "scene_private clip union intersection and duplicate boundaries agree at three DPI scales" {
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const fill = try scaledGeometry("M0 0H8V5H0Z", scale);
        defer fill.close() catch unreachable;
        const left = try scaledGeometry("M.5 .5H4.5V4.5H.5Z", scale);
        defer left.close() catch unreachable;
        const right = try scaledGeometry("M3.5 .5H7.5V4.5H3.5Z", scale);
        defer right.close() catch unreachable;
        const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{ fill, left, right }, .brushes = &.{.{ .solid = .{ 0, 0, 1, 1 } }}, .clips = &.{ .{ .geometry = 1 }, .{ .geometry = 2 }, .{ .union_of = .{ .a = 0, .b = 1 } }, .{ .intersection = .{ .a = 2, .b = 0 } }, .{ .intersection = .{ .a = 3, .b = 3 } } }, .nodes = &.{ .{ .paint = .{ .geometry = 0, .brush = 0 } }, .{ .group = .{ .children = .{ .len = 2 }, .clip = 4, .opacity = 0.5 } } }, .children = &.{ 0, 0 }, .roots = &.{1} };
        var work: s.Work = .{};
        const raster = try s.Raster.create(allocator, program, .{}, &work);
        defer raster.close() catch unreachable;
        const width: u32 = @intFromFloat(8 * scale);
        const height: u32 = @intFromFloat(@ceil(5 * scale));
        var output: [16 * 10 * 4]u8 = undefined;
        try raster.render(output[0 .. width * height * 4], width, height, &work, null);
        for (0..height) |y| for (0..width) |x| {
            var covered: u32 = 0;
            for (0..4) |sy| for (0..4) |sx| {
                const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4;
                const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4;
                if (px >= 0.5 * scale and px < 4.5 * scale and py >= 0.5 * scale and py < 4.5 * scale) covered += 1;
            };
            const alpha = byte(@as(f64, @floatFromInt(covered)) / 16 * 0.5);
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, output[(y * width + x) * 4 ..][0..4]);
        };
    }
}

test "scene_private masks use resolved continuous alpha and selected luminance color space" {
    const fill = try geometry("M0 0H2V2H0Z");
    defer fill.close() catch unreachable;
    const cases = [_]s.Mask{ .{ .node = 0, .mode = .alpha }, .{ .node = 0 }, .{ .node = 0, .linear_rgb = true } };
    for (cases, 0..) |mask, which| {
        const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{ .{ .solid = .{ 0.25, 0.25, 0.25, 0.5 } }, .{ .solid = .{ 0, 0, 1, 1 } } }, .masks = &.{mask}, .nodes = &.{ .{ .paint = .{ .geometry = 0, .brush = 0 } }, .{ .paint = .{ .geometry = 0, .brush = 1 } }, .{ .group = .{ .children = .{ .len = 1 }, .mask = 0, .opacity = 0.8 } } }, .children = &.{1}, .roots = &.{2} };
        var work: s.Work = .{};
        const raster = try s.Raster.create(allocator, program, .{}, &work);
        defer raster.close() catch unreachable;
        var output: [16]u8 = undefined;
        try raster.render(&output, 2, 2, &work, null);
        const alpha: u8 = switch (which) {
            0 => 102,
            1 => 51,
            else => 22,
        };
        for (0..4) |pixel| try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, output[pixel * 4 ..][0..4]);
    }
}

fn allocationCase(a: std.mem.Allocator, program: s.Program) !void {
    var work: s.Work = .{};
    const raster = try s.Raster.create(a, program, .{}, &work);
    defer raster.close() catch unreachable;
    var output: [16]u8 = undefined;
    try raster.render(&output, 2, 2, &work, null);
}
test "scene_private entire workspace allocation failure and byte budget release geometry pins" {
    const fill = try geometry("M0 0H2V2H0Z");
    defer fill.close() catch unreachable;
    const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .solid = .{ 1, 0, 0, 1 } }}, .clips = &.{.{ .geometry = 0 }}, .nodes = &.{.{ .paint = .{ .geometry = 0, .brush = 0, .clip = 0 } }}, .children = &.{}, .roots = &.{0} };
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{program});
    try std.testing.expectEqual(@as(usize, 0), fill.row_users);
    var work: s.Work = .{};
    const raster = try s.Raster.create(allocator, program, .{}, &work);
    const bytes = try raster.stats();
    try std.testing.expectError(error.ResourceInUse, fill.close());
    try raster.close();
    try std.testing.expectEqual(@as(usize, 0), fill.row_users);
    try std.testing.expectError(error.CapacityExceeded, s.Raster.create(allocator, program, .{ .bytes = bytes - 1 }, &work));
    try std.testing.expectEqual(@as(usize, 0), fill.row_users);
}

test "scene_private repeated stripe replay allocates nothing and cancellation preserves a private candidate" {
    const fill = try geometry("M0 0H70V3H0Z");
    defer fill.close() catch unreachable;
    const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .solid = .{ 0, 0, 1, 1 } }}, .nodes = &.{.{ .paint = .{ .geometry = 0, .brush = 0 } }}, .children = &.{}, .roots = &.{0} };
    var failure = std.testing.FailingAllocator.init(allocator, .{});
    var work: s.Work = .{};
    const raster = try s.Raster.create(failure.allocator(), program, .{}, &work);
    defer raster.close() catch unreachable;
    const count = failure.alloc_index;
    failure.fail_index = count;
    var output: [70 * 3 * 4]u8 = @splat(19);
    var cancellation: v.Cancellation = .{};
    cancellation.request();
    try std.testing.expectError(error.Cancelled, raster.render(&output, 70, 3, &work, &cancellation));
    for (output) |value| try std.testing.expectEqual(@as(u8, 19), value);
    for (0..50) |_| {
        work = .{};
        try raster.render(&output, 70, 3, &work, null);
        for (0..70 * 3) |pixel| try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, output[pixel * 4 ..][0..4]);
    }
    try std.testing.expectEqual(count, failure.alloc_index);
}

test "scene_private invalid dependencies and work limits fail explicitly" {
    const fill = try geometry("M0 0H2V2H0Z");
    defer fill.close() catch unreachable;
    var work: s.Work = .{};
    var program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .solid = .{ 0, 0, 1, 1 } }}, .nodes = &.{.{ .group = .{ .children = .{ .len = 1 } } }}, .children = &.{0}, .roots = &.{0} };
    try std.testing.expectError(error.InvalidSceneDependency, s.Raster.create(allocator, program, .{}, &work));
    program.nodes = &.{.{ .paint = .{ .geometry = 0, .brush = 0 } }};
    program.children = &.{};
    program.clips = &.{.{ .union_of = .{ .a = 0, .b = 0 } }};
    try std.testing.expectError(error.InvalidSceneDependency, s.Raster.create(allocator, program, .{}, &work));
    program.clips = &.{};
    work.op_limit = work.ops;
    try std.testing.expectError(error.SceneWorkExceeded, s.Raster.create(allocator, program, .{}, &work));
    work = .{};
    const raster = try s.Raster.create(allocator, program, .{}, &work);
    defer raster.close() catch unreachable;
    var output: [16]u8 = @splat(19);
    work.color.limit = 0;
    try std.testing.expectError(error.ColorWorkExceeded, raster.render(&output, 2, 2, &work, null));
    for (output) |value| try std.testing.expectEqual(@as(u8, 19), value);
}

test "scene_private mask dependencies layers calls and clip depth are preflighted" {
    const fill = try geometry("M0 0H2V2H0Z");
    defer fill.close() catch unreachable;
    var work: s.Work = .{};
    var program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .solid = .{ 0, 0, 1, 1 } }}, .nodes = &.{ .{ .paint = .{ .geometry = 0, .brush = 0 } }, .{ .group = .{ .children = .{ .len = 1 }, .opacity = 0.5 } }, .{ .group = .{ .children = .{ .start = 1, .len = 1 }, .opacity = 0.5 } } }, .children = &.{ 0, 1 }, .roots = &.{2} };
    try std.testing.expectError(error.LayersFull, s.Raster.create(allocator, program, .{ .layers = 1 }, &work));
    try std.testing.expectError(error.ReferenceDepthFull, s.Raster.create(allocator, program, .{ .calls = 2 }, &work));
    program.nodes = &.{ .{ .paint = .{ .geometry = 0, .brush = 0 } }, .{ .group = .{ .children = .{ .len = 1 }, .mask = 0 } } };
    program.masks = &.{.{ .node = 1, .mode = .alpha }};
    program.roots = &.{1};
    try std.testing.expectError(error.InvalidSceneDependency, s.Raster.create(allocator, program, .{}, &work));
    program.masks = &.{};
    program.nodes = &.{.{ .paint = .{ .geometry = 0, .brush = 0 } }};
    program.children = &.{};
    program.roots = &.{0};
    var clips: [34]s.Clip = undefined;
    clips[0] = .{ .geometry = 0 };
    for (1..clips.len) |index| clips[index] = .{ .union_of = .{ .a = index - 1, .b = index - 1 } };
    program.clips = &clips;
    try std.testing.expectError(error.ReferenceDepthFull, s.Raster.create(allocator, program, .{}, &work));
    try std.testing.expectEqual(@as(usize, 0), fill.row_users);
    var cancellation: v.Cancellation = .{};
    cancellation.request();
    program.clips = &.{};
    try std.testing.expectError(error.Cancelled, s.Raster.create(allocator, program, .{ .cancellation = &cancellation }, &work));
}

test "scene_private owner checks precede descriptor validation and rendering" {
    const fill = try geometry("M0 0H2V2H0Z");
    defer fill.close() catch unreachable;
    const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .solid = .{ 0, 0, 1, 1 } }}, .nodes = &.{.{ .paint = .{ .geometry = 0, .brush = 0 } }}, .children = &.{}, .roots = &.{0} };
    var work: s.Work = .{};
    const raster = try s.Raster.create(allocator, program, .{}, &work);
    defer raster.close() catch unreachable;
    const Probe = struct {
        raster: *s.Raster,
        program: s.Program,
        wrong: usize = 0,
        fn worker(self: *@This()) void {
            var local: s.Work = .{};
            _ = s.Raster.create(allocator, self.program, .{ .bytes = 0 }, &local) catch |err| value: {
                if (err == error.WrongThread) self.wrong += 1;
                break :value undefined;
            };
            var bytes: [4]u8 = undefined;
            self.raster.render(&bytes, 0, 0, &local, null) catch |err| {
                if (err == error.WrongThread) self.wrong += 1;
            };
            _ = self.raster.stats() catch |err| value: {
                if (err == error.WrongThread) self.wrong += 1;
                break :value 0;
            };
            self.raster.close() catch |err| {
                if (err == error.WrongThread) self.wrong += 1;
            };
        }
    };
    var probe: Probe = .{ .raster = raster, .program = program };
    const thread = try std.Thread.spawn(.{}, Probe.worker, .{&probe});
    thread.join();
    try std.testing.expectEqual(@as(usize, 4), probe.wrong);
}

test "scene_private sample budget includes inherited clips group snapshots and mask scope resets" {
    const fill = try geometry("M0 0H2V1H0Z");
    defer fill.close() catch unreachable;
    const paints = [_]s.Node{.{ .paint = .{ .geometry = 0, .brush = 0 } }};
    const isolated = [_]s.Node{ paints[0], .{ .group = .{ .children = .{ .len = 1 }, .opacity = 0.5 } } };
    const masked = [_]s.Node{ paints[0], .{ .group = .{ .children = .{ .len = 1 }, .mask = 0 } } };
    const Case = struct { nodes: []const s.Node, root: usize, samples: u64, alpha: u8 };
    // Two pixels: geometry reserves 17 writes/pixel, every inherited clip or
    // AND costs two, a scope reset costs 32, and its explicit clip copy two.
    const cases = [_]Case{
        .{ .nodes = &paints, .root = 0, .samples = 32 + 2 + 34 + 2, .alpha = 255 },
        .{ .nodes = &isolated, .root = 1, .samples = 32 + 2 + 34 + 2 + 34 + 2, .alpha = 128 },
        .{ .nodes = &masked, .root = 1, .samples = 32 + 2 + 34 + 2 + 34 + 2 + 32 + 2 + 34 + 2, .alpha = 255 },
    };
    for (cases) |case| {
        const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .solid = .{ 0, 0, 1, 1 } }}, .masks = &.{.{ .node = 0, .mode = .alpha }}, .nodes = case.nodes, .children = &.{0}, .roots = &.{case.root} };
        var work: s.Work = .{};
        const raster = try s.Raster.create(allocator, program, .{}, &work);
        defer raster.close() catch unreachable;
        var output: [8]u8 = @splat(19);
        work = .{ .geometry = .{ .sample_limit = case.samples - 1 } };
        try std.testing.expectError(error.SampleWorkExceeded, raster.render(&output, 2, 1, &work, null));
        for (output) |value| try std.testing.expectEqual(@as(u8, 19), value);
        try std.testing.expect(work.geometry.sample_work <= work.geometry.sample_limit);
        work = .{ .geometry = .{ .sample_limit = case.samples } };
        try raster.render(&output, 2, 1, &work, null);
        try std.testing.expectEqual(case.samples, work.geometry.sample_work);
        try std.testing.expectEqual(case.alpha, output[3]);
    }
}

test "scene_private shared clip DAG is evaluated once per tile with linear counted work" {
    const fill = try geometry("M0 0H70V1H0Z");
    defer fill.close() catch unreachable;
    // Most clips are unused by this tile. A duplicate-child DAG of depth 31
    // would expand to billions of calls without memoizing successful results.
    var clips: [1024]s.Clip = @splat(.{ .geometry = 0 });
    for (1..32) |index| clips[index] = .{ .union_of = .{ .a = index - 1, .b = index - 1 } };
    const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .solid = .{ 0, 0, 1, 1 } }}, .clips = &clips, .nodes = &.{.{ .paint = .{ .geometry = 0, .brush = 0, .clip = 31 } }}, .children = &.{}, .roots = &.{ 0, 0, 0 } };
    var failure = std.testing.FailingAllocator.init(allocator, .{});
    var work: s.Work = .{};
    const raster = try s.Raster.create(failure.allocator(), program, .{}, &work);
    defer raster.close() catch unreachable;
    const allocations = failure.alloc_index;
    failure.fail_index = allocations;
    var output: [70 * 4]u8 = undefined;
    for (0..2) |pass| {
        work = .{ .op_limit = 3 * 68, .geometry = .{ .sample_limit = 70 * 108 + 3 * 32 } };
        try raster.render(&output, 70, 1, &work, null);
        try std.testing.expectEqual(@as(u64, 3 * 68), work.ops);
        try std.testing.expectEqual(@as(u64, 70 * 108 + 3 * 32), work.geometry.sample_work);
        // Crossing caches survive x changes and repeated renders of this y;
        // clip caches survive only their single tile, including its short tail.
        try std.testing.expectEqual(@as(u64, if (pass == 0) fill.edges.len * 4 else 0), work.geometry.scan_tests);
        for (0..70) |pixel| try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, output[pixel * 4 ..][0..4]);
        for (raster.clips[0..32]) |cache| try std.testing.expectEqual(raster.clip_epoch, cache.epoch);
        for (raster.clips[32..]) |cache| try std.testing.expectEqual(@as(u64, 0), cache.epoch);
    }
    try std.testing.expectEqual(allocations, failure.alloc_index);
}

test "scene_private clip cache publishes only complete results and never wraps its epoch" {
    const fill = try geometry("M0 0H2V1H0Z");
    defer fill.close() catch unreachable;
    const program: s.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = &.{fill}, .brushes = &.{.{ .solid = .{ 0, 0, 1, 1 } }}, .clips = &.{ .{ .geometry = 0 }, .{ .union_of = .{ .a = 0, .b = 0 } } }, .nodes = &.{.{ .paint = .{ .geometry = 0, .brush = 0, .clip = 1 } }}, .children = &.{}, .roots = &.{0} };
    var work: s.Work = .{};
    const raster = try s.Raster.create(allocator, program, .{}, &work);
    defer raster.close() catch unreachable;
    var output: [8]u8 = @splat(19);
    // Begin32 + inherited2 + geometry34 succeeds. Its parent OR needs two
    // more writes, so only the completed leaf may publish this epoch.
    work = .{ .geometry = .{ .sample_limit = 32 + 2 + 34 } };
    try std.testing.expectError(error.SampleWorkExceeded, raster.render(&output, 2, 1, &work, null));
    try std.testing.expectEqual(raster.clip_epoch, raster.clips[0].epoch);
    try std.testing.expectEqual(@as(u64, 0), raster.clips[1].epoch);
    for (output) |value| try std.testing.expectEqual(@as(u8, 19), value);
    work = .{};
    raster.clip_epoch = std.math.maxInt(u64) - 1;
    try raster.render(&output, 2, 1, &work, null);
    try std.testing.expectEqual(std.math.maxInt(u64), raster.clip_epoch);
    @memset(&output, 19);
    try std.testing.expectError(error.GenerationExhausted, raster.render(&output, 2, 1, &work, null));
    try std.testing.expectEqual(std.math.maxInt(u64), raster.clip_epoch);
    for (output) |value| try std.testing.expectEqual(@as(u8, 19), value);
}
