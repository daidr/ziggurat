const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const a = std.testing.allocator;
const Mode = @TypeOf((svg.PrepareOptions{ .main_thread = 0, .width = 1, .height = 1 }).compositing);
const Mock = struct {
    chunks: []const []const u8,
    calls: usize = 0,
    fn shape(ptr: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        if (self.calls >= self.chunks.len) return error.UnexpectedTextRequest;
        try std.testing.expectEqualStrings(self.chunks[self.calls], request.utf8);
        self.calls += 1;
        const path = try v.Path.create(allocator, &.{ .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 5, .y = 0 } }, .{ .line = .{ .x = 5, .y = 10 } }, .{ .line = .{ .x = 0, .y = 10 } }, .close }, .{});
        errdefer path.close() catch unreachable;
        const cells = try allocator.dupe(v.Bounds, &.{.{ .x = 0, .y = 0, .width = 5, .height = 10 }});
        return .{ .path = path, .cells = cells, .first_baseline = 8, .advance = 5, .glyphs = 1 };
    }
    fn provider(self: *Mock) svg.text.Provider {
        return .{ .context = self, .shape = shape };
    }
};
fn prepare(allocator: std.mem.Allocator, document: *svg.Document, mock: *Mock, mode: Mode, limits: svg.PrepareLimits) !*svg.Prepared {
    return document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = mock.provider(), .limits = limits });
}
fn pixelsEqual(source: []const u8, expected: []const u8, chunks: []const []const u8, mode: Mode) !void {
    const document = try svg.Document.parse(a, source, .{});
    defer document.close() catch unreachable;
    const oracle = try svg.Document.parse(a, expected, .{});
    defer oracle.close() catch unreachable;
    var mock: Mock = .{ .chunks = chunks };
    const actual = try prepare(a, document, &mock, mode, .{});
    defer actual.close() catch unreachable;
    const image = try oracle.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode });
    defer image.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, image.pixels, actual.pixels);
    try std.testing.expectEqual(chunks.len, mock.calls);
    try std.testing.expectEqual(chunks.len, (try actual.stats()).text_chunks);
}
test "same-style nested spans and normalized whitespace remain one shaping chunk" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try pixelsEqual("<svg><style>tspan{font-size:100%}</style><text x='4' y='12' font-size='10'> A<tspan> \nB<tspan>\tC</tspan> </tspan>D </text></svg>", "<svg><path d='M4 4H9V14H4Z'/></svg>", &.{"A B C D"}, mode);
        try pixelsEqual("<svg><text x='4' y='12'>A<tspan display='none' fill='red'>ignored</tspan>C</text></svg>", "<svg><path d='M4 4H9V14H4Z'/></svg>", &.{"AC"}, mode);
        try pixelsEqual("<svg><text x='4' y='12'>A <tspan xml:space='preserve'> B<tspan xml:space='default'>  C  </tspan> D </tspan> </text></svg>", "<svg><path d='M4 4H9V14H4Z'/></svg>", &.{"A  B C  D "}, mode);
    }
}
test "zero and complete-turn rotation values keep the ordinary batch provider" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| try pixelsEqual("<svg><text x='4' y='12' rotate='360 -720'>A<tspan>V</tspan></text></svg>", "<svg><path d='M4 4H9V14H4Z'/></svg>", &.{"AV"}, mode);
}

test "position lists reject malformed separators and empty values before shaping" {
    const cases = [_]struct { attribute: []const u8, err: anyerror }{
        .{ .attribute = "x=''", .err = error.InvalidLength },
        .{ .attribute = "x='1,'", .err = error.InvalidLength },
        .{ .attribute = "x='1,,2'", .err = error.InvalidNumber },
        .{ .attribute = "x='1-2'", .err = error.NumberSeparatorRequired },
        .{ .attribute = "x='1qu'", .err = error.UnsupportedLengthUnit },
        .{ .attribute = "rotate=''", .err = error.InvalidNumber },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><text {s}>A</text></svg>", .{case.attribute});
        defer a.free(source);
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        var mock: Mock = .{ .chunks = &.{} };
        try std.testing.expectError(case.err, prepare(a, document, &mock, .pixel, .{}));
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
    }
}
test "absolute lists count Unicode scalars and consume ancestor slots through nested overrides" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try pixelsEqual("<svg><text x='2 10 18' y='12'>A<tspan x='8'>B</tspan>C</text></svg>", "<svg><path d='M2 4H7V14H2Z M8 4H13V14H8Z M18 4H23V14H18Z'/></svg>", &.{ "A", "B", "C" }, mode);
        try pixelsEqual("<svg><text x='4, 12' y='12'> 😀<tspan>中</tspan>A</text></svg>", "<svg><path d='M4 4H9V14H4Z M12 4H17V14H12Z'/></svg>", &.{ "😀", "中A" }, mode);
        try pixelsEqual("<svg><text x='1 7 13 19' y='12'>A<tspan x='4'>BC</tspan>D</text></svg>", "<svg><path d='M1 4H6V14H1Z M4 4H9V14H4Z M13 4H18V14H13Z M19 4H24V14H19Z'/></svg>", &.{ "A", "B", "C", "D" }, mode);
        try pixelsEqual("<svg><text x='2' y='10'>A<tspan y='18' dx='3'>B</tspan></text></svg>", "<svg><path d='M2 2H7V12H2Z M10 10H15V20H10Z'/></svg>", &.{ "A", "B" }, mode);
    }
}
test "chunk anchors and omitted axes use actual directional advances" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try pixelsEqual("<svg><text x='8 20' y='12' text-anchor='middle'>A<tspan>B</tspan></text></svg>", "<svg><path d='M5.5 4H10.5V14H5.5Z M17.5 4H22.5V14H17.5Z'/></svg>", &.{ "A", "B" }, mode);
        try pixelsEqual("<svg><text x='20' y='10' direction='rtl'>A<tspan y='18'>B</tspan></text></svg>", "<svg><path d='M15 2H20V12H15Z M10 10H15V20H10Z'/></svg>", &.{ "A", "B" }, mode);
        try pixelsEqual("<svg viewBox='0 0 32 24'><text x='25% 50%' y='50%' dx='1px 0' rotate='0 0'>AB</text></svg>", "<svg><path d='M9 4H14V14H9Z M16 4H21V14H16Z'/></svg>", &.{ "A", "B" }, mode);
    }
}
test "relative shifts and style changes never silently break continuous shaping" {
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "<svg><text dx='0 1'>AV</text></svg>", .err = error.UnsupportedTextMapping },
        .{ .source = "<svg><text>A<tspan dy='1'>V</tspan></text></svg>", .err = error.UnsupportedTextMapping },
        .{ .source = "<svg><text rotate='30'>A</text></svg>", .err = error.UnsupportedTextMapping },
        .{ .source = "<svg><text>A<tspan font-weight='700'>V</tspan></text></svg>", .err = error.UnsupportedTextSpanStyle },
        .{ .source = "<svg><text>A<tspan fill='red'>V</tspan></text></svg>", .err = error.UnsupportedTextMapping },
        .{ .source = "<svg><text visibility='hidden'>A<tspan visibility='visible'>B</tspan></text></svg>", .err = error.UnsupportedTextSpanStyle },
        .{ .source = "<svg><tspan>A</tspan></svg>", .err = error.InvalidTextSpanParent },
    };
    for (cases) |case| {
        const document = try svg.Document.parse(a, case.source, .{});
        defer document.close() catch unreachable;
        for ([_]Mode{ .pixel, .sample_color }) |mode| {
            var mock: Mock = .{ .chunks = &.{} };
            try std.testing.expectError(case.err, prepare(a, document, &mock, mode, .{}));
            try std.testing.expectEqual(@as(usize, 0), mock.calls);
        }
    }
}
fn allocationFixture(allocator: std.mem.Allocator, document: *svg.Document) !void {
    var mock: Mock = .{ .chunks = &.{ "😀", "中", "A" } };
    const result = try prepare(allocator, document, &mock, .pixel, .{});
    defer result.close() catch unreachable;
}

fn hiddenFixture(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode) !void {
    var mock: Mock = .{ .chunks = &.{} };
    const result = try prepare(allocator, document, &mock, mode, .{});
    defer result.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    try std.testing.expectEqual(@as(usize, 0), (try result.stats()).text_requests);
    for (result.pixels) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "hidden text validates the same-style subtree without font requests" {
    const document = try svg.Document.parse(a, "<svg><text visibility='hidden' x='2 10' y='12'>A<tspan>B</tspan></text></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try hiddenFixture(a, document, mode);
        try std.testing.checkAllAllocationFailures(a, hiddenFixture, .{ document, mode });
    }
}
test "positioning has scene cumulative budgets and allocation rollback" {
    const document = try svg.Document.parse(a, "<svg><text x='2 10 18' y='12'>😀<tspan>中</tspan>A</text></svg>", .{});
    defer document.close() catch unreachable;
    try std.testing.checkAllAllocationFailures(a, allocationFixture, .{document});
    const fields = [_][]const u8{ "characters", "position_values", "chunks" };
    const errors = [_]anyerror{ error.TextCharactersFull, error.TextPositionsFull, error.TextChunksFull };
    inline for (fields, errors) |field, err| {
        var limits: svg.PrepareLimits = .{};
        @field(limits.text, field) = 1;
        var mock: Mock = .{ .chunks = &.{} };
        try std.testing.expectError(err, prepare(a, document, &mock, .pixel, limits));
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
    }
}
test "cached span acceptance includes inherited paint and instance position budgets" {
    const document = try svg.Document.parse(a, "<svg><defs><text id='t'>A<tspan fill='red'>B</tspan></text></defs><use href='#t' fill='red'/><use href='#t' fill='blue'/></svg>", .{});
    defer document.close() catch unreachable;
    var mock: Mock = .{ .chunks = &.{"AB"} };
    try std.testing.expectError(error.UnsupportedTextMapping, prepare(a, document, &mock, .pixel, .{}));
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    const repeated = try svg.Document.parse(a, "<svg><defs><text id='t' x='1 8'>AB</text></defs><use href='#t'/><use href='#t'/></svg>", .{});
    defer repeated.close() catch unreachable;
    var limits: svg.PrepareLimits = .{};
    limits.text.position_values = 3;
    mock = .{ .chunks = &.{ "A", "B" } };
    try std.testing.expectError(error.TextPositionsFull, prepare(a, repeated, &mock, .pixel, limits));
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
}
