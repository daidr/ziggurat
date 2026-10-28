const std = @import("std");
const view = @import("ziggurat_view");
const lay = @import("layout.zig");

const testing = std.testing;
const Layout = lay.Layout;

/// Ten DIP per byte, and a line 1.5 times the font size.
fn measureFixed(_: ?*anyopaque, text: []const u8, font: view.Font) view.Size {
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 10 * font.size / 16, .height = font.size * 1.5 };
}
fn fixedMeasure(_: ?*anyopaque, text: []const u8) view.Size {
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 10, .height = 24 };
}
const measurer: view.Measurer = .{ .measure = fixedMeasure, .measure_font = measureFixed };

fn pieceX(l: *const Layout, rune: u32) f32 {
    for (l.pieces.items) |p| if (p.rune == rune) return l.lines.items[p.line].x + p.x;
    unreachable;
}

test "justified lines stretch to the width, but the last" {
    var l = Layout.init(testing.allocator);
    defer l.deinit();
    try l.build(&.{.{ .text = "aa bb cc dd ee" }}, .{ .measurer = measurer, .width = 100, .justify = true });
    try testing.expectEqual(@as(usize, 2), l.lines.items.len);
    // "aa bb cc" is 80 wide: its two spaces take 10 more each.
    try testing.expectEqual(@as(f32, 100), l.lines.items[0].width);
    try testing.expectEqual(@as(f32, 40), pieceX(&l, 3));
    try testing.expectEqual(@as(f32, 80), pieceX(&l, 6));
    // Carets and selection follow the words.
    try testing.expectEqual(@as(f32, 90), l.caret(7, .downstream).x);
    try testing.expectEqual(@as(u32, 7), l.hit(.{ .x = 89, .y = 5 }).rune);
    try testing.expectEqual(@as(f32, 50), l.lines.items[1].width);
    try testing.expectEqual(@as(f32, 30), pieceX(&l, 12));

    // Ideographs widen the room after them; a centered last line stays
    // centered.
    try l.build(&.{.{ .text = "汉字测试" }}, .{ .measurer = measurer, .width = 100, .justify = true, .@"align" = .center });
    try testing.expectEqual(@as(f32, 35), pieceX(&l, 1));
    try testing.expectEqual(@as(f32, 70), pieceX(&l, 2));
    try testing.expectEqual(@as(f32, 35), l.lines.items[1].x);
}

test "the first line is indented and wraps narrower" {
    var l = Layout.init(testing.allocator);
    defer l.deinit();
    try l.build(&.{.{ .text = "aa bb cc dd" }}, .{ .measurer = measurer, .width = 100, .indent = 20 });
    try testing.expectEqual(@as(usize, 2), l.lines.items.len);
    try testing.expectEqual(@as(f32, 20), l.caret(0, .downstream).x);
    try testing.expectEqual(@as(u32, 9), l.lines.items[1].start);
    try testing.expectEqual(@as(f32, 0), l.caret(9, .downstream).x);
    try testing.expectEqual(@as(u32, 0), l.hit(.{ .x = 5, .y = 5 }).rune);
    // A word too long for the indented line breaks at its room.
    try l.build(&.{.{ .text = "abcdefghijkl" }}, .{ .measurer = measurer, .width = 100, .indent = 20 });
    try testing.expectEqual(@as(u32, 8), l.lines.items[0].end);
    // Unless words may not break: it overflows.
    try l.build(&.{.{ .text = "abcdefghijkl" }}, .{ .measurer = measurer, .width = 100, .indent = 20, .no_break_words = true });
    try testing.expectEqual(@as(usize, 1), l.lines.items.len);
    try testing.expectEqual(@as(f32, 140), l.width);
}

test "a soft hyphen takes no room, and shows where the line breaks at it" {
    var l = Layout.init(testing.allocator);
    defer l.deinit();
    try l.build(&.{.{ .text = "go ordi\u{ad}nary" }}, .{ .measurer = measurer });
    try testing.expectEqual(@as(f32, 30 + 40 + 40), l.width);
    try testing.expectEqual(@as(f32, 70), l.caret(8, .downstream).x);
    try testing.expectEqual(@as(f32, 70), l.caret(7, .downstream).x);
    // At 75 "ordi" fits but its hyphen does not: it starts the next line,
    // which breaks after it, its hyphen showing.
    try l.build(&.{.{ .text = "go ordi\u{ad}nary" }}, .{ .measurer = measurer, .width = 75 });
    try testing.expectEqual(@as(usize, 3), l.lines.items.len);
    try testing.expectEqual(@as(u32, 3), l.lines.items[1].start);
    try testing.expectEqual(@as(u32, 8), l.lines.items[1].end);
    try testing.expectEqual(@as(f32, 50), l.lines.items[1].width);
    const piece = l.pieces.items[l.lines.items[1].first_piece];
    try testing.expect(piece.hyphen);
    try testing.expectEqualStrings("ordi", l.visibleText(piece));
}

test "a baseline shift and a line height make room on the line" {
    var l = Layout.init(testing.allocator);
    defer l.deinit();
    try l.build(&.{ .{ .text = "x" }, .{ .text = "2", .style = .{ .font = .{ .size = 10 }, .baseline_shift = 10 } }, .{ .text = "y", .style = .{ .font = .{ .size = 10 }, .baseline_shift = -3 } } }, .{ .measurer = measurer, .font = .{ .size = 16 } });
    const line = l.lines.items[0];
    try testing.expectEqual(@as(f32, 21), line.ascent);
    try testing.expectEqual(@as(f32, 7), line.descent);
    try testing.expectEqual(@as(f32, 21), line.baseline);
    try l.build(&.{.{ .text = "x" }}, .{ .measurer = measurer, .font = .{ .size = 20 }, .line_height = 2 });
    try testing.expectEqual(@as(f32, 40), l.height);
    // A span of 16 DIP is 24 tall: 8 above it on a line of 40.
    try testing.expectApproxEqAbs(@as(f32, 8 + 17.6), l.lines.items[0].baseline, 0.001);
    try testing.expectEqual(@as(f32, 40), l.caret(0, .downstream).height);
}
