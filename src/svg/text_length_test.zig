const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const a = std.testing.allocator;
const Mode = @TypeOf((svg.PrepareOptions{ .main_thread = 0, .width = 1, .height = 1 }).compositing);
const Mock = struct {
    calls: usize = 0,
    advance: f64 = 5,
    arc: bool = false,
    curves: bool = false,
    fn shape(ptr: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        try std.testing.expectEqualStrings("AV", request.utf8);
        self.calls += 1;
        const path = try v.Path.parseData(allocator, if (self.arc) "M0 0A5 5 0 0 1 5 10Z" else if (self.curves) "M0 0Q5 -2 5 4C5 7 2 10 0 10Z" else "M0 0H5V10H0Z", .{});
        errdefer path.close() catch unreachable;
        const cells = try allocator.dupe(v.Bounds, &.{.{ .x = -1, .y = 0, .width = 7, .height = 10 }});
        return .{ .path = path, .cells = cells, .first_baseline = 8, .advance = self.advance, .glyphs = 1 };
    }
    fn provider(self: *Mock) svg.text.Provider {
        return .{ .context = self, .shape = shape };
    }
};
fn image(allocator: std.mem.Allocator, source: []const u8, mode: Mode, mock: ?*Mock) !*svg.Prepared {
    const document = try svg.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    return document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 40, .height = 24, .compositing = mode, .text_provider = if (mock) |m| m.provider() else null });
}
fn equal(source: []const u8, expected: []const u8, mode: Mode) !void {
    var mock: Mock = .{};
    const actual = try image(a, source, mode, &mock);
    defer actual.close() catch unreachable;
    const oracle = try image(a, expected, mode, null);
    defer oracle.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, oracle.pixels, actual.pixels);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqual(@as(usize, 1), (try actual.stats()).text_requests);
}
test "text length stretches one shaped chunk before directional anchoring" {
    const cases = [_]struct { direction: []const u8, anchor: []const u8, x: f64 }{
        .{ .direction = "ltr", .anchor = "start", .x = 20 },
        .{ .direction = "rtl", .anchor = "start", .x = 10 },
        .{ .direction = "ltr", .anchor = "middle", .x = 15 },
        .{ .direction = "rtl", .anchor = "middle", .x = 15 },
        .{ .direction = "ltr", .anchor = "end", .x = 10 },
        .{ .direction = "rtl", .anchor = "end", .x = 20 },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><text x='20' y='12' textLength='10' lengthAdjust='spacingAndGlyphs' direction='{s}' text-anchor='{s}'>A<tspan>V</tspan></text></svg>", .{ case.direction, case.anchor });
        defer a.free(source);
        const expected = try std.fmt.allocPrint(a, "<svg><rect x='{d}' y='4' width='10' height='10'/></svg>", .{case.x});
        defer a.free(expected);
        for ([_]Mode{ .pixel, .sample_color }) |mode| try equal(source, expected, mode);
    }
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><text x='4' y='12' textLength=' 1.875pt ' lengthAdjust=' spacingAndGlyphs '>AV</text></svg>", "<svg><rect x='4' y='4' width='2.5' height='10'/></svg>", mode);
        try equal("<svg><text x='4' y='12' textLength='0' lengthAdjust='spacingAndGlyphs'>AV</text></svg>", "<svg/>", mode);
        try equal("<svg><text x='4' y='12' lengthAdjust='spacing'>AV</text></svg>", "<svg><rect x='4' y='4' width='5' height='10'/></svg>", mode);
    }
}
test "length bounds scale full glyph cells independently of ink" {
    const paint = "<linearGradient id='g' x2='1' y2='0'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='.75' height='1'/></clipPath><mask id='m' maskUnits='objectBoundingBox' maskContentUnits='objectBoundingBox' x='0' y='0' width='1' height='1' mask-type='alpha'><rect width='.875' height='1' fill='white'/></mask>";
    const user = "<linearGradient id='g' gradientUnits='userSpaceOnUse' gradientTransform='matrix(14 0 0 10 18 4)' x2='1' y2='0'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><clipPath id='c'><rect x='18' y='4' width='10.5' height='10'/></clipPath><mask id='m' maskUnits='userSpaceOnUse' maskContentUnits='userSpaceOnUse' x='18' y='4' width='14' height='10' mask-type='alpha'><rect x='18' y='4' width='12.25' height='10' fill='white'/></mask>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| try equal("<svg><defs>" ++ paint ++ "</defs><text x='20' y='12' textLength='10' lengthAdjust='spacingAndGlyphs' fill='url(#g)' clip-path='url(#c)' mask='url(#m)'>AV</text></svg>", "<svg><defs>" ++ user ++ "</defs><path d='M20 4H30V14H20Z' fill='url(#g)' clip-path='url(#c)' mask='url(#m)'/></svg>", mode);
}
test "length conversion covers Bezier control points and use retains shared geometry" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var mock: Mock = .{ .curves = true };
        const actual = try image(a, "<svg><text x='4' y='12' textLength='10' lengthAdjust='spacingAndGlyphs'>AV</text></svg>", mode, &mock);
        defer actual.close() catch unreachable;
        const oracle = try image(a, "<svg><path d='M4 4Q14 2 14 8C14 11 8 14 4 14Z'/></svg>", mode, null);
        defer oracle.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, oracle.pixels, actual.pixels);
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try equal("<svg><defs><text id='t' y='12' textLength='10' lengthAdjust='spacingAndGlyphs'>A<tspan>V</tspan></text></defs><use href='#t' x='4'/><use href='#t' x='20'/></svg>", "<svg><rect x='4' y='4' width='10' height='10'/><rect x='20' y='4' width='10' height='10'/></svg>", mode);
    }
}
test "unsupported length models reject before the first font request" {
    const cases = [_]struct { body: []const u8, err: anyerror }{
        .{ .body = "<text textLength='10'>AV</text>", .err = error.UnsupportedTextMapping },
        .{ .body = "<text textLength='10' lengthAdjust='spacing'>AV</text>", .err = error.UnsupportedTextMapping },
        .{ .body = "<text textLength='-1' lengthAdjust='spacingAndGlyphs'>AV</text>", .err = error.InvalidTextLength },
        .{ .body = "<text textLength='50%' lengthAdjust='spacingAndGlyphs'>AV</text>", .err = error.UnsupportedTextLengthPercent },
        .{ .body = "<text lengthAdjust='SpacingAndGlyphs'>AV</text>", .err = error.InvalidTextLengthAdjust },
        .{ .body = "<text textLength='10' lengthAdjust='spacingAndGlyphs' x='0 10'>AV</text>", .err = error.UnsupportedTextLengthChunks },
        .{ .body = "<text>A<tspan textLength='5' lengthAdjust='spacingAndGlyphs'>V</tspan></text>", .err = error.UnsupportedTextSpanLength },
        .{ .body = "<rect width='5' height='5' textLength='10'/>", .err = error.UnsupportedAttribute },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg>{s}</svg>", .{case.body});
        defer a.free(source);
        for ([_]Mode{ .pixel, .sample_color }) |mode| {
            var mock: Mock = .{};
            try std.testing.expectError(case.err, image(a, source, mode, &mock));
            try std.testing.expectEqual(@as(usize, 0), mock.calls);
        }
    }
}
test "zero advance and custom arc length conversion fail without partial output" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var zero: Mock = .{ .advance = 0 };
        try std.testing.expectError(error.UnsupportedTextLengthZeroAdvance, image(a, "<svg><text textLength='10' lengthAdjust='spacingAndGlyphs'>AV</text></svg>", mode, &zero));
        var precision: Mock = .{};
        try std.testing.expectError(error.UnsupportedTextLengthPrecision, image(a, "<svg><text textLength='5e-324' lengthAdjust='spacingAndGlyphs'>AV</text></svg>", mode, &precision));
        var arc: Mock = .{ .arc = true };
        try std.testing.expectError(error.UnsupportedTextLengthOutline, image(a, "<svg><text textLength='10' lengthAdjust='spacingAndGlyphs'>AV</text></svg>", mode, &arc));
        const identity = try image(a, "<svg><text textLength='5' lengthAdjust='spacingAndGlyphs'>AV</text></svg>", mode, &arc);
        defer identity.close() catch unreachable;
    }
}
fn allocationFixture(allocator: std.mem.Allocator, mode: Mode) !void {
    var mock: Mock = .{};
    const result = try image(allocator, "<svg><text x='20' y='12' textLength='10' lengthAdjust='spacingAndGlyphs'>A<tspan>V</tspan></text></svg>", mode, &mock);
    defer result.close() catch unreachable;
}
test "length candidates release every failed allocation in both modes" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.checkAllAllocationFailures(a, allocationFixture, .{mode});
}
