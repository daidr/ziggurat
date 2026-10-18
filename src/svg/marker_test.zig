const std = @import("std");
const svg = @import("root.zig");
const a = std.testing.allocator;
const Mode = @FieldType(svg.PrepareOptions, "compositing");
pub const definition = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
fn image(allocator: std.mem.Allocator, source: []const u8, mode: Mode) !*svg.Prepared {
    const document = try svg.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    return document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode });
}
fn equal(source: []const u8, expected: []const u8, mode: Mode) !void {
    const actual = try image(a, source, mode);
    defer actual.close() catch unreachable;
    const oracle = try image(a, expected, mode);
    defer oracle.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, oracle.pixels, actual.pixels);
}
fn acceptedGeometry(source: []const u8, mode: Mode) !void {
    const output = try image(a, source, mode);
    try output.close();
}

const open_zero_arc_positive = "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M12 4A8 8 0 0 1 20 12L20 12H28' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const open_zero_arc_positive_oracle = "<svg><rect x='11' y='3' width='2' height='2' fill='red'/><rect x='19' y='11' width='2' height='2' fill='red'/><rect x='19' y='11' width='2' height='2' fill='red'/><rect x='27' y='11' width='2' height='2' fill='red'/></svg>";

test "open zero arc fixed marker public pixel positive" {
    try equal(open_zero_arc_positive, open_zero_arc_positive_oracle, .pixel);
}
test "open zero arc fixed marker public compiled sample positive" {
    try equal(open_zero_arc_positive, open_zero_arc_positive_oracle, .sample_color);
}

test "existing open zero arcs retain complete pixel allocation and work fingerprints" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), open_zero_arc_positive, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG zero-arc-open fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}
const closed_zero_arc_positive = "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M12 4A8 8 0 0 1 20 12Q20 12 20 12H4Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const closed_zero_arc_positive_oracle = "<svg><rect x='11' y='3' width='2' height='2' fill='red'/><rect x='19' y='11' width='2' height='2' fill='red'/><rect x='19' y='11' width='2' height='2' fill='red'/><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='11' y='3' width='2' height='2' fill='red'/></svg>";
test "closed zero arc fixed marker public pixel positive" {
    try equal(closed_zero_arc_positive, closed_zero_arc_positive_oracle, .pixel);
}
test "closed zero arc fixed marker public compiled sample positive" {
    try equal(closed_zero_arc_positive, closed_zero_arc_positive_oracle, .sample_color);
}
const ClosedArcAxis = enum { right, down, left, up };
const ClosedArcRole = struct { x: i32, y: i32, axis: ClosedArcAxis };
const closed_arc_roles = [_]ClosedArcRole{
    .{ .x = 12, .y = 0, .axis = .right },
    .{ .x = 20, .y = 8, .axis = .down },
    .{ .x = 20, .y = 8, .axis = .left },
    .{ .x = 4, .y = 8, .axis = .left },
    .{ .x = 4, .y = 8, .axis = .up },
    .{ .x = 4, .y = 0, .axis = .up },
    .{ .x = 4, .y = 0, .axis = .right },
    .{ .x = 12, .y = 0, .axis = .right },
};
const closed_zero_z_arc_roles = [_]ClosedArcRole{
    .{ .x = 20, .y = 12, .axis = .down },
    .{ .x = 4, .y = 12, .axis = .up },
    .{ .x = 4, .y = 12, .axis = .up },
    .{ .x = 20, .y = 12, .axis = .down },
    .{ .x = 20, .y = 12, .axis = .down },
    .{ .x = 20, .y = 12, .axis = .down },
};
fn prescribedArcPalettes(roles: []const ClosedArcRole, opacity: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(a);
    try xml.appendSlice(a, "<svg>");
    for (roles) |role| {
        const vertical = role.axis == .down or role.axis == .up;
        const left = role.x - @as(i32, if (vertical) 2 else 4);
        const top = role.y - @as(i32, if (vertical) 4 else 2);
        const red_first = role.axis == .right or role.axis == .down;
        const piece = try std.fmt.allocPrint(a, "<rect x='{d}' y='{d}' width='4' height='4' fill='{s}' fill-opacity='{s}'/><rect x='{d}' y='{d}' width='4' height='4' fill='{s}' fill-opacity='{s}'/>", .{ left, top, if (red_first) "red" else "blue", opacity, left + @as(i32, if (vertical) 0 else 4), top + @as(i32, if (vertical) 4 else 0), if (red_first) "blue" else "red", opacity });
        defer a.free(piece);
        try xml.appendSlice(a, piece);
    }
    try xml.appendSlice(a, "</svg>");
    return xml.toOwnedSlice(a);
}
test "closed zero arc keeps every axis role and real Z anchor in source order" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const oracle = try prescribedArcPalettes(&closed_arc_roles, opacity);
        defer a.free(oracle);
        for ([_][]const u8{
            "M12 0A8 8 0 0 1 20 8Q20 8 20 8H4Q4 8 4 8V0Q4 0 4 0Z",
            "m12 0a-8 -8 360 0 1 8 8q0 0 0 0h-16c0 0 0 0 0 0v-8h0z",
        }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{ palette, data });
            defer a.free(source);
            try equal(source, oracle, mode);
        }
    };
}
test "closed zero arc keeps terminal constant mid and zero Z seam as distinct paints" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='M20 12A8 8 0 0 1 4 12Q4 12 4 12A8 8 0 0 1 20 12C20 12 20 12 20 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{palette});
        defer a.free(source);
        const oracle = try prescribedArcPalettes(&closed_zero_z_arc_roles, opacity);
        defer a.free(oracle);
        try equal(source, oracle, mode);
        if (opacity[0] == '.') {
            const output = try image(a, source, mode);
            defer output.close() catch unreachable;
            const four: u8 = if (mode == .pixel) 240 else 239;
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, four, four }, output.pixels[(10 * 32 + 20) * 4 ..][0..4]);
            try std.testing.expectEqualSlices(u8, &.{ 192, 0, 0, 192 }, output.pixels[(10 * 32 + 4) * 4 ..][0..4]);
        }
    };
}
test "closed zero arc preserves signed leading and trailing linear fallback" {
    const palette = "<rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/>";
    // Same-end C leaves right and returns down;the following zero-radius A
    // is a real down line. Nonzero Z points up,so the shared seam is-45.
    const seam = "<g transform='translate(12 12) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>" ++ palette ++ "</g>";
    const source = "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>" ++ palette ++ "</marker></defs><path d='M12 12Q12 12 12 12C20 12 12 4 12 12Q12 12 12 12A0 8 0 0 1 12 20Q12 20 12 20Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    const roles = [_]ClosedArcRole{
        .{ .x = 12, .y = 12, .axis = .right },
        .{ .x = 12, .y = 12, .axis = .down },
        .{ .x = 12, .y = 12, .axis = .down },
        .{ .x = 12, .y = 20, .axis = .down },
        .{ .x = 12, .y = 20, .axis = .up },
    };
    const mids = try prescribedArcPalettes(&roles, ".5019607843137255");
    defer a.free(mids);
    const oracle = try std.fmt.allocPrint(a, "<svg><defs><clipPath id='v'><rect width='8' height='4'/></clipPath></defs>{s}{s}{s}</svg>", .{ seam, mids[5 .. mids.len - 6], seam });
    defer a.free(oracle);
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "closed zero arc bounded cursor includes real Z and never rescans its prefix" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [131]v.Command = undefined;
    commands[0] = .{ .move = .{ .x = 12, .y = 20 } };
    commands[1] = .{ .arc = .{ .radius = .{ .x = 8, .y = 8 }, .sweep = true, .end = .{ .x = 20, .y = 28 } } };
    for (commands[2..130]) |*command| command.* = .{ .quadratic = .{ .control = .{ .x = 20, .y = 28 }, .end = .{ .x = 20, .y = 28 } } };
    commands[130] = .close;
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    const topology = try markers.closed(&work, path, true);
    try std.testing.expectEqual(markers.MidStrategy.zero_polynomials, topology.mids);
    try std.testing.expectEqual(@as(usize, 131), work.node_visits);
    var cursor: markers.ClosedZeroPolynomialCursor = .{};
    var count: usize = 0;
    while (try cursor.next(&work, path)) |mid| {
        try std.testing.expectEqual(v.Point{ .x = 20, .y = 28 }, mid.point);
        const angle: f64 = if (count == 0) @as(f64, std.math.pi) / 2 else if (count == 128) -3 * @as(f64, std.math.pi) / 4 else -9 * @as(f64, std.math.pi) / 8;
        try std.testing.expectApproxEqAbs(angle, mid.direction.?, 1e-14);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 129), count);
    try std.testing.expectEqual(@as(usize, 130), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 390), work.node_visits);
    try std.testing.expectEqual(@as(usize, 0), work.live);
    work.node_visits = 0;
    work.options.limits.node_visits = 65;
    cursor = .{};
    try std.testing.expectError(error.NodeWorkExceeded, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 64), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 1), cursor.at);
    try std.testing.expectEqual(@as(usize, 65), work.node_visits);
    work.node_visits = 0;
    work.options.limits.node_visits = 129;
    try std.testing.expectError(error.NodeWorkExceeded, markers.closed(&work, path, false));
    try std.testing.expectEqual(@as(usize, 129), work.node_visits);
    var cancellation: v.Cancellation = .{};
    cancellation.request();
    work.node_visits = 0;
    work.options.cancellation = &cancellation;
    cursor = .{};
    try std.testing.expectError(error.Cancelled, cursor.next(&work, path));
    try std.testing.expectError(error.Cancelled, markers.closed(&work, path, true));
    try std.testing.expectEqual(@as(usize, 0), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 0), work.node_visits);
    // A long nonconstant L/Q prefix reaches its first A before the late zero.
    // Its first outgoing is polynomial;the previous A incoming is saved.
    commands[0] = .{ .move = .{} };
    for (commands[1..128], 1..) |*command, i| command.* = .{ .quadratic = .{ .control = .{ .x = @floatFromInt(i) }, .end = .{ .x = @floatFromInt(i) } } };
    commands[128] = .{ .arc = .{ .radius = .{ .x = 8, .y = 8 }, .sweep = true, .end = .{ .x = 135, .y = 8 } } };
    commands[129] = .{ .line = .{ .x = 135, .y = 8 } };
    const late = try v.Path.create(a, &commands, .{});
    defer late.close() catch unreachable;
    work.options.cancellation = null;
    work.options.limits.node_visits = 130;
    work.node_visits = 0;
    const late_topology = try markers.closed(&work, late, false);
    try std.testing.expectEqual(markers.MidStrategy.zero_polynomials, late_topology.mids);
    try std.testing.expectEqual(@as(usize, 130), work.node_visits);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(markers.ClosedTopology));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(markers.OpenTopology));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(markers.MidCursor));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(markers.ClosedZeroPolynomialCursor));
    std.debug.print("svg_closed_zero_arc_sizes topology={d} endpoints={d} ordinary_cursor={d} cold_cursor={d} directions={d}\n", .{ @sizeOf(markers.ClosedTopology), @sizeOf(markers.Endpoints), @sizeOf(markers.MidCursor), @sizeOf(markers.ClosedZeroPolynomialCursor), @sizeOf(v.Arc.Directions) });
}
test "closed zero arc exact budgets OOM and references cover prefix order and zero Z" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{
        "M12 4A8 8 0 0 1 20 12Q20 12 20 12H4Z",
        "M12 4H12A8 8 0 0 1 20 12C20 12 20 12 20 12Z",
        "M12 4Q12 4 12 4A8 8 0 0 1 20 12H4Z",
        "M12 4Q16 4 16 8A4 4 0 0 1 20 12H20Z",
        "M12 4A8 8 0 0 1 20 12Q24 12 24 16H24Z",
        "M12 4A8 8 0 0 1 20 12H24Q24 12 24 12Z",
        "M20 12A8 8 0 0 1 4 12Q4 12 4 12A8 8 0 0 1 20 12C20 12 20 12 20 12Z",
    }) |data| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
        defer a.free(source);
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        const output = try document.prepare(a, options);
        const stats = try output.stats();
        try output.close();
        options.limits.node_visits = stats.node_visits;
        const exact = try document.prepare(a, options);
        try exact.close();
        options.limits.node_visits -= 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.bytes = stats.peak_bytes;
        const exact_bytes = try document.prepare(a, options);
        try exact_bytes.close();
        options.limits.bytes -= 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
    };
    const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M12 4H12A8 8 0 0 1 20 12Z' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
    defer instance.close() catch unreachable;
    try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .limits = .{ .reference_depth = 1 } }));
}
test "closed zero arc rejects only actual auto ambiguity and preserves missing content gates" {
    const fixed = "<marker id='f' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    const one = "M4 12A0 8 0 0 1 12 12Q12 12 12 12A0 8 0 0 1 4 12Z";
    const two = "M4 12A0 8 0 0 1 12 12Q12 12 12 12C12 12 12 12 12 12A0 8 0 0 1 4 12Z";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const mid_only = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{one});
        defer a.free(mid_only);
        try equal(mid_only, "<svg><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/><path d='M10 15L4 12L10 9Z' fill='red'/></svg>", mode);
        const endpoint = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)'/></svg>", .{one});
        defer a.free(endpoint);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, endpoint, mode));
        const actual_mid = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{two});
        defer a.free(actual_mid);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, actual_mid, mode));
        const unused = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#f)' marker-mid='url(#missing)' marker-end='url(#f)'/></svg>", .{two});
        defer a.free(unused);
        try equal(unused, "<svg><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='3' y='11' width='2' height='2' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerWidth='0'><use href='#absent'/></marker></defs><path d='M12 4H12A8 8 0 0 1 20 12Z' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try acceptedGeometry("<svg><defs><marker id='m'><rect width='2' height='2'/></marker></defs><path d='M12 4H12A8 8 0 0 1 20 12Z' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", mode);
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M12 4H12A8 8 0 0 1 20 12Z' fill='none' marker-mid='url(#missing)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs><marker id='m' markerWidth='0' orient='auto'><rect width='2' height='2'/></marker></defs><path d='M4 12A0 8 0 0 1 12 12Q12 12 12 12C12 12 12 12 12 12A0 8 0 0 1 4 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg/>", mode);
    }
}
test "closed zero arc whole paint effects and analytical object bounds stay shared" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='green' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='7.5' y='8.25' width='10' height='9'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='6' y='6' width='4' height='4' fill='red' fill-opacity='.5'/><rect x='14' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='14' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='6' width='4' height='4' fill='green' fill-opacity='.5'/>";
    const data = "M8 8A8 8 0 0 1 16 16Q16 16 16 16H8Z";
    const stroke = "<path d='" ++ data ++ "' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='" ++ data ++ "' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g transform='matrix(.75 .125 .25 .75 0 0)'><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs>" ++ heads ++ "<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M12 4A8 8 0 0 1 20 12Q20 12 20 12Z' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' clip-path='url(#c)'/></svg>", "<svg><rect x='12' y='4' width='2' height='2' fill='red' fill-opacity='.5'/><rect x='18' y='10' width='2' height='2' fill='blue' fill-opacity='.5'/><rect x='18' y='10' width='2' height='2' fill='blue' fill-opacity='.5'/><rect x='12' y='4' width='2' height='2' fill='green' fill-opacity='.5'/></svg>", mode);
    }
}

test "open zero arc keeps each down diagonal right raw mid in paint order" {
    const viewport = "<clipPath id='v'><rect width='8' height='4'/></clipPath>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| for ([_]struct { zeros: []const u8, diagonal: bool }{
        .{ .zeros = "H20", .diagonal = false },
        .{ .zeros = "Q20 12 20 12", .diagonal = false },
        .{ .zeros = "C20 12 20 12 20 12", .diagonal = false },
        .{ .zeros = "H20Q20 12 20 12", .diagonal = true },
        .{ .zeros = "Q20 12 20 12C20 12 20 12 20 12", .diagonal = true },
    }) |case| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='M12 4A8 8 0 0 1 20 12{s}H28' fill='none' marker-mid='url(#m)'/></svg>", .{ palette, case.zeros });
        defer a.free(source);
        const diagonal = if (case.diagonal) try std.fmt.allocPrint(a, "<g transform='translate(20 12) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>{s}</g>", .{palette}) else try a.dupe(u8, "");
        defer a.free(diagonal);
        // Center(12,12):the quarter circle arrives down. The zero run's
        // next real H leaves right. Keep D/D,(R/D),R/R as ordered paints.
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ viewport ++ "</defs><rect x='18' y='8' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='18' y='12' width='4' height='4' fill='blue' fill-opacity='{s}'/>{s}<g transform='translate(16 10)' clip-path='url(#v)'>{s}</g></svg>", .{ opacity, opacity, diagonal, palette });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "open zero arc preserves signed negative mid rather than normalized CSS angle" {
    const palette = "<rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/>";
    const source = "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>" ++ palette ++ "</marker></defs><path d='M12 20A8 8 0 0 0 20 12Q20 12 20 12C20 12 20 12 20 12H28' fill='none' marker-mid='url(#m)'/></svg>";
    const oracle = "<svg><defs><clipPath id='v'><rect width='8' height='4'/></clipPath></defs><rect x='18' y='12' width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='18' y='8' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/><g transform='translate(20 12) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>" ++ palette ++ "</g><g transform='translate(16 10)' clip-path='url(#v)'>" ++ palette ++ "</g></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "open zero arc future anchor retains outgoing then promotes incoming once" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12Q20 12 20 12C20 12 20 12 20 12A8 8 0 0 1 12 20Q12 20 12 20H4' fill='none' marker-mid='url(#m)'/></svg>";
    const down = "<path d='M23 6L20 12L17 6Z' fill='red'/>";
    const left = "<path d='M18 23L12 20L18 17Z' fill='red'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, "<svg>" ++ down ++ down ++ down ++ left ++ left ++ "</svg>", mode);
    const right = "<path d='M6 1L12 4L6 7Z' fill='red'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "H12", "Q12 4 12 4", "C12 4 12 4 12 4" }) |prefix| {
        const prefix_suffix = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M12 4{s}A8 8 0 0 1 20 12C20 12 20 12 20 12' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{prefix});
        defer a.free(prefix_suffix);
        try equal(prefix_suffix, "<svg>" ++ right ++ right ++ down ++ down ++ "</svg>", mode);
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal("<svg><defs>" ++ definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12H20' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg>" ++ right ++ down ++ down ++ "</svg>", mode);
}

test "open zero arc radius flags reflected controls and nonconstant loop keep real limits" {
    const cases = [_]struct { arc: []const u8, down: bool }{
        .{ .arc = "A8 8 0 0 1 20 12", .down = true },
        .{ .arc = "a-8 -8 0 0 1 8 8", .down = true },
        .{ .arc = "A8 8 360 0 1 20 12", .down = true },
        .{ .arc = "A8 8 0 0 0 20 12", .down = false },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M12 4Q12 4 12 4{s}C20 12 20 12 20 12' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{case.arc});
        defer a.free(source);
        // The second circle center(20,4) leaves down and arrives right.
        const first = if (case.down) "<path d='M6 1L12 4L6 7Z' fill='red'/>" else "<path d='M15 -2L12 4L9 -2Z' fill='red'/>";
        const last = if (case.down) "<path d='M23 6L20 12L17 6Z' fill='red'/>" else "<path d='M14 9L20 12L14 15Z' fill='red'/>";
        const oracle = try std.fmt.allocPrint(a, "<svg>{s}{s}{s}{s}</svg>", .{ first, first, last, last });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const data = "M4 12A0 8 0 1 1 12 12Q12 12 12 12T20 12C24 12 12 4 20 12C20 12 20 12 20 12";
        const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{data});
        defer a.free(source);
        try equal(source, "<svg><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='19' y='11' width='2' height='2' fill='red'/><rect x='19' y='11' width='2' height='2' fill='red'/></svg>", mode);
    }
}

test "open zero arc source roles compose whole effects once and keep analytic bbox" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='green' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='7.5' y='4.25' width='15' height='13'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const data = "M12 4A8 8 0 0 1 20 12Q20 12 20 12H28";
    const marks = "<rect x='10' y='2' width='4' height='4' fill='red' fill-opacity='.5'/><rect x='18' y='10' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='18' y='10' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='26' y='10' width='4' height='4' fill='green' fill-opacity='.5'/>";
    const stroke = "<path d='" ++ data ++ "' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='" ++ data ++ "' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g transform='matrix(.75 .125 .25 .75 0 0)'><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs>" ++ heads ++ "<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M12 4A8 8 0 0 1 20 12Q20 12 20 12' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' clip-path='url(#c)'/></svg>", "<svg><rect x='12' y='4' width='2' height='2' fill='red' fill-opacity='.5'/><rect x='18' y='10' width='2' height='2' fill='blue' fill-opacity='.5'/><rect x='18' y='10' width='2' height='2' fill='green' fill-opacity='.5'/></svg>", mode);
    }
}

test "open zero arc automatic opposite limits and missing roles preserve instance gates" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    const one = "M4 12A0 8 0 0 1 12 12Q12 12 12 12A0 8 0 0 1 4 12";
    const two = "M4 12A0 8 0 0 1 12 12Q12 12 12 12C12 12 12 12 12 12A0 8 0 0 1 4 12";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{one});
        defer a.free(source);
        try equal(source, "<svg><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/></svg>", mode);
        const automatic = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{two});
        defer a.free(automatic);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, automatic, mode));
        const oriented = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{two});
        defer a.free(oriented);
        try equal(oriented, "<svg><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/></svg>", mode);
        const unused = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", .{two});
        defer a.free(unused);
        try equal(unused, "<svg><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='3' y='11' width='2' height='2' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerWidth='0'><use href='#absent'/></marker></defs><path d='M12 4A8 8 0 0 1 20 12H20' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try acceptedGeometry("<svg><defs><marker id='m'><rect width='2' height='2'/></marker></defs><path d='M12 4A8 8 0 0 1 20 12H20' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", mode);
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M12 4A8 8 0 0 1 20 12H20' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#missing)'/></svg>", "<svg/>", mode);
        try std.testing.expectError(error.UnsupportedArcPrecision, image(a, "<svg><defs>" ++ fixed ++ "</defs><path d='M0 0Q0 0 0 0A1 1 0 0 1 1e-160 0' fill='none' marker-start='url(#m)'/></svg>", mode));
    }
}

test "open zero arc long cursor has monotonic limits work cancellation and unchanged records" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [130]v.Command = undefined;
    commands[0] = .{ .move = .{ .x = 4, .y = 8 } };
    for (commands[1..65]) |*command| command.* = .{ .quadratic = .{ .control = .{ .x = 4, .y = 8 }, .end = .{ .x = 4, .y = 8 } } };
    commands[65] = .{ .arc = .{ .radius = .{ .x = 8, .y = 8 }, .sweep = true, .end = .{ .x = 12, .y = 16 } } };
    for (commands[66..]) |*command| command.* = .{ .cubic = .{ .first = .{ .x = 12, .y = 16 }, .second = .{ .x = 12, .y = 16 }, .end = .{ .x = 12, .y = 16 } } };
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    const topology = (try markers.endpoints(&work, path, "path")).?;
    try std.testing.expectEqual(markers.MidStrategy.zero_polynomials, topology.mids);
    try std.testing.expectEqual(@as(usize, 129), work.node_visits);
    try std.testing.expectApproxEqAbs(@as(f64, 0), topology.ends.start_angle, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi) / 2, topology.ends.end_angle, 1e-14);
    var cursor: markers.ZeroPolynomialCursor = .{};
    var count: usize = 0;
    while (try cursor.next(&work, path)) |mid| {
        try std.testing.expectEqual(v.Point{ .x = if (count < 64) 4 else 12, .y = if (count < 64) 8 else 16 }, mid.point);
        try std.testing.expectApproxEqAbs(@as(f64, if (count < 64) 0 else @as(f64, std.math.pi) / 2), mid.direction.?, 1e-14);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 128), count);
    try std.testing.expectEqual(@as(usize, 129), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 386), work.node_visits);
    try std.testing.expectEqual(@as(usize, 0), work.live);
    cursor = .{};
    work.node_visits = 0;
    work.options.limits.node_visits = 65;
    try std.testing.expectError(error.NodeWorkExceeded, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 64), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 1), cursor.at);
    work.node_visits = 0;
    work.options.limits.node_visits = 128;
    try std.testing.expectError(error.NodeWorkExceeded, markers.endpoints(&work, path, "path"));
    try std.testing.expectEqual(@as(usize, 128), work.node_visits);
    var cancellation: v.Cancellation = .{};
    cancellation.request();
    work.options.cancellation = &cancellation;
    work.node_visits = 0;
    cursor = .{};
    try std.testing.expectError(error.Cancelled, cursor.next(&work, path));
    try std.testing.expectError(error.Cancelled, markers.endpoints(&work, path, "path"));
    try std.testing.expectEqual(@as(usize, 0), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 0), work.node_visits);
    const tiny_commands = [_]v.Command{
        .{ .move = .{ .x = 12, .y = 4 } },
        .{ .quadratic = .{ .control = .{ .x = 12, .y = 4 }, .end = .{ .x = 12, .y = 4 } } },
        .{ .arc = .{ .radius = .{ .x = 8, .y = 8 }, .sweep = true, .end = .{ .x = 20, .y = 12 } } },
    };
    const tiny = try v.Path.create(a, &tiny_commands, .{});
    defer tiny.close() catch unreachable;
    work.options.cancellation = null;
    work.options.limits.node_visits = 5;
    _ = (try markers.endpoints(&work, tiny, "path")).?;
    cursor = .{};
    try std.testing.expect((try cursor.next(&work, tiny)) != null);
    try std.testing.expect((try cursor.next(&work, tiny)) == null);
    try std.testing.expectEqual(@as(usize, 5), work.node_visits);
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(markers.OpenTopology));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(markers.ClosedTopology));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(markers.MidCursor));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(markers.ZeroLineCursor));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(markers.ZeroPolynomialCursor));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(markers.ClosedZeroPolynomialCursor));
    std.debug.print("svg_zero_arc_sizes ends={d} open={d} closed={d} ordinary_cursor={d} line_cursor={d} cold_cursor={d} closed_cold_cursor={d} arc_directions={d}\n", .{ @sizeOf(markers.Endpoints), @sizeOf(markers.OpenTopology), @sizeOf(markers.ClosedTopology), @sizeOf(markers.MidCursor), @sizeOf(markers.ZeroLineCursor), @sizeOf(markers.ZeroPolynomialCursor), @sizeOf(markers.ClosedZeroPolynomialCursor), @sizeOf(v.Arc.Directions) });
}

test "open zero arc resumes a late nonzero prefix without rescanning commands" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [68]v.Command = undefined;
    commands[0] = .{ .move = .{} };
    for (commands[1..65], 1..) |*command, i| command.* = .{ .line = .{ .x = @floatFromInt(i) } };
    commands[65] = .{ .arc = .{ .radius = .{ .x = 8, .y = 8 }, .sweep = true, .end = .{ .x = 72, .y = 8 } } };
    commands[66] = .{ .quadratic = .{ .control = .{ .x = 72, .y = 8 }, .end = .{ .x = 72, .y = 8 } } };
    commands[67] = .{ .line = .{ .x = 80, .y = 8 } };
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    _ = (try markers.endpoints(&work, path, "path")).?;
    try std.testing.expectEqual(@as(usize, 67), work.node_visits);
    var cursor: markers.ZeroPolynomialCursor = .{};
    var count: usize = 0;
    while (try cursor.next(&work, path)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 66), count);
    try std.testing.expectEqual(@as(usize, 67), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 200), work.node_visits);
}

test "open zero arc exact node peak OOM and reference budgets count every raw role" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{
        "M12 4A8 8 0 0 1 20 12Q20 12 20 12H28",
        "M12 4Q12 4 12 4A8 8 0 0 1 20 12C20 12 20 12 20 12",
        "M12 4A8 8 0 0 1 20 12Q20 12 20 12A8 8 0 0 1 12 20H12H4",
        "M4 12A0 8 0 0 1 12 12Q12 12 12 12C12 12 12 12 12 12A0 8 0 0 1 4 12",
    }) |data| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
        defer a.free(source);
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        const output = try document.prepare(a, options);
        const stats = try output.stats();
        try output.close();
        options.limits.node_visits = stats.node_visits;
        const exact = try document.prepare(a, options);
        try exact.close();
        options.limits.node_visits -= 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.bytes = stats.peak_bytes;
        const exact_bytes = try document.prepare(a, options);
        try exact_bytes.close();
        options.limits.bytes -= 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
    };
    const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M12 4A8 8 0 0 1 20 12H20H28' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
    defer instance.close() catch unreachable;
    try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .limits = .{ .reference_depth = 1 } }));
}

test "closed constant polynomial uses the real Z as its following anchor" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M12 20C2 20 2 8 12 8Q12 8 12 8Z' fill='none' marker-mid='url(#m)'/></svg>";
    const oracle = "<svg><path d='M6 5L12 8L6 11Z' fill='red'/><path d='M15 2L12 8L9 2Z' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "closed constant runs keep ordered right diagonal down limits before real Z" {
    const clips = "<clipPath id='v'><rect width='8' height='4'/></clipPath>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| for ([_]struct { zeros: []const u8, diagonal: bool }{
        .{ .zeros = "Q12 8 12 8", .diagonal = false },
        .{ .zeros = "C12 8 12 8 12 8", .diagonal = false },
        .{ .zeros = "H12Q12 8 12 8", .diagonal = true },
        .{ .zeros = "Q12 8 12 8C12 8 12 8 12 8", .diagonal = true },
    }) |case| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='M12 20C2 20 2 8 12 8{s}Z' fill='none' marker-mid='url(#m)'/></svg>", .{ palette, case.zeros });
        defer a.free(source);
        const diagonal = if (case.diagonal) try std.fmt.allocPrint(a, "<g transform='translate(12 8) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>{s}</g>", .{palette}) else try a.dupe(u8, "");
        defer a.free(diagonal);
        // C arrives from the left;Z goes down. Keep the one-zero 0/90
        // or two-zero 0/45/90 raw mids as distinct ordered paints.
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ clips ++ "</defs><g transform='translate(8 6)' clip-path='url(#v)'>{s}</g>{s}<rect x='10' y='4' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='10' y='8' width='4' height='4' fill='blue' fill-opacity='{s}'/></svg>", .{ palette, diagonal, opacity, opacity });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "closed leading and trailing polynomials keep their linear limits and signed seam" {
    const clip = "<clipPath id='v'><rect width='8' height='4'/></clipPath>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const seam = try std.fmt.allocPrint(a, "<g transform='translate(12 8) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>{s}</g>", .{palette});
        defer a.free(seam);
        const right = try std.fmt.allocPrint(a, "<g transform='translate(8 6)' clip-path='url(#v)'>{s}</g>", .{palette});
        defer a.free(right);
        const down = try std.fmt.allocPrint(a, "<rect x='10' y='4' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='10' y='8' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(down);
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ clip ++ "</defs>{s}{s}{s}{s}{s}</svg>", .{ seam, right, down, down, seam });
        defer a.free(oracle);
        for ([_][]const u8{
            "M12 8Q12 8 12 8C20 8 12 0 12 8Q12 8 12 8Z",
            "M12 8H12C20 8 12 0 12 8C12 8 12 8 12 8Z",
            "m12 8q0 0 0 0c8 0 0 -8 0 0h0z",
        }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{ palette, data });
            defer a.free(source);
            try equal(source, oracle, mode);
        }
    };
}

test "closed all constant polynomials retain each colored role and positive x fallback" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red' fill-opacity='.5019607843137255'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='green' fill-opacity='.5019607843137255'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker>";
    const red = "<rect x='8' y='10' width='8' height='4' fill='red' fill-opacity='.5019607843137255'/>";
    const green = "<rect x='8' y='10' width='8' height='4' fill='green' fill-opacity='.5019607843137255'/>";
    const blue = "<rect x='8' y='10' width='8' height='4' fill='blue' fill-opacity='.5019607843137255'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]struct { data: []const u8, mids: []const u8, pixel: u8, lane: u8 }{
        .{ .data = "M12 12Q12 12 12 12Z", .mids = green, .pixel = 224, .lane = 223 },
        .{ .data = "M12 12C12 12 12 12 12 12Z", .mids = green, .pixel = 224, .lane = 223 },
        .{ .data = "M12 12Q12 12 12 12C12 12 12 12 12 12Z", .mids = green ++ green, .pixel = 240, .lane = 239 },
        .{ .data = "m12 12h0q0 0 0 0c0 0 0 0 0 0z", .mids = green ++ green ++ green, .pixel = 248, .lane = 247 },
        .{ .data = "M12 12T12 12S12 12 12 12Z", .mids = green ++ green, .pixel = 240, .lane = 239 },
    }) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ "</defs><path d='{s}' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>", .{case.data});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg>" ++ red ++ "{s}" ++ blue ++ "</svg>", .{case.mids});
        defer a.free(oracle);
        try equal(source, oracle, mode);
        const same = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ "</defs><path d='{s}' fill='none' marker-start='url(#s)' marker-mid='url(#s)' marker-end='url(#s)'/></svg>", .{case.data});
        defer a.free(same);
        const output = try image(a, same, mode);
        defer output.close() catch unreachable;
        const alpha = if (mode == .pixel) case.pixel else case.lane;
        const expected: [4]u8 = .{ 0, 0, alpha, alpha };
        for (0..24) |y| for (0..32) |x| try std.testing.expectEqualSlices(u8, if (x >= 8 and x < 16 and y >= 10 and y < 14) &expected else &.{ 0, 0, 0, 0 }, output.pixels[(y * 32 + x) * 4 ..][0..4]);
    };
}

test "closed polynomial actual direction and capability gates preserve unused roles" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        // This same-end Q is not constant:it leaves right and returns left.
        // Zero Q/Z inherit left. Only the shared endpoint seam is opposite.
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M12 12Q20 12 12 12Q12 12 12 12Z' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M18 15L12 12L18 9Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M12 12Q20 12 12 12Q12 12 12 12Z' fill='none' marker-start='url(#m)'/></svg>", mode));
        // A single constant separates right/left mids;two add an actual
        // ambiguous180 mid. Neither an unused seam nor missing mid vetoes.
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12Q12 12 12 12H4Z' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/><path d='M10 15L4 12L10 9Z' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12Q12 12 12 12C12 12 12 12 12 12H4Z' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 12H12Q12 12 12 12C12 12 12 12 12 12H4Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='3' y='11' width='2' height='2' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 12H12Q12 12 12 12C12 12 12 12 12 12H4Z' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", "<svg><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='3' y='11' width='2' height='2' fill='red'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerWidth='0' orient='auto'><rect width='2' height='2'/></marker></defs><path d='M4 12H12Q12 12 12 12C12 12 12 12 12 12H4Z' fill='none' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerWidth='0'><use href='#absent'/></marker></defs><path d='M12 12Q12 12 12 12Z' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try acceptedGeometry("<svg><defs><marker id='m'><rect width='2' height='2'/></marker></defs><path d='M12 12Q12 12 12 12Z' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", mode);
        try equal("<svg><defs><rect id='r'/></defs><path d='M12 12Q12 12 12 12Z' fill='none' marker-mid='url(#r)'/></svg>", "<svg/>", mode);
        const reverse = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
        try equal("<svg><defs>" ++ reverse ++ "</defs><path d='M12 12Q12 12 12 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M18 15L12 12L18 9Z' fill='red'/><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M6 9L12 12L6 15Z' fill='red'/></svg>", mode);
    }
}

test "closed nullable polynomial cursor includes Z once with bounded work and no allocation" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [131]v.Command = undefined;
    commands[0] = .{ .move = .{ .x = 12, .y = 20 } };
    commands[1] = .{ .cubic = .{ .first = .{ .x = 2, .y = 20 }, .second = .{ .x = 2, .y = 8 }, .end = .{ .x = 12, .y = 8 } } };
    for (commands[2..130]) |*command| command.* = .{ .quadratic = .{ .control = .{ .x = 12, .y = 8 }, .end = .{ .x = 12, .y = 8 } } };
    commands[130] = .close;
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    const topology = try markers.closed(&work, path, true);
    try std.testing.expectEqual(markers.MidStrategy.zero_polynomials, topology.mids);
    try std.testing.expectEqual(@as(usize, 131), work.node_visits);
    work.node_visits = 0;
    var cursor: markers.ClosedZeroPolynomialCursor = .{};
    var count: usize = 0;
    while (try cursor.next(&work, path)) |mid| {
        try std.testing.expectEqual(v.Point{ .x = 12, .y = 8 }, mid.point);
        try std.testing.expectEqual(@as(f64, if (count == 0) 0 else if (count == 128) @as(f64, std.math.pi) / 2 else @as(f64, std.math.pi) / 4), mid.direction.?);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 129), count);
    try std.testing.expectEqual(@as(usize, 130), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 259), work.node_visits);
    try std.testing.expectEqual(@as(usize, 0), work.live);
    cursor = .{};
    work.node_visits = 0;
    work.options.limits.node_visits = 65;
    try std.testing.expectError(error.NodeWorkExceeded, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 64), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 1), cursor.at);
    try std.testing.expectEqual(@as(usize, 65), work.node_visits);
    work.node_visits = 0;
    work.options.limits.node_visits = 129;
    try std.testing.expectError(error.NodeWorkExceeded, markers.closed(&work, path, false));
    try std.testing.expectEqual(@as(usize, 129), work.node_visits);
    var cancel: v.Cancellation = .{};
    cancel.request();
    work.node_visits = 0;
    work.options.cancellation = &cancel;
    cursor = .{};
    try std.testing.expectError(error.Cancelled, cursor.next(&work, path));
    try std.testing.expectError(error.Cancelled, markers.closed(&work, path, true));
    try std.testing.expectEqual(@as(usize, 0), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 0), work.node_visits);
    const tiny = try v.Path.create(a, &.{ .{ .move = .{ .x = 12, .y = 12 } }, .{ .quadratic = .{ .control = .{ .x = 12, .y = 12 }, .end = .{ .x = 12, .y = 12 } } }, .close }, .{});
    defer tiny.close() catch unreachable;
    work.options.cancellation = null;
    work.options.limits.node_visits = 6;
    work.node_visits = 0;
    const small = try markers.closed(&work, tiny, true);
    try std.testing.expectEqual(markers.MidStrategy.zero_polynomials, small.mids);
    try std.testing.expectEqual(@as(f64, 0), small.seam.direction.?);
    cursor = .{};
    try std.testing.expectEqual(@as(f64, 0), (try cursor.next(&work, tiny)).?.direction.?);
    try std.testing.expect((try cursor.next(&work, tiny)) == null);
    try std.testing.expectEqual(@as(usize, 2), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 6), work.node_visits);
    // Late promotion from a real polynomial prefix must not revisit it.
    for (commands[1..129], 0..) |*command, i| {
        const end: v.Point = .{ .x = @floatFromInt(13 + i), .y = 20 };
        command.* = .{ .quadratic = .{ .control = end, .end = end } };
    }
    commands[129] = .{ .line = commands[128].quadratic.end };
    const late = try v.Path.create(a, &commands, .{});
    defer late.close() catch unreachable;
    work.options.limits.node_visits = 130;
    work.node_visits = 0;
    const late_topology = try markers.closed(&work, late, false);
    try std.testing.expectEqual(markers.MidStrategy.zero_polynomials, late_topology.mids);
    try std.testing.expectEqual(@as(usize, 130), work.node_visits);
    std.debug.print("svg_closed_polynomial_zero_sizes topology={d} open_topology={d} endpoints={d} middle={d} ordinary_cursor={d} open_line_cursor={d} closed_line_cursor={d} open_polynomial_cursor={d} closed_polynomial_cursor={d}\n", .{ @sizeOf(markers.ClosedTopology), @sizeOf(markers.OpenTopology), @sizeOf(markers.Endpoints), @sizeOf(markers.Middle), @sizeOf(markers.MidCursor), @sizeOf(markers.ZeroLineCursor), @sizeOf(markers.ClosedZeroLineCursor), @sizeOf(markers.ZeroPolynomialCursor), @sizeOf(markers.ClosedZeroPolynomialCursor) });
}

test "closed zero polynomial roles share node byte allocation and reference budgets" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var regular: ?usize = null;
        for ([_][]const u8{
            "M4 4Q12 4 12 12H20C24 12 24 16 20 20H4Z",
            "M4 4Q12 4 12 12Q12 12 12 12C12 12 20 12 20 20H4Z",
            "M12 12Q12 12 12 12C12 12 12 12 12 12H12Q12 12 12 12Z",
            "M4 4H4Q4 4 12 12C12 12 12 12 12 12H20Z",
        }, 0..) |data, i| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const document = try svg.Document.parse(a, source, .{});
            defer document.close() catch unreachable;
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
            const output = try document.prepare(a, options);
            const stats = try output.stats();
            try output.close();
            if (i == 0) regular = stats.node_visits else try std.testing.expectEqual(regular.? + 5, stats.node_visits);
            options.limits.node_visits = stats.node_visits;
            const exact = try document.prepare(a, options);
            try exact.close();
            options.limits.node_visits -= 1;
            try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
            options.limits = .{};
            options.limits.bytes = stats.peak_bytes - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        }
        var without_mid: ?usize = null;
        for ([_][]const u8{ "M4 4Q12 4 12 12H20C24 12 24 16 20 20H4Z", "M12 12Q12 12 12 12C12 12 12 12 12 12H12Q12 12 12 12Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const output = try image(a, source, mode);
            const stats = try output.stats();
            try output.close();
            if (without_mid) |visits| try std.testing.expectEqual(visits, stats.node_visits) else without_mid = stats.node_visits;
        }
        const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M12 12Q12 12 12 12Z' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer instance.close() catch unreachable;
        try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .limits = .{ .reference_depth = 1 } }));
    }
}

test "closed zero polynomial whole effects and analytical bbox remain target operations" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='green' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='7.5' y='8.25' width='10' height='9'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='6' y='6' width='4' height='4' fill='red' fill-opacity='.5'/><rect x='14' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='14' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='6' width='4' height='4' fill='green' fill-opacity='.5'/>";
    const stroke = "<path d='M8 8Q16 8 16 16Q16 16 16 16H8Z' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M8 8Q16 8 16 16Q16 16 16 16H8Z' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g transform='matrix(.75 .125 .25 .75 0 0)'><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs>" ++ heads ++ "<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M12 12Q12 12 12 12Z' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' clip-path='url(#c)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red'/></marker><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M8 12Q16 0 24 12Q24 12 24 12Z' fill='none' marker-mid='url(#m)' clip-path='url(#c)'/></svg>", "<svg><rect x='18' y='6' width='6' height='6' fill='red'/><rect x='18' y='6' width='6' height='6' fill='red'/></svg>", mode);
        const units = "<marker id='m' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red' fill-opacity='.5'/></marker>";
        const box = "<rect x='10' y='10' width='4' height='4' fill='red' fill-opacity='.5'/>";
        try equal("<svg><defs>" ++ units ++ "</defs><path d='M12 12Q12 12 12 12Z' fill='none' stroke='none' stroke-width='2' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg>" ++ box ++ box ++ box ++ "</svg>", mode);
        try equal("<svg><defs>" ++ units ++ "</defs><path d='M12 12Q12 12 12 12Z' fill='none' stroke-width='0' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg/>", mode);
    }
}

test "existing open zero polynomials retain complete pixel allocation and work fingerprints" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M4 8Q12 8 12 16Q12 16 12 16C12 16 12 16 12 16Q12 16 20 16' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG zero-polynomial-open fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}

test "existing closed zero polynomials retain complete pixel allocation and work fingerprints" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M12 8Q12 8 12 8C20 8 12 0 12 8Q12 8 12 8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG zero-polynomial-closed fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}
test "open polynomial zero uses the preceding incoming and following outgoing independently" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M4 8Q12 8 12 16H12Q12 16 20 16' fill='none' marker-mid='url(#m)'/></svg>";
    const oracle = "<svg><path d='M15 10L12 16L9 10Z' fill='red'/><path d='M6 13L12 16L6 19Z' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "existing closed zero L retains complete pixel allocation and work fingerprints" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M12 20H2V8H12H12H12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG closed-zero-line fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}

test "one and two zero polynomials preserve incoming diagonal outgoing paint order" {
    const viewport = "<clipPath id='v'><rect width='8' height='4'/></clipPath>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| for ([_]struct { zeros: []const u8, diagonal: bool }{
        .{ .zeros = "H12", .diagonal = false },
        .{ .zeros = "Q12 16 12 16", .diagonal = false },
        .{ .zeros = "C12 16 12 16 12 16", .diagonal = false },
        .{ .zeros = "H12Q12 16 12 16", .diagonal = true },
        .{ .zeros = "Q12 16 12 16C12 16 12 16 12 16", .diagonal = true },
    }) |case| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='M4 8Q12 8 12 16{s}Q12 16 20 16' fill='none' marker-mid='url(#m)'/></svg>", .{ palette, case.zeros });
        defer a.free(source);
        const diagonal = if (case.diagonal) try std.fmt.allocPrint(a, "<g transform='translate(12 16) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>{s}</g>", .{palette}) else try a.dupe(u8, "");
        defer a.free(diagonal);
        // The preceding Q is right-out/down-in. Paint down,then optional45,
        // then right,one distinct palette per original source vertex.
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ viewport ++ "</defs><rect x='10' y='12' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='10' y='16' width='4' height='4' fill='blue' fill-opacity='{s}'/>{s}<g transform='translate(8 14)' clip-path='url(#v)'>{s}</g></svg>", .{ opacity, opacity, diagonal, palette });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "zero polynomial leading trailing and nonconstant loops use different endpoint limits" {
    const cases = [_]struct { data: []const u8, arrows: []const u8 }{
        .{ .data = "M12 8Q12 8 12 8Q20 8 20 16", .arrows = "<path d='M6 5L12 8L6 11Z' fill='red'/><path d='M6 5L12 8L6 11Z' fill='red'/><path d='M23 10L20 16L17 10Z' fill='red'/>" },
        .{ .data = "M4 8Q12 8 12 16C12 16 12 16 12 16", .arrows = "<path d='M-2 5L4 8L-2 11Z' fill='red'/><path d='M15 10L12 16L9 10Z' fill='red'/><path d='M15 10L12 16L9 10Z' fill='red'/>" },
        .{ .data = "M12 12Q20 12 12 12Q12 12 12 12", .arrows = "<path d='M6 9L12 12L6 15Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/>" },
        .{ .data = "M12 12Q12 12 12 12C20 12 20 12 12 12", .arrows = "<path d='M6 9L12 12L6 15Z' fill='red'/><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/>" },
        .{ .data = "m12 8h0q0 0 0 0c0 0 8 0 8 8", .arrows = "<path d='M6 5L12 8L6 11Z' fill='red'/><path d='M6 5L12 8L6 11Z' fill='red'/><path d='M6 5L12 8L6 11Z' fill='red'/><path d='M23 10L20 16L17 10Z' fill='red'/>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{case.data});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg>{s}</svg>", .{case.arrows});
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "zero polynomials retain whole target effects and analytical bbox" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='green' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='7.5' y='8.25' width='12' height='12'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='6' y='10' width='4' height='4' fill='red' fill-opacity='.5'/><rect x='10' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='10' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='18' y='14' width='4' height='4' fill='green' fill-opacity='.5'/>";
    const stroke = "<path d='M8 12Q12 12 12 16Q12 16 12 16L20 16' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M8 12Q12 12 12 16Q12 16 12 16L20 16' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs>" ++ heads ++ "<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M12 12Q12 12 12 12C12 12 12 12 12 12' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' clip-path='url(#c)'/></svg>", "<svg/>", mode);
        const view = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red' fill-opacity='.5'/></marker>";
        const box = "<rect x='10' y='11' width='6' height='4' fill='red' fill-opacity='.5'/>";
        try equal("<svg><defs>" ++ view ++ "</defs><g transform='matrix(.75 .125 .25 .75 0 0)'><path d='M12 12Q12 12 12 12C12 12 12 12 12 12' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></g></svg>", "<svg><g transform='matrix(.75 .125 .25 .75 0 0)'>" ++ box ++ box ++ box ++ "</g></svg>", mode);
    }
}

test "constant polynomials keep single and all zero source roles in positive x" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red' fill-opacity='.5019607843137255'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='green' fill-opacity='.5019607843137255'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker>";
    const red = "<rect x='8' y='10' width='8' height='4' fill='red' fill-opacity='.5019607843137255'/>";
    const green = "<rect x='8' y='10' width='8' height='4' fill='green' fill-opacity='.5019607843137255'/>";
    const blue = "<rect x='8' y='10' width='8' height='4' fill='blue' fill-opacity='.5019607843137255'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]struct { data: []const u8, mids: []const u8, pixel: u8, lane: u8 }{
        .{ .data = "M12 12Q12 12 12 12", .mids = "", .pixel = 192, .lane = 192 },
        .{ .data = "M12 12C12 12 12 12 12 12", .mids = "", .pixel = 192, .lane = 192 },
        .{ .data = "M12 12T12 12", .mids = "", .pixel = 192, .lane = 192 },
        .{ .data = "M12 12Q12 12 12 12C12 12 12 12 12 12", .mids = green, .pixel = 224, .lane = 223 },
        .{ .data = "m12 12h0q0 0 0 0t0 0", .mids = green ++ green, .pixel = 240, .lane = 239 },
        .{ .data = "m12 12q0 0 0 0t0 0s0 0 0 0", .mids = green ++ green, .pixel = 240, .lane = 239 },
    }) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ "</defs><path d='{s}' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>", .{case.data});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg>" ++ red ++ "{s}" ++ blue ++ "</svg>", .{case.mids});
        defer a.free(oracle);
        try equal(source, oracle, mode);
        const same_source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ "</defs><path d='{s}' fill='none' marker-start='url(#s)' marker-mid='url(#s)' marker-end='url(#s)'/></svg>", .{case.data});
        defer a.free(same_source);
        const output = try image(a, same_source, mode);
        defer output.close() catch unreachable;
        const alpha = if (mode == .pixel) case.pixel else case.lane;
        const expected: [4]u8 = .{ 0, 0, alpha, alpha };
        for (0..24) |y| for (0..32) |x| try std.testing.expectEqualSlices(u8, if (x >= 8 and x < 16 and y >= 10 and y < 14) &expected else &.{ 0, 0, 0, 0 }, output.pixels[(y * 32 + x) * 4 ..][0..4]);
    };
}

test "zero polynomial actual auto and unused single segment gates stay separate" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const one = "M4 12Q8 12 12 12Q12 12 12 12Q8 12 4 12";
        const two = "M4 12Q8 12 12 12Q12 12 12 12C12 12 12 12 12 12Q8 12 4 12";
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{one});
        defer a.free(source);
        try equal(source, "<svg><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/></svg>", mode);
        const rejected = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{two});
        defer a.free(rejected);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, rejected, mode));
        const accepted = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{two});
        defer a.free(accepted);
        try equal(accepted, "<svg><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/></svg>", mode);
        const unused = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", .{two});
        defer a.free(unused);
        try equal(unused, "<svg><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='3' y='11' width='2' height='2' fill='red'/></svg>", mode);
        try equal("<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='M12 12Q12 12 12 12' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerWidth='0'><use href='#absent'/></marker></defs><path d='M12 12Q12 12 12 12C12 12 12 12 12 12' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try equal("<svg><defs><marker id='m' markerWidth='0' orient='auto'><rect width='2' height='2'/></marker></defs><path d='M4 12Q8 12 12 12Q12 12 12 12C12 12 12 12 12 12Q8 12 4 12' fill='none' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try acceptedGeometry("<svg><defs><marker id='m'><rect width='2' height='2'/></marker></defs><path d='M12 12Q12 12 12 12C12 12 12 12 12 12' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", mode);
    }
}

test "zero polynomial cold cursor is monotonic and bills each original command once" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [130]v.Command = undefined;
    commands[0] = .{ .move = .{ .x = 4, .y = 12 } };
    commands[1] = .{ .quadratic = .{ .control = .{ .x = 12, .y = 12 }, .end = .{ .x = 12, .y = 20 } } };
    for (commands[2..129], 0..) |*command, i| command.* = if (i % 2 == 0) .{ .quadratic = .{ .control = .{ .x = 12, .y = 20 }, .end = .{ .x = 12, .y = 20 } } } else .{ .cubic = .{ .first = .{ .x = 12, .y = 20 }, .second = .{ .x = 12, .y = 20 }, .end = .{ .x = 12, .y = 20 } } };
    commands[129] = .{ .quadratic = .{ .control = .{ .x = 12, .y = 20 }, .end = .{ .x = 20, .y = 20 } } };
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    const topology = (try markers.endpoints(&work, path, "path")).?;
    try std.testing.expectEqual(markers.MidStrategy.zero_polynomials, topology.mids);
    try std.testing.expectEqual(@as(usize, 129), work.node_visits);
    try std.testing.expectEqual(@as(f64, 0), topology.ends.start_angle);
    try std.testing.expectEqual(@as(f64, 0), topology.ends.end_angle);
    work.node_visits = 0;
    var cursor: markers.ZeroPolynomialCursor = .{};
    var count: usize = 0;
    while (try cursor.next(&work, path)) |mid| {
        try std.testing.expectEqual(v.Point{ .x = 12, .y = 20 }, mid.point);
        try std.testing.expectEqual(@as(f64, if (count == 0) @as(f64, std.math.pi) / 2 else if (count == 127) 0 else @as(f64, std.math.pi) / 4), mid.direction.?);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 128), count);
    try std.testing.expectEqual(@as(usize, 129), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 257), work.node_visits);
    try std.testing.expectEqual(@as(usize, 0), work.live);
    cursor = .{};
    work.node_visits = 0;
    work.options.limits.node_visits = 65;
    try std.testing.expectError(error.NodeWorkExceeded, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 64), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 1), cursor.at);
    try std.testing.expectEqual(@as(usize, 65), work.node_visits);
    work.node_visits = 0;
    work.options.limits.node_visits = 128;
    try std.testing.expectError(error.NodeWorkExceeded, markers.endpoints(&work, path, "path"));
    try std.testing.expectEqual(@as(usize, 128), work.node_visits);
    var cancel: v.Cancellation = .{};
    cancel.request();
    work.node_visits = 0;
    work.options.cancellation = &cancel;
    cursor = .{};
    try std.testing.expectError(error.Cancelled, cursor.next(&work, path));
    try std.testing.expectError(error.Cancelled, markers.endpoints(&work, path, "path"));
    try std.testing.expectEqual(@as(usize, 0), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 0), work.node_visits);
    std.debug.print("svg_zero_polynomial_sizes topology={d} closed_topology={d} ordinary_cursor={d} line_cursor={d} closed_line_cursor={d} polynomial_cursor={d}\n", .{ @sizeOf(markers.OpenTopology), @sizeOf(markers.ClosedTopology), @sizeOf(markers.MidCursor), @sizeOf(markers.ZeroLineCursor), @sizeOf(markers.ClosedZeroLineCursor), @sizeOf(markers.ZeroPolynomialCursor) });
}

test "zero polynomial node peak byte OOM and references count every original role" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var regular: ?usize = null;
        for ([_][]const u8{ "M4 8Q8 8 12 12H16C16 16 20 16 20 20H24", "M4 8Q12 8 12 16H12Q12 16 20 16H20", "M12 12Q12 12 12 12C12 12 12 12 12 12H12Q12 12 12 12", "M4 8H4Q4 8 4 8C4 8 12 8 12 16H20" }, 0..) |data, i| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const document = try svg.Document.parse(a, source, .{});
            defer document.close() catch unreachable;
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
            const output = try document.prepare(a, options);
            const stats = try output.stats();
            try output.close();
            if (i == 0) regular = stats.node_visits else try std.testing.expectEqual(regular.? + 4, stats.node_visits);
            options.limits.node_visits = stats.node_visits;
            const exact = try document.prepare(a, options);
            try exact.close();
            options.limits.node_visits -= 1;
            try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
            options.limits = .{};
            options.limits.bytes = stats.peak_bytes - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        }
        var without_mid: ?usize = null;
        for ([_][]const u8{ "M4 8Q8 8 12 12H16C16 16 20 16 20 20H24", "M12 12Q12 12 12 12C12 12 12 12 12 12H12Q12 12 12 12" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const output = try image(a, source, mode);
            const stats = try output.stats();
            try output.close();
            if (without_mid) |visits| try std.testing.expectEqual(visits, stats.node_visits) else without_mid = stats.node_visits;
        }
        const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M12 12Q12 12 12 12C12 12 12 12 12 12' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer instance.close() catch unreachable;
        try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .limits = .{ .reference_depth = 1 } }));
    }
}

test "closed zero line uses the real Z as its later linear anchor" {
    const clip = "<clipPath id='c'><rect x='8' y='4' width='8' height='8'/></clipPath>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ clip ++ "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/></marker></defs><path d='M12 20H2V8H12H12Z' fill='none' marker-mid='url(#m)' clip-path='url(#c)'/></svg>", .{ opacity, opacity });
        defer a.free(source);
        // The last real H points right,while Z is the later down anchor.
        // Two coincident raw mids point right then down. Earlier mids atx2
        // cannot intersect the independent target clip beginning atx8.
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ clip ++ "</defs><g clip-path='url(#c)'><rect x='8' y='6' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='12' y='6' width='4' height='4' fill='blue' fill-opacity='{s}'/><rect x='10' y='4' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='10' y='8' width='4' height='4' fill='blue' fill-opacity='{s}'/></g></svg>", .{ opacity, opacity, opacity, opacity });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "two trailing zero lines preserve ordered right diagonal down mids before real Z" {
    const clip = "<clipPath id='c'><rect x='8' y='4' width='8' height='8'/></clipPath><clipPath id='v'><rect width='8' height='4'/></clipPath>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ clip ++ "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='M12 20H2V8H12H12H12Z' fill='none' marker-mid='url(#m)' clip-path='url(#c)'/></svg>", .{palette});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ clip ++ "</defs><g clip-path='url(#c)'><g transform='translate(8 6)' clip-path='url(#v)'>{s}</g><g transform='translate(12 8) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>{s}</g><rect x='10' y='4' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='10' y='8' width='4' height='4' fill='blue' fill-opacity='{s}'/></g></svg>", .{ palette, palette, opacity, opacity });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "closed leading and trailing zero runs keep linear limits distinct from their seam" {
    const clip = "<clipPath id='c'><rect x='9' y='9' width='6' height='6'/></clipPath><clipPath id='v'><rect width='8' height='4'/></clipPath>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ clip ++ "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='M12 12H12H20V4H12V12H12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)' clip-path='url(#c)'/></svg>", .{palette});
        defer a.free(source);
        // Only roles at p0 enter this clip:seam45,leading0,two trailing90,
        // seam45. In particular no cyclic search turns either rawmid into45.
        const seam = try std.fmt.allocPrint(a, "<g transform='translate(12 12) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>{s}</g>", .{palette});
        defer a.free(seam);
        const down = try std.fmt.allocPrint(a, "<rect x='10' y='8' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='10' y='12' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(down);
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ clip ++ "</defs><g clip-path='url(#c)'>{s}<g transform='translate(8 10)' clip-path='url(#v)'>{s}</g>{s}{s}{s}</g></svg>", .{ seam, palette, down, down, seam });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "all zero closed lines retain every original role and positive x fallback" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red' fill-opacity='.5019607843137255'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='green' fill-opacity='.5019607843137255'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker>";
    const red = "<rect x='8' y='10' width='8' height='4' fill='red' fill-opacity='.5019607843137255'/>";
    const green = "<rect x='8' y='10' width='8' height='4' fill='green' fill-opacity='.5019607843137255'/>";
    const blue = "<rect x='8' y='10' width='8' height='4' fill='blue' fill-opacity='.5019607843137255'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]struct { data: []const u8, mids: []const u8, pixel: u8, lane: u8 }{
        .{ .data = "M12 12H12Z", .mids = green, .pixel = 224, .lane = 223 },
        .{ .data = "M12 12H12V12Z", .mids = green ++ green, .pixel = 240, .lane = 239 },
        .{ .data = "m12 12h0v0l0 0z", .mids = green ++ green ++ green, .pixel = 248, .lane = 247 },
    }) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ "</defs><path d='{s}' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>", .{case.data});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg>" ++ red ++ "{s}" ++ blue ++ "</svg>", .{case.mids});
        defer a.free(oracle);
        try equal(source, oracle, mode);
        const same_source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ "</defs><path d='{s}' fill='none' marker-start='url(#s)' marker-mid='url(#s)' marker-end='url(#s)'/></svg>", .{case.data});
        defer a.free(same_source);
        const output = try image(a, same_source, mode);
        defer output.close() catch unreachable;
        const alpha = if (mode == .pixel) case.pixel else case.lane;
        const expected: [4]u8 = .{ 0, 0, alpha, alpha };
        for (0..24) |y| for (0..32) |x| try std.testing.expectEqualSlices(u8, if (x >= 8 and x < 16 and y >= 10 and y < 14) &expected else &.{ 0, 0, 0, 0 }, output.pixels[(y * 32 + x) * 4 ..][0..4]);
    };
}

test "closed zero line actual auto limits and capability gates preserve unused roles" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        // The unused seam is opposite,but each side of this single zero has
        // its own defined limit. Two zeros instead create a real180-degree mid.
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12H12H4Z' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/><path d='M10 15L4 12L10 9Z' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12H12H12H4Z' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 12H12H12H12H4Z' fill='none' marker-mid='url(#m)'/></svg>", "<svg><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='3' y='11' width='2' height='2' fill='red'/></svg>", mode);
        const unused = "M4 8H12H12H12H4V20H20V4H4V8Z";
        const no_mid = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", .{unused});
        defer a.free(no_mid);
        try equal(no_mid, "<svg><rect x='3' y='7' width='2' height='2' fill='red'/><rect x='3' y='7' width='2' height='2' fill='red'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerWidth='0' orient='auto'><rect width='2' height='2'/></marker></defs><path d='M4 12H12H12H12H4Z' fill='none' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerWidth='0'><use href='#absent'/></marker></defs><path d='M12 12H12Z' fill='none' marker-mid='url(#m)'/></svg>", mode));
        // Unlike a single open line,closed M/L/Z has a genuine raw mid even
        // when every point coincides. It must not bypass content/units gates.
        try acceptedGeometry("<svg><defs><marker id='m'><rect width='2' height='2'/></marker></defs><path d='M12 12H12Z' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", mode);
        try equal("<svg><defs><rect id='r'/></defs><path d='M12 12H12Z' fill='none' marker-mid='url(#r)'/></svg>", "<svg/>", mode);
    }
}

test "closed zero cursor classifies real Z exactly once with bounded lookahead" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [131]v.Command = undefined;
    commands[0] = .{ .move = .{ .x = 12, .y = 20 } };
    commands[1] = .{ .line = .{ .x = 2, .y = 20 } };
    commands[2] = .{ .line = .{ .x = 2, .y = 8 } };
    for (commands[3..130]) |*command| command.* = .{ .line = .{ .x = 12, .y = 8 } };
    commands[130] = .close;
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    const topology = try markers.closed(&work, path, true);
    try std.testing.expectEqual(markers.MidStrategy.zero_lines, topology.mids);
    try std.testing.expectEqual(@as(usize, 131), work.node_visits);
    work.node_visits = 0;
    var cursor: markers.ClosedZeroLineCursor = .{};
    var count: usize = 0;
    while (try cursor.next(&work, path)) |mid| {
        if (count == 2) try std.testing.expectEqual(@as(f64, 0), mid.direction.?);
        if (count == 3) try std.testing.expectEqual(@as(f64, std.math.pi) / 4, mid.direction.?);
        if (count == 128) try std.testing.expectEqual(@as(f64, std.math.pi) / 2, mid.direction.?);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 129), count);
    try std.testing.expectEqual(@as(usize, 130), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 259), work.node_visits);
    try std.testing.expectEqual(@as(usize, 0), work.live);
    cursor = .{};
    work.node_visits = 0;
    // Three early nonzero anchors plus two mids consume5;the next rawmid
    // scans a long run,then stops before the command beyond this allowance.
    _ = try cursor.next(&work, path);
    _ = try cursor.next(&work, path);
    work.options.limits.node_visits = 65;
    try std.testing.expectError(error.NodeWorkExceeded, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 62), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 3), cursor.at);
    try std.testing.expectEqual(@as(usize, 65), work.node_visits);
    var cancel: v.Cancellation = .{};
    cancel.request();
    cursor = .{};
    work.node_visits = 0;
    work.options.cancellation = &cancel;
    try std.testing.expectError(error.Cancelled, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 0), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 0), work.node_visits);
    try std.testing.expectError(error.Cancelled, markers.closed(&work, path, true));
    // The smallest all-zero closed path still has one real raw mid. Both
    // segment classifications include its zero Z;the sentinel costs nothing.
    const tiny = try v.Path.create(a, &.{ .{ .move = .{ .x = 12, .y = 12 } }, .{ .line = .{ .x = 12, .y = 12 } }, .close }, .{});
    defer tiny.close() catch unreachable;
    work.options.cancellation = null;
    work.options.limits.node_visits = 6;
    work.node_visits = 0;
    const tiny_topology = try markers.closed(&work, tiny, true);
    try std.testing.expectEqual(markers.MidStrategy.zero_lines, tiny_topology.mids);
    try std.testing.expectEqual(@as(f64, 0), tiny_topology.seam.direction.?);
    cursor = .{};
    try std.testing.expectEqual(@as(f64, 0), (try cursor.next(&work, tiny)).?.direction.?);
    try std.testing.expect((try cursor.next(&work, tiny)) == null);
    try std.testing.expectEqual(@as(usize, 2), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 6), work.node_visits);
    std.debug.print("svg_marker_closed_zero_sizes topology={d} middle={d} old_cursor={d} open_zero_cursor={d} closed_zero_cursor={d}\n", .{ @sizeOf(markers.ClosedTopology), @sizeOf(markers.Middle), @sizeOf(markers.MidCursor), @sizeOf(markers.ZeroLineCursor), @sizeOf(markers.ClosedZeroLineCursor) });
}

test "closed zero line effects and analytical target bbox apply once to every role" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='green' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='7.5' y='8.25' width='10' height='9'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='6' y='6' width='4' height='4' fill='red' fill-opacity='.5'/><rect x='14' y='6' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='14' y='6' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='14' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='6' width='4' height='4' fill='green' fill-opacity='.5'/>";
    const stroke = "<path d='M8 8H16H16V16H8Z' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M8 8H16H16V16H8Z' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs>" ++ heads ++ "<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M12 12H12Z' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' clip-path='url(#c)'/></svg>", "<svg/>", mode);
        const units = "<marker id='m' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red' fill-opacity='.5'/></marker>";
        const box = "<rect x='10' y='10' width='4' height='4' fill='red' fill-opacity='.5'/>";
        try equal("<svg><defs>" ++ units ++ "</defs><path d='M12 12H12Z' fill='none' stroke='none' stroke-width='2' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg>" ++ box ++ box ++ box ++ "</svg>", mode);
        try equal("<svg><defs>" ++ units ++ "</defs><path d='M12 12H12Z' fill='none' stroke-width='0' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg/>", mode);
    }
}

test "closed zero duplicate paints share node byte allocation and reference budgets" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var regular: ?usize = null;
        for ([_][]const u8{ "M4 4H12V16H20V20Z", "M12 12H12H12H12H12Z", "M4 4H12H12V16V16Z", "M4 4H4H4V16H20Z", "M4 4H12H12H4H4Z" }, 0..) |data, i| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const document = try svg.Document.parse(a, source, .{});
            defer document.close() catch unreachable;
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
            const output = try document.prepare(a, options);
            const stats = try output.stats();
            try output.close();
            if (i == 0) regular = stats.node_visits else try std.testing.expectEqual(regular.? + 5, stats.node_visits);
            options.limits.node_visits = stats.node_visits;
            const exact = try document.prepare(a, options);
            try exact.close();
            options.limits.node_visits -= 1;
            try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
            options.limits = .{};
            options.limits.bytes = stats.peak_bytes - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        }
        var without_mid: ?usize = null;
        for ([_][]const u8{ "M4 4H12V16H20V20Z", "M12 12H12H12H12H12Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const output = try image(a, source, mode);
            const stats = try output.stats();
            try output.close();
            if (without_mid) |visits| try std.testing.expectEqual(visits, stats.node_visits) else without_mid = stats.node_visits;
        }
        const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M12 12H12Z' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer instance.close() catch unreachable;
        try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .limits = .{ .reference_depth = 1 } }));
    }
}

test "existing zero Z markers retain complete pixel allocation and work fingerprints" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M8 12A4 4 0 0 1 16 12A4 4 0 0 1 8 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG zero-close fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}

test "zero Z keeps a distinct terminal mid between signed shared seam instances" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| for ([_]bool{ false, true }) |negative| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='M12 12C20 12 12 {s} 12 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{ palette, if (negative) "20" else "4" });
        defer a.free(source);
        // Three original roles coincide:seam+/-45,terminalmid+/-90,seam.
        // Every clipped palette is a distinct paint;no marker helper supplies
        // the signed matrix or the terminal rectangle coordinates.
        const seam = try std.fmt.allocPrint(a, "<g transform='translate(12 12) matrix(.7071067811865476 {s} {s} .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>{s}</g>", .{ if (negative) "-.7071067811865475" else ".7071067811865475", if (negative) ".7071067811865475" else "-.7071067811865475", palette });
        defer a.free(seam);
        const oracle = try std.fmt.allocPrint(a, "<svg><defs><clipPath id='v'><rect width='8' height='4'/></clipPath></defs>{s}<rect x='10' y='{s}' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='10' y='{s}' width='4' height='4' fill='blue' fill-opacity='{s}'/>{s}</svg>", .{ seam, if (negative) "12" else "8", opacity, if (negative) "8" else "12", opacity, seam });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "existing zero open markers retain complete pixel allocation and work fingerprints" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12H12H12V20' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG zero-open fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}

test "zero Z keeps original line polygon and nonconstant loop vertices" {
    const marker = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='blue' fill-opacity='.5019607843137255'/></marker>";
    const box = "<rect width='2' height='2' fill='blue' fill-opacity='.5019607843137255'";
    const listed = "<svg>" ++ box ++ " x='7' y='7'/>" ++ box ++ " x='23' y='7'/>" ++ box ++ " x='23' y='15'/>" ++ box ++ " x='7' y='7'/>" ++ box ++ " x='7' y='7'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "<path d='M8 8H24V16L8 8Z'", "<path d='m8 8h16v8l-16-8z'", "<polygon points='8,8 24,8 24,16 8,8'" }) |element| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ marker ++ "</defs>{s} fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{element});
            defer a.free(source);
            try equal(source, listed, mode);
        }
        for ([_][]const u8{ "M12 12Q20 12 12 12Z", "M12 12C20 12 4 12 12 12Z", "m12 12s-8 0 0 0z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ marker ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, "<svg>" ++ box ++ " x='11' y='11'/>" ++ box ++ " x='11' y='11'/>" ++ box ++ " x='11' y='11'/></svg>", mode);
        }
    }
}

test "zero Z first and terminal arc limits retain signed seam and original mid order" {
    const negative_quarter = "matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0)";
    const up = "matrix(.00000000000000006123233995736766 -1 1 .00000000000000006123233995736766 0 0)";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]struct { data: []const u8, seam: []const u8, middle: []const u8 }{
        .{ .data = "M8 12H16A4 4 0 0 1 8 12Z", .seam = negative_quarter, .middle = "rotate(45)" },
        .{ .data = "m8 12h8a-4 -4 360 1 1 -8 0z", .seam = negative_quarter, .middle = "rotate(45)" },
        .{ .data = "M8 12H16Q8 20 8 12Z", .seam = negative_quarter, .middle = "matrix(.38268343236508984 .9238795325112867 -.9238795325112867 .38268343236508984 0 0)" },
        .{ .data = "M8 12A4 4 0 0 1 16 12A4 4 0 0 1 8 12Z", .seam = up, .middle = "rotate(90)" },
        .{ .data = "M8 12A4 4 0 0 1 16 12C16 20 8 20 8 12Z", .seam = up, .middle = "rotate(90)" },
    }) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><g transform='translate(.125 .25) scale(.8)'><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></g></svg>", .{case.data});
        defer a.free(source);
        const triangle = "<path d='M0 1L6 4L0 7Z' fill='red'/>";
        const oracle = try std.fmt.allocPrint(a, "<svg><defs><clipPath id='v'><rect width='8' height='8'/></clipPath></defs><g transform='translate(.125 .25) scale(.8)'><g transform='translate(8 12) {s} translate(-6 -4)' clip-path='url(#v)'>{s}</g><g transform='translate(16 12) {s} translate(-6 -4)' clip-path='url(#v)'>{s}</g><g transform='translate(8 12) {s} translate(-6 -4)' clip-path='url(#v)'>{s}</g><g transform='translate(8 12) {s} translate(-6 -4)' clip-path='url(#v)'>{s}</g></g></svg>", .{ case.seam, triangle, case.middle, triangle, up, triangle, case.seam, triangle });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "zero Z three coincident roles retain independent colors and per mode alpha" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red' fill-opacity='.5019607843137255'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='green' fill-opacity='.5019607843137255'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker>";
    const marks = "<rect x='8' y='10' width='8' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='8' y='10' width='8' height='4' fill='green' fill-opacity='.5019607843137255'/><rect x='8' y='10' width='8' height='4' fill='blue' fill-opacity='.5019607843137255'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ heads ++ "</defs><path d='M12 12C20 12 4 12 12 12Z' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>", "<svg>" ++ marks ++ "</svg>", mode);
        const same = try image(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red' fill-opacity='.5019607843137255'/></marker></defs><path d='M12 12C20 12 4 12 12 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", mode);
        defer same.close() catch unreachable;
        const alpha: u8 = if (mode == .pixel) 224 else 223;
        const expected: [4]u8 = .{ 0, 0, alpha, alpha };
        for (0..24) |y| for (0..32) |x| try std.testing.expectEqualSlices(u8, if (x >= 8 and x < 16 and y >= 10 and y < 14) &expected else &.{ 0, 0, 0, 0 }, same.pixels[(y * 32 + x) * 4 ..][0..4]);
    }
}

test "zero Z computes only needed seam directions and retains Plan capability gates" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M12 12Q20 12 12 12Z' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M18 15L12 12L18 9Z' fill='red'/></svg>", mode);
        for ([_][]const u8{ "marker-start", "marker-end" }) |attribute| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M12 12Q20 12 12 12Z' fill='none' {s}='url(#m)'/></svg>", .{attribute});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, source, mode));
        }
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M12 12Q20 12 12 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerWidth='0' orient='auto'><rect width='2' height='2'/></marker></defs><path d='M12 12Q20 12 12 12Z' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg/>", mode);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerWidth='0' orient='auto'><use href='#absent'/></marker></defs><path d='M12 12Q20 12 12 12Z' fill='none' marker-start='url(#m)'/></svg>", mode));
        try equal("<svg><defs><marker id='m'><rect width='2' height='2'/></marker></defs><path d='M12 12C20 12 4 12 12 12Z' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs><rect id='r'/></defs><path d='M12 12Q20 12 12 12Z' fill='none' marker-start='url(#r)' marker-mid='url(#absent)' marker-end='url(#missing)'/></svg>", "<svg/>", mode);
        const reverse = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
        try equal("<svg><defs>" ++ reverse ++ "</defs><path d='M12 12C20 12 4 12 12 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M18 15L12 12L18 9Z' fill='red'/><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M6 9L12 12L6 15Z' fill='red'/></svg>", mode);
    }
}

test "zero Z original segment and mid visits stay linear with finite cancellation limits" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [131]v.Command = undefined;
    commands[0] = .{ .move = .{ .x = 4, .y = 12 } };
    for (commands[1..129], 0..) |*command, i| command.* = .{ .line = .{ .x = if (i % 2 == 0) 12 else 20, .y = if (i % 3 == 0) 8 else 20 } };
    commands[129] = .{ .line = commands[0].move };
    commands[130] = .close;
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    _ = try markers.closed(&work, path, false);
    try std.testing.expectEqual(@as(usize, 130), work.node_visits);
    work.node_visits = 0;
    _ = try markers.closed(&work, path, true);
    try std.testing.expectEqual(@as(usize, 131), work.node_visits);
    var cursor: markers.MidCursor = .{};
    var count: usize = 0;
    while (try cursor.nextClosed(&work, path)) |middle| {
        if (count == 128) {
            try std.testing.expectEqual(v.Point{ .x = 4, .y = 12 }, middle.point);
            try std.testing.expectEqual(std.math.atan2(@as(f64, -8), @as(f64, -16)), middle.direction.?);
        }
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 129), count);
    try std.testing.expectEqual(@as(usize, 260), work.node_visits);
    work.node_visits = 0;
    work.options.limits.node_visits = 130;
    try std.testing.expectError(error.NodeWorkExceeded, markers.closed(&work, path, true));
    try std.testing.expectEqual(@as(usize, 130), work.node_visits);
    work.node_visits = 0;
    work.options.limits.node_visits = 128;
    cursor = .{};
    for (0..128) |_| _ = try cursor.nextClosed(&work, path);
    try std.testing.expectError(error.NodeWorkExceeded, cursor.nextClosed(&work, path));
    var cancel: v.Cancellation = .{};
    cancel.request();
    work.node_visits = 0;
    work.options.cancellation = &cancel;
    try std.testing.expectError(error.Cancelled, markers.closed(&work, path, true));
    cursor = .{};
    try std.testing.expectError(error.Cancelled, cursor.nextClosed(&work, path));
    try std.testing.expectEqual(@as(usize, 0), work.node_visits);
    try std.testing.expectEqual(@as(usize, 0), work.live);
    std.debug.print("svg_zero_close_sizes middle={d} mid_cursor={d} point={d}\n", .{ @sizeOf(markers.Middle), @sizeOf(markers.MidCursor), @sizeOf(v.Point) });
}

test "zero Z duplicate instances share exact byte work reference and allocation budgets" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var visits: ?usize = null;
        for ([_][]const u8{ "M8 12H16V20Z", "M8 12H16H8Z", "M8 12H16A4 4 0 0 1 8 12Z", "M8 12A4 4 0 0 1 16 12C16 20 8 20 8 12Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const document = try svg.Document.parse(a, source, .{});
            defer document.close() catch unreachable;
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
            const output = try document.prepare(a, options);
            const stats = try output.stats();
            try output.close();
            if (visits) |prior| try std.testing.expectEqual(prior, stats.node_visits) else visits = stats.node_visits;
            options.limits.node_visits = stats.node_visits;
            const exact = try document.prepare(a, options);
            try exact.close();
            options.limits.node_visits -= 1;
            try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
            options.limits = .{};
            options.limits.bytes = stats.peak_bytes - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        }
        const document = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M12 12C20 12 4 12 12 12Z' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(error.ReferenceDepthFull, document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .limits = .{ .reference_depth = 1 } }));
    }
}

test "zero Z keeps whole target effects bbox and viewport reference placement" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='green' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='7.5' y='8.25' width='12' height='12'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='6' y='6' width='4' height='4' fill='red' fill-opacity='.5'/><rect x='14' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='14' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='6' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='6' y='6' width='4' height='4' fill='green' fill-opacity='.5'/>";
    const stroke = "<path d='M8 8Q16 8 16 16C16 20 8 20 8 16V8Z' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M8 8Q16 8 16 16C16 20 8 20 8 16V8Z' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke fill" else "normal"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        const view = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red' fill-opacity='.5'/></marker>";
        const box = "<rect x='6' y='11' width='6' height='4' fill='red' fill-opacity='.5'/>";
        try equal("<svg><defs>" ++ view ++ "</defs><g transform='matrix(.75 .125 .25 .75 0 0)'><path d='M8 12C16 12 0 12 8 12Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></g></svg>", "<svg><g transform='matrix(.75 .125 .25 .75 0 0)'>" ++ box ++ box ++ box ++ "</g></svg>", mode);
        try equal("<svg><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath>" ++ view ++ "</defs><path d='M8 12C16 12 0 12 8 12Z' fill='none' marker-mid='url(#m)' clip-path='url(#c)'/></svg>", "<svg/>", mode);
    }
}

test "one zero line preserves two separately painted original mids with distinct directions" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/></marker></defs><path d='M4 12H12L12 12V20' fill='none' marker-mid='url(#m)'/></svg>", .{ opacity, opacity });
        defer a.free(source);
        // The single zero line starts right and ends down:its two distinct
        // raw vertices paint right then down,not one45-degree marker.
        const oracle = try std.fmt.allocPrint(a, "<svg><rect x='8' y='10' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='12' y='10' width='4' height='4' fill='blue' fill-opacity='{s}'/><rect x='10' y='8' width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='10' y='12' width='4' height='4' fill='blue' fill-opacity='{s}'/></svg>", .{ opacity, opacity, opacity, opacity });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}
test "two zero lines retain ordered right diagonal down mids including translucent overlap" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const palette = try std.fmt.allocPrint(a, "<rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/>", .{ opacity, opacity });
        defer a.free(palette);
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'>{s}</marker></defs><path d='M4 12H12L12 12L12 12V20' fill='none' marker-mid='url(#m)'/></svg>", .{palette});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg><defs><clipPath id='v'><rect width='8' height='4'/></clipPath></defs><g transform='translate(8 10)' clip-path='url(#v)'>{s}</g><g transform='translate(12 12) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-4 -2)' clip-path='url(#v)'>{s}</g><g transform='translate(12 12) rotate(90) translate(-4 -2)' clip-path='url(#v)'>{s}</g></svg>", .{ palette, palette, palette });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "zero line leading trailing line and polyline anchors preserve duplicate paints" {
    const cases = [_]struct { element: []const u8, expected: []const u8 }{
        .{ .element = "<path d='M12 4L12 4V20'", .expected = "<path d='M15 -2L12 4L9 -2Z' fill='red'/><path d='M15 -2L12 4L9 -2Z' fill='red'/><path d='M15 14L12 20L9 14Z' fill='red'/>" },
        .{ .element = "<path d='m12 4h0v16'", .expected = "<path d='M15 -2L12 4L9 -2Z' fill='red'/><path d='M15 -2L12 4L9 -2Z' fill='red'/><path d='M15 14L12 20L9 14Z' fill='red'/>" },
        .{ .element = "<polyline points='12,4 12,4 12,20'", .expected = "<path d='M15 -2L12 4L9 -2Z' fill='red'/><path d='M15 -2L12 4L9 -2Z' fill='red'/><path d='M15 14L12 20L9 14Z' fill='red'/>" },
        .{ .element = "<path d='M4 12H20L20 12'", .expected = "<path d='M-2 9L4 12L-2 15Z' fill='red'/><path d='M14 9L20 12L14 15Z' fill='red'/><path d='M14 9L20 12L14 15Z' fill='red'/>" },
        .{ .element = "<path d='M4 12 20 12 20 12'", .expected = "<path d='M-2 9L4 12L-2 15Z' fill='red'/><path d='M14 9L20 12L14 15Z' fill='red'/><path d='M14 9L20 12L14 15Z' fill='red'/>" },
        .{ .element = "<line x1='12' y1='12' x2='12' y2='12'", .expected = "<path d='M6 9L12 12L6 15Z' fill='red'/><path d='M6 9L12 12L6 15Z' fill='red'/>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs>{s} fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{case.element});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg>{s}</svg>", .{case.expected});
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "all zero lines use positive x for each ordered original vertex" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='green' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='yellow' fill-opacity='.5019607843137255'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='purple' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='cyan' fill-opacity='.5019607843137255'/></marker>";
    const marks = "<rect x='8' y='10' width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='12' y='10' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/><rect x='8' y='10' width='4' height='4' fill='green' fill-opacity='.5019607843137255'/><rect x='12' y='10' width='4' height='4' fill='yellow' fill-opacity='.5019607843137255'/><rect x='8' y='10' width='4' height='4' fill='green' fill-opacity='.5019607843137255'/><rect x='12' y='10' width='4' height='4' fill='yellow' fill-opacity='.5019607843137255'/><rect x='8' y='10' width='4' height='4' fill='purple' fill-opacity='.5019607843137255'/><rect x='12' y='10' width='4' height='4' fill='cyan' fill-opacity='.5019607843137255'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ heads ++ "</defs><path d='M12 12L12 12H12V12' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>", "<svg>" ++ marks ++ "</svg>", mode);
        const same = try image(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red' fill-opacity='.5019607843137255'/></marker></defs><path d='M12 12H12H12H12' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", mode);
        defer same.close() catch unreachable;
        // Pixel rounds after each paint:128->192->224->240. The sample lane
        // rounds once:255*(1-(127/255)^4)=239.311...,so its final byte is239.
        const alpha: u8 = if (mode == .pixel) 240 else 239;
        const expected: [4]u8 = .{ 0, 0, alpha, alpha };
        for (0..24) |y| for (0..32) |x| try std.testing.expectEqualSlices(u8, if (x >= 8 and x < 16 and y >= 10 and y < 14) &expected else &.{ 0, 0, 0, 0 }, same.pixels[(y * 32 + x) * 4 ..][0..4]);
    }
}

test "zero line automatic reversal and unused markers follow separate endpoint limits" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12L12 12H4' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M6 9L12 12L6 15Z' fill='red'/><path d='M18 15L12 12L18 9Z' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12L12 12L12 12H4' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 12H12L12 12L12 12H4' fill='none' marker-mid='url(#m)'/></svg>", "<svg><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12L12 12L12 12H4' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M-2 9L4 12L-2 15Z' fill='red'/><path d='M10 15L4 12L10 9Z' fill='red'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerWidth='0' orient='auto'><rect width='2' height='2'/></marker></defs><path d='M4 12H12L12 12L12 12H4' fill='none' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        // Content validation intentionally precedes dimensional suppression.
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerWidth='0' orient='auto'><use href='#absent'/></marker></defs><path d='M4 12H12L12 12L12 12H4' fill='none' marker-mid='url(#m)'/></svg>", mode));
        // A single zero segment has no interior vertex or mid capability.
        try equal("<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='M12 12L12 12' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs><rect id='r'/></defs><path d='M12 12H12H12' fill='none' marker-mid='url(#r)'/></svg>", "<svg/>", mode);
        const reverse = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
        try equal("<svg><defs>" ++ reverse ++ "</defs><path d='M12 12H12' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M18 15L12 12L18 9Z' fill='red'/><path d='M6 9L12 12L6 15Z' fill='red'/></svg>", mode);
    }
}

test "zero polynomial newly supported topology still validates requested content" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "M8 8H16H16Q20 20 24 20A4 4 0 0 1 24 20Z", "M8 8H16Q20 20 24 20H24A4 4 0 0 1 24 20Z", "M8 8H8M4 4H16", "M8 8Q8 8 8 8A4 4 0 0 1 8 8Z", "M8 8A8 8 0 0 1 8 8", "M8 8H8A8 8 0 0 1 8 8H16Z", "M8 8A8 8 0 0 1 16 16H16A4 4 0 0 1 16 16Z", "M8 8" }) |data| {
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse'><use href='#absent'/></marker></defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
        defer a.free(source);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, source, mode));
    };
}

test "zero line cold scans are cumulative bounded work with no cursor allocation" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [130]v.Command = undefined;
    commands[0] = .{ .move = .{ .x = 4, .y = 12 } };
    for (commands[1..129]) |*command| command.* = .{ .line = .{ .x = 12, .y = 12 } };
    commands[129] = .{ .line = .{ .x = 12, .y = 20 } };
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    const topology = (try markers.endpoints(&work, path, "path")).?;
    try std.testing.expectEqual(markers.MidStrategy.zero_lines, topology.mids);
    try std.testing.expectEqual(@as(usize, 129), work.node_visits);
    try std.testing.expectEqual(@as(f64, 0), topology.ends.start_angle);
    try std.testing.expectEqual(@as(f64, std.math.pi) / 2, topology.ends.end_angle);
    work.node_visits = 0;
    var cursor: markers.ZeroLineCursor = .{};
    var count: usize = 0;
    while (try cursor.next(&work, path)) |middle| {
        try std.testing.expectEqual(v.Point{ .x = 12, .y = 12 }, middle.point);
        try std.testing.expectEqual(@as(f64, if (count == 0) 0 else if (count == 127) @as(f64, std.math.pi) / 2 else @as(f64, std.math.pi) / 4), middle.direction.?);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 128), count);
    try std.testing.expectEqual(@as(usize, 129), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 257), work.node_visits);
    try std.testing.expectEqual(@as(usize, 0), work.live);
    // The first returned mid must not hide unbounded lookahead:the finite
    // scan allowance stops before inspecting the next original segment.
    cursor = .{};
    work.node_visits = 0;
    work.options.limits.node_visits = 65;
    try std.testing.expectError(error.NodeWorkExceeded, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 64), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 1), cursor.at);
    try std.testing.expectEqual(@as(usize, 65), work.node_visits);
    var cancel: v.Cancellation = .{};
    cancel.request();
    cursor = .{};
    work.node_visits = 0;
    work.options.cancellation = &cancel;
    try std.testing.expectError(error.Cancelled, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 0), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 0), work.node_visits);
}

test "zero line node bytes allocation and reference limits include all duplicate instances" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var regular: ?usize = null;
        for ([_][]const u8{ "M4 8H12V16H20V20", "M12 12H12H12H12H12", "M4 8H12H12V16V16", "M4 8H4H4V16H20", "M4 8H12V16V16V16" }, 0..) |data, i| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const document = try svg.Document.parse(a, source, .{});
            defer document.close() catch unreachable;
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
            const output = try document.prepare(a, options);
            const stats = try output.stats();
            try output.close();
            if (i == 0) regular = stats.node_visits else try std.testing.expectEqual(regular.? + 4, stats.node_visits);
            options.limits.node_visits = stats.node_visits;
            const exact = try document.prepare(a, options);
            try exact.close();
            options.limits.node_visits -= 1;
            try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
            options.limits = .{};
            options.limits.bytes = stats.peak_bytes - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        }
        var without_mid: ?usize = null;
        for ([_][]const u8{ "M4 8H12V16H20V20", "M12 12H12H12H12H12" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const output = try image(a, source, mode);
            const stats = try output.stats();
            try output.close();
            if (without_mid) |visits| try std.testing.expectEqual(visits, stats.node_visits) else without_mid = stats.node_visits;
        }
        const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M4 12H12H12V20' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer instance.close() catch unreachable;
        try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .limits = .{ .reference_depth = 1 } }));
    }
}

test "zero line source order effects and degenerate bbox stay whole target" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='4' refY='4'><rect width='8' height='8' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='4' refY='4'><rect width='8' height='8' fill='blue' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='4' refY='4'><rect width='8' height='8' fill='gold' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='7.5' y='8.25' width='10' height='9'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='4' y='8' width='8' height='8' fill='red' fill-opacity='.5'/><rect x='8' y='8' width='8' height='8' fill='blue' fill-opacity='.5'/><rect x='8' y='8' width='8' height='8' fill='blue' fill-opacity='.5'/><rect x='8' y='12' width='8' height='8' fill='gold' fill-opacity='.5'/>";
    const stroke = "<path d='M8 12H12L12 12V16' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M8 12H12L12 12V16' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs>" ++ heads ++ "<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M12 12H12H12' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' clip-path='url(#c)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs>" ++ heads ++ "</defs><path d='M12 12H12H12' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>", "<svg><rect x='8' y='8' width='8' height='8' fill='red' fill-opacity='.5'/><rect x='8' y='8' width='8' height='8' fill='blue' fill-opacity='.5'/><rect x='8' y='8' width='8' height='8' fill='gold' fill-opacity='.5'/></svg>", mode);
    }
}
test "endpoint marker matches independently translated arrow geometry" {
    const source = "<svg><defs>" ++ definition ++ "</defs><line x1='8' y1='12' x2='24' y2='12' stroke='blue' stroke-width='2' marker-end='url(#m)'/></svg>";
    const oracle = "<svg><line x1='8' y1='12' x2='24' y2='12' stroke='blue' stroke-width='2'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(18 8)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "marker layout costs are explicit without a new common owner" {
    std.debug.print("svg_marker_sizes style={d} frame={d} plan={d} endpoints={d} mid_cursor={d}\n", .{ @sizeOf(@import("style.zig").Style), @sizeOf(@import("prepare.zig").Frame), @sizeOf(@import("marker.zig").Plan), @sizeOf(@import("marker.zig").Endpoints), @sizeOf(@import("marker.zig").MidCursor) });
    std.debug.print("svg_marker_zero_sizes open_topology={d} zero_cursor={d}\n", .{ @sizeOf(@import("marker.zig").OpenTopology), @sizeOf(@import("marker.zig").ZeroLineCursor) });
}
test "nonzero marker viewBox ref and letterbox keep viewport clipping in viewport coordinates" {
    const cases = [_]struct { aspect: []const u8, x: u8, y: u8 }{ .{ .aspect = "meet", .x = 16, .y = 10 }, .{ .aspect = "slice", .x = 17, .y = 11 } };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='8' viewBox='10 20 4 4' preserveAspectRatio='xMidYMid {s}' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker></defs><path d='M8 12H20' fill='none' marker-end='url(#m)'/></svg>", .{case.aspect});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg><rect x='{d}' y='{d}' width='12' height='8' fill='red'/></svg>", .{ case.x, case.y });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}
test "user space markers survive absent strokes and ignore target NSS width" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "stroke='none'", "stroke='blue' stroke-width='0'", "stroke='none' vector-effect='non-scaling-stroke'", "fill-opacity='0' stroke-opacity='0'" }) |attributes| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M8 12H24' fill='none' {s} marker-end='url(#m)'/></svg>", .{attributes});
        defer a.free(source);
        try equal(source, "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(18 8)'/></svg>", mode);
    };
}

test "auto start reverse and fixed angle units use source path directions" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const reversed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
        try equal("<svg><defs>" ++ reversed ++ "</defs><polyline points='8,12 16,6 24,12' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><g transform='translate(8 12) rotate(143.13010235415598) translate(-6 -4)'><path d='M0 1L6 4L0 7Z' fill='red'/></g><g transform='translate(24 12) rotate(36.86989764584402) translate(-6 -4)'><path d='M0 1L6 4L0 7Z' fill='red'/></g></svg>", mode);
        for ([_][]const u8{ "90", "90deg", "100grad", ".25turn", "1.5707963267948966rad" }) |angle| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' orient='{s}'><rect width='4' height='2' fill='red'/></marker></defs><path d='M8 12H16' fill='none' marker-end='url(#m)'/></svg>", .{angle});
            defer a.free(source);
            try equal(source, "<svg><rect x='14' y='12' width='2' height='4' fill='red'/></svg>", mode);
        }
    }
}
const translucent = "<marker id='r' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='4' refY='4'><rect width='8' height='8' fill='red' fill-opacity='.5'/></marker><marker id='b' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='4' refY='4'><rect width='8' height='8' fill='blue' fill-opacity='.5'/></marker>";
const boxes = "<rect x='10' y='8' width='8' height='8' fill='red' fill-opacity='.5'/><rect x='14' y='8' width='8' height='8' fill='blue' fill-opacity='.5'/>";
test "single cubic endpoint markers follow control tangents rather than the endpoint chord" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M8 8C16 8 24 8 24 16' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>";
    const oracle = "<svg><path d='M2 5L8 8L2 11Z M27 10L24 16L21 10Z' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "single arc endpoint markers follow all four analytic circle flag directions" {
    const cases = [_]struct { flags: []const u8, arrows: []const u8 }{
        .{ .flags = "0 1", .arrows = "<path d='M17 2L14 8L11 2Z' fill='red'/><path d='M14 17L8 14L14 11Z' fill='red'/>" },
        .{ .flags = "0 0", .arrows = "<path d='M20 11L14 8L20 5Z' fill='red'/><path d='M11 8L8 14L5 8Z' fill='red'/>" },
        .{ .flags = "1 0", .arrows = "<path d='M11 14L14 8L17 14Z' fill='red'/><path d='M2 11L8 14L2 17Z' fill='red'/>" },
        .{ .flags = "1 1", .arrows = "<path d='M8 5L14 8L8 11Z' fill='red'/><path d='M5 20L8 14L11 20Z' fill='red'/>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M14 8A6 6 0 {s} 8 14' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", .{case.flags});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg>{s}</svg>", .{case.arrows});
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "mixed arc original vertices include continuous A to A and A to line mids" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4' fill='none' marker-mid='url(#m)'/></svg>";
    // The two original mids point down and left. Ellipse centers,implicit
    // flatten vertices,the start and final H endpoint are not marker sites.
    const oracle = "<svg><path d='M23 6L20 12L17 6Z' fill='red'/><path d='M18 23L12 20L18 17Z' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "closed arcs retain first tangent seam and all original mids including terminal Z" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4C0 20 0 4 4 4Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    // The real closing edge points right,matching the first A outgoing and
    // final C incoming. The two curved mids point down and left.
    const oracle = "<svg><path d='M6 1L12 4L6 7Z' fill='red'/><path d='M23 6L20 12L17 6Z' fill='red'/><path d='M18 23L12 20L18 17Z' fill='red'/><path d='M10 23L4 20L10 17Z' fill='red'/><path d='M-2 1L4 4L-2 7Z' fill='red'/><path d='M6 1L12 4L6 7Z' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "closed arc semicircles use the real Z at the shared seam and final mid" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]bool{ false, true }) |large| for ([_]bool{ false, true }) |sweep| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M8 12A8 4 0 {d} {d} 24 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{ @intFromBool(large), @intFromBool(sweep) });
        defer a.free(source);
        // An upper half ellipse leaves up and enters down;the lower half
        // reverses those limits. Z points left in both,not along either A.
        // Lower-half final mid is signed-135 degrees,not CSS-normalized225.
        // These independently known coefficients avoid that2ULP difference
        // at exact sample boundaries;the viewport clip stays explicit too.
        const final_pose = if (sweep) "rotate(135)" else "matrix(-.7071067811865475 -.7071067811865476 .7071067811865476 -.7071067811865475 0 0)";
        const oracle = try std.fmt.allocPrint(a, "<svg><defs><clipPath id='v'><rect width='8' height='8'/></clipPath></defs><g transform='translate(8 12) rotate({d}) translate(-6 -4)' clip-path='url(#v)'><path d='M0 1L6 4L0 7Z' fill='red'/></g><g transform='translate(24 12) {s} translate(-6 -4)' clip-path='url(#v)'><path d='M0 1L6 4L0 7Z' fill='red'/></g><g transform='translate(8 12) rotate({d}) translate(-6 -4)' clip-path='url(#v)'><path d='M0 1L6 4L0 7Z' fill='red'/></g></svg>", .{ @as(u16, if (sweep) 225 else 135), final_pose, @as(u16, if (sweep) 225 else 135) });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "closed arc cursor covers every adjacent type and late first arcs without extra vertices" {
    const cases = [_][]const u8{ "M16 4V16A8 8 0 0 0 24 8", "M8 8Q16 8 16 16A8 8 0 0 0 24 8", "M8 8C12 8 16 8 16 16A8 8 0 0 0 24 8", "M8 8A8 8 0 0 1 16 16H28", "M8 8A8 8 0 0 1 16 16Q24 16 24 8", "M8 8A8 8 0 0 1 16 16C20 16 24 12 24 8", "M8 8A8 8 0 0 1 16 16A4 4 0 0 0 20 12" };
    const clip = "<clipPath id='c'><rect x='10' y='10' width='10' height='10'/></clipPath>";
    const oracle = "<svg><defs>" ++ clip ++ "</defs><g clip-path='url(#c)'><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(16 16) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></g></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |data| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ clip ++ "</defs><path d='{s}Z' fill='none' marker-mid='url(#m)' clip-path='url(#c)'/></svg>", .{data});
        defer a.free(source);
        try equal(source, oracle, mode);
    };
}

test "closed terminal A and relative normalized arcs keep endpoint source order" {
    const terminal = "<svg><path d='M14 1L20 4L14 7Z' fill='red'/><path d='M1 18L4 12L7 18Z' fill='red'/><path d='M6 1L12 4L6 7Z' fill='red'/><path d='M14 1L20 4L14 7Z' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M20 4C28 4 4 20 4 12A8 8 0 0 1 12 4Z", "m20 4c8 0 -16 16 -16 8a-8 -8 360 0 1 8 -8z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, terminal, mode);
        }
        // The start-only reverse must not change the shared end seam.
        const reverse = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
        try equal("<svg><defs>" ++ reverse ++ "</defs><path d='M20 4C28 4 4 20 4 12A8 8 0 0 1 12 4Z' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M26 7L20 4L26 1Z' fill='red'/><path d='M14 1L20 4L14 7Z' fill='red'/></svg>", mode);
    }
}

test "closed arc failures and automatic directions apply only to actual instances" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "marker-start", "marker-mid", "marker-end" }) |attribute| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M8 12A0 5 80 1 0 24 12Z' fill='none' {s}='url(#m)'/></svg>", .{attribute});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, source, mode));
        }
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M8 12A0 5 80 1 0 24 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><rect x='7' y='11' width='2' height='2' fill='red'/><rect x='23' y='11' width='2' height='2' fill='red'/><rect x='7' y='11' width='2' height='2' fill='red'/></svg>", mode);
        for ([_][]const u8{ "M8 8A8 8 0 0 1 16 16H20V8H16Z", "M8 8A8 8 0 0 1 16 16V8H24V20Z" }, 0..) |data, at| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' {s}='url(#m)'/></svg>", .{ data, if (at == 0) "marker-mid" else "marker-end" });
            defer a.free(source);
            const output = try image(a, source, mode);
            try output.close();
        }
        for ([_][]const u8{ "M8 8A8 8 0 0 1 8 8A8 8 0 0 1 8 8H8Z", "M8 8A8 8 0 0 1 8 8Q20 20 8 8H8Z", "M8 8A8 8 0 0 1 8 8L8 8H8Z", "M8 8A8 8 0 1 1 8 8H16Z", "M8 8H16A8 8 0 0 1 16 8V16Z", "M8 8A8 8 0 0 1 8 8H16Z", "M8 8A8 8 0 0 1 8 8C16 16 16 16 16 16Z", "M8 8A8 8 0 0 1 16 16M4 4H8Z", "M8 8A8 8 0 0 1 16 16ZH8Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedMarkerContent, image(a, source, mode));
        }
        try std.testing.expectError(error.UnsupportedArcPrecision, image(a, "<svg><defs>" ++ fixed ++ "</defs><path d='M1 0H0A1 1 0 0 1 1e-160 0V1Z' fill='none' marker-start='url(#m)'/></svg>", mode));
        // Closed M+A+Z has an actual mid,including content/NSS capability.
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse'><use href='#absent'/></marker></defs><path d='M8 8A8 8 0 0 1 16 16Z' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try acceptedGeometry("<svg><defs><marker id='m'><rect width='3' height='3'/></marker></defs><path d='M8 8A8 8 0 0 1 16 16Z' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", mode);
        try equal("<svg><defs><rect id='r'/></defs><path d='M8 8A8 8 0 1 1 8 8Z' fill='none' marker-start='url(#r)' marker-mid='url(#missing)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M8 8A8 8 0 0 1 16 16Z' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)' transform='scale(.75)'/></svg>", "<svg><rect x='5.25' y='5.25' width='1.5' height='1.5' fill='red'/><rect x='11.25' y='11.25' width='1.5' height='1.5' fill='red'/><rect x='5.25' y='5.25' width='1.5' height='1.5' fill='red'/></svg>", mode);
    }
}

test "mixed arc mids use all seven adjacent segment pairs without derivative length weighting" {
    const cases = [_][]const u8{
        "M16 4V16A8 8 0 0 0 24 8",
        "M8 8Q16 8 16 16A8 8 0 0 0 24 8",
        "M8 8C12 8 16 8 16 16A8 8 0 0 0 24 8",
        "M8 8A8 8 0 0 1 16 16H28",
        "M8 8A8 8 0 0 1 16 16Q24 16 24 8",
        "M8 8A8 8 0 0 1 16 16C20 16 24 12 24 8",
        "M8 8A8 8 0 0 1 16 16A4 4 0 0 0 20 12",
    };
    const oracle = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(16 16) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for (cases) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8A16 8 0 0 1 24 16A4 4 0 0 0 28 12' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>", mode);
    }
}

test "mixed arc normalization reflected controls rotation and zero radius retain original vertices" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M12 4a8 8 0 0 1 8 8a8 8 0 0 1 -8 8h-8", "M12 4A-8 -8 360 0 1 20 12A8 8 -360 0 1 12 20H4", "M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20Q8 20 4 20", "M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20C12 20 8 20 4 20" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, "<svg><path d='M23 6L20 12L17 6Z' fill='red'/><path d='M18 23L12 20L18 17Z' fill='red'/></svg>", mode);
        }
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 12A1 1 0 0 1 24 12V20' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M27 6L24 12L21 6Z' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M4 8H12A0 6 45 1 0 20 8H28' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M6 5L12 8L6 11Z' fill='red'/><path d='M14 5L20 8L14 11Z' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M16 24A8 4 90 0 1 12 16V8' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M9 22L12 16L15 22Z' fill='red'/></svg>", mode);
        // A preceding A contributes only its raw end to the next Q's start;
        // Q/C same-endpoint nonconstant loops still have original vertices.
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red' fill-opacity='.5019607843137255'/></marker></defs><path d='M8 8A8 8 0 0 1 16 16Q20 16 16 16H24' fill='none' marker-mid='url(#m)'/></svg>", "<svg><rect x='15' y='15' width='2' height='2' fill='red' fill-opacity='.5019607843137255'/><rect x='15' y='15' width='2' height='2' fill='red' fill-opacity='.5019607843137255'/></svg>", mode);
    }
}

test "mixed arc preflight and automatic reversal apply only to actual supported instances" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M8 8A8 8 0 0 1 16 16V8", "M8 8A8 8 0 0 1 16 16A4 4 0 0 1 20 12" }) |data| {
            const automatic = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{data});
            defer a.free(automatic);
            try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, automatic, mode));
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, "<svg><rect x='15' y='15' width='2' height='2' fill='red'/></svg>", mode);
        }
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8A8 8 0 0 1 16 16V8' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M2 5L8 8L2 11Z' fill='red'/><path d='M13 14L16 8L19 14Z' fill='red'/></svg>", mode);
        for ([_][]const u8{ "M4 4H12A8 8 0 1 1 12 4H20Z", "M4 4H12A8 8 0 0 1 20 12M4 4H8", "M4 4H12A8 8 0 0 1 12 4H20Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedMarkerContent, image(a, source, mode));
        }
        try std.testing.expectError(error.UnsupportedArcPrecision, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M1 0H0A1 1 0 0 1 1e-160 0H2' fill='none' marker-start='url(#m)' marker-mid='url(#m)'/></svg>", mode));
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-mid='url(#m)' transform='scale(.75)'/></svg>", "<svg><rect x='14.25' y='8.25' width='1.5' height='1.5' fill='red'/><rect x='8.25' y='14.25' width='1.5' height='1.5' fill='red'/></svg>", mode);
        try equal("<svg><defs><rect id='r'/></defs><path d='M8 8A8 8 0 0 1 16 16V8' fill='none' marker-mid='url(#r)'/></svg>", "<svg/>", mode);
    }
}

test "mixed arc marks remain source ordered inside shared effects and original geometry bbox" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='6' width='6' height='12' fill='green' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='gold' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='5.5' y='6.25' width='20' height='12'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const stroke = "<path d='M12 8A4 4 0 0 1 16 12A4 4 0 0 1 12 16H8' fill='none' stroke='purple' stroke-width='2'/>";
    const marks = "<rect x='6' y='2' width='12' height='12' fill='red' fill-opacity='.5'/><rect x='10' y='6' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='16' y='6' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='6' y='10' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='12' y='10' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='2' y='10' width='12' height='12' fill='gold' fill-opacity='.5'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M12 8A4 4 0 0 1 16 12A4 4 0 0 1 12 16H8' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        // Semicircle plus H has bbox[8,28]x[4,12];the final marker's
        // extension to x34,y18 must not enlarge the objectBoundingBox clip.
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red'/></marker><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M8 12A8 8 0 0 1 24 12H28' fill='none' marker-end='url(#m)' clip-path='url(#c)'/></svg>", "<svg><rect x='22' y='6' width='6' height='6' fill='red'/></svg>", mode);
    }
}

test "single arc normalized radii relative coordinates fixed and reverse directions preserve endpoint poses" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M8 8A16 8 0 0 1 24 16", "m8 8a16 8 0 0 1 16 8", "M8 8A-16 -8 360 0 1 24 16" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, "<svg><path d='M2 5L8 8L2 11Z' fill='red'/><path d='M27 10L24 16L21 10Z' fill='red'/></svg>", mode);
        }
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 12A1 1 0 0 1 24 12' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M5 18L8 12L11 18Z' fill='red'/><path d='M27 6L24 12L21 6Z' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 12A0 5 80 1 0 24 12' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M2 9L8 12L2 15Z' fill='red'/><path d='M18 9L24 12L18 15Z' fill='red'/></svg>", mode);
        const reverse = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
        try equal("<svg><defs>" ++ reverse ++ "</defs><path d='M8 8A16 8 0 0 1 24 16' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M14 11L8 8L14 5Z' fill='red'/><path d='M27 10L24 16L21 10Z' fill='red'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M8 8A16 8 0 0 1 24 16' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-end='url(#m)' transform='scale(.75)'/></svg>", "<svg><rect x='17.25' y='11.25' width='1.5' height='1.5' fill='red'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker></defs><path d='M8 8A16 8 0 0 1 24 16' fill='none' stroke='none' stroke-width='2' marker-end='url(#m)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", "<svg><rect x='20' y='14' width='12' height='8' fill='red' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", mode);
    }
}

test "single arc endpoints share whole target effects paint order and analytic bbox" {
    const effects = "<clipPath id='c'><rect x='8.5' y='6.25' width='10' height='12'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const stroke = "<path d='M14 8A6 6 0 0 1 8 14' fill='none' stroke='green' stroke-width='2'/>";
    const marks = "<rect x='10' y='4' width='8' height='8' fill='red' fill-opacity='.5'/><rect x='4' y='10' width='8' height='8' fill='blue' fill-opacity='.5'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ translucent ++ effects ++ "</defs><path d='M14 8A6 6 0 0 1 8 14' fill='none' stroke='green' stroke-width='2' marker-start='url(#r)' marker-end='url(#b)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        // The upper semicircle bbox is[8,24]x[4,12]. The end marker viewport
        // is[18,30]x[0,12];only their exact6x8 intersection survives.
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='12'><rect width='12' height='12' fill='red'/></marker><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M8 12A8 8 0 0 1 24 12' fill='none' marker-end='url(#m)' clip-path='url(#c)'/></svg>", "<svg><rect x='18' y='4' width='6' height='8' fill='red'/></svg>", mode);
    }
}

test "single arc topology reaches content validation only for actual roles" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{
            "M8 8A6 6 0 1 1 8 8", "M8 8A0 6 0 0 1 8 8", "M8 8H12A6 6 0 0 1 12 8", "M8 8A6 6 0 0 1 14 14A6 6 0 0 1 14 14", "M8 8A6 6 0 0 1 8 8L14 14Z", "M8 8A6 6 0 0 1 14 14M20 20H24",
        }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse'><use href='#absent'/></marker></defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedMarkerContent, image(a, source, mode));
        }
        try equal("<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='M8 8A6 6 0 1 1 8 8' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='M8 8A16 8 0 0 1 24 16' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs><rect id='r'/></defs><path d='M8 8A16 8 0 0 1 24 16' fill='none' marker-start='url(#r)' marker-end='url(#absent)'/></svg>", "<svg/>", mode);
        try std.testing.expectError(error.UnsupportedArcPrecision, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M0 0A1 1 0 0 1 1e-160 0' fill='none' marker-end='url(#m)'/></svg>", mode));
        try acceptedGeometry("<svg><defs><marker id='m'><rect width='3' height='3'/></marker></defs><path d='M8 8A16 8 0 0 1 24 16' fill='none' vector-effect='non-scaling-stroke' marker-end='url(#m)'/></svg>", mode);
    }
}

test "single Bezier endpoint limits use the first noncoincident control vector" {
    const right_down = "<path d='M2 5L8 8L2 11Z' fill='red'/><path d='M27 10L24 16L21 10Z' fill='red'/>";
    const down_right = "<path d='M11 2L8 8L5 2Z' fill='red'/><path d='M18 13L24 16L18 19Z' fill='red'/>";
    const right_right = "<path d='M2 5L8 8L2 11Z' fill='red'/><path d='M18 5L24 8L18 11Z' fill='red'/>";
    const cases = [_]struct { data: []const u8, arrows: []const u8 }{
        .{ .data = "M8 8Q24 8 24 16", .arrows = right_down },
        .{ .data = "m8 8q16 0 16 8", .arrows = right_down },
        .{ .data = "m8 8c8 0 16 0 16 8", .arrows = right_down },
        .{ .data = "M8 8C8 8 24 8 24 16", .arrows = right_down },
        .{ .data = "M8 8S24 8 24 16", .arrows = right_down },
        .{ .data = "m8 8s16 0 16 8", .arrows = right_down },
        .{ .data = "M8 8C8 16 24 16 24 16", .arrows = down_right },
        .{ .data = "M8 8C8 8 8 8 24 8", .arrows = right_right },
        .{ .data = "M8 8C24 8 24 8 24 8", .arrows = right_right },
        .{ .data = "M8 8Q8 8 24 8", .arrows = right_right },
        .{ .data = "M8 8Q24 8 24 8", .arrows = right_right },
        .{ .data = "M8 8T24 8", .arrows = right_right },
        .{ .data = "m8 8t16 0", .arrows = right_right },
        // Equal endpoints do not make the nonconstant curve a zero segment.
        .{ .data = "M8 12C16 12 8 4 8 12", .arrows = "<path d='M2 9L8 12L2 15Z' fill='red'/><path d='M11 6L8 12L5 6Z' fill='red'/>" },
        .{ .data = "M8 12Q16 12 8 12", .arrows = "<path d='M2 9L8 12L2 15Z' fill='red'/><path d='M14 15L8 12L14 9Z' fill='red'/>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", .{case.data});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg>{s}</svg>", .{case.arrows});
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "single Bezier fixed reverse and signed automatic angles retain the endpoint contract" {
    const reverse = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='90'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ reverse ++ "</defs><path d='M8 8C16 8 24 8 24 16' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M14 11L8 8L14 5Z' fill='red'/><path d='M27 10L24 16L21 10Z' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M8 8Q24 8 24 16' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M11 2L8 8L5 2Z' fill='red'/><path d='M27 10L24 16L21 10Z' fill='red'/></svg>", mode);
        // Known +/-45-degree matrices, independent of marker tangent helpers.
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8C12 12 20 20 24 16' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>", mode);
    }
}

test "single Bezier markers share the target effects and its analytic geometry bbox" {
    const effects = "<clipPath id='c'><rect x='10.5' y='8.25' width='12' height='8'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const stroke = "<path d='M12 12C20 12 12 4 12 12' fill='none' stroke='green' stroke-width='2'/>";
    const marks = "<rect x='8' y='8' width='8' height='8' fill='red' fill-opacity='.5'/><rect x='8' y='8' width='8' height='8' fill='blue' fill-opacity='.5'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ translucent ++ effects ++ "</defs><path d='M12 12C20 12 12 4 12 12' fill='none' stroke='green' stroke-width='2' marker-start='url(#r)' marker-end='url(#b)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        for ([_][]const u8{ "M8 12Q16 0 24 12", "M8 12C8 4 24 4 24 12" }) |data| {
            // Both independent polynomials have bbox[8,24]x[6,12]. The
            // marker extends to x30,y18;objectBBox must exclude that extension.
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red'/></marker><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='{s}' fill='none' marker-end='url(#m)' clip-path='url(#c)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, "<svg><rect x='18' y='6' width='6' height='6' fill='red'/></svg>", mode);
        }
    }
}

test "single Bezier marker units viewBox ref and target affine preserve their existing order" {
    const marker = "<marker id='m' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M8 12C16 12 20 8 20 12' fill='none' stroke='none' stroke-width='2' marker-end='url(#m)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", "<svg><rect x='16' y='10' width='12' height='8' fill='red' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M8 8Q20 4 20 12H28' fill='none' stroke='none' stroke-width='2' marker-mid='url(#m)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", "<svg><rect x='16' y='10' width='12' height='8' fill='red' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M4 4Q16 4 16 12' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-end='url(#m)' transform='scale(1.25)'/></svg>", "<svg><rect x='18.75' y='13.75' width='2.5' height='2.5' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M8 12C16 12 20 8 20 12' fill='none' stroke-width='0' marker-end='url(#m)'/></svg>", "<svg/>", mode);
        try acceptedGeometry("<svg><defs>" ++ marker ++ "</defs><path d='M8 12Q16 4 24 12' fill='none' vector-effect='non-scaling-stroke' marker-end='url(#m)'/></svg>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M8 8Q20 4 20 12H28' fill='none' stroke-width='0' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M8 8Q20 4 20 12H28' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
    }
}

test "single Bezier markers keep explicit geometry and unused reference boundaries" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse'><rect width='3' height='3'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M8 8Q8 8 8 8A4 4 0 0 1 8 8Z", "M8 8C8 8 8 8 8 8A4 4 0 0 1 8 8Z", "M8 8T8 8A4 4 0 0 1 8 8Z", "M8 8L12 8Q24 8 24 16L24 16A4 4 0 0 1 24 16Z", "M8 8Q24 8 24 16L8 8H8A4 4 0 0 1 8 8Z", "M8 8C12 8 16 12 16 16Q20 20 24 16A2 2 0 0 1 24 16Z", "M8 8Q24 8 24 16L24 16A4 4 0 0 1 24 16Z", "M8 8C12 8 16 12 16 16L8 8H8A4 4 0 0 1 8 8Z", "M8 8Q24 8 24 16M4 4H8", "M8 8A8 8 0 0 1 8 8" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try acceptedGeometry(source, mode);
        }
        try equal("<svg><defs><rect id='r'/></defs><path d='M8 8Q24 8 24 16' fill='none' stroke='blue' marker-start='url(#r)' marker-end='url(#missing)'/></svg>", "<svg><path d='M8 8Q24 8 24 16' fill='none' stroke='blue'/></svg>", mode);
        // There is no interior vertex. Do not inspect this unsupported marker
        // content or apply its strokeWidth/NSS capability gate.
        try equal("<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='M8 8C8 8 8 8 8 8' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><style>use{marker-end:url(#m)!important}</style><defs><g color='blue' display='none'><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='currentColor'/></marker></g><path id='p' d='M8 8C16 8 24 8 24 16' fill='none'/></defs><use href='#p' marker-end='none' color='red'/></svg>", "<svg><rect x='23' y='15' width='2' height='2' fill='blue'/></svg>", mode);
        try equal("<svg><style>use{marker-mid:url(#m)!important}</style><defs><g color='blue' display='none'><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='currentColor'/></marker></g><path id='p' d='M4 4Q12 4 12 12H24' fill='none'/></defs><use href='#p' marker-mid='none' color='red'/></svg>", "<svg><rect x='11' y='11' width='2' height='2' fill='blue'/></svg>", mode);
    }
}

test "single segment endpoint candidates use one segment visit and release every failed candidate" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var baseline_visits: ?usize = null;
        for ([_][]const u8{ "M8 8L24 16", "M8 8Q24 8 24 16", "M8 8C16 8 24 8 24 16", "M8 8A16 8 0 0 1 24 16" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const document = try svg.Document.parse(a, source, .{});
            defer document.close() catch unreachable;
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
            const output = try document.prepare(a, options);
            const stats = try output.stats();
            try output.close();
            if (baseline_visits) |visits| try std.testing.expectEqual(visits, stats.node_visits) else baseline_visits = stats.node_visits;
            options.limits.node_visits = stats.node_visits;
            const exact = try document.prepare(a, options);
            try exact.close();
            options.limits.node_visits -= 1;
            try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
            options.limits = .{};
            options.limits.bytes = stats.peak_bytes - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        }
        const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M8 8C16 8 24 8 24 16' fill='none'/></defs><use href='#p' marker-end='url(#m)'/></svg>", .{});
        defer instance.close() catch unreachable;
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        options.limits.reference_depth = 1;
        try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, options));
    }
}

test "mixed original curve vertices use segment tangents and exclude controls and the final endpoint" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M4 8H12Q12 16 20 16H28' fill='none' marker-mid='url(#m)'/></svg>";
    const oracle = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(12 8) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/><path d='M14 13L20 16L14 19Z' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, oracle, mode);
}

test "mixed mid bisectors use incoming and outgoing controls across all segment pairs" {
    const cases = [_][]const u8{
        "M4 12H12Q12 20 20 20",
        "M4 4Q12 4 12 12H24",
        "M4 12H12C12 20 20 20 20 12",
        "M4 4C12 4 12 4 12 12H24",
        "M4 4Q12 4 12 12C20 12 20 20 24 20",
        "M4 4C12 4 12 4 12 12Q20 12 20 20",
        "M4 4Q12 4 12 12Q20 12 20 20",
        "M4 4C12 4 12 4 12 12C20 12 20 20 24 20",
        // Incoming and outgoing derivative limits with coincident controls.
        "M4 4C12 4 12 12 12 12Q20 12 20 20",
        "M4 12C12 12 12 12 12 12V20",
        "M4 12H12C12 12 12 12 12 20",
        "M4 12H12Q12 12 12 20",
        "M12 4Q12 12 12 12H24",
    };
    const diagonal = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(12 12) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for (cases) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, diagonal, mode);
        }
        // A16-unit incoming line and1-unit outgoing control still bisect45.
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M4 12H20Q20 13 28 20' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(20 12) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>", mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M28 8Q20 8 12 12C4 8 4 8 4 4' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M18 15L12 12L18 9Z' fill='red'/></svg>", mode);
    }
}

test "mixed reflected controls loops and endpoint directions preserve original topology" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M4 4Q12 4 12 12T20 20", "m4 4q8 0 8 8t8 8", "M4 4C8 4 12 4 12 12S20 20 24 12", "m4 4c4 0 8 0 8 8s8 8 12 0" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, "<svg><path d='M15 6L12 12L9 6Z' fill='red'/></svg>", mode);
        }
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12C12 20 20 12 12 12H4' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(12 12) matrix(.7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/><path d='M18 15L12 12L18 9Z' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8Q16 8 16 16C16 20 24 20 24 16' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><path d='M2 5L8 8L2 11Z' fill='red'/><path d='M19 10L16 16L13 10Z' fill='red'/><path d='M21 22L24 16L27 22Z' fill='red'/></svg>", mode);
    }
}

test "mixed geometry preflight precedes instances and auto reversal is required only by actual markers" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const cusp = "M4 12H12Q4 12 4 20";
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{cusp});
        defer a.free(source);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, source, mode));
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 12H12Q4 12 4 20' fill='none' marker-mid='url(#m)'/></svg>", "<svg><rect x='11' y='11' width='2' height='2' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12Q4 12 4 20' fill='none' marker-end='url(#m)'/></svg>", "<svg><path d='M7 14L4 20L1 14Z' fill='red'/></svg>", mode);
        for ([_][]const u8{ "M4 12H12C4 12 4 12 4 4M8 8H12", "M4 12H12C4 12 4 12 4 4A2 2 0 0 1 4 4Z", "M4 12H12C4 12 4 12 4 4L4 4A4 4 0 0 1 4 4Z", "M4 12H12Q12 12 12 12A4 4 0 0 1 12 12Z", "M4 12H12C12 12 12 12 12 12A4 4 0 0 1 12 12Z" }) |data| {
            const invalid = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(invalid);
            try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, invalid, mode));
        }
        // The omitted A contributes no vertex;the retained L/C cusp is still
        // an actual180-degree automatic mid. A fixed marker paints three roles.
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12C4 12 4 12 4 4A2 2 0 0 1 4 4' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", mode));
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 12H12C4 12 4 12 4 4A2 2 0 0 1 4 4' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='3' y='3' width='2' height='2' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12C4 12 4 12 4 4L4 4A4 4 0 0 1 8 8' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", mode));
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 12H12C4 12 4 12 4 4L4 4A4 4 0 0 1 8 8' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><rect x='3' y='11' width='2' height='2' fill='red'/><rect x='11' y='11' width='2' height='2' fill='red'/><rect x='3' y='3' width='2' height='2' fill='red'/><rect x='3' y='3' width='2' height='2' fill='red'/><rect x='7' y='7' width='2' height='2' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='M4 12H12Q20 12 20 20L20 20A4 4 0 0 1 20 20Z' fill='none' marker-start='url(#m)'/></svg>", mode));
        try equal("<svg><defs><rect id='r'/></defs><path d='M4 4Q12 4 12 12H24' fill='none' marker-start='url(#r)' marker-mid='url(#missing)' marker-end='url(#r)'/></svg>", "<svg/>", mode);
    }
}

test "mixed marker source order effects and analytic bbox remain whole target operations" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='6' width='6' height='12' fill='green' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='gold' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='5.5' y='6.25' width='20' height='12'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const stroke = "<path d='M12 12Q16 8 16 12C20 12 20 16 16 16L12 12' fill='none' stroke='purple' stroke-width='2'/>";
    const marks = "<rect x='6' y='6' width='12' height='12' fill='red' fill-opacity='.5'/><rect x='10' y='6' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='16' y='6' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='10' y='10' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='16' y='10' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='6' y='6' width='12' height='12' fill='gold' fill-opacity='.5'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M12 12Q16 8 16 12C20 12 20 16 16 16L12 12' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red'/></marker><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M8 12C8 4 24 4 24 12H28' fill='none' marker-end='url(#m)' clip-path='url(#c)'/></svg>", "<svg><rect x='22' y='6' width='6' height='6' fill='red'/></svg>", mode);
    }
}

test "mixed curve candidates share per command marker bytes reference and allocation limits" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var visits: ?usize = null;
        for ([_][]const u8{ "M4 8H12V16H28", "M4 8H12Q12 16 20 16H28", "M4 4Q12 0 12 8C12 16 16 16 24 16H28", "M4 4H8V8Q24 8 24 16", "M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4", "M4 8H12A8 8 0 0 1 20 16H28", "M4 4H8V8A8 8 0 0 1 16 16", "M4 4Q12 0 12 8C12 16 16 16 24 16A8 8 0 0 1 28 20" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const document = try svg.Document.parse(a, source, .{});
            defer document.close() catch unreachable;
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
            const output = try document.prepare(a, options);
            const stats = try output.stats();
            try output.close();
            if (visits) |count| try std.testing.expectEqual(count, stats.node_visits) else visits = stats.node_visits;
            options.limits.node_visits = stats.node_visits;
            const exact = try document.prepare(a, options);
            try exact.close();
            options.limits.node_visits -= 1;
            try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
            options.limits = .{};
            options.limits.bytes = stats.peak_bytes - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        }
        const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M4 4Q12 0 12 8C12 16 16 16 24 16H28' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer instance.close() catch unreachable;
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        options.limits.reference_depth = 1;
        try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, options));
        const arc_instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer arc_instance.close() catch unreachable;
        try std.testing.expectError(error.ReferenceDepthFull, arc_instance.prepare(a, options));
    }
}

test "marker order and whole target effects include both endpoints exactly once" {
    const effects = "<clipPath id='c'><rect x='10.5' y='8.25' width='12' height='8'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]bool{ false, true }) |reversed| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ translucent ++ effects ++ "</defs><path d='M14 12H18' fill='none' stroke='green' stroke-width='4' marker-start='url(#r)' marker-end='url(#b)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (reversed) "markers stroke" else "stroke markers"});
        defer a.free(source);
        const line = "<path d='M14 12H18' fill='none' stroke='green' stroke-width='4'/>";
        const oracle = if (reversed) "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>" ++ boxes ++ line ++ "</g></svg>" else "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>" ++ line ++ boxes ++ "</g></svg>";
        try equal(source, oracle, mode);
    };
}
test "marker inheritance and cascade use definitions rather than referring element styles" {
    const cases = [_]struct { prefix: []const u8 = "", attr: []const u8 = "", suffix: []const u8 = "", visible: bool = true }{
        .{ .prefix = "<g marker-end='url(#m)'>", .suffix = "</g>" },
        .{ .prefix = "<g marker-end='url(#m)'>", .attr = "marker-end='inherit'", .suffix = "</g>" },
        .{ .prefix = "<g marker-end='url(#m)'>", .attr = "marker-end='unset'", .suffix = "</g>" },
        .{ .prefix = "<g marker-end='url(#m)'>", .attr = "marker-end='initial'", .suffix = "</g>", .visible = false },
        .{ .prefix = "<style>path{marker-end:url(#m)!important}</style>", .attr = "marker-end='none' style='marker-end:none'" },
        .{ .prefix = "<defs>", .attr = "id='p'", .suffix = "</defs><use href='#p' marker-end='url(#m)' color='red'/>" },
    };
    const marker = "<g color='blue' display='none'><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' display='none'><rect width='8' height='8' fill='currentColor' marker-end='none'/></marker></g>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ marker ++ "</defs>{s}<path d='M8 12H24' fill='none' color='red' {s}/>{s}</svg>", .{ case.prefix, case.attr, case.suffix });
        defer a.free(source);
        try equal(source, if (case.visible) "<svg><rect x='18' y='8' width='8' height='8' fill='blue'/></svg>" else "<svg/>", mode);
    };
}
test "user space marker follows outer affine even when target stroke is non scaling" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg viewBox='0 0 32 24' transform='matrix(1 0 .25 1 1 0)'><defs>" ++ definition ++ "</defs><path d='M4 6H10' transform='scale(2)' fill='none' stroke='blue' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#m)'/></svg>", "<svg viewBox='0 0 32 24' transform='matrix(1 0 .25 1 1 0)'><path d='M4 6H10' transform='scale(2)' fill='none' stroke='blue' stroke-width='2' vector-effect='non-scaling-stroke'/><path d='M0 1L6 4L0 7Z' fill='red' transform='matrix(2 0 0 2 8 4)'/></svg>", mode);
    }
}
fn allocationTrial(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode) !void {
    const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode });
    defer output.close() catch unreachable;
}
test "marker failures preserve shared work bytes and late cleanup ownership" {
    const document = try svg.Document.parse(a, "<svg><defs>" ++ definition ++ "</defs><path d='M8 12H24' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        const output = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode });
        const stats = try output.stats();
        try output.close();
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        options.limits.bytes = stats.peak_bytes - 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.node_visits = stats.node_visits - 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.reference_depth = 0;
        try std.testing.expectError(error.InvalidLimits, document.prepare(a, options));
    }
}
test "invalid marker references remain absent and extended topology is accepted" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs><rect id='r' width='3' height='3'/></defs><path d='M1 1L8 8' marker-start='url(#r)' marker-end='url(#missing)'/></svg>", "<svg><path d='M1 1L8 8'/></svg>", mode);
        for ([_]struct { data: []const u8, opposite_seam: bool = false }{
            .{ .data = "M1 1L2 1Q4 1 8 8L8 8A4 4 0 0 1 8 8Z" },
            .{ .data = "M1 1L8 8L1 1H1Q2 2 3 3A4 4 0 0 1 3 3Z", .opposite_seam = true },
            .{ .data = "M1 1L8 8M2 2L9 9" },
            .{ .data = "M1 1L1 1Q2 2 3 3A4 4 0 0 1 3 3Z", .opposite_seam = true },
            .{ .data = "M1 1" },
        }) |case| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' marker-end='url(#m)'/></svg>", .{case.data});
            defer a.free(source);
            if (case.opposite_seam)
                try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, source, mode))
            else
                try acceptedGeometry(source, mode);
        }
        try std.testing.expectError(error.UnsupportedMarkerTarget, image(a, "<svg><defs>" ++ definition ++ "</defs><rect width='10' height='10' marker-end='url(#m)'/></svg>", mode));
    }
}
test "unsupported marker definition combinations reject before content expansion" {
    const cases = [_]struct { attr: []const u8, content: []const u8 = "<rect width='8' height='8'/>", err: anyerror }{
        .{ .attr = "markerUnits='objectBoundingBox'", .err = error.UnsupportedMarkerUnits },
        .{ .attr = "markerUnits='userSpaceOnUse' markerWidth='-1'", .err = error.InvalidMarkerSize },
        .{ .attr = "markerUnits='userSpaceOnUse' markerWidth='50%'", .err = error.UnsupportedMarkerPercentage },
        .{ .attr = "markerUnits='userSpaceOnUse' refY='50%'", .err = error.UnsupportedMarkerPercentage },
        .{ .attr = "markerUnits='userSpaceOnUse' overflow='visible'", .err = error.UnsupportedMarkerOverflow },
        .{ .attr = "markerUnits='userSpaceOnUse' style='overflow:auto'", .err = error.UnsupportedMarkerOverflow },
        .{ .attr = "markerUnits='userSpaceOnUse' opacity='.5'", .err = error.UnsupportedMarkerStyle },
        .{ .attr = "markerUnits='userSpaceOnUse' transform='scale(2)'", .err = error.UnsupportedMarkerTransform },
        .{ .attr = "markerUnits='userSpaceOnUse'", .content = "<use href='#m'/>", .err = error.UnsupportedMarkerContent },
        .{ .attr = "markerUnits='userSpaceOnUse'", .content = "<path d='M0 0H4' marker-end='url(#m)'/>", .err = error.UnsupportedMarkerContent },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' {s}>{s}</marker></defs><path d='M8 12H24' marker-end='url(#m)'/></svg>", .{ case.attr, case.content });
        defer a.free(source);
        try std.testing.expectError(case.err, image(a, source, mode));
    };
}

test "default marker viewport zero dimensions and absent references have explicit behavior" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse'><rect width='8' height='8' fill='red'/></marker></defs><path d='M8 12H20' fill='none' marker-end='url(#m)'/></svg>", "<svg><rect x='20' y='12' width='3' height='3' fill='red'/></svg>", mode);
        for ([_][]const u8{ "markerWidth='0'", "markerHeight='0'", "viewBox='0 0 0 4'" }) |attribute| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' {s}><rect width='8' height='8'/></marker></defs><path d='M8 12H20' fill='none' marker-end='url(#m)'/></svg>", .{attribute});
            defer a.free(source);
            try equal(source, "<svg/>", mode);
        }
        try equal("<svg><defs><rect id='r'/></defs><path d='M2 2Q6 2 10 10' fill='none' stroke='blue' marker-end='url(#r)'/></svg>", "<svg><path d='M2 2Q6 2 10 10' fill='none' stroke='blue'/></svg>", mode);
    }
}
test "marker reference depth and unsupported content reject before a font request" {
    const document = try svg.Document.parse(a, "<svg><defs>" ++ definition ++ "<path id='p' d='M8 12H20' fill='none'/></defs><use href='#p' marker-end='url(#m)'/></svg>", .{});
    defer document.close() catch unreachable;
    const text_document = try svg.Document.parse(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse'><text>A</text></marker></defs><path d='M8 12H20' fill='none' marker-end='url(#m)'/></svg>", .{});
    defer text_document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        options.limits.reference_depth = 1;
        try std.testing.expectError(error.ReferenceDepthFull, document.prepare(a, options));
        options.limits = .{};
        var provider: @import("text_adjust_test.zig").Mock = .{};
        options.text_provider = provider.provider();
        try std.testing.expectError(error.UnsupportedMarkerContent, text_document.prepare(a, options));
        try std.testing.expectEqual(@as(usize, 0), provider.calls);
    }
}

test "fixed user space marker allocations and work retain complete fingerprints" {
    const sources = [_][]const u8{
        "<svg><defs>" ++ definition ++ "</defs><path d='M8 12H24' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='8' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker></defs><path d='M8 12H20' fill='none' marker-end='url(#m)'/></svg>",
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (sources, 0..) |source, index| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG marker fingerprint {s}/{d}: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), index, pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    };
}
test "default stroke width marker scales independently specified rectangle geometry" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs><marker id='m' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M8 12H20' fill='none' stroke-width='2' marker-end='url(#m)'/></svg>", "<svg><rect x='18' y='10' width='4' height='4' fill='red'/></svg>", mode);
    }
}

test "stroke width markers use computed target widths including absolute units and absent paints" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "", "markerUnits='strokeWidth'" }) |units| for ([_][]const u8{ "2", "2px", "1.5pt", ".125pc", ".020833333333333332in", "7.0710678118654755%" }) |width| {
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' {s} markerWidth='.125pc' markerHeight='1.5pt' refX='.75pt' refY='1px' stroke-width='9'><rect width='2' height='2' fill='red'/></marker></defs><path d='M8 12H20' fill='none' stroke='none' stroke-width='{s}' fill-opacity='0' stroke-opacity='0' marker-end='url(#m)'/></svg>", .{ units, width });
        defer a.free(source);
        try equal(source, "<svg><rect x='18' y='10' width='4' height='4' fill='red'/></svg>", mode);
    };
}
test "zero stroke width suppresses stroke units while user space markers remain independent" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "", "markerUnits='strokeWidth'" }) |units| {
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' {s}><rect width='3' height='3' fill='red'/></marker></defs><path d='M8 12H20' fill='none' stroke='blue' stroke-width='0' marker-end='url(#m)'/></svg>", .{units});
        defer a.free(source);
        try equal(source, "<svg/>", mode);
    };
}
test "stroke unit viewBox ref clip and target affine retain the specified order" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]struct { aspect: []const u8, x: f64, y: f64 }{ .{ .aspect = "meet", .x = 13, .y = 10.5 }, .{ .aspect = "slice", .x = 13.75, .y = 11.25 } }) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' preserveAspectRatio='xMidYMid {s}' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker></defs><path d='M8 12H16' fill='none' stroke-width='1.5' transform='matrix(.75 .125 .25 .75 0 0)' marker-end='url(#m)'/></svg>", .{case.aspect});
        defer a.free(source);
        // Meet maps ref to(2,1); slice maps it to(1.5,.5). Apply width1.5
        // before endpoint translation. The viewport remains6x4 marker units.
        const oracle = try std.fmt.allocPrint(a, "<svg><rect x='{d}' y='{d}' width='9' height='6' fill='red' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", .{ case.x, case.y });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}
test "stroke unit scaling reads referring cascade and preserves whole target effects" {
    const marker = "<marker id='m' markerWidth='2' markerHeight='2' refX='1' refY='1' stroke-width='9'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><style>#p{stroke-width:2!important}</style><defs>" ++ marker ++ "</defs><path id='p' d='M8 12H20' fill='none' stroke-width='3' style='stroke-width:4' marker-end='url(#m)'/></svg>", "<svg><rect x='18' y='10' width='4' height='4' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ marker ++ "<path id='p' d='M8 12H20' fill='none'/></defs><g stroke-width='2'><use href='#p' marker-end='url(#m)'/></g></svg>", "<svg><rect x='18' y='10' width='4' height='4' fill='red'/></svg>", mode);
        const effects = "<clipPath id='c'><rect x='10.5' y='8.25' width='12' height='8'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
        const heads = "<marker id='r' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5'/></marker><marker id='b' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5'/></marker>";
        try equal("<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M14 12H18' fill='none' stroke='green' stroke-width='2' marker-start='url(#r)' marker-end='url(#b)' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'><path d='M14 12H18' fill='none' stroke='green' stroke-width='2'/>" ++ boxes ++ "</g></svg>", mode);
    }
}
test "stroke width marker NSS default and explicit units accept conformal targets" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "", "markerUnits='strokeWidth'" }) |units| {
        const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' {s}><rect width='3' height='3'/></marker></defs><path d='M8 12H20' fill='none' vector-effect='non-scaling-stroke' marker-end='url(#m)'/></svg>", .{units});
        defer a.free(source);
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        const output = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode });
        try output.close();
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal("<svg><defs><marker id='m'><rect width='3' height='3'/></marker></defs><path d='M8 12H20' fill='none' stroke='blue' vector-effect='non-scaling-stroke'/></svg>", "<svg><path d='M8 12H20' fill='none' stroke='blue' vector-effect='non-scaling-stroke'/></svg>", mode);
}
test "stroke width marker candidates charge and release all allocation failures" {
    const document = try svg.Document.parse(a, "<svg><defs><marker id='m' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M8 12H20' fill='none' stroke-width='2' marker-start='url(#m)' marker-end='url(#m)'/></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
}

test "interior markers use source vertices and an equal direction bisector" {
    const cases = [_]struct { target: []const u8, oracle: []const u8 }{
        .{ .target = "<path d='M4 12H12V20' fill='none' marker-mid='url(#m)'/>", .oracle = "<path d='M-6 -3L0 0L-6 3Z' fill='red' transform='matrix(.7071067811865476 .7071067811865476 -.7071067811865476 .7071067811865476 12 12)'/>" },
        // The outgoing vertical segment is much shorter. Raw vector addition
        // would not yield45 degrees; marker orientation ignores segment length.
        .{ .target = "<polyline points='2,12 20,12 20,14' fill='none' marker-mid='url(#m)'/>", .oracle = "<path d='M-6 -3L0 0L-6 3Z' fill='red' transform='matrix(.7071067811865476 .7071067811865476 -.7071067811865476 .7071067811865476 20 12)'/>" },
        .{ .target = "<path d='M4 12H12 24' fill='none' marker-mid='url(#m)'/>", .oracle = "<path d='M6 9L12 12L6 15Z' fill='red'/>" },
        //153.4349 degrees and-153.4349 degrees bisect at180, not at0.
        .{ .target = "<path d='M24 8L16 12L4 6' fill='none' marker-mid='url(#m)'/>", .oracle = "<path d='M22 15L16 12L22 9Z' fill='red'/>" },
        .{ .target = "<path d='m24 16l-8 -4 -12 6' fill='none' marker-mid='url(#m)'/>", .oracle = "<path d='M22 15L16 12L22 9Z' fill='red'/>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs>{s}</svg>", .{case.target});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg>{s}</svg>", .{case.oracle});
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "automatic reverse affects only the start and fixed orientation handles a reversal" {
    const reversed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ reversed ++ "</defs><path d='M4 12H12V20' fill='none' marker-mid='url(#m)'/></svg>", "<svg><path d='M-6 -3L0 0L-6 3Z' fill='red' transform='matrix(.7071067811865476 .7071067811865476 -.7071067811865476 .7071067811865476 12 12)'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='2' orient='90'><rect width='4' height='2' fill='red'/></marker></defs><path d='M4 12H16 4' fill='none' marker-mid='url(#m)'/></svg>", "<svg><rect x='14' y='12' width='2' height='4' fill='red'/></svg>", mode);
        for ([_][]const u8{ definition, reversed }) |marker| {
            for ([_][]const u8{ "M4 12H16 4", "M4 4L12 12L6 6" }) |data| {
                const source = try std.fmt.allocPrint(a, "<svg><defs>{s}</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{ marker, data });
                defer a.free(source);
                try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, source, mode));
            }
        }
    }
}

test "interior markers retain path order before the final endpoint and whole target effects" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6' orient='auto'><rect width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='6' width='6' height='12' fill='green' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='gold' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='5.5' y='6.25' width='20' height='12'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const target = "<path d='M12 12H16V16H12' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'";
    // Two successive mid instances rotate45 and135 degrees. Their differently
    // colored halves overlap, making reversal of source order observable.
    const marks = "<rect x='6' y='6' width='12' height='12' fill='red' fill-opacity='.5'/><g transform='translate(16 12) rotate(45) translate(-6 -6)'><rect width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='6' width='6' height='12' fill='green' fill-opacity='.5'/></g><g transform='translate(16 16) rotate(135) translate(-6 -6)'><rect width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='6' width='6' height='12' fill='green' fill-opacity='.5'/></g><rect x='6' y='10' width='12' height='12' fill='gold' fill-opacity='.5'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]bool{ false, true }) |first| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs>" ++ target ++ " paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
        defer a.free(source);
        const stroke = "<path d='M12 12H16V16H12' fill='none' stroke='purple' stroke-width='2'/>";
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
}

test "interior marker viewBox clip reference and units compose before target affine" {
    const marker = "<marker id='m' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M4 12H16V20' fill='none' stroke='none' stroke-width='2' marker-mid='url(#m)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", "<svg><rect x='12' y='10' width='12' height='8' fill='red' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M4 12H16V20' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-mid='url(#m)' transform='scale(1.25)'/></svg>", "<svg><rect x='18.75' y='13.75' width='2.5' height='2.5' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M4 12H16V20' fill='none' stroke-width='0' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M4 12H16V20' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
    }
}

test "interior marker cascade inheritance resets and use preserve definition ancestry" {
    const marker = "<g color='blue' display='none'><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='currentColor'/></marker></g>";
    const cases = [_]struct { prefix: []const u8 = "", attr: []const u8 = "", suffix: []const u8 = "", visible: bool = true }{
        .{ .attr = "marker-mid='url(#m)'" },
        .{ .prefix = "<g marker-mid='url(#m)'>", .suffix = "</g>" },
        .{ .prefix = "<g marker-mid='url(#m)'>", .attr = "marker-mid='inherit'", .suffix = "</g>" },
        .{ .prefix = "<g marker-mid='url(#m)'>", .attr = "marker-mid='unset'", .suffix = "</g>" },
        .{ .prefix = "<g marker-mid='url(#m)'>", .attr = "marker-mid='initial'", .suffix = "</g>", .visible = false },
        .{ .prefix = "<style>path{marker-mid:url(#m)!important}</style>", .attr = "marker-mid='none' style='marker-mid:none'" },
        .{ .prefix = "<defs>", .attr = "id='p'", .suffix = "</defs><use href='#p' marker-mid='url(#m)' color='red'/>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ marker ++ "</defs>{s}<path d='M4 12H16V20' fill='none' {s}/>{s}</svg>", .{ case.prefix, case.attr, case.suffix });
        defer a.free(source);
        try equal(source, if (case.visible) "<svg><rect x='15' y='11' width='2' height='2' fill='blue'/></svg>" else "<svg/>", mode);
    };
}

test "absent or uninstantiated interior markers do not spend preparation work" {
    const marker = "<marker id='m'><rect width='3' height='3'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const sources = [_][]const u8{
            "<svg><defs>" ++ marker ++ "</defs><path d='M4 12H20' fill='none' stroke='blue' vector-effect='non-scaling-stroke'/></svg>",
            "<svg><defs>" ++ marker ++ "</defs><path d='M4 12H20' fill='none' stroke='blue' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>",
        };
        var baseline: ?@import("prepare.zig").Stats = null;
        var pixel_hash: u64 = 0;
        var allocation_count: usize = 0;
        for (sources, 0..) |source, at| {
            var probe: @import("text_paint_test.zig").PlacementProbe = .{};
            const output = try image(probe.allocator(), source, mode);
            const stats = try output.stats();
            const hash = std.hash.Wyhash.hash(0, output.pixels);
            try output.close();
            if (at == 0) {
                baseline = stats;
                pixel_hash = hash;
                allocation_count = probe.allocations;
            } else {
                // Attribute parsing charges its source bytes; drawing and
                // traversal must not inspect the uninstantiated definition.
                try std.testing.expectEqual(baseline.?.node_visits, stats.node_visits);
                try std.testing.expectEqual(baseline.?.paths, stats.paths);
                try std.testing.expectEqual(baseline.?.pixel_work, stats.pixel_work);
                try std.testing.expectEqual(baseline.?.sample_work, stats.sample_work);
                try std.testing.expectEqual(baseline.?.color_work, stats.color_work);
                try std.testing.expectEqual(pixel_hash, hash);
                try std.testing.expectEqual(allocation_count, probe.allocations);
            }
            try std.testing.expect(probe.live == 0);
        }
        try equal("<svg><defs><rect id='r'/></defs><path d='M4 12H16V20' fill='none' marker-mid='url(#r)'/></svg>", "<svg/>", mode);
        try equal("<svg><path d='M4 12H16V20' fill='none' marker-mid='url(#missing)'/></svg>", "<svg/>", mode);
    }
}

test "interior marker candidates preserve shared limits and ownership on every failure" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12V20H20' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    const document = try svg.Document.parse(a, source, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        const output = try document.prepare(a, options);
        const stats = try output.stats();
        try output.close();
        options.limits.node_visits = stats.node_visits;
        const exact = try document.prepare(a, options);
        try exact.close();
        options.limits.node_visits -= 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.bytes = stats.peak_bytes - 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
    }
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "M4 12H16V20L4 12H4Q8 8 16 12A4 4 0 0 1 16 12Z", "M4 12H16M16 12V20", "M4 12H16Q20 12 20 20L20 20A4 4 0 0 1 20 20Z", "M4 12H16 16Q20 12 20 20A4 4 0 0 1 20 20Z" }) |data| {
        const unsupported = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-mid='url(#m)'/></svg>", .{data});
        defer a.free(unsupported);
        try acceptedGeometry(unsupported, mode);
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m'><path d='M0 0H3' marker-mid='url(#m)'/></marker></defs><path d='M4 12H16V20' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try std.testing.expectError(error.UnsupportedPatternPaintServer, image(a, "<svg><defs>" ++ definition ++ "<pattern id='p' patternUnits='userSpaceOnUse' width='8' height='8'><path d='M0 0H4V8' marker-mid='url(#m)'/></pattern></defs><rect width='32' height='24' fill='url(#p)'/></svg>", mode));
    }
}

test "existing open interior marker retains complete pixel allocation and work fingerprints" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M4 12H12V20H20' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG open-mid fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}

const closed_rectangle_oracle = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 8) rotate(45) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) rotate(135) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 16) rotate(225) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>";
test "closed M L target retains complete pixel allocation and work fingerprints" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M8 8H24V16H8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG closed-fast fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}

test "closed polynomial target retains complete pixel allocation and work fingerprints" {
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M8 8C16 8 24 8 24 16H8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), source, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG closed-polynomial fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}

test "closed curve seam and last listed mid use separate closing and curve directions" {
    const oracle = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) rotate(135) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 16) rotate(225) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "M8 8Q24 8 24 16H8Z", "M8 8C16 8 24 8 24 16H8Z", "M8 8C8 8 24 8 24 16H8Z", "m8 8s16 0 16 8h-16z" }) |data| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
        defer a.free(source);
        try equal(source, oracle, mode);
    };
}

test "closed curve fallback limits and last segment tangent differ from the seam edge" {
    const last_curve = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 8) rotate(45) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 16) rotate(225) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M8 8C8 8 8 8 24 8V16H8Z", "M8 8C24 8 24 8 24 8V16H8Z", "M8 8Q8 8 24 8V16H8Z", "M8 8Q24 8 24 8V16H8Z", "m8 8t16 0v8h-16z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, closed_rectangle_oracle, mode);
        }
        for ([_][]const u8{ "M8 8H24C24 16 16 16 8 16Z", "M8 8H24C24 16 8 16 8 16Z", "M8 8H24Q24 16 8 16Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, last_curve, mode);
        }
    }
}

test "closed curve loops and reflected commands preserve every original vertex" {
    const small = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='blue' fill-opacity='.5019607843137255'/></marker>";
    const rectangle = "<rect width='2' height='2' fill='blue' fill-opacity='.5019607843137255'";
    const reflected = "<svg>" ++ rectangle ++ " x='7' y='7'/>" ++ rectangle ++ " x='23' y='15'/>" ++ rectangle ++ " x='7' y='15'/>" ++ rectangle ++ " x='7' y='7'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M8 8Q24 8 24 16T8 16Z", "M8 8C16 8 24 8 24 16S16 24 8 16Z", "m8 8q16 0 16 8t-16 0z", "m8 8c8 0 16 0 16 8s-8 8 -16 0z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ small ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, reflected, mode);
        }
        try equal("<svg><defs>" ++ small ++ "</defs><path d='M8 8H16C16 16 24 8 16 8V16H8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg>" ++ rectangle ++ " x='7' y='7'/>" ++ rectangle ++ " x='15' y='7'/>" ++ rectangle ++ " x='15' y='7'/>" ++ rectangle ++ " x='15' y='15'/>" ++ rectangle ++ " x='7' y='15'/>" ++ rectangle ++ " x='7' y='7'/></svg>", mode);
    }
}

test "closed curves retain arc mixture boundaries and require only actual automatic directions" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    const unused_seam = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 8) rotate(45) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) rotate(135) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(16 16) rotate(225) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(16 8) matrix(-.7071067811865475 -.7071067811865476 .7071067811865476 -.7071067811865475 0 0) translate(-6 -4)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8Q16 8 24 8V16H16V8Z' fill='none' marker-mid='url(#m)'/></svg>", unused_seam, mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8C16 8 24 8 24 8H8V16Z' fill='none' marker-end='url(#m)'/></svg>", "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>", mode);
        for ([_][]const u8{ "marker-start", "marker-mid", "marker-end" }) |attribute| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M8 12Q16 12 24 12Z' fill='none' {s}='url(#m)'/></svg>", .{attribute});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, source, mode));
        }
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M8 12Q16 12 24 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><rect x='7' y='11' width='2' height='2' fill='red'/><rect x='23' y='11' width='2' height='2' fill='red'/><rect x='7' y='11' width='2' height='2' fill='red'/></svg>", mode);
        for ([_][]const u8{ "M8 8Q16 8 8 8H8A4 4 0 0 1 8 8Z", "M8 8C16 8 8 16 8 8H8A4 4 0 0 1 8 8Z", "M8 8Q8 8 8 8A4 4 0 0 1 8 8Z", "M8 8H24Q24 8 24 8A4 4 0 0 1 24 8Z", "M8 8Q24 8 24 16H24A4 4 0 0 1 24 16Z", "M8 8Q24 8 24 16M4 4H8Z", "M8 8Q24 8 24 16ZH8Z", "M8 8Q24 8 24 16A4 4 0 0 1 24 16H8Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try acceptedGeometry(source, mode);
        }
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='M8 8Q24 8 24 16H24A4 4 0 0 1 24 16Z' fill='none' marker-start='url(#m)'/></svg>", mode));
        try equal("<svg><defs><rect id='r'/></defs><path d='M8 8Q16 8 8 8Z' fill='none' marker-start='url(#r)' marker-mid='url(#missing)'/></svg>", "<svg/>", mode);
    }
}

test "closed curve work bytes reference and allocation failures share the original ledger" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var visits: ?usize = null;
        for ([_][]const u8{ "M8 8H24V16H8Z", "M8 8Q24 8 24 16H16H8Z", "M8 8H24V16Q16 24 8 16Z", "M8 8Q24 8 24 16C16 16 16 20 16 16H8Z", "M8 8A8 8 0 0 1 16 16H24V20Z", "M8 8H16A8 8 0 0 1 24 16H8Z", "M8 8H24V16A8 8 0 0 1 16 24Z", "M8 8A8 8 0 0 1 16 16A8 8 0 0 1 8 24H4Z", "M8 8Q16 8 16 16C16 20 24 20 24 16A8 8 0 0 0 16 8Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            const document = try svg.Document.parse(a, source, .{});
            defer document.close() catch unreachable;
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
            const output = try document.prepare(a, options);
            const stats = try output.stats();
            try output.close();
            if (visits) |count| try std.testing.expectEqual(count, stats.node_visits) else visits = stats.node_visits;
            options.limits.node_visits = stats.node_visits;
            const exact = try document.prepare(a, options);
            try exact.close();
            options.limits.node_visits -= 1;
            try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
            options.limits = .{};
            options.limits.bytes = stats.peak_bytes - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        }
        const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M8 8Q24 8 24 16H8Z' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer instance.close() catch unreachable;
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        options.limits.reference_depth = 1;
        try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, options));
        const arc_instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M8 8Q16 8 16 16A8 8 0 0 0 24 8Z' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
        defer arc_instance.close() catch unreachable;
        try std.testing.expectError(error.ReferenceDepthFull, arc_instance.prepare(a, options));
    }
}

test "closed arc source order whole effects and original analytic bbox remain shared" {
    const effects = "<clipPath id='c'><rect x='8.5' y='5.25' width='15' height='13'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='8' y='6' width='8' height='8' fill='red' fill-opacity='.5'/><rect x='12' y='6' width='8' height='8' fill='blue' fill-opacity='.5'/><rect x='12' y='10' width='8' height='8' fill='blue' fill-opacity='.5'/><rect x='8' y='10' width='8' height='8' fill='blue' fill-opacity='.5'/><rect x='8' y='6' width='8' height='8' fill='red' fill-opacity='.5'/>";
    const stroke = "<path d='M12 10A2 2 0 0 1 16 10V14H12Z' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ translucent ++ effects ++ "</defs><path d='M12 10A2 2 0 0 1 16 10V14H12Z' fill='none' stroke='purple' stroke-width='2' marker-start='url(#r)' marker-mid='url(#b)' marker-end='url(#r)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        // The upper half ellipse has bbox[8,24]x[8,12],including Z. The fixed
        // end marker at p0 is clipped to its independently known6x4 corner.
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red'/></marker><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='M8 12A8 4 0 0 1 24 12Z' fill='none' marker-end='url(#m)' clip-path='url(#c)'/></svg>", "<svg><rect x='8' y='8' width='6' height='4' fill='red'/></svg>", mode);
    }
}

test "closed curve target effects and analytic bbox include markers only once" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='6' width='6' height='12' fill='green' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='gold' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='8.5' y='5.25' width='15' height='13'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='6' y='4' width='12' height='12' fill='red' fill-opacity='.5'/><rect x='10' y='4' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='16' y='4' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='10' y='8' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='16' y='8' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='6' y='8' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='12' y='8' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='6' y='4' width='12' height='12' fill='gold' fill-opacity='.5'/>";
    const stroke = "<path d='M12 10C14 8 16 8 16 10V14H12Z' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='M12 10C14 8 16 8 16 10V14H12Z' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        for ([_][]const u8{ "M8 12Q16 0 24 12Z", "M8 12C8 4 24 4 24 12Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red'/></marker><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='{s}' fill='none' marker-end='url(#m)' clip-path='url(#c)'/></svg>", .{data});
            defer a.free(source);
            // Both curves have independent bbox[8,24]x[6,12];the end marker
            // is at p0=(8,12),not the last curve endpoint=(24,12).
            try equal(source, "<svg><rect x='8' y='6' width='6' height='6' fill='red'/></svg>", mode);
        }
    }
}

test "closed path uses the seam bisector for both endpoints and keeps the last listed mid" {
    // CSS rotate normalizes-45 to315 degrees. These known signed-radian
    // matrices keep that unrelated ULP choice out of the seam pixel oracle.
    const css_pose = try @import("numbers.zig").transform("rotate(-45)");
    const signed_angle = -@as(f64, std.math.pi) / 4;
    std.debug.print("SVG closed angle bits: css-cos={x} signed-cos={x} css-sin={x} signed-sin={x}\n", .{ @as(u64, @bitCast(css_pose.xx)), @as(u64, @bitCast(@cos(signed_angle))), @as(u64, @bitCast(css_pose.yx)), @as(u64, @bitCast(@sin(signed_angle))) });
    const source = "<svg><defs>" ++ definition ++ "</defs><path d='M8 8H24V16H8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, closed_rectangle_oracle, mode);
}
test "polygon markers preserve the equivalent closed source vertices" {
    const source = "<svg><defs>" ++ definition ++ "</defs><polygon points='8,8 24,8 24,16 8,16' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, closed_rectangle_oracle, mode);
}

test "closed reverse winding and auto start reverse keep independent endpoint orientations" {
    const ccw = "<svg><defs>" ++ definition ++ "</defs><path d='M8 8V16H24V8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    const ccw_oracle = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) rotate(135) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 16) rotate(45) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 8) matrix(-.7071067811865475 -.7071067811865476 .7071067811865476 -.7071067811865475 0 0) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) rotate(135) translate(-6 -4)'/></svg>";
    const reversed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='8' refX='6' refY='4' orient='auto-start-reverse'><path d='M0 1L6 4L0 7Z' fill='red'/></marker>";
    const reverse_oracle = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) rotate(135) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 8) rotate(45) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) rotate(135) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 16) rotate(225) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>";
    const open_oracle = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 8) rotate(45) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) rotate(135) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 16) rotate(225) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(0 -1 1 0 0 0) translate(-6 -4)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal(ccw, ccw_oracle, mode);
        try equal("<svg><defs>" ++ reversed ++ "</defs><path d='M8 8H24V16H8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", reverse_oracle, mode);
        // Returning to the first coordinate with L is still an open subpath.
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8H24V16H8V8' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", open_oracle, mode);
    }
}

test "closed marker source order and whole target effects apply to all instances once" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='6' width='6' height='12' fill='green' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='gold' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='8.5' y='5.25' width='15' height='13'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const marks = "<rect x='6' y='4' width='12' height='12' fill='red' fill-opacity='.5'/><rect x='10' y='4' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='16' y='4' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='10' y='8' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='16' y='8' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='6' y='8' width='6' height='12' fill='blue' fill-opacity='.5'/><rect x='12' y='8' width='6' height='12' fill='green' fill-opacity='.5'/><rect x='6' y='4' width='12' height='12' fill='gold' fill-opacity='.5'/>";
    const stroke = "<path d='M12 10H16V14H12Z' fill='none' stroke='purple' stroke-width='2'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]bool{ false, true }) |first| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><polygon points='12,10 16,10 16,14 12,14' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
        defer a.free(source);
        const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
        defer a.free(oracle);
        try equal(source, oracle, mode);
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='12' refX='6' refY='6'><rect width='12' height='12' fill='blue'/></marker><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><polygon points='12,10 16,10 16,14 12,14' fill='none' marker-end='url(#m)' clip-path='url(#c)'/></svg>", "<svg><rect x='12' y='10' width='4' height='4' fill='blue'/></svg>", mode);
}

test "closed marker units and nonzero viewBox reference keep the target affine order" {
    const marker = "<marker id='m' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ marker ++ "</defs><polygon points='16,12 24,12 24,20 16,20' fill='none' stroke='none' stroke-width='2' marker-end='url(#m)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", "<svg><rect x='12' y='10' width='12' height='8' fill='red' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M16 12Q24 8 24 20L16 20Z' fill='none' stroke='none' stroke-width='2' marker-end='url(#m)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", "<svg><rect x='12' y='10' width='12' height='8' fill='red' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", mode);
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M8 8H16V16H8Z' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-end='url(#m)' transform='scale(2)'/></svg>", "<svg><rect x='14' y='14' width='4' height='4' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M8 8H16V16H8Z' fill='none' stroke-width='0' marker-end='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><polygon points='8,8 16,8 16,16 8,16' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M8 8Q16 8 16 16H8Z' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-end='url(#m)' transform='scale(2)'/></svg>", "<svg><rect x='14' y='14' width='4' height='4' fill='red'/></svg>", mode);
        try equal("<svg><defs>" ++ marker ++ "</defs><path d='M8 8Q16 8 16 16H8Z' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", "<svg/>", mode);
    }
}

test "closed direction failures concern only the actual automatic instances" {
    const unused_seam_oracle = "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 8) rotate(45) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(24 16) rotate(135) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(16 16) rotate(225) translate(-6 -4)'/><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(16 8) matrix(-.7071067811865475 -.7071067811865476 .7071067811865476 -.7071067811865475 0 0) translate(-6 -4)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8H24V16H16V8Z' fill='none' marker-mid='url(#m)'/></svg>", unused_seam_oracle, mode);
        try equal("<svg><defs>" ++ definition ++ "</defs><path d='M8 8H24H8V16Z' fill='none' marker-end='url(#m)'/></svg>", "<svg><path d='M0 1L6 4L0 7Z' fill='red' transform='translate(8 8) matrix(.7071067811865476 -.7071067811865475 .7071067811865475 .7071067811865476 0 0) translate(-6 -4)'/></svg>", mode);
        for ([_][]const u8{ "marker-start", "marker-mid", "marker-end" }) |attribute| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ definition ++ "</defs><path d='M8 12H24Z' fill='none' {s}='url(#m)'/></svg>", .{attribute});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, source, mode));
        }
        try equal("<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><polygon points='8,12 24,12' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", "<svg><rect x='7' y='11' width='2' height='2' fill='red'/><rect x='23' y='11' width='2' height='2' fill='red'/><rect x='7' y='11' width='2' height='2' fill='red'/></svg>", mode);
    }
}

test "closed source vertices include omitted arcs and multiple subpaths" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse'><rect width='3' height='3'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M8 8H24Q24 12 24 16L8 8H8A4 4 0 0 1 8 8Z", "M8 8H24H24Q24 12 24 16A4 4 0 0 1 24 16Z", "M8 8H24ZV16Z", "M8 8H24M24 8V16Z", "M8 8H24Q24 8 24 8A4 4 0 0 1 24 8Z", "M8 8Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-end='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try acceptedGeometry(source, mode);
        }
        try equal("<svg><defs>" ++ fixed ++ "</defs><polygon points='8,8 24,8 24,16 8,8 8,8' fill='none' marker-mid='url(#m)'/></svg>", "<svg><rect x='24' y='8' width='3' height='3'/><rect x='24' y='16' width='3' height='3'/><rect x='8' y='8' width='3' height='3'/><rect x='8' y='8' width='3' height='3'/></svg>", mode);
        try equal("<svg><defs><rect id='r'/></defs><polygon points='8,8 24,8 24,16' fill='none' marker-start='url(#r)' marker-mid='url(#missing)'/></svg>", "<svg/>", mode);
    }
}

test "closed marker use cascade and definition ancestry remain separate" {
    const marker = "<g color='blue' display='none'><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='currentColor'/></marker></g>";
    const blue_boxes = "<svg><rect x='23' y='7' width='2' height='2' fill='blue'/><rect x='23' y='15' width='2' height='2' fill='blue'/><rect x='7' y='15' width='2' height='2' fill='blue'/></svg>";
    const cases = [_]struct { prefix: []const u8 = "", attr: []const u8 = "", suffix: []const u8 = "", visible: bool = true }{
        .{ .attr = "marker-mid='url(#m)'" },
        .{ .prefix = "<g marker-mid='url(#m)'>", .attr = "marker-mid='inherit'", .suffix = "</g>" },
        .{ .prefix = "<g marker-mid='url(#m)'>", .attr = "marker-mid='unset'", .suffix = "</g>" },
        .{ .prefix = "<g marker-mid='url(#m)'>", .attr = "marker-mid='initial'", .suffix = "</g>", .visible = false },
        .{ .prefix = "<style>path{marker-mid:url(#m)!important}</style>", .attr = "marker-mid='none' style='marker-mid:none'" },
        .{ .prefix = "<defs>", .attr = "id='p'", .suffix = "</defs><use href='#p' marker-mid='url(#m)' color='red'/>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ marker ++ "</defs>{s}<path d='M8 8H24V16H8Z' fill='none' {s}/>{s}</svg>", .{ case.prefix, case.attr, case.suffix });
        defer a.free(source);
        try equal(source, if (case.visible) blue_boxes else "<svg/>", mode);
    };
}

test "closed marker work byte and reference limits preserve all failure ownership" {
    const document = try svg.Document.parse(a, "<svg><defs>" ++ definition ++ "</defs><polygon points='8,8 24,8 24,16 8,16' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{});
    defer document.close() catch unreachable;
    const instance = try svg.Document.parse(a, "<svg><defs>" ++ definition ++ "<path id='p' d='M8 8H24V16H8Z' fill='none'/></defs><use href='#p' marker-end='url(#m)'/></svg>", .{});
    defer instance.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        const output = try document.prepare(a, options);
        const stats = try output.stats();
        try output.close();
        options.limits.node_visits = stats.node_visits;
        const exact = try document.prepare(a, options);
        try exact.close();
        options.limits.node_visits -= 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.bytes = stats.peak_bytes - 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.reference_depth = 1;
        try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, options));
    }
}

test "existing closed zero arcs retain complete pixel allocation and work fingerprints" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: @import("text_paint_test.zig").PlacementProbe = .{};
        const output = try image(probe.allocator(), closed_zero_arc_positive, mode);
        const pixels = std.hash.Wyhash.hash(0, output.pixels);
        const stats = try output.stats();
        try output.close();
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG zero-arc-closed fingerprint {s}/0: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} paths={d} visits={d} style={d} parse={d} pixel-work={d} sample-work={d} scan={d} color={d} scene={d} sort={d}\n", .{ @tagName(mode), pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.paths, stats.node_visits, stats.style_work, stats.parse_work, stats.pixel_work, stats.sample_work, stats.scan_tests, stats.color_work, stats.scene_work, stats.sort_work });
    }
}

const omitted_arc_positive = "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M8 8H16A7 7 0 1 1 16 8V16' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const omitted_arc_positive_oracle = "<svg><rect x='7' y='7' width='2' height='2' fill='red'/><rect x='15' y='7' width='2' height='2' fill='red'/><rect x='15' y='15' width='2' height='2' fill='red'/></svg>";
test "omitted arc retained roles public pixel positive" {
    try equal(omitted_arc_positive, omitted_arc_positive_oracle, .pixel);
}
test "omitted arc retained roles public compiled sample positive" {
    try equal(omitted_arc_positive, omitted_arc_positive_oracle, .sample_color);
}

const OmittedRole = struct { x: i32, y: i32, angle: enum { right, diagonal, down, left } };
fn omittedPaletteOracle(allocator: std.mem.Allocator, roles: []const OmittedRole, opacity: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "<svg>");
    for (roles) |role| {
        const matrix = switch (role.angle) {
            .right => "1 0 0 1",
            .diagonal => ".7071067811865476 .7071067811865475 -.7071067811865475 .7071067811865476",
            .down => "0 1 -1 0",
            .left => "-1 0 0 -1",
        };
        const element = try std.fmt.allocPrint(allocator, "<g transform='translate({d} {d}) matrix({s} 0 0)'><rect x='-4' y='-2' width='4' height='4' fill='red' fill-opacity='{s}'/><rect y='-2' width='4' height='4' fill='blue' fill-opacity='{s}'/></g>", .{ role.x, role.y, matrix, opacity, opacity });
        defer allocator.free(element);
        try bytes.appendSlice(allocator, element);
    }
    try bytes.appendSlice(allocator, "</svg>");
    return bytes.toOwnedSlice(allocator);
}
const omitted_palette = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='{s}'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='{s}'/></marker>";
test "omitted arcs join retained vertices once while constants keep both limits" {
    const simple = [_]OmittedRole{ .{ .x = 8, .y = 8, .angle = .right }, .{ .x = 16, .y = 8, .angle = .diagonal }, .{ .x = 16, .y = 16, .angle = .down } };
    const single_zero = [_]OmittedRole{ .{ .x = 8, .y = 8, .angle = .right }, .{ .x = 16, .y = 8, .angle = .right }, .{ .x = 16, .y = 8, .angle = .down }, .{ .x = 16, .y = 16, .angle = .down } };
    const two_zero = [_]OmittedRole{ .{ .x = 8, .y = 8, .angle = .right }, .{ .x = 16, .y = 8, .angle = .right }, .{ .x = 16, .y = 8, .angle = .diagonal }, .{ .x = 16, .y = 8, .angle = .down }, .{ .x = 16, .y = 16, .angle = .down } };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const marker = try std.fmt.allocPrint(a, omitted_palette, .{ opacity, opacity });
        defer a.free(marker);
        for ([_]struct { path: []const u8, roles: []const OmittedRole }{
            .{ .path = "M8 8H16A7 7 0 1 1 16 8V16", .roles = &simple },
            .{ .path = "M8 8A0 7 0 0 1 16 8A7 7 0 0 1 16 8V16", .roles = &simple },
            .{ .path = "M8 8H16A7 7 0 1 1 16 8A0 7 0 0 1 16 8A7 0 90 1 0 16 8V16", .roles = &simple },
            .{ .path = "M8 8a7 7 0 1 1 0 0H16a7 7 0 0 0 0 0V16a7 7 90 1 0 0 0", .roles = &simple },
            .{ .path = "M8 8H16H16A7 7 0 0 1 16 8V16", .roles = &single_zero },
            .{ .path = "M8 8H16H16H16A7 7 0 0 1 16 8V16", .roles = &two_zero },
            .{ .path = "M8 8H16Q16 8 16 8A7 7 0 0 1 16 8C16 8 16 8 16 8V16", .roles = &two_zero },
        }) |case| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>{s}</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{ marker, case.path });
            defer a.free(source);
            const oracle = try omittedPaletteOracle(a, case.roles, opacity);
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
    };
}
test "omitted arc cursor uses retained right index and real arc or loop limits" {
    const curve = [_]OmittedRole{ .{ .x = 12, .y = 4, .angle = .right }, .{ .x = 20, .y = 12, .angle = .down }, .{ .x = 20, .y = 12, .angle = .right }, .{ .x = 28, .y = 12, .angle = .right } };
    const loop = [_]OmittedRole{ .{ .x = 12, .y = 12, .angle = .right }, .{ .x = 12, .y = 12, .angle = .down }, .{ .x = 12, .y = 12, .angle = .right }, .{ .x = 20, .y = 12, .angle = .right } };
    const arcs = [_]OmittedRole{ .{ .x = 12, .y = 4, .angle = .right }, .{ .x = 20, .y = 12, .angle = .down }, .{ .x = 12, .y = 20, .angle = .left }, .{ .x = 4, .y = 20, .angle = .left } };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "1", ".5019607843137255" }) |opacity| {
        const marker = try std.fmt.allocPrint(a, omitted_palette, .{ opacity, opacity });
        defer a.free(marker);
        for ([_]struct { path: []const u8, roles: []const OmittedRole }{
            .{ .path = "M12 4A8 8 0 0 1 20 12Q20 12 20 12A7 7 0 0 1 20 12H28", .roles = &curve },
            .{ .path = "M12 12C20 12 12 4 12 12Q12 12 12 12A7 7 0 0 1 12 12H20", .roles = &loop },
            .{ .path = "M12 4A8 8 0 0 1 20 12A7 7 0 0 1 20 12A8 8 0 0 1 12 20H4", .roles = &arcs },
        }) |case| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>{s}</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{ marker, case.path });
            defer a.free(source);
            const oracle = try omittedPaletteOracle(a, case.roles, opacity);
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
    };
}
test "omitted arcs all retained constant roles preserve exact alpha" {
    const source = "<svg><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red' fill-opacity='.5019607843137255'/></marker></defs><path d='M12 12Q12 12 12 12A7 7 0 0 1 12 12C12 12 12 12 12 12' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try image(a, source, mode);
        defer output.close() catch unreachable;
        const alpha: u8 = if (mode == .pixel) 224 else 223;
        for (0..24) |y| for (0..32) |x| {
            const expected: [4]u8 = if (x >= 8 and x < 16 and y >= 10 and y < 14) .{ 0, 0, alpha, alpha } else @splat(0);
            try std.testing.expectEqualSlices(u8, &expected, output.pixels[(y * 32 + x) * 4 ..][0..4]);
        };
    }
}

test "omitted arc cold traversal charges raw scans and retained mids linearly" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var commands: [130]v.Command = undefined;
    commands[0] = .{ .move = .{ .x = 12, .y = 12 } };
    for (commands[1..]) |*command| command.* = .{ .quadratic = .{ .control = .{ .x = 12, .y = 12 }, .end = .{ .x = 12, .y = 12 } } };
    commands[65] = .{ .arc = .{ .radius = .{ .x = 7, .y = 7 }, .end = .{ .x = 12, .y = 12 } } };
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    const topology = (try markers.endpoints(&work, path, "path")).?;
    try std.testing.expectEqual(markers.MidStrategy.omitted, topology.mids);
    try std.testing.expectEqual(@as(usize, 129), work.node_visits);
    try std.testing.expectEqual(@as(f64, 0), topology.ends.start_angle);
    try std.testing.expectEqual(@as(f64, 0), topology.ends.end_angle);
    var cursor: markers.OmittedPolynomialCursor = .{};
    var count: usize = 0;
    while (try cursor.next(&work, path)) |mid| {
        try std.testing.expectEqual(v.Point{ .x = 12, .y = 12 }, mid.point);
        try std.testing.expectEqual(@as(f64, 0), mid.direction.?);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 127), count);
    try std.testing.expectEqual(@as(usize, 129), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 130), cursor.at);
    try std.testing.expectEqual(@as(usize, 514), work.node_visits);
    try std.testing.expectEqual(@as(usize, 0), work.live);
    cursor = .{};
    work.node_visits = 0;
    work.options.limits.node_visits = 65;
    try std.testing.expectError(error.NodeWorkExceeded, cursor.next(&work, path));
    try std.testing.expectEqual(@as(usize, 62), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 1), cursor.at);
    try std.testing.expectEqual(@as(usize, 65), work.node_visits);
    work.node_visits = 0;
    work.options.limits.node_visits = 128;
    try std.testing.expectError(error.NodeWorkExceeded, markers.endpoints(&work, path, "path"));
    try std.testing.expectEqual(@as(usize, 128), work.node_visits);
    var cancellation: v.Cancellation = .{};
    cancellation.request();
    work.options.cancellation = &cancellation;
    work.node_visits = 0;
    cursor = .{};
    try std.testing.expectError(error.Cancelled, cursor.next(&work, path));
    try std.testing.expectError(error.Cancelled, markers.endpoints(&work, path, "path"));
    try std.testing.expectEqual(@as(usize, 0), cursor.at);
    try std.testing.expectEqual(@as(usize, 0), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 0), work.node_visits);
    work.options.cancellation = null;
    work.options.limits = .{};
    for (commands[1..129], 0..) |*command, i| command.* = .{ .line = .{ .x = 5 + @as(f64, @floatFromInt(i)), .y = 8 } };
    commands[0] = .{ .move = .{ .x = 4, .y = 8 } };
    commands[129] = .{ .arc = .{ .radius = .{ .x = 7, .y = 7 }, .end = commands[128].line } };
    const late = try v.Path.create(a, &commands, .{});
    defer late.close() catch unreachable;
    work.node_visits = 0;
    try std.testing.expectEqual(markers.MidStrategy.omitted, (try markers.endpoints(&work, late, "path")).?.mids);
    try std.testing.expectEqual(@as(usize, 129), work.node_visits);
    cursor = .{};
    count = 0;
    while (try cursor.next(&work, late)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 127), count);
    try std.testing.expectEqual(@as(usize, 513), work.node_visits);
    try std.testing.expectEqual(@as(usize, 128), cursor.scanned);
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(markers.OpenTopology));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(markers.ClosedTopology));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(markers.MidCursor));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(markers.ZeroLineCursor));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(markers.ZeroPolynomialCursor));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(markers.OmittedPolynomialCursor));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(?usize));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(?v.Arc.Directions));
    std.debug.print("svg_omitted_arc_sizes ends={d} open={d} closed={d} ordinary={d} polynomial={d} omitted={d} directions={d} optional_index={d} optional_directions={d}\n", .{ @sizeOf(markers.Endpoints), @sizeOf(markers.OpenTopology), @sizeOf(markers.ClosedTopology), @sizeOf(markers.MidCursor), @sizeOf(markers.ZeroPolynomialCursor), @sizeOf(markers.OmittedPolynomialCursor), @sizeOf(v.Arc.Directions), @sizeOf(?usize), @sizeOf(?v.Arc.Directions) });
}
test "omitted arcs validate the first query and now accept all arities" {
    const v = @import("ziggurat_vector");
    const markers = @import("marker.zig");
    const pre = @import("prepare.zig");
    const document = try svg.Document.parse(a, "<svg/>", .{});
    defer document.close() catch unreachable;
    var work: pre.Work = .{ .allocator = a, .document = @import("document.zig").state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24 }, .live = 0, .peak = 0, .style_work = .{ .limit = 65536 }, .parse_work = .{ .limit = 65536 } };
    const commands = [_]v.Command{ .{ .move = .{ .x = 8, .y = 8 } }, .{ .arc = .{ .radius = .{ .x = 7, .y = 7 }, .end = .{ .x = 8, .y = 8 } } }, .{ .line = .{ .x = 16, .y = 8 } }, .{ .line = .{ .x = 16, .y = 16 } } };
    const path = try v.Path.create(a, &commands, .{});
    defer path.close() catch unreachable;
    // Deliberate test-only corruption of the otherwise immutable source shows
    // that the equality routing hint cannot bypass public Arc validation.
    path.commands[1].arc.radius.x = std.math.nan(f64);
    try std.testing.expectError(error.InvalidGeometry, markers.endpoints(&work, path, "path"));
    path.commands[1].arc.radius.x = 7;
    try std.testing.expectEqual(@as(usize, 1), work.node_visits);
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{
        "M8 8A7 7 0 0 1 8 8A7 7 0 0 1 8 8",
        "M8 8H16A7 7 0 0 1 16 8",
        "M8 8A7 7 0 0 1 8 8H16",
        "M8 8H16A7 7 0 0 1 16 8V16Z",
        "M8 8H16A7 7 0 0 1 16 8M20 20H24",
    }) |data| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
        defer a.free(source);
        try acceptedGeometry(source, mode);
    };
}
test "omitted arcs exact limits OOM reference and actual marker gates share the parent" {
    const fixed = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{
        "M8 8H16A7 7 0 0 1 16 8V16",
        "M8 8A7 7 0 0 1 8 8H16V16A7 7 0 0 1 16 16",
        "M12 4A8 8 0 0 1 20 12Q20 12 20 12A7 7 0 0 1 20 12H28",
        "M8 8Q8 8 8 8A7 7 0 0 1 8 8C8 8 8 8 8 8",
    }) |data| {
        const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='{s}' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>", .{data});
        defer a.free(source);
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        const output = try document.prepare(a, options);
        const stats = try output.stats();
        try output.close();
        options.limits.node_visits = stats.node_visits;
        const exact = try document.prepare(a, options);
        try exact.close();
        options.limits.node_visits -= 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.bytes = stats.peak_bytes;
        const exact_bytes = try document.prepare(a, options);
        try exact_bytes.close();
        options.limits.bytes -= 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
    };
    const instance = try svg.Document.parse(a, "<svg><defs>" ++ fixed ++ "<path id='p' d='M8 8H16A7 7 0 0 1 16 8V16' fill='none'/></defs><use href='#p' marker-mid='url(#m)'/></svg>", .{});
    defer instance.close() catch unreachable;
    try std.testing.expectError(error.ReferenceDepthFull, instance.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .limits = .{ .reference_depth = 1 } }));
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M8 8H16A7 7 0 0 1 16 8H8' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M8 8H16A7 7 0 0 1 16 8H8' fill='none' marker-start='url(#m)' marker-mid='url(#absent)' marker-end='url(#m)'/></svg>", "<svg><rect x='7' y='7' width='2' height='2' fill='red'/><rect x='7' y='7' width='2' height='2' fill='red'/></svg>", mode);
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerWidth='0'><use href='#absent'/></marker></defs><path d='M8 8H16A7 7 0 0 1 16 8V16' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try acceptedGeometry("<svg><defs><marker id='m'><rect width='2' height='2'/></marker></defs><path d='M8 8H16A7 7 0 0 1 16 8V16' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", mode);
    }
}

test "omitted markers retain whole paint effects and source geometry object bounds" {
    const heads = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='green' fill-opacity='.5'/></marker>";
    const effects = "<clipPath id='c'><rect x='7.5' y='8.25' width='10' height='9'/></clipPath><mask id='k' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect width='32' height='24' fill='white' fill-opacity='.75'/></mask>";
    const data = "M8 8H16A7 7 0 1 1 16 8V16";
    const stroke = "<path d='M8 8H16V16' fill='none' stroke='purple' stroke-width='2'/>";
    const marks = "<rect x='6' y='6' width='4' height='4' fill='red' fill-opacity='.5'/><rect x='14' y='6' width='4' height='4' fill='blue' fill-opacity='.5'/><rect x='14' y='14' width='4' height='4' fill='green' fill-opacity='.5'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]bool{ false, true }) |first| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ heads ++ effects ++ "</defs><path d='" ++ data ++ "' fill='none' stroke='purple' stroke-width='2' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' paint-order='{s}' opacity='.5' clip-path='url(#c)' mask='url(#k)' transform='matrix(.75 .125 .25 .75 0 0)'/></svg>", .{if (first) "markers stroke" else "stroke markers"});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><defs>" ++ effects ++ "</defs><g transform='matrix(.75 .125 .25 .75 0 0)'><g opacity='.5' clip-path='url(#c)' mask='url(#k)'>{s}{s}</g></g></svg>", .{ if (first) marks else stroke, if (first) stroke else marks });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><defs>" ++ heads ++ "<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><path d='" ++ data ++ "' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)' clip-path='url(#c)'/></svg>", "<svg><rect x='8' y='8' width='2' height='2' fill='red' fill-opacity='.5'/><rect x='14' y='8' width='2' height='2' fill='blue' fill-opacity='.5'/><rect x='14' y='14' width='2' height='2' fill='green' fill-opacity='.5'/></svg>", mode);
    }
}

test {
    _ = @import("marker_topology_test.zig");
}

const unified_definitions = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='#00ff00' fill-opacity='.5019607843137255'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='blue'/></marker>";
const unified_data = "M4 4A7 7 0 0 1 4 4M12 4A7 7 0 0 1 12 4H16A7 7 0 0 1 16 4ZM4 12C12 12 -4 12 4 12A7 7 0 0 1 4 12ZM20 12A7 7 0 0 1 20 12H24A7 7 0 0 1 24 12";
pub const unified_source = "<svg><defs>" ++ unified_definitions ++ "</defs><path d='" ++ unified_data ++ "' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>";
// Literal whole-path roles: one initial start, seven internal vertices (including
// both closed seam copies), and one final end. No topology helper builds this.
const unified_oracle = "<svg><rect x='3' y='3' width='2' height='2' fill='red'/><rect x='11' y='3' width='2' height='2' fill='#00ff00' fill-opacity='.5019607843137255'/><rect x='15' y='3' width='2' height='2' fill='#00ff00' fill-opacity='.5019607843137255'/><rect x='11' y='3' width='2' height='2' fill='#00ff00' fill-opacity='.5019607843137255'/><rect x='3' y='11' width='2' height='2' fill='#00ff00' fill-opacity='.5019607843137255'/><rect x='3' y='11' width='2' height='2' fill='#00ff00' fill-opacity='.5019607843137255'/><rect x='3' y='11' width='2' height='2' fill='#00ff00' fill-opacity='.5019607843137255'/><rect x='19' y='11' width='2' height='2' fill='#00ff00' fill-opacity='.5019607843137255'/><rect x='23' y='11' width='2' height='2' fill='blue'/></svg>";

test "unified marker topology has a literal whole path alpha role oracle" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal(unified_source, unified_oracle, mode);
        const point_source = "<svg><defs><marker id='s' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red' fill-opacity='.5'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='blue' fill-opacity='.5'/></marker></defs><path d='M8 8A4 4 0 0 1 8 8A4 4 0 0 1 8 8' fill='none' marker-start='url(#s)' marker-end='url(#e)'/></svg>";
        try equal(point_source, "<svg><rect x='7' y='7' width='2' height='2' fill='red' fill-opacity='.5'/><rect x='7' y='7' width='2' height='2' fill='blue' fill-opacity='.5'/></svg>", mode);
    }
}

test "unified zero or one retained segment has no phantom mid reference" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "M8 8", "M8 8A4 4 0 0 1 8 8A4 4 0 0 1 8 8", "M8 8A4 4 0 0 1 8 8H16A4 4 0 0 1 16 8", "M8 8A4 4 0 0 1 8 8Z" }) |data| {
            const source = try std.fmt.allocPrint(a, "<svg><defs><marker id='m'><use href='#absent'/></marker></defs><path d='{s}' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>", .{data});
            defer a.free(source);
            try equal(source, "<svg/>", mode);
        }
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='m' markerUnits='userSpaceOnUse'><use href='#absent'/></marker></defs><path d='M8 8H8A4 4 0 0 1 8 8H8' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ definition ++ "</defs><path d='M8 8H16A4 4 0 0 1 16 8ZM20 4V12' fill='none' marker-mid='url(#m)'/></svg>", mode));
        try acceptedGeometry("<svg><defs>" ++ unified_definitions ++ "</defs><path d='M8 8H16A4 4 0 0 1 16 8ZM20 4V12' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>", mode);
    }
}

test "unified topology charges the same parent work bytes and allocation failures" {
    const document = try svg.Document.parse(a, unified_source, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        const output = try document.prepare(a, options);
        const stats = try output.stats();
        try output.close();
        options.limits.node_visits = stats.node_visits;
        const exact = try document.prepare(a, options);
        try exact.close();
        options.limits.node_visits -= 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.bytes = stats.peak_bytes;
        const exact_bytes = try document.prepare(a, options);
        try exact_bytes.close();
        options.limits.bytes -= 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
    }
}

const host_unit_definition = "<marker id='hm' markerWidth='4' markerHeight='2' refX='2' refY='1' orient='auto'><rect width='2' height='2' fill='red'/><rect x='2' width='2' height='2' fill='blue'/></marker>";
pub const host_unit_positive = "<svg><defs>" ++ host_unit_definition ++ "</defs><path d='M4 6H10' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>";
const host_unit_oracle = "<svg><rect x='16' y='10' width='4' height='4' fill='red'/><rect x='20' y='10' width='4' height='4' fill='blue'/></svg>";

test "marker host stroke units have a literal pixel and compiled oracle" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(host_unit_positive, host_unit_oracle, mode);
}

test {
    _ = @import("marker_space_test.zig");
}

test "marker host stroke units preserve reflected rotated and outer affine bases" {
    const fixed = "<marker id='hm' markerWidth='4' markerHeight='2' refX='2' refY='1' orient='90'><rect width='2' height='2' fill='red'/><rect x='2' width='2' height='2' fill='blue'/></marker>";
    const reversed = "<marker id='hm' markerWidth='4' markerHeight='2' refX='2' refY='1' orient='auto-start-reverse'><rect width='2' height='2' fill='red'/><rect x='2' width='2' height='2' fill='blue'/></marker>";
    const cases = [_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "<path d='M4 6H10' transform='matrix(-2 0 0 2 32 0)'", .expected = "<rect x='12' y='10' width='4' height='4' fill='red'/><rect x='8' y='10' width='4' height='4' fill='blue'/>" },
        .{ .path = "<path d='M4 6H8' transform='matrix(0 2 -2 0 28 0)'", .expected = "<rect x='14' y='12' width='4' height='4' fill='red'/><rect x='14' y='16' width='4' height='4' fill='blue'/>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 6H10' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>", "<svg><rect x='18' y='8' width='4' height='4' fill='red'/><rect x='18' y='12' width='4' height='4' fill='blue'/></svg>", mode);
        try equal("<svg><defs>" ++ reversed ++ "</defs><path d='M4 6H10' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-start='url(#hm)'/></svg>", "<svg><rect x='8' y='10' width='4' height='4' fill='red'/><rect x='4' y='10' width='4' height='4' fill='blue'/></svg>", mode);
        try equal("<svg><defs>" ++ reversed ++ "</defs><path d='M4 6H10' transform='matrix(-2 0 0 2 32 0)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-start='url(#hm)'/></svg>", "<svg><rect x='20' y='10' width='4' height='4' fill='red'/><rect x='24' y='10' width='4' height='4' fill='blue'/></svg>", mode);
        for (cases) |case| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ host_unit_definition ++ "</defs>{s} fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>", .{case.path});
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg>{s}</svg>", .{case.expected});
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg transform='matrix(1 0 .25 1 1 0)'><defs>" ++ host_unit_definition ++ "</defs><path d='M4 6H10' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>", "<svg transform='matrix(1 0 .25 1 1 0)'><rect x='16' y='10' width='4' height='4' fill='red'/><rect x='20' y='10' width='4' height='4' fill='blue'/></svg>", mode);
        try equal("<svg viewBox='0 0 16 12'><defs>" ++ host_unit_definition ++ "</defs><path d='M2 3H5' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>", host_unit_oracle, mode);
        try equal("<svg><defs>" ++ host_unit_definition ++ "<path id='hp' d='M4 6H10' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></defs><use href='#hp' x='3' y='2'/></svg>", "<svg><rect x='19' y='12' width='4' height='4' fill='red'/><rect x='23' y='12' width='4' height='4' fill='blue'/></svg>", mode);
        try equal("<svg><defs>" ++ host_unit_definition ++ "</defs><svg x='2' y='2' width='16' height='12' viewBox='0 0 8 6'><path d='M2 2H6' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg></svg>", "<svg><rect x='10' y='4' width='4' height='4' fill='red'/><rect x='14' y='4' width='4' height='4' fill='blue'/></svg>", mode);
    }
}

test "marker host stroke units clip the positioning viewport before marker viewBox" {
    const definition_host = "<marker id='hm' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='12' refY='22'><rect x='-100' y='-100' width='200' height='200' fill='red'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal("<svg><defs>" ++ definition_host ++ "</defs><path d='M4 6H10' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>", "<svg><rect x='14' y='8' width='12' height='8' fill='red'/></svg>", mode);
}

test "marker host stroke units reject nonconformal only for real nonzero instances" {
    const fixed = "<marker id='hm' markerWidth='4' markerHeight='2'><rect width='4' height='2'/></marker>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "scale(2 3)", "matrix(1 0 .25 1 0 0)", "scale(0)" }) |transform| {
            const source = try std.fmt.allocPrint(a, "<svg><defs>" ++ fixed ++ "</defs><path d='M4 6H10' transform='{s}' fill='none' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>", .{transform});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedMarkerStrokeSpace, image(a, source, mode));
        }
        try equal("<svg><defs>" ++ fixed ++ "</defs><path d='M4 6H10' transform='scale(2 3)' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>", "<svg/>", mode);
        try equal("<svg><defs><marker id='hm'><use href='#missing'/></marker></defs><path d='M4 6H10' transform='scale(2 3)' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#hm)'/></svg>", "<svg/>", mode);
        try std.testing.expectError(error.UnsupportedMarkerDirection, image(a, "<svg><defs>" ++ host_unit_definition ++ "</defs><path d='M4 6H10H4' transform='scale(2)' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#hm)'/></svg>", mode));
        try std.testing.expectError(error.UnsupportedMarkerContent, image(a, "<svg><defs><marker id='hm'><use href='#missing'/></marker></defs><path d='M4 6H10' fill='none' stroke-width='0' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/></svg>", mode));
    }
}

test "marker host stroke units share node bytes allocation and final cancellation contracts" {
    const document = try svg.Document.parse(a, host_unit_positive, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode };
        const prepared = try document.prepare(a, options);
        const stats = try prepared.stats();
        try prepared.close();
        options.limits.node_visits = stats.node_visits;
        const exact = try document.prepare(a, options);
        try exact.close();
        options.limits.node_visits -= 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.bytes = stats.peak_bytes - 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
    }
}
