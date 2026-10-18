const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const a = std.testing.allocator;
const Mode = @TypeOf((svg.PrepareOptions{ .main_thread = 0, .width = 1, .height = 1 }).compositing);
const Mock = struct {
    calls: usize = 0,
    source: ?[]const u8 = null,
    document: ?*svg.Document = null,
    lease: ?*svg.text.Lease = null,
    full_cells: ?[]const v.Bounds = null,
    invalid: enum { none, metrics, allocator } = .none,
    fn provider(self: *Mock) svg.text.Provider {
        return .{ .context = self, .shape = shape, .lease = self.lease };
    }
    fn shape(context: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *Mock = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.source) |source| try std.testing.expectEqualStrings(source, request.utf8);
        if (self.document) |document| {
            try std.testing.expectError(error.Busy, document.close());
            try std.testing.expectError(error.Busy, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 1, .height = 1 }));
            _ = try document.node(0);
        }
        const width = request.font.size / 2;
        const path = try v.Path.create(if (self.invalid == .allocator) a else allocator, &.{ .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = width, .y = 0 } }, .{ .line = .{ .x = width, .y = request.font.size } }, .{ .line = .{ .x = 0, .y = request.font.size } }, .close }, .{});
        errdefer path.close() catch unreachable;
        const cells = if (self.full_cells) |values| try allocator.dupe(v.Bounds, values) else null;
        return .{ .path = path, .cells = cells, .first_baseline = if (self.invalid == .metrics) std.math.nan(f64) else request.font.size * 0.8, .advance = width, .glyphs = if (cells) |values| values.len else 1 };
    }
};
fn prepare(document: *svg.Document, provider: *Mock, mode: Mode, limits: svg.PrepareLimits) !*svg.Prepared {
    return document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = provider.provider(), .limits = limits });
}
test "SVG text uses resolved style baseline anchor whitespace and independent path geometry" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const document = try svg.Document.parse(a, "<svg width='32' height='24'><style>text{font-size:10px;fill:red}</style><text x='4' y='12'> A<!--split--> <![CDATA[ B ]]></text></svg>", .{});
        defer document.close() catch unreachable;
        var provider: Mock = .{ .source = "A B", .document = document };
        const output = try prepare(document, &provider, mode, .{});
        defer output.close() catch unreachable;
        const expected = try svg.Document.parse(a, "<svg width='32' height='24'><path fill='red' d='M4 4H9V14H4Z'/></svg>", .{});
        defer expected.close() catch unreachable;
        const pixels = try expected.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode });
        defer pixels.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, pixels.pixels, output.pixels);
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        try std.testing.expectEqual(@as(usize, 1), (try output.stats()).text_requests);
    }
}
test "SVG text clips and direct use share geometry and bounded per-prepare cache" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const document = try svg.Document.parse(a, "<svg><defs><text id='t' x='2' y='10' font-size='10'>A</text><clipPath id='c'><use href='#t'/></clipPath></defs><g clip-path='url(#c)'><use href='#t' fill='blue'/><use href='#t' fill='blue'/></g></svg>", .{});
        defer document.close() catch unreachable;
        var provider: Mock = .{ .source = "A" };
        const output = try prepare(document, &provider, mode, .{});
        defer output.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        try std.testing.expectEqual(@as(usize, 3), (try output.stats()).text_glyphs);
        try std.testing.expect(output.pixels[(5 * 32 + 4) * 4 + 3] > 0);
        var low: svg.PrepareLimits = .{};
        low.text.glyphs = 1;
        try std.testing.expectError(error.TextCapacityExceeded, prepare(document, &provider, mode, low));
        low = .{};
        low.text.work = 1;
        try std.testing.expectError(error.TextWorkExceeded, prepare(document, &provider, mode, low));
    }
}
test "SVG text default whitespace deletes XML newlines without CSS segment breaks" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "a\nb", .expected = "ab" },
        .{ .source = "a\r\nb\rc", .expected = "abc" },
        .{ .source = "a\tb", .expected = "a b" },
        .{ .source = "中\n文", .expected = "中文" },
        .{ .source = " a<!--split-->\n<![CDATA[b\n]]>c \t d ", .expected = "abc d" },
        .{ .source = "a \n b", .expected = "a b" },
        .{ .source = "a&#10;b", .expected = "ab" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg><text xml:space='default'>{s}</text></svg>", .{case.source});
        defer a.free(source);
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        var provider: Mock = .{ .source = case.expected };
        const output = try prepare(document, &provider, mode, .{});
        defer output.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
    };
}
test "SVG text anchors use direction and user space gradients do not require an ink bbox" {
    const cases = [_]struct { anchor: []const u8, direction: []const u8, x: f64 }{
        .{ .anchor = "start", .direction = "ltr", .x = 20 },    .{ .anchor = "end", .direction = "ltr", .x = 15 },
        .{ .anchor = "start", .direction = "rtl", .x = 15 },    .{ .anchor = "end", .direction = "rtl", .x = 20 },
        .{ .anchor = "middle", .direction = "rtl", .x = 17.5 },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        var buffer: [800]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "<svg><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x2='32'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><g font-size='20'><text font-size='50%' x='20' y='12' text-anchor='{s}' direction='{s}' fill='url(#g)'>A</text></g></svg>", .{ case.anchor, case.direction });
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        var provider: Mock = .{ .source = "A" };
        const output = try prepare(document, &provider, mode, .{});
        defer output.close() catch unreachable;
        const reference = try std.fmt.bufPrint(&buffer, "<svg><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x2='32'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><rect x='{d}' y='4' width='5' height='10' fill='url(#g)'/></svg>", .{case.x});
        const expected = try svg.Document.parse(a, reference, .{});
        defer expected.close() catch unreachable;
        const image = try expected.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode });
        defer image.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, image.pixels, output.pixels);
    };
}
test "SVG preserved XML spaces retain every normalized LF tab and text node boundary" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = " a\t b\n ", .expected = " a  b  " },
        .{ .source = " \r\n中<!--split-->\r<![CDATA[\t 文 ]]>", .expected = "  中   文 " },
        .{ .source = "a&#10;b", .expected = "a b" },
        .{ .source = " \t\n ", .expected = "    " },
        .{ .source = "\u{a0}a\u{2003}", .expected = "\u{a0}a\u{2003}" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "<svg xml:space='preserve'><g><text>{s}</text></g></svg>", .{case.source});
        defer a.free(source);
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        var provider: Mock = .{ .source = case.expected };
        const output = try prepare(document, &provider, mode, .{});
        defer output.close() catch unreachable;
        try std.testing.expectEqual(case.expected.len, (try output.stats()).text_source_bytes);
    };
}

const SpaceModes = struct {
    mock: Mock = .{},
    calls: usize = 0,
    fn shape(ctx: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *SpaceModes = @ptrCast(@alignCast(ctx));
        self.mock.source = if (self.calls == 0) " A  B " else "A B";
        self.calls += 1;
        return Mock.shape(&self.mock, allocator, request);
    }
};

test "SVG same text use cache separates inherited XML whitespace mode" {
    const source = "<svg><defs><text id='t' font-size='10'> A  B </text></defs><use href='#t' xml:space='preserve'/><use href='#t' x='10' xml:space='default'/></svg>";
    const document = try svg.Document.parse(a, source, .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var provider: SpaceModes = .{};
        const output = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = .{ .context = &provider, .shape = SpaceModes.shape } });
        defer output.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 2), provider.calls);
        try std.testing.expectEqual(@as(usize, 9), (try output.stats()).text_source_bytes);
    }
}

test "SVG text strict boundaries and invalid provider results fail without publication" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const sources = [_]struct { source: []const u8, err: anyerror }{
            .{ .source = "<svg><text xml:space='invalid'> A </text></svg>", .err = error.UnsupportedTextWhitespace },
            .{ .source = "<svg><text white-space='normal'>A</text></svg>", .err = error.UnsupportedTextWhitespace },
            .{ .source = "<svg><style>text{white-space:inherit}</style><text>A</text></svg>", .err = error.UnsupportedTextWhitespace },
            .{ .source = "<svg><text>a&#13;b</text></svg>", .err = error.UnsupportedTextWhitespace },
            .{ .source = "<svg><text>A<tspan font-size='20'>B</tspan></text></svg>", .err = error.UnsupportedTextSpanStyle },
            .{ .source = "<svg><defs><linearGradient id='g'><stop/></linearGradient></defs><text fill='url(#g)'>A</text></svg>", .err = error.UnsupportedTextBoundingBox },
            .{ .source = "<svg><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs><g clip-path='url(#c)'><text>A</text></g></svg>", .err = error.UnsupportedTextBoundingBox },
        };
        for (sources) |case| {
            const document = try svg.Document.parse(a, case.source, .{});
            defer document.close() catch unreachable;
            var provider: Mock = .{ .source = "A" };
            try std.testing.expectError(case.err, prepare(document, &provider, mode, .{}));
        }
        const document = try svg.Document.parse(a, "<svg><text>A</text></svg>", .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(error.TextProviderRequired, document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode }));
        var provider: Mock = .{ .invalid = .metrics };
        try std.testing.expectError(error.InvalidTextProviderMetrics, prepare(document, &provider, mode, .{}));
        provider.invalid = .allocator;
        try std.testing.expectError(error.InvalidTextProviderAllocator, prepare(document, &provider, mode, .{}));
    }
}
fn allocationPass(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode) !void {
    var provider: Mock = .{};
    const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = provider.provider() });
    defer output.close() catch unreachable;
}
test "SVG text candidates and caches unwind every allocation failure" {
    const document = try svg.Document.parse(a, "<svg><defs><text id='t' font-size='10'>A</text></defs><use href='#t'/><use x='8' href='#t'/></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.checkAllAllocationFailures(a, allocationPass, .{ document, mode });
}
fn compareCells(source: []const u8, oracle: []const u8, cells: []const v.Bounds) !void {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        const expected = try svg.Document.parse(a, oracle, .{});
        defer expected.close() catch unreachable;
        var provider: Mock = .{ .full_cells = cells };
        const actual = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 48, .height = 48, .compositing = mode, .text_provider = provider.provider() });
        defer actual.close() catch unreachable;
        const reference = try expected.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 48, .height = 48, .compositing = mode });
        defer reference.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, reference.pixels, actual.pixels);
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
    }
}

test "SVG text object bounds use complete cells for gradients clips and masks" {
    const cells = [_]v.Bounds{.{ .x = 0, .y = -2, .width = 10, .height = 20 }};
    const gradient = "<svg><defs><linearGradient id='g' x2='0%' y2='100%'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><text x='4' y='12' font-size='10' fill='url(#g)'>A</text></svg>";
    const gradient_oracle = "<svg><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x1='0' y1='2' x2='0' y2='22'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><path d='M4 4H9V14H4Z' fill='url(#g)'/></svg>";
    try compareCells(gradient, gradient_oracle, &cells);
    const clip = "<svg><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='.5'/></clipPath></defs><text x='4' y='12' font-size='10' clip-path='url(#c)' fill='blue'>A</text></svg>";
    const clip_oracle = "<svg><defs><clipPath id='c'><rect x='4' y='2' width='10' height='10'/></clipPath></defs><path d='M4 4H9V14H4Z' fill='blue' clip-path='url(#c)'/></svg>";
    try compareCells(clip, clip_oracle, &cells);
    const mask = "<svg><defs><mask id='m' maskUnits='objectBoundingBox' maskContentUnits='objectBoundingBox' x='0' y='0' width='1' height='1' mask-type='alpha'><rect width='.25' height='1' fill='white'/></mask></defs><text x='4' y='12' font-size='10' mask='url(#m)' fill='blue'>A</text></svg>";
    const mask_oracle = "<svg><defs><mask id='m' maskUnits='userSpaceOnUse' maskContentUnits='userSpaceOnUse' x='4' y='2' width='10' height='20' mask-type='alpha'><rect x='4' y='2' width='2.5' height='20' fill='white'/></mask></defs><path d='M4 4H9V14H4Z' fill='blue' mask='url(#m)'/></svg>";
    try compareCells(mask, mask_oracle, &cells);
}

test "SVG parent bounds transform individual cells before union" {
    const cells = [_]v.Bounds{ .{ .x = 0, .y = 0, .width = 2, .height = 10 }, .{ .x = 8, .y = 8, .width = 2, .height = 10 } };
    const source = "<svg><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect x='.5' width='.5' height='1'/></clipPath></defs><g clip-path='url(#c)'><text font-size='10' transform='matrix(1 1 -1 1 20 20)' fill='blue'>A</text></g></svg>";
    const oracle = "<svg><defs><clipPath id='c'><rect x='24' y='12' width='6' height='28'/></clipPath></defs><g clip-path='url(#c)'><path d='M0 -8H5V2H0Z' transform='matrix(1 1 -1 1 20 20)' fill='blue'/></g></svg>";
    try compareCells(source, oracle, &cells);
}

fn cellsAllocationPass(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode) !void {
    var provider: Mock = .{ .full_cells = &.{.{ .x = 0, .y = -2, .width = 10, .height = 20 }} };
    const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = provider.provider() });
    defer output.close() catch unreachable;
}

test "SVG owned full cells unwind candidate failures and reject invalid metrics" {
    const document = try svg.Document.parse(a, "<svg><defs><linearGradient id='g'><stop stop-color='blue'/></linearGradient></defs><text y='12' font-size='10' fill='url(#g)'>A</text></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, cellsAllocationPass, .{ document, mode });
        var provider: Mock = .{ .full_cells = &.{.{ .x = 0, .y = 0, .width = -1, .height = 1 }} };
        try std.testing.expectError(error.InvalidTextProviderCells, prepare(document, &provider, mode, .{}));
        provider.full_cells = &.{.{ .x = std.math.nan(f64), .y = 0, .width = 1, .height = 1 }};
        try std.testing.expectError(error.InvalidTextProviderCells, prepare(document, &provider, mode, .{}));
    }
}

const LeaseProbe = struct {
    lease: svg.text.Lease,
    active: bool = true,
    checks: usize = 0,
    failure: ?anyerror = null,
    fn allocator(self: *LeaseProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn check(self: *LeaseProbe) void {
        if (!self.active) return;
        std.testing.expectError(error.ResourceInUse, self.lease.ensureUnused()) catch |err| {
            self.failure = err;
        };
        self.checks += 1;
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *LeaseProbe = @ptrCast(@alignCast(context));
        self.check();
        return a.rawAlloc(length, alignment, ret);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *LeaseProbe = @ptrCast(@alignCast(context));
        self.check();
        a.rawFree(bytes, alignment, ret);
    }
};

test "SVG provider owner is pinned through every scene allocation and final cache disposal" {
    const document = try svg.Document.parse(a, "<svg><text y='12'>A</text><text x='10' y='12'>B</text></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var probe: LeaseProbe = .{ .lease = svg.text.Lease.init(std.Thread.getCurrentId()) };
        var provider: Mock = .{ .lease = &probe.lease };
        const output = try document.prepare(probe.allocator(), .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = provider.provider() });
        probe.active = false;
        defer output.close() catch unreachable;
        if (probe.failure) |err| return err;
        try std.testing.expect(probe.checks > 8);
        try probe.lease.ensureUnused();
    }
}

const CloseProbe = struct {
    child: std.mem.Allocator,
    document: ?*svg.Document = null,
    image: ?*svg.Prepared = null,
    active: bool = false,
    checks: usize = 0,
    failure: ?anyerror = null,
    fn allocator(self: *CloseProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CloseProbe = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(length, alignment, ret);
    }
    fn probe(self: *CloseProbe) !void {
        if (self.document) |document| {
            try std.testing.expectError(error.Closed, document.close());
            try std.testing.expectError(error.Closed, document.node(0));
        } else {
            try std.testing.expectError(error.Closed, self.image.?.close());
            try std.testing.expectError(error.Closed, self.image.?.view());
        }
        self.checks += 1;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CloseProbe = @ptrCast(@alignCast(context));
        if (self.active) self.probe() catch |err| {
            self.failure = err;
        };
        self.child.rawFree(bytes, alignment, ret);
    }
};
test "SVG document and image final frees revoke recursive close before callbacks" {
    var probe: CloseProbe = .{ .child = a };
    const document = try svg.Document.parse(probe.allocator(), "<svg><rect width='1' height='1'/></svg>", .{});
    const image = try document.prepare(probe.allocator(), .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 });
    probe.document = document;
    probe.active = true;
    try document.close();
    probe.document = null;
    probe.image = image;
    try image.close();
    if (probe.failure) |err| return err;
    try std.testing.expect(probe.checks >= 6);
}
