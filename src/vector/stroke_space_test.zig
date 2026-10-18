const std = @import("std");
const v = @import("root.zig");
const a = std.testing.allocator;

fn compare(source: []const v.Command, host: []const v.Command, matrix: v.Transform, stroke: v.Stroke, scale: f32) !void {
    const path = try v.Path.create(a, source, .{});
    defer path.close() catch unreachable;
    const oracle = try v.Path.create(a, host, .{});
    defer oracle.close() catch unreachable;
    var actual_stroke = stroke;
    actual_stroke.space = .transformed;
    const viewport: v.drawing.Rect = .{ .width = 32, .height = 32 };
    const actual = try path.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .viewport = viewport, .scale = scale, .transform = matrix, .style = .{ .stroke = actual_stroke }, .retain_samples = true });
    defer actual.close() catch unreachable;
    const expected = try oracle.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .viewport = viewport, .scale = scale, .style = .{ .stroke = stroke }, .retain_samples = true });
    defer expected.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, actual.coverage.pixels, expected.coverage.pixels);
    try std.testing.expectEqualSlices(u16, actual.samples, expected.samples);
    // Compiled rows share the same stroker, with independent public entry
    // validation and origin/scale handling. Read every row of their result.
    const geometry = try v.geometry.compile(path, a, .{ .transform = matrix, .scale = scale, .style = .{ .stroke = actual_stroke } });
    defer geometry.close() catch unreachable;
    const rows = try v.geometry.Rows.create(a, &.{geometry}, 1024 * 1024);
    defer rows.close() catch unreachable;
    var work: v.geometry.Work = .{};
    var bits: [64]u16 = undefined;
    for (0..actual.coverage.height) |y| {
        const row = try rows.prepare(0, @intCast(y), &work, null);
        try row.writeSamples(0, bits[0..actual.coverage.width], &work);
        try std.testing.expectEqualSlices(u16, expected.samples[y * expected.coverage.stride ..][0..actual.coverage.width], bits[0..actual.coverage.width]);
    }
}

test "transformed strokes share host width joins caps dashes and trim after affine mapping" {
    const source = [_]v.Command{ .{ .move = .{ .x = 1, .y = 1 } }, .{ .line = .{ .x = 5, .y = 1 } }, .{ .line = .{ .x = 5, .y = 5 } }, .{ .line = .{ .x = 1, .y = 5 } }, .close };
    const cases = [_]struct { matrix: v.Transform, host: [5]v.Command }{
        .{ .matrix = .{ .xx = 3, .yy = 2, .x0 = 2, .y0 = 3 }, .host = .{ .{ .move = .{ .x = 5, .y = 5 } }, .{ .line = .{ .x = 17, .y = 5 } }, .{ .line = .{ .x = 17, .y = 13 } }, .{ .line = .{ .x = 5, .y = 13 } }, .close } },
        .{ .matrix = .{ .xx = -2, .xy = 1, .yy = 2, .x0 = 18, .y0 = 2 }, .host = .{ .{ .move = .{ .x = 17, .y = 4 } }, .{ .line = .{ .x = 9, .y = 4 } }, .{ .line = .{ .x = 13, .y = 12 } }, .{ .line = .{ .x = 21, .y = 12 } }, .close } },
        .{ .matrix = .{ .xx = 0, .yx = 2, .xy = -3, .yy = 0, .x0 = 22, .y0 = 2 }, .host = .{ .{ .move = .{ .x = 19, .y = 4 } }, .{ .line = .{ .x = 19, .y = 12 } }, .{ .line = .{ .x = 7, .y = 12 } }, .{ .line = .{ .x = 7, .y = 4 } }, .close } },
    };
    for (cases) |case| for ([_]f32{ 1, 1.5, 2 }) |scale| for ([_]v.Join{ .miter, .round, .bevel }) |join| for ([_]v.Cap{ .butt, .square, .round }) |cap| {
        try compare(&source, &case.host, case.matrix, .{ .width = 2, .join = join, .cap = cap }, scale);
        try compare(&source, &case.host, case.matrix, .{ .width = 2, .join = join, .cap = cap, .dashes = &.{ 4, 2 }, .dash_offset = -1, .trim = .{ .start = 0.75, .end = 0.25 } }, scale);
    };
}

test "transformed curve centerlines flatten in host coordinates" {
    const source = [_]v.Command{ .{ .move = .{ .x = 1, .y = 1 } }, .{ .quadratic = .{ .control = .{ .x = 3, .y = 5 }, .end = .{ .x = 5, .y = 1 } } }, .{ .cubic = .{ .first = .{ .x = 7, .y = -3 }, .second = .{ .x = 9, .y = 5 }, .end = .{ .x = 11, .y = 1 } } } };
    const host = [_]v.Command{ .{ .move = .{ .x = 6, .y = 8 } }, .{ .quadratic = .{ .control = .{ .x = 14, .y = 16 }, .end = .{ .x = 14, .y = 8 } } }, .{ .cubic = .{ .first = .{ .x = 14, .y = 0 }, .second = .{ .x = 26, .y = 16 }, .end = .{ .x = 26, .y = 8 } } } };
    for ([_]f32{ 1, 1.5, 2 }) |scale| try compare(&source, &host, .{ .xx = 2, .xy = 1, .yy = 2, .x0 = 3, .y0 = 6 }, .{ .width = 1.5, .cap = .round, .dashes = &.{ 3, 1 } }, scale);
    const arc = [_]v.Command{ .{ .move = .{ .x = 2, .y = 2 } }, .{ .arc = .{ .radius = .{ .x = 2, .y = 2 }, .sweep = true, .end = .{ .x = 6, .y = 2 } } } };
    const ellipse = [_]v.Command{ .{ .move = .{ .x = 8, .y = 9 } }, .{ .arc = .{ .radius = .{ .x = 6, .y = 4 }, .sweep = true, .end = .{ .x = 20, .y = 9 } } } };
    for ([_]f32{ 1, 1.5, 2 }) |scale| try compare(&arc, &ellipse, .{ .xx = 3, .yy = 2, .x0 = 2, .y0 = 5 }, .{ .width = 2, .cap = .round }, scale);
}

test "identity host strokes preserve dash and trim curve geometry at sub-unit physical scales" {
    const source = [_]v.Command{ .{ .move = .{ .x = 1, .y = 2 } }, .{ .quadratic = .{ .control = .{ .x = 15, .y = 31 }, .end = .{ .x = 30, .y = 2 } } }, .{ .cubic = .{ .first = .{ .x = 6, .y = 27 }, .second = .{ .x = 24, .y = 1 }, .end = .{ .x = 2, .y = 28 } } }, .{ .arc = .{ .radius = .{ .x = 12, .y = 7 }, .rotation = 35, .sweep = true, .end = .{ .x = 29, .y = 15 } } } };
    for ([_]f32{ 0.0625, 0.125, 0.5 }) |scale| for ([_]v.Stroke{
        .{ .width = 4, .cap = .round, .dashes = &.{ 1.3, 0.7 } },
        .{ .width = 4, .cap = .square, .trim = .{ .start = 0.17, .end = 0.83 } },
        .{ .width = 4, .cap = .round, .dashes = &.{ 3, 1 }, .trim = .{ .start = 0.8, .end = 0.2 } },
    }) |stroke| try compare(&source, &source, .{}, stroke, scale);
}

fn failure(allocator: std.mem.Allocator) !void {
    const path = try v.Path.parseData(allocator, "M1 1Q3 5 5 1L7 5", .{});
    defer path.close() catch unreachable;
    const result = try path.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 32, .height = 24 }, .transform = .{ .xx = 3, .yy = 2, .x0 = 2, .y0 = 3 }, .style = .{ .stroke = .{ .space = .transformed, .width = 2, .dashes = &.{ 3, 1 }, .cap = .round } } });
    defer result.close() catch unreachable;
}
test "transformed strokes preserve allocation and cumulative cut budget failures" {
    try std.testing.checkAllAllocationFailures(a, failure, .{});
    const path = try v.Path.parseData(a, "M1 1H10", .{});
    defer path.close() catch unreachable;
    try std.testing.expectError(error.StrokeBudgetExceeded, path.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 32, .height = 24 }, .transform = .{ .xx = 3 }, .style = .{ .stroke = .{ .space = .transformed, .dashes = &.{ 1e-9, 1e-9 } } }, .limits = .{ .stroke_steps = 128 } }));
}

test "host outlines apply an independent output map without retaining borrowed transforms" {
    const source = try v.Path.parseData(a, "M1 3H7", .{});
    defer source.close() catch unreachable;
    const outline = try v.Path.parseData(a, "M3 5H21V7H3Z", .{});
    defer outline.close() catch unreachable;
    const dashed = try v.Path.parseData(a, "M4 5H8V7H4Z M10 5H14V7H10Z M16 5H20V7H16Z", .{});
    defer dashed.close() catch unreachable;
    for ([_]v.Transform{ .{ .xx = 1.5, .yy = 0.75, .x0 = 1, .y0 = 2 }, .{ .xy = 0.5, .x0 = 1, .y0 = 2 }, .{ .xx = -1, .yx = 0.25, .x0 = 28, .y0 = 2 } }) |output| for ([_]f32{ 1, 1.5, 2 }) |scale| for ([_]bool{ false, true }) |cuts| {
        const options: v.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 32, .height = 24 }, .scale = scale, .transform = .{ .xx = 3, .yy = 2 }, .stroke_output = &output, .style = .{ .stroke = .{ .space = .transformed, .width = 2, .dashes = if (cuts) &.{ 4, 2 } else &.{}, .dash_offset = if (cuts) -1 else 0 } } };
        const actual = try source.prepare(a, options);
        defer actual.close() catch unreachable;
        const expected = try (if (cuts) dashed else outline).prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .viewport = options.viewport, .scale = scale, .transform = output });
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, expected.coverage.pixels, actual.coverage.pixels);
    };
    var output: v.Transform = .{ .xy = 0.5, .x0 = 1, .y0 = 2 };
    const geometry = try v.geometry.compile(source, a, .{ .transform = .{ .xx = 3, .yy = 2 }, .stroke_output = &output, .style = .{ .stroke = .{ .space = .transformed, .width = 2 } } });
    defer geometry.close() catch unreachable;
    const bounds = geometry.bounds;
    output = .{ .x0 = 100 };
    try std.testing.expectEqual(bounds, geometry.bounds);
    try std.testing.expectError(error.InvalidStrokeSpace, source.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 32, .height = 24 }, .stroke_output = &output }));
    try std.testing.expectError(error.InvalidStrokeSpace, v.geometry.compile(source, a, .{ .stroke_output = &output }));
    output.xx = std.math.nan(f64);
    try std.testing.expectError(error.InvalidTransform, source.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 32, .height = 24 }, .stroke_output = &output, .style = .{ .stroke = .{ .space = .transformed } } }));
}

const OutputMutator = struct {
    output: *v.Transform,
    changed: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(context: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!self.changed) {
            self.output.x0 = 4;
            self.changed = true;
        }
        return a.rawAlloc(bytes, alignment, ret);
    }
    fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        a.rawFree(bytes, alignment, ret);
    }
};
test "coverage captures output transform before the first allocator callback" {
    const path = try v.Path.parseData(a, "M2 6H14", .{});
    defer path.close() catch unreachable;
    var output: v.Transform = .{};
    const options: v.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 32, .height = 24 }, .style = .{ .stroke = .{ .space = .transformed, .width = 2 } }, .stroke_output = &output };
    const expected = try path.prepare(a, options);
    defer expected.close() catch unreachable;
    var mutator: OutputMutator = .{ .output = &output };
    const result = try path.prepare(mutator.allocator(), options);
    defer result.close() catch unreachable;
    try std.testing.expect(mutator.changed);
    try std.testing.expectEqualSlices(u8, expected.coverage.pixels, result.coverage.pixels);
}
test "compiled geometry captures output transform before the first allocator callback" {
    const path = try v.Path.parseData(a, "M2 6H14", .{});
    defer path.close() catch unreachable;
    var output: v.Transform = .{};
    const options: v.geometry.Options = .{ .style = .{ .stroke = .{ .space = .transformed, .width = 2 } }, .stroke_output = &output };
    const expected = try v.geometry.compile(path, a, options);
    defer expected.close() catch unreachable;
    var mutator: OutputMutator = .{ .output = &output };
    const result = try v.geometry.compile(path, mutator.allocator(), options);
    defer result.close() catch unreachable;
    try std.testing.expect(mutator.changed);
    try std.testing.expectEqualDeep(expected.bounds, result.bounds);
}
