//! Searching the screen and the scrollback for text. Matching is exact but
//! for the case of ASCII letters, and goes across soft wraps, so a match
//! may span rows. Matches keep absolute rows, so they stay put as output
//! scrolls; `update` searches again when the screen changed, and the
//! selected match stays selected while it is there.
const std = @import("std");
const zio = @import("ziggurat_io");
const screen_module = @import("screen.zig");

const Screen = screen_module.Screen;
const Position = screen_module.Position;

/// A match, from its first cell to its last, inclusive.
pub const Match = struct {
    start: Position,
    end: Position,

    pub fn contains(self: Match, at: Position) bool {
        return at.order(self.start) != .lt and at.order(self.end) != .gt;
    }
};

/// How a search goes, for a find bar's "1 of 3".
pub const Status = struct {
    /// The text searched for: empty when no search goes.
    text: []const u8 = "",
    /// Matches on the screen that shows: a full-screen program's, or the
    /// main screen's with its scrollback.
    total: usize = 0,
    /// The selected match's place, 1 the newest; 0 when none is.
    selected: usize = 0,
};

pub const max_text = 256;

pub const Search = struct {
    allocator: std.mem.Allocator,
    text_bytes: [max_text]u8 = undefined,
    text_len: usize = 0,
    /// The text as code points, ASCII letters lowered.
    needle: std.ArrayList(u21) = .empty,
    /// Matches, oldest first.
    matches: std.ArrayList(Match) = .empty,
    selected: ?usize = null,
    /// Select the newest match once one is found, as a search starts.
    pick: bool = false,
    /// What the matches were found in.
    revision: ?u64 = null,
    alternate: bool = false,
    pushed: u64 = 0,
    /// Code points of the logical line being searched, and their cells.
    line: std.ArrayList(u21) = .empty,
    cells: std.ArrayList(Position) = .empty,

    pub fn init(allocator: std.mem.Allocator) Search {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Search) void {
        self.needle.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.line.deinit(self.allocator);
        self.cells.deinit(self.allocator);
    }

    pub fn active(self: *const Search) bool {
        return self.needle.items.len > 0;
    }

    /// Search for `text`; the newest match is selected once found. The
    /// same text again keeps the selected match; empty ends the search.
    pub fn start(self: *Search, text: []const u8) !void {
        if (text.len == 0) return self.end();
        if (std.mem.eql(u8, text, self.text_bytes[0..self.text_len]) and self.active()) return;
        const len = @min(text.len, max_text);
        var view = std.unicode.Utf8View.init(text[0..len]) catch return error.InvalidUtf8;
        self.needle.clearRetainingCapacity();
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| try self.needle.append(self.allocator, fold(cp));
        @memcpy(self.text_bytes[0..len], text[0..len]);
        self.text_len = len;
        self.matches.clearRetainingCapacity();
        self.selected = null;
        self.pick = true;
        self.revision = null;
    }

    pub fn end(self: *Search) void {
        self.needle.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.text_len = 0;
        self.selected = null;
        self.pick = false;
        self.revision = null;
    }

    pub fn status(self: *const Search) Status {
        if (!self.active()) return .{};
        return .{ .text = self.text_bytes[0..self.text_len], .total = self.matches.items.len, .selected = if (self.selected) |i| self.matches.items.len - i else 0 };
    }

    /// Search again when the screen changed since the last search. True
    /// when the matches or the selected one may have changed.
    pub fn update(self: *Search, screen: *Screen) !bool {
        if (!self.active()) return false;
        if (self.revision == screen.content and self.alternate == screen.onAlternate() and self.pushed == screen.pushed) return false;
        const kept: ?Match = if (self.selected) |i| self.matches.items[i] else null;
        try self.find(screen);
        self.revision = screen.content;
        self.alternate = screen.onAlternate();
        self.pushed = screen.pushed;
        self.selected = null;
        if (kept) |match| {
            for (self.matches.items, 0..) |m, i| if (std.meta.eql(m, match)) {
                self.selected = i;
                break;
            };
            // Gone: the nearest one that is still there.
            if (self.selected == null and self.matches.items.len > 0) {
                var i: usize = 0;
                while (i < self.matches.items.len and self.matches.items[i].start.order(match.start) == .lt) i += 1;
                self.selected = @min(i, self.matches.items.len - 1);
            }
        }
        if (self.pick and self.matches.items.len > 0) {
            self.pick = false;
            self.selected = self.matches.items.len - 1;
            self.show(screen);
        }
        return true;
    }

    /// Select the next match toward older output, up into the scrollback,
    /// wrapping past the oldest; `previous` goes toward newer output. The
    /// selected match scrolls into view.
    pub fn next(self: *Search, screen: *Screen) void {
        self.step(screen, true);
    }
    pub fn previous(self: *Search, screen: *Screen) void {
        self.step(screen, false);
    }

    fn step(self: *Search, screen: *Screen, older: bool) void {
        const n = self.matches.items.len;
        // A match picked by hand is the one to keep.
        self.pick = false;
        if (n == 0) return;
        self.selected = if (self.selected) |i|
            (if (older) (if (i == 0) n - 1 else i - 1) else (if (i + 1 == n) 0 else i + 1))
        else
            n - 1;
        self.show(screen);
    }

    /// Scroll the selected match to the middle of the view unless all of
    /// it shows, as browsers do, rather than to an edge a find bar may
    /// cover.
    pub fn show(self: *const Search, screen: *Screen) void {
        const i = self.selected orelse return;
        const match = self.matches.items[i];
        const top = screen.viewRow(0);
        const bottom = top + screen.rows;
        if (match.start.row >= top and match.end.row < bottom) return;
        const half: u64 = screen.rows / 2;
        // The offset that puts the match's first row at the middle.
        const wanted: i128 = @as(i128, screen.pushed) + half - match.start.row;
        const clamped: usize = @intCast(zio.asUnsigned(std.math.clamp(wanted, 0, @as(i128, screen.historyCount()))));
        _ = screen.scrollView(@as(isize, @intCast(clamped)) - @as(isize, @intCast(screen.viewportOffset())));
    }

    /// Whether a cell is in a match, and in the selected one.
    pub fn at(self: *const Search, position: Position) enum { none, match, selected } {
        const items = self.matches.items;
        // The first match that ends at or after the position.
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (items[mid].end.order(position) == .lt) lo = mid + 1 else hi = mid;
        }
        if (lo < items.len and items[lo].contains(position)) return if (self.selected == lo) .selected else .match;
        return .none;
    }

    fn find(self: *Search, screen: *const Screen) !void {
        self.matches.clearRetainingCapacity();
        const first = if (screen.onAlternate()) screen.pushed else screen.firstRow();
        const last = screen.screenRow(screen.rows);
        var row = first;
        while (row < last) {
            // A logical line: rows joined by soft wraps.
            self.line.clearRetainingCapacity();
            self.cells.clearRetainingCapacity();
            while (row < last) {
                const r = screen.rowAt(row) orelse break;
                for (r.cells, 0..) |cell, col| {
                    if (cell.wide == .spacer) continue;
                    try self.line.append(self.allocator, if (cell.cp == 0) ' ' else fold(cell.cp));
                    try self.cells.append(self.allocator, .{ .row = row, .col = @intCast(col) });
                }
                row += 1;
                if (!r.wrapped) break;
            }
            try self.matchLine();
        }
    }

    fn matchLine(self: *Search) !void {
        const needle = self.needle.items;
        const hay = self.line.items;
        var i: usize = 0;
        while (i + needle.len <= hay.len) {
            if (std.mem.eql(u21, hay[i..][0..needle.len], needle)) {
                const last = self.cells.items[i + needle.len - 1];
                try self.matches.append(self.allocator, .{ .start = self.cells.items[i], .end = last });
                i += needle.len;
            } else i += 1;
        }
    }
};

fn fold(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
}

test "matches across the scrollback and soft wraps, newest selected" {
    var s = try Screen.init(std.testing.allocator, .{ .cols = 10, .rows = 3, .scrollback = 100, .scrollback_cells = 1000 });
    defer s.deinit();
    for ("foo bar\r\n") |b| if (b == '\r') s.carriageReturn() else if (b == '\n') s.lineFeed() else s.print(b);
    for ("xx FOO\r\n") |b| if (b == '\r') s.carriageReturn() else if (b == '\n') s.lineFeed() else s.print(b);
    for ("1\r\n2\r\n") |b| if (b == '\r') s.carriageReturn() else if (b == '\n') s.lineFeed() else s.print(b);
    // "abcdefghfo" wraps into "o".
    for ("abcdefghfoo") |b| s.print(b);
    var search = Search.init(std.testing.allocator);
    defer search.deinit();
    try search.start("foo");
    try std.testing.expect(try search.update(&s));
    try std.testing.expectEqual(@as(usize, 3), search.status().total);
    try std.testing.expectEqual(@as(usize, 1), search.status().selected);
    const newest = search.matches.items[2];
    try std.testing.expectEqual(@as(u16, 8), newest.start.col);
    try std.testing.expectEqual(newest.start.row + 1, newest.end.row);
    try std.testing.expectEqual(@as(u16, 0), newest.end.col);
    try std.testing.expect(search.at(newest.end) == .selected);
    try std.testing.expect(search.at(search.matches.items[0].start) == .match);
    try std.testing.expect(search.at(.{ .row = newest.start.row, .col = 0 }) == .none);
    // Toward older output, up into the scrollback, and wrapping around.
    search.next(&s);
    try std.testing.expectEqual(@as(usize, 2), search.status().selected);
    search.next(&s);
    try std.testing.expectEqual(@as(usize, 3), search.status().selected);
    // The oldest match is in the scrollback: the view scrolled to it.
    try std.testing.expect(s.viewportOffset() > 0);
    search.next(&s);
    try std.testing.expectEqual(@as(usize, 1), search.status().selected);
    search.previous(&s);
    try std.testing.expectEqual(@as(usize, 3), search.status().selected);
    // Nothing changed: no search again.
    try std.testing.expect(!try search.update(&s));
    // New output keeps the selected match.
    _ = s.scrollViewToBottom();
    for ("\r\nfoo") |b| if (b == '\r') s.carriageReturn() else if (b == '\n') s.lineFeed() else s.print(b);
    try std.testing.expect(try search.update(&s));
    try std.testing.expectEqual(@as(usize, 4), search.status().total);
    try std.testing.expectEqual(@as(usize, 4), search.status().selected);
    // The same text keeps it too; empty ends the search.
    try search.start("foo");
    try std.testing.expectEqual(@as(usize, 4), search.status().selected);
    try search.start("");
    try std.testing.expectEqual(@as(usize, 0), search.status().total);
    try std.testing.expect(!search.active());
}
