const std = @import("std");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const syntax = @import("ziggurat_code_syntax");
const Highlighting = @import("highlight.zig").Highlighting;
const MultiCursor = @import("multicursor.zig").Commands;
const GitGutter = @import("git_gutter.zig").GitGutter;

const Fixture = struct {
    document: *d.Document,
    engine: *t.Engine,
    adapter: *editing.Adapter,
    fn init(source: []const u8) !Fixture {
        const allocator = std.testing.allocator;
        const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
        errdefer document.close() catch unreachable;
        const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        errdefer engine.close() catch unreachable;
        const adapter = try editing.Adapter.create(allocator, document, engine, .{});
        return .{ .document = document, .engine = engine, .adapter = adapter };
    }
    fn deinit(self: *Fixture) void {
        self.adapter.close() catch unreachable;
        self.engine.close() catch unreachable;
        self.document.close() catch unreachable;
    }
    fn text(self: *Fixture, buffer: []u8) []const u8 {
        const length = self.document.byteLength() catch unreachable;
        return buffer[0 .. self.document.read(.{ .start = 0, .end = length }, buffer) catch unreachable];
    }
    fn select(self: *Fixture, anchor: usize, caret: usize) !void {
        _ = try self.adapter.setSelections(&.{.{ .anchor = anchor, .caret = caret }}, 0);
    }
    fn expectSelections(self: *Fixture, expected: []const [2]usize, primary: usize) !void {
        var buffer: [16]d.Selection = undefined;
        const view = try self.document.selections(&buffer);
        try std.testing.expectEqual(expected.len, view.items.len);
        for (expected, view.items) |want, got| {
            try std.testing.expectEqual(want[0], got.anchor);
            try std.testing.expectEqual(want[1], got.caret);
        }
        try std.testing.expectEqual(primary, view.primary);
    }
};

test "visible lines become foreground markers that follow edits" {
    var fixture = try Fixture.init("const a = 1; // one\nvar b = \"two\";\n");
    defer fixture.deinit();
    var highlighting = try Highlighting.init(std.testing.allocator, &syntax.languages.zig, syntax.Theme.light(), .{});
    defer highlighting.deinit();
    const find: editing.RangeMarker = .{ .range = .{ .start = 6, .end = 7 }, .kind = .underline, .color = 0xd08a00 };
    var result = try highlighting.update(fixture.adapter, 0, 10, &.{find});
    try std.testing.expect(result.ready and result.current);
    const theme = syntax.Theme.light();
    const markers = highlighting.markers.items;
    try std.testing.expectEqual(editing.RangeMarkerKind.foreground, markers[0].kind);
    try std.testing.expectEqual(@as(usize, 0), markers[0].range.start);
    try std.testing.expectEqual(@as(usize, 5), markers[0].range.end);
    try std.testing.expectEqual(theme.color(.keyword), markers[0].color);
    var saw_find = false;
    var saw_comment = false;
    for (markers, 0..) |marker, index| {
        if (index > 0) try std.testing.expect(marker.range.start >= markers[index - 1].range.start);
        if (marker.kind == .underline) saw_find = true;
        if (marker.color == theme.color(.comment)) saw_comment = true;
    }
    try std.testing.expect(saw_find and saw_comment);
    // An edit moves the markers with the text.
    _ = try fixture.adapter.replace(.{ .start = 0, .end = 5 }, "pub const");
    result = try highlighting.update(fixture.adapter, 0, 10, &.{});
    try std.testing.expect(result.current);
    try std.testing.expectEqual(@as(usize, 3), highlighting.markers.items[0].range.end);
    try std.testing.expectEqual(@as(usize, 4), highlighting.markers.items[1].range.start);
    try std.testing.expectEqual(@as(usize, 9), highlighting.markers.items[1].range.end);
    // A later line only: the first visible line starts the markers.
    result = try highlighting.update(fixture.adapter, 1, 1, &.{});
    const second = try fixture.document.line(1);
    try std.testing.expect(highlighting.markers.items[0].range.start >= second.start);
}

test "select next, all matches, carets above and below, and selection undo" {
    var fixture = try Fixture.init("foo bar foo baz foo\nfoobar\n\tfoo x\n");
    defer fixture.deinit();
    var commands = MultiCursor.init(std.testing.allocator, .{});
    defer commands.deinit();
    try fixture.select(1, 1);
    try std.testing.expect(try commands.selectNext(fixture.adapter, false));
    try fixture.expectSelections(&.{.{ 0, 3 }}, 0);
    try std.testing.expect(try commands.selectNext(fixture.adapter, false));
    try fixture.expectSelections(&.{ .{ 0, 3 }, .{ 8, 11 } }, 1);
    try std.testing.expect(try commands.selectNext(fixture.adapter, false));
    try std.testing.expect(try commands.selectNext(fixture.adapter, false));
    // Whole words only: "foobar" is skipped, the tab-indented one taken.
    try fixture.expectSelections(&.{ .{ 0, 3 }, .{ 8, 11 }, .{ 16, 19 }, .{ 28, 31 } }, 3);
    try std.testing.expect(!try commands.selectNext(fixture.adapter, false));
    try std.testing.expect(try commands.undoSelection(fixture.adapter, false));
    try fixture.expectSelections(&.{ .{ 0, 3 }, .{ 8, 11 }, .{ 16, 19 } }, 2);
    try std.testing.expect(try commands.undoSelection(fixture.adapter, true));
    try fixture.expectSelections(&.{ .{ 0, 3 }, .{ 8, 11 }, .{ 16, 19 }, .{ 28, 31 } }, 3);
    try std.testing.expect(try commands.single(fixture.adapter));
    try fixture.expectSelections(&.{.{ 28, 31 }}, 0);
    // Previous occurrence wraps backward.
    try std.testing.expect(try commands.selectNext(fixture.adapter, true));
    try fixture.expectSelections(&.{ .{ 16, 19 }, .{ 28, 31 } }, 0);

    try fixture.select(9, 9);
    try std.testing.expect(try commands.selectAllMatches(fixture.adapter));
    try fixture.expectSelections(&.{ .{ 0, 3 }, .{ 8, 11 }, .{ 16, 19 }, .{ 28, 31 } }, 1);

    // Carets keep the primary's column across a tab, and going back
    // removes them newest first.
    try fixture.select(5, 5);
    try std.testing.expect(try commands.addCaret(fixture.adapter, .below));
    try fixture.expectSelections(&.{ .{ 5, 5 }, .{ 25, 25 } }, 1);
    try std.testing.expect(try commands.addCaret(fixture.adapter, .below));
    try fixture.expectSelections(&.{ .{ 5, 5 }, .{ 25, 25 }, .{ 29, 29 } }, 2);
    try std.testing.expect(try commands.addCaret(fixture.adapter, .above));
    try fixture.expectSelections(&.{ .{ 5, 5 }, .{ 25, 25 } }, 1);
    try std.testing.expect(try commands.addCaret(fixture.adapter, .above));
    try fixture.expectSelections(&.{.{ 5, 5 }}, 0);
    try std.testing.expect(!try commands.addCaret(fixture.adapter, .above));
}

test "grow and shrink by syntax, split lines and go to brackets" {
    const source = "call(a, \"one two\", [b])\nnext\n";
    var fixture = try Fixture.init(source);
    defer fixture.deinit();
    var highlighter = try syntax.Highlighter.init(std.testing.allocator, syntax.languages.go.tokenizer.?);
    defer highlighter.deinit();
    _ = try highlighter.highlight(syntax.highlighter.SliceLines{ .text = source }, 10, 100);
    var commands = MultiCursor.init(std.testing.allocator, .{});
    defer commands.deinit();
    commands.setSyntax(&syntax.languages.go, &highlighter);
    const one = std.mem.indexOf(u8, source, "one").?;
    try fixture.select(one + 1, one + 1);
    const steps = [_][2]usize{
        .{ one, one + 3 }, // the word
        .{ one, one + 7 }, // the string's inside
        .{ one - 1, one + 8 }, // with its quotes
        .{ 5, 22 }, // the parentheses' inside
        .{ 4, 23 }, // with them
        .{ 0, 23 }, // the line
        .{ 0, source.len }, // everything
    };
    for (steps) |step| {
        try std.testing.expect(try commands.selectLarger(fixture.adapter));
        try fixture.expectSelections(&.{step}, 0);
    }
    try std.testing.expect(!try commands.selectLarger(fixture.adapter));
    var back = steps.len - 1;
    while (back > 0) {
        back -= 1;
        try std.testing.expect(try commands.selectSmaller(fixture.adapter));
        try fixture.expectSelections(&.{steps[back]}, 0);
    }
    try std.testing.expect(try commands.selectSmaller(fixture.adapter));
    try fixture.expectSelections(&.{.{ one + 1, one + 1 }}, 0);

    try fixture.select(2, 27);
    try std.testing.expect(try commands.splitIntoLines(fixture.adapter));
    try fixture.expectSelections(&.{ .{ 2, 23 }, .{ 24, 27 } }, 1);

    // From inside the brackets to the closing one, then back inside.
    const b = std.mem.indexOfScalar(u8, source, 'b').?;
    try fixture.select(b, b);
    try std.testing.expect(try commands.toBracket(fixture.adapter, false));
    try fixture.expectSelections(&.{.{ b + 1, b + 1 }}, 0);
    try std.testing.expect(try commands.toBracket(fixture.adapter, true));
    try fixture.expectSelections(&.{.{ b + 1, b }}, 0);
    try fixture.select(b, b);
    const pair = (try commands.bracketsAround(fixture.adapter)).?;
    try std.testing.expectEqual(b - 1, pair.open);
}

test "the gutter marks changes against a base and reverts them" {
    var fixture = try Fixture.init("one\nTWO\nthree\nfour\n");
    defer fixture.deinit();
    var gutter = GitGutter.init(std.testing.allocator, .{});
    defer gutter.deinit();
    try std.testing.expect(!try gutter.update(fixture.document));
    try gutter.setBase("one\ntwo\nthree\n");
    try std.testing.expect(try gutter.update(fixture.document));
    try std.testing.expect(!try gutter.update(fixture.document));
    try std.testing.expectEqual(@as(usize, 2), gutter.hunks().len);
    try std.testing.expectEqual(.unchanged, gutter.status(0));
    try std.testing.expectEqual(.modified, gutter.status(1));
    try std.testing.expectEqual(.unchanged, gutter.status(2));
    try std.testing.expectEqual(.added, gutter.status(3));
    try std.testing.expectEqual(@as(?usize, 1), gutter.hunkTarget(0, .next));
    try std.testing.expectEqual(@as(?usize, 3), gutter.hunkTarget(1, .next));
    try std.testing.expectEqual(@as(?usize, 1), gutter.hunkTarget(3, .next));
    try std.testing.expectEqual(@as(?usize, 3), gutter.hunkTarget(1, .previous));
    try fixture.select(0, 0);
    try std.testing.expect(try gutter.goToHunk(fixture.adapter, .next));
    try fixture.expectSelections(&.{.{ 4, 4 }}, 0);
    try std.testing.expect(try gutter.revertHunks(fixture.adapter));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\n", fixture.text(&buffer));
    _ = try gutter.update(fixture.document);
    try std.testing.expectEqual(@as(usize, 1), gutter.hunks().len);
    // Deleting a line leaves a wedge on the line after it.
    _ = try fixture.adapter.replace(.{ .start = 4, .end = 8 }, "");
    _ = try gutter.update(fixture.document);
    try std.testing.expectEqual(.deleted_above, gutter.status(1));
    try fixture.select(4, 4);
    try std.testing.expect(try gutter.revertHunks(fixture.adapter));
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\n", fixture.text(&buffer));
    try gutter.setBase(null);
    try std.testing.expectEqual(@as(usize, 0), gutter.hunks().len);
}
