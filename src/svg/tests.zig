const std = @import("std");
const api = @import("root.zig");
const xml = @import("xml.zig");
const numbers = @import("numbers.zig");
const shape = @import("shape.zig");
const vector = @import("ziggurat_vector");
const paint = @import("paint.zig");
const allocator = std.testing.allocator;

test "owned SVG XML tree preserves ancestry and decodes attributes and text once" {
    var source = ("\xef\xbb\xbf<?xml version='1.0' encoding='UTF-8' standalone='yes'?>" ++
        "<svg xmlns='http://www.w3.org/2000/svg'><g id='a&amp;b' data-x='a\r\n&#10;b'>" ++
        "<path d='M0 0L2 2'/><title>A&amp;lt;&#x1f600;<![CDATA[<&\r\n>]]></title></g></svg>").*;
    const document = try api.Document.parse(allocator, &source, .{});
    defer document.close() catch unreachable;
    @memset(&source, 'x');
    const root = try document.node(0);
    try std.testing.expectEqualStrings("svg", root.name);
    const group = try document.node(root.first_child.?);
    try std.testing.expectEqualStrings("a&b", group.attribute("id").?);
    try std.testing.expectEqualStrings("a \nb", group.attribute("data-x").?);
    const path = try document.node(group.first_child.?);
    try std.testing.expectEqualStrings("path", path.name);
    const title = try document.node(path.next_sibling.?);
    const text = try document.node(title.first_child.?);
    try std.testing.expectEqualStrings("A&lt;😀", text.text);
    try std.testing.expectEqualStrings("<&\n>", (try document.node(text.next_sibling.?)).text);
    try std.testing.expectEqual(@as(usize, 6), (try document.stats()).nodes);
}

test "XML parser rejects declarations external entities ambiguity and incomplete input" {
    const cases = [_][]const u8{
        "",                                     "<svg>",                       "<svg></g>",                                     "<svg/><svg/>",           "text<svg/>",                                    "<svg/>text",                                         "<svg x='a' x='b'/>",
        "<svg x=a/>",                           "<svg x='a'b='b'/>",           "<svg x='<x'/>",                                 "<svg x='&external;'/>",  "<svg>&#0;</svg>",                               "<svg>&#xD800;</svg>",                                "<svg>&#x110000;</svg>",
        "<svg>&#X20;</svg>",                    "<svg>&#-1;</svg>",            "<svg>&#x;</svg>",                               "<svg>]]></svg>",         "<!DOCTYPE svg SYSTEM 'file:///private'><svg/>", "<!DOCTYPE svg [<!ENTITY x 'value'>]><svg>&x;</svg>", "<?x abc?><svg/>",
        " <!--x--><?xml version='1.0'?><svg/>", "<?xml version='1.1'?><svg/>", "<?xml version='1.0' encoding='UTF-16'?><svg/>", "<svg><!--a--b--></svg>", "<svg><!--a---></svg>",                          "<svg>\x01</svg>",                                    "<svg>\xff</svg>",
        "<html/>",                              "<svg xmlns='urn:other'/>",
    };
    for (cases) |input| {
        if (api.Document.parse(allocator, input, .{})) |document| {
            try document.close();
            std.debug.print("unexpected accepted XML: {s}\n", .{input});
            return error.InvalidInputAccepted;
        } else |_| {}
    }
    const prefix = try api.Document.parse(allocator, "<v:svg xmlns:v='http://www.w3.org/2000/svg'/>", .{});
    try prefix.close();
}

test "XML allocation failures and node depth attribute byte budgets preserve ownership" {
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const value = try api.Document.parse(a, "<svg><g><path d='M0 0'/><title>x&amp;y</title></g></svg>", .{});
            try value.close();
        }
    }.run, .{});
    try std.testing.expectError(error.NodesFull, api.Document.parse(allocator, "<svg>a<!--x-->b</svg>", .{ .nodes = 2 }));
    try std.testing.expectError(error.DepthFull, api.Document.parse(allocator, "<svg><g/></svg>", .{ .depth = 1 }));
    try std.testing.expectError(error.AttributesFull, api.Document.parse(allocator, "<svg a='1' b='2'/>", .{ .attributes = 1 }));
    try std.testing.expectError(error.AttributeTooLarge, api.Document.parse(allocator, "<svg a='123'/>", .{ .attribute_bytes = 2 }));
    try std.testing.expectError(error.InputTooLarge, api.Document.parse(allocator, "<svg/>", .{ .input_bytes = 1 }));
    try std.testing.expectError(error.CapacityExceeded, api.Document.parse(allocator, "<svg/>", .{ .bytes = 1 }));
    var decoded: [8]u8 = undefined;
    try std.testing.expectEqualStrings("<&'\"😀", decoded[0..try xml.decode(&decoded, "&lt;&amp;&apos;&quot;&#128512;", false)]);
    try std.testing.expectError(error.BufferTooSmall, xml.decode(decoded[0..1], "&amp;&amp;", false));
}

test "SVG numeric lists physical units and transform order have strict finite bounds" {
    var values: [4]f64 = undefined;
    try std.testing.expectEqualSlices(f64, &.{ -1, 0.5, 200, 3 }, try numbers.list("-1, .5 2e2,3.", &values));
    try std.testing.expectApproxEqAbs(@as(f64, 96), try (try numbers.length("2.54cm")).resolve(1), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 96), try (try numbers.length("72pt")).resolve(1), 1e-10);
    try std.testing.expectEqual(@as(f64, 40), try (try numbers.length("25%")).resolve(160));
    const matrix = try numbers.transform("translate(10 20) scale(2 3)");
    const result = matrix.apply(.{ .x = 1, .y = 2 });
    try std.testing.expectEqual(@as(f64, 12), result.x);
    try std.testing.expectEqual(@as(f64, 26), result.y);
    const rotated = (try numbers.transform("rotate(90, 3, 4)")).apply(.{ .x = 4, .y = 4 });
    try std.testing.expectApproxEqAbs(@as(f64, 3), rotated.x, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5), rotated.y, 1e-12);
    try std.testing.expectError(error.UnsupportedNumberPrecision, numbers.scalar("1e-999"));
    try std.testing.expectError(error.InvalidNumber, numbers.scalar("NaN"));
    try std.testing.expectError(error.NumberSeparatorRequired, numbers.list("1.2.3", &values));
    try std.testing.expectError(error.InvalidNumber, numbers.list("1,", &values));
    try std.testing.expectError(error.InvalidTransform, numbers.transform("matrix(1 2)"));
    try std.testing.expectError(error.InvalidTransform, numbers.transform("skewX(90)"));
    try std.testing.expectError(error.TransformSeparatorRequired, numbers.transform("scale(2)translate(1)"));
}

test "basic SVG shapes produce independent bounded path masks" {
    const cases = [_]struct { input: []const u8, data: []const u8, stroke: bool = false }{
        .{ .input = "<rect x='12.5%' y='2' width='50%' height='8'/>", .data = "M2 2H10V10H2Z" },
        .{ .input = "<rect x='2' y='2' width='8' height='8' rx='2'/>", .data = "M4 2H8A2 2 0 0 1 10 4V8A2 2 0 0 1 8 10H4A2 2 0 0 1 2 8V4A2 2 0 0 1 4 2Z" },
        .{ .input = "<circle cx='8' cy='8' r='4'/>", .data = "M12 8A4 4 0 0 1 8 12A4 4 0 0 1 4 8A4 4 0 0 1 8 4A4 4 0 0 1 12 8Z" },
        .{ .input = "<ellipse cx='8' cy='8' rx='4' ry='2'/>", .data = "M12 8A4 2 0 0 1 8 10A4 2 0 0 1 4 8A4 2 0 0 1 8 6A4 2 0 0 1 12 8Z" },
        .{ .input = "<polygon points='2,2 10,2 10,10 2,10'/>", .data = "M2 2H10V10H2Z" },
        .{ .input = "<polyline points='2,2 10,2 10,10'/>", .data = "M2 2H10V10", .stroke = true },
        .{ .input = "<line x1='2' y1='4' x2='12' y2='4'/>", .data = "M2 4H12", .stroke = true },
    };
    for (cases) |case| {
        const input = try std.fmt.allocPrint(allocator, "<svg>{s}</svg>", .{case.input});
        defer allocator.free(input);
        const document = try api.Document.parse(allocator, input, .{});
        defer document.close() catch unreachable;
        const node = try document.node((try document.node(0)).first_child.?);
        const actual_path = (try shape.path(allocator, node, node.name, .{ .width = 16, .height = 16 }, .{}, null)).?;
        defer actual_path.close() catch unreachable;
        const expected_path = try vector.Path.parseData(allocator, case.data, .{});
        defer expected_path.close() catch unreachable;
        var o: vector.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 16, .height = 16 } };
        if (case.stroke) o.style = .{ .stroke = .{ .width = 2, .cap = .round } };
        const actual = try actual_path.prepare(allocator, o);
        defer actual.close() catch unreachable;
        const expected = try expected_path.prepare(allocator, o);
        defer expected.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, (try expected.view()).coverage.pixels, (try actual.view()).coverage.pixels);
    }
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const value = try api.Document.parse(a, "<svg><polygon points='1 1 2 2 1 2'/></svg>", .{});
            defer value.close() catch unreachable;
            const node = try value.node(1);
            const path_value = (try shape.path(a, node, node.name, .{ .width = 16, .height = 16 }, .{}, null)).?;
            try path_value.close();
        }
    }.run, .{});
}

test "SVG paint handles encoded sRGB alpha HSL and strictly local paint references" {
    const cases = [_]struct { input: []const u8, expected: paint.Color }{
        .{ .input = "#f08", .expected = .{ .r = 255, .b = 136 } },
        .{ .input = "#12ab34cd", .expected = .{ .r = 18, .g = 171, .b = 52, .a = 205 } },
        .{ .input = "RGB(100%, 0%, 0%)", .expected = .{ .r = 255 } },
        .{ .input = "rgba(300,-2,0,.5)", .expected = .{ .r = 255, .a = 128 } },
        .{ .input = "rgb(255 0% 0 / 25%)", .expected = .{ .r = 255, .a = 64 } },
        .{ .input = "hsl(-120 100% 50%)", .expected = .{ .b = 255 } },
        .{ .input = "hsla(.5turn, 100%, 50%, .25)", .expected = .{ .g = 255, .b = 255, .a = 64 } },
        .{ .input = "ALIceBLue", .expected = .{ .r = 240, .g = 248, .b = 255 } },
        .{ .input = "RebeccaPurple", .expected = .{ .r = 102, .g = 51, .b = 153 } },
        .{ .input = "transparent", .expected = .{ .a = 0 } },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, try paint.color(case.input));
    try std.testing.expectEqual(paint.Paint.current_color, try paint.parse(" currentColor "));
    const reference = (try paint.parse("url('#gradient') red")).reference;
    try std.testing.expectEqualStrings("gradient", reference.id);
    try std.testing.expectEqual(paint.Color{ .r = 255 }, reference.fallback.color);
    for ([_][]const u8{ "url(file:///x)", "url(data:x)", "url(https://example.test/x#y)", "url(icons.svg#x)" }) |input| try std.testing.expectError(error.ExternalResourceDenied, paint.parse(input));
    for ([_][]const u8{ "#+1+2+3", "#12", "#12345", "rgb(1,,2)", "rgb(1 2)", "rgb(1 2 3, .5)", "rgb(1,2,3 / .5)", "rgb(1 2 3 .5)", "hsl(1 2 3)", "rgb(1e999 0 0)", "rgb(1 2 3 /)" }) |input| {
        if (paint.color(input)) |_| return error.InvalidColorAccepted else |_| {}
    }
}

test "SVG preparation composites overlapping children once and owns a stable image view" {
    const document = try api.Document.parse(allocator, "<svg viewBox='0 0 16 16'><g opacity='.5' fill='red'><rect x='2' y='2' width='8' height='8'/>" ++
        "<rect x='6' y='2' width='8' height='8' style='fill:blue'/></g></svg>", .{});
    var document_closed = false;
    defer if (!document_closed) document.close() catch unreachable;
    const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 16, .height = 16 });
    defer image.close() catch unreachable;
    try document.close();
    document_closed = true;
    const view = try image.view();
    try view.validate();
    const pixels = view.levels[0].pixels;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128 }, pixels[(4 * 16 + 4) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, pixels[(4 * 16 + 8) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[0..4]);
    try view.lease.acquire();
    try std.testing.expectError(error.ResourceInUse, image.close());
    view.lease.release();
    try std.testing.expectEqual(@as(usize, 2), (try image.stats()).paths);
    const inherit = try api.Document.parse(allocator, "<svg viewBox='0 0 8 8'><g visibility='hidden' fill='currentColor'><rect width='8' height='8' visibility='visible'/></g></svg>", .{});
    defer inherit.close() catch unreachable;
    const green = try inherit.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 16, .height = 8, .current_color = .{ .g = 255 } });
    defer green.close() catch unreachable;
    const g = (try green.view()).levels[0].pixels;
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, g[(4 * 16 + 8) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, g[(4 * 16 + 1) * 4 ..][0..4]);
}

test "SVG preparing all allocation failures and explicit work budgets preserve the source" {
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const document = try api.Document.parse(a, "<svg viewBox='0 0 16 16'><g opacity='.5'><polygon points='2 2 12 2 12 12 2 12' fill='red' stroke='blue' stroke-dasharray='2 1' stroke-linecap='round'/></g></svg>", .{});
            defer document.close() catch unreachable;
            const image = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 16, .height = 16 });
            try image.close();
        }
    }.run, .{});
    const document = try api.Document.parse(allocator, "<svg><g opacity='.5'><rect width='8' height='8'/></g></svg>", .{});
    defer document.close() catch unreachable;
    var options: api.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 16, .height = 16 };
    options.limits.layers = 0;
    try std.testing.expectError(error.LayersFull, document.prepare(allocator, options));
    options.limits.layers = 8;
    options.limits.pixel_work = 1;
    try std.testing.expectError(error.PixelWorkExceeded, document.prepare(allocator, options));
    options.limits.pixel_work = 4096;
    options.limits.bytes = 2048;
    try std.testing.expectError(error.CapacityExceeded, document.prepare(allocator, options));
    options.limits = .{};
    var cancellation: vector.Cancellation = .{};
    cancellation.request();
    options.cancellation = &cancellation;
    try std.testing.expectError(error.Cancelled, document.prepare(allocator, options));
    for ([_][]const u8{ "<svg><script/></svg>", "<svg><defs><script/></defs></svg>", "<svg><rect fill='url(https://example.test/a)'/></svg>", "<svg xmlns:x='urn:other'><x:rect/></svg>" }) |input| {
        const invalid = try api.Document.parse(allocator, input, .{});
        defer invalid.close() catch unreachable;
        if (invalid.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 1, .height = 1 })) |image| {
            try image.close();
            return error.InvalidFeatureAccepted;
        } else |_| {}
    }
}

fn expectSvgPixel(image: *api.Prepared, x: usize, y: usize, expected: []const u8) !void {
    const level = (try image.view()).levels[0];
    try std.testing.expectEqualSlices(u8, expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
}

test "SVG CSS compound selectors cascade specificity importance and inheritance before painting" {
    const source = "<svg viewBox='0 0 16 4' color='lime'><style><![CDATA[/* bounded sheet */" ++
        "rect { fill: red } .tile { fill: blue } rect.tile.hot { fill: gold }" ++
        "#one { fill: purple } #one { fill: currentColor !important }" ++
        "#two { fill: red !important } #four, .unused { fill: blue }" ++
        "]]></style><style>#four { fill: currentColor }</style>" ++
        "<rect id='one' class='tile hot' width='4' height='4' fill='black' style='fill:yellow'/>" ++
        "<rect id='two' class='tile' x='4' width='4' height='4' style='FILL:blue !IMPORTANT'/>" ++
        "<g fill='cyan' color='red'><rect x='8' width='4' height='4' style='fill:inherit;color:initial'/></g>" ++
        "<rect id='four' x='12' width='4' height='4'/></svg>";
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 16, .height = 4 });
    defer image.close() catch unreachable;
    try expectSvgPixel(image, 2, 2, &.{ 0, 255, 0, 255 });
    try expectSvgPixel(image, 6, 2, &.{ 255, 0, 0, 255 });
    try expectSvgPixel(image, 10, 2, &.{ 255, 255, 0, 255 });
    try expectSvgPixel(image, 14, 2, &.{ 0, 255, 0, 255 });
    const stats = try image.stats();
    try std.testing.expectEqual(@as(usize, 9), stats.stylesheet_rules);
    try std.testing.expect(stats.stylesheet_bytes > 0 and stats.style_work > 0);
}

test "SVG CSS allocation failures and aggregate rule declaration matching budgets are bounded" {
    const source = "<svg viewBox='0 0 4 4'><style>.tile { fill: red; stroke: blue; stroke-width: 1PX }" ++
        "#one, rect.tile { fill: currentColor !important }</style><rect id='one' class='tile' color='lime' width='4' height='4'/></svg>";
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator, input: []const u8) !void {
            const document = try api.Document.parse(a, input, .{});
            defer document.close() catch unreachable;
            const image = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 });
            try image.close();
        }
    }.run, .{source});
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    var options: api.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 };
    options.limits.styles.bytes = 2;
    try std.testing.expectError(error.StylesheetTooLarge, document.prepare(allocator, options));
    options.limits.styles = .{ .rules = 1 };
    try std.testing.expectError(error.RulesFull, document.prepare(allocator, options));
    options.limits.styles = .{ .declarations = 1 };
    try std.testing.expectError(error.DeclarationsFull, document.prepare(allocator, options));
    options.limits.styles = .{};
    options.limits.style_work = 1;
    try std.testing.expectError(error.StyleWorkExceeded, document.prepare(allocator, options));
    options.limits = .{};
    const image = try document.prepare(allocator, options);
    try image.close();
}

test "SVG CSS unsupported selectors and external rules fail explicitly even when not matched" {
    const cases = [_][]const u8{
        "@import 'https://example.test/style.css';", "@media all {rect {fill:red}}",
        "g rect {fill:red}",                         "rect:hover {fill:red}",
        "[id] {fill:red}",                           ".123 {fill:red}",
        ".-1 {fill:red}",                            ". {fill:red}",
        ".x {fill:red",                              ".x {fill:var(--color)}",
        ".x {fill:url(https://example.test/a)}",     ".x {fill:red} /* unclosed",
        ".x {unknown:red}",
    };
    for (cases) |sheet| {
        const source = try std.fmt.allocPrint(allocator, "<svg><style><![CDATA[{s}]]></style><rect width='4' height='4'/></svg>", .{sheet});
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        if (document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 })) |image| {
            try image.close();
            std.debug.print("unsupported sheet accepted: {s}\n", .{sheet});
            return error.UnsupportedStyleAccepted;
        } else |_| {}
    }
    const split = try api.Document.parse(allocator, "<svg><style>.x {fill:</style><style>red}</style></svg>", .{});
    defer split.close() catch unreachable;
    try std.testing.expectError(error.InvalidStylesheet, split.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 }));
}

fn svgPixelsEqual(actual_source: []const u8, expected_source: []const u8, width: u32, height: u32) !void {
    const options: api.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = width, .height = height };
    const actual_document = try api.Document.parse(allocator, actual_source, .{});
    defer actual_document.close() catch unreachable;
    const actual = try actual_document.prepare(allocator, options);
    defer actual.close() catch unreachable;
    const expected_document = try api.Document.parse(allocator, expected_source, .{});
    defer expected_document.close() catch unreachable;
    const expected = try expected_document.prepare(allocator, options);
    defer expected.close() catch unreachable;
    const a = (try actual.view()).levels[0];
    const e = (try expected.view()).levels[0];
    try std.testing.expectEqualSlices(u8, e.pixels[0..e.byte_len], a.pixels[0..a.byte_len]);
}

test "SVG use resolves indexed local IDs inherits instance styles and composes x y before transforms" {
    try svgPixelsEqual(
        "<svg viewBox='0 0 24 16' xmlns:xlink='http://www.w3.org/1999/xlink'>" ++
            "<style>.tile {fill:currentColor}</style><defs><g fill='blue'><rect id='tile' class='tile' width='4' height='4'/></g>" ++
            "<use id='second' href='#tile' x='2'/></defs>" ++
            "<use href='#tile' x='2' y='2' transform='scale(2)' color='red' width='1' height='1'/>" ++
            "<use xlink:href='#second' x='12' y='4' color='lime'/></svg>",
        "<svg viewBox='0 0 24 16'><rect x='4' y='4' width='8' height='8' fill='red'/>" ++
            "<rect x='14' y='4' width='4' height='4' fill='lime'/></svg>",
        24,
        16,
    );
}

test "SVG symbol and nested viewports map percentages overrides and clip once after group opacity" {
    // A8 rows are aligned to four bytes; output widths need not be aligned.
    try svgPixelsEqual(
        "<svg viewBox='0 0 17 13'><svg x='2' y='3' width='8' height='7'><rect x='-2' y='-2' width='12' height='11' fill='red'/></svg></svg>",
        "<svg viewBox='0 0 17 13'><rect x='2' y='3' width='8' height='7' fill='red'/></svg>",
        17,
        13,
    );
    try svgPixelsEqual(
        "<svg viewBox='0 0 24 16'><defs><symbol id='tile' viewBox='0 0 4 4' width='4' height='4'>" ++
            "<rect x='-100%' y='-100%' width='300%' height='300%'/></symbol></defs>" ++
            "<use href='#tile' x='2' y='2' width='8' height='8' fill='red' opacity='.5'/>" ++
            "<svg x='50%' y='25%' width='25%' height='50%' viewBox='0 0 3 4' preserveAspectRatio='none'>" ++
            "<rect width='100%' height='100%' fill='lime'/></svg></svg>",
        "<svg viewBox='0 0 24 16'><rect x='2' y='2' width='8' height='8' fill='red' opacity='.5'/>" ++
            "<rect x='12' y='4' width='6' height='8' fill='lime'/></svg>",
        24,
        16,
    );
    try svgPixelsEqual(
        "<svg viewBox='0 0 16 16'><svg x='4' y='4' width='8' height='8' viewBox='0 0 8 8' style='overflow:visible'>" ++
            "<rect x='-2' y='-2' width='12' height='12' fill='blue'/></svg></svg>",
        "<svg viewBox='0 0 16 16'><rect x='2' y='2' width='12' height='12' fill='blue'/></svg>",
        16,
        16,
    );
}

test "SVG reference cycles duplicates external locations expansion and allocation failures preserve source" {
    const cases = [_]struct { input: []const u8, err: anyerror }{
        .{ .input = "<svg id='a'><use href='#a'/></svg>", .err = error.ReferenceCycle },
        .{ .input = "<svg><defs><g id='a'><use href='#b'/></g><g id='b'><use href='#a'/></g></defs><use href='#a'/></svg>", .err = error.ReferenceCycle },
        .{ .input = "<svg><g id='a'/><g id='a'/></svg>", .err = error.DuplicateId },
        .{ .input = "<svg><use href='#missing'/></svg>", .err = error.ReferenceNotFound },
        .{ .input = "<svg><defs><use href='https://example.test/a#b'/></defs></svg>", .err = error.ExternalResourceDenied },
        .{ .input = "<svg><use href='file:///private'/></svg>", .err = error.ExternalResourceDenied },
        .{ .input = "<svg><use href='#a%20b'/></svg>", .err = error.UnsupportedReferenceEscape },
        .{ .input = "<svg xmlns:xlink='urn:other'><use xlink:href='#a'/></svg>", .err = error.UnsupportedNamespace },
        .{ .input = "<svg><symbol id='x'/><use href='#x' width='-1'/></svg>", .err = error.InvalidViewport },
    };
    const options: api.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 16, .height = 16 };
    for (cases) |case| {
        const document = try api.Document.parse(allocator, case.input, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(case.err, document.prepare(allocator, options));
    }
    const source = "<svg viewBox='0 0 16 16'><defs><symbol id='x' viewBox='0 0 4 4'><rect width='4' height='4'/></symbol>" ++
        "<g id='y'><use href='#x'/><use href='#x'/></g></defs><use href='#y' width='8' height='8'/></svg>";
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator, input: []const u8, settings: api.PrepareOptions) !void {
            const document = try api.Document.parse(a, input, .{});
            defer document.close() catch unreachable;
            const image = try document.prepare(a, settings);
            try image.close();
        }
    }.run, .{ source, options });
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    var limited = options;
    limited.limits.reference_depth = 1;
    try std.testing.expectError(error.ReferenceDepthFull, document.prepare(allocator, limited));
    limited = options;
    limited.limits.node_visits = 4;
    try std.testing.expectError(error.NodeWorkExceeded, document.prepare(allocator, limited));
    const image = try document.prepare(allocator, options);
    try image.close();
}

test "SVG gradient straight alpha interpolation hard stops templates and color space have independent pixels" {
    const source = "<svg viewBox='0 0 4 4'><style>.first {stop-color:red} .last {stop-color:blue;stop-opacity:0}</style>" ++
        "<defs><linearGradient id='base' gradientUnits='userSpaceOnUse' x1='.5' x2='4.5'><stop class='first'/>" ++
        "<stop offset='1' class='last'/></linearGradient><linearGradient id='g' href='#base'/></defs>" ++
        "<rect width='4' height='4' fill='url(#g)'/></svg>";
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 });
    defer image.close() catch unreachable;
    try expectSvgPixel(image, 0, 2, &.{ 0, 0, 255, 255 });
    try expectSvgPixel(image, 2, 2, &.{ 64, 0, 64, 128 });
    const linear = try api.Document.parse(allocator, "<svg viewBox='0 0 4 4'><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x1='.5' x2='4.5' color-interpolation='linearRGB'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>", .{});
    defer linear.close() catch unreachable;
    const light = try linear.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 });
    defer light.close() catch unreachable;
    try expectSvgPixel(light, 2, 2, &.{ 188, 0, 188, 255 });
    const hard = try api.Document.parse(allocator, "<svg viewBox='0 0 4 4'><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x1='.5' x2='4.5'><stop stop-color='red'/><stop offset='.5' stop-color='red'/><stop offset='.5' stop-color='blue'/><stop offset='1' stop-color='blue'/></linearGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>", .{});
    defer hard.close() catch unreachable;
    const edge = try hard.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 });
    defer edge.close() catch unreachable;
    try expectSvgPixel(edge, 1, 2, &.{ 0, 0, 255, 255 });
    try expectSvgPixel(edge, 2, 2, &.{ 255, 0, 0, 255 });
}

test "SVG gradient bounding boxes use analytic geometry and transform before object mapping" {
    try svgPixelsEqual(
        "<svg viewBox='0 0 24 16'><defs><linearGradient id='g' gradientTransform='translate(.25) scale(.5)'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><path d='M2 2C2 18 18 18 18 2Z' fill='url(#g)' transform='translate(1) skewX(10)'/></svg>",
        "<svg viewBox='0 0 24 16'><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x1='6' y1='2' x2='14' y2='2'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><path d='M2 2C2 18 18 18 18 2Z' fill='url(#g)' transform='translate(1) skewX(10)'/></svg>",
        24,
        16,
    );
    try svgPixelsEqual(
        "<svg viewBox='0 0 16 16'><defs><radialGradient id='g' fr='.1'><stop stop-color='white'/><stop offset='1' stop-color='black'/></radialGradient></defs><rect x='2' y='4' width='12' height='8' fill='url(#g)'/></svg>",
        "<svg viewBox='0 0 16 16'><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='.5' cy='.5' r='.5' fr='.1' gradientTransform='matrix(12 0 0 8 2 4)'><stop stop-color='white'/><stop offset='1' stop-color='black'/></radialGradient></defs><rect x='2' y='4' width='12' height='8' fill='url(#g)'/></svg>",
        16,
        16,
    );
}

test "SVG gradient repeat reflect and concentric focal radius follow independent scalar geometry" {
    for ([_][]const u8{ "repeat", "reflect" }, 0..) |spread, which| {
        const input = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 8 4'><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x1='.5' x2='4.5' spreadMethod='{s}'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><rect width='8' height='4' fill='url(#g)'/></svg>", .{spread});
        defer allocator.free(input);
        const document = try api.Document.parse(allocator, input, .{});
        defer document.close() catch unreachable;
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4 });
        defer image.close() catch unreachable;
        try expectSvgPixel(image, 5, 2, if (which == 0) &.{ 64, 0, 191, 255 } else &.{ 191, 0, 64, 255 });
    }
    const document = try api.Document.parse(allocator, "<svg viewBox='0 0 8 8'><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='3.5' cy='3.5' r='4' fr='2'><stop stop-color='white'/><stop offset='1' stop-color='black'/></radialGradient></defs><rect width='8' height='8' fill='url(#g)'/></svg>", .{});
    defer document.close() catch unreachable;
    const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 8 });
    defer image.close() catch unreachable;
    try expectSvgPixel(image, 3, 3, &.{ 255, 255, 255, 255 });
    try expectSvgPixel(image, 5, 3, &.{ 255, 255, 255, 255 });
    try expectSvgPixel(image, 6, 3, &.{ 128, 128, 128, 255 });
    try expectSvgPixel(image, 7, 3, &.{ 0, 0, 0, 255 });
}

test "SVG attribute parse work bounds repeated long empty geometry and transform instances" {
    const whitespace = try allocator.alloc(u8, 64000);
    defer allocator.free(whitespace);
    @memset(whitespace, ' ');
    inline for ([_][]const u8{ "<g id='item' transform='{s}matrix(1 0 0 1 0 0)'/>", "<path id='item' d='{s}'/>", "<polygon id='item' points='{s}'/>" }) |definition| {
        const body = try std.fmt.allocPrint(allocator, definition, .{whitespace});
        defer allocator.free(body);
        const uses = try allocator.alloc(u8, "<use href='#item'/>".len * 128);
        defer allocator.free(uses);
        for (0..128) |i| @memcpy(uses[i * "<use href='#item'/>".len ..][0.."<use href='#item'/>".len], "<use href='#item'/>");
        const source = try std.fmt.allocPrint(allocator, "<svg><defs>{s}</defs>{s}</svg>", .{ body, uses });
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        // Empty geometry can keep vertices/scan/pixel work tiny while repeating
        // a large attribute; its byte processing has a separate cumulative cap.
        try std.testing.expectError(error.ParseWorkExceeded, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 1, .height = 1, .limits = .{ .parse_work = 256000 } }));
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 1, .height = 1, .limits = .{ .parse_work = 16 * 1024 * 1024 } });
        defer image.close() catch unreachable;
        try std.testing.expect((try image.stats()).parse_work > 8_000_000);
    }
}

test "SVG gradient allocation failures cycles limits fallback and unsupported focal geometry are explicit" {
    // An exclamation mark inside a URL token is not the important delimiter.
    try svgPixelsEqual("<svg><defs><linearGradient id='bang!'><stop stop-color='red'/></linearGradient></defs><rect width='4' height='4' style='fill: url(&quot;#bang!&quot;) !important'/></svg>", "<svg><rect width='4' height='4' fill='red'/></svg>", 4, 4);
    const source = "<svg viewBox='0 0 4 4'><defs><radialGradient id='g' fx='.4' fy='.4'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></radialGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>";
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator, input: []const u8) !void {
            const document = try api.Document.parse(a, input, .{});
            defer document.close() catch unreachable;
            const image = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 });
            try image.close();
        }
    }.run, .{source});
    const cases = [_]struct { input: []const u8, err: anyerror }{
        .{ .input = "<linearGradient id='g' href='#g'/>", .err = error.ReferenceCycle },
        .{ .input = "<radialGradient id='g' fr='-1'/>", .err = error.InvalidRadialRadius },
        .{ .input = "<radialGradient id='g' r='-1'/>", .err = error.InvalidRadialRadius },
        .{ .input = "<linearGradient id='g' x2='1px'/>", .err = error.UnsupportedBoundingBoxUnit },
    };
    for (cases) |case| {
        const input = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 4 4'><defs>{s}</defs><rect width='4' height='4' fill='url(#g)'/></svg>", .{case.input});
        defer allocator.free(input);
        const document = try api.Document.parse(allocator, input, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(case.err, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 }));
    }
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    try std.testing.expectError(error.GradientStopsFull, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .limits = .{ .gradient_stops = 1 } }));
    try svgPixelsEqual("<svg><rect width='4' height='4' fill='url(#missing) red'/></svg>", "<svg><rect width='4' height='4' fill='red'/></svg>", 4, 4);
    try svgPixelsEqual("<svg><defs><linearGradient id='g' x1='1' x2='1' spreadMethod='repeat'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>", "<svg><rect width='4' height='4' fill='blue'/></svg>", 4, 4);
}

test "gradient template stop discovery consumes the global node visit budget" {
    const source = "<svg><defs><linearGradient id='g'><title/><title/><title/><title/><title/><title/><title/><title/></linearGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>";
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    try std.testing.expectError(error.NodeWorkExceeded, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .limits = .{ .node_visits = 8 } }));
}

test "SVG coincident clip union intersection and viewport edges share sample coverage" {
    const cases = [_][]const u8{
        "<clipPath id='c'><rect x='.25' y='.25' width='4.5' height='3.5'/></clipPath>",
        "<clipPath id='c'><rect x='.25' y='.25' width='4.5' height='3.5'/><rect x='.25' y='.25' width='4.5' height='3.5'/></clipPath>",
        "<clipPath id='a'><rect x='.25' y='.25' width='4.5' height='3.5'/></clipPath><clipPath id='c' clip-path='url(#a)'><rect x='.25' y='.25' width='4.5' height='3.5'/></clipPath>",
        "<path id='p' d='M.25 .25H4.75V3.75H.25Z'/><clipPath id='c'><use href='#p'/></clipPath>",
    };
    for (cases) |definition| {
        const source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 7 5'><defs>{s}</defs><g clip-path='url(#c)'><g clip-path='url(#c)' opacity='.5'><rect x='.25' y='.25' width='4.5' height='3.5' fill='red'/></g></g></svg>", .{definition});
        defer allocator.free(source);
        try svgPixelsEqual(source, "<svg viewBox='0 0 7 5'><rect x='.25' y='.25' width='4.5' height='3.5' fill='red' opacity='.5'/></svg>", 7, 5);
    }
    try svgPixelsEqual("<svg viewBox='0 0 7 5'><svg x='.25' y='.25' width='4.5' height='3.5' viewBox='0 0 4.5 3.5'><rect width='4.5' height='3.5'/></svg></svg>", "<svg viewBox='0 0 7 5'><rect x='.25' y='.25' width='4.5' height='3.5'/></svg>", 7, 5);
    try svgPixelsEqual("<svg viewBox='0 0 7 5'><defs><clipPath id='c'><rect x='.25' y='.25' width='2.5' height='3.5'/><rect x='2' y='.25' width='2.75' height='3.5'/></clipPath></defs><rect width='7' height='5' clip-path='url(#c)'/></svg>", "<svg viewBox='0 0 7 5'><rect x='.25' y='.25' width='4.5' height='3.5'/></svg>", 7, 5);
}

test "SVG clip rules units containers transforms and CSS preserve independent geometry" {
    try svgPixelsEqual("<svg viewBox='0 0 16 12'><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect x='.25' y='.25' width='.5' height='.5'/></clipPath></defs><g transform='translate(2 2)' clip-path='url(#c)'><rect x='2' y='2' width='8' height='4'/><rect x='8' y='2' width='2' height='4'/></g></svg>", "<svg viewBox='0 0 16 12'><rect x='6' y='5' width='4' height='2'/></svg>", 16, 12);
    try svgPixelsEqual("<svg viewBox='0 0 8 8'><style>.hole {clip-rule:evenodd} rect {clip-path:url(#c)}</style><defs><clipPath id='c'><path class='hole' d='M.25 .25H7.75V7.75H.25Z M2 2H6V6H2Z'/></clipPath></defs><rect width='8' height='8'/></svg>", "<svg viewBox='0 0 8 8'><path fill-rule='evenodd' d='M.25 .25H7.75V7.75H.25Z M2 2H6V6H2Z'/></svg>", 8, 8);
    try svgPixelsEqual("<svg viewBox='0 0 8 8'><defs><clipPath id='c' transform='translate(1 1)'><rect width='4' height='4' fill='none' stroke-width='100' opacity='0'/></clipPath></defs><rect width='8' height='8' clip-path='url(#c)'/></svg>", "<svg viewBox='0 0 8 8'><rect x='1' y='1' width='4' height='4'/></svg>", 8, 8);
}

test "SVG clip failures cancellation and all allocation failures leave no partial snapshot" {
    const source = "<svg><defs><clipPath id='c'><rect x='.25' y='.25' width='4.5' height='3.5'/><circle cx='2' cy='2' r='1'/></clipPath></defs><g clip-path='url(#c)' opacity='.5'><rect width='7' height='5'/></g></svg>";
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator, input: []const u8) !void {
            const document = try api.Document.parse(a, input, .{});
            defer document.close() catch unreachable;
            const image = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 7, .height = 5 });
            try image.close();
        }
    }.run, .{source});
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "<svg><defs><clipPath id='c' clip-path='url(#c)'><rect width='4' height='4'/></clipPath></defs><rect width='4' height='4' clip-path='url(#c)'/></svg>", .err = error.ReferenceCycle },
        .{ .source = "<svg><defs><clipPath id='c'><g><rect width='4' height='4'/></g></clipPath></defs><rect width='4' height='4' clip-path='url(#c)'/></svg>", .err = error.UnsupportedClipChild },
        .{ .source = "<svg><rect width='4' height='4' clip-path='url(#missing)'/></svg>", .err = error.ReferenceNotFound },
    };
    for (cases) |case| {
        const document = try api.Document.parse(allocator, case.source, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(case.err, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 7, .height = 5 }));
    }
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    try std.testing.expectError(error.SampleWorkExceeded, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 7, .height = 5, .limits = .{ .sample_work = 1 } }));
    var cancellation: vector.Cancellation = .{};
    cancellation.request();
    try std.testing.expectError(error.Cancelled, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 7, .height = 5, .cancellation = &cancellation }));
}

test "SVG mask alpha luminance color space and group opacity have independent pixels" {
    const cases = [_]struct { attributes: []const u8, fill: []const u8, alpha: u8 }{
        .{ .attributes = "", .fill = "#808080", .alpha = 128 },
        .{ .attributes = "color-interpolation='linearRGB'", .fill = "#808080", .alpha = 55 },
        .{ .attributes = "", .fill = "#80808080", .alpha = 64 },
        .{ .attributes = "color-interpolation='linearRGB'", .fill = "#80808080", .alpha = 27 },
        .{ .attributes = "mask-type='alpha'", .fill = "#00000080", .alpha = 128 },
        .{ .attributes = "", .fill = "red", .alpha = 54 },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator, "<svg><defs><mask id='m' {s}><rect width='4' height='4' fill='{s}'/></mask></defs><g mask='url(#m)'><rect width='4' height='4' fill='red'/><rect x='1' width='3' height='4' fill='red'/></g></svg>", .{ case.attributes, case.fill });
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 });
        defer image.close() catch unreachable;
        try expectSvgPixel(image, 0, 2, &.{ 0, 0, case.alpha, case.alpha });
        try expectSvgPixel(image, 2, 2, &.{ 0, 0, case.alpha, case.alpha });
    }
}

test "SVG mask region content units nested effects and coincident region use bounded sample planes" {
    try svgPixelsEqual("<svg viewBox='0 0 12 10'><defs><mask id='m' maskContentUnits='objectBoundingBox' x='0' y='0' width='1' height='1'><rect width='.5' height='1' fill='white'/></mask></defs><rect x='2' y='2' width='8' height='6' mask='url(#m)'/></svg>", "<svg viewBox='0 0 12 10'><rect x='2' y='2' width='4' height='6'/></svg>", 12, 10);
    try svgPixelsEqual("<svg viewBox='0 0 7 5'><defs><mask id='m' maskUnits='userSpaceOnUse' x='.25' y='.25' width='4.5' height='3.5' mask-type='alpha'><rect x='.25' y='.25' width='4.5' height='3.5'/></mask></defs><rect width='7' height='5' mask='url(#m)'/></svg>", "<svg viewBox='0 0 7 5'><rect x='.25' y='.25' width='4.5' height='3.5'/></svg>", 7, 5);
    try svgPixelsEqual("<svg viewBox='0 0 8 8'><defs><clipPath id='c'><rect width='4' height='8'/></clipPath><mask id='a' mask-type='alpha'><rect width='8' height='8' opacity='.5'/></mask><mask id='b' mask-type='alpha'><g mask='url(#a)' opacity='.5'><rect width='8' height='8'/><rect width='8' height='8'/></g></mask></defs><g mask='url(#b)' clip-path='url(#c)' opacity='.5'><rect width='8' height='8'/></g></svg>", "<svg viewBox='0 0 8 8'><rect width='4' height='8' opacity='.125'/></svg>", 8, 8);
    try svgPixelsEqual("<svg><defs><mask id='m' width='0'><rect width='4' height='4' fill='white'/></mask></defs><rect width='4' height='4' mask='url(#m)'/></svg>", "<svg/>", 4, 4);
}

test "SVG masking allocation rollback cycle and scene limits include its private layers" {
    const source = "<svg><defs><mask id='m' mask-type='alpha'><g opacity='.5'><rect width='7' height='5'/></g></mask></defs><rect width='7' height='5' mask='url(#m)'/></svg>";
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator, input: []const u8) !void {
            const document = try api.Document.parse(a, input, .{});
            defer document.close() catch unreachable;
            const image = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 7, .height = 5 });
            try image.close();
        }
    }.run, .{source});
    const cyclic = try api.Document.parse(allocator, "<svg><defs><mask id='m'><rect width='4' height='4' mask='url(#m)'/></mask></defs><rect width='4' height='4' mask='url(#m)'/></svg>", .{});
    defer cyclic.close() catch unreachable;
    try std.testing.expectError(error.ReferenceCycle, cyclic.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 }));
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    try std.testing.expectError(error.LayersFull, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 7, .height = 5, .limits = .{ .layers = 1 } }));
    try std.testing.expectError(error.CapacityExceeded, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 7, .height = 5, .limits = .{ .bytes = 512 } }));
    const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 7, .height = 5 });
    defer image.close() catch unreachable;
    try std.testing.expect((try image.stats()).sample_work > 0);
    try std.testing.expect((try image.stats()).peak_bytes > (try image.stats()).owned_bytes);
}

test "root SVG transform is outside its viewBox coordinate mapping" {
    try svgPixelsEqual("<svg viewBox='0 0 8 8' transform='translate(2 1)'><rect width='2' height='2'/></svg>", "<svg viewBox='0 0 16 16'><rect x='2' y='1' width='4' height='4'/></svg>", 16, 16);
}

const RadialCase = struct { cx: f64, cy: f64, radius: f64, fx: f64, fy: f64, first: f64 };
fn radialOracle(value: RadialCase, px: f64, py: f64, spread: usize) ?f64 {
    if (value.radius == 0) return 1;
    if (value.cx == value.fx and value.cy == value.fy and value.radius == value.first) return null;
    const x: f128 = @as(f128, px) - value.fx;
    const y: f128 = @as(f128, py) - value.fy;
    const dx: f128 = @as(f128, value.cx) - value.fx;
    const dy: f128 = @as(f128, value.cy) - value.fy;
    const dr: f128 = @as(f128, value.radius) - value.first;
    const r: f128 = value.first;
    const a = dx * dx + dy * dy - dr * dr;
    const b = -2 * (x * dx + y * dy + r * dr);
    const c = x * x + y * y - r * r;
    var roots: [2]f128 = undefined;
    var count: usize = 0;
    if (a == 0) {
        if (b != 0) {
            roots[0] = -c / b;
            count = 1;
        }
    } else {
        const discriminant = b * b - 4 * a * c;
        if (discriminant >= 0) {
            roots[0] = (-b + @sqrt(discriminant)) / (2 * a);
            roots[1] = (-b - @sqrt(discriminant)) / (2 * a);
            count = 2;
        }
    }
    var best: ?f128 = null;
    for (roots[0..count]) |root| {
        if (r + root * dr < 0) continue;
        if (best == null or root > best.?) best = root;
    }
    var t = best orelse {
        if (a == 0 and r == 0 and dr > 0) return if (spread == 0) 1 else 0.5;
        return null;
    };
    switch (spread) {
        0 => t = std.math.clamp(t, 0, 1),
        1 => t = @mod(t, 1),
        2 => {
            t = @mod(t, 2);
            if (t > 1) t = 2 - t;
        },
        else => unreachable,
    }
    return @floatCast(t);
}

test "SVG general radial circles match independent f128 cone roots and transparent regions" {
    const cases = [_]RadialCase{
        .{ .cx = 5.5, .cy = 4.5, .radius = 4, .fx = 5.5, .fy = 4.5, .first = 1 },
        .{ .cx = 3.5, .cy = 4.5, .radius = 2, .fx = 8.5, .fy = 4.5, .first = 0.75 },
        .{ .cx = 3.5, .cy = 4.5, .radius = 2, .fx = 6.5, .fy = 4.5, .first = 3 },
        .{ .cx = 5.5, .cy = 4.5, .radius = 2, .fx = 5.5, .fy = 4.5, .first = 4 },
        .{ .cx = 4.5, .cy = 4.5, .radius = 2, .fx = 3.5, .fy = 4.5, .first = 2 },
        .{ .cx = 3.5, .cy = 4.5, .radius = 2, .fx = 5.5, .fy = 4.5, .first = 0 },
        .{ .cx = 4.5, .cy = 4.5, .radius = 2, .fx = 3.5, .fy = 4.5, .first = 4 },
        .{ .cx = 1.5, .cy = 1.5, .radius = 5, .fx = 4.5, .fy = 5.5, .first = 0 },
        .{ .cx = 5.5, .cy = 4.5, .radius = 2, .fx = 5.5, .fy = 4.5, .first = 2 },
        .{ .cx = 5.5, .cy = 4.5, .radius = 0, .fx = 3.5, .fy = 4.5, .first = 2 },
    };
    for (cases, 0..) |case, case_index| for ([_][]const u8{ "pad", "repeat", "reflect" }, 0..) |spread, spread_index| {
        const source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 12 10'><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='{d}' cy='{d}' r='{d}' fx='{d}' fy='{d}' fr='{d}' spreadMethod='{s}'><stop stop-color='white'/><stop offset='1' stop-color='black'/></radialGradient></defs><rect width='12' height='10' fill='url(#g)'/></svg>", .{ case.cx, case.cy, case.radius, case.fx, case.fy, case.first, spread });
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 12, .height = 10 });
        defer image.close() catch unreachable;
        const pixels = image.pixels;
        for (0..10) |y| for (0..12) |x| {
            const t = radialOracle(case, @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5, spread_index);
            const expected: u8 = if (t) |amount| @intFromFloat(@round((1 - amount) * 255)) else 0;
            const alpha: u8 = if (t != null) 255 else 0;
            const pixel = pixels[(y * 12 + x) * 4 ..][0..4];
            if (@abs(@as(i32, pixel[0]) - expected) > 1 or pixel[3] != alpha) {
                std.debug.print("radial case={d} spread={s} point=({d},{d}) expected={d}/{d} actual={any}\n", .{ case_index, spread, x, y, expected, alpha, pixel });
                return error.RadialOracleMismatch;
            }
        };
    };
}

test "SVG group clips retain the documented per paint antialiasing boundary" {
    const document = try api.Document.parse(allocator, "<svg><defs><clipPath id='c'><rect x='.5' width='3' height='4'/></clipPath></defs><g clip-path='url(#c)'><rect width='4' height='4'/><rect width='4' height='4'/></g></svg>", .{});
    defer document.close() catch unreachable;
    const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 });
    defer image.close() catch unreachable;
    // Each paint gets the same eight coverage samples. Source-over combines
    // their quantized alpha (192), not a full-scene sample-color plane (128).
    try expectSvgPixel(image, 0, 1, &.{ 0, 0, 0, 192 });
}

test "SVG radial semantic cases choose the last valid circle and tangent spread limit" {
    const cases = [_]struct { attributes: []const u8, x: usize, y: usize, pixel: [4]u8 }{
        // Equal-radius circles translated along x: x=3.5 lies on two circles,
        // t=-1 and t=3. The last valid circle is t=3, the black pad color.
        .{ .attributes = "cx='2.5' cy='2.5' r='2' fx='1.5' fy='2.5' fr='2'", .x = 3, .y = 2, .pixel = .{ 0, 0, 0, 255 } },
        // Shrinking concentric circles r(t)=4-2t: distance3 means t=.5.
        .{ .attributes = "cx='2.5' cy='2.5' r='2' fx='2.5' fy='2.5' fr='4'", .x = 5, .y = 2, .pixel = .{ 128, 128, 128, 255 } },
        // A point far perpendicular to an external-focus cone has no circle.
        .{ .attributes = "cx='1.5' cy='2.5' r='1' fx='5.5' fy='2.5' fr='0'", .x = 5, .y = 7, .pixel = .{ 0, 0, 0, 0 } },
        // Tangent point focus=(4.5,2.5): beyond it, SVG pad is the last color,
        // repeat/reflect are the offset-weighted average rather than clear.
        .{ .attributes = "cx='2.5' cy='2.5' r='2' fx='4.5' fy='2.5'", .x = 6, .y = 2, .pixel = .{ 0, 0, 0, 255 } },
        .{ .attributes = "cx='2.5' cy='2.5' r='2' fx='4.5' fy='2.5' spreadMethod='repeat'", .x = 6, .y = 2, .pixel = .{ 128, 128, 128, 255 } },
        .{ .attributes = "cx='2.5' cy='2.5' r='2' fx='4.5' fy='2.5' spreadMethod='reflect'", .x = 4, .y = 2, .pixel = .{ 128, 128, 128, 255 } },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator, "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' {s}><stop stop-color='white'/><stop offset='1' stop-color='black'/></radialGradient></defs><rect width='8' height='8' fill='url(#g)'/></svg>", .{case.attributes});
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 8 });
        defer image.close() catch unreachable;
        try expectSvgPixel(image, case.x, case.y, &case.pixel);
    }
}

test "SVG tangent radial limit averages offsets in its selected interpolation space" {
    for ([_][]const u8{ "", "color-interpolation='linearRGB'" }, 0..) |attributes, which| {
        const source = try std.fmt.allocPrint(allocator, "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='2.5' cy='2.5' r='2' fx='4.5' fy='2.5' spreadMethod='repeat' {s}><stop stop-color='white'/><stop offset='.25' stop-color='white'/><stop offset='.25' stop-color='black'/><stop offset='1' stop-color='black'/></radialGradient></defs><rect width='8' height='8' fill='url(#g)'/></svg>", .{attributes});
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 8 });
        defer image.close() catch unreachable;
        const value: u8 = if (which == 0) 64 else 137;
        try expectSvgPixel(image, 6, 2, &.{ value, value, value, 255 });
    }
    try svgPixelsEqual("<svg viewBox='0 0 16 16'><defs><radialGradient id='g' cx='.5' cy='.5' r='.5' fx='1.1' fy='.2' fr='.25' spreadMethod='reflect'><stop stop-color='#f008'/><stop offset='1' stop-color='blue'/></radialGradient></defs><rect x='2' y='4' width='12' height='8' transform='skewX(5)' fill='url(#g)'/></svg>", "<svg viewBox='0 0 16 16'><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='.5' cy='.5' r='.5' fx='1.1' fy='.2' fr='.25' gradientTransform='matrix(12 0 0 8 2 4)' spreadMethod='reflect'><stop stop-color='#f008'/><stop offset='1' stop-color='blue'/></radialGradient></defs><rect x='2' y='4' width='12' height='8' transform='skewX(5)' fill='url(#g)'/></svg>", 16, 16);
}

test "SVG effect references and explicitly unsupported definition capabilities fail clearly" {
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='2.5' cy='2.5' r='3' fx='4.5' fy='2.5' fr='1'><stop/></radialGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>", .err = error.UnsupportedRadialFocus },
        .{ .source = "<svg><rect width='4' height='4' style='clip-path:url(#c) rgb(0,0,0)'/></svg>", .err = error.InvalidEffectReference },
        .{ .source = "<svg><defs><mask id='m' transform='translate(1)'><rect width='4' height='4'/></mask></defs><rect width='4' height='4' mask='url(#m)'/></svg>", .err = error.UnsupportedMaskTransform },
        .{ .source = "<svg><defs><mask id='m' mask='url(#m)'><rect width='4' height='4'/></mask></defs><rect width='4' height='4' mask='url(#m)'/></svg>", .err = error.ReferenceCycle },
        .{ .source = "<svg><defs><clipPath id='c' mask='url(#m)'/></defs><rect width='4' height='4' clip-path='url(#c)'/></svg>", .err = error.UnsupportedClipContainerEffect },
        .{ .source = "<svg><defs><mask id='m' maskUnits='invalid'/></defs><rect width='4' height='4' mask='url(#m)'/></svg>", .err = error.InvalidCoordinateUnits },
        .{ .source = "<svg><defs><mask id='m' width='-1'/></defs><rect width='4' height='4' mask='url(#m)'/></svg>", .err = error.InvalidMaskRegion },
    };
    for (cases) |case| {
        const document = try api.Document.parse(allocator, case.source, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(case.err, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 }));
    }
}

test "SVG nonzero underflowing gradient vectors do not become zero-length constant paints" {
    const document = try api.Document.parse(allocator, "<svg><defs><linearGradient id='g' gradientUnits='userSpaceOnUse' x1='0' y1='0' x2='1e-200' y2='0' spreadMethod='repeat'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>", .{});
    defer document.close() catch unreachable;
    try std.testing.expectError(error.UnsupportedGradientPrecision, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 }));
}

test "SVG clip use rejects indirect and container targets while direct silhouettes stay valid" {
    const definitions = [_][]const u8{
        "<path id='p' d='M0 0H4V4H0Z'/><use id='u' href='#p'/><clipPath id='c'><use href='#u'/></clipPath>",
        "<g id='g'><rect width='4' height='4'/></g><clipPath id='c'><use href='#g'/></clipPath>",
        "<symbol id='s'><rect width='4' height='4'/></symbol><clipPath id='c'><use href='#s'/></clipPath>",
    };
    for (definitions) |definition| {
        const source = try std.fmt.allocPrint(allocator, "<svg><defs>{s}</defs><rect width='4' height='4' clip-path='url(#c)'/></svg>", .{definition});
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(error.InvalidClipUseTarget, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4 }));
    }
    try svgPixelsEqual("<svg><defs><path id='p' d='M.5 .5H3.5V3.5H.5Z'/><clipPath id='c'><use href='#p'/></clipPath></defs><rect width='4' height='4' clip-path='url(#c)'/></svg>", "<svg><rect x='.5' y='.5' width='3' height='3'/></svg>", 4, 4);
}

test "SVG tangent repeating radial rejects variable alpha without changing supported spreads" {
    const cases = [_]struct { spread: []const u8, focus: []const u8, stops: []const u8, rejected: bool }{
        .{ .spread = "repeat", .focus = "4.5", .stops = "<stop stop-color='red' stop-opacity='0'/><stop offset='1' stop-color='blue'/>", .rejected = true },
        .{ .spread = "reflect", .focus = "4.5", .stops = "<stop stop-color='red'/><stop offset='1' stop-color='blue' stop-opacity='.5'/>", .rejected = true },
        .{ .spread = "pad", .focus = "4.5", .stops = "<stop stop-color='red' stop-opacity='0'/><stop offset='1' stop-color='blue'/>", .rejected = false },
        .{ .spread = "repeat", .focus = "3.5", .stops = "<stop stop-color='red' stop-opacity='0'/><stop offset='1' stop-color='blue'/>", .rejected = false },
        .{ .spread = "reflect", .focus = "5.5", .stops = "<stop stop-color='red' stop-opacity='0'/><stop offset='1' stop-color='blue'/>", .rejected = false },
        .{ .spread = "repeat", .focus = "4.5", .stops = "<stop stop-color='red' stop-opacity='.5'/><stop offset='1' stop-color='blue' stop-opacity='.5'/>", .rejected = false },
        .{ .spread = "reflect", .focus = "4.5", .stops = "<stop stop-color='red' stop-opacity='0'/><stop offset='1' stop-color='blue' stop-opacity='0'/>", .rejected = false },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator, "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='2.5' cy='2.5' r='2' fx='{s}' fy='2.5' spreadMethod='{s}'>{s}</radialGradient></defs><rect width='8' height='8' fill='url(#g)'/></svg>", .{ case.focus, case.spread, case.stops });
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        if (case.rejected) {
            try std.testing.expectError(error.UnsupportedRadialAverage, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 8 }));
        } else {
            const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 8 });
            defer image.close() catch unreachable;
            if (std.mem.eql(u8, case.spread, "pad")) try expectSvgPixel(image, 6, 2, &.{ 255, 0, 0, 255 });
        }
    }
}
