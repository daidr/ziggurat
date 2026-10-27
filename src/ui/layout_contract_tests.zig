const std = @import("std");
const layout = @import("layout.zig");
const Rect = layout.Rect;

const sentinel: Rect = .{ .x = -9, .y = -8, .width = 7, .height = 6 };
const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };

test "percentage maximum uses padded inner main extent before gaps" {
    var output: [2]Rect = undefined;
    const result = try layout.arrange(.{ .x = 5, .y = 7, .width = 200, .height = 40 }, .{ .axis = .row, .padding = layout.Insets.all(10), .gap = 20 }, &.{
        .{ .preferred = .{ .width = 20 }, .grow = 2, .main_max_percent = 50 },
        .{ .preferred = .{ .width = 20 }, .grow = 1 },
    }, &output);
    try std.testing.expectEqual(@as(f32, 90), output[0].width);
    try std.testing.expectEqual(@as(f32, 70), output[1].width);
    try std.testing.expectEqual(@as(f32, 125), output[1].x);
    try std.testing.expectEqual(@as(f32, 200), result.content_size.width);

    _ = try layout.arrange(.{ .x = 0, .y = 0, .width = 50, .height = 120 }, .{ .padding = .{ .top = 10, .bottom = 10 }, .gap = 10 }, &.{
        .{ .preferred = .{ .height = 80 }, .main_max_percent = 25, .shrink = 0 },
        .{ .preferred = .{ .height = 75 } },
    }, &output);
    try std.testing.expectEqual(@as(f32, 25), output[0].height);
    try std.testing.expectEqual(@as(f32, 65), output[1].height);
}

test "automatic content minimum is capped while explicit minima win maximum" {
    var output: [1]Rect = undefined;
    var item: layout.Item = .{ .preferred = .{ .width = 120 }, .content_minimum = .{ .width = 80 }, .main_max_percent = 40 };
    _ = try layout.arrange(bounds, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 40), output[0].width);
    item.main_minimum = 80;
    _ = try layout.arrange(bounds, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 80), output[0].width);
    item.main_minimum = null;
    item.constraints.min.width = 75;
    _ = try layout.arrange(bounds, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 75), output[0].width);

    item = .{ .preferred = .{ .width = 120 }, .content_minimum = .{ .width = 100 }, .constraints = .{ .max = .{ .width = 40 } } };
    _ = try layout.arrange(bounds, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 40), output[0].width);
    item.main_minimum = 80;
    _ = try layout.arrange(bounds, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 80), output[0].width);
}

test "explicit zero permits shrink below intrinsic content without changing cross floor" {
    var output: [2]Rect = undefined;
    const result = try layout.arrange(bounds, .{ .axis = .row }, &.{
        .{ .preferred = .{ .width = 80, .height = 20 }, .content_minimum = .{ .width = 80, .height = 20 }, .main_minimum = 0, .alignment = .start },
        .{ .preferred = .{ .width = 100 }, .shrink = 0 },
    }, &output);
    try std.testing.expectEqual(@as(f32, 0), output[0].width);
    try std.testing.expectEqual(@as(f32, 20), output[0].height);
    try std.testing.expectEqual(@as(f32, 100), output[1].width);
    try std.testing.expectEqual(@as(f32, 0), result.overflow.width);
}

test "explicit minima remain visible overflow rather than violating the floor" {
    var output: [2]Rect = undefined;
    const result = try layout.arrange(bounds, .{ .axis = .row, .overflow = .visible }, &.{
        .{ .preferred = .{ .width = 80 }, .main_minimum = 80, .main_max_percent = 40 },
        .{ .preferred = .{ .width = 50 }, .shrink = 0 },
    }, &output);
    try std.testing.expectEqual(@as(f32, 80), output[0].width);
    try std.testing.expectEqual(@as(f32, 130), result.content_size.width);
    try std.testing.expectEqual(@as(f32, 30), result.overflow.width);
    try std.testing.expectEqual(@as(?Rect, null), result.clip);
}

test "percentages include zero and values above one hundred" {
    var output: [1]Rect = undefined;
    var item: layout.Item = .{ .preferred = .{ .width = 200 }, .main_max_percent = 150, .shrink = 0 };
    const result = try layout.arrange(bounds, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 150), output[0].width);
    try std.testing.expectEqual(@as(f32, 50), result.overflow.width);
    item.main_max_percent = 0;
    _ = try layout.arrange(bounds, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 0), output[0].width);
    item.preferred.width = 200;
    item.main_max_percent = std.math.floatMax(f32);
    // Resolving a very large percentage must not first overflow f32.
    _ = try layout.arrange(.{ .x = 0, .y = 0, .width = 1e20, .height = 10 }, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 200), output[0].width);
}

test "unknown parent measurement ignores percentages and resolves absolute bounds" {
    const item: layout.Item = .{
        .preferred = .{ .width = 200, .height = 30 },
        .content_minimum = .{ .width = 80, .height = 10 },
        .main_max_percent = 25,
        .constraints = .{ .max = .{ .width = 120, .height = 20 } },
    };
    const measured = try layout.measure(.{ .axis = .row, .padding = layout.Insets.all(5) }, &.{item});
    try std.testing.expectEqual(layout.Size{ .width = 90, .height = 20 }, measured.minimum);
    try std.testing.expectEqual(layout.Size{ .width = 130, .height = 30 }, measured.preferred);
    var output: [1]Rect = undefined;
    _ = try layout.arrange(bounds, .{ .axis = .row }, &.{item}, &output);
    try std.testing.expectEqual(@as(f32, 25), output[0].width);
    var explicit = item;
    explicit.main_minimum = 80;
    const explicit_measured = try layout.measure(.{ .axis = .row }, &.{explicit});
    try std.testing.expectEqual(@as(f32, 80), explicit_measured.minimum.width);
    _ = try layout.arrange(bounds, .{ .axis = .row }, &.{explicit}, &output);
    try std.testing.expectEqual(@as(f32, 80), output[0].width);
}

test "measurement is intrinsic and does not iterate a percentage sized parent" {
    const items = [_]layout.Item{
        .{ .preferred = .{ .width = 80, .height = 10 }, .main_max_percent = 25 },
        .{ .preferred = .{ .width = 40, .height = 20 }, .main_max_percent = 50 },
    };
    const options: layout.Options = .{ .axis = .row, .padding = layout.Insets.all(5), .gap = 10 };
    const measured = try layout.measure(options, &items);
    try std.testing.expectEqual(layout.Size{ .width = 20, .height = 10 }, measured.minimum);
    try std.testing.expectEqual(layout.Size{ .width = 140, .height = 30 }, measured.preferred);
    var output: [2]Rect = undefined;
    const result = try layout.arrange(.{ .x = 0, .y = 0, .width = measured.preferred.width, .height = measured.preferred.height }, options, &items, &output);
    try std.testing.expectEqual(@as(f32, 32.5), output[0].width);
    try std.testing.expectEqual(@as(f32, 40), output[1].width);
    try std.testing.expectEqual(@as(f32, 92.5), result.content_size.width);
}

test "row baseline group measures ascent and descent before arranging" {
    const items = [_]layout.Item{
        .{ .preferred = .{ .width = 10, .height = 12 }, .constraints = .{ .min = .{ .height = 10 } }, .baseline = 9 },
        .{ .preferred = .{ .width = 10, .height = 20 }, .constraints = .{ .min = .{ .height = 8 } }, .baseline = 5 },
    };
    const measured = try layout.measure(.{ .axis = .row }, &items);
    try std.testing.expectEqual(@as(f32, 12), measured.minimum.height);
    try std.testing.expectEqual(@as(f32, 24), measured.preferred.height);
    var output: [2]Rect = undefined;
    const result = try layout.arrange(.{ .x = 4, .y = 6, .width = 30, .height = 20 }, .{ .axis = .row }, &items, &output);
    try std.testing.expectEqual(@as(f32, 6), output[0].y);
    try std.testing.expectEqual(@as(f32, 10), output[1].y);
    try std.testing.expectEqual(output[0].y + items[0].baseline.?, output[1].y + items[1].baseline.?);
    try std.testing.expectEqual(@as(f32, 24), result.content_size.height);
    try std.testing.expectEqual(@as(f32, 4), result.overflow.height);
    // Baselines do not stretch to the available cross extent.
    try std.testing.expectEqual(@as(f32, 12), output[0].height);
    try std.testing.expectEqual(@as(f32, 20), output[1].height);
}

test "cross baseline also supports columns with explicit numeric offsets" {
    var output: [2]Rect = undefined;
    const items = [_]layout.Item{
        .{ .preferred = .{ .width = 12, .height = 10 }, .baseline = 9, .alignment = .end },
        .{ .preferred = .{ .width = 20, .height = 10 }, .baseline = 5 },
    };
    const measured = try layout.measure(.{ .padding = .{ .left = 3, .right = 7 } }, &items);
    try std.testing.expectEqual(@as(f32, 19), measured.minimum.width);
    try std.testing.expectEqual(@as(f32, 34), measured.preferred.width);
    const result = try layout.arrange(.{ .x = 10, .y = 20, .width = 25, .height = 30 }, .{ .padding = .{ .left = 3, .right = 7 } }, &items, &output);
    try std.testing.expectEqual(@as(f32, 13), output[0].x);
    try std.testing.expectEqual(@as(f32, 17), output[1].x);
    try std.testing.expectEqual(@as(f32, 9), result.overflow.width);
}

test "baseline contribution is declaration independent and coexists with normal alignment" {
    const items = [_]layout.Item{
        .{ .preferred = .{ .width = 10, .height = 12 }, .baseline = 9 },
        .{ .preferred = .{ .width = 10, .height = 20 }, .baseline = 5 },
        .{ .preferred = .{ .width = 10, .height = 4 }, .alignment = .center },
    };
    var output: [3]Rect = undefined;
    const result = try layout.arrange(bounds, .{ .axis = .row }, &items, &output);
    try std.testing.expectEqual(@as(f32, 48), output[2].y);
    var reversed: [3]Rect = undefined;
    const reverse_result = try layout.arrange(bounds, .{ .axis = .row }, &.{ items[2], items[1], items[0] }, &reversed);
    try std.testing.expectEqual(result.content_size, reverse_result.content_size);
    try std.testing.expectEqual(output[0].y, reversed[2].y);
    try std.testing.expectEqual(output[1].y, reversed[1].y);
    try std.testing.expectEqual(output[2].y, reversed[0].y);
}

test "baseline establishes a minimum cross extent and permits a zero offset" {
    var output: [2]Rect = undefined;
    const items = [_]layout.Item{
        .{ .preferred = .{ .width = 10 }, .baseline = 9 },
        .{ .preferred = .{ .width = 10, .height = 3 }, .baseline = 0 },
    };
    const result = try layout.arrange(bounds, .{ .axis = .row }, &items, &output);
    try std.testing.expectEqual(@as(f32, 9), output[0].height);
    try std.testing.expectEqual(@as(f32, 9), output[1].y);
    try std.testing.expectEqual(@as(f32, 12), result.content_size.height);
}

test "invalid extended constraints preserve all caller output and absolute validation" {
    var output = @as([2]Rect, @splat(sentinel));
    const invalid_items = [_]layout.Item{
        .{ .preferred = .{}, .main_minimum = -1 },
        .{ .preferred = .{}, .main_minimum = std.math.inf(f32) },
        .{ .preferred = .{}, .main_max_percent = -1 },
        .{ .preferred = .{}, .main_max_percent = std.math.nan(f32) },
        .{ .preferred = .{}, .main_max_percent = std.math.inf(f32) },
        .{ .preferred = .{}, .content_minimum = .{ .width = -1 } },
        .{ .preferred = .{}, .baseline = -1 },
        .{ .preferred = .{}, .baseline = std.math.nan(f32) },
        .{ .preferred = .{}, .baseline = 5, .constraints = .{ .max = .{ .height = 4 } } },
        .{ .preferred = .{}, .main_minimum = 20, .constraints = .{ .min = .{ .width = 8 }, .max = .{ .width = 4 } } },
    };
    for (invalid_items) |invalid| {
        try std.testing.expectError(error.InvalidConstraints, layout.arrange(bounds, .{ .axis = .row }, &.{ .{ .preferred = .{ .width = 10 } }, invalid }, &output));
        try std.testing.expectEqualSlices(Rect, &(@as([2]Rect, @splat(sentinel))), &output);
        try std.testing.expectError(error.InvalidConstraints, layout.measure(.{ .axis = .row }, &.{invalid}));
    }
}

test "late coordinate and result overflows do not partially publish rectangles" {
    var output = @as([3]Rect, @splat(sentinel));
    const maximum = std.math.floatMax(f32);
    const items = [_]layout.Item{
        .{ .preferred = .{ .width = 1 }, .shrink = 0 },
        .{ .preferred = .{ .width = maximum }, .shrink = 0 },
    };
    try std.testing.expectError(error.GeometryOverflow, layout.arrange(bounds, .{ .axis = .row, .gap = maximum }, &items, &output));
    try std.testing.expectEqualSlices(Rect, &(@as([3]Rect, @splat(sentinel))), &output);
    try std.testing.expectError(error.GeometryOverflow, layout.arrange(bounds, .{ .padding = .{ .left = maximum, .right = maximum } }, &.{.{ .preferred = .{} }}, &output));
    try std.testing.expectEqualSlices(Rect, &(@as([3]Rect, @splat(sentinel))), &output);
    try std.testing.expectError(error.GeometryOverflow, layout.arrange(.{ .x = maximum, .y = 0, .width = maximum, .height = 1 }, .{}, &.{}, &output));
    try std.testing.expectEqualSlices(Rect, &(@as([3]Rect, @splat(sentinel))), &output);
    _ = try layout.arrange(bounds, .{}, &.{.{ .preferred = .{} }}, &output);
    try std.testing.expectEqual(sentinel, output[1]);
    try std.testing.expectEqual(sentinel, output[2]);
}

test "empty measurement keeps padding excludes gaps and rejects invalid geometry" {
    const empty = try layout.measure(.{ .axis = .row, .padding = layout.Insets.all(10), .gap = std.math.floatMax(f32) }, &.{});
    try std.testing.expectEqual(layout.Size{ .width = 20, .height = 20 }, empty.minimum);
    try std.testing.expectEqual(empty.minimum, empty.preferred);
    try std.testing.expectError(error.InvalidGeometry, layout.measure(.{ .gap = -1 }, &.{}));
    try std.testing.expectError(error.InvalidGeometry, layout.measure(.{ .padding = .{ .right = std.math.nan(f32) } }, &.{}));
    try std.testing.expectError(error.GeometryOverflow, layout.measure(.{ .padding = .{ .top = std.math.floatMax(f32), .bottom = std.math.floatMax(f32) } }, &.{}));
    const too_many: [layout.max_items + 1]layout.Item = @splat(.{ .preferred = .{} });
    try std.testing.expectError(error.TooManyItems, layout.measure(.{}, &too_many));
}

test "all fixed capacity items resolve percentage caps without DIP iteration" {
    var items: [layout.max_items]layout.Item = undefined;
    for (&items, 0..) |*item, index| item.* = .{
        .preferred = .{ .width = 1, .height = 12 },
        .content_minimum = .{ .width = 1, .height = 4 },
        .grow = 1,
        .main_max_percent = if (index % 2 == 0) @as(f32, 0.1) else null,
        .baseline = if (index % 3 == 0) @as(f32, 9) else null,
    };
    var output: [layout.max_items]Rect = undefined;
    const result = try layout.arrange(.{ .x = 0, .y = 0, .width = 4096, .height = 20 }, .{ .axis = .row }, &items, &output);
    try std.testing.expectApproxEqAbs(@as(f32, 4096), result.content_size.width, 0.001);
    for (output, 0..) |rectangle, index| {
        try std.testing.expect(layout.validRect(rectangle));
        if (index % 2 == 0) try std.testing.expectApproxEqAbs(@as(f32, 4.096), rectangle.width, 0.00001);
        if (index > 0) try std.testing.expectApproxEqAbs(output[index - 1].x + output[index - 1].width, rectangle.x, 0.001);
    }
}

test "saturating shrink preserves tiny hard floors beside huge preferred extents" {
    const floor: f32 = 1e-30;
    const items = [_]layout.Item{
        .{ .preferred = .{ .width = 1e30 }, .main_minimum = floor },
        .{ .preferred = .{ .width = 1e20 }, .constraints = .{ .min = .{ .width = floor } } },
    };
    const zero_main: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 1 };
    var output: [2]Rect = undefined;
    const result = try layout.arrange(zero_main, .{ .axis = .row }, &items, &output);
    try std.testing.expectEqual(floor, output[0].width);
    try std.testing.expectEqual(floor, output[1].width);
    try std.testing.expectEqual(@as(f32, floor * 2), result.overflow.width);
    var reversed: [2]Rect = undefined;
    const reversed_result = try layout.arrange(zero_main, .{ .axis = .row }, &.{ items[1], items[0] }, &reversed);
    try std.testing.expectEqualSlices(Rect, &output, &reversed);
    try std.testing.expectEqual(result.content_size, reversed_result.content_size);
}

test "growth keeps exact resolved caps with extreme weights and tiny extents" {
    var output: [3]Rect = undefined;
    const result = try layout.arrange(bounds, .{ .axis = .row }, &.{
        .{ .preferred = .{ .width = 1e-30 }, .grow = std.math.floatMax(f32), .main_max_percent = 0.1 },
        .{ .preferred = .{ .width = 1e-30 }, .grow = 1e20, .constraints = .{ .max = .{ .width = 0.2 } } },
        .{ .preferred = .{ .width = 1e-30 }, .grow = 1e-30 },
    }, &output);
    try std.testing.expect(output[0].width <= @as(f32, 0.1));
    try std.testing.expect(output[1].width <= @as(f32, 0.2));
    try std.testing.expect(output[2].width >= @as(f32, 1e-30));
    try std.testing.expectApproxEqAbs(@as(f32, 100), result.content_size.width, 0.00001);
}
