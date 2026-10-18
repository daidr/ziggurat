const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const a = std.testing.allocator;
const Mode = @FieldType(svg.PrepareOptions, "compositing");

fn image(allocator: std.mem.Allocator, source: []const u8, mode: Mode, provider: ?svg.text.Provider) !*svg.Prepared {
    const document = try svg.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    return document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = provider });
}
fn equal(source: []const u8, expected: []const u8, mode: Mode) !void {
    const actual = try image(a, source, mode, null);
    defer actual.close() catch unreachable;
    const oracle = try image(a, expected, mode, null);
    defer oracle.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, oracle.pixels, actual.pixels);
}
const geometry = "d='M6 5H24V18H6Z' stroke-width='6' stroke-linejoin='round'";
const fill = "<path " ++ geometry ++ " fill='rgba(255,0,0,0.625)'/>";
const stroke = "<path " ++ geometry ++ " fill='none' stroke='rgba(0,0,255,0.75)'/>";
const fill_first = "<svg>" ++ fill ++ stroke ++ "</svg>";
const stroke_first = "<svg>" ++ stroke ++ fill ++ "</svg>";

test "paint order resolves omitted operations and all permutations without duplicate paints" {
    const cases = [_]struct { value: []const u8, reversed: bool }{
        .{ .value = "normal", .reversed = false },
        .{ .value = "fill", .reversed = false },
        .{ .value = "markers", .reversed = false },
        .{ .value = "fill stroke", .reversed = false },
        .{ .value = "fill markers", .reversed = false },
        .{ .value = "markers fill", .reversed = false },
        .{ .value = "fill stroke markers", .reversed = false },
        .{ .value = "fill markers stroke", .reversed = false },
        .{ .value = "markers fill stroke", .reversed = false },
        .{ .value = "stroke", .reversed = true },
        .{ .value = "stroke fill", .reversed = true },
        .{ .value = "stroke markers", .reversed = true },
        .{ .value = "markers stroke", .reversed = true },
        .{ .value = "stroke fill markers", .reversed = true },
        .{ .value = "stroke markers fill", .reversed = true },
        .{ .value = "markers stroke fill", .reversed = true },
        .{ .value = " STROKE\tMarkers \nFILL ", .reversed = true },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><path " ++ geometry ++ " fill='rgba(255,0,0,0.625)' stroke='rgba(0,0,255,0.75)' paint-order='{s}'/></svg>", .{case.value});
        defer a.free(source);
        try equal(source, if (case.reversed) stroke_first else fill_first, mode);
    };
    const default = try image(a, "<svg><path " ++ geometry ++ " fill='rgba(255,0,0,0.625)' stroke='rgba(0,0,255,0.75)'/></svg>", .pixel, null);
    defer default.close() catch unreachable;
    const reversed = try image(a, stroke_first, .pixel, null);
    defer reversed.close() catch unreachable;
    try std.testing.expect(!std.mem.eql(u8, default.pixels, reversed.pixels));
}

test "paint order participates in cascade inheritance use and reset keywords" {
    const body = "<path " ++ geometry ++ " fill='rgba(255,0,0,0.625)' stroke='rgba(0,0,255,0.75)' {s}/>";
    const cases = [_]struct { prefix: []const u8, attribute: []const u8, suffix: []const u8, reversed: bool }{
        .{ .prefix = "<g paint-order='stroke'>", .attribute = "", .suffix = "</g>", .reversed = true },
        .{ .prefix = "<g paint-order='stroke'>", .attribute = "paint-order='inherit'", .suffix = "</g>", .reversed = true },
        .{ .prefix = "<g paint-order='stroke'>", .attribute = "paint-order='unset'", .suffix = "</g>", .reversed = true },
        .{ .prefix = "<g paint-order='stroke'>", .attribute = "paint-order='initial'", .suffix = "</g>", .reversed = false },
        .{ .prefix = "<g paint-order='stroke'>", .attribute = "style='paint-order:normal'", .suffix = "</g>", .reversed = false },
        .{ .prefix = "<style>.p{paint-order:stroke!important}</style>", .attribute = "class='p' paint-order='normal' style='paint-order:fill'", .suffix = "", .reversed = true },
        .{ .prefix = "<style>.p{paint-order:stroke}</style>", .attribute = "class='p' paint-order='stroke' style='paint-order:normal'", .suffix = "", .reversed = false },
        .{ .prefix = "<defs>", .attribute = "id='p'", .suffix = "</defs><use href='#p' paint-order='stroke'/>", .reversed = true },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const shape = try std.fmt.allocPrint(a, body, .{case.attribute});
        defer a.free(shape);
        const source = try std.fmt.allocPrint(a, "<svg>{s}{s}{s}</svg>", .{ case.prefix, shape, case.suffix });
        defer a.free(source);
        try equal(source, if (case.reversed) stroke_first else fill_first, mode);
    };
}

const effects = "<defs><linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='green'/></linearGradient><clipPath id='c'><rect x='5.5' y='4.25' width='20' height='15'/></clipPath><mask id='m' mask-type='alpha'><rect width='32' height='24' fill='white' opacity='.75'/></mask></defs>";
const effect_path = "<path " ++ geometry ++ " fill='url(#g)' stroke='rgba(0,0,255,0.75)' paint-order='stroke'/>";
const effect_oracle = "<path " ++ geometry ++ " fill='none' stroke='rgba(0,0,255,0.75)'/><path " ++ geometry ++ " fill='url(#g)'/>";
const effect_source = "<svg>" ++ effects ++ "<g opacity='.5' clip-path='url(#c)' mask='url(#m)'>" ++ effect_path ++ "</g></svg>";

test "paint order keeps gradient mask clip and element opacity outside both operations" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal(effect_source, "<svg>" ++ effects ++ "<g opacity='.5' clip-path='url(#c)' mask='url(#m)'>" ++ effect_oracle ++ "</g></svg>", mode);
        try equal("<svg>" ++ effects ++ "<path " ++ geometry ++ " fill='url(#g)' stroke='rgba(0,0,255,0.75)' paint-order='stroke' opacity='.5' clip-path='url(#c)' mask='url(#m)'/></svg>", "<svg>" ++ effects ++ "<g opacity='.5' clip-path='url(#c)' mask='url(#m)'>" ++ effect_oracle ++ "</g></svg>", mode);
    }
}

test "invalid paint order rejects without allocating a raster or entering a provider" {
    const cases = [_][]const u8{ "", "fill fill", "stroke stroke", "markers markers", "normal fill", "fill normal", "fill,stroke", "fill stroke markers fill", "background" };
    for (cases) |value| {
        const source = try std.fmt.allocPrint(a, "<svg><path " ++ geometry ++ " paint-order='{s}'/></svg>", .{value});
        defer a.free(source);
        for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.expectError(error.InvalidPaintOrder, image(a, source, mode, null));
    }
    try std.testing.expectError(error.UnsupportedMarkerUnits, image(a, "<svg><marker id='m' markerUnits='objectBoundingBox'/><path paint-order='markers stroke' d='M0 0H10'/></svg>", .pixel, null));
    try std.testing.expectError(error.UnsupportedAttribute, image(a, "<svg><path marker='url(#m)' paint-order='markers stroke' d='M0 0H10'/></svg>", .sample_color, null));
}

const Glyph = struct {
    calls: usize = 0,
    fn shape(ptr: *anyopaque, allocator: std.mem.Allocator, _: svg.text.Request) !svg.text.Result {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        const path = try v.Path.parseData(allocator, "M0 0H5V10H0Z", .{});
        return .{ .path = path, .first_baseline = 8, .advance = 5, .glyphs = 1 };
    }
    fn interface(self: *@This()) svg.text.Provider {
        return .{ .context = self, .shape = shape };
    }
};
test "text order reuses one shaped outline and span acceptance checks the inherited order" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var glyph: Glyph = .{};
        const output = try image(a, "<svg><text x='10' y='12' fill='red' stroke='blue' stroke-width='4' paint-order='stroke'>A<tspan>B</tspan></text></svg>", mode, glyph.interface());
        defer output.close() catch unreachable;
        const oracle = try image(a, "<svg><path d='M10 4H15V14H10Z' fill='none' stroke='blue' stroke-width='4'/><path d='M10 4H15V14H10Z' fill='red'/></svg>", mode, null);
        defer oracle.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, oracle.pixels, output.pixels);
        try std.testing.expectEqual(@as(usize, 1), glyph.calls);
        try std.testing.expectError(error.UnsupportedTextSpanStyle, image(a, "<svg><text paint-order='stroke'>A<tspan paint-order='normal'>B</tspan></text></svg>", mode, glyph.interface()));
        try std.testing.expectEqual(@as(usize, 1), glyph.calls);
        glyph.calls = 0;
        try std.testing.expectError(error.UnsupportedTextSpanStyle, image(a, "<svg><defs><text id='t'>A<tspan paint-order='normal'>B</tspan></text></defs><use href='#t'/><use href='#t' paint-order='stroke'/></svg>", mode, glyph.interface()));
        try std.testing.expectEqual(@as(usize, 1), glyph.calls);
    }
}

fn allocationFailures(allocator: std.mem.Allocator, mode: Mode) !void {
    const output = try image(allocator, effect_source, mode, null);
    defer output.close() catch unreachable;
}
test "reordered paint candidates unwind every allocation failure" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.checkAllAllocationFailures(a, allocationFailures, .{mode});
}
