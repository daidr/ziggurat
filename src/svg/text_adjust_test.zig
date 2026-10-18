const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const a = std.testing.allocator;
const Mode = @TypeOf((svg.PrepareOptions{ .main_thread = 0, .width = 1, .height = 1 }).compositing);
pub const Mock = struct {
    calls: usize = 0,
    pub fn provider(self: *Mock) svg.text.Provider {
        return .{ .context = self, .shape = shape, .supports_mapping = true };
    }
    fn shape(context: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
        const self: *Mock = @ptrCast(@alignCast(context));
        self.calls += 1;
        const count: usize = if (std.mem.endsWith(u8, request.utf8, "X")) 2 else 1;
        var commands: [10]v.Command = undefined;
        var glyphs: [2]svg.text.mapping.Glyph = undefined;
        var clusters: [2]svg.text.mapping.Cluster = undefined;
        var cells: [2]v.Bounds = undefined;
        for (0..count) |i| {
            const left: f64 = @floatFromInt(if (request.font.direction == .rtl) (count - 1 - i) * 5 else i * 5);
            commands[i * 5 ..][0..5].* = .{ .{ .move = .{ .x = left, .y = 0 } }, .{ .line = .{ .x = left + 5, .y = 0 } }, .{ .line = .{ .x = left + 5, .y = 10 } }, .{ .line = .{ .x = left, .y = 10 } }, .close };
            cells[i] = .{ .x = left, .y = 0, .width = 5, .height = 10 };
            glyphs[i] = .{ .commands = .{ .start = i * 5, .count = 5 }, .cluster = i, .pen = .{ .x = left + @as(f64, if (request.font.direction == .rtl) 5 else 0), .y = 8 }, .advance = if (request.font.direction == .rtl) -5 else 5, .cell = cells[i] };
            clusters[i] = .{ .source = .{ .start = if (i == 0) 0 else 2, .end = if (i == 0 and count == 2) 2 else request.utf8.len }, .glyphs = .{ .start = i, .count = 1 }, .commands = glyphs[i].commands, .bidi_level = if (request.font.direction == .rtl) 1 else 0 };
        }
        const path = try v.Path.create(allocator, commands[0 .. count * 5], .{});
        errdefer path.close() catch unreachable;
        const owned_cells = try allocator.dupe(v.Bounds, cells[0..count]);
        errdefer allocator.free(owned_cells);
        var mapping: ?*svg.text.Mapping = null;
        if (request.include_mapping) {
            const mp = try v.Path.create(allocator, commands[0 .. count * 5], .{});
            errdefer mp.close() catch unreachable;
            const src = try allocator.dupe(u8, request.utf8);
            errdefer allocator.free(src);
            const gs = try allocator.dupe(svg.text.mapping.Glyph, glyphs[0..count]);
            errdefer allocator.free(gs);
            const cs = try allocator.dupe(svg.text.mapping.Cluster, clusters[0..count]);
            errdefer allocator.free(cs);
            mapping = try svg.text.Mapping.adopt(allocator, .{ .path = mp, .source = src, .glyphs = gs, .clusters = cs });
        }
        return .{ .path = path, .cells = owned_cells, .mapping = mapping, .first_baseline = 8, .advance = @floatFromInt(count * 5), .glyphs = count };
    }
};
fn compare(input: []const u8, expected: []const u8, mode: Mode) !void {
    const doc = try svg.Document.parse(a, input, .{});
    defer doc.close() catch unreachable;
    const oracle = try svg.Document.parse(a, expected, .{});
    defer oracle.close() catch unreachable;
    var mock: Mock = .{};
    const actual = try doc.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .text_provider = mock.provider(), .compositing = mode });
    defer actual.close() catch unreachable;
    const image = try oracle.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode });
    defer image.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqualSlices(u8, image.pixels, actual.pixels);
}

const NumericWork = struct {
    pub fn check(_: *@This()) !void {}
};

test "default textLength spacing keeps complete typographic units rigid" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try compare("<svg><text x='4' y='12' textLength='20'>f<tspan>iX</tspan></text></svg>", "<svg><path d='M4 4H9V14H4Z M19 4H24V14H19Z'/></svg>", mode);
        try compare("<svg><text x='20' y='12' direction='rtl' textLength='20' lengthAdjust='spacing'>fiX</text></svg>", "<svg><path d='M15 4H20V14H15Z M0 4H5V14H0Z'/></svg>", mode);
        try compare("<svg><text x='4' y='12' textLength='4'>fiX</text></svg>", "<svg><path d='M5 4H10V14H5Z M4 4H9V14H4Z'/></svg>", mode);
        try compare("<svg><text x='4' y='12' dx='0 2 3' textLength='20'>fiX</text></svg>", "<svg><path d='M4 4H9V14H4Z M19 4H24V14H19Z'/></svg>", mode);
        try compare("<svg><text x='4' y='12' rotate='30' textLength='20'>fiX</text></svg>", "<svg><path d='M0 0H5V10H0Z' transform='translate(4 4) rotate(30 0 8)'/><path d='M0 0H5V10H0Z' transform='translate(19 4) rotate(30 0 8)'/></svg>", mode);
    }
}
const NumericCache = struct {
    work: *NumericWork,
    used: u64 = 0,
    pub fn charge(self: *@This(), amount: u64) !void {
        if (amount > 4096 -| self.used) return error.TextWorkExceeded;
        self.used += amount;
    }
};
fn numericAnchor(direction: svg.text.Direction, anchor: svg.text.Anchor, source: []const u8, delta: f64, expected: []const f64) !void {
    return numericAdjust(direction, anchor, source, delta, null, expected);
}
fn numericAdjust(direction: svg.text.Direction, anchor: svg.text.Anchor, source: []const u8, delta: f64, spacing: ?f64, expected: []const f64) !void {
    var mock: Mock = .{};
    const result = try Mock.shape(&mock, a, .{ .utf8 = source, .font = .{ .direction = direction }, .max_glyphs = 2, .max_commands = 20, .max_bytes = 65536, .cancellation = null, .include_mapping = true });
    defer result.path.close() catch unreachable;
    defer a.free(result.cells.?);
    const mapping = result.mapping.?;
    defer mapping.close() catch unreachable;
    const view = try mapping.view();
    var plan: @import("text_position.zig").Plan = .{ .allocator = a, .viewport = .{ .width = 32, .height = 24 } };
    plan.text_length = spacing;
    plan.spacing_length = spacing != null;
    defer plan.deinit();
    try plan.source.appendSlice(a, source);
    plan.character_count = source.len;
    for (0..source.len) |i| try plan.characters.append(a, .{ .start = i, .end = i + 1, .dx = if (i == source.len - 1) delta else 0 });
    var work: NumericWork = .{};
    var cache: NumericCache = .{ .work = &work };
    const quads = try @import("text_adjust.zig").apply(&cache, a, view, &plan, .{ .direction = direction }, anchor, .{ .x = 0, .y = 8 }, 8);
    defer a.free(quads);
    try std.testing.expectEqual(expected.len, view.glyphs.len);
    for (expected, 0..) |left, i| {
        const start = i * 5;
        try std.testing.expectEqualDeep(v.Command{ .move = .{ .x = left, .y = 0 } }, view.path.commands[start]);
        try std.testing.expectEqualDeep(v.Command{ .line = .{ .x = left + 5, .y = 0 } }, view.path.commands[start + 1]);
        try std.testing.expectEqualDeep(v.Command{ .line = .{ .x = left + 5, .y = 10 } }, view.path.commands[start + 2]);
        try std.testing.expectEqualDeep(v.Command{ .line = .{ .x = left, .y = 10 } }, view.path.commands[start + 3]);
        try std.testing.expectEqualDeep(@import("text_adjust.zig").Quad{ .{ .x = left, .y = 0 }, .{ .x = left + 5, .y = 0 }, .{ .x = left, .y = 10 }, .{ .x = left + 5, .y = 10 } }, quads[i]);
    }
}

test "SVG2 anchor uses signed advance extents when relative positions cross the chunk origin" {
    // Fixed coordinates from the SVG2 anchoring algorithm, not an oracle
    // derived by executing the implementation's min/max or anchor branches.
    const Case = struct { direction: svg.text.Direction, anchor: svg.text.Anchor, delta: f64, left: [2]f64 };
    const cases = [_]Case{
        .{ .direction = .ltr, .anchor = .start, .delta = -100, .left = .{ 95, 0 } },
        .{ .direction = .ltr, .anchor = .middle, .delta = -100, .left = .{ 45, -50 } },
        .{ .direction = .ltr, .anchor = .end, .delta = -100, .left = .{ -5, -100 } },
        .{ .direction = .ltr, .anchor = .start, .delta = 100, .left = .{ 0, 105 } },
        .{ .direction = .ltr, .anchor = .middle, .delta = 100, .left = .{ -55, 50 } },
        .{ .direction = .ltr, .anchor = .end, .delta = 100, .left = .{ -110, -5 } },
        .{ .direction = .rtl, .anchor = .start, .delta = -100, .left = .{ -5, -110 } },
        .{ .direction = .rtl, .anchor = .middle, .delta = -100, .left = .{ 50, -55 } },
        .{ .direction = .rtl, .anchor = .end, .delta = -100, .left = .{ 105, 0 } },
        .{ .direction = .rtl, .anchor = .start, .delta = 100, .left = .{ -100, -5 } },
        .{ .direction = .rtl, .anchor = .middle, .delta = 100, .left = .{ -50, 45 } },
        .{ .direction = .rtl, .anchor = .end, .delta = 100, .left = .{ 0, 95 } },
    };
    for (cases) |case| try numericAnchor(case.direction, case.anchor, "fiX", case.delta, &case.left);
}

test "unused delta inside the final typographic unit does not change any anchor" {
    const Case = struct { direction: svg.text.Direction, anchor: svg.text.Anchor, left: f64 };
    const cases = [_]Case{
        .{ .direction = .ltr, .anchor = .start, .left = 0 },
        .{ .direction = .ltr, .anchor = .middle, .left = -2.5 },
        .{ .direction = .ltr, .anchor = .end, .left = -5 },
        .{ .direction = .rtl, .anchor = .start, .left = -5 },
        .{ .direction = .rtl, .anchor = .middle, .left = -2.5 },
        .{ .direction = .rtl, .anchor = .end, .left = 0 },
    };
    for (cases) |case| for ([_]f64{ -100, 0, 100 }) |delta| try numericAnchor(case.direction, case.anchor, "fi", delta, &.{case.left});
}
test "cluster interior deltas carry to the next unit without reshaping or splitting" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try compare("<svg><text x='4' y='12' dx='0 3 4'>f<tspan>iX</tspan></text></svg>", "<svg><path d='M4 4H9V14H4Z M16 4H21V14H16Z'/></svg>", mode);
        try compare("<svg><text x='4' y='12' dx='0 99' dy='0 70'>fi</text></svg>", "<svg><path d='M4 4H9V14H4Z'/></svg>", mode);
        try compare("<svg><text x='20' y='12' direction='rtl' dx='0 2 3'>fiX</text></svg>", "<svg><path d='M15 4H20V14H15Z M15 4H20V14H15Z'/></svg>", mode);
        try compare("<svg><text x='20' y='12' text-anchor='middle' dx='0 3 4'>fiX</text></svg>", "<svg><path d='M11.5 4H16.5V14H11.5Z M23.5 4H28.5V14H23.5Z'/></svg>", mode);
    }
}
test "ancestor rotation repeats its tail and nested rotation wins only in its scope" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try compare("<svg><text x='4' y='12' rotate='0 30'>f<tspan>i</tspan>X</text></svg>", "<svg><path d='M0 0H5V10H0Z' transform='translate(4 4)'/><path d='M5 0H10V10H5Z' transform='translate(4 4) rotate(30 5 8)'/></svg>", mode);
        try compare("<svg><text x='4' y='12' rotate='30'><tspan rotate='0'>fi</tspan><tspan rotate='0'>X</tspan></text></svg>", "<svg><path d='M4 4H9V14H4Z M9 4H14V14H9Z'/></svg>", mode);
        try compare("<svg><text x='4' y='12' rotate='0'><tspan rotate='30'>fi</tspan>X</text></svg>", "<svg><path d='M0 0H5V10H0Z' transform='translate(4 4) rotate(30 0 8)'/><path d='M9 4H14V14H9Z'/></svg>", mode);
    }
}
test "mapping combinations reject before font access and defaults retain legacy providers" {
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "<svg><text rotate='20' textLength='12' lengthAdjust='spacingAndGlyphs'>fi</text></svg>", .err = error.UnsupportedTextLengthPositioning },
        .{ .source = "<svg><text rotate='20' x='1 12'>fi</text></svg>", .err = error.UnsupportedTextPositionChunks },
        .{ .source = "<svg><text textLength='20' x='1 12'>fiX</text></svg>", .err = error.UnsupportedTextLengthChunks },
        .{ .source = "<svg><text rotate='20'>f\u{202e}i</text></svg>", .err = error.UnsupportedTextPositionControls },
    };
    for (cases) |case| for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const doc = try svg.Document.parse(a, case.source, .{});
        defer doc.close() catch unreachable;
        var mock: Mock = .{};
        try std.testing.expectError(case.err, doc.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .text_provider = mock.provider(), .compositing = mode }));
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
    };
}
fn allocated(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode) !void {
    var mock: Mock = .{};
    const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .text_provider = mock.provider(), .compositing = mode });
    defer output.close() catch unreachable;
}
test "mapped path candidates and metadata release every failed allocation" {
    const doc = try svg.Document.parse(a, "<svg><text x='4' y='12' dx='0 2' rotate='15 25'>fiX</text></svg>", .{});
    defer doc.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.checkAllAllocationFailures(a, allocated, .{ doc, mode });
}

test "spacing anchors use the final signed advance intervals even after reversal" {
    const Case = struct { direction: svg.text.Direction, anchor: svg.text.Anchor, length: f64, left: [2]f64 };
    const cases = [_]Case{
        .{ .direction = .ltr, .anchor = .start, .length = 20, .left = .{ 0, 15 } },
        .{ .direction = .ltr, .anchor = .middle, .length = 20, .left = .{ -10, 5 } },
        .{ .direction = .ltr, .anchor = .end, .length = 20, .left = .{ -20, -5 } },
        .{ .direction = .rtl, .anchor = .start, .length = 20, .left = .{ -5, -20 } },
        .{ .direction = .rtl, .anchor = .middle, .length = 20, .left = .{ 5, -10 } },
        .{ .direction = .rtl, .anchor = .end, .length = 20, .left = .{ 15, 0 } },
        .{ .direction = .ltr, .anchor = .start, .length = 4, .left = .{ 1, 0 } },
        .{ .direction = .ltr, .anchor = .middle, .length = 4, .left = .{ -2, -3 } },
        .{ .direction = .ltr, .anchor = .end, .length = 4, .left = .{ -5, -6 } },
        .{ .direction = .rtl, .anchor = .start, .length = 4, .left = .{ -6, -5 } },
        .{ .direction = .rtl, .anchor = .middle, .length = 4, .left = .{ -3, -2 } },
        .{ .direction = .rtl, .anchor = .end, .length = 4, .left = .{ 0, 1 } },
    };
    for (cases) |case| try numericAdjust(case.direction, case.anchor, "fiX", 0, case.length, &case.left);
    try numericAdjust(.ltr, .start, "fi", 0, 5, &.{0});
    try std.testing.expectError(error.UnsupportedTextLengthSingleCluster, numericAdjust(.ltr, .start, "fi", 0, 20, &.{0}));
}
test "spacing orders three unequal clusters with a zero advance and reversed storage" {
    const Case = struct { direction: svg.text.Direction, desired: f64, left: [3]f64 };
    const cases = [_]Case{
        .{ .direction = .ltr, .desired = 12, .left = .{ 6, 4, 0 } },
        .{ .direction = .ltr, .desired = 0, .left = .{ 0, 4, 6 } },
        .{ .direction = .rtl, .desired = 12, .left = .{ -12, -4, -2 } },
        .{ .direction = .rtl, .desired = 0, .left = .{ -6, -4, -8 } },
    };
    for (cases) |case| {
        // Storage is C/B/A; source logical order is A/B/C. B paints ink
        // without advancing, while A and C advance different distances.
        const path = try v.Path.parseData(a, if (case.direction == .ltr) "M2 0H8V10H2Z M2 0H3V10H2Z M0 0H2V10H0Z" else "M0 0H6V10H0Z M6 0H7V10H6Z M6 0H8V10H6Z", .{});
        defer path.close() catch unreachable;
        const cells = if (case.direction == .ltr) [_]v.Bounds{
            .{ .x = 2, .y = 0, .width = 6, .height = 10 },
            .{ .x = 2, .y = 0, .width = 1, .height = 10 },
            .{ .x = 0, .y = 0, .width = 2, .height = 10 },
        } else [_]v.Bounds{
            .{ .x = 0, .y = 0, .width = 6, .height = 10 },
            .{ .x = 6, .y = 0, .width = 1, .height = 10 },
            .{ .x = 6, .y = 0, .width = 2, .height = 10 },
        };
        const pens: [3]f64 = if (case.direction == .ltr) .{ 2, 2, 0 } else .{ 6, 6, 8 };
        const advances: [3]f64 = if (case.direction == .ltr) .{ 6, 0, 2 } else .{ -6, 0, -2 };
        var glyphs: [3]svg.text.mapping.Glyph = undefined;
        var clusters: [3]svg.text.mapping.Cluster = undefined;
        for (0..3) |i| {
            glyphs[i] = .{ .commands = .{ .start = i * 5, .count = 5 }, .cluster = i, .pen = .{ .x = pens[i], .y = 8 }, .advance = advances[i], .cell = cells[i] };
            clusters[i] = .{ .source = .{ .start = 2 - i, .end = 3 - i }, .glyphs = .{ .start = i, .count = 1 }, .commands = glyphs[i].commands, .bidi_level = if (case.direction == .rtl) 1 else 0 };
        }
        var plan: @import("text_position.zig").Plan = .{ .allocator = a, .viewport = .{ .width = 32, .height = 24 }, .character_count = 3, .text_length = case.desired, .spacing_length = true };
        defer plan.deinit();
        try plan.source.appendSlice(a, "ABC");
        for (0..3) |i| try plan.characters.append(a, .{ .start = i, .end = i + 1 });
        var work: NumericWork = .{};
        var cache: NumericCache = .{ .work = &work };
        const quads = try @import("text_adjust.zig").apply(&cache, a, .{ .path = path, .source = "ABC", .glyphs = &glyphs, .clusters = &clusters }, &plan, .{ .direction = case.direction }, .start, .{ .x = 0, .y = 8 }, 8);
        defer a.free(quads);
        for (case.left, 0..) |left, i| {
            try std.testing.expectEqualDeep(v.Command{ .move = .{ .x = left, .y = 0 } }, path.commands[i * 5]);
            try std.testing.expectEqual(left, quads[i][0].x);
            try std.testing.expectEqual(left + cells[i].width, quads[i][1].x);
        }
    }
}
test "spacing candidates release every failed allocation and hidden text needs no mapping" {
    const document = try svg.Document.parse(a, "<svg><text x='4' y='12' rotate='20' textLength='20'>fiX</text></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.checkAllAllocationFailures(a, allocated, .{ document, mode });
    const hidden = try svg.Document.parse(a, "<svg><text visibility='hidden' textLength='20'>fiX</text></svg>", .{});
    defer hidden.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var mock: Mock = .{};
        var provider = mock.provider();
        provider.supports_mapping = false;
        const output = try hidden.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .text_provider = provider, .compositing = mode });
        defer output.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
        for (output.pixels) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
test "full rotated cell corners survive outer affine group bounding boxes" {
    const outer: v.Transform = .{ .xx = 0.8, .yx = 0.2, .xy = 0.3, .yy = 0.9, .x0 = 1, .y0 = 1 };
    const cosine = @cos(@as(f64, 30) * std.math.pi / 180);
    const sine = @sin(@as(f64, 30) * std.math.pi / 180);
    var minimum: v.Point = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
    var maximum: v.Point = .{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) };
    for ([_]f64{ 0, 5 }) |left| {
        const turn: v.Transform = .{ .xx = cosine, .yx = sine, .xy = -sine, .yy = cosine, .x0 = left + 4 - cosine * left + sine * 8, .y0 = 12 - sine * left - cosine * 8 };
        for ([_]v.Point{ .{ .x = left, .y = 0 }, .{ .x = left + 5, .y = 0 }, .{ .x = left, .y = 10 }, .{ .x = left + 5, .y = 10 } }) |corner| {
            const point = outer.apply(turn.apply(corner));
            minimum.x = @min(minimum.x, point.x);
            minimum.y = @min(minimum.y, point.y);
            maximum.x = @max(maximum.x, point.x);
            maximum.y = @max(maximum.y, point.y);
        }
    }
    const body = "<g clip-path='url(#c)'><g transform='matrix(.8 .2 .3 .9 1 1)'><text x='4' y='12' rotate='30'>fiX</text></g></g></svg>";
    const source = "<svg><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='.5' height='1'/></clipPath></defs>" ++ body;
    const expected = try std.fmt.allocPrint(a, "<svg><defs><clipPath id='c'><rect x='{d}' y='{d}' width='{d}' height='{d}'/></clipPath></defs>" ++ body, .{ minimum.x, minimum.y, (maximum.x - minimum.x) / 2, maximum.y - minimum.y });
    defer a.free(expected);
    const doc = try svg.Document.parse(a, source, .{});
    defer doc.close() catch unreachable;
    const oracle = try svg.Document.parse(a, expected, .{});
    defer oracle.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var mock: Mock = .{};
        const actual = try doc.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = mock.provider() });
        defer actual.close() catch unreachable;
        mock = .{};
        const image = try oracle.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = mock.provider() });
        defer image.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, image.pixels, actual.pixels);
    }
}
test "mapping cache counts both source paths and repeated rendering instances" {
    const doc = try svg.Document.parse(a, "<svg><defs><text id='t' x='4' y='12' rotate='30'>fiX</text></defs><use href='#t'/><use href='#t' x='12'/></svg>", .{});
    defer doc.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var mock: Mock = .{};
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .compositing = mode, .text_provider = mock.provider() };
        options.limits.text.commands = 30;
        const output = try doc.prepare(a, options);
        defer output.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try std.testing.expectEqual(@as(usize, 20), (try output.stats()).text_commands);
        try std.testing.expectEqual(@as(usize, 30), (try output.stats()).text_accounted_commands);
        try std.testing.expectEqual(@as(usize, 1), (try output.stats()).text_mapping_requests);
        options.limits.text.commands = 29;
        mock = .{};
        try std.testing.expectError(error.TextCapacityExceeded, doc.prepare(a, options));
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
    }
}
