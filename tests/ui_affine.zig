const std = @import("std");
const a = @import("affine");

fn expectPoint(expected: a.Point, actual: a.Point) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 1e-8);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 1e-8);
}
fn expectRect(expected: a.Rect, actual: a.Rect) !void {
    try expectPoint(.{ .x = expected.x, .y = expected.y }, .{ .x = actual.x, .y = actual.y });
    try expectPoint(.{ .x = expected.width, .y = expected.height }, .{ .x = actual.width, .y = actual.height });
}

test "composition applies local then parent, and vectors omit translations" {
    const scale = try a.Affine.scaling(.{ .x = 2, .y = -3 });
    const rotate = try a.Affine.rotation(std.math.pi / 2.0);
    const move = try a.Affine.translation(.{ .x = 10, .y = 20 });
    const combined = try (try scale.then(rotate)).then(move);
    try expectPoint(.{ .x = 16, .y = 22 }, try combined.mapPoint(.{ .x = 1, .y = 2 }));
    try expectPoint(.{ .x = 6, .y = 2 }, try combined.mapVector(.{ .x = 1, .y = 2 }));
    const space = try (try a.Space.init(move)).child(try scale.then(rotate));
    try expectPoint(try combined.mapPoint(.{ .x = 1, .y = 2 }), try space.windowPoint(.{ .x = 1, .y = 2 }));
    try expectPoint(.{ .x = 1, .y = 2 }, try space.localPoint(.{ .x = 16, .y = 22 }));
}

test "inverse round trips translation, rotation, shear and reflection" {
    const transforms = [_]a.Affine{
        .{},
        .{ .x0 = -200, .y0 = 90 },
        .{ .xx = 3, .yy = 0.125 },
        .{ .xx = -2, .yy = 0.5, .x0 = 17 },
        .{ .xx = 1, .xy = 0.7, .yx = -0.3, .yy = 1, .y0 = 29 },
        try a.Affine.rotation(0.71),
    };
    for (transforms) |transform| {
        const space = try a.Space.init(transform);
        for (0..40) |index| {
            const point: a.Point = .{ .x = @as(f64, @floatFromInt(index)) * 13.7 - 250, .y = 9.125 - @as(f64, @floatFromInt(index)) * 0.9 };
            try expectPoint(point, try space.localPoint(try space.windowPoint(point)));
            try expectPoint(point, try space.localVector(try space.windowVector(point)));
        }
    }
}

test "singular, ill conditioned, nonfinite and overflowing inverses reject" {
    const invalid = [_]a.Affine{
        .{ .xx = 0 },
        .{ .xx = 1, .xy = 1, .yx = 1, .yy = 1 },
        .{ .xx = 1, .xy = 1, .yx = 1, .yy = 1 + 1e-13 },
        .{ .xx = std.math.nan(f64) },
        .{ .x0 = std.math.inf(f64) },
        .{ .xx = 1e-30, .yy = 1e-30 },
        .{ .xx = a.max_component * 2 },
        .{ .xx = 1e-6, .yy = 1e-6, .x0 = a.max_component },
    };
    for (invalid) |transform| try std.testing.expectError(error.InvalidTransform, a.Space.init(transform));
    try std.testing.expectError(error.InvalidTransform, a.Affine.rotation(std.math.inf(f64)));
    try std.testing.expectError(error.InvalidTransform, a.Affine.scaling(.{ .x = 0, .y = 1 }));
    try std.testing.expectError(error.InvalidTransform, (a.Affine{ .xx = 1e9 }).then(.{ .xx = 1e9 }));
    try std.testing.expectError(error.GeometryOverflow, (a.Affine{ .xx = 2 }).mapPoint(.{ .x = a.max_component }));
}

test "native narrowing validates the exact shared forward matrix" {
    const original: a.Affine = .{ .xx = 1, .xy = 1, .yx = 1, .yy = 1 + 1e-8 };
    try original.validate();
    try std.testing.expectError(error.InvalidTransform, original.narrowed());
    const narrowed = try (a.Affine{ .xx = -1.123456789, .yy = 0.7654321, .x0 = 1.23456789 }).narrowed();
    try std.testing.expectEqual(@as(f64, @as(f32, -1.123456789)), narrowed.xx);
    const space = try a.Space.init(narrowed);
    try expectPoint(.{ .x = 11, .y = 3 }, try space.localPoint(try space.windowPoint(.{ .x = 11, .y = 3 })));
}

test "rotated hit uses inverse geometry instead of its bounding box" {
    const space = try a.Space.init(try a.Affine.rotation(std.math.pi / 4.0));
    const local: a.Rect = .{ .width = 10, .height = 10 };
    const bounds = try space.windowBounds(local);
    try std.testing.expect(bounds.contains(.{ .x = 6, .y = 1 }));
    try std.testing.expect(!(try space.contains(local, .{ .x = 6, .y = 1 })));
    try std.testing.expect(try space.contains(local, .{ .x = 0, .y = 7 }));
    const reflected = try a.Space.init(.{ .xx = -1, .x0 = 10 });
    try std.testing.expect(try reflected.contains(local, .{ .x = 10, .y = 0 }));
    try std.testing.expect(!(try reflected.contains(local, .{ .x = 0, .y = 0 })));
}

test "source and ancestor clips remain in their own spaces" {
    var table = a.GeometryTable(4, 4).init();
    const root_clip = try table.addClip(.identity, null, .{ .width = 10, .height = 10 });
    const child = try table.addChild(.identity, .{ .x0 = -100 });
    const source_clip = try table.addClip(child, root_clip, .{ .width = 200, .height = 20 });
    const ref: a.Ref = .{ .space = child, .clip = source_clip };
    const outside_original_window: a.Rect = .{ .x = 100, .width = 20, .height = 20 };
    try std.testing.expect(try table.contains(ref, outside_original_window, .{ .x = 5, .y = 5 }));
    try std.testing.expect(!(try table.contains(ref, outside_original_window, .{ .x = 15, .y = 5 })));
    try expectRect(.{ .width = 10, .height = 10 }, (try table.visibleBounds(ref, outside_original_window)).?);
    const shear = try table.addChild(child, .{ .xy = 0.5, .x0 = 110 });
    const nested: a.Ref = .{ .space = shear, .clip = source_clip };
    const point = try (try table.getSpace(shear)).windowPoint(.{ .x = -7, .y = 4 });
    try expectPoint(.{ .x = 5, .y = 4 }, point);
    try std.testing.expect(try table.contains(nested, .{ .x = -10, .width = 10, .height = 10 }, point));
}

fn polygonContains(polygon: *const a.Polygon, point: a.Point) bool {
    var positive = false;
    var negative = false;
    for (polygon.points(), 0..) |first, index| {
        const second = polygon.storage[(index + 1) % polygon.len];
        const cross = (second.x - first.x) * (point.y - first.y) - (second.y - first.y) * (point.x - first.x);
        positive = positive or cross > 1e-9;
        negative = negative or cross < -1e-9;
    }
    return polygon.len >= 3 and !(positive and negative);
}

test "convex visible polygon agrees with independent sampled inverse hit" {
    var table = a.GeometryTable(4, 4).init();
    const clip = try table.addClip(.identity, null, .{ .x = -4, .y = -3, .width = 8, .height = 6 });
    const rotated = try table.addSpace(try a.Affine.rotation(0.68));
    const reflected = try table.addSpace(try (a.Affine{ .xx = -1, .xy = 0.3, .x0 = 1 }).then(try a.Affine.rotation(-0.23)));
    const local_clip = try table.addClip(reflected, clip, .{ .x = -4, .y = -3, .width = 8, .height = 6 });
    const ref: a.Ref = .{ .space = rotated, .clip = local_clip };
    const local: a.Rect = .{ .x = -4, .y = -3, .width = 8, .height = 6 };
    var polygon: a.Polygon = .{};
    try table.visiblePolygon(ref, local, &polygon);
    try std.testing.expect(polygon.len > 4);
    for (0..50) |row| for (0..50) |column| {
        const point: a.Point = .{ .x = @as(f64, @floatFromInt(column)) * 0.2 - 5.013, .y = @as(f64, @floatFromInt(row)) * 0.2 - 5.017 };
        try std.testing.expectEqual(try table.contains(ref, local, point), polygonContains(&polygon, point));
    };
}

test "all thirty two rotated clips stay within a proven polygon capacity" {
    var table = a.GeometryTable(33, 32).init();
    var parent: ?a.ClipId = null;
    for (0..32) |index| {
        const space = try table.addSpace(try a.Affine.rotation(@as(f64, @floatFromInt(index)) * std.math.pi / 64));
        parent = try table.addClip(space, parent, .{ .x = -1, .y = -1, .width = 2, .height = 2 });
    }
    var polygon: a.Polygon = .{};
    try table.visiblePolygon(.{ .clip = parent }, .{ .x = -2, .y = -2, .width = 4, .height = 4 }, &polygon);
    try std.testing.expectEqual(@as(usize, 128), polygon.len);
    try std.testing.expect(polygon.bounds() != null);
    try std.testing.expect(try table.contains(.{ .clip = parent }, .{ .x = -2, .y = -2, .width = 4, .height = 4 }, .{}));
}

test "table overflow, depth and invalid candidates never publish partial entries" {
    var table = a.GeometryTable(2, 33).init();
    const mark = table.checkpoint();
    try std.testing.expectError(error.InvalidTransform, table.addSpace(.{ .xx = 0 }));
    try std.testing.expectEqualDeep(mark, table.checkpoint());
    _ = try table.addSpace(.{ .x0 = 1 });
    try std.testing.expectError(error.SpacesFull, table.addSpace(.{}));
    var parent: ?a.ClipId = null;
    for (0..32) |_| parent = try table.addClip(.identity, parent, .{ .width = 10, .height = 10 });
    const full = table.checkpoint();
    try std.testing.expectError(error.ClipDepthExceeded, table.addClip(.identity, parent, .{ .width = 10, .height = 10 }));
    try std.testing.expectError(error.InvalidGeometry, table.addClip(.identity, null, .{ .width = -1, .height = 10 }));
    try std.testing.expectEqualDeep(full, table.checkpoint());
    var small = a.GeometryTable(1, 1).init();
    _ = try small.addClip(.identity, null, .{ .width = 1, .height = 1 });
    try std.testing.expectError(error.ClipsFull, small.addClip(.identity, null, .{}));
}

test "rollback removes candidate geometry while preserving committed values" {
    var table = a.GeometryTable(4, 4).init();
    const first = try table.addClip(.identity, null, .{ .width = 10, .height = 10 });
    const mark = table.checkpoint();
    const child = try table.addSpace(.{ .x0 = 50 });
    const second = try table.addClip(child, first, .{ .width = 10, .height = 10 });
    try std.testing.expectError(error.InvalidCheckpoint, table.rollback(.{ .spaces = 1, .clips = 2 }));
    try table.rollback(mark);
    try std.testing.expectError(error.InvalidSpace, table.getSpace(child));
    try std.testing.expectError(error.InvalidClip, table.contains(.{ .clip = second }, .{ .width = 10, .height = 10 }, .{}));
    try std.testing.expect(try table.contains(.{ .clip = first }, .{ .width = 10, .height = 10 }, .{ .x = 1, .y = 1 }));
}

test "invalid query leaves output unchanged and corrupted cycles are bounded" {
    var table = a.GeometryTable(2, 2).init();
    const clip = try table.addClip(.identity, null, .{ .width = 10, .height = 10 });
    var output: a.Polygon = .{};
    try table.visiblePolygon(.{}, .{ .width = 2, .height = 3 }, &output);
    const old = output;
    try std.testing.expectError(error.InvalidSpace, table.visiblePolygon(.{ .space = @enumFromInt(3) }, .{}, &output));
    try std.testing.expectEqualDeep(old.points(), output.points());
    table.clips[0].parent = clip;
    try std.testing.expectError(error.InvalidClip, table.visiblePolygon(.{ .clip = clip }, .{}, &output));
    try std.testing.expectEqualDeep(old.points(), output.points());
}

test "empty clipping and caret bounds keep explicit geometry semantics" {
    var table = a.GeometryTable(1, 1).init();
    const clip = try table.addClip(.identity, null, .{ .width = 0, .height = 5 });
    try std.testing.expectEqual(@as(?a.Rect, null), try table.visibleBounds(.{ .clip = clip }, .{ .width = 10, .height = 10 }));
    try std.testing.expect(!(try table.contains(.{ .clip = clip }, .{ .width = 10, .height = 10 }, .{})));
    const space = try a.Space.init(.{ .xx = 0, .xy = -2, .yx = 3, .yy = 0, .x0 = 30, .y0 = 20 });
    try expectRect(.{ .x = 10, .y = 26, .width = 10, .height = 3 }, try space.windowCaret(.{ .x = 2, .y = 5, .width = 1, .height = 5 }));
    try expectPoint(.{ .x = 2, .y = -3 }, try space.localVector(try space.windowVector(.{ .x = 2, .y = -3 })));
}

test "large valid extents and remote pointer misses do not corrupt geometry" {
    const space = try a.Space.init(try a.Affine.rotation(std.math.pi / 4.0));
    const bounds = try space.windowBounds(.{ .x = -5e11, .y = -5e11, .width = 1e12, .height = 1e12 });
    try bounds.validate();
    try std.testing.expect(bounds.width > a.max_component);
    const tiny = try a.Space.init(.{ .xx = 1e-6, .yy = 1e-6, .x0 = 1e6 });
    try std.testing.expect(!(try tiny.contains(.{ .width = 10, .height = 10 }, .{ .x = -1 })));
    try std.testing.expectError(error.GeometryOverflow, tiny.localPoint(.{ .x = -1 }));
}

test "identity default table and float UI geometry adapt without core imports" {
    var table: a.GeometryTable(1, 0) = .{};
    const FloatPoint = struct { x: f32, y: f32 };
    const FloatRect = struct { x: f32, y: f32, width: f32, height: f32 };
    const local = a.Rect.from(FloatRect{ .x = 1.25, .y = -2.5, .width = 5, .height = 8 });
    const point = a.Point.from(FloatPoint{ .x = 2.25, .y = 1.5 });
    try std.testing.expect(try table.contains(.{}, local, point));
    try expectRect(local, (try table.visibleBounds(.{}, local)).?);
    try std.testing.expectError(error.ClipsFull, table.addClip(.identity, null, local));
}

test "zero width system carets clip as segments including a boundary anchor" {
    var table = a.GeometryTable(2, 1).init();
    const rotated = try table.addSpace(.{ .xx = 0, .xy = -2, .yx = 3, .yy = 0, .x0 = 30 });
    const clip = try table.addClip(rotated, null, .{ .width = 10, .height = 10 });
    const ref: a.Ref = .{ .space = rotated, .clip = clip };
    try expectRect(.{ .x = 10, .y = 15, .width = 20, .height = 0 }, (try table.visibleCaretBounds(ref, .{ .x = 5, .y = -2, .width = 0, .height = 14 })).?);
    try expectRect(.{ .x = 10, .y = 30, .width = 20, .height = 0 }, (try table.visibleCaretBounds(ref, .{ .x = 10, .height = 10 })).?);
    try std.testing.expectEqual(@as(?a.Rect, null), try table.visibleCaretBounds(ref, .{ .x = 11, .height = 10 }));
}
