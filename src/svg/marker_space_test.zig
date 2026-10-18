const std = @import("std");
const v = @import("ziggurat_vector");
const space = @import("marker_space.zig");

fn equal(actual: v.Transform, expected: v.Transform) !void {
    inline for (std.meta.fields(v.Transform)) |field|
        try std.testing.expectApproxEqAbs(@field(expected, field.name), @field(actual, field.name), 1e-12);
}

test "literal host poses remove only uniform scale and preserve reflection" {
    const point: v.Point = .{ .x = 5, .y = 2 };
    const reference: v.Point = .{ .x = 1, .y = 0 };
    try equal(try space.pose(.{ .xx = 2, .yy = 2, .x0 = 3, .y0 = 4 }, point, 0, 2, reference), .{ .xx = 2, .yy = 2, .x0 = 11, .y0 = 8 });
    try equal(try space.pose(.{ .xx = 0, .yx = 2, .xy = -2, .yy = 0, .x0 = 20 }, point, 0, 2, reference), .{ .xx = 0, .yx = 2, .xy = -2, .yy = 0, .x0 = 16, .y0 = 8 });
    try equal(try space.pose(.{ .xx = -2, .yy = 2, .x0 = 24 }, point, 0, 2, reference), .{ .xx = -2, .yy = 2, .x0 = 16, .y0 = 4 });
    try equal(try space.pose(.{ .xx = -2, .yy = 2, .x0 = 24 }, point, std.math.pi / 2.0, 2, reference), .{ .xx = 0, .yx = 2, .xy = 2, .yy = 0, .x0 = 14, .y0 = 2 });
    try equal(try space.pose(.{ .xx = 3, .yx = 4, .xy = -4, .yy = 3 }, .{ .x = 1, .y = 2 }, 0, 5, reference), .{ .xx = 3, .yx = 4, .xy = -4, .yy = 3, .x0 = -8, .y0 = 6 });
    const outer: v.Transform = .{ .xx = 2, .xy = 1, .yy = 3, .x0 = 7, .y0 = 9 };
    try equal((try space.pose(.{ .xx = 2, .yy = 2, .x0 = 3, .y0 = 4 }, point, 0, 2, reference)).then(outer), .{ .xx = 4, .xy = 2, .yy = 6, .x0 = 37, .y0 = 33 });
}

test "conformal normalization never forms an overflowing inverse scale or norm" {
    for ([_]f64{ std.math.floatTrueMin(f64), 1e-300, 1e300, std.math.floatMax(f64) }) |scale| {
        try equal(try space.pose(.{ .xx = scale, .yy = scale }, .{}, 0, 2, .{}), .{ .xx = 2, .yy = 2 });
        try equal(try space.pose(.{ .xx = -scale, .yy = scale }, .{}, 0, 2, .{}), .{ .xx = -2, .yy = 2 });
    }
}

test "nonconformal singular and nonfinite hosts are explicit errors" {
    for ([_]v.Transform{ .{ .xx = 2, .yy = 3 }, .{ .xy = 0.5 }, .{ .xx = 0, .yy = 0 }, .{ .xx = 1, .yx = 1, .xy = 0, .yy = 0 }, .{ .xx = 1, .yy = 1 + std.math.floatEps(f64) } }) |host|
        try std.testing.expectError(error.UnsupportedMarkerStrokeSpace, space.pose(host, .{}, 0, 1, .{}));
    try std.testing.expectError(error.InvalidTransform, space.pose(.{ .x0 = std.math.inf(f64) }, .{}, 0, 1, .{}));
    try std.testing.expectError(error.InvalidTransform, space.pose(.{}, .{}, 0, std.math.inf(f64), .{}));
}

test "existing matrix products retain exact conformal classification" {
    var host: v.Transform = .{};
    for (0..64) |i| {
        const angle = @as(f64, @floatFromInt(i)) / 11;
        const sine = @sin(angle);
        const cosine = @cos(angle);
        host = host.then(.{ .xx = cosine, .yx = sine, .xy = -sine, .yy = cosine }).then(.{ .xx = -1.125, .yy = 1.125 });
        _ = try space.pose(host, .{}, angle, 2, .{});
    }
    std.debug.print("marker host private values transform={d} result={d};64 composed conformal hosts accepted\n", .{ @sizeOf(v.Transform), @sizeOf(@TypeOf(space.pose(.{}, .{}, 0, 1, .{}))) });
}
