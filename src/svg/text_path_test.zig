const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const Mock = @import("text_adjust_test.zig").Mock;
const a = std.testing.allocator;
const Mode = @FieldType(svg.PrepareOptions, "compositing");
const route = "<defs><path id='p' d='M4 12H9V22'/></defs>";
const source = "<svg>" ++ route ++ "<text fill='red'><textPath href='#p'>fi<tspan fill='blue'>X</tspan></textPath></text></svg>";
const red = "<path d='M4 4H9V14H4Z' fill='red'/>";
const blue = "<path d='M17 12V17H7V12Z' fill='blue'/>";
const whole = "<path d='M4 4H9V14H4Z M17 12V17H7V12Z' fill='none' stroke='black' stroke-width='1.5'/>";

fn image(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode, mock: *Mock, limits: svg.PrepareLimits) !*svg.Prepared {
    return document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = mock.provider(), .limits = limits });
}
fn equal(input: []const u8, expected: []const u8, mode: Mode, requests: usize) !void {
    const document = try svg.Document.parse(a, input, .{});
    defer document.close() catch unreachable;
    const oracle = try svg.Document.parse(a, expected, .{});
    defer oracle.close() catch unreachable;
    var mock: Mock = .{};
    const actual = try image(a, document, mode, &mock, .{});
    defer actual.close() catch unreachable;
    const result = try image(a, oracle, mode, &mock, .{});
    defer result.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, result.pixels, actual.pixels);
    try std.testing.expectEqual(requests, mock.calls);
    try std.testing.expectEqual(requests, (try actual.stats()).text_mapping_requests);
}
test "textPath keeps rigid glyphs and complete cells across an exact polyline corner" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal(source, "<svg>" ++ red ++ blue ++ "</svg>", mode, 1);
        try equal("<svg xmlns:xlink='http://www.w3.org/1999/xlink'><defs><path id='p' d='m4 12l0 0h5v10'/></defs><text fill='red'><textPath xlink:href='#p' method='align' spacing='exact'>fi<tspan fill='blue'>X</tspan></textPath></text></svg>", "<svg>" ++ red ++ blue ++ "</svg>", mode, 1);
        try equal("<svg>" ++ route ++ "<text fill='red' stroke='black' stroke-width='1.5'><textPath href='#p'>fi<tspan fill='blue'>X</tspan></textPath></text></svg>", "<svg>" ++ red ++ blue ++ whole ++ "</svg>", mode, 1);
        try equal("<svg>" ++ route ++ "<text fill='red' stroke='black' stroke-width='1.5' paint-order='stroke'><textPath href='#p'>fi<tspan fill='blue'>X</tspan></textPath></text></svg>", "<svg>" ++ whole ++ red ++ blue ++ "</svg>", mode, 1);
        try equal("<svg transform='matrix(1 0 .25 1 1 1)'>" ++ route ++ "<text transform='scale(.75)' fill='red' stroke='black' stroke-width='1.5' vector-effect='non-scaling-stroke' paint-order='stroke'><textPath href='#p'>fi<tspan fill='blue'>X</tspan></textPath></text></svg>", "<svg transform='matrix(1 0 .25 1 1 1)'><path d='M3 3H6.75V10.5H3Z M12.75 9V12.75H5.25V9Z' fill='none' stroke='black' stroke-width='1.5'/><path d='M3 3H6.75V10.5H3Z' fill='red'/><path d='M12.75 9V12.75H5.25V9Z' fill='blue'/></svg>", mode, 1);
        // Both cells are rotated before their union. The half-width bbox clip
        // is [4,10.5] x [4,17], even after the enclosing shear is applied.
        try equal("<svg><g transform='matrix(1 0 .25 1 0 0)'>" ++ route ++ "<defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='.5' height='1'/></clipPath></defs><text fill='red' clip-path='url(#c)'><textPath href='#p'>fi<tspan fill='blue'>X</tspan></textPath></text></g></svg>", "<svg><g transform='matrix(1 0 .25 1 0 0)'><defs><clipPath id='c'><rect x='4' y='4' width='6.5' height='13'/></clipPath></defs><g clip-path='url(#c)'>" ++ red ++ blue ++ "</g></g></svg>", mode, 1);
    }
}
test "textPath corner orientation follows the start-end chord and extends endpoints" {
    const cosine = 3 / @sqrt(@as(f64, 13));
    const sine = 2 / @sqrt(@as(f64, 13));
    const expected = try std.fmt.allocPrint(a, "<svg><path d='M0 0H5V10H0Z' fill='red' transform='matrix({d} {d} {d} {d} {d} {d})'/><path d='M17 14V19H7V14Z' fill='blue'/></svg>", .{ cosine, sine, -sine, cosine, 8.5 - cosine * 2.5 + sine * 8, 12 - sine * 2.5 - cosine * 8 });
    defer a.free(expected);
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg>" ++ route ++ "<text fill='red'><textPath href='#p' startOffset='2'>fi<tspan fill='blue'>X</tspan></textPath></text></svg>", expected, mode, 1);
        // First glyph starts before the finite route, but its midpoint is on
        // it. Extending the first segment preserves its ordinary rigid pose.
        try equal("<svg><defs><path id='p' d='M4 12H24'/></defs><text><textPath href='#p' startOffset='-2'>fiX</textPath></text></svg>", "<svg><path d='M2 4H7V14H2Z M7 4H12V14H7Z'/></svg>", mode, 1);
    }
}
test "textPath anchors percentages and RTL retain original glyph paint order" {
    const cases = [_]struct { direction: []const u8, anchor: []const u8, first: f64, second: f64 }{
        .{ .direction = "ltr", .anchor = "start", .first = 14, .second = 19 },
        .{ .direction = "ltr", .anchor = "middle", .first = 9, .second = 14 },
        .{ .direction = "ltr", .anchor = "end", .first = 4, .second = 9 },
        .{ .direction = "rtl", .anchor = "start", .first = 9, .second = 4 },
        .{ .direction = "rtl", .anchor = "middle", .first = 14, .second = 9 },
        .{ .direction = "rtl", .anchor = "end", .first = 19, .second = 14 },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const input = try std.fmt.allocPrint(a, "<svg><defs><path id='p' d='M4 12H24'/></defs><text direction='{s}' text-anchor='{s}' fill='red'><textPath href='#p' startOffset='50%'>fi<tspan fill='blue'>X</tspan></textPath></text></svg>", .{ case.direction, case.anchor });
        defer a.free(input);
        const expected = try std.fmt.allocPrint(a, "<svg><rect x='{d}' y='4' width='5' height='10' fill='red'/><rect x='{d}' y='4' width='5' height='10' fill='blue'/></svg>", .{ case.first, case.second });
        defer a.free(expected);
        try equal(input, expected, mode, 1);
    };
}
test "textPath target local transform changes only route before text use and viewport transforms" {
    const input = "<svg viewBox='0 0 16 12'><g transform='translate(100 200)'><defs><path id='p' transform='translate(1 1) scale(2)' d='M1 5H11'/><text id='t' fill='red'><textPath href='#p'>fi<tspan fill='blue'>X</tspan></textPath></text></defs></g><use href='#t' transform='translate(1 0)'/></svg>";
    const expected = "<svg viewBox='0 0 16 12'><g transform='translate(1 0)'><rect x='3' y='3' width='5' height='10' fill='red'/><rect x='8' y='3' width='5' height='10' fill='blue'/></g></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(input, expected, mode, 1);
}
test "textPath instance recoloring never poses the mapped candidate a second time" {
    const input = "<svg>" ++ route ++ "<defs><text id='t'><textPath href='#p'>fi<tspan fill='blue'>X</tspan></textPath></text></defs><use href='#t' fill='red'/><use href='#t' fill='green' transform='translate(2 0)'/></svg>";
    const expected = "<svg>" ++ red ++ blue ++ "<g transform='translate(2 0)'><path d='M4 4H9V14H4Z' fill='green'/>" ++ blue ++ "</g></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(input, expected, mode, 1);
}

const ProviderCase = struct {
    kind: enum { multiple, zero, bidi },
    mock: Mock = .{},
    fn provider(self: *@This()) svg.text.Provider {
        return .{ .context = self, .shape = shape, .supports_mapping = true };
    }
    fn shape(context: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *@This() = @ptrCast(@alignCast(context));
        const base = self.mock.provider();
        var result = try base.shape(base.context, allocator, request);
        errdefer {
            if (result.mapping) |mapping| mapping.close() catch unreachable;
            if (result.cells) |cells| allocator.free(cells);
            result.path.close() catch unreachable;
        }
        const view = try result.mapping.?.view();
        switch (self.kind) {
            .zero => @constCast(view.glyphs)[0].advance = 0,
            .bidi => @constCast(view.clusters)[0].bidi_level = 1,
            .multiple => {
                const owned_source = try allocator.dupe(u8, view.source);
                errdefer allocator.free(owned_source);
                const glyphs = try allocator.dupe(svg.text.mapping.Glyph, view.glyphs);
                errdefer allocator.free(glyphs);
                for (glyphs) |*glyph| glyph.cluster = 0;
                const clusters = try allocator.dupe(svg.text.mapping.Cluster, &.{.{ .source = .{ .start = 0, .end = view.source.len }, .glyphs = .{ .start = 0, .count = glyphs.len }, .commands = .{ .start = 0, .count = view.path.commands.len }, .bidi_level = 0 }});
                errdefer allocator.free(clusters);
                const path = try result.mapping.?.takePath();
                result.mapping = null;
                errdefer path.close() catch unreachable;
                result.mapping = try svg.text.Mapping.adopt(allocator, .{ .path = path, .source = owned_source, .glyphs = glyphs, .clusters = clusters });
            },
        }
        return result;
    }
};
test "textPath rejects indivisible multi-glyph clusters mixed bidi and zero advance explicitly" {
    const document = try svg.Document.parse(a, source, .{});
    defer document.close() catch unreachable;
    const cases = [_]struct { kind: @FieldType(ProviderCase, "kind"), err: anyerror }{
        .{ .kind = .multiple, .err = error.UnsupportedTextPathCluster },
        .{ .kind = .zero, .err = error.UnsupportedTextPathZeroAdvance },
        .{ .kind = .bidi, .err = error.UnsupportedTextPositionBidi },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        var mock: ProviderCase = .{ .kind = case.kind };
        try std.testing.expectError(case.err, document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = mock.provider() }));
    };
    const overflow = try svg.Document.parse(a, "<svg>" ++ route ++ "<text><textPath href='#p' startOffset='100%'>fiX</textPath></text></svg>", .{});
    defer overflow.close() catch unreachable;
    var mock: Mock = .{};
    try std.testing.expectError(error.UnsupportedTextPathOverflow, image(a, overflow, .pixel, &mock, .{}));
    const backtrack = try svg.Document.parse(a, "<svg><defs><path id='p' d='M4 12H6.5H4'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .{});
    defer backtrack.close() catch unreachable;
    mock = .{};
    try std.testing.expectError(error.UnsupportedTextPathOrientation, image(a, backtrack, .pixel, &mock, .{}));
}
test "textPath unsupported geometry and markup fail before shaping" {
    const cases = [_]struct { input: []const u8, err: anyerror }{
        .{ .input = "<svg><defs><path id='p' d='M0 0Q10 10 20 0'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathGeometry },
        .{ .input = "<svg><defs><path id='p' d='M0 0C1 2 3 4 5 6'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathGeometry },
        .{ .input = "<svg><defs><path id='p' d='M0 0A5 5 0 0 0 10 10'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathGeometry },
        .{ .input = "<svg><defs><path id='p' d='M0 0L20 0Z'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathGeometry },
        .{ .input = "<svg><defs><path id='p' d='M0 0L10 0M10 0L20 0'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathSubpaths },
        .{ .input = "<svg><defs><path id='p' d='M0 0L0 0'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathGeometry },
        .{ .input = "<svg>" ++ route ++ "<text x='0'><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathPositioning },
        .{ .input = "<svg>" ++ route ++ "<text textLength='5'><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathPositioning },
        .{ .input = "<svg>" ++ route ++ "<text><textPath href='#p' method='stretch'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathMethod },
        .{ .input = "<svg>" ++ route ++ "<text><textPath href='#p' spacing='auto'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathMethod },
        .{ .input = "<svg>" ++ route ++ "<text>A<textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathContents },
        .{ .input = "<svg>" ++ route ++ "<text><textPath href='#p'>fiX</textPath>A</text></svg>", .err = error.UnsupportedTextPathContents },
        .{ .input = "<svg>" ++ route ++ "<text><textPath href='#p'>fiX</textPath><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathContents },
        .{ .input = "<svg>" ++ route ++ "<text><textPath href='#p'><tspan dx='0'>fiX</tspan></textPath></text></svg>", .err = error.UnsupportedTextPathPositioning },
        .{ .input = "<svg>" ++ route ++ "<text><tspan><textPath href='#p'>fiX</textPath></tspan></text></svg>", .err = error.InvalidTextPathParent },
        .{ .input = "<svg><defs><path id='p' d='M0 0H1000000000L1000000000 .000000001'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathPrecision },
        .{ .input = "<svg><text><textPath href='https://invalid/p'>fiX</textPath></text></svg>", .err = error.ExternalResourceDenied },
        .{ .input = "<svg><text><textPath href='#missing'>fiX</textPath></text></svg>", .err = error.MissingReference },
        .{ .input = "<svg><defs><rect id='p' width='20' height='1'/></defs><text><textPath href='#p'>fiX</textPath></text></svg>", .err = error.UnsupportedTextPathTarget },
    };
    for (cases) |case| for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const document = try svg.Document.parse(a, case.input, .{});
        defer document.close() catch unreachable;
        var mock: Mock = .{};
        try std.testing.expectError(case.err, image(a, document, mode, &mock, .{}));
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
    };
}
fn allocationFixture(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode) !void {
    var mock: Mock = .{};
    const result = try image(allocator, document, mode, &mock, .{});
    defer result.close() catch unreachable;
}
test "textPath owns every metric candidate and has cumulative work and scene byte limits" {
    const document = try svg.Document.parse(a, source, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, allocationFixture, .{ document, mode });
        var mock: Mock = .{};
        const baseline = try image(a, document, mode, &mock, .{});
        const stats = try baseline.stats();
        try baseline.close();
        var limits: svg.PrepareLimits = .{};
        limits.text.work = stats.text_work - 1;
        mock = .{};
        try std.testing.expectError(error.TextWorkExceeded, image(a, document, mode, &mock, limits));
        limits = .{};
        limits.bytes = stats.peak_bytes - 1;
        mock = .{};
        try std.testing.expectError(error.CapacityExceeded, image(a, document, mode, &mock, limits));
    }
}
