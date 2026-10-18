const std = @import("std");
const v = @import("ziggurat_vector");
const t = @import("marker_topology.zig");
const Work = struct {
    visits: usize = 0,
    limit: usize = std.math.maxInt(usize),
    cancelled: bool = false,
    pub fn visit(self: *Work) !void {
        if (self.cancelled) return error.Cancelled;
        if (self.visits == self.limit) return error.NodeWorkExceeded;
        self.visits += 1;
    }
};
const Expected = struct { x: f64, y: f64, angle: ?f64, kind: t.Kind };
fn e(x: f64, y: f64, angle: ?f64, kind: t.Kind) Expected {
    return .{ .x = x, .y = y, .angle = angle, .kind = kind };
}
const pi: f64 = std.math.pi;
fn verify(data: []const u8, expected: []const Expected) !void {
    const path = try v.Path.parseData(std.testing.allocator, data, .{});
    defer path.close() catch unreachable;
    var work: Work = .{};
    const topology = try t.inspect(&work, path.commands);
    try t.validate(&work, path.commands);
    var cursor = t.Cursor.init(path.commands, topology);
    var count: usize = 0;
    while (try cursor.next(&work)) |role| {
        try std.testing.expect(count < expected.len);
        const want = expected[count];
        try std.testing.expectEqual(v.Point{ .x = want.x, .y = want.y }, role.point);
        try std.testing.expectEqual(want.kind, role.kind);
        if (want.angle) |angle| {
            try std.testing.expect(role.direction != null);
            try std.testing.expectApproxEqAbs(angle, role.direction.?, 1e-12);
        } else try std.testing.expectEqual(@as(?f64, null), role.direction);
        count += 1;
    }
    try std.testing.expectEqual(expected.len, count);
    // Every full pass is bounded. Each described M delimiter can be observed
    // twice; there is no bound proportional to vertices times raw commands.
    try std.testing.expect(work.visits <= 5 * path.commands.len + 2 * topology.subpaths + expected.len);
}

test "literal roles unify omitted arity closed seams and whole path subpath boundaries" {
    const cases = [_]struct { data: []const u8, roles: []const Expected }{
        .{ .data = "M8 8", .roles = &.{ e(8, 8, 0, .start), e(8, 8, 0, .end) } },
        .{ .data = "M8 8A7 7 0 1 1 8 8A0 7 0 0 1 8 8", .roles = &.{ e(8, 8, 0, .start), e(8, 8, 0, .end) } },
        .{ .data = "M8 8A7 7 0 0 1 8 8H16A7 7 0 1 0 16 8", .roles = &.{ e(8, 8, 0, .start), e(16, 8, 0, .end) } },
        .{ .data = "M8 8A7 7 0 0 1 8 8A0 7 0 0 1 16 8", .roles = &.{ e(8, 8, 0, .start), e(16, 8, 0, .end) } },
        .{ .data = "M8 8C16 8 8 0 8 8A7 7 0 0 1 8 8", .roles = &.{ e(8, 8, 0, .start), e(8, 8, pi / 2, .end) } },
        .{ .data = "M8 8A7 7 0 0 1 8 8Z", .roles = &.{ e(8, 8, 0, .start), e(8, 8, 0, .end) } },
        .{ .data = "M8 8H16A7 7 0 0 1 16 8V16H8Z", .roles = &.{ e(8, 8, -pi / 4, .start), e(16, 8, pi / 4, .mid), e(16, 16, 3 * pi / 4, .mid), e(8, 16, 5 * pi / 4, .mid), e(8, 8, -pi / 4, .end) } },
        .{ .data = "M4 0A8 8 0 0 1 12 8A7 7 0 0 1 12 8Z", .roles = &.{ e(4, 0, -3 * pi / 8, .start), e(12, 8, 7 * pi / 8, .mid), e(4, 0, -3 * pi / 8, .end) } },
        .{ .data = "M4 4H12M20 4V12", .roles = &.{ e(4, 4, 0, .start), e(12, 4, 0, .mid), e(20, 4, pi / 2, .mid), e(20, 12, pi / 2, .end) } },
        .{ .data = "M4 4V12M20 4M24 4V12", .roles = &.{ e(4, 4, pi / 2, .start), e(4, 12, pi / 2, .mid), e(20, 4, 0, .mid), e(24, 4, pi / 2, .mid), e(24, 12, pi / 2, .end) } },
        .{ .data = "M4 4V12M20 4Q20 4 20 4L20 4", .roles = &.{ e(4, 4, pi / 2, .start), e(4, 12, pi / 2, .mid), e(20, 4, 0, .mid), e(20, 4, 0, .mid), e(20, 4, 0, .end) } },
        .{ .data = "M4 4M20 4V12", .roles = &.{ e(4, 4, 0, .start), e(20, 4, pi / 2, .mid), e(20, 12, pi / 2, .end) } },
        .{ .data = "M8 8A7 7 0 0 1 8 8M16 8H16ZM24 8", .roles = &.{ e(8, 8, 0, .start), e(16, 8, 0, .mid), e(16, 8, 0, .mid), e(16, 8, 0, .mid), e(24, 8, 0, .end) } },
        .{ .data = "M8 8ZM16 8Z", .roles = &.{ e(8, 8, 0, .start), e(8, 8, 0, .mid), e(16, 8, 0, .mid), e(16, 8, 0, .end) } },
        .{ .data = "M8 8C16 8 0 8 8 8A7 7 0 0 1 8 8ZM20 4V12", .roles = &.{ e(8, 8, 0, .start), e(8, 8, 0, .mid), e(8, 8, 0, .mid), e(20, 4, pi / 2, .mid), e(20, 12, pi / 2, .end) } },
        .{ .data = "M8 8H16Z", .roles = &.{ e(8, 8, null, .start), e(16, 8, null, .mid), e(8, 8, null, .end) } },
        // The existing parser materializes the implicit new M after close.
        .{ .data = "M8 8ZV16", .roles = &.{ e(8, 8, 0, .start), e(8, 8, 0, .mid), e(8, 8, pi / 2, .mid), e(8, 16, pi / 2, .end) } },
    };
    for (cases) |case| try verify(case.data, case.roles);
    std.debug.print("marker topology literal oracle: {d} cases, K0/K1, omitted/zero distinction, closed seams/global roles/subpath-isolated limits\n", .{cases.len});
}

test "topology cold loops have bounded work and cancellation before source reads" {
    const path = try v.Path.parseData(std.testing.allocator, "M8 8Q8 8 8 8A7 7 0 0 1 8 8C8 8 8 8 8 8ZM20 4V12M24 4", .{});
    defer path.close() catch unreachable;
    var work: Work = .{};
    const inspection = try t.inspect(&work, path.commands);
    try t.validate(&work, path.commands);
    var cursor = t.Cursor.init(path.commands, inspection);
    while (try cursor.next(&work)) |_| {}
    const exact = work.visits;
    work = .{ .limit = exact };
    const again = try t.inspect(&work, path.commands);
    try t.validate(&work, path.commands);
    cursor = t.Cursor.init(path.commands, again);
    while (try cursor.next(&work)) |_| {}
    try std.testing.expectEqual(exact, work.visits);
    work = .{ .limit = exact - 1 };
    const short = try t.inspect(&work, path.commands);
    try t.validate(&work, path.commands);
    cursor = t.Cursor.init(path.commands, short);
    while (cursor.next(&work)) |next| {
        if (next == null) return error.ExpectedWorkFailure;
    } else |err| try std.testing.expectEqual(error.NodeWorkExceeded, err);
    work = .{ .cancelled = true };
    try std.testing.expectError(error.Cancelled, t.inspect(&work, path.commands));
    cursor = t.Cursor.init(path.commands, inspection);
    try std.testing.expectError(error.Cancelled, cursor.next(&work));
    try std.testing.expectEqual(@as(usize, 0), work.visits);
    std.debug.print("marker topology private values: inspect={d} cursor={d} role={d}; bounded work={d}\n", .{ @sizeOf(t.Inspection), @sizeOf(t.Cursor), @sizeOf(t.Role), exact });
}

test "omitted arity hints cannot bypass the first Arc validation" {
    const commands = [_]v.Command{ .{ .move = .{ .x = 8, .y = 8 } }, .{ .arc = .{ .radius = .{ .x = std.math.nan(f64), .y = 7 }, .end = .{ .x = 8, .y = 8 } } } };
    var work: Work = .{};
    const inspection = try t.inspect(&work, &commands);
    try std.testing.expectEqual(@as(usize, 1), inspection.vertices);
    try std.testing.expectError(error.InvalidGeometry, t.validate(&work, &commands));
}
