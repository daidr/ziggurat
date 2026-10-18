const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const Mock = @import("text_adjust_test.zig").Mock;
const a = std.testing.allocator;
const Mode = @FieldType(svg.PrepareOptions, "compositing");

pub const PlacementProbe = struct {
    trace: std.hash.Wyhash = std.hash.Wyhash.init(0),
    allocations: usize = 0,
    frees: usize = 0,
    live: usize = 0,
    peak: usize = 0,
    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn mark(self: *@This(), kind: u8, bytes: usize) void {
        var encoded: [9]u8 = undefined;
        encoded[0] = kind;
        std.mem.writeInt(u64, encoded[1..], @intCast(bytes), .little);
        self.trace.update(&encoded);
    }
    fn alloc(ptr: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const memory = a.rawAlloc(bytes, alignment, ret) orelse return null;
        self.mark(1, bytes);
        self.allocations += 1;
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
        return memory;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.mark(2, bytes.len);
        self.frees += 1;
        self.live -= bytes.len;
        a.rawFree(bytes, alignment, ret);
    }
};

test "ordinary and existing mixed placement retain their pixel allocation and budget fingerprints" {
    const sources = [_][]const u8{
        "<svg><text x='4' y='12' fill='red'>fiX</text></svg>",
        "<svg><text x='4' y='12' textLength='20' lengthAdjust='spacingAndGlyphs' fill='red'>fiX</text></svg>",
        "<svg><text x='4' y='12' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>",
        "<svg><text x='4' y='12' textLength='20' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>",
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (sources, 0..) |source, index| {
        var probe: PlacementProbe = .{};
        var mock: Mock = .{};
        const result = try image(probe.allocator(), source, mode, mock.provider(), .{});
        const pixels = std.hash.Wyhash.hash(0, result.pixels);
        const stats = try result.stats();
        try result.close();
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try std.testing.expectEqual(@as(usize, if (index < 2) 0 else 1), stats.text_mapping_requests);
        try std.testing.expect(probe.live == 0 and probe.allocations == probe.frees);
        std.debug.print("SVG placement fingerprint {s}/{d}: pixels={x} trace={x} alloc={d} peak={d} scene-peak={d} work={d} commands={d}\n", .{ @tagName(mode), index, pixels, probe.trace.final(), probe.allocations, probe.peak, stats.peak_bytes, stats.text_work, stats.text_accounted_commands });
    };
}

fn image(allocator: std.mem.Allocator, source: []const u8, mode: Mode, provider: svg.text.Provider, limits: svg.text.Limits) !*svg.Prepared {
    const document = try svg.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    return document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = provider, .limits = .{ .text = limits } });
}
fn equal(source: []const u8, oracle: []const u8, mode: Mode) !void {
    return equalUses(source, oracle, mode, 1);
}
fn equalUses(source: []const u8, oracle: []const u8, mode: Mode, uses: usize) !void {
    var mock: Mock = .{};
    const actual = try image(a, source, mode, mock.provider(), .{});
    defer actual.close() catch unreachable;
    const expected = try image(a, oracle, mode, mock.provider(), .{});
    defer expected.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    const stats = try actual.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.text_mapping_requests);
    try std.testing.expectEqual(uses * 2, stats.text_paint_runs);
    try std.testing.expectEqual(uses * 10, stats.text_commands);
    try std.testing.expectEqual(uses * 10, stats.text_paint_commands);
    try std.testing.expectEqual(10 + uses * 20, stats.text_accounted_commands);
}
const left = "<path d='M4 4H9V14H4Z' fill='red'/>";
const right = "<path d='M9 4H14V14H9Z' fill='blue'/>";
const common = "<path d='M4 4H9V14H4Z M9 4H14V14H9Z' fill='none' stroke='black' stroke-width='2'/>";
test "paint-only spans keep one shaping and replace only the chunk fill phase" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><text x='4' y='12' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ left ++ right ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' fill='red' stroke='black' stroke-width='2'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ left ++ right ++ common ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' fill='red' stroke='black' stroke-width='2' paint-order='stroke'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ common ++ left ++ right ++ "</svg>", mode);
        try equal("<svg><text x='20' y='12' direction='rtl' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><rect x='15' y='4' width='5' height='10' fill='red'/><rect x='10' y='4' width='5' height='10' fill='blue'/></svg>", mode);
        try equal("<svg><text x='4' y='12' fill='red' fill-opacity='.5'>fi<tspan fill='blue' fill-opacity='.25'>X</tspan></text></svg>", "<svg><rect x='4' y='4' width='5' height='10' fill='red' fill-opacity='.5'/><rect x='9' y='4' width='5' height='10' fill='blue' fill-opacity='.25'/></svg>", mode);
    }
}

test "whole-text cells effects and non-scaling stroke stay outside the fill partitions" {
    const defs = "<defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='.75' height='1'/></clipPath><mask id='m' mask-type='alpha'><rect width='32' height='24' fill='white' opacity='.75'/></mask></defs>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        // Clip and mask each query the whole-text bbox before the paint use.
        // These cache uses retain the existing conservative command budget.
        try equalUses("<svg>" ++ defs ++ "<text x='4' y='12' fill='red' opacity='.5' clip-path='url(#c)' mask='url(#m)'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><defs><mask id='m' mask-type='alpha'><rect width='32' height='24' fill='white' opacity='.75'/></mask></defs><g opacity='.5' mask='url(#m)'><g clip-path='url(#u)'><defs><clipPath id='u'><rect x='4' y='4' width='7.5' height='10'/></clipPath></defs>" ++ left ++ right ++ "</g></g></svg>", mode, 3);
        const source = "<svg transform='matrix(1 0 .25 1 1 1)'><text x='2' y='6' transform='scale(2)' fill='red' stroke='black' stroke-width='2' vector-effect='non-scaling-stroke' paint-order='stroke'>fi<tspan fill='blue'>X</tspan></text></svg>";
        const oracle = "<svg transform='matrix(1 0 .25 1 1 1)'><path d='M4 -4H14V16H4Z M14 -4H24V16H14Z' fill='none' stroke='black' stroke-width='2'/><rect x='4' y='-4' width='10' height='20' fill='red'/><rect x='14' y='-4' width='10' height='20' fill='blue'/></svg>";
        try equal(source, oracle, mode);
    }
}

test "mixed fills use one cluster placement before whole stroke and preserve ligature scalar carry" {
    const red = "<path d='M12 12V17H2V12Z' fill='red'/>";
    const blue = "<path d='M14 7H19V17H14Z' fill='blue'/>";
    const stroke = "<path d='M12 12V17H2V12Z M14 7H19V17H14Z' fill='none' stroke='black' stroke-width='1.5'/>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        // The second scalar belongs to the first ligature. Its dx/dy carry to
        // X, while only the ligature's first scalar supplies its rotation.
        try equal("<svg><text x='4' y='12' dx='0 2 3' dy='0 1 2' rotate='90 180 0' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ red ++ blue ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' dx='0 2 3' dy='0 1 2' rotate='90 180 0' fill='red' stroke='black' stroke-width='1.5'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ red ++ blue ++ stroke ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' dx='0 2 3' dy='0 1 2' rotate='90 180 0' fill='red' stroke='black' stroke-width='1.5' paint-order='stroke'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ stroke ++ red ++ blue ++ "</svg>", mode);
        try equal("<svg><text x='20' y='12' direction='rtl' dx='0 2 3' dy='0 1 2' rotate='0 90' fill='red' fill-opacity='.5'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><rect x='15' y='4' width='5' height='10' fill='red' fill-opacity='.5'/><rect x='18' y='10' width='10' height='5' fill='blue' fill-opacity='.5'/></svg>", mode);
        // An outer scale changes the posed centerline, then NSS constructs a
        // single host-space stroke around the complete two-color geometry.
        try equal("<svg><text x='4' y='12' dx='0 2 3' dy='0 1 2' rotate='90 180 0' transform='scale(.75)' fill='red' stroke='black' stroke-width='2' vector-effect='non-scaling-stroke' paint-order='stroke'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><path d='M9 9V12.75H1.5V9Z M10.5 5.25H14.25V12.75H10.5Z' fill='none' stroke='black' stroke-width='2'/><path d='M9 9V12.75H1.5V9Z' fill='red'/><path d='M10.5 5.25H14.25V12.75H10.5Z' fill='blue'/></svg>", mode);
    }
}

test "mixed spacing keeps ligatures rigid and uses final intervals for every anchor" {
    const Case = struct { direction: []const u8, anchor: []const u8, x: u32, first: f64, second: f64 };
    const cases = [_]Case{
        .{ .direction = "ltr", .anchor = "start", .x = 4, .first = 4, .second = 19 },
        .{ .direction = "ltr", .anchor = "middle", .x = 16, .first = 6, .second = 21 },
        .{ .direction = "ltr", .anchor = "end", .x = 28, .first = 8, .second = 23 },
        .{ .direction = "rtl", .anchor = "start", .x = 28, .first = 23, .second = 8 },
        .{ .direction = "rtl", .anchor = "middle", .x = 16, .first = 21, .second = 6 },
        .{ .direction = "rtl", .anchor = "end", .x = 4, .first = 19, .second = 4 },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for (cases) |case| {
            const source = try std.fmt.allocPrint(a, "<svg><text x='{d}' y='12' direction='{s}' text-anchor='{s}' textLength='20' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", .{ case.x, case.direction, case.anchor });
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><rect x='{d}' y='4' width='5' height='10' fill='red'/><rect x='{d}' y='4' width='5' height='10' fill='blue'/></svg>", .{ case.first, case.second });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><text x='4' y='12' textLength='4' lengthAdjust='spacing' fill='red' fill-opacity='.5'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><rect x='5' y='4' width='5' height='10' fill='red' fill-opacity='.5'/><rect x='4' y='4' width='5' height='10' fill='blue' fill-opacity='.5'/></svg>", mode);
        try equal("<svg><text x='4' y='12' textLength='0' fill='red' fill-opacity='.5'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><rect x='9' y='4' width='5' height='10' fill='red' fill-opacity='.5'/><rect x='4' y='4' width='5' height='10' fill='blue' fill-opacity='.5'/></svg>", mode);
        const red = "<path d='M12 12V17H2V12Z' fill='red'/>";
        const blue = "<path d='M19 7H24V17H19Z' fill='blue'/>";
        const stroke = "<path d='M12 12V17H2V12Z M19 7H24V17H19Z' fill='none' stroke='black' stroke-width='1.5'/>";
        try equal("<svg><text x='4' y='12' textLength='20' dx='0 2 3' dy='0 1 2' rotate='90 180 0' fill='red' stroke='black' stroke-width='1.5'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ red ++ blue ++ stroke ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' textLength='20' lengthAdjust='spacing' dx='0 2 3' dy='0 1 2' rotate='90 180 0' fill='red' stroke='black' stroke-width='1.5' paint-order='stroke'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ stroke ++ red ++ blue ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' textLength='20' dx='0 2 3' dy='0 1 2' rotate='90 180 0' transform='scale(.75)' fill='red' stroke='black' stroke-width='2' vector-effect='non-scaling-stroke' paint-order='stroke'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><path d='M9 9V12.75H1.5V9Z M14.25 5.25H18V12.75H14.25Z' fill='none' stroke='black' stroke-width='2'/><path d='M9 9V12.75H1.5V9Z' fill='red'/><path d='M14.25 5.25H18V12.75H14.25Z' fill='blue'/></svg>", mode);
    }
}

test "mixed spacingAndGlyphs scales a whole shaped chunk before directional anchoring" {
    const Case = struct { direction: []const u8, anchor: []const u8, first: f64, second: f64 };
    const cases = [_]Case{
        .{ .direction = "ltr", .anchor = "start", .first = 12, .second = 22 },
        .{ .direction = "ltr", .anchor = "middle", .first = 2, .second = 12 },
        .{ .direction = "ltr", .anchor = "end", .first = -8, .second = 2 },
        .{ .direction = "rtl", .anchor = "start", .first = 2, .second = -8 },
        .{ .direction = "rtl", .anchor = "middle", .first = 12, .second = 2 },
        .{ .direction = "rtl", .anchor = "end", .first = 22, .second = 12 },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for (cases) |case| {
            const source = try std.fmt.allocPrint(a, "<svg><text x='12' y='12' direction='{s}' text-anchor='{s}' textLength='20' lengthAdjust='spacingAndGlyphs' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", .{ case.direction, case.anchor });
            defer a.free(source);
            const oracle = try std.fmt.allocPrint(a, "<svg><rect x='{d}' y='4' width='10' height='10' fill='red'/><rect x='{d}' y='4' width='10' height='10' fill='blue'/></svg>", .{ case.first, case.second });
            defer a.free(oracle);
            try equal(source, oracle, mode);
        }
        try equal("<svg><text x='4' y='12' textLength='5' lengthAdjust='spacingAndGlyphs' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><rect x='4' y='4' width='2.5' height='10' fill='red'/><rect x='6.5' y='4' width='2.5' height='10' fill='blue'/></svg>", mode);
        try equal("<svg><text x='4' y='12' textLength='10' lengthAdjust='spacingAndGlyphs' dx='0 0 0' dy='0' rotate='360 720' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ left ++ right ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' textLength='0' lengthAdjust='spacingAndGlyphs' fill='red' stroke='black'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><path d='M4 4V14Z M4 4V14Z' fill='none' stroke='black'/></svg>", mode);
        const red = "<rect x='4' y='4' width='10' height='10' fill='red'/>";
        const blue = "<rect x='14' y='4' width='10' height='10' fill='blue'/>";
        const stroke = "<path d='M4 4H14V14H4Z M14 4H24V14H14Z' fill='none' stroke='black' stroke-width='2'/>";
        try equal("<svg><text x='4' y='12' textLength='20' lengthAdjust='spacingAndGlyphs' fill='red' stroke='black' stroke-width='2'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ red ++ blue ++ stroke ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' textLength='20' lengthAdjust='spacingAndGlyphs' fill='red' stroke='black' stroke-width='2' paint-order='stroke'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg>" ++ stroke ++ red ++ blue ++ "</svg>", mode);
        try equal("<svg><text x='4' y='12' textLength='20' lengthAdjust='spacingAndGlyphs' transform='scale(.75)' fill='red' stroke='black' stroke-width='2' vector-effect='non-scaling-stroke'>fi<tspan fill='blue'>X</tspan></text></svg>", "<svg><rect x='3' y='3' width='7.5' height='7.5' fill='red'/><rect x='10.5' y='3' width='7.5' height='7.5' fill='blue'/><path d='M3 3H10.5V10.5H3Z M10.5 3H18V10.5H10.5Z' fill='none' stroke='black' stroke-width='2'/></svg>", mode);
    }
}

test "posed mixed text keeps exact cell corners through another affine object bbox query" {
    // Independent four-corner construction for two 5x10 cells rotated 45deg
    // about their baseline pens, followed by x'=x+y/2, y'=x/4+y.
    const cosine = @cos(@as(f64, std.math.pi) / 4);
    const sine = @sin(@as(f64, std.math.pi) / 4);
    for ([_]bool{ false, true }) |spacing| {
        var low_x: f64 = std.math.inf(f64);
        var low_y: f64 = std.math.inf(f64);
        var high_x: f64 = -std.math.inf(f64);
        var high_y: f64 = -std.math.inf(f64);
        for ([_]f64{ 8, if (spacing) 23 else 13 }) |pen_x| for ([_]f64{ 0, 5 }) |local_x| for ([_]f64{ -8, 2 }) |local_y| {
            const x = pen_x + local_x * cosine - local_y * sine;
            const y = 12 + local_x * sine + local_y * cosine;
            const mapped_x = x + y / 2;
            const mapped_y = x / 4 + y;
            low_x = @min(low_x, mapped_x);
            high_x = @max(high_x, mapped_x);
            low_y = @min(low_y, mapped_y);
            high_y = @max(high_y, mapped_y);
        };
        const clip = try std.fmt.allocPrint(a, "<clipPath id='c'><rect x='{d}' y='{d}' width='{d}' height='{d}'/></clipPath>", .{ low_x + (high_x - low_x) * 0.1, low_y + (high_y - low_y) * 0.05, (high_x - low_x) * 0.7, (high_y - low_y) * 0.8 });
        defer a.free(clip);
        const body = try std.fmt.allocPrint(a, "<g clip-path='url(#c)' opacity='.625'><text x='8' y='12' {s} rotate='45' transform='matrix(1 .25 .5 1 0 0)' fill='red'>fi<tspan fill='blue'>X</tspan></text></g></svg>", .{if (spacing) "textLength='20'" else ""});
        defer a.free(body);
        const expected_source = try std.fmt.allocPrint(a, "<svg><defs>{s}</defs>{s}", .{ clip, body });
        defer a.free(expected_source);
        const actual_source = try std.fmt.allocPrint(a, "<svg><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect x='.1' y='.05' width='.7' height='.8'/></clipPath></defs>{s}", .{body});
        defer a.free(actual_source);
        for ([_]Mode{ .pixel, .sample_color }) |mode| {
            var mock: Mock = .{};
            const actual = try image(a, actual_source, mode, mock.provider(), .{});
            defer actual.close() catch unreachable;
            const expected = try image(a, expected_source, mode, mock.provider(), .{});
            defer expected.close() catch unreachable;
            try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
            try std.testing.expectEqual(@as(usize, 2), mock.calls);
            try std.testing.expectEqual(@as(usize, 1), (try actual.stats()).text_mapping_requests);
        }
    }
}

test "equal effective paints retain the original unmapped batch including a ligature across markup" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{
        "<svg><text fill='red'>f<tspan fill='currentColor' color='red'>iX</tspan></text></svg>",
        "<svg><text fill-opacity='0' fill='red'>f<tspan fill='blue'>iX</tspan></text></svg>",
        "<svg><text fill='none'>f<tspan fill='transparent'>iX</tspan></text></svg>",
        "<svg><text fill='red' rotate='360 720' dx='0 0 0'>f<tspan fill='currentColor' color='red'>iX</tspan></text></svg>",
    }) |source| {
        var mock: Mock = .{};
        var provider = mock.provider();
        provider.supports_mapping = false;
        const result = try image(a, source, mode, provider, .{});
        defer result.close() catch unreachable;
        const stats = try result.stats();
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try std.testing.expectEqual(@as(usize, 0), stats.text_mapping_requests);
        try std.testing.expectEqual(@as(usize, 0), stats.text_paint_runs);
        try std.testing.expectEqual(@as(usize, 10), stats.text_accounted_commands);
    };
}

test "uniform descendant paint overrides the text root without requesting mapping" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var mock: Mock = .{};
        var provider = mock.provider();
        provider.supports_mapping = false;
        const actual = try image(a, "<svg><text x='4' y='12' fill='red'><tspan fill='blue' fill-opacity='.5'>f<tspan>iX</tspan></tspan></text></svg>", mode, provider, .{});
        defer actual.close() catch unreachable;
        const expected = try image(a, "<svg><path d='M4 4H9V14H4Z M9 4H14V14H9Z' fill='blue' fill-opacity='.5'/></svg>", mode, provider, .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        const stats = try actual.stats();
        try std.testing.expectEqual(@as(usize, 0), stats.text_mapping_requests);
        try std.testing.expectEqual(@as(usize, 0), stats.text_paint_runs);
        try std.testing.expectEqual(@as(usize, 10), stats.text_accounted_commands);
    }
}

test "mapped geometry is reused across inherited paints without sharing brush values" {
    const source = "<svg><defs><text id='t' x='4' y='12' fill='currentColor'>fi<tspan fill='blue'>X</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='green' x='14'/></svg>";
    const oracle = "<svg>" ++ left ++ right ++ "<rect x='18' y='4' width='5' height='10' fill='green'/><rect x='23' y='4' width='5' height='10' fill='blue'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var mock: Mock = .{};
        const actual = try image(a, source, mode, mock.provider(), .{ .source_bytes = 3 });
        defer actual.close() catch unreachable;
        const expected = try image(a, oracle, mode, mock.provider(), .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        const stats = try actual.stats();
        try std.testing.expectEqual(@as(usize, 1), stats.text_requests);
        try std.testing.expectEqual(@as(usize, 4), stats.text_paint_runs);
        try std.testing.expectEqual(@as(usize, 20), stats.text_paint_commands);
        try std.testing.expectEqual(@as(usize, 50), stats.text_accounted_commands);
    }
}

test "different effective paints inside one original cluster fail instead of splitting its glyph" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var mock: Mock = .{};
        try std.testing.expectError(error.UnsupportedTextPaintCluster, image(a, "<svg><text fill='red'>f<tspan fill='blue'>iX</tspan></text></svg>", mode, mock.provider(), .{}));
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        mock = .{};
        try std.testing.expectError(error.UnsupportedTextPaintCluster, image(a, "<svg><text rotate='30' dx='0 2 3' fill='red'>f<tspan fill='blue'>iX</tspan></text></svg>", mode, mock.provider(), .{}));
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        const cases = [_]struct { source: []const u8, err: anyerror }{
            .{ .source = "<svg><text fill='red' stroke='currentColor'>fi<tspan fill='blue' color='green'>X</tspan></text></svg>", .err = error.UnsupportedTextSpanStyle },
            .{ .source = "<svg><text fill='red'>fi<tspan fill='blue' paint-order='stroke'>X</tspan></text></svg>", .err = error.UnsupportedTextSpanStyle },
            .{ .source = "<svg><text fill='red'>fi<tspan fill='blue' vector-effect='non-scaling-stroke'>X</tspan></text></svg>", .err = error.UnsupportedTextSpanStyle },
            .{ .source = "<svg><text fill='red'>fi<tspan fill='blue' font-weight='700'>X</tspan></text></svg>", .err = error.UnsupportedTextSpanStyle },
            .{ .source = "<svg><text fill='red' textLength='20' lengthAdjust='spacingAndGlyphs' dx='1'>fi<tspan fill='blue'>X</tspan></text></svg>", .err = error.UnsupportedTextLengthPositioning },
            .{ .source = "<svg><text fill='red' textLength='20' lengthAdjust='spacingAndGlyphs' dy='1'>fi<tspan fill='blue'>X</tspan></text></svg>", .err = error.UnsupportedTextLengthPositioning },
            .{ .source = "<svg><text fill='red' textLength='20' lengthAdjust='spacingAndGlyphs' dx='0 0 1'>fi<tspan fill='blue'>X</tspan></text></svg>", .err = error.UnsupportedTextLengthPositioning },
            .{ .source = "<svg><text fill='red' textLength='20' lengthAdjust='spacingAndGlyphs' rotate='15'>fi<tspan fill='blue'>X</tspan></text></svg>", .err = error.UnsupportedTextLengthPositioning },
            .{ .source = "<svg><text fill='red' textLength='20' x='0 10'>fi<tspan fill='blue'>X</tspan></text></svg>", .err = error.UnsupportedTextPaintChunks },
            .{ .source = "<svg><text fill='red' textLength='20%'>fi<tspan fill='blue'>X</tspan></text></svg>", .err = error.UnsupportedTextLengthPercent },
            .{ .source = "<svg><text fill='red'>fi<tspan fill='blue' textLength='20'>X</tspan></text></svg>", .err = error.UnsupportedTextSpanLength },
            .{ .source = "<svg><text fill='red'>fi<tspan x='10' fill='blue'>X</tspan></text></svg>", .err = error.UnsupportedTextPaintChunks },
            .{ .source = "<svg><text fill='url(#g)'>fi<tspan fill='blue'>X</tspan></text></svg>", .err = error.UnsupportedTextPaintServer },
            .{ .source = "<svg><text fill='red'><tspan fill='url(#g)'>fiX</tspan></text></svg>", .err = error.UnsupportedTextPaintServer },
        };
        for (cases) |case| {
            mock = .{};
            try std.testing.expectError(case.err, image(a, case.source, mode, mock.provider(), .{}));
            try std.testing.expectEqual(@as(usize, 0), mock.calls);
        }
    }
}

test "mixed spacing cannot invent a gap or split the effective paint of a ligature" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        for ([_]struct { length: u32, err: anyerror }{
            .{ .length = 20, .err = error.UnsupportedTextLengthSingleCluster },
            .{ .length = 5, .err = error.UnsupportedTextPaintCluster },
        }) |case| {
            const source = try std.fmt.allocPrint(a, "<svg><text fill='red' textLength='{d}'>f<tspan fill='blue'>i</tspan></text></svg>", .{case.length});
            defer a.free(source);
            var mock: Mock = .{};
            try std.testing.expectError(case.err, image(a, source, mode, mock.provider(), .{}));
            try std.testing.expectEqual(@as(usize, 1), mock.calls);
        }
        var mock: Mock = .{};
        var provider = mock.provider();
        provider.supports_mapping = false;
        try std.testing.expectError(error.UnsupportedTextMapping, image(a, "<svg><text fill='red' textLength='20'>fi<tspan fill='blue'>X</tspan></text></svg>", mode, provider, .{}));
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
        mock = .{};
        try std.testing.expectError(error.UnsupportedTextPaintCluster, image(a, "<svg><text fill='red' textLength='20' lengthAdjust='spacingAndGlyphs'>f<tspan fill='blue'>i</tspan></text></svg>", mode, mock.provider(), .{}));
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
    }
}

fn allocationPass(allocator: std.mem.Allocator, mode: Mode) !void {
    var mock: Mock = .{};
    const result = try image(allocator, "<svg><g opacity='.5'><text x='4' y='12' fill='red' stroke='black'>fi<tspan fill='blue'>X</tspan></text></g></svg>", mode, mock.provider(), .{});
    defer result.close() catch unreachable;
}
fn uniformAllocationPass(allocator: std.mem.Allocator, mode: Mode) !void {
    var mock: Mock = .{};
    const result = try image(allocator, "<svg><text x='4' y='12' fill='red'><tspan fill='blue'>fiX</tspan></text></svg>", mode, mock.provider(), .{});
    defer result.close() catch unreachable;
}
test "paint runs commands and all candidate storage share cumulative preparation budgets" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, allocationPass, .{mode});
        try std.testing.checkAllAllocationFailures(a, uniformAllocationPass, .{mode});
        var mock: Mock = .{};
        const source = "<svg><text x='4' y='12' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>";
        try std.testing.expectError(error.TextPaintRunsFull, image(a, source, mode, mock.provider(), .{ .paint_runs = 1 }));
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
        try std.testing.expectError(error.TextCapacityExceeded, image(a, source, mode, mock.provider(), .{ .commands = 29 }));
        const result = try image(a, source, mode, mock.provider(), .{ .commands = 30, .paint_runs = 2 });
        defer result.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 30), (try result.stats()).text_accounted_commands);
    }
}

const Fault = struct {
    mock: Mock = .{},
    kind: enum { source, glyph_range, commands, bidi, empty, glyph_start },
    fn provider(self: *Fault) svg.text.Provider {
        return .{ .context = self, .shape = shape, .supports_mapping = true };
    }
    fn shape(context: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *Fault = @ptrCast(@alignCast(context));
        const inner = self.mock.provider();
        const result = try inner.shape(inner.context, allocator, request);
        const view = try result.mapping.?.view();
        const clusters = @constCast(view.clusters);
        const glyphs = @constCast(view.glyphs);
        switch (self.kind) {
            .source => clusters[0].source.end = request.utf8.len + 1,
            .glyph_range => clusters[1].glyphs.start = 0,
            .commands => glyphs[0].commands.start = std.math.maxInt(usize),
            .bidi => clusters[0].bidi_level = 1,
            .empty => clusters[0].glyphs.count = 0,
            .glyph_start => view.path.commands[5] = .{ .line = .{ .x = 5, .y = 0 } },
        }
        return result;
    }
};

const StretchProvider = struct {
    mock: Mock = .{},
    kind: enum { curves, arc, cells, zero },
    fn provider(self: *@This()) svg.text.Provider {
        return .{ .context = self, .shape = shape, .supports_mapping = true };
    }
    fn shape(ptr: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const inner = self.mock.provider();
        var result = try inner.shape(inner.context, allocator, request);
        const view = try result.mapping.?.view();
        switch (self.kind) {
            .curves => for ([_]*v.Path{ result.path, view.path }) |path| {
                path.commands[1] = .{ .quadratic = .{ .control = .{ .x = 5, .y = -2 }, .end = .{ .x = 5, .y = 4 } } };
                path.commands[2] = .{ .cubic = .{ .first = .{ .x = 5, .y = 7 }, .second = .{ .x = 2, .y = 10 }, .end = .{ .x = 0, .y = 10 } } };
                path.commands[3] = .{ .line = .{ .x = 0, .y = 0 } };
            },
            .arc => for ([_]*v.Path{ result.path, view.path }) |path| {
                path.commands[1] = .{ .arc = .{ .radius = .{ .x = 5, .y = 5 }, .sweep = true, .end = .{ .x = 5, .y = 10 } } };
            },
            .cells => {
                const values = [_]v.Bounds{ .{ .x = -1, .y = 0, .width = 7, .height = 14 }, .{ .x = 4, .y = -2, .width = 7, .height = 12 } };
                for (@constCast(view.glyphs), result.cells.?, values) |*glyph, *cell, value| {
                    glyph.cell = value;
                    cell.* = value;
                }
            },
            .zero => result.advance = 0,
        }
        return result;
    }
};

test "mixed horizontal placement transforms every Bezier point and preserves explicit arc limits" {
    const source = "<svg><text x='4' y='12' textLength='20' lengthAdjust='spacingAndGlyphs' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var provider: StretchProvider = .{ .kind = .curves };
        const actual = try image(a, source, mode, provider.provider(), .{});
        defer actual.close() catch unreachable;
        var unused: Mock = .{};
        const expected = try image(a, "<svg><path d='M4 4Q14 2 14 8C14 11 8 14 4 14L4 4Z' fill='red'/><rect x='14' y='4' width='10' height='10' fill='blue'/></svg>", mode, unused.provider(), .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        provider = .{ .kind = .arc };
        try std.testing.expectError(error.UnsupportedTextLengthOutline, image(a, source, mode, provider.provider(), .{}));
        const identity = try image(a, "<svg><text x='4' y='12' textLength='10' lengthAdjust='spacingAndGlyphs' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", mode, provider.provider(), .{});
        defer identity.close() catch unreachable;
        const arc_oracle = try image(a, "<svg><path d='M4 4A5 5 0 0 1 9 14H4Z' fill='red'/><rect x='9' y='4' width='5' height='10' fill='blue'/></svg>", mode, unused.provider(), .{});
        defer arc_oracle.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, arc_oracle.pixels, identity.pixels);
        provider = .{ .kind = .zero };
        try std.testing.expectError(error.UnsupportedTextLengthZeroAdvance, image(a, source, mode, provider.provider(), .{}));
        const zero = try image(a, "<svg><text x='4' y='12' textLength='0' lengthAdjust='spacingAndGlyphs' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", mode, provider.provider(), .{});
        defer zero.close() catch unreachable;
        const zero_oracle = try image(a, "<svg>" ++ left ++ right ++ "</svg>", mode, unused.provider(), .{});
        defer zero_oracle.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, zero_oracle.pixels, zero.pixels);
        try std.testing.expectError(error.UnsupportedTextLengthPrecision, image(a, "<svg><text textLength='5e-324' lengthAdjust='spacingAndGlyphs' fill='red'>fi<tspan fill='blue'>X</tspan></text></svg>", mode, unused.provider(), .{}));
    }
}

test "stretched whole-text bbox uses each full glyph cell after the outer affine" {
    const actual_source = "<svg><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect x='.1' y='.05' width='.7' height='.8'/></clipPath></defs><g opacity='.625' clip-path='url(#c)'><text x='4' y='12' textLength='20' lengthAdjust='spacingAndGlyphs' transform='matrix(1 .25 .5 1 0 0)' fill='red'>fi<tspan fill='blue'>X</tspan></text></g></svg>";
    // After x*2+(4,4), cells are [2,16]x[4,18] and [12,26]x[2,14].
    // Four corners through the shear give union [4,33]x[4.5,22], which is
    // smaller than transforming the aggregate local box [2,26]x[2,18].
    const expected_source = "<svg><defs><clipPath id='c'><rect x='6.9' y='5.375' width='20.3' height='14'/></clipPath></defs><g opacity='.625' clip-path='url(#c)'><g transform='matrix(1 .25 .5 1 0 0)'><rect x='4' y='4' width='10' height='10' fill='red'/><rect x='14' y='4' width='10' height='10' fill='blue'/></g></g></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var provider: StretchProvider = .{ .kind = .cells };
        const actual = try image(a, actual_source, mode, provider.provider(), .{});
        defer actual.close() catch unreachable;
        var unused: Mock = .{};
        const expected = try image(a, expected_source, mode, unused.provider(), .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        try std.testing.expectEqual(@as(usize, 1), provider.mock.calls);
    }
}
test "mixed fill validates provider ranges source coverage and direction before copying parts" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_][]const u8{ "", "dx='0 1 2' rotate='15 -20 25'", "textLength='20'", "textLength='20' lengthAdjust='spacingAndGlyphs'" }, 0..) |attributes, index| for (std.enums.values(@FieldType(Fault, "kind"))) |kind| {
        const positioned = index == 1 or index == 2;
        const source = try std.fmt.allocPrint(a, "<svg><text fill='red' {s}>fi<tspan fill='blue'>X</tspan></text></svg>", .{attributes});
        defer a.free(source);
        var fault: Fault = .{ .kind = kind };
        try std.testing.expectError(switch (kind) {
            .bidi => if (positioned) error.UnsupportedTextPositionBidi else error.UnsupportedTextPaintBidi,
            .empty => if (positioned) error.UnsupportedTextPositionCluster else error.UnsupportedTextPaintCluster,
            else => error.InvalidTextProviderMapping,
        }, image(a, source, mode, fault.provider(), .{}));
        try std.testing.expectEqual(@as(usize, 1), fault.mock.calls);
    };
}

const Overlap = struct {
    mock: Mock = .{},
    fn provider(self: *Overlap) svg.text.Provider {
        return .{ .context = self, .shape = shape, .supports_mapping = true };
    }
    fn shape(context: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *Overlap = @ptrCast(@alignCast(context));
        const inner = self.mock.provider();
        var result = try inner.shape(inner.context, allocator, request);
        const view = try result.mapping.?.view();
        const glyphs = @constCast(view.glyphs);
        const clusters = @constCast(view.clusters);
        // This provider paints the right blue glyph before the overlapping
        // left red glyph. Its command order is explicit, its source order is
        // reversed, and sorting by either x or source would reverse the ink.
        for (glyphs, clusters, 0..) |*glyph, *cluster, i| {
            const x: f64 = if (i == 0) 4 else 0;
            const commands = [_]v.Command{ .{ .move = .{ .x = x, .y = 0 } }, .{ .line = .{ .x = x + 8, .y = 0 } }, .{ .line = .{ .x = x + 8, .y = 10 } }, .{ .line = .{ .x = x, .y = 10 } }, .close };
            @memcpy(view.path.commands[i * 5 ..][0..5], &commands);
            @memcpy(result.path.commands[i * 5 ..][0..5], &commands);
            glyph.cell = .{ .x = x, .y = 0, .width = 8, .height = 10 };
            glyph.pen = .{ .x = x + 8, .y = 8 };
            glyph.advance = -8;
            result.cells.?[i] = glyph.cell;
            cluster.source = if (i == 0) .{ .start = 2, .end = 3 } else .{ .start = 0, .end = 2 };
        }
        result.advance = 12;
        return result;
    }
};
test "transparent overlapping RTL glyphs preserve provider paint order rather than source or x sorting" {
    const cases = [_]struct { text: []const u8, oracle: []const u8 }{
        .{ .text = "<svg><text x='20' y='12' direction='rtl' fill='red' fill-opacity='.5'>fi<tspan fill='blue'>X</tspan></text></svg>", .oracle = "<svg><rect x='12' y='4' width='8' height='10' fill='blue' fill-opacity='.5'/><rect x='8' y='4' width='8' height='10' fill='red' fill-opacity='.5'/></svg>" },
        .{ .text = "<svg><text x='20' y='12' direction='rtl' dx='0 0 1' rotate='90 0 0' fill='red' fill-opacity='.5'>fi<tspan fill='blue'>X</tspan></text></svg>", .oracle = "<svg><rect x='12' y='4' width='8' height='10' fill='blue' fill-opacity='.5'/><rect x='13' y='4' width='10' height='8' fill='red' fill-opacity='.5'/></svg>" },
        .{ .text = "<svg><text x='20' y='12' direction='rtl' textLength='20' fill='red' fill-opacity='.5'>fi<tspan fill='blue'>X</tspan></text></svg>", .oracle = "<svg><rect x='8' y='4' width='8' height='10' fill='blue' fill-opacity='.5'/><rect x='12' y='4' width='8' height='10' fill='red' fill-opacity='.5'/></svg>" },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        var provider: Overlap = .{};
        const actual = try image(a, case.text, mode, provider.provider(), .{});
        defer actual.close() catch unreachable;
        var unused: Mock = .{};
        const expected = try image(a, case.oracle, mode, unused.provider(), .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        const pixel = actual.pixels[(8 * 32 + 14) * 4 ..][0..4];
        try std.testing.expectEqual(@as(u8, 64), pixel[0]);
        try std.testing.expectEqual(@as(u8, 128), pixel[2]);
        try std.testing.expectEqual(@as(usize, 1), provider.mock.calls);
    };
}

const Three = struct {
    calls: usize = 0,
    fn provider(self: *Three) svg.text.Provider {
        return .{ .context = self, .shape = shape, .supports_mapping = true };
    }
    fn shape(context: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *Three = @ptrCast(@alignCast(context));
        self.calls += 1;
        try std.testing.expectEqualStrings("fiXY", request.utf8);
        try std.testing.expect(request.include_mapping);
        var commands: [15]v.Command = undefined;
        var glyphs: [3]svg.text.mapping.Glyph = undefined;
        var clusters: [3]svg.text.mapping.Cluster = undefined;
        for (0..3) |i| {
            const x: f64 = @floatFromInt(i * 5);
            commands[i * 5 ..][0..5].* = .{ .{ .move = .{ .x = x, .y = 0 } }, .{ .line = .{ .x = x + 5, .y = 0 } }, .{ .line = .{ .x = x + 5, .y = 10 } }, .{ .line = .{ .x = x, .y = 10 } }, .close };
            glyphs[i] = .{ .commands = .{ .start = i * 5, .count = 5 }, .cluster = i, .pen = .{ .x = x, .y = 8 }, .advance = 5, .cell = .{ .x = x, .y = 0, .width = 5, .height = 10 } };
            clusters[i] = .{ .source = .{ .start = if (i == 0) 0 else i + 1, .end = i + 2 }, .glyphs = .{ .start = i, .count = 1 }, .commands = glyphs[i].commands, .bidi_level = 0 };
        }
        const batch = try v.Path.create(allocator, &commands, .{});
        errdefer batch.close() catch unreachable;
        const path = try v.Path.create(allocator, &commands, .{});
        errdefer path.close() catch unreachable;
        const source = try allocator.dupe(u8, request.utf8);
        errdefer allocator.free(source);
        const gs = try allocator.dupe(svg.text.mapping.Glyph, &glyphs);
        errdefer allocator.free(gs);
        const cs = try allocator.dupe(svg.text.mapping.Cluster, &clusters);
        errdefer allocator.free(cs);
        const mapping = try svg.text.Mapping.adopt(allocator, .{ .path = path, .source = source, .glyphs = gs, .clusters = cs });
        return .{ .path = batch, .mapping = mapping, .glyphs = 3, .first_baseline = 8, .advance = 15 };
    }
};
const repartition_source = "<svg><defs><text id='t' x='2' y='12' fill='currentColor'>fi<tspan fill='blue'>X</tspan><tspan fill='red'>Y</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='blue' x='14'/></svg>";
const positioned_repartition_source = "<svg><defs><text id='t' x='2' y='12' rotate='90 0 0 0' dx='0 1 2 3' fill='currentColor'>fi<tspan fill='blue'>X</tspan><tspan fill='red'>Y</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='blue' x='8'/></svg>";
const spacing_repartition_source = "<svg><defs><text id='t' x='2' y='12' textLength='23' rotate='90 0 0 0' dx='0 1 2 3' fill='currentColor'>fi<tspan fill='blue'>X</tspan><tspan fill='red'>Y</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='blue' x='8'/></svg>";
const stretch_repartition_source = "<svg><defs><text id='t' x='2' y='12' textLength='30' lengthAdjust='spacingAndGlyphs' fill='currentColor'>fi<tspan fill='blue'>X</tspan><tspan fill='red'>Y</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='blue' x='4'/></svg>";
test "paint cache repartition replaces owning paths and preserves earlier instance brushes" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var provider: Three = .{};
        const actual = try image(a, repartition_source, mode, provider.provider(), .{ .source_bytes = 4, .paint_runs = 5, .commands = 75 });
        defer actual.close() catch unreachable;
        var unused: Mock = .{};
        const expected = try image(a, "<svg><rect x='2' y='4' width='5' height='10' fill='red'/><rect x='7' y='4' width='5' height='10' fill='blue'/><rect x='12' y='4' width='5' height='10' fill='red'/><rect x='16' y='4' width='10' height='10' fill='blue'/><rect x='26' y='4' width='5' height='10' fill='red'/></svg>", mode, unused.provider(), .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        const stats = try actual.stats();
        try std.testing.expectEqual(@as(usize, 5), stats.text_paint_runs);
        try std.testing.expectEqual(@as(usize, 30), stats.text_paint_commands);
        try std.testing.expectEqual(@as(usize, 75), stats.text_accounted_commands);
    }
}
test "recolor and repartition reuse the placed mapping without applying its mutable pose twice" {
    const oracle = "<svg><rect x='0' y='12' width='10' height='5' fill='red'/><rect x='10' y='4' width='5' height='10' fill='blue'/><rect x='18' y='4' width='5' height='10' fill='red'/><rect x='8' y='12' width='10' height='5' fill='blue'/><rect x='18' y='4' width='5' height='10' fill='blue'/><rect x='26' y='4' width='5' height='10' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var provider: Three = .{};
        const actual = try image(a, positioned_repartition_source, mode, provider.provider(), .{ .source_bytes = 4, .paint_runs = 5, .commands = 75 });
        defer actual.close() catch unreachable;
        var unused: Mock = .{};
        const expected = try image(a, oracle, mode, unused.provider(), .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        const stats = try actual.stats();
        try std.testing.expectEqual(@as(usize, 1), stats.text_mapping_requests);
        try std.testing.expectEqual(@as(usize, 5), stats.text_paint_runs);
        try std.testing.expectEqual(@as(usize, 30), stats.text_paint_commands);
        try std.testing.expectEqual(@as(usize, 75), stats.text_accounted_commands);
    }
}
test "mixed spacing reuses its placed mapping when inherited paints change partitions" {
    // The unspaced advance intervals are [0,5], [8,13], [16,21].
    // Target 23 adds displacements 0/1/2 before the common anchor offset 2.
    const oracle = "<svg><rect x='0' y='12' width='10' height='5' fill='red'/><rect x='11' y='4' width='5' height='10' fill='blue'/><rect x='20' y='4' width='5' height='10' fill='red'/><rect x='8' y='12' width='10' height='5' fill='blue'/><rect x='19' y='4' width='5' height='10' fill='blue'/><rect x='28' y='4' width='5' height='10' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var provider: Three = .{};
        const actual = try image(a, spacing_repartition_source, mode, provider.provider(), .{ .source_bytes = 4, .paint_runs = 5, .commands = 75 });
        defer actual.close() catch unreachable;
        var unused: Mock = .{};
        const expected = try image(a, oracle, mode, unused.provider(), .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        const stats = try actual.stats();
        try std.testing.expectEqual(@as(usize, 1), stats.text_mapping_requests);
        try std.testing.expectEqual(@as(usize, 5), stats.text_paint_runs);
        try std.testing.expectEqual(@as(usize, 30), stats.text_paint_commands);
        try std.testing.expectEqual(@as(usize, 75), stats.text_accounted_commands);
        try std.testing.expectError(error.TextWorkExceeded, image(a, spacing_repartition_source, mode, provider.provider(), .{ .work = stats.text_work - 1 }));
        try std.testing.expectError(error.TextPaintRunsFull, image(a, spacing_repartition_source, mode, provider.provider(), .{ .paint_runs = 4 }));
        try std.testing.expectError(error.TextCapacityExceeded, image(a, spacing_repartition_source, mode, provider.provider(), .{ .commands = 74 }));
    }
}
test "mixed horizontal stretch is not reapplied when use recolors or repartitions" {
    const oracle = "<svg><rect x='2' y='4' width='10' height='10' fill='red'/><rect x='12' y='4' width='10' height='10' fill='blue'/><rect x='22' y='4' width='10' height='10' fill='red'/><rect x='6' y='4' width='20' height='10' fill='blue'/><rect x='26' y='4' width='10' height='10' fill='red'/></svg>";
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var provider: Three = .{};
        const actual = try image(a, stretch_repartition_source, mode, provider.provider(), .{ .source_bytes = 4, .paint_runs = 5, .commands = 75 });
        defer actual.close() catch unreachable;
        var unused: Mock = .{};
        const expected = try image(a, oracle, mode, unused.provider(), .{});
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        const stats = try actual.stats();
        try std.testing.expectEqual(@as(usize, 1), stats.text_mapping_requests);
        try std.testing.expectEqual(@as(usize, 5), stats.text_paint_runs);
        try std.testing.expectEqual(@as(usize, 75), stats.text_accounted_commands);
        try std.testing.expectError(error.TextWorkExceeded, image(a, stretch_repartition_source, mode, provider.provider(), .{ .work = stats.text_work - 1 }));
        try std.testing.expectError(error.TextPaintRunsFull, image(a, stretch_repartition_source, mode, provider.provider(), .{ .paint_runs = 4 }));
        try std.testing.expectError(error.TextCapacityExceeded, image(a, stretch_repartition_source, mode, provider.provider(), .{ .commands = 74 }));
    }
}
fn repartitionAllocationPass(allocator: std.mem.Allocator, mode: Mode, source: []const u8) !void {
    var provider: Three = .{};
    const result = try image(allocator, source, mode, provider.provider(), .{});
    defer result.close() catch unreachable;
}
const Reentry = struct {
    document: *svg.Document,
    cancellation: *v.Cancellation,
    cancel_at: usize = std.math.maxInt(usize),
    events: usize = 0,
    live: usize = 0,
    active: bool = true,
    failure: ?anyerror = null,
    fn allocator(self: *Reentry) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn fire(self: *Reentry) void {
        if (!self.active) return;
        std.testing.expectError(error.Busy, self.document.close()) catch |err| {
            self.failure = err;
        };
        if (self.events == self.cancel_at) self.cancellation.request();
        self.events += 1;
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Reentry = @ptrCast(@alignCast(context));
        self.fire();
        const memory = a.rawAlloc(len, alignment, ret) orelse return null;
        self.live += len;
        return memory;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Reentry = @ptrCast(@alignCast(context));
        self.fire();
        self.live -= memory.len;
        a.rawFree(memory, alignment, ret);
    }
};
test "repartition allocation failures and every foreign allocation or free cancellation unwind the whole candidate" {
    for ([_][]const u8{ repartition_source, positioned_repartition_source, spacing_repartition_source, stretch_repartition_source }) |source| {
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        for ([_]Mode{ .pixel, .sample_color }) |mode| {
            try std.testing.checkAllAllocationFailures(a, repartitionAllocationPass, .{ mode, source });
            var provider: Three = .{};
            var cancellation: v.Cancellation = .{};
            var probe: Reentry = .{ .document = document, .cancellation = &cancellation };
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = provider.provider(), .cancellation = &cancellation };
            const result = try document.prepare(probe.allocator(), options);
            const events = probe.events;
            const peak = (try result.stats()).peak_bytes;
            probe.active = false;
            try result.close();
            if (probe.failure) |err| return err;
            try std.testing.expectEqual(@as(usize, 0), probe.live);
            options.limits.bytes = peak - 1;
            try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
            options.limits.bytes = 64 * 1024 * 1024;
            for (0..events) |at| {
                provider = .{};
                cancellation = .{};
                probe = .{ .document = document, .cancellation = &cancellation, .cancel_at = at };
                options.text_provider = provider.provider();
                try std.testing.expectError(error.Cancelled, document.prepare(probe.allocator(), options));
                if (probe.failure) |err| return err;
                try std.testing.expectEqual(@as(usize, 0), probe.live);
            }
        }
    }
}
