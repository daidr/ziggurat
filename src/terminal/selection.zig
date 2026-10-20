//! Text selected with the pointer: by cell, by word or by line, held in
//! absolute rows so it stays on its text as output scrolls, and copied out
//! with wrapped lines joined and trailing blanks dropped.
const std = @import("std");
const screen_module = @import("screen.zig");

const Screen = screen_module.Screen;
pub const Position = screen_module.Position;

pub const Unit = enum { cell, word, line };

/// Characters that end a word besides spaces.
pub const word_separators = " \t()[]{}<>'\"`,;|│";

pub const Range = struct {
    start: Position,
    /// Inclusive.
    end: Position,

    pub fn contains(self: Range, at: Position) bool {
        return at.order(self.start) != .lt and at.order(self.end) != .gt;
    }
};

pub const Selection = struct {
    anchor: Position,
    head: Position,
    unit: Unit = .cell,
    /// The pointer is still dragging it.
    dragging: bool = true,

    /// The selected cells, grown to whole words or lines.
    pub fn range(self: Selection, screen: *const Screen) Range {
        var start = self.anchor;
        var end = self.head;
        if (start.order(end) == .gt) std.mem.swap(Position, &start, &end);
        switch (self.unit) {
            .cell => {},
            .word => {
                start = wordStart(screen, start);
                end = wordEnd(screen, end);
            },
            .line => {
                start = lineStart(screen, start);
                end = lineEnd(screen, end);
            },
        }
        return .{ .start = start, .end = end };
    }

    /// Nothing is selected by a press without a drag.
    pub fn empty(self: Selection) bool {
        return self.unit == .cell and self.anchor.row == self.head.row and self.anchor.col == self.head.col;
    }
};

fn cellAt(screen: *const Screen, at: Position) ?screen_module.Cell {
    const line = screen.rowAt(at.row) orelse return null;
    if (at.col >= line.cells.len) return null;
    return line.cells[at.col];
}

fn isWord(screen: *const Screen, at: Position) bool {
    const cell = cellAt(screen, at) orelse return false;
    if (cell.wide == .spacer) return true;
    if (cell.cp == 0) return false;
    var bytes: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cell.cp, &bytes) catch return false;
    return std.mem.indexOf(u8, word_separators, bytes[0..n]) == null;
}

fn wordStart(screen: *const Screen, at: Position) Position {
    if (!isWord(screen, at)) return at;
    var p = at;
    while (true) {
        if (p.col == 0) {
            // Words continue from the end of a wrapped line above.
            if (p.row == 0) return p;
            const above = screen.rowAt(p.row - 1) orelse return p;
            if (!above.wrapped or above.cells.len == 0) return p;
            const prev: Position = .{ .row = p.row - 1, .col = @intCast(above.cells.len - 1) };
            if (!isWord(screen, prev)) return p;
            p = prev;
            continue;
        }
        const prev: Position = .{ .row = p.row, .col = p.col - 1 };
        if (!isWord(screen, prev)) return p;
        p = prev;
    }
}

fn wordEnd(screen: *const Screen, at: Position) Position {
    if (!isWord(screen, at)) return at;
    var p = at;
    while (true) {
        const line = screen.rowAt(p.row) orelse return p;
        if (p.col + 1 >= line.cells.len) {
            if (!line.wrapped) return p;
            const next: Position = .{ .row = p.row + 1, .col = 0 };
            if (!isWord(screen, next)) return p;
            p = next;
            continue;
        }
        const next: Position = .{ .row = p.row, .col = p.col + 1 };
        if (!isWord(screen, next)) return p;
        p = next;
    }
}

fn lineStart(screen: *const Screen, at: Position) Position {
    var row = at.row;
    while (row > 0) {
        const above = screen.rowAt(row - 1) orelse break;
        if (!above.wrapped) break;
        row -= 1;
    }
    return .{ .row = row, .col = 0 };
}

fn lineEnd(screen: *const Screen, at: Position) Position {
    var row = at.row;
    while (true) {
        const line = screen.rowAt(row) orelse break;
        if (!line.wrapped or screen.rowAt(row + 1) == null) break;
        row += 1;
    }
    return .{ .row = row, .col = std.math.maxInt(u16) };
}

/// The text of `range`, wrapped lines joined and others ended by '\n'.
pub fn text(screen: *const Screen, range: Range, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var row = @max(range.start.row, screen.firstRow());
    while (row <= range.end.row) : (row += 1) {
        const line = screen.rowAt(row) orelse break;
        const from: usize = if (row == range.start.row) range.start.col else 0;
        const to: usize = if (row == range.end.row) @min(@as(usize, range.end.col) + 1, line.cells.len) else line.cells.len;
        const begin = out.items.len;
        var x = from;
        while (x < to) : (x += 1) {
            const cell = line.cells[x];
            if (cell.wide == .spacer) continue;
            var bytes: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(if (cell.cp == 0) ' ' else cell.cp, &bytes);
            try out.appendSlice(allocator, bytes[0..n]);
        }
        const joined = line.wrapped and to == line.cells.len;
        if (!joined) {
            // Trailing blanks of a line are padding, not text.
            while (out.items.len > begin and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
            if (row != range.end.row) try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

fn feed(screen: *Screen, bytes: []const u8) void {
    var view = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (view.nextCodepoint()) |cp| switch (cp) {
        '\n' => screen.nextLine(),
        else => screen.print(cp),
    };
}

test "cell, word and line selections copy their text" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 8, .rows = 4, .scrollback = 10 });
    defer screen.deinit();
    feed(&screen, "foo bar.baz\nnext   \n中文 ok");
    const base = screen.screenRow(0);
    var selection: Selection = .{ .anchor = .{ .row = base, .col = 4 }, .head = .{ .row = base + 1, .col = 2 } };
    const cells = try text(&screen, selection.range(&screen), std.testing.allocator);
    defer std.testing.allocator.free(cells);
    // The wrapped line joins its continuation.
    try std.testing.expectEqualStrings("bar.baz", cells);
    selection.unit = .word;
    selection.anchor = .{ .row = base, .col = 5 };
    selection.head = selection.anchor;
    const word = try text(&screen, selection.range(&screen), std.testing.allocator);
    defer std.testing.allocator.free(word);
    try std.testing.expectEqualStrings("bar.baz", word);
    selection.unit = .line;
    selection.head = .{ .row = base + 2, .col = 0 };
    const lines = try text(&screen, selection.range(&screen), std.testing.allocator);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqualStrings("foo bar.baz\nnext", lines);
    // A wide character's spacer belongs to it.
    selection = .{ .anchor = .{ .row = base + 3, .col = 1 }, .head = .{ .row = base + 3, .col = 1 }, .unit = .word };
    const wide = try text(&screen, selection.range(&screen), std.testing.allocator);
    defer std.testing.allocator.free(wide);
    try std.testing.expectEqualStrings("中文", wide);
    try std.testing.expect(!selection.empty());
    try std.testing.expect(selection.range(&screen).contains(.{ .row = base + 3, .col = 2 }));
}
