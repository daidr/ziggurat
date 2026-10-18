const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const a = std.testing.allocator;
const Mode = @FieldType(svg.PrepareOptions, "compositing");
const seamless = "<svg><defs><pattern id='p' patternUnits='userSpaceOnUse' x='.5' width='4' height='4'><rect width='4' height='4' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>";
pub const expanded_source = "<svg><defs><pattern id='base' width='.5' height='1' viewBox='0 0 16 24' preserveAspectRatio='none'><rect width='8' height='24' fill='red'/></pattern><pattern id='p' href='#base'/></defs><rect width='32' height='24' fill='url(#p)'/></svg>";
fn stripeOracle(input: []const u8) !void {
    const document = try svg.Document.parse(a, input, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try prepare(document, mode);
        defer output.close() catch unreachable;
        for (0..4) |y| for (0..8) |x| {
            const expected: [4]u8 = if (x % 4 < 2) .{ 0, 0, 255, 255 } else .{ 0, 0, 0, 0 };
            try std.testing.expectEqualSlices(u8, &expected, output.pixels[(y * 8 + x) * 4 ..][0..4]);
        };
    }
}
test "pattern expansion default object units and independent content units" {
    try stripeOracle("<svg><defs><pattern id='p' width='.5' height='1' patternContentUnits='objectBoundingBox'><rect width='.25' height='1' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>");
    try stripeOracle("<svg><defs><pattern id='p' width='.5' height='1'><rect width='2' height='4' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>");
}
test "pattern expansion nonzero viewBox origin none fit" {
    try stripeOracle("<svg><defs><pattern id='p' patternUnits='userSpaceOnUse' width='4' height='4' viewBox='10 20 2 4' preserveAspectRatio='none'><rect x='10' y='20' width='1' height='4' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>");
}
test "pattern expansion template content inherits host pattern style" {
    try stripeOracle("<svg><defs color='blue'><pattern id='base' patternUnits='userSpaceOnUse' width='4' height='4'><rect width='2' height='4' fill='currentColor'/></pattern><g color='red'><pattern id='p' href='#base'/></g></defs><rect width='8' height='4' fill='url(#p)'/></svg>");
}
test "pattern expansion bbox excludes stroke and transform preserves literal half coverage" {
    const document = try svg.Document.parse(a, "<svg><defs><pattern id='p' width='.5' height='1' patternContentUnits='objectBoundingBox'><rect width='.25' height='1' fill='red'/></pattern></defs><rect x='1' y='1' width='6' height='2' transform='matrix(-1 0 0 1 8 0)' fill='url(#p)'/></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try prepare(document, mode);
        defer output.close() catch unreachable;
        for (0..4) |y| for (0..8) |x| {
            const alpha: u8 = if (y == 1 or y == 2) (if (x == 3 or x == 6) 255 else if (x == 2 or x == 5) 128 else 0) else 0;
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, output.pixels[(y * 8 + x) * 4 ..][0..4]);
        };
    }
}
test "pattern expansion meet and slice retain tile clip in its own coordinates" {
    const document = try svg.Document.parse(a, "<svg><defs><pattern id='p' patternUnits='userSpaceOnUse' width='4' height='4' viewBox='0 0 4 2'><rect width='4' height='2' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try prepare(document, mode);
        defer output.close() catch unreachable;
        for (0..4) |y| for (0..8) |x| {
            const alpha: u8 = if (y == 1 or y == 2) 255 else 0;
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, output.pixels[(y * 8 + x) * 4 ..][0..4]);
        };
    }
    try stripeOracle("<svg><defs><pattern id='p' patternUnits='userSpaceOnUse' width='4' height='4' viewBox='0 0 4 2' preserveAspectRatio='xMidYMid slice'><rect width='2' height='2' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>");
    try stripeOracle("<svg><defs><pattern id='p' width='.5' height='1' viewBox='10 20 4 4' preserveAspectRatio='none'><rect x='10' y='20' width='2' height='4' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>");
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal("<svg><defs><pattern id='p' width='.5' height='.5' viewBox='0 0 4 2'><rect width='4' height='2' fill='red'/></pattern></defs><rect width='8' height='8' fill='url(#p)'/></svg>", "<svg><rect y='1' width='8' height='2' fill='red'/></svg>", mode);
    try stripeOracle("<svg><defs><pattern id='p' width='.5' height='.5' viewBox='0 0 4 2' preserveAspectRatio='xMidYMid slice'><rect width='2' height='2' fill='red'/></pattern></defs><rect width='8' height='8' fill='url(#p)'/></svg>");
}
test "pattern expansion viewBox ignores content units and supports zero geometry bbox stroke" {
    const document = try svg.Document.parse(a, "<svg><defs><pattern id='p' patternUnits='userSpaceOnUse' patternContentUnits='objectBoundingBox' width='4' height='4' viewBox='0 0 4 4'><rect width='2' height='4' fill='red'/></pattern></defs><path d='M0 2H8' fill='none' stroke='url(#p)' stroke-width='2'/></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try prepare(document, mode);
        defer output.close() catch unreachable;
        for (0..4) |y| for (0..8) |x| {
            const alpha: u8 = if ((y == 1 or y == 2) and x % 4 < 2) 255 else 0;
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, output.pixels[(y * 8 + x) * 4 ..][0..4]);
        };
    }
    const degenerate = try svg.Document.parse(a, "<svg><defs><pattern id='p' width='.5' height='1' patternContentUnits='objectBoundingBox'><rect width='1' height='1' fill='red'/></pattern></defs><path d='M0 2H8' fill='none' stroke='url(#p)' stroke-width='2'/></svg>", .{});
    defer degenerate.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const empty = try prepare(degenerate, mode);
        defer empty.close() catch unreachable;
        try std.testing.expect(std.mem.allEqual(u8, empty.pixels, 0));
    }
}
test "pattern expansion nearest template attributes and own content override" {
    try stripeOracle("<svg><defs><pattern id='a' patternUnits='userSpaceOnUse' width='8' height='4'><rect width='8' height='4' fill='blue'/></pattern><pattern id='b' href='#a' width='4'/><pattern id='p' href='#b'><desc>not content</desc><rect width='2' height='4' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>");
    const document = try svg.Document.parse(a, "<svg><defs><pattern id='a' patternUnits='userSpaceOnUse' width='4' height='4'><rect width='4' height='4' fill='red' opacity='.5'/><rect width='4' height='4' fill='blue' opacity='.5'/></pattern><pattern id='p' href='#a'><desc>still clones a</desc></pattern></defs><rect width='8' height='4' fill='url(#p)' fill-opacity='.5'/></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try prepare(document, mode);
        defer output.close() catch unreachable;
        for (0..32) |at| try std.testing.expectEqualSlices(u8, &.{ 64, 0, 32, 96 }, output.pixels[at * 4 ..][0..4]);
    }
}
test "pattern expansion direct depth one remains valid while template links consume depth" {
    const document = try svg.Document.parse(a, seamless, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4, .compositing = mode, .limits = .{ .reference_depth = 1 } });
        defer output.close() catch unreachable;
    }
    var storage: [8192]u8 = undefined;
    var count = (try std.fmt.bufPrint(&storage, "<svg><defs>", .{})).len;
    for (0..31) |i| count += (try std.fmt.bufPrint(storage[count..], "<pattern id='p{d}' href='#p{d}'/>", .{ i, i + 1 })).len;
    count += (try std.fmt.bufPrint(storage[count..], "<pattern id='p31' patternUnits='userSpaceOnUse' width='4' height='4'><rect width='2' height='4' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p0)'/></svg>", .{})).len;
    const chain = try svg.Document.parse(a, storage[0..count], .{});
    defer chain.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4, .compositing = mode, .limits = .{ .reference_depth = 32 } };
        const output = try chain.prepare(a, options);
        defer output.close() catch unreachable;
        for (0..32) |i| {
            const alpha: u8 = if (i % 8 % 4 < 2) 255 else 0;
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, output.pixels[i * 4 ..][0..4]);
        }
        options.limits.reference_depth = 31;
        try std.testing.expectError(error.ReferenceDepthFull, chain.prepare(a, options));
    }
}
test "pattern expansion coordinate policy and template failures are explicit" {
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "<svg><defs><pattern id='p' width='.5' height='1' viewBox='0 0 4 2'><rect width='4' height='2'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>", .err = error.UnsupportedPatternCoordinateSpace },
        .{ .source = "<svg><defs><pattern id='p' width='.5' height='1' patternTransform='translate(.5 0)'><rect width='4' height='2'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>", .err = error.UnsupportedPatternCoordinateSpace },
        .{ .source = "<svg><defs><pattern id='p' href='#q'/><pattern id='q' href='#p'/></defs><rect width='8' height='4' fill='url(#p)'/></svg>", .err = error.ReferenceCycle },
        .{ .source = "<svg><defs><pattern id='p' href='#q'/><g id='q'/></defs><rect width='8' height='4' fill='url(#p)'/></svg>", .err = error.UnsupportedPatternTemplate },
        .{ .source = "<svg><defs><pattern id='p' href='https://example.invalid/p.svg#q'/></defs><rect width='8' height='4' fill='url(#p)'/></svg>", .err = error.ExternalResourceDenied },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const document = try svg.Document.parse(a, case.source, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(case.err, prepare(document, mode));
    };
}
test "pattern expansion shared object-space transform rotates grid and content together" {
    const document = try svg.Document.parse(a, "<svg><defs><pattern id='p' width='.5' height='1' patternContentUnits='objectBoundingBox' patternTransform='matrix(0 1 -1 0 1 0)'><rect width='.25' height='1' fill='red'/></pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try prepare(document, mode);
        defer output.close() catch unreachable;
        for (0..4) |y| for (0..8) |x| {
            const alpha: u8 = if (y % 2 == 0) 255 else 0;
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, output.pixels[(y * 8 + x) * 4 ..][0..4]);
        };
    }
}
test "pattern expansion template bbox preparation retains all allocation and work boundaries" {
    const document = try svg.Document.parse(a, expanded_source, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        const output = try prepare(document, mode);
        const stats = try output.stats();
        try output.close();
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4, .compositing = mode };
        options.limits.node_visits = stats.node_visits - 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.bytes = stats.peak_bytes - 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.reference_depth = 1;
        try std.testing.expectError(error.ReferenceDepthFull, document.prepare(a, options));
    }
}
fn allocationPreservesPrevious(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode, previous: *svg.Prepared, expected: *const [8 * 4 * 4]u8, identity: u64) !void {
    defer {
        std.testing.expectEqualSlices(u8, expected, previous.pixels) catch @panic("candidate changed previous pixels");
        const view = previous.view() catch @panic("candidate revoked previous view");
        std.testing.expectEqual(identity, view.identity) catch @panic("candidate changed previous identity");
    }
    try allocationTrial(allocator, document, mode);
}
test "pattern expansion failed candidates preserve an existing prepared image" {
    const document = try svg.Document.parse(a, expanded_source, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const previous = try prepare(document, mode);
        defer previous.close() catch unreachable;
        var expected: [8 * 4 * 4]u8 = undefined;
        @memcpy(&expected, previous.pixels);
        const identity = (try previous.view()).identity;
        try std.testing.checkAllAllocationFailures(a, allocationPreservesPrevious, .{ document, mode, previous, &expected, identity });
    }
}
test "pattern expansion text uses full cells once in both compositing owners" {
    const Provider = struct {
        calls: usize = 0,
        cells: bool = true,
        fn shape(ptr: *anyopaque, allocator: std.mem.Allocator, _: svg.text.Request) !svg.text.Result {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            const commands = [_]v.Command{ .{ .move = .{} }, .{ .line = .{ .x = 8 } }, .{ .line = .{ .x = 8, .y = 4 } }, .{ .line = .{ .y = 4 } }, .close };
            const path = try v.Path.create(allocator, &commands, .{});
            errdefer path.close() catch unreachable;
            const cells = [_]v.Bounds{.{ .x = 0, .y = 0, .width = 16, .height = 4 }};
            return .{ .path = path, .cells = if (self.cells) try allocator.dupe(v.Bounds, &cells) else null, .first_baseline = 8, .advance = 16, .glyphs = 1 };
        }
        fn provider(self: *@This()) svg.text.Provider {
            return .{ .context = self, .shape = shape };
        }
    };
    const document = try svg.Document.parse(a, "<svg><defs><pattern id='p' width='.5' height='1' patternContentUnits='objectBoundingBox'><rect width='.25' height='1' fill='red'/></pattern></defs><text y='8' fill='url(#p)'>A</text></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var source: Provider = .{};
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4, .text_provider = source.provider(), .compositing = mode };
        const output = try document.prepare(a, options);
        defer output.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), source.calls);
        for (0..4) |y| for (0..8) |x| {
            const alpha: u8 = if (x < 4) 255 else 0;
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, output.pixels[(y * 8 + x) * 4 ..][0..4]);
        };
        source = .{ .cells = false };
        options.text_provider = source.provider();
        try std.testing.expectError(error.UnsupportedTextBoundingBox, document.prepare(a, options));
        try std.testing.expectEqual(@as(usize, 1), source.calls);
    }
}
fn prepare(document: *svg.Document, mode: Mode) !*svg.Prepared {
    return document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4, .compositing = mode });
}
fn equal(input: []const u8, expected: []const u8, mode: Mode) !void {
    const document = try svg.Document.parse(a, input, .{});
    defer document.close() catch unreachable;
    const reference = try svg.Document.parse(a, expected, .{});
    defer reference.close() catch unreachable;
    const output = try prepare(document, mode);
    defer output.close() catch unreachable;
    const oracle = try prepare(reference, mode);
    defer oracle.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, oracle.pixels, output.pixels);
}
test "independent per-tile A8 source-over is a fractional-seam counterexample" {
    const document = try svg.Document.parse(a, "<svg><rect x='-3.5' width='4' height='4' fill='red'/><rect x='.5' width='4' height='4' fill='red'/><rect x='4.5' width='4' height='4' fill='red'/></svg>", .{});
    defer document.close() catch unreachable;
    const pixel = try prepare(document, .pixel);
    defer pixel.close() catch unreachable;
    const lanes = try prepare(document, .sample_color);
    defer lanes.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 192, 192 }, pixel.pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, lanes.pixels[0..4]);
}
test "pattern transforms use target user space and external clips share the lane domain" {
    const pattern = "<defs><pattern id='p' patternUnits='userSpaceOnUse' x='-.5' width='4' height='4'><rect width='2' height='4' fill='red'/></pattern></defs>";
    const stripes = "<rect x='0' width='1.5' height='4' fill='red'/><rect x='3.5' width='2' height='4' fill='red'/><rect x='7.5' width='.5' height='4' fill='red'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg>" ++ pattern ++ "<rect width='8' height='4' fill='url(#p)'/></svg>", "<svg>" ++ stripes ++ "</svg>", mode);
        try equal("<svg>" ++ pattern ++ "<defs><clipPath id='c'><rect x='.5' width='6' height='4'/></clipPath></defs><rect width='8' height='4' fill='url(#p)' clip-path='url(#c)'/></svg>", "<svg><rect x='.5' width='1' height='4' fill='red'/><rect x='3.5' width='2' height='4' fill='red'/></svg>", mode);
        const transformed = "<defs><pattern id='p' patternUnits='userSpaceOnUse' width='4' height='4' patternTransform='matrix(1 0 .25 1 0 0)'><rect width='2' height='4' fill='red'/></pattern></defs>";
        // After inverse shear, the visible rows can intersect a tile to either
        // side. The explicit path oracle includes those clipped neighbors.
        try equal("<svg>" ++ transformed ++ "<rect width='8' height='4' fill='url(#p)'/></svg>", "<svg><defs><clipPath id='c'><rect width='8' height='4'/></clipPath></defs><g clip-path='url(#c)' transform='matrix(1 0 .25 1 0 0)'><rect x='-4' width='2' height='4' fill='red'/><rect width='2' height='4' fill='red'/><rect x='4' width='2' height='4' fill='red'/></g></svg>", mode);
    }
}
test "pattern overlap alpha and fill opacity belong to one complete paint" {
    const input = "<svg><defs><pattern id='p' patternUnits='userSpaceOnUse' x='.5' width='4' height='4'><rect width='4' height='4' fill='red' fill-opacity='.5'/><rect width='4' height='4' fill='blue' fill-opacity='.5'/></pattern></defs><rect width='8' height='4' fill='url(#p)' fill-opacity='.5'/></svg>";
    const document = try svg.Document.parse(a, input, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try prepare(document, mode);
        defer output.close() catch unreachable;
        for (0..8 * 4) |pixel| try std.testing.expectEqualSlices(u8, &.{ 64, 0, 32, 96 }, output.pixels[pixel * 4 ..][0..4]);
    }
}
test "pattern pitch follows target user space even for non-scaling stroke geometry" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg viewBox='0 0 16 8' transform='translate(1 0)'><defs><pattern id='p' patternUnits='userSpaceOnUse' width='4' height='4'><rect width='2' height='4' fill='red'/></pattern></defs><path d='M0 4H16' fill='none' stroke='url(#p)' stroke-width='1' vector-effect='non-scaling-stroke'/></svg>", "<svg><rect x='1' y='1.5' width='1' height='1' fill='red'/><rect x='3' y='1.5' width='1' height='1' fill='red'/><rect x='5' y='1.5' width='1' height='1' fill='red'/><rect x='7' y='1.5' width='1' height='1' fill='red'/></svg>", mode);
    }
}
test "pattern content inherits definition ancestors and remains available when not displayed" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal("<svg><defs><g color='blue' display='none'><pattern id='p' patternUnits='userSpaceOnUse' width='4' height='4' display='none'><rect width='4' height='4' fill='currentColor'/></pattern></g></defs><rect width='8' height='4' color='red' fill='url(#p)'/></svg>", "<svg><rect width='8' height='4' fill='blue'/></svg>", mode);
}
fn allocationTrial(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode) !void {
    const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4, .compositing = mode });
    defer output.close() catch unreachable;
}
test "pattern candidate allocation failure and shared budget failure discard the whole paint" {
    const document = try svg.Document.parse(a, seamless, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        const output = try prepare(document, mode);
        const stats = try output.stats();
        try output.close();
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4, .compositing = mode };
        options.limits.bytes = stats.peak_bytes - 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.node_visits = stats.node_visits - 1;
        try std.testing.expectError(error.NodeWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.color_work = stats.color_work - 1;
        try std.testing.expectError(error.ColorWorkExceeded, document.prepare(a, options));
        options.limits = .{};
        options.limits.scene_work = stats.scene_work - 1;
        try std.testing.expectError(error.SceneWorkExceeded, document.prepare(a, options));
    }
}
test "pattern unsupported combinations and huge candidate counts fail before tile enumeration" {
    const cases = [_]struct { attributes: []const u8, content: []const u8 = "<rect width='4' height='4'/>", err: anyerror }{
        .{ .attributes = "patternUnits='invalid' width='4' height='4'", .err = error.UnsupportedPatternUnits },
        .{ .attributes = "patternUnits='userSpaceOnUse' patternContentUnits='invalid' width='4' height='4'", .err = error.UnsupportedPatternUnits },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='4' height='4' href='#x'", .err = error.ReferenceNotFound },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='4' height='4' viewBox='0 0 -4 4'", .err = error.InvalidViewBox },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='4' height='4' style='overflow:auto'", .err = error.UnsupportedPatternOverflow },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='-1' height='4'", .err = error.InvalidPatternSize },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='4' height='4'", .content = "<use href='#x'/>", .err = error.UnsupportedPatternContent },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='4' height='4'", .content = "<rect width='50%' height='4'/>", .err = error.UnsupportedPatternPercentage },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='4' height='4'", .content = "<rect width='4' height='4' fill='url(#q)'/>", .err = error.UnsupportedPatternPaintServer },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='1e-30' height='4'", .err = error.UnsupportedPatternPrecision },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='.00001' height='.00001'", .err = error.NodeWorkExceeded },
        .{ .attributes = "patternUnits='userSpaceOnUse' width='4' height='4' patternTransform='matrix(1 0 1000000 1 0 0)'", .err = error.NodeWorkExceeded },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const input = try std.fmt.allocPrint(a, "<svg><defs><pattern id='p' {s}>{s}</pattern></defs><rect width='8' height='4' fill='url(#p)'/></svg>", .{ case.attributes, case.content });
        defer a.free(input);
        const document = try svg.Document.parse(a, input, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(case.err, prepare(document, mode));
    };
}
test "one continuous pattern paint resolves fractional tile seams once" {
    const document = try svg.Document.parse(a, seamless, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const output = try prepare(document, mode);
        defer output.close() catch unreachable;
        for (0..8 * 4) |pixel| try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, output.pixels[pixel * 4 ..][0..4]);
    }
}
