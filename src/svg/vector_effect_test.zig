const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const a = std.testing.allocator;
const Mode = @FieldType(svg.PrepareOptions, "compositing");

fn prepare(allocator: std.mem.Allocator, source: []const u8, mode: Mode, width: u32, height: u32, provider: ?svg.text.Provider) !*svg.Prepared {
    const document = try svg.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    return document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = width, .height = height, .compositing = mode, .text_provider = provider });
}
fn equal(actual: []const u8, oracle: []const u8, mode: Mode, width: u32, height: u32) !void {
    const result = try prepare(a, actual, mode, width, height, null);
    defer result.close() catch unreachable;
    const expected = try prepare(a, oracle, mode, width, height, null);
    defer expected.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, expected.pixels, result.pixels);
}

test "non-scaling strokes use outer viewport coordinates across viewBox affine and nested viewport maps" {
    const cases = [_]struct { source: []const u8, oracle: []const u8 }{
        .{ .source = "<svg viewBox='0 0 16 12'><path d='M2 3H14' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", .oracle = "<svg><rect x='4' y='5' width='24' height='2' fill='red'/></svg>" },
        .{ .source = "<svg><path d='M1 1H7' transform='matrix(3 0 1 2 2 4)' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", .oracle = "<svg><rect x='6' y='5' width='18' height='2' fill='red'/></svg>" },
        .{ .source = "<svg><path d='M1 1H7' transform='matrix(-3 0 1 2 26 4)' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", .oracle = "<svg><rect x='6' y='5' width='18' height='2' fill='red'/></svg>" },
        .{ .source = "<svg><path d='M1 1H7' transform='matrix(0 2 -3 0 14 2)' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", .oracle = "<svg><rect x='10' y='4' width='2' height='12' fill='red'/></svg>" },
        .{ .source = "<svg><svg x='2' y='4' width='24' height='12' viewBox='0 0 12 6'><path d='M1 1H11' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg></svg>", .oracle = "<svg><rect x='4' y='5' width='20' height='2' fill='red'/></svg>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| try equal(case.source, case.oracle, mode, 32, 24);
    // Changing output dimensions changes the path's host transform. The host
    // remains physical output pixels, so the stroke is still exactly 2 px.
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]u32{ 1, 2, 3 }) |factor| {
        const result = try prepare(a, cases[0].source, mode, 32 * factor, 24 * factor, null);
        defer result.close() catch unreachable;
        for (0..24 * factor) |y| {
            const offset = y * result.level.stride + 16 * factor * 4;
            try std.testing.expectEqual(@as(u8, if (y == 6 * factor - 1 or y == 6 * factor) 255 else 0), result.pixels[offset + 3]);
        }
    };
}

test "non-scaling strokes measure dash offset caps joins and percentage width in host coordinates" {
    const source = "<svg><path d='M1 3H7V8' transform='scale(3 2)' fill='none' stroke='blue' stroke-width='2' stroke-dasharray='4 2' stroke-dashoffset='-1' stroke-linecap='round' stroke-linejoin='round' vector-effect='non-scaling-stroke'/></svg>";
    const oracle = "<svg><path d='M3 6H21V16' fill='none' stroke='blue' stroke-width='2' stroke-dasharray='4 2' stroke-dashoffset='-1' stroke-linecap='round' stroke-linejoin='round'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal(source, oracle, mode, 32, 24);
        try equal("<svg viewBox='0 0 16 12'><path d='M2 3H14' stroke='red' stroke-width='10%' vector-effect='non-scaling-stroke'/></svg>", "<svg><path d='M4 6H28' stroke='red' stroke-width='1.4142135623730951'/></svg>", mode, 32, 24);
    }
}

test "outer svg transforms map host outlines after stroking and survive use nested viewports and mask definitions" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "<svg transform='matrix(1 0 .5 1 1 2)'><path d='M1 3H7' transform='scale(3 2)' fill='none' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", .expected = "<svg><path d='M3 5H21V7H3Z' transform='matrix(1 0 .5 1 1 2)' fill='red'/></svg>" },
        .{ .source = "<svg transform='scale(.75 1.5)'><path d='M1 3H7' transform='scale(3 2)' fill='none' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", .expected = "<svg><rect x='3' y='5' width='18' height='2' transform='scale(.75 1.5)' fill='red'/></svg>" },
        .{ .source = "<svg viewBox='0 0 16 12' transform='scale(.5 .75)'><path d='M2 3H14' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", .expected = "<svg><rect x='4' y='5' width='24' height='2' transform='scale(.5 .75)' fill='red'/></svg>" },
        .{ .source = "<svg transform='matrix(1 0 .5 1 1 2)'><defs><path id='p' d='M1 3H7' fill='none' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></defs><use href='#p' transform='scale(3 2)'/></svg>", .expected = "<svg><path d='M3 5H21V7H3Z' transform='matrix(1 0 .5 1 1 2)' fill='red'/></svg>" },
        .{ .source = "<svg transform='matrix(1 0 .5 1 1 2)'><svg x='2' y='4' width='24' height='12' viewBox='0 0 12 6'><path d='M1 1H11' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg></svg>", .expected = "<svg><rect x='4' y='5' width='20' height='2' transform='matrix(1 0 .5 1 1 2)' fill='red'/></svg>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for (cases) |case| try equal(case.source, case.expected, mode, 32, 24);
        try equal("<svg transform='matrix(1 0 .5 1 1 2)'><defs><mask id='m' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><path d='M1 3H7' transform='scale(3 2)' fill='none' stroke='white' stroke-width='2' vector-effect='non-scaling-stroke'/></mask></defs><rect width='32' height='24' fill='red' mask='url(#m)'/></svg>", "<svg transform='matrix(1 0 .5 1 1 2)'><defs><mask id='m' maskUnits='userSpaceOnUse' x='0' y='0' width='32' height='24' mask-type='alpha'><rect x='3' y='5' width='18' height='2' fill='white'/></mask></defs><rect width='32' height='24' fill='red' mask='url(#m)'/></svg>", mode, 32, 24);
    }
}

test "vector effect participates in cascade explicit inheritance reset and use without implicit inheritance" {
    const geometry = "d='M1 3H7' transform='scale(3 2)' stroke='red' stroke-width='2'";
    const fixed = "<svg><rect x='3' y='5' width='18' height='2' fill='red'/></svg>";
    const normal = "<svg><rect x='3' y='4' width='18' height='4' fill='red'/></svg>";
    const cases = [_]struct { source: []const u8, host: bool }{
        .{ .source = "<svg><g vector-effect='non-scaling-stroke'><path " ++ geometry ++ "/></g></svg>", .host = false },
        .{ .source = "<svg><g vector-effect='non-scaling-stroke'><path " ++ geometry ++ " vector-effect='inherit'/></g></svg>", .host = true },
        .{ .source = "<svg><g vector-effect='non-scaling-stroke'><path " ++ geometry ++ " vector-effect='unset'/></g></svg>", .host = false },
        .{ .source = "<svg><path " ++ geometry ++ " vector-effect='non-scaling-stroke' style='vector-effect:initial'/></svg>", .host = false },
        .{ .source = "<svg><style>.fixed{vector-effect:non-scaling-stroke!important}</style><path " ++ geometry ++ " class='fixed' vector-effect='none' style='vector-effect:none'/></svg>", .host = true },
        .{ .source = "<svg><defs><path id='p' " ++ geometry ++ " vector-effect='non-scaling-stroke'/></defs><use href='#p'/></svg>", .host = true },
        .{ .source = "<svg><defs><path id='p' " ++ geometry ++ " vector-effect='inherit'/></defs><use href='#p' vector-effect='non-scaling-stroke'/></svg>", .host = true },
        .{ .source = "<svg><path " ++ geometry ++ " vector-effect=' NON-SCALING-STROKE '/></svg>", .host = true },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| try equal(case.source, if (case.host) fixed else normal, mode, 32, 24);
}

test "vector effect leaves local paint servers fill object bounds clipping and opacity intact" {
    const defs = "<defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x1='0' x2='16'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><clipPath id='c'><rect x='3.25' y='2' width='24' height='10.5'/></clipPath><mask id='m' mask-type='alpha'><rect width='32' height='24' fill='white' opacity='.5'/></mask></defs>";
    const actual = "<svg>" ++ defs ++ "<g clip-path='url(#c)' opacity='.5'><path d='M2 3H14' transform='scale(2)' stroke='url(#g)' stroke-width='2' vector-effect='non-scaling-stroke'/></g></svg>";
    const expected = "<svg>" ++ defs ++ "<g clip-path='url(#c)' opacity='.5'><rect x='2' y='2.5' width='12' height='1' transform='scale(2)' fill='url(#g)'/></g></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal(actual, expected, mode, 32, 24);
        // The object gradient still uses the original geometry, before the
        // non-scaling stroke outline is constructed in the host viewport.
        try equal("<svg><defs><linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><path d='M2 2H12V8H2Z' transform='scale(2)' stroke='url(#g)' fill='url(#g)' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", "<svg><defs><linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><path d='M4 4H24V16H4Z' stroke='url(#g)' fill='url(#g)' stroke-width='2'/></svg>", mode, 32, 24);
        try equal("<svg><path d='M1 1H9' transform='matrix(1 2 2 4 2 2)' stroke='red' stroke-width='2' vector-effect='non-scaling-stroke'/></svg>", "<svg/>", mode, 32, 24);
    }
    const pre = @import("prepare.zig");
    try std.testing.expect(pre.nonsingular(.{ .xx = 1e-200, .yy = 1e-200 }));
    try std.testing.expect(pre.nonsingular(.{ .xx = 1, .xy = 1, .yx = 1, .yy = 1 + std.math.floatEps(f64) }));
    try std.testing.expect(!pre.nonsingular(.{ .xx = 1e-200, .xy = 1e-200, .yx = 1e-200, .yy = 1e-200 }));
}

const Glyph = struct {
    fn shape(_: *anyopaque, allocator: std.mem.Allocator, _: svg.text.Request) !svg.text.Result {
        return .{ .path = try v.Path.parseData(allocator, "M0 0H4V4H0Z", .{}), .first_baseline = 0, .advance = 4, .glyphs = 1 };
    }
};
test "text graphics elements use the same host stroke while independent tspan effects remain explicit errors" {
    var context: u8 = 0;
    const provider: svg.text.Provider = .{ .context = &context, .shape = Glyph.shape };
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const actual = try prepare(a, "<svg><text x='2' y='2' transform='scale(2)' vector-effect='non-scaling-stroke' fill='none' stroke='red' stroke-width='2'>a<tspan>b</tspan></text></svg>", mode, 32, 24, provider);
        defer actual.close() catch unreachable;
        const expected = try prepare(a, "<svg><path d='M4 4H12V12H4Z' fill='none' stroke='red' stroke-width='2'/></svg>", mode, 32, 24, null);
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        try std.testing.expectError(error.UnsupportedTextSpanStyle, prepare(a, "<svg><text>a<tspan vector-effect='non-scaling-stroke'>b</tspan></text></svg>", mode, 32, 24, provider));
    }
}

fn failure(allocator: std.mem.Allocator, mode: Mode) !void {
    const result = try prepare(allocator, "<svg transform='matrix(1 0 .5 1 1 2)'><g opacity='.5'><path d='M1 1Q3 5 5 1L7 5' transform='scale(3 2)' fill='none' stroke='red' stroke-width='2' stroke-dasharray='3 1' vector-effect='non-scaling-stroke'/></g></svg>", mode, 32, 24, null);
    defer result.close() catch unreachable;
}
test "vector effects reject unsupported programs and roll back every candidate allocation" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_][]const u8{ "", "non-scaling-size", "non-rotation", "fixed-position", "none non-scaling-stroke" }) |value| {
            const source = try std.fmt.allocPrint(a, "<svg><path d='M1 1H7' vector-effect='{s}'/></svg>", .{value});
            defer a.free(source);
            try std.testing.expectError(error.UnsupportedVectorEffect, prepare(a, source, mode, 32, 24, null));
        }
        try std.testing.checkAllAllocationFailures(a, failure, .{mode});
    }
}
