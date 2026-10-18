const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const svg = @import("ziggurat_svg");
const svg_text = @import("ziggurat_svg_text");
const text = @import("ziggurat_text_layout");
const outlines = @import("ziggurat_text_outlines");
const vector = @import("ziggurat_vector");
const Mode = @FieldType(svg.PrepareOptions, "compositing");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_image_objects() u32;
const source = "<svg viewBox='0 0 128 48'><text x='8' y='30' font-size='24' fill='rgba(64,128,192,0.5)'>Office A O</text></svg>";
const span_source = "<svg viewBox='0 0 128 48'><text x='8 52 96' y='30' font-size='24' fill='rgba(64,128,192,0.5)'>AV<tspan>ffi</tspan></text></svg>";
const clipped_source = "<svg viewBox='0 0 128 48'><defs><text id='t' x='8' y='30' font-size='24'>Office A O</text><clipPath id='c'><use href='#t'/></clipPath></defs><rect width='128' height='48' fill='rgba(64,128,192,0.5)' clip-path='url(#c)'/></svg>";
fn near(want: u8, got: u8) !void {
    if (@abs(@as(i32, want) - @as(i32, got)) > 1) return error.TextPixelMismatch;
}
fn pixelOracle(allocator: std.mem.Allocator, shaped_source: []const u8, svg_inputs: []const []const u8, verify_native: bool) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    const layout = try engine.layout(shaped_source, .{ .size = 24 });
    const shape = try outlines.fromLayout(layout, allocator, .{});
    const baseline = (try shape.stats()).first_baseline;
    try layout.close();
    try engine.close();
    defer shape.close() catch unreachable;
    for (svg_inputs) |input| for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const provider = try svg_text.Provider.create(allocator, std.Thread.getCurrentId(), .{});
        const document = try svg.Document.parse(allocator, input, .{});
        const width: u32 = @intFromFloat(128 * scale);
        const height: u32 = @intFromFloat(48 * scale);
        const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = width, .height = height, .compositing = mode, .text_provider = try provider.interface() });
        defer output.close() catch unreachable;
        try document.close();
        try provider.close();
        const coverage = try (try shape.path()).prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) }, .transform = .{ .xx = scale, .yy = scale, .x0 = 8 * scale, .y0 = (30 - baseline) * scale } });
        defer coverage.close() catch unreachable;
        const mask = (try coverage.view()).coverage;
        var visible: usize = 0;
        for (0..height) |y| for (0..width) |x| {
            const amount = mask.pixels[y * mask.stride + x];
            visible += @intFromBool(amount != 0);
            const alpha: f64 = @as(f64, @floatFromInt(amount)) / 255 * 128 / 255;
            const actual = output.pixels[(y * width + x) * 4 ..][0..4];
            try near(@intFromFloat(@round(192 * alpha)), actual[0]);
            try near(@intFromFloat(@round(128 * alpha)), actual[1]);
            try near(@intFromFloat(@round(64 * alpha)), actual[2]);
            try near(@intFromFloat(@round(255 * alpha)), actual[3]);
        };
        try std.testing.expect(visible > 0);
        try std.testing.expectEqual(@as(usize, 1), (try output.stats()).text_requests);
        if (verify_native) try nativeReplay(allocator, output, scale);
    };
}
fn objectBoundsOracle(allocator: std.mem.Allocator, positioned: bool) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    const Fragment = struct { utf8: []const u8, x: f64 };
    const fragments: []const Fragment = if (positioned) &.{ .{ .utf8 = "O", .x = 8 }, .{ .utf8 = "j", .x = 70 } } else &.{.{ .utf8 = "Oj", .x = 8 }};
    var union_bounds: ?vector.Bounds = null;
    for (fragments) |fragment| {
        const layout = try engine.layout(fragment.utf8, .{ .size = 24, .italic = true });
        defer layout.close() catch unreachable;
        const shape = try outlines.fromLayout(layout, allocator, .{ .include_cells = true });
        defer shape.close() catch unreachable;
        const baseline = (try shape.stats()).first_baseline;
        const cells = try shape.cells();
        try std.testing.expect(cells.len > 0);
        for (cells) |local| {
            var cell = local;
            cell.x += fragment.x;
            cell.y += 30 - baseline;
            if (union_bounds) |previous| {
                const x = @min(previous.x, cell.x);
                const y = @min(previous.y, cell.y);
                union_bounds = .{ .x = x, .y = y, .width = @max(previous.x + previous.width, cell.x + cell.width) - x, .height = @max(previous.y + previous.height, cell.y + cell.height) - y };
            } else union_bounds = cell;
        }
    }
    try engine.close();
    const bounds = union_bounds.?;
    const gradient = "<linearGradient id='g' x2='0' y2='1'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>";
    // Use an identical affine map for the independent bounds oracle. Expanding
    // only y endpoints changes floating-point evaluation at channel half ties.
    const gradient_user = try std.fmt.allocPrint(allocator, "<linearGradient id='g' gradientUnits='userSpaceOnUse' gradientTransform='matrix({d} 0 0 {d} {d} {d})' x2='0' y2='1'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>", .{ bounds.width, bounds.height, bounds.x, bounds.y });
    defer allocator.free(gradient_user);
    const clip = "<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='.5'/></clipPath>";
    const clip_user = try std.fmt.allocPrint(allocator, "<clipPath id='c'><rect x='{d}' y='{d}' width='{d}' height='{d}'/></clipPath>", .{ bounds.x, bounds.y, bounds.width, bounds.height * 0.5 });
    defer allocator.free(clip_user);
    const mask = "<mask id='m' maskUnits='objectBoundingBox' maskContentUnits='objectBoundingBox' x='0' y='0' width='1' height='1' mask-type='alpha'><rect width='.75' height='1' fill='white'/></mask>";
    const mask_user = try std.fmt.allocPrint(allocator, "<mask id='m' maskUnits='userSpaceOnUse' maskContentUnits='userSpaceOnUse' x='{d}' y='{d}' width='{d}' height='{d}' mask-type='alpha'><rect x='{d}' y='{d}' width='{d}' height='{d}' fill='white'/></mask>", .{ bounds.x, bounds.y, bounds.width, bounds.height, bounds.x, bounds.y, bounds.width * 0.75, bounds.height });
    defer allocator.free(mask_user);
    const cases = [_]struct { object: []const u8, user: []const u8, attributes: []const u8 }{
        .{ .object = gradient, .user = gradient_user, .attributes = "fill='url(#g)'" },
        .{ .object = clip, .user = clip_user, .attributes = "fill='blue' clip-path='url(#c)'" },
        .{ .object = mask, .user = mask_user, .attributes = "fill='blue' mask='url(#m)'" },
    };
    for (cases) |case| {
        const x_positions = if (positioned) "8 70" else "8";
        const object_source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><defs>{s}</defs><text x='{s}' y='30' font-size='24' font-style='italic' {s}>O<tspan>j</tspan></text></svg>", .{ case.object, x_positions, case.attributes });
        defer allocator.free(object_source);
        const user_source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><defs>{s}</defs><text x='{s}' y='30' font-size='24' font-style='italic' {s}>Oj</text></svg>", .{ case.user, x_positions, case.attributes });
        defer allocator.free(user_source);
        const object = try svg.Document.parse(allocator, object_source, .{});
        defer object.close() catch unreachable;
        const user = try svg.Document.parse(allocator, user_source, .{});
        defer user.close() catch unreachable;
        for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]f32{ 1, 1.5, 2 }) |scale| {
            const provider = try svg_text.Provider.create(allocator, std.Thread.getCurrentId(), .{});
            const options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = @intFromFloat(128 * scale), .height = @intFromFloat(48 * scale), .compositing = mode, .text_provider = try provider.interface() };
            const actual = try object.prepare(allocator, options);
            defer actual.close() catch unreachable;
            const expected = try user.prepare(allocator, options);
            defer expected.close() catch unreachable;
            try provider.close();
            try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
            try std.testing.expectEqual(@as(usize, if (positioned) 2 else 1), (try actual.stats()).text_requests);
            if (!positioned) try nativeReplay(allocator, actual, scale);
        };
    }
}
fn positionedOracle(allocator: std.mem.Allocator, actual_source: []const u8, oracle_source: []const u8, expected_requests: usize, replay_native: bool) !void {
    const actual_document = try svg.Document.parse(allocator, actual_source, .{});
    defer actual_document.close() catch unreachable;
    const oracle_document = try svg.Document.parse(allocator, oracle_source, .{});
    defer oracle_document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const provider = try svg_text.Provider.create(allocator, std.Thread.getCurrentId(), .{});
        defer provider.close() catch unreachable;
        const options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = @intFromFloat(128 * scale), .height = @intFromFloat(48 * scale), .compositing = mode, .text_provider = try provider.interface() };
        const actual = try actual_document.prepare(allocator, options);
        defer actual.close() catch unreachable;
        try std.testing.expectEqual(expected_requests, (try actual.stats()).text_requests);
        try std.testing.expectEqual(@as(u64, @intCast(expected_requests)), (try provider.stats()).requests);
        const expected = try oracle_document.prepare(allocator, options);
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        if (replay_native) try nativeReplay(allocator, actual, scale);
    };
}
fn spanOracles(allocator: std.mem.Allocator) !void {
    // These node boundaries deliberately split kerning, ligature, joining,
    // combining and emoji sequences. Each complete string must use one Layout.
    const cases = [_]struct { plain: []const u8, spans: []const u8, attributes: []const u8 = "" }{
        .{ .plain = "AV office", .spans = "A<tspan>V of<tspan>fi</tspan>ce</tspan>" },
        .{ .plain = "السّلام", .spans = "ال<tspan>س<tspan>ّ</tspan>لا</tspan>م", .attributes = "direction='rtl' text-anchor='end'" },
        .{ .plain = "é 👩‍💻", .spans = "e<tspan>́ 👩<tspan>‍</tspan>💻</tspan>" },
        .{ .plain = "A B C", .spans = "  A<tspan> \n B<tspan>\tC </tspan></tspan> " },
        .{ .plain = " A  B C ", .spans = "<tspan xml:space='preserve'> A <tspan> B</tspan> C </tspan>" },
    };
    for (cases) |case| {
        const actual = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><text x='8' y='30' font-size='24' fill='rgba(64,128,192,0.5)' {s}>{s}</text></svg>", .{ case.attributes, case.spans });
        defer allocator.free(actual);
        const expected = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><text x='8' y='30' font-size='24' fill='rgba(64,128,192,0.5)' xml:space='preserve' {s}>{s}</text></svg>", .{ case.attributes, case.plain });
        defer allocator.free(expected);
        try positionedOracle(allocator, actual, expected, 1, false);
    }
    try positionedOracle(allocator, span_source, "<svg viewBox='0 0 128 48'><g font-size='24' fill='rgba(64,128,192,0.5)'><text x='8' y='30'>A</text><text x='52' y='30'>V</text><text x='96' y='30'>ffi</text></g></svg>", 3, true);
    try positionedOracle(allocator, "<svg viewBox='0 0 128 48'><text x='8 52' y='30' font-size='24'>e<tspan>́</tspan></text></svg>", "<svg viewBox='0 0 128 48'><g font-size='24'><text x='8' y='30'>e</text><text x='52' y='30'>́</text></g></svg>", 2, false);
    try positionedOracle(allocator, "<svg viewBox='0 0 128 48'><text x='8 52' y='30' font-size='24'>😀<tspan>A</tspan></text></svg>", "<svg viewBox='0 0 128 48'><g font-size='24'><text x='8' y='30'>😀</text><text x='52' y='30'>A</text></g></svg>", 2, false);
    // Omitted x uses the preceding chunk's actual advance, including direction;
    // omitted y retains the current baseline rather than reverting to zero.
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    for ([_]bool{ false, true }) |rtl| {
        const layout = try engine.layout("AV", .{ .size = 24, .direction = if (rtl) .rtl else .ltr });
        defer layout.close() catch unreachable;
        const outline = try outlines.fromLayout(layout, allocator, .{});
        defer outline.close() catch unreachable;
        const advance = (try outline.stats()).advance;
        const first: f64 = if (rtl) 118 else 8;
        const next = first + (if (rtl) -advance else advance) + 3;
        const last: f64 = if (rtl) 20 else 72;
        const direction = if (rtl) "rtl" else "ltr";
        const actual = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><text x='{d}' y='20' font-size='24' direction='{s}'>A<tspan>V</tspan><tspan y='44' dx='3'>ffi</tspan><tspan x='{d}' dy='-10'>O</tspan></text></svg>", .{ first, direction, last });
        defer allocator.free(actual);
        const expected = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><g font-size='24' direction='{s}'><text x='{d}' y='20'>AV</text><text x='{d}' y='44'>ffi</text><text x='{d}' y='34'>O</text></g></svg>", .{ direction, first, next, last });
        defer allocator.free(expected);
        try positionedOracle(allocator, actual, expected, 3, false);
    }
}
fn paintOrderOracle(allocator: std.mem.Allocator) !void {
    const defs = "<defs><linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><clipPath id='c'><rect x='7.5' y='8.25' width='112' height='31'/></clipPath><mask id='m' mask-type='alpha'><rect width='128' height='48' fill='white' opacity='.75'/></mask></defs>";
    const open = "<svg viewBox='0 0 128 48'>" ++ defs ++ "<g fill='url(#g)' stroke='rgba(16,192,64,.75)' stroke-width='3' stroke-linejoin='round' opacity='.75' clip-path='url(#c)' mask='url(#m)' font-size='24'>";
    try positionedOracle(allocator, open ++ "<text x='8' y='30' paint-order='stroke'>AV of<tspan>fi</tspan>ce</text></g></svg>", open ++ "<text x='8' y='30' fill='none'>AV office</text><text x='8' y='30' stroke='none'>AV office</text></g></svg>", 1, true);
    try positionedOracle(allocator, open ++ "<text x='120' y='30' direction='rtl' paint-order='markers stroke'>ال<tspan>سّ</tspan>لام</text></g></svg>", open ++ "<text x='120' y='30' direction='rtl' fill='none'>السّلام</text><text x='120' y='30' direction='rtl' stroke='none'>السّلام</text></g></svg>", 1, false);
}
fn appendPaintOutline(allocator: std.mem.Allocator, data: *std.ArrayList(u8), commands: []const vector.Command, transform: vector.Transform, offset: vector.Point) !void {
    for (commands) |command| switch (command) {
        .move, .line => |point| {
            const p = transform.apply(point);
            try data.print(allocator, "{s}{d} {d}", .{ if (command == .move) "M" else "L", p.x + offset.x, p.y + offset.y });
        },
        .cubic => |cubic| {
            const p = transform.apply(cubic.first);
            const q = transform.apply(cubic.second);
            const r = transform.apply(cubic.end);
            try data.print(allocator, "C{d} {d} {d} {d} {d} {d}", .{ p.x + offset.x, p.y + offset.y, q.x + offset.x, q.y + offset.y, r.x + offset.x, r.y + offset.y });
        },
        .close => try data.appendSlice(allocator, "Z"),
        else => return error.UnexpectedSystemOutline,
    };
}
fn coloredPath(allocator: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8, blue: bool) !void {
    if (data.len != 0) try output.print(allocator, "<path fill='{s}' fill-opacity='{s}' d='{s}'/>", .{ if (blue) "blue" else "red", if (blue) ".5" else ".75", data });
}
fn paintedOracle(allocator: std.mem.Allocator) !void {
    try positionedOracle(allocator, "<svg viewBox='0 0 128 48'><text x='8' y='30' font-size='24' fill='red'><tspan fill='blue'>of<tspan>fi</tspan>ce</tspan></text></svg>", "<svg viewBox='0 0 128 48'><text x='8' y='30' font-size='24' fill='blue'>office</text></svg>", 1, false);
    const cases = [_]struct { plain: []const u8, markup: []const u8, boundary: usize, rtl: bool = false, require_accept: bool = false, attributes: []const u8 = "", dx: ?[]const f64 = null, dy: []const f64 = &.{}, rotation: []const f64 = &.{} }{
        .{ .plain = "AV office", .markup = "A<tspan fill='blue' fill-opacity='.5'>V of<tspan>fi</tspan>ce</tspan>", .boundary = 1 },
        .{ .plain = "السّلام", .markup = "ال<tspan fill='blue' fill-opacity='.5'>سّلام</tspan>", .boundary = "ال".len, .rtl = true },
        .{ .plain = "אבג", .markup = "א<tspan fill='blue' fill-opacity='.5'>בג</tspan>", .boundary = "א".len, .rtl = true, .require_accept = true },
        .{ .plain = "éX", .markup = "é<tspan fill='blue' fill-opacity='.5'>X</tspan>", .boundary = "é".len },
        .{ .plain = "éX", .markup = "e<tspan fill='blue' fill-opacity='.5'>́X</tspan>", .boundary = 1 },
        .{ .plain = "AVX", .markup = "A<tspan fill='blue' fill-opacity='.5'>VX</tspan>", .boundary = 1, .require_accept = true, .attributes = "dx='0 3 4' dy='0 1 -2' rotate='15 -20 30'", .dx = &.{ 0, 3, 4 }, .dy = &.{ 0, 1, -2 }, .rotation = &.{ 15, -20, 30 } },
        .{ .plain = "אבג", .markup = "א<tspan fill='blue' fill-opacity='.5'>בג</tspan>", .boundary = "א".len, .rtl = true, .require_accept = true, .attributes = "dx='0 3 4' dy='0 1 -2' rotate='10 -15 25'", .dx = &.{ 0, 3, 4 }, .dy = &.{ 0, 1, -2 }, .rotation = &.{ 10, -15, 25 } },
    };
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const defs = "<defs><clipPath id='c'><rect x='1.25' y='1.5' width='125.5' height='45'/></clipPath><mask id='m' maskUnits='userSpaceOnUse' x='0' y='0' width='128' height='48' mask-type='alpha'><rect width='128' height='48' fill='white' opacity='.75'/></mask></defs>";
    const group = "<g opacity='.625' clip-path='url(#c)' mask='url(#m)'>";
    var accepted: usize = 0;
    var accepted_rtl: usize = 0;
    var accepted_positioned: usize = 0;
    var rejected: usize = 0;
    for (cases, 0..) |case, case_index| {
        const layout = try engine.layout(case.plain, .{ .size = 24, .direction = if (case.rtl) .rtl else .ltr });
        defer layout.close() catch unreachable;
        const shape = try outlines.fromLayout(layout, allocator, .{ .include_mapping = true });
        defer shape.close() catch unreachable;
        const mapping = try shape.takeMapping();
        defer mapping.close() catch unreachable;
        const clusters = try mapping.clusters();
        const original_glyphs = try mapping.glyphs();
        const path = try mapping.path();
        const metrics = try shape.stats();
        var offset: vector.Point = .{ .x = if (case.rtl) 120 - metrics.advance else 8, .y = 30 - metrics.first_baseline };
        const transforms = try allocator.alloc(vector.Transform, clusters.len);
        defer allocator.free(transforms);
        @memset(transforms, .{});
        var supported = true;
        for (clusters) |cluster| {
            supported = supported and !(cluster.source.start < case.boundary and case.boundary < cluster.source.end) and cluster.glyphs.count != 0;
            for ([_]usize{ cluster.source.start, cluster.source.end }) |byte| {
                var grapheme = false;
                for (0..(try layout.graphemeCount()) + 1) |i| grapheme = grapheme or try layout.graphemeByte(i) == byte;
                supported = supported and grapheme;
            }
        }
        // This plain RTL fixture is a required positive oracle. A platform
        // cannot satisfy it by taking the explicit cluster-rejection branch.
        if (case.require_accept) try std.testing.expect(supported);
        if (case.dx) |deltas| {
            var minimum: f64 = std.math.inf(f64);
            var maximum: f64 = -std.math.inf(f64);
            for (clusters, transforms) |cluster, *transform| {
                var low: f64 = std.math.inf(f64);
                var high: f64 = -std.math.inf(f64);
                for (original_glyphs[cluster.glyphs.start..][0..cluster.glyphs.count]) |glyph| {
                    low = @min(low, @min(glyph.pen.x, glyph.pen.x + glyph.advance));
                    high = @max(high, @max(glyph.pen.x, glyph.pen.x + glyph.advance));
                }
                // Fixed fixtures have one scalar per cluster and zero initial
                // dx/dy. Read source ownership from the original native map,
                // never the SVG Plan or its computed poses.
                var byte: usize = 0;
                var scalar: usize = 0;
                var dx: f64 = 0;
                var dy: f64 = 0;
                while (byte <= cluster.source.start and scalar < deltas.len) : (scalar += 1) {
                    dx += deltas[scalar];
                    dy += case.dy[scalar];
                    if (byte == cluster.source.start) break;
                    byte += try std.unicode.utf8ByteSequenceLength(case.plain[byte]);
                }
                minimum = @min(minimum, low + dx);
                maximum = @max(maximum, high + dx);
                const pivot_x = if (case.rtl) high else low;
                const pivot_y = original_glyphs[cluster.glyphs.start].pen.y;
                const angle = case.rotation[scalar] * std.math.pi / 180;
                const cosine = @cos(angle);
                const sine = @sin(angle);
                transform.* = .{ .xx = cosine, .xy = -sine, .yx = sine, .yy = cosine, .x0 = pivot_x + dx - cosine * pivot_x + sine * pivot_y, .y0 = pivot_y + dy - sine * pivot_x - cosine * pivot_y };
            }
            offset.x = if (case.rtl) 120 - maximum else 8 - minimum;
        }
        var fills: std.ArrayList(u8) = .empty;
        defer fills.deinit(allocator);
        var current: std.ArrayList(u8) = .empty;
        defer current.deinit(allocator);
        var previous: ?bool = null;
        // Build the oracle from the native glyph array's paint order, not the
        // SVG consumer's cluster walk or source/geometry order. In RTL these
        // are independent orderings; transparent overlapping ink must retain
        // the provider's order through the neutral mapping copy.
        for (original_glyphs) |glyph| {
            const cluster = clusters[glyph.cluster];
            const blue = cluster.source.start >= case.boundary;
            if (previous) |color| if (blue != color) {
                try coloredPath(allocator, &fills, current.items, color);
                current.clearRetainingCapacity();
            };
            try appendPaintOutline(allocator, &current, path.commands[glyph.mapped_segments.start..][0..glyph.mapped_segments.count], transforms[glyph.cluster], offset);
            previous = blue;
        }
        if (previous) |color| try coloredPath(allocator, &fills, current.items, color);
        var whole: std.ArrayList(u8) = .empty;
        defer whole.deinit(allocator);
        for (original_glyphs) |glyph| try appendPaintOutline(allocator, &whole, path.commands[glyph.mapped_segments.start..][0..glyph.mapped_segments.count], transforms[glyph.cluster], offset);
        const stroke = try std.fmt.allocPrint(allocator, "<path fill='none' stroke='rgba(16,192,64,.75)' stroke-width='1.5' stroke-linejoin='round' d='{s}'/>", .{whole.items});
        defer allocator.free(stroke);
        for ([_]bool{ false, true }) |stroke_first| {
            const actual_source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'>" ++ defs ++ "<text x='{d}' y='30' font-size='24' direction='{s}' fill='red' fill-opacity='.75' stroke='rgba(16,192,64,.75)' stroke-width='1.5' stroke-linejoin='round' opacity='.625' clip-path='url(#c)' mask='url(#m)' paint-order='{s}' {s}>{s}</text></svg>", .{ @as(u32, if (case.rtl) 120 else 8), if (case.rtl) "rtl" else "ltr", if (stroke_first) "stroke" else "normal", case.attributes, case.markup });
            defer allocator.free(actual_source);
            const actual_document = try svg.Document.parse(allocator, actual_source, .{});
            defer actual_document.close() catch unreachable;
            const expected_source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'>" ++ defs ++ group ++ "{s}{s}</g></svg>", .{ if (stroke_first) stroke else fills.items, if (stroke_first) fills.items else stroke });
            defer allocator.free(expected_source);
            const expected_document = try svg.Document.parse(allocator, expected_source, .{});
            defer expected_document.close() catch unreachable;
            for ([_]Mode{ .pixel, .sample_color }) |mode| for ([_]f32{ 1, 1.5, 2 }) |scale| {
                const provider = try svg_text.Provider.create(allocator, std.Thread.getCurrentId(), .{});
                defer provider.close() catch unreachable;
                const options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = @intFromFloat(128 * scale), .height = @intFromFloat(48 * scale), .compositing = mode, .text_provider = try provider.interface() };
                if (supported) {
                    const actual = try actual_document.prepare(allocator, options);
                    defer actual.close() catch unreachable;
                    const stats = try actual.stats();
                    try std.testing.expectEqual(@as(usize, 1), stats.text_requests);
                    try std.testing.expectEqual(@as(usize, 1), stats.text_mapping_requests);
                    try std.testing.expectEqual(@as(u64, 1), (try provider.stats()).requests);
                    const expected = try expected_document.prepare(allocator, options);
                    defer expected.close() catch unreachable;
                    try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
                    if ((case_index == 0 or case.dx != null) and !stroke_first) try nativeReplay(allocator, actual, scale);
                } else {
                    const result = actual_document.prepare(allocator, options);
                    if (result) |unexpected| {
                        try unexpected.close();
                        return error.ExpectedTextPaintClusterRejection;
                    } else |err| switch (err) {
                        error.UnsupportedTextPaintCluster, error.UnsupportedTextPositionCluster => {},
                        else => return err,
                    }
                }
            };
        }
        if (supported) {
            accepted += 1;
            if (case.rtl) accepted_rtl += 1;
            if (case.dx != null) accepted_positioned += 1;
        } else rejected += 1;
    }
    try std.testing.expect(accepted >= 2 and rejected >= 1);
    try std.testing.expect(accepted_rtl >= 1);
    try std.testing.expectEqual(@as(usize, 2), accepted_positioned);
    std.debug.print("SVG text fill oracle: {d} accepted ({d} RTL, {d} positioned), {d} explicit cluster rejection, original Layout/common stroke/two paint orders\n", .{ accepted, accepted_rtl, accepted_positioned, rejected });
}
fn paintedSpacingOracle(allocator: std.mem.Allocator) !void {
    const Case = struct { rtl: bool = false, length: f64 = 0, stretch: ?f64 = null, anchor: svg.text.Anchor = .start, delta: f64 = 0, dy: f64 = 0, rotation: [2]f64 = .{ 0, 0 }, explicit: bool = false };
    const cases = [_]Case{
        .{ .length = 48 },
        .{ .rtl = true, .length = 48, .explicit = true },
        .{ .length = 8, .anchor = .middle, .delta = 3, .dy = 1, .rotation = .{ 15, -20 } },
        .{ .rtl = true, .length = 8, .anchor = .middle, .delta = 3, .dy = 1, .rotation = .{ 10, -15 }, .explicit = true },
        .{ .length = 0, .anchor = .end },
        .{ .rtl = true, .length = 0, .anchor = .end },
        .{ .stretch = 2 },
        .{ .rtl = true, .stretch = 2 },
        .{ .stretch = 0.5, .anchor = .middle },
        .{ .rtl = true, .stretch = 0.5, .anchor = .middle },
        .{ .stretch = 0, .anchor = .end },
        .{ .rtl = true, .stretch = 0, .anchor = .end },
    };
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const defs = "<defs><clipPath id='c'><rect x='1.25' y='1.5' width='125.5' height='45'/></clipPath><mask id='m' maskUnits='userSpaceOnUse' x='0' y='0' width='128' height='48' mask-type='alpha'><rect width='128' height='48' fill='white' opacity='.75'/></mask></defs>";
    for (cases, 0..) |case, ci| {
        const plain = if (case.rtl) "אב" else "AV";
        const markup = if (case.rtl) "א<tspan fill='blue' fill-opacity='.5'>ב</tspan>" else "A<tspan fill='blue' fill-opacity='.5'>V</tspan>";
        const layout = try engine.layout(plain, .{ .size = 24, .direction = if (case.rtl) .rtl else .ltr });
        defer layout.close() catch unreachable;
        const shape = try outlines.fromLayout(layout, allocator, .{ .include_mapping = true });
        defer shape.close() catch unreachable;
        const mapping = try shape.takeMapping();
        defer mapping.close() catch unreachable;
        const clusters = try mapping.clusters();
        const glyphs = try mapping.glyphs();
        const path = try mapping.path();
        const metrics = try shape.stats();
        // These two-letter fixtures must be accepted, including real RTL.
        // A single gap has the exact endpoint displacement: no spacing loop,
        // source sorting, SVG Plan or text_adjust helper defines this oracle.
        try std.testing.expectEqual(@as(usize, 2), clusters.len);
        try std.testing.expectEqual(@as(usize, 2), glyphs.len);
        var low: [2]f64 = undefined;
        var high: [2]f64 = undefined;
        var ordinal: [2]usize = undefined;
        var transforms: [2]vector.Transform = undefined;
        for (clusters, 0..) |cluster, i| {
            try std.testing.expectEqual(@as(usize, 1), cluster.glyphs.count);
            try std.testing.expectEqual(@as(u8, if (case.rtl) 1 else 0), cluster.bidi_level & 1);
            const glyph = glyphs[cluster.glyphs.start];
            ordinal[i] = if (cluster.source.start == 0) 0 else 1;
            low[i] = @min(glyph.pen.x, glyph.pen.x + glyph.advance) + if (ordinal[i] == 0) @as(f64, 0) else case.delta;
            high[i] = @max(glyph.pen.x, glyph.pen.x + glyph.advance) + if (ordinal[i] == 0) @as(f64, 0) else case.delta;
        }
        try std.testing.expect(ordinal[0] != ordinal[1]);
        const natural = @max(high[0], high[1]) - @min(low[0], low[1]);
        const last_shift = (case.length - natural) * @as(f64, if (case.rtl) -1 else 1);
        for (0..2) |i| if (ordinal[i] == 1) {
            low[i] += last_shift;
            high[i] += last_shift;
        };
        const minimum = @min(low[0], low[1]);
        const maximum = @max(high[0], high[1]);
        const reference = switch (case.anchor) {
            .start => if (case.rtl) maximum else minimum,
            .middle => (minimum + maximum) / 2,
            .end => if (case.rtl) minimum else maximum,
        };
        var offset: vector.Point = .{ .x = 64 - reference, .y = 30 - metrics.first_baseline };
        for (clusters, 0..) |cluster, i| {
            const glyph = glyphs[cluster.glyphs.start];
            // The native pen may be the left endpoint even in an RTL run.
            // Direction selects the alignment endpoint of its full advance.
            const pivot: vector.Point = .{ .x = if (case.rtl) @max(glyph.pen.x, glyph.pen.x + glyph.advance) else @min(glyph.pen.x, glyph.pen.x + glyph.advance), .y = glyph.pen.y };
            const angle = case.rotation[ordinal[i]] * std.math.pi / 180;
            const cosine = @cos(angle);
            const sine = @sin(angle);
            const dx = if (ordinal[i] == 0) @as(f64, 0) else case.delta + last_shift;
            const dy = if (ordinal[i] == 0) @as(f64, 0) else case.dy;
            transforms[i] = .{ .xx = cosine, .xy = -sine, .yx = sine, .yy = cosine, .x0 = pivot.x + dx - cosine * pivot.x + sine * pivot.y, .y0 = pivot.y + dy - sine * pivot.x - cosine * pivot.y };
        }
        // An independently prescribed 2x/.5x/0x horizontal transform. Its
        // target is derived from the original native advance, not SVG's
        // placement or a second shaped string. All glyphs use the same map.
        const desired = if (case.stretch) |ratio| metrics.advance * ratio else case.length;
        if (case.stretch) |ratio| {
            @memset(&transforms, .{ .xx = ratio });
            offset.x = 64 - switch (case.anchor) {
                .start => if (case.rtl) desired else 0,
                .middle => desired / 2,
                .end => if (case.rtl) 0 else desired,
            };
        }
        var fills: std.ArrayList(u8) = .empty;
        defer fills.deinit(allocator);
        var whole: std.ArrayList(u8) = .empty;
        defer whole.deinit(allocator);
        for (glyphs) |glyph| {
            var data: std.ArrayList(u8) = .empty;
            defer data.deinit(allocator);
            try appendPaintOutline(allocator, &data, path.commands[glyph.mapped_segments.start..][0..glyph.mapped_segments.count], transforms[glyph.cluster], offset);
            try coloredPath(allocator, &fills, data.items, ordinal[glyph.cluster] == 1);
            try whole.appendSlice(allocator, data.items);
        }
        const stroke = try std.fmt.allocPrint(allocator, "<path fill='none' stroke='rgba(16,192,64,.75)' stroke-width='1.5' d='{s}'/>", .{whole.items});
        defer allocator.free(stroke);
        for ([_]bool{ false, true }) |stroke_first| {
            const actual = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'>" ++ defs ++ "<text x='64' y='30' font-size='24' direction='{s}' text-anchor='{s}' textLength='{d}' {s} dx='0 {d}' dy='0 {d}' rotate='{d} {d}' fill='red' fill-opacity='.75' stroke='rgba(16,192,64,.75)' stroke-width='1.5' opacity='.625' clip-path='url(#c)' mask='url(#m)' paint-order='{s}'>{s}</text></svg>", .{ if (case.rtl) "rtl" else "ltr", @tagName(case.anchor), desired, if (case.stretch != null) "lengthAdjust='spacingAndGlyphs'" else if (case.explicit) "lengthAdjust='spacing'" else "", case.delta, case.dy, case.rotation[0], case.rotation[1], if (stroke_first) "stroke" else "normal", markup });
            defer allocator.free(actual);
            const expected = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'>" ++ defs ++ "<g opacity='.625' clip-path='url(#c)' mask='url(#m)'>{s}{s}</g></svg>", .{ if (stroke_first) stroke else fills.items, if (stroke_first) fills.items else stroke });
            defer allocator.free(expected);
            positionedOracle(allocator, actual, expected, 1, (ci < 2 or ci == 6 or ci == 7) and !stroke_first) catch |err| {
                std.debug.print("mixed length case={d} rtl={} length={d} stretch={any} anchor={s} stroke-first={} low={any} high={any} offset={any} transforms={any}\nactual: {s}\noracle: {s}\n", .{ ci, case.rtl, desired, case.stretch, @tagName(case.anchor), stroke_first, low, high, offset, transforms, actual, expected });
                return err;
            };
        }
    }
    std.debug.print("SVG mixed spacing oracle: 6 required accepted (3 RTL), one-gap native endpoints/provider glyph order, dx/dy/rotate, zero/overlap, two paint orders/3DPI\n", .{});
    std.debug.print("SVG mixed stretch oracle: 6 required accepted (3 RTL), prescribed 2x/.5x/0x original Layout/provider glyph order, whole stroke, two paint orders/3DPI\n", .{});
}

fn lengthOracle(allocator: std.mem.Allocator) !void {
    const cases = [_]struct { plain: []const u8, spans: []const u8, rtl: bool = false }{
        .{ .plain = "AV office", .spans = "A<tspan>V of<tspan>fi</tspan>ce</tspan>" },
        .{ .plain = "السّلام", .spans = "ال<tspan>سّ</tspan>لام", .rtl = true },
        .{ .plain = "é 👩‍💻", .spans = "e<tspan>́ 👩‍</tspan>💻" },
    };
    const open = "<svg viewBox='0 0 128 48'><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x2='128'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><clipPath id='c'><rect x='1.25' y='1.5' width='125.5' height='45'/></clipPath><mask id='m' maskUnits='userSpaceOnUse' maskContentUnits='userSpaceOnUse' x='0' y='0' width='128' height='48' mask-type='alpha'><rect width='128' height='48' fill='rgba(255,255,255,0.75)'/></mask></defs><g font-size='24' opacity='.625' fill='url(#g)' stroke='rgba(20,80,120,0.75)' stroke-width='1.5' paint-order='stroke' clip-path='url(#c)' mask='url(#m)'>";
    for (cases, 0..) |case, case_index| {
        const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        const layout = try engine.layout(case.plain, .{ .size = 24, .direction = if (case.rtl) .rtl else .ltr });
        const shape = try outlines.fromLayout(layout, allocator, .{});
        defer shape.close() catch unreachable;
        const metrics = try shape.stats();
        try layout.close();
        try engine.close();
        // Build an independent SVG path from the original system contours.
        // Stroke width remains in user units after glyph stretching.
        for ([_]f64{ 48, 96 }) |desired| {
            const stretch = desired / metrics.advance;
            const x_offset = 64 - desired / 2;
            const y_offset = 30 - metrics.first_baseline;
            var path: std.ArrayList(u8) = .empty;
            defer path.deinit(allocator);
            for ((try shape.path()).commands) |command| switch (command) {
                .move, .line => |point| try path.print(allocator, "{s}{d} {d}", .{ if (command == .move) "M" else "L", point.x * stretch + x_offset, point.y + y_offset }),
                .cubic => |curve| try path.print(allocator, "C{d} {d} {d} {d} {d} {d}", .{ curve.first.x * stretch + x_offset, curve.first.y + y_offset, curve.second.x * stretch + x_offset, curve.second.y + y_offset, curve.end.x * stretch + x_offset, curve.end.y + y_offset }),
                .close => try path.appendSlice(allocator, "Z"),
                else => return error.UnexpectedSystemOutline,
            };
            const actual = try std.fmt.allocPrint(allocator, open ++ "<text x='64' y='30' text-anchor='middle' textLength='{d}' lengthAdjust='spacingAndGlyphs' direction='{s}'>{s}</text></g></svg>", .{ desired, if (case.rtl) "rtl" else "ltr", case.spans });
            defer allocator.free(actual);
            const expected = try std.fmt.allocPrint(allocator, open ++ "<path d='{s}'/></g></svg>", .{path.items});
            defer allocator.free(expected);
            try positionedOracle(allocator, actual, expected, 1, case_index == 0);
        }
    }
}

fn textPathOracle(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var accepted: usize = 0;
    for ([_]bool{ false, true }) |rtl| {
        const plain = if (rtl) "אב" else "AV";
        const markup = if (rtl) "א<tspan fill='blue' fill-opacity='.5'>ב</tspan>" else "A<tspan fill='blue' fill-opacity='.5'>V</tspan>";
        const layout = try engine.layout(plain, .{ .size = 24, .direction = if (rtl) .rtl else .ltr });
        defer layout.close() catch unreachable;
        const shape = try outlines.fromLayout(layout, allocator, .{ .include_mapping = true });
        defer shape.close() catch unreachable;
        const mapping = try shape.takeMapping();
        defer mapping.close() catch unreachable;
        const clusters = try mapping.clusters();
        const glyphs = try mapping.glyphs();
        const path = try mapping.path();
        const metrics = try shape.stats();
        try std.testing.expectEqual(@as(usize, 2), clusters.len);
        try std.testing.expectEqual(@as(usize, 2), glyphs.len);
        var low: [2]f64 = undefined;
        var high: [2]f64 = undefined;
        for (glyphs, 0..) |glyph, i| {
            try std.testing.expectEqual(@as(usize, 1), clusters[glyph.cluster].glyphs.count);
            low[i] = @min(glyph.pen.x, glyph.pen.x + glyph.advance);
            high[i] = @max(glyph.pen.x, glyph.pen.x + glyph.advance);
        }
        const left = @min(low[0], low[1]);
        const right = @max(high[0], high[1]);
        const corner = (if (low[0] < low[1]) high[0] else high[1]) - left;
        const bend = corner * 0.4;
        for ([_]bool{ false, true }) |extended| {
            const initial_shift = if (extended) -corner * 0.25 else 0;
            var transforms: [2]vector.Transform = undefined;
            // Independent two-piece oracle. No SVG Plan, Route, pose helper or
            // source sorting: the raw native glyph intervals define its inputs.
            // The first spatial glyph straddles the elbow, so the exact chord
            // direction differs from either of the two segment tangents.
            for (glyphs, 0..) |glyph, i| {
                const start = low[i] - left + initial_shift;
                const end = high[i] - left + initial_shift;
                const middle = (start + end) / 2;
                const first: vector.Point = if (start <= bend) .{ .x = 24 + start, .y = 16 } else .{ .x = 24 + bend, .y = 16 + start - bend };
                const last: vector.Point = if (end <= bend) .{ .x = 24 + end, .y = 16 } else .{ .x = 24 + bend, .y = 16 + end - bend };
                const mid: vector.Point = if (middle <= bend) .{ .x = 24 + middle, .y = 16 } else .{ .x = 24 + bend, .y = 16 + middle - bend };
                const dx = last.x - first.x;
                const dy = last.y - first.y;
                const norm = std.math.hypot(dx, dy);
                const cosine = dx / norm;
                const sine = dy / norm;
                const raw_middle = (glyph.pen.x + glyph.pen.x + glyph.advance) / 2;
                transforms[glyph.cluster] = .{ .xx = cosine, .xy = -sine, .yx = sine, .yy = cosine, .x0 = mid.x - cosine * raw_middle + sine * metrics.first_baseline, .y0 = mid.y - sine * raw_middle - cosine * metrics.first_baseline };
            }
            var fills: std.ArrayList(u8) = .empty;
            defer fills.deinit(allocator);
            var whole: std.ArrayList(u8) = .empty;
            defer whole.deinit(allocator);
            for (glyphs) |glyph| {
                var data: std.ArrayList(u8) = .empty;
                defer data.deinit(allocator);
                try appendPaintOutline(allocator, &data, path.commands[glyph.mapped_segments.start..][0..glyph.mapped_segments.count], transforms[glyph.cluster], .{});
                try coloredPath(allocator, &fills, data.items, clusters[glyph.cluster].source.start != 0);
                try whole.appendSlice(allocator, data.items);
            }
            const stroke = try std.fmt.allocPrint(allocator, "<path fill='none' stroke='rgba(16,192,64,.75)' stroke-width='1.5' d='{s}'/>", .{whole.items});
            defer allocator.free(stroke);
            var x0: f64 = std.math.inf(f64);
            var y0: f64 = std.math.inf(f64);
            var x1: f64 = -std.math.inf(f64);
            var y1: f64 = -std.math.inf(f64);
            for (glyphs) |glyph| {
                const cell = glyph.cell;
                for ([_]vector.Point{ .{ .x = cell.x, .y = cell.y }, .{ .x = cell.x + cell.width, .y = cell.y }, .{ .x = cell.x, .y = cell.y + cell.height }, .{ .x = cell.x + cell.width, .y = cell.y + cell.height } }) |point| {
                    const placed = transforms[glyph.cluster].apply(point);
                    x0 = @min(x0, placed.x);
                    y0 = @min(y0, placed.y);
                    x1 = @max(x1, placed.x);
                    y1 = @max(y1, placed.y);
                }
            }
            const cell_actual = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><defs><path id='p' transform='translate(24 16)' d='M0 0H{d}V120'/><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='.6' height='1'/></clipPath></defs><g transform='matrix(1 0 .25 1 0 0)'><text font-size='24' direction='{s}' fill='red' fill-opacity='.75' clip-path='url(#c)'><textPath href='#p' startOffset='{d}'>{s}</textPath></text></g></svg>", .{ bend, if (rtl) "rtl" else "ltr", initial_shift + if (rtl) right - left else 0, markup });
            defer allocator.free(cell_actual);
            const cell_expected = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><defs><clipPath id='c'><rect x='{d}' y='{d}' width='{d}' height='{d}'/></clipPath></defs><g transform='matrix(1 0 .25 1 0 0)' clip-path='url(#c)'>{s}</g></svg>", .{ x0, y0, (x1 - x0) * 0.6, y1 - y0, fills.items });
            defer allocator.free(cell_expected);
            try positionedOracle(allocator, cell_actual, cell_expected, 1, false);
            const defs = "<defs><clipPath id='c'><rect x='1.25' y='1.5' width='125.5' height='45'/></clipPath><mask id='m' maskUnits='userSpaceOnUse' x='0' y='0' width='128' height='48' mask-type='alpha'><rect width='128' height='48' fill='white' opacity='.75'/></mask></defs>";
            for ([_]svg.text.Anchor{ .start, .middle, .end }) |anchor| {
                const offset = switch (anchor) {
                    .start => if (rtl) right - left else 0,
                    .middle => (right - left) / 2,
                    .end => if (rtl) 0 else right - left,
                };
                for ([_]bool{ false, true }) |stroke_first| {
                    const actual_source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'>" ++ defs ++ "<g transform='translate(1000 2000)'><defs><path id='route' transform='translate(24 16)' d='M0 0H{d}V120'/></defs></g><text font-size='24' direction='{s}' text-anchor='{s}' fill='red' fill-opacity='.75' stroke='rgba(16,192,64,.75)' stroke-width='1.5' opacity='.625' clip-path='url(#c)' mask='url(#m)' paint-order='{s}'><textPath href='#route' startOffset='{d}'>{s}</textPath></text></svg>", .{ bend, if (rtl) "rtl" else "ltr", @tagName(anchor), if (stroke_first) "stroke" else "normal", offset + initial_shift, markup });
                    defer allocator.free(actual_source);
                    const expected_source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'>" ++ defs ++ "<g opacity='.625' clip-path='url(#c)' mask='url(#m)'>{s}{s}</g></svg>", .{ if (stroke_first) stroke else fills.items, if (stroke_first) fills.items else stroke });
                    defer allocator.free(expected_source);
                    try positionedOracle(allocator, actual_source, expected_source, 1, anchor == .start and !stroke_first);
                    if (anchor == .start and !stroke_first and !extended) {
                        const document = try svg.Document.parse(allocator, actual_source, .{});
                        defer document.close() catch unreachable;
                        const provider = try svg_text.Provider.create(allocator, std.Thread.getCurrentId(), .{});
                        defer provider.close() catch unreachable;
                        for ([_]Mode{ .pixel, .sample_color }) |mode| {
                            try reentry(allocator, document, provider, mode);
                            try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{ document, provider, mode });
                        }
                    }
                }
                accepted += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 12), accepted);
    std.debug.print("SVG textPath oracle: 12 required accepted (6 RTL), original Layout/glyph order, exact elbow chord/endpoint extension/cell bbox, target-local transform, whole stroke/two paint orders/3DPI, OOM/reentry\n", .{});
}
fn mappedOracle(allocator: std.mem.Allocator) !void {
    const Case = struct { plain: []const u8, markup: []const u8, attributes: []const u8, dx: []const f64, dy: []const f64, rotation: []const f64, rtl: bool = false, anchor: svg.text.Anchor = .start, spacing: ?f64 = null };
    const cases = [_]Case{
        .{ .plain = "AV", .markup = "A<tspan>V</tspan>", .attributes = "dx='0 4' dy='0 2' rotate='0 25'", .dx = &.{ 0, 4 }, .dy = &.{ 0, 2 }, .rotation = &.{ 0, 25 } },
        .{ .plain = "ffiX", .markup = "f<tspan>fi</tspan>X", .attributes = "dx='0 2 3 4' rotate='0 35'", .dx = &.{ 0, 2, 3, 4 }, .dy = &.{ 0, 0, 0, 0 }, .rotation = &.{ 0, 35, 35, 35 }, .anchor = .middle },
        .{ .plain = "éX", .markup = "e<tspan>́</tspan>X", .attributes = "dx='0 3 4' rotate='0 25'", .dx = &.{ 0, 3, 4 }, .dy = &.{ 0, 0, 0 }, .rotation = &.{ 0, 25, 25 } },
        .{ .plain = "سلام", .markup = "س<tspan>لام</tspan>", .attributes = "dx='0 2 3 4' rotate='10 25'", .dx = &.{ 0, 2, 3, 4 }, .dy = &.{ 0, 0, 0, 0 }, .rotation = &.{ 10, 25, 25, 25 }, .rtl = true },
        .{ .plain = "é", .markup = "e<tspan>́</tspan>", .attributes = "dx='0 91' dy='0 71' rotate='15 45'", .dx = &.{ 0, 91 }, .dy = &.{ 0, 71 }, .rotation = &.{ 15, 45 } },
        .{ .plain = "👩‍💻X", .markup = "👩<tspan>‍💻</tspan>X", .attributes = "dx='0 2 3 4' rotate='0 25'", .dx = &.{ 0, 2, 3, 4 }, .dy = &.{ 0, 0, 0, 0 }, .rotation = &.{ 0, 25, 25, 25 } },
        .{ .plain = "AV", .markup = "A<tspan>V</tspan>", .attributes = "textLength='96'", .dx = &.{ 0, 0 }, .dy = &.{ 0, 0 }, .rotation = &.{0}, .spacing = 96, .anchor = .middle },
        .{ .plain = "ffiX", .markup = "f<tspan>fi</tspan>X", .attributes = "textLength='96' lengthAdjust='spacing'", .dx = &.{ 0, 0, 0, 0 }, .dy = &.{ 0, 0, 0, 0 }, .rotation = &.{0}, .spacing = 96, .anchor = .middle },
        .{ .plain = "éX", .markup = "e<tspan>́</tspan>X", .attributes = "textLength='48'", .dx = &.{ 0, 0, 0 }, .dy = &.{ 0, 0, 0 }, .rotation = &.{0}, .spacing = 48 },
        .{ .plain = "سلام", .markup = "س<tspan>لام</tspan>", .attributes = "textLength='96'", .dx = &.{ 0, 0, 0, 0 }, .dy = &.{ 0, 0, 0, 0 }, .rotation = &.{0}, .spacing = 96, .rtl = true },
        .{ .plain = "AV", .markup = "A<tspan>V</tspan>", .attributes = "textLength='72' dx='3 4' dy='2 1' rotate='15 25'", .dx = &.{ 3, 4 }, .dy = &.{ 2, 1 }, .rotation = &.{ 15, 25 }, .spacing = 72, .anchor = .end },
        .{ .plain = "سلام", .markup = "س<tspan>لام</tspan>", .attributes = "textLength='96' dx='3 2 3 4' rotate='10 25'", .dx = &.{ 3, 2, 3, 4 }, .dy = &.{ 0, 0, 0, 0 }, .rotation = &.{ 10, 25, 25, 25 }, .spacing = 96, .anchor = .middle, .rtl = true },
        .{ .plain = "AV", .markup = "A<tspan>V</tspan>", .attributes = "textLength='8'", .dx = &.{ 0, 0 }, .dy = &.{ 0, 0 }, .rotation = &.{0}, .spacing = 8, .anchor = .middle },
    };
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var accepted: usize = 0;
    var rejected: usize = 0;
    for (cases, 0..) |case, case_index| {
        const layout = try engine.layout(case.plain, .{ .size = 24, .direction = if (case.rtl) .rtl else .ltr });
        defer layout.close() catch unreachable;
        const shape = try outlines.fromLayout(layout, allocator, .{ .include_mapping = true });
        defer shape.close() catch unreachable;
        const mapping = try shape.takeMapping();
        defer mapping.close() catch unreachable;
        const glyphs = try mapping.glyphs();
        const clusters = try mapping.clusters();
        const source_path = try mapping.path();
        const baseline = (try shape.stats()).first_baseline;
        const transforms = try allocator.alloc(vector.Transform, clusters.len);
        defer allocator.free(transforms);
        const relative_dx = try allocator.alloc(f64, clusters.len);
        defer allocator.free(relative_dx);
        var minimum: f64 = std.math.inf(f64);
        var maximum: f64 = -std.math.inf(f64);
        var supported = true;
        for (clusters, transforms, relative_dx) |cluster, *transform, *saved_dx| {
            var boundary_start = false;
            var boundary_end = false;
            for (0..(try layout.graphemeCount()) + 1) |gi| {
                boundary_start = boundary_start or try layout.graphemeByte(gi) == cluster.source.start;
                boundary_end = boundary_end or try layout.graphemeByte(gi) == cluster.source.end;
            }
            supported = supported and boundary_start and boundary_end and cluster.glyphs.count != 0;
            var pen_low: f64 = std.math.inf(f64);
            var pen_high: f64 = -std.math.inf(f64);
            for (glyphs[cluster.glyphs.start..][0..cluster.glyphs.count]) |glyph| {
                pen_low = @min(pen_low, @min(glyph.pen.x, glyph.pen.x + glyph.advance));
                pen_high = @max(pen_high, @max(glyph.pen.x, glyph.pen.x + glyph.advance));
            }
            var byte: usize = 0;
            var scalar: usize = 0;
            var dx: f64 = 0;
            var dy: f64 = 0;
            while (byte <= cluster.source.start and scalar < case.dx.len) : (scalar += 1) {
                dx += case.dx[scalar];
                dy += case.dy[scalar];
                if (byte == cluster.source.start) break;
                byte += try std.unicode.utf8ByteSequenceLength(case.plain[byte]);
            }
            // The first scalar's dx is a common chunk origin shift. Keep it
            // outside the advance interval used for directional anchoring.
            dx -= case.dx[0];
            saved_dx.* = dx;
            minimum = @min(minimum, pen_low + dx);
            maximum = @max(maximum, pen_high + dx);
            const pivot_x = if (case.rtl) pen_high else pen_low;
            const pivot_y = if (cluster.glyphs.count == 0) baseline else glyphs[cluster.glyphs.start].pen.y;
            const radians = case.rotation[@min(scalar, case.rotation.len - 1)] * std.math.pi / 180;
            const cosine = @cos(radians);
            const sine = @sin(radians);
            transform.* = .{ .xx = cosine, .xy = -sine, .yx = sine, .yy = cosine, .x0 = pivot_x + dx - cosine * pivot_x + sine * pivot_y, .y0 = pivot_y + dy - sine * pivot_x - cosine * pivot_y };
        }
        if (case.spacing) |desired| {
            try std.testing.expect(clusters.len >= 2);
            const change = (desired - (maximum - minimum)) * @as(f64, if (case.rtl) -1 else 1);
            minimum = std.math.inf(f64);
            maximum = -std.math.inf(f64);
            for (clusters, transforms, relative_dx) |cluster, *transform, dx| {
                var logical_before: usize = 0;
                for (clusters) |other| if (other.source.start < cluster.source.start) {
                    logical_before += 1;
                };
                const shift = change / @as(f64, @floatFromInt(clusters.len - 1)) * @as(f64, @floatFromInt(logical_before));
                transform.x0 += shift;
                for (glyphs[cluster.glyphs.start..][0..cluster.glyphs.count]) |glyph| {
                    minimum = @min(minimum, @min(glyph.pen.x, glyph.pen.x + glyph.advance) + dx + shift);
                    maximum = @max(maximum, @max(glyph.pen.x, glyph.pen.x + glyph.advance) + dx + shift);
                }
            }
        }
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(allocator);
        for (clusters, transforms) |cluster, transform| for (source_path.commands[cluster.mapped_segments.start..][0..cluster.mapped_segments.count]) |command| switch (command) {
            .move, .line => |point| {
                const p = transform.apply(point);
                try path.print(allocator, "{s}{d} {d}", .{ if (command == .move) "M" else "L", p.x, p.y });
            },
            .cubic => |curve| {
                const p = transform.apply(curve.first);
                const q = transform.apply(curve.second);
                const r = transform.apply(curve.end);
                try path.print(allocator, "C{d} {d} {d} {d} {d} {d}", .{ p.x, p.y, q.x, q.y, r.x, r.y });
            },
            .close => try path.appendSlice(allocator, "Z"),
            else => return error.UnexpectedSystemOutline,
        };
        const reference = switch (case.anchor) {
            .middle => (minimum + maximum) / 2,
            .start => if (case.rtl) maximum else minimum,
            .end => if (case.rtl) minimum else maximum,
        };
        const actual = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><text x='64' y='30' font-size='24' direction='{s}' text-anchor='{s}' {s}>{s}</text></svg>", .{ if (case.rtl) "rtl" else "ltr", @tagName(case.anchor), case.attributes, case.markup });
        defer allocator.free(actual);
        const expected = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><path transform='translate({d} {d})' d='{s}'/></svg>", .{ 64 + case.dx[0] - reference, 30 - baseline, path.items });
        defer allocator.free(expected);
        if (supported) {
            try positionedOracle(allocator, actual, expected, 1, case_index == 0 or case.spacing != null);
            accepted += 1;
        } else {
            const document = try svg.Document.parse(allocator, actual, .{});
            defer document.close() catch unreachable;
            const provider = try svg_text.Provider.create(allocator, std.Thread.getCurrentId(), .{});
            defer provider.close() catch unreachable;
            for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.expectError(error.UnsupportedTextPositionCluster, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 128, .height = 48, .compositing = mode, .text_provider = try provider.interface() }));
            rejected += 1;
        }
    }
    std.debug.print("SVG mapped native oracle: {d} accepted, {d} explicit cluster rejection (no character reshaping)\n", .{ accepted, rejected });
}
fn read(renderer: anytype, x: u32, y: u32) !u32 {
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) return renderer.readPixelForTest(x, y);
    if (builtin.os.tag == .windows) {
        const pixel = c.GetPixel(renderer.dc, @intCast(x), @intCast(y));
        if (pixel == c.CLR_INVALID) return error.ReadPixelFailed;
        return ((pixel & 255) << 16) | (pixel & 0xff00) | ((pixel >> 16) & 255);
    }
    return zlc_test_raw_pixel(renderer.native.?, x, y);
}
fn readFrame(renderer: anytype, width: u32, height: u32, pixels: []u32) !void {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) return;
    try renderer.readPixelsForTest(width, height, pixels);
    // Keep the old independent single-pixel read at five points to check the
    // batch's row indexing and channel order without a round trip per pixel.
    for ([_][2]u32{ .{ 0, 0 }, .{ width - 1, 0 }, .{ width / 2, height / 2 }, .{ 0, height - 1 }, .{ width - 1, height - 1 } }) |point|
        try std.testing.expectEqual(try read(renderer, point[0], point[1]), pixels[@as(usize, point[1]) * width + point[0]]);
}
fn framePixel(renderer: anytype, pixels: []const u32, width: u32, x: u32, y: u32) !u32 {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) return read(renderer, x, y);
    return pixels[@as(usize, y) * width + x];
}
fn replay(renderer: anytype, image: *svg.Prepared, scale: f32, context: *anyopaque, window: ?*anyopaque) !void {
    const view = try image.view();
    const level = view.levels[0];
    try renderer.uploadImage(view);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 128, .height = 48 }, 0x204060);
    try buffer.pushClip(.{ .x = 12, .y = 0, .width = 112, .height = 48 });
    try buffer.image(.{ .x = 0, .y = 0, .width = 128, .height = 48 }, view, .{ .sampling = .nearest });
    try buffer.popClip();
    try std.testing.expectError(error.ResourceInUse, image.close());
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = level.width, .height = level.height, .scale = scale } };
    // The fixture prepares 128x48 at up to2x. Software keeps its original read
    // path; only the GPU specialization reserves this fixed diagnostic buffer.
    var frame_pixels: [if (@TypeOf(renderer.*) == ui.SoftwareRenderer) 0 else 256 * 96]u32 = undefined;
    for (0..4) |pass| {
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        if (@TypeOf(renderer.*) != ui.SoftwareRenderer) {
            if (pass == 0) try readFrame(renderer, level.width, level.height, frame_pixels[0 .. @as(usize, level.width) * level.height]);
        }
        if (pass == 0) for (0..level.height) |y| for (0..level.width) |x| {
            const pixel = level.pixels[y * level.stride + x * 4 ..][0..4];
            const actual = try framePixel(renderer, &frame_pixels, level.width, @intCast(x), @intCast(y));
            inline for ([_]u5{ 0, 8, 16 }) |shift| {
                const channel = shift / 8;
                const background: f64 = @floatFromInt((@as(u32, 0x204060) >> shift) & 255);
                const expected: u8 = if (@as(f64, @floatFromInt(x)) >= 12 * scale and @as(f64, @floatFromInt(x)) < 124 * scale) @intFromFloat(@round(@as(f64, @floatFromInt(pixel[channel])) + background * (1 - @as(f64, @floatFromInt(pixel[3])) / 255))) else @intFromFloat(background);
                const got: u8 = @truncate(actual >> shift);
                if (@abs(@as(i32, expected) - @as(i32, got)) > 2) return error.NativeTextPixelMismatch;
            }
        };
        if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else renderer.end() catch |err| {
            if (err != error.PresentationBusy) return err;
        };
    }
    const warmed = renderer.imageStats().native_creations;
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
    try std.testing.expectEqual(warmed, renderer.imageStats().native_creations);
    buffer.reset();
    _ = try renderer.releaseImage(view.identity);
    try image.lease.ensureUnused();
}
fn nativeReplay(allocator: std.mem.Allocator, image: *svg.Prepared, scale: f32) !void {
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd = window.nativeHandle();
            const dc = c.GetDC(hwnd) orelse return error.NoSurface;
            defer _ = c.ReleaseDC(hwnd, dc);
            const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            {
                var renderer: ui.SoftwareRenderer = .{};
                defer renderer.deinit();
                try replay(&renderer, image, scale, dc, hwnd);
            }
            try std.testing.expectEqual(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var renderer: ui.d3d11.Renderer = .{};
                try renderer.init(.{ .driver = driver });
                defer renderer.deinit();
                try replay(&renderer, image, scale, dc, hwnd);
                renderer.deinit();
                try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
            };
        }
        _ = try window.destroy();
    } else {
        const surface = cairo_image_surface_create(0, 256, 96) orelse return error.NoSurface;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.NoSurface;
        defer cairo_destroy(context);
        var renderer: ui.SoftwareRenderer = .{};
        defer renderer.deinit();
        try replay(&renderer, image, scale, context, null);
        renderer.deinit();
        try std.testing.expectEqual(@as(u32, 0), zlc_test_live_image_objects());
    }
}
fn allocationPass(allocator: std.mem.Allocator, document: *svg.Document, provider: *svg_text.Provider, mode: Mode) !void {
    const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 128, .height = 48, .compositing = mode, .text_provider = try provider.interface() });
    defer output.close() catch unreachable;
}
const Reentry = struct {
    child: std.mem.Allocator,
    document: *svg.Document,
    provider: *svg_text.Provider,
    active: bool = true,
    checks: usize = 0,
    native_checks: usize = 0,
    failure: ?anyerror = null,
    allocations: usize = 0,
    cancellation: ?*vector.Cancellation = null,
    cancel_at: usize = 0,
    fn allocator(self: *Reentry) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn probe(self: *Reentry) !void {
        if (!self.active) return;
        try std.testing.expectError(error.Busy, self.document.close());
        try std.testing.expectError(error.Busy, self.document.prepare(self.child, .{ .main_thread = std.Thread.getCurrentId(), .width = 1, .height = 1 }));
        try std.testing.expectError(error.Busy, self.provider.stats());
        try std.testing.expectError(error.Busy, self.provider.close());
        self.native_checks += 1;
        self.checks += 1;
    }
    fn fire(self: *Reentry) void {
        self.probe() catch |err| {
            self.failure = err;
        };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Reentry = @ptrCast(@alignCast(context));
        self.allocations += 1;
        if (self.allocations == self.cancel_at) if (self.cancellation) |cancel| cancel.request();
        self.fire();
        return self.child.rawAlloc(length, alignment, ret);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Reentry = @ptrCast(@alignCast(context));
        self.fire();
        self.child.rawFree(bytes, alignment, ret);
    }
};
fn reentry(allocator: std.mem.Allocator, document: *svg.Document, provider: *svg_text.Provider, mode: Mode) !void {
    var state: Reentry = .{ .child = allocator, .document = document, .provider = provider };
    const output = try document.prepare(state.allocator(), .{ .main_thread = std.Thread.getCurrentId(), .width = 128, .height = 48, .compositing = mode, .text_provider = try provider.interface() });
    state.active = false;
    defer output.close() catch unreachable;
    if (state.failure) |err| return err;
    try std.testing.expect(state.checks > 0 and state.native_checks > 0);
    const peak = (try output.stats()).peak_bytes;
    var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 128, .height = 48, .compositing = mode, .text_provider = try provider.interface() };
    options.limits.bytes = peak - 1;
    try std.testing.expectError(error.CapacityExceeded, document.prepare(allocator, options));
    for (1..state.allocations + 1) |at| {
        var cancellation: vector.Cancellation = .{};
        var interrupted: Reentry = .{ .child = allocator, .document = document, .provider = provider, .cancellation = &cancellation, .cancel_at = at };
        var cancelled_options = options;
        cancelled_options.limits.bytes = 64 * 1024 * 1024;
        cancelled_options.cancellation = &cancellation;
        try std.testing.expectError(error.Cancelled, document.prepare(interrupted.allocator(), cancelled_options));
        if (interrupted.failure) |err| return err;
    }
}
const Worker = struct {
    allocator: std.mem.Allocator,
    provider: svg.text.Provider,
    main_thread: std.Thread.Id,
    fn run(self: *Worker) !void {
        const document = try svg.Document.parse(self.allocator, source, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(error.WrongThread, document.prepare(self.allocator, .{ .main_thread = self.main_thread, .width = 128, .height = 48, .text_provider = self.provider }));
    }
};
pub fn main() !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(heap.deinit() == .ok);
    const allocator = heap.allocator();
    try pixelOracle(allocator, "Office A O", &.{ source, clipped_source }, true);
    try pixelOracle(allocator, "  A   O ", &.{"<svg viewBox='0 0 128 48' xml:space='preserve'><text x='8' y='30' font-size='24' fill='rgba(64,128,192,0.5)'> \tA\n  O </text></svg>"}, false);
    try objectBoundsOracle(allocator, false);
    try objectBoundsOracle(allocator, true);
    try spanOracles(allocator);
    try paintOrderOracle(allocator);
    try paintedOracle(allocator);
    try paintedSpacingOracle(allocator);
    try lengthOracle(allocator);
    try textPathOracle(allocator);
    try mappedOracle(allocator);
    const provider = try svg_text.Provider.create(allocator, std.Thread.getCurrentId(), .{});
    var worker: Worker = .{ .allocator = allocator, .provider = try provider.interface(), .main_thread = std.Thread.getCurrentId() };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    try std.testing.expectEqual(@as(u64, 0), (try provider.stats()).requests);
    const multiple = try svg.Document.parse(allocator, "<svg><text>A\u{2028}B</text></svg>", .{});
    try std.testing.expectError(error.UnsupportedTextMultiline, multiple.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 128, .height = 48, .text_provider = try provider.interface() }));
    try multiple.close();
    const hidden = try svg.Document.parse(allocator, "<svg><text visibility='hidden' x='8 52' y='30'>A<tspan>V</tspan></text></svg>", .{});
    defer hidden.close() catch unreachable;
    const visibility_change = try svg.Document.parse(allocator, "<svg><text visibility='hidden'>A<tspan visibility='visible'>V</tspan></text></svg>", .{});
    defer visibility_change.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 128, .height = 48, .compositing = mode, .text_provider = try provider.interface() };
        const image = try hidden.prepare(allocator, options);
        defer image.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 0), (try image.stats()).text_requests);
        try std.testing.expectError(error.UnsupportedTextSpanStyle, visibility_change.prepare(allocator, options));
    }
    try std.testing.expectEqual(@as(u64, 0), (try provider.stats()).requests);
    const document = try svg.Document.parse(allocator, source, .{});
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try reentry(allocator, document, provider, mode);
        try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{ document, provider, mode });
    }
    try document.close();
    const spans = try svg.Document.parse(allocator, span_source, .{});
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try reentry(allocator, spans, provider, mode);
        try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{ spans, provider, mode });
    }
    try spans.close();
    const mapped = try svg.Document.parse(allocator, "<svg><text x='8' y='30' font-size='24' rotate='10 25' dx='0 3 4'>A<tspan>V office</tspan></text></svg>", .{});
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try reentry(allocator, mapped, provider, mode);
        try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{ mapped, provider, mode });
    }
    try mapped.close();
    for ([_][]const u8{
        "<svg><defs><text id='t' x='8' y='30' font-size='24' fill='currentColor' stroke='black'>A<tspan fill='blue'>V</tspan><tspan fill='red'>X</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='blue' x='3' y='6'/></svg>",
        "<svg><defs><text id='t' x='8' y='30' font-size='24' fill='currentColor' stroke='black' rotate='35 0 0' dx='0 2 3'>A<tspan fill='blue'>V</tspan><tspan fill='red'>X</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='blue' x='3' y='6'/></svg>",
        "<svg><defs><text id='t' x='8' y='30' textLength='72' font-size='24' fill='currentColor' stroke='black' rotate='35 0 0' dx='0 2 3'>A<tspan fill='blue'>V</tspan><tspan fill='red'>X</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='blue' x='3' y='6'/></svg>",
        "<svg><defs><text id='t' x='8' y='30' textLength='72' lengthAdjust='spacingAndGlyphs' font-size='24' fill='currentColor' stroke='black'>A<tspan fill='blue'>V</tspan><tspan fill='red'>X</tspan></text></defs><use href='#t' color='red'/><use href='#t' color='blue' x='3' y='6'/></svg>",
    }) |painted_source| {
        const painted = try svg.Document.parse(allocator, painted_source, .{});
        for ([_]Mode{ .pixel, .sample_color }) |mode| {
            try reentry(allocator, painted, provider, mode);
            try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{ painted, provider, mode });
        }
        try painted.close();
    }
    const mixed = try svg.Document.parse(allocator, "<svg><text rotate='15'>ABC אבג</text></svg>", .{});
    defer mixed.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.expectError(error.UnsupportedTextPositionBidi, mixed.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 128, .height = 48, .compositing = mode, .text_provider = try provider.interface() }));
    try provider.close();
    const counts = text.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.references);
    try std.testing.expectEqual(@as(u32, 0), counts.modules);
    std.debug.print("SVG text: nested shaping, positions/RTL, paint-order/text length, solid fill runs/common stroke, glyph outlines/full cells, gradient/clip/mask, two modes/3DPI, full candidate OOM and refs=0 passed\n", .{});
}
