//! The grid of cells a terminal shows, its scrollback and its cursor. The
//! screen allocates once for its size and scrollback budget and again only
//! on `resize`; printing, scrolling and erasing never allocate.
const std = @import("std");
const width = @import("width.zig");

/// A cell color: the default foreground or background, one of the 256
/// palette entries, or a direct RGB value.
pub const Color = packed struct(u32) {
    value: u24 = 0,
    kind: Kind = .default,

    pub const Kind = enum(u8) { default, palette, rgb };
    pub fn palette(index: u8) Color {
        return .{ .value = index, .kind = .palette };
    }
    pub fn rgb(value: u24) Color {
        return .{ .value = value, .kind = .rgb };
    }
};

pub const Underline = enum(u3) { none, single, double, curly, dotted, dashed };

pub const Attributes = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: Underline = .none,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    overline: bool = false,
    _: u5 = 0,
};

pub const Style = struct {
    fg: Color = .{},
    bg: Color = .{},
    underline_color: Color = .{},
    attrs: Attributes = .{},
    /// A hyperlink id from `Links`, or 0.
    link: u16 = 0,

    pub fn eql(a: Style, b: Style) bool {
        return @as(u32, @bitCast(a.fg)) == @as(u32, @bitCast(b.fg)) and @as(u32, @bitCast(a.bg)) == @as(u32, @bitCast(b.bg)) and
            @as(u32, @bitCast(a.underline_color)) == @as(u32, @bitCast(b.underline_color)) and @as(u16, @bitCast(a.attrs)) == @as(u16, @bitCast(b.attrs)) and a.link == b.link;
    }
};

pub const Wide = enum(u2) {
    narrow,
    /// The first of the two cells of a wide character, holding it.
    wide,
    /// The second cell of a wide character, holding nothing.
    spacer,
};

pub const Cell = struct {
    /// 0 for a cell nothing was written to.
    cp: u21 = 0,
    wide: Wide = .narrow,
    style: Style = .{},

    pub fn blank(style: Style) Cell {
        // Erased cells keep the background only.
        return .{ .style = .{ .bg = style.bg } };
    }
    pub fn isBlank(self: Cell) bool {
        return (self.cp == 0 or self.cp == ' ') and self.style.bg.kind == .default and !self.style.attrs.inverse and self.style.link == 0 and self.style.attrs.underline == .none;
    }
};

pub const Charset = enum { ascii, dec_graphics, uk };

pub const MouseTracking = enum { none, x10, normal, button, any };
pub const MouseEncoding = enum { x10, utf8, sgr, urxvt, sgr_pixels };
pub const CursorShape = enum { block, underline, bar };

pub const Modes = struct {
    /// IRM: printing shifts the rest of the line right.
    insert: bool = false,
    /// LNM: line feed also returns the carriage, and Enter sends CR LF.
    newline: bool = false,
    /// DECAWM: printing past the last column wraps to the next line.
    autowrap: bool = true,
    /// DECOM: cursor positions count from the scrolling region.
    origin: bool = false,
    /// DECCKM: arrows send SS3 rather than CSI.
    cursor_keys: bool = false,
    /// DECKPAM: the keypad sends application sequences.
    keypad: bool = false,
    cursor_visible: bool = true,
    cursor_blink: bool = false,
    cursor_shape: CursorShape = .block,
    /// DECSCNM: the whole screen shows inverted.
    reverse_video: bool = false,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    mouse: MouseTracking = .none,
    mouse_encoding: MouseEncoding = .x10,
    /// The wheel sends arrow keys on the alternate screen when the mouse
    /// is not tracked.
    alternate_scroll: bool = true,
    /// Output between the begin and end of a synchronized update is shown
    /// together.
    synchronized: bool = false,
};

pub const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    /// The last column was printed; the next character wraps first.
    pending_wrap: bool = false,
    style: Style = .{},
    charsets: [2]Charset = .{ .ascii, .ascii },
    /// Which of G0 and G1 prints.
    shift: u1 = 0,
};

const Saved = struct {
    cursor: Cursor = .{},
    origin: bool = false,
    autowrap: bool = true,
};

/// The rows on screen, each a slice into one block of cells. Scrolling
/// rotates `map` instead of moving cells.
const Grid = struct {
    cells: []Cell,
    map: []u32,
    wrapped: []bool,
    cols: u16,
    rows: u16,

    fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Grid {
        const count = @as(usize, cols) * rows;
        const cells = try allocator.alloc(Cell, count);
        errdefer allocator.free(cells);
        const map = try allocator.alloc(u32, rows);
        errdefer allocator.free(map);
        const wrapped = try allocator.alloc(bool, rows);
        @memset(cells, .{});
        for (map, 0..) |*m, i| m.* = @intCast(i);
        @memset(wrapped, false);
        return .{ .cells = cells, .map = map, .wrapped = wrapped, .cols = cols, .rows = rows };
    }
    fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.map);
        allocator.free(self.wrapped);
    }
    fn row(self: *const Grid, y: usize) []Cell {
        const physical: usize = self.map[y];
        return self.cells[physical * self.cols ..][0..self.cols];
    }
    fn wrap(self: *const Grid, y: usize) *bool {
        return &self.wrapped[self.map[y]];
    }
    fn clearRow(self: *const Grid, y: usize, fill: Cell) void {
        @memset(self.row(y), fill);
        self.wrap(y).* = false;
    }
    /// Move rows `top..bottom` (exclusive) up by `n`, clearing the bottom.
    fn rotateUp(self: *Grid, top: usize, bottom: usize, n: usize, fill: Cell) void {
        const span = self.map[top..bottom];
        std.mem.rotate(u32, span, n);
        for (bottom - n..bottom) |y| self.clearRow(y, fill);
    }
    fn rotateDown(self: *Grid, top: usize, bottom: usize, n: usize, fill: Cell) void {
        const span = self.map[top..bottom];
        std.mem.rotate(u32, span, span.len - n);
        for (top..top + n) |y| self.clearRow(y, fill);
    }
};

/// Lines scrolled off the top of the primary screen, trimmed of trailing
/// blanks and kept in a ring of cells bounded by line count and cell count.
pub const History = struct {
    cells: []Cell,
    lines: []Line,
    first: usize = 0,
    count: usize = 0,

    pub const Line = struct { start: usize, len: usize, wrapped: bool };

    fn init(allocator: std.mem.Allocator, lines: usize, cells: usize) !History {
        const line_storage = try allocator.alloc(Line, lines);
        errdefer allocator.free(line_storage);
        return .{ .cells = try allocator.alloc(Cell, cells), .lines = line_storage };
    }
    fn deinit(self: *History, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.lines);
    }
    fn at(self: *const History, index: usize) Line {
        return self.lines[(self.first + index) % self.lines.len];
    }
    fn dropOldest(self: *History) void {
        self.first = (self.first + 1) % self.lines.len;
        self.count -= 1;
    }
    /// Line `index`, 0 the oldest.
    pub fn get(self: *const History, index: usize) struct { cells: []const Cell, wrapped: bool } {
        const line = self.at(index);
        return .{ .cells = self.cells[line.start..][0..line.len], .wrapped = line.wrapped };
    }
    fn push(self: *History, row: []const Cell, wrapped: bool) void {
        if (self.lines.len == 0) return;
        var len = row.len;
        while (len > 0 and row[len - 1].isBlank()) len -= 1;
        len = @min(len, self.cells.len);
        if (self.count == self.lines.len) self.dropOldest();
        var position: usize = 0;
        if (self.count > 0) {
            const newest = self.at(self.count - 1);
            position = newest.start + newest.len;
            if (position + len > self.cells.len) {
                // Wrapping to the start frees the tail, which holds the oldest lines.
                const tail = position;
                position = 0;
                while (self.count > 0 and self.at(0).start >= tail) self.dropOldest();
            }
        }
        while (self.count > 0) {
            const oldest = self.at(0);
            const overlaps = oldest.start < position + len and position < oldest.start + oldest.len;
            // An empty line sitting where the new one goes is overwritten too.
            const covered = oldest.len == 0 and oldest.start >= position and oldest.start < position + len;
            if (!overlaps and !covered) break;
            self.dropOldest();
        }
        @memcpy(self.cells[position..][0..len], row[0..len]);
        self.lines[(self.first + self.count) % self.lines.len] = .{ .start = position, .len = len, .wrapped = wrapped };
        self.count += 1;
    }
    fn clear(self: *History) void {
        self.first = 0;
        self.count = 0;
    }
    /// Take back the newest line.
    fn pop(self: *History) ?Line {
        if (self.count == 0) return null;
        self.count -= 1;
        return self.at(self.count);
    }
};

/// Hyperlink targets set by OSC 8, kept in a ring of fixed slots. Ids grow
/// by one per link, so a cell whose link slot was reused finds no target.
pub const Links = struct {
    slots: []Slot,
    bytes: []u8,
    next: u16 = 1,

    pub const max_uri = 2048;
    const Slot = struct { id: u16 = 0, len: u16 = 0 };

    fn init(allocator: std.mem.Allocator, count: usize) !Links {
        const slots = try allocator.alloc(Slot, count);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        return .{ .slots = slots, .bytes = try allocator.alloc(u8, count * max_uri) };
    }
    fn deinit(self: *Links, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        allocator.free(self.bytes);
    }
    fn add(self: *Links, uri: []const u8) u16 {
        if (self.slots.len == 0 or uri.len == 0 or uri.len > max_uri) return 0;
        const id = self.next;
        self.next +%= 1;
        if (self.next == 0) self.next = 1;
        const index = id % self.slots.len;
        self.slots[index] = .{ .id = id, .len = @intCast(uri.len) };
        @memcpy(self.bytes[index * max_uri ..][0..uri.len], uri);
        return id;
    }
    pub fn get(self: *const Links, id: u16) ?[]const u8 {
        if (id == 0 or self.slots.len == 0) return null;
        const index = id % self.slots.len;
        const slot = self.slots[index];
        if (slot.id != id) return null;
        return self.bytes[index * max_uri ..][0..slot.len];
    }
};

pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    /// Lines kept after they scroll off the top; 0 keeps none.
    scrollback: u32 = 5000,
    /// Cells shared by those lines once trailing blanks are trimmed.
    scrollback_cells: u32 = 5000 * 64,
    /// Hyperlinks remembered at once.
    links: u16 = 64,
};

/// A position in the scrollback and the screen together. Rows count from
/// the first line ever written, so they stay put as output scrolls.
pub const Position = struct {
    row: u64,
    col: u16,

    pub fn order(a: Position, b: Position) std.math.Order {
        if (a.row != b.row) return std.math.order(a.row, b.row);
        return std.math.order(a.col, b.col);
    }
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    primary: Grid,
    alternate: Grid,
    on_alternate: bool = false,
    history: History,
    links: Links,
    cursor: Cursor = .{},
    saved: [2]Saved = .{ .{}, .{} },
    /// Scrolling region, inclusive rows.
    top: u16 = 0,
    bottom: u16,
    tabs: []bool,
    modes: Modes = .{},
    /// Lines ever pushed into the scrollback, including dropped ones.
    pushed: u64 = 0,
    /// Lines the view is scrolled back from the bottom.
    viewport: usize = 0,
    /// Changes whenever a visible cell, the cursor or a mode changes.
    revision: u64 = 0,
    /// Changes with what the screen and scrollback hold, but not as the
    /// view scrolls.
    content: u64 = 0,
    /// The character last printed, repeated by REP.
    last_printed: u21 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Screen {
        const cols = @max(options.cols, 2);
        const rows = @max(options.rows, 1);
        var primary = try Grid.init(allocator, cols, rows);
        errdefer primary.deinit(allocator);
        var alternate = try Grid.init(allocator, cols, rows);
        errdefer alternate.deinit(allocator);
        var history = try History.init(allocator, options.scrollback, if (options.scrollback == 0) 0 else options.scrollback_cells);
        errdefer history.deinit(allocator);
        var links = try Links.init(allocator, options.links);
        errdefer links.deinit(allocator);
        const tabs = try allocator.alloc(bool, cols);
        var self: Screen = .{ .allocator = allocator, .cols = cols, .rows = rows, .primary = primary, .alternate = alternate, .history = history, .links = links, .bottom = rows - 1, .tabs = tabs };
        self.resetTabs();
        return self;
    }

    pub fn deinit(self: *Screen) void {
        self.primary.deinit(self.allocator);
        self.alternate.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.links.deinit(self.allocator);
        self.allocator.free(self.tabs);
    }

    fn grid(self: *Screen) *Grid {
        return if (self.on_alternate) &self.alternate else &self.primary;
    }
    fn gridConst(self: *const Screen) *const Grid {
        return if (self.on_alternate) &self.alternate else &self.primary;
    }
    fn changed(self: *Screen) void {
        self.revision +%= 1;
        self.content +%= 1;
    }
    fn viewChanged(self: *Screen) void {
        self.revision +%= 1;
    }
    fn fill(self: *const Screen) Cell {
        return Cell.blank(self.cursor.style);
    }

    pub fn row(self: *const Screen, y: usize) []Cell {
        return self.gridConst().row(y);
    }
    pub fn wrapped(self: *const Screen, y: usize) bool {
        return self.gridConst().wrap(y).*;
    }
    pub fn onAlternate(self: *const Screen) bool {
        return self.on_alternate;
    }

    // ---- Rows by absolute position --------------------------------------

    /// The absolute row of the first line still in the scrollback.
    pub fn firstRow(self: *const Screen) u64 {
        return self.pushed - self.history.count;
    }
    /// The absolute row of screen row `y`.
    pub fn screenRow(self: *const Screen, y: usize) u64 {
        return self.pushed + y;
    }
    /// The cells of absolute row `abs`, or null once it left the scrollback
    /// or past the bottom. History rows can be shorter than the screen.
    pub fn rowAt(self: *const Screen, abs: u64) ?struct { cells: []const Cell, wrapped: bool } {
        if (abs < self.firstRow()) return null;
        if (abs < self.pushed) {
            const line = self.history.get(@intCast(abs - self.firstRow()));
            return .{ .cells = line.cells, .wrapped = line.wrapped };
        }
        const y = abs - self.pushed;
        if (y >= self.rows) return null;
        return .{ .cells = self.row(@intCast(y)), .wrapped = self.wrapped(@intCast(y)) };
    }
    /// The absolute row shown at view row `y`, given the viewport.
    pub fn viewRow(self: *const Screen, y: usize) u64 {
        return self.pushed + y - self.viewportOffset();
    }
    pub fn viewportOffset(self: *const Screen) usize {
        if (self.on_alternate) return 0;
        return @min(self.viewport, self.history.count);
    }
    /// Scroll the view `delta` lines back (positive) or forward; true when
    /// it moved.
    pub fn scrollView(self: *Screen, delta: isize) bool {
        if (self.on_alternate) return false;
        const before = self.viewportOffset();
        const wanted: isize = @as(isize, @intCast(before)) + delta;
        self.viewport = @intCast(std.math.clamp(wanted, 0, @as(isize, @intCast(self.history.count))));
        if (self.viewport == before) return false;
        self.viewChanged();
        return true;
    }
    pub fn scrollViewToBottom(self: *Screen) bool {
        if (self.viewport == 0) return false;
        self.viewport = 0;
        self.viewChanged();
        return true;
    }
    pub fn historyCount(self: *const Screen) usize {
        return if (self.on_alternate) 0 else self.history.count;
    }

    // ---- Printing ----------------------------------------------------------

    pub fn print(self: *Screen, raw: u21) void {
        const cp = self.mapCharset(raw);
        const w = width.of(cp);
        if (w == 0) {
            // Combining marks have no cell of their own.
            return;
        }
        self.last_printed = cp;
        self.changed();
        const g = self.grid();
        if (self.cursor.pending_wrap and self.modes.autowrap) {
            g.wrap(self.cursor.y).* = true;
            self.cursor.x = 0;
            self.index();
        }
        self.cursor.pending_wrap = false;
        var x = self.cursor.x;
        if (w == 2 and x + 1 >= self.cols) {
            if (!self.modes.autowrap) return;
            // A wide character that does not fit wraps whole.
            const line = g.row(self.cursor.y);
            self.clearCell(line, x);
            g.wrap(self.cursor.y).* = true;
            self.cursor.x = 0;
            self.index();
            x = 0;
        }
        const line = g.row(self.cursor.y);
        if (self.modes.insert) {
            const end = self.cols;
            if (x + w < end) std.mem.copyBackwards(Cell, line[x + w .. end], line[x .. end - w]);
            // A wide character cut at the right edge leaves a blank.
            if (line[end - 1].wide == .wide) line[end - 1] = self.fill();
        }
        self.clearCell(line, x);
        if (w == 2) self.clearCell(line, x + 1);
        line[x] = .{ .cp = cp, .wide = if (w == 2) .wide else .narrow, .style = self.cursor.style };
        if (w == 2) line[x + 1] = .{ .wide = .spacer, .style = self.cursor.style };
        const next = x + w;
        if (next >= self.cols) {
            self.cursor.x = self.cols - 1;
            self.cursor.pending_wrap = self.modes.autowrap;
        } else self.cursor.x = next;
    }

    /// Repeat the last printed character `n` times.
    pub fn repeat(self: *Screen, n: usize) void {
        if (self.last_printed == 0) return;
        const cp = self.last_printed;
        for (0..@min(n, @as(usize, self.cols) * self.rows)) |_| self.printMapped(cp);
    }
    fn printMapped(self: *Screen, cp: u21) void {
        const saved = self.cursor.charsets;
        self.cursor.charsets = .{ .ascii, .ascii };
        defer self.cursor.charsets = saved;
        self.print(cp);
    }

    /// Clear the cell at `x` and the other half of a wide character there.
    fn clearCell(self: *const Screen, line: []Cell, x: usize) void {
        if (x >= line.len) return;
        switch (line[x].wide) {
            .wide => if (x + 1 < line.len) {
                line[x + 1] = self.fill();
            },
            .spacer => if (x > 0) {
                line[x - 1] = self.fill();
            },
            .narrow => {},
        }
        line[x] = self.fill();
    }

    fn mapCharset(self: *const Screen, cp: u21) u21 {
        return switch (self.cursor.charsets[self.cursor.shift]) {
            .ascii => cp,
            .uk => if (cp == '#') 0xa3 else cp,
            .dec_graphics => if (cp >= 0x60 and cp <= 0x7e) dec_graphics[cp - 0x60] else cp,
        };
    }

    pub fn designate(self: *Screen, slot: u1, charset: Charset) void {
        self.cursor.charsets[slot] = charset;
    }
    pub fn shiftTo(self: *Screen, slot: u1) void {
        self.cursor.shift = slot;
    }

    // ---- Cursor ------------------------------------------------------------

    fn regionTop(self: *const Screen) u16 {
        return if (self.modes.origin) self.top else 0;
    }
    fn regionBottom(self: *const Screen) u16 {
        return if (self.modes.origin) self.bottom else self.rows - 1;
    }

    /// Move to 0-based column `x` and row `y`, relative to the scrolling
    /// region in origin mode.
    pub fn moveTo(self: *Screen, x: usize, y: usize) void {
        const top = self.regionTop();
        self.cursor.x = @intCast(@min(x, self.cols - 1));
        self.cursor.y = @intCast(@min(top + y, self.regionBottom()));
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn moveToColumn(self: *Screen, x: usize) void {
        self.cursor.x = @intCast(@min(x, self.cols - 1));
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn moveToRow(self: *Screen, y: usize) void {
        self.moveTo(self.cursor.x, y);
    }
    /// Move up, stopping at the top margin when inside the region.
    pub fn up(self: *Screen, n: usize) void {
        const limit: u16 = if (self.cursor.y >= self.top) self.top else 0;
        self.cursor.y = @intCast(@max(@as(isize, limit), @as(isize, self.cursor.y) - @as(isize, @intCast(@min(n, self.rows)))));
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn down(self: *Screen, n: usize) void {
        const limit: u16 = if (self.cursor.y <= self.bottom) self.bottom else self.rows - 1;
        self.cursor.y = @intCast(@min(@as(usize, limit), @as(usize, self.cursor.y) + @min(n, self.rows)));
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn forward(self: *Screen, n: usize) void {
        self.cursor.x = @intCast(@min(@as(usize, self.cols - 1), @as(usize, self.cursor.x) + @min(n, self.cols)));
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn backward(self: *Screen, n: usize) void {
        self.cursor.x = @intCast(@max(0, @as(isize, self.cursor.x) - @as(isize, @intCast(@min(n, self.cols)))));
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn carriageReturn(self: *Screen) void {
        self.cursor.x = 0;
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn backspace(self: *Screen) void {
        if (self.cursor.pending_wrap) {
            self.cursor.pending_wrap = false;
        } else if (self.cursor.x > 0) self.cursor.x -= 1;
        self.changed();
    }

    /// IND: down a line, scrolling the region at its bottom.
    pub fn index(self: *Screen) void {
        self.changed();
        if (self.cursor.y == self.bottom) {
            self.scrollUp(1);
        } else if (self.cursor.y < self.rows - 1) self.cursor.y += 1;
    }
    /// LF, VT and FF: index, and return in newline mode.
    pub fn lineFeed(self: *Screen) void {
        self.index();
        if (self.modes.newline) self.cursor.x = 0;
        self.cursor.pending_wrap = false;
    }
    /// RI: up a line, scrolling the region down at its top.
    pub fn reverseIndex(self: *Screen) void {
        self.changed();
        self.cursor.pending_wrap = false;
        if (self.cursor.y == self.top) {
            self.scrollDown(1);
        } else if (self.cursor.y > 0) self.cursor.y -= 1;
    }
    pub fn nextLine(self: *Screen) void {
        self.index();
        self.cursor.x = 0;
        self.cursor.pending_wrap = false;
    }

    pub fn saveCursor(self: *Screen) void {
        self.saved[@intFromBool(self.on_alternate)] = .{ .cursor = self.cursor, .origin = self.modes.origin, .autowrap = self.modes.autowrap };
    }
    pub fn restoreCursor(self: *Screen) void {
        const saved = self.saved[@intFromBool(self.on_alternate)];
        self.cursor = saved.cursor;
        self.cursor.x = @min(self.cursor.x, self.cols - 1);
        self.cursor.y = @min(self.cursor.y, self.rows - 1);
        self.modes.origin = saved.origin;
        self.modes.autowrap = saved.autowrap;
        self.changed();
    }

    // ---- Tabs --------------------------------------------------------------

    fn resetTabs(self: *Screen) void {
        for (self.tabs, 0..) |*tab, i| tab.* = i % 8 == 0 and i > 0;
    }
    pub fn setTab(self: *Screen) void {
        self.tabs[self.cursor.x] = true;
    }
    pub fn clearTab(self: *Screen, all: bool) void {
        if (all) @memset(self.tabs, false) else self.tabs[self.cursor.x] = false;
    }
    pub fn tabForward(self: *Screen, n: usize) void {
        for (0..@min(n, self.cols)) |_| {
            var x = self.cursor.x + 1;
            while (x < self.cols - 1 and !self.tabs[x]) x += 1;
            self.cursor.x = @intCast(@min(x, self.cols - 1));
        }
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn tabBackward(self: *Screen, n: usize) void {
        for (0..@min(n, self.cols)) |_| {
            if (self.cursor.x == 0) break;
            var x = self.cursor.x - 1;
            while (x > 0 and !self.tabs[x]) x -= 1;
            self.cursor.x = x;
        }
        self.cursor.pending_wrap = false;
        self.changed();
    }

    // ---- Scrolling ---------------------------------------------------------

    pub fn setRegion(self: *Screen, top: usize, bottom: usize) void {
        const b = @min(bottom, self.rows - 1);
        if (top >= b) return;
        self.top = @intCast(top);
        self.bottom = @intCast(b);
        self.moveTo(0, 0);
    }

    /// Scroll the region up `n` lines. Lines leaving the top of the whole
    /// primary screen go to the scrollback.
    pub fn scrollUp(self: *Screen, count: usize) void {
        const span = @as(usize, self.bottom) - self.top + 1;
        const n = @min(count, span);
        if (n == 0) return;
        const g = self.grid();
        if (!self.on_alternate and self.top == 0) {
            for (0..n) |y| self.history.push(g.row(y), g.wrap(y).*);
            self.pushed += n;
            // A view scrolled back keeps showing the same lines.
            if (self.viewport > 0) self.viewport = @min(self.viewport + n, self.history.count);
        }
        g.rotateUp(self.top, @as(usize, self.bottom) + 1, n, self.fill());
        self.changed();
    }
    pub fn scrollDown(self: *Screen, count: usize) void {
        const span = @as(usize, self.bottom) - self.top + 1;
        const n = @min(count, span);
        if (n == 0) return;
        self.grid().rotateDown(self.top, @as(usize, self.bottom) + 1, n, self.fill());
        self.changed();
    }
    /// IL: insert blank lines at the cursor, inside the region.
    pub fn insertLines(self: *Screen, count: usize) void {
        if (self.cursor.y < self.top or self.cursor.y > self.bottom) return;
        const n = @min(count, @as(usize, self.bottom) - self.cursor.y + 1);
        self.grid().rotateDown(self.cursor.y, @as(usize, self.bottom) + 1, n, self.fill());
        self.cursor.x = 0;
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn deleteLines(self: *Screen, count: usize) void {
        if (self.cursor.y < self.top or self.cursor.y > self.bottom) return;
        const n = @min(count, @as(usize, self.bottom) - self.cursor.y + 1);
        self.grid().rotateUp(self.cursor.y, @as(usize, self.bottom) + 1, n, self.fill());
        self.cursor.x = 0;
        self.cursor.pending_wrap = false;
        self.changed();
    }

    // ---- Editing -----------------------------------------------------------

    /// ICH: shift the rest of the line right, blanking at the cursor.
    pub fn insertChars(self: *Screen, count: usize) void {
        const line = self.grid().row(self.cursor.y);
        const x = self.cursor.x;
        const n = @min(count, self.cols - x);
        // A wide character split at the cursor goes.
        if (line[x].wide == .spacer) self.clearCell(line, x);
        if (x + n < self.cols) std.mem.copyBackwards(Cell, line[x + n ..], line[x .. self.cols - n]);
        @memset(line[x .. x + n], self.fill());
        if (line[self.cols - 1].wide == .wide) line[self.cols - 1] = self.fill();
        self.cursor.pending_wrap = false;
        self.changed();
    }
    /// DCH: shift the rest of the line left over the cursor.
    pub fn deleteChars(self: *Screen, count: usize) void {
        const line = self.grid().row(self.cursor.y);
        const x = self.cursor.x;
        const n = @min(count, self.cols - x);
        // Wide characters split at either end of the deleted cells go.
        if (line[x].wide == .spacer) self.clearCell(line, x);
        if (x + n < self.cols and line[x + n].wide == .spacer) self.clearCell(line, x + n);
        std.mem.copyForwards(Cell, line[x .. self.cols - n], line[x + n ..]);
        @memset(line[self.cols - n ..], self.fill());
        self.cursor.pending_wrap = false;
        self.changed();
    }
    /// ECH: blank cells from the cursor without moving the rest.
    pub fn eraseChars(self: *Screen, count: usize) void {
        const line = self.grid().row(self.cursor.y);
        const x = self.cursor.x;
        const n = @min(@max(count, 1), self.cols - x);
        self.clearCell(line, x);
        self.clearCell(line, x + n - 1);
        @memset(line[x .. x + n], self.fill());
        self.cursor.pending_wrap = false;
        self.changed();
    }

    pub const Erase = enum { below, above, all, scrollback };

    pub fn eraseLine(self: *Screen, mode: Erase) void {
        const g = self.grid();
        const line = g.row(self.cursor.y);
        const x = self.cursor.x;
        switch (mode) {
            .below => {
                self.clearCell(line, x);
                @memset(line[x..], self.fill());
                g.wrap(self.cursor.y).* = false;
            },
            .above => {
                self.clearCell(line, x);
                @memset(line[0 .. x + 1], self.fill());
            },
            .all, .scrollback => g.clearRow(self.cursor.y, self.fill()),
        }
        self.cursor.pending_wrap = false;
        self.changed();
    }
    pub fn eraseDisplay(self: *Screen, mode: Erase) void {
        const g = self.grid();
        switch (mode) {
            .below => {
                self.eraseLine(.below);
                for (@as(usize, self.cursor.y) + 1..self.rows) |y| g.clearRow(y, self.fill());
            },
            .above => {
                self.eraseLine(.above);
                for (0..self.cursor.y) |y| g.clearRow(y, self.fill());
            },
            .all => for (0..self.rows) |y| g.clearRow(y, self.fill()),
            .scrollback => {
                self.history.clear();
                self.viewport = 0;
            },
        }
        self.changed();
    }
    /// Clear the scrollback and the screen above the cursor's line, which
    /// moves to the top with what is below it: what a user's clear does,
    /// keeping the shell's prompt. Nothing on the alternate screen.
    pub fn clearToCursor(self: *Screen) bool {
        if (self.on_alternate) return false;
        const g = self.grid();
        const from: usize = self.cursor.y;
        if (from > 0) {
            for (0..self.rows - from) |y| {
                @memcpy(g.row(y), g.row(y + from));
                g.wrap(y).* = g.wrap(y + from).*;
            }
            for (self.rows - from..self.rows) |y| g.clearRow(y, Cell.blank(.{}));
        }
        self.cursor.y = 0;
        self.history.clear();
        self.viewport = 0;
        self.changed();
        return true;
    }
    /// Clear the scrollback alone.
    pub fn clearScrollback(self: *Screen) void {
        self.history.clear();
        self.viewport = 0;
        self.changed();
    }
    /// DECALN: fill the screen with 'E'.
    pub fn alignmentTest(self: *Screen) void {
        const g = self.grid();
        for (0..self.rows) |y| {
            @memset(g.row(y), .{ .cp = 'E' });
            g.wrap(y).* = false;
        }
        self.top = 0;
        self.bottom = self.rows - 1;
        self.moveTo(0, 0);
    }

    // ---- Modes and screens -------------------------------------------------

    /// Switch to the alternate screen, clearing it, or back.
    pub fn useAlternate(self: *Screen, on: bool, save_cursor: bool, clear: bool) void {
        if (on == self.on_alternate) {
            if (on and clear) self.eraseDisplay(.all);
            return;
        }
        if (on) {
            if (save_cursor) self.saveCursor();
            self.on_alternate = true;
            if (clear) for (0..self.rows) |y| self.alternate.clearRow(y, Cell.blank(self.cursor.style));
        } else {
            if (clear) for (0..self.rows) |y| self.alternate.clearRow(y, .{});
            self.on_alternate = false;
            if (save_cursor) self.restoreCursor();
        }
        self.viewport = 0;
        self.changed();
    }

    /// RIS: everything back to the start, keeping the size.
    pub fn reset(self: *Screen) void {
        self.on_alternate = false;
        for (0..self.rows) |y| {
            self.primary.clearRow(y, .{});
            self.alternate.clearRow(y, .{});
        }
        self.history.clear();
        self.cursor = .{};
        self.saved = .{ .{}, .{} };
        self.modes = .{};
        self.top = 0;
        self.bottom = self.rows - 1;
        self.viewport = 0;
        self.last_printed = 0;
        self.resetTabs();
        self.changed();
    }
    /// DECSTR: modes, margins and the pen back to their defaults, keeping
    /// the text.
    pub fn softReset(self: *Screen) void {
        self.modes.insert = false;
        self.modes.origin = false;
        self.modes.autowrap = true;
        self.modes.cursor_keys = false;
        self.modes.keypad = false;
        self.modes.cursor_visible = true;
        self.top = 0;
        self.bottom = self.rows - 1;
        self.cursor.style = .{};
        self.cursor.charsets = .{ .ascii, .ascii };
        self.cursor.shift = 0;
        self.cursor.pending_wrap = false;
        self.saved = .{ .{}, .{} };
        self.changed();
    }

    pub fn setLink(self: *Screen, uri: []const u8) void {
        self.cursor.style.link = if (uri.len == 0) 0 else self.links.add(uri);
    }
    pub fn link(self: *const Screen, id: u16) ?[]const u8 {
        return self.links.get(id);
    }

    // ---- Size --------------------------------------------------------------

    /// Change the size. Lines keep their text from the left; the cursor
    /// stays on its line, pushing lines above into the scrollback when the
    /// screen gets shorter and pulling them back when it gets taller.
    pub fn resize(self: *Screen, cols_wanted: u16, rows_wanted: u16) !void {
        const cols = @max(cols_wanted, 2);
        const rows = @max(rows_wanted, 1);
        if (cols == self.cols and rows == self.rows) return;
        var primary = try Grid.init(self.allocator, cols, rows);
        errdefer primary.deinit(self.allocator);
        var alternate = try Grid.init(self.allocator, cols, rows);
        errdefer alternate.deinit(self.allocator);
        const tabs = try self.allocator.alloc(bool, cols);
        errdefer comptime unreachable;

        // Rows dropped from the top of the primary screen go to the
        // scrollback; rows added come back from it.
        var shift: isize = 0;
        if (rows < self.rows) {
            // Keep the cursor's line and as much below it as fits.
            const used = self.usedRows();
            const keep_from = if (used > rows) used - rows else 0;
            const cursor_from = if (self.primaryCursorY() + 1 > rows) self.primaryCursorY() + 1 - rows else 0;
            shift = @intCast(@max(keep_from, cursor_from));
            shift = @min(shift, @as(isize, @intCast(self.primaryCursorY())));
            for (0..@intCast(shift)) |y| self.history.push(self.primary.row(y), self.primary.wrap(y).*);
            self.pushed += @intCast(shift);
        } else if (rows > self.rows and !self.on_alternate) {
            const room = rows - self.rows;
            shift = -@as(isize, @intCast(@min(room, self.history.count)));
        }
        const pulled: usize = if (shift < 0) @intCast(-shift) else 0;
        // Rows pulled back from the scrollback come first.
        var y: usize = pulled;
        while (y > 0) {
            y -= 1;
            const line = self.history.pop().?;
            const target = primary.row(y);
            const n = @min(line.len, cols);
            @memcpy(target[0..n], self.history.cells[line.start..][0..n]);
            fixRightEdge(target, n);
            primary.wrap(y).* = line.wrapped;
        }
        self.pushed -= pulled;
        const kept_from: usize = if (shift > 0) @intCast(shift) else 0;
        for (kept_from..self.rows) |from| {
            const to = from - kept_from + pulled;
            if (to >= rows) break;
            copyRow(primary.row(to), self.primary.row(from));
            primary.wrap(to).* = self.primary.wrap(from).*;
        }
        for (0..@min(rows, self.rows)) |from| {
            copyRow(alternate.row(from), self.alternate.row(from));
            alternate.wrap(from).* = self.alternate.wrap(from).*;
        }

        self.primary.deinit(self.allocator);
        self.alternate.deinit(self.allocator);
        self.allocator.free(self.tabs);
        self.primary = primary;
        self.alternate = alternate;
        self.tabs = tabs;
        const old_cols = self.cols;
        self.cols = cols;
        self.rows = rows;
        self.resetTabs();
        _ = old_cols;
        self.top = 0;
        self.bottom = rows - 1;
        if (!self.on_alternate) {
            const moved = @as(isize, self.cursor.y) - shift;
            self.cursor.y = @intCast(std.math.clamp(moved, 0, @as(isize, rows - 1)));
        } else {
            self.cursor.y = @min(self.cursor.y, rows - 1);
            const saved = &self.saved[0].cursor;
            const moved = @as(isize, saved.y) - shift;
            saved.y = @intCast(std.math.clamp(moved, 0, @as(isize, rows - 1)));
        }
        self.cursor.x = @min(self.cursor.x, cols - 1);
        self.cursor.pending_wrap = false;
        self.viewport = @min(self.viewport, self.history.count);
        self.changed();
    }

    fn primaryCursorY(self: *const Screen) usize {
        return if (self.on_alternate) self.saved[0].cursor.y else self.cursor.y;
    }
    /// Rows of the primary screen down to the last with text or the cursor.
    fn usedRows(self: *const Screen) usize {
        const used: usize = self.primaryCursorY() + 1;
        var y: usize = self.rows;
        while (y > used) {
            y -= 1;
            for (self.primary.row(y)) |cell| if (!cell.isBlank()) return y + 1;
        }
        return used;
    }
};

fn copyRow(to: []Cell, from: []const Cell) void {
    const n = @min(to.len, from.len);
    @memcpy(to[0..n], from[0..n]);
    fixRightEdge(to, n);
}
/// A wide character cut in half at the right edge becomes a blank.
fn fixRightEdge(line: []Cell, n: usize) void {
    if (n > 0 and n <= line.len and line[n - 1].wide == .wide and (n == line.len or line[n].wide != .spacer)) line[n - 1] = .{ .style = .{ .bg = line[n - 1].style.bg } };
}

/// The DEC special graphics set for 0x60..0x7e: line drawing and symbols.
const dec_graphics = [_]u21{
    0x25c6, 0x2592, 0x2409, 0x240c, 0x240d, 0x240a, 0x00b0, 0x00b1,
    0x2424, 0x240b, 0x2518, 0x2510, 0x250c, 0x2514, 0x253c, 0x23ba,
    0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c, 0x2524, 0x2534, 0x252c,
    0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3, 0x00b7,
};

fn text(screen: *const Screen, y: usize, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (screen.row(y)) |cell| {
        if (cell.wide == .spacer) continue;
        const cp: u21 = if (cell.cp == 0) ' ' else cell.cp;
        len += std.unicode.utf8Encode(cp, buffer[len..]) catch unreachable;
    }
    while (len > 0 and buffer[len - 1] == ' ') len -= 1;
    return buffer[0..len];
}

fn printAll(screen: *Screen, bytes: []const u8) void {
    var view = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (view.nextCodepoint()) |cp| switch (cp) {
        '\n' => screen.nextLine(),
        else => screen.print(cp),
    };
}

test "printing wraps, wide characters take two cells and the region scrolls into history" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 5, .rows = 2, .scrollback = 10, .scrollback_cells = 100 });
    defer screen.deinit();
    var buffer: [64]u8 = undefined;
    printAll(&screen, "abcdefg");
    try std.testing.expectEqualStrings("abcde", text(&screen, 0, &buffer));
    try std.testing.expectEqualStrings("fg", text(&screen, 1, &buffer));
    try std.testing.expect(screen.wrapped(0));
    printAll(&screen, "\n中文x");
    try std.testing.expectEqual(@as(usize, 1), screen.history.count);
    try std.testing.expectEqualStrings("fg", text(&screen, 0, &buffer));
    try std.testing.expectEqualStrings("中文x", text(&screen, 1, &buffer));
    try std.testing.expectEqual(Wide.spacer, screen.row(1)[1].wide);
    // A wide character at the last column wraps whole.
    printAll(&screen, "\nabcd中");
    try std.testing.expectEqualStrings("abcd", text(&screen, 0, &buffer));
    try std.testing.expectEqualStrings("中", text(&screen, 1, &buffer));
    try std.testing.expectEqual(@as(u64, 3), screen.pushed);
    const oldest = screen.rowAt(screen.firstRow()).?;
    try std.testing.expectEqual(@as(usize, 5), oldest.cells.len);
    try std.testing.expect(oldest.wrapped);
    // Overwriting half a wide character blanks the other half.
    screen.moveTo(1, 1);
    screen.print('z');
    try std.testing.expectEqual(@as(u21, 0), screen.row(1)[0].cp);
    try std.testing.expectEqual(@as(u21, 'z'), screen.row(1)[1].cp);
}

test "scrollback drops the oldest lines within its cell budget" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 8, .rows = 1, .scrollback = 100, .scrollback_cells = 12 });
    defer screen.deinit();
    printAll(&screen, "aaaa\nbbbb\ncccc\ndddd\n");
    try std.testing.expectEqual(@as(u64, 4), screen.pushed);
    // Twelve cells hold three lines of four.
    try std.testing.expectEqual(@as(usize, 3), screen.history.count);
    try std.testing.expectEqual(@as(u21, 'b'), screen.rowAt(screen.firstRow()).?.cells[0].cp);
    try std.testing.expect(screen.rowAt(0) == null);
    printAll(&screen, "eeeeeee\n");
    try std.testing.expectEqual(@as(u21, 'e'), screen.rowAt(screen.pushed - 1).?.cells[6].cp);
    try std.testing.expectEqual(@as(u21, 'd'), screen.rowAt(screen.firstRow()).?.cells[0].cp);
    try std.testing.expect(screen.history.count == 2);
    // Empty lines take no cells.
    printAll(&screen, "\n\n\n");
    try std.testing.expectEqual(@as(usize, 5), screen.history.count);
}

test "editing inside the scrolling region" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 4, .rows = 4, .scrollback = 10 });
    defer screen.deinit();
    var buffer: [64]u8 = undefined;
    printAll(&screen, "1111\n2222\n3333\n4444");
    screen.setRegion(1, 2);
    screen.moveTo(0, 2);
    screen.index();
    try std.testing.expectEqualStrings("1111", text(&screen, 0, &buffer));
    try std.testing.expectEqualStrings("3333", text(&screen, 1, &buffer));
    try std.testing.expectEqualStrings("", text(&screen, 2, &buffer));
    try std.testing.expectEqualStrings("4444", text(&screen, 3, &buffer));
    // Lines leaving a region below the top do not reach the scrollback.
    try std.testing.expectEqual(@as(usize, 0), screen.history.count);
    screen.moveTo(0, 1);
    screen.reverseIndex();
    try std.testing.expectEqualStrings("", text(&screen, 1, &buffer));
    try std.testing.expectEqualStrings("3333", text(&screen, 2, &buffer));
    screen.top = 0;
    screen.bottom = 3;
    screen.modes.origin = false;
    screen.moveTo(1, 3);
    screen.insertChars(2);
    try std.testing.expectEqualStrings("4  4", text(&screen, 3, &buffer));
    screen.deleteChars(1);
    try std.testing.expectEqualStrings("4 4", text(&screen, 3, &buffer));
    screen.eraseLine(.below);
    try std.testing.expectEqualStrings("4", text(&screen, 3, &buffer));
    screen.moveTo(0, 0);
    screen.deleteLines(1);
    try std.testing.expectEqualStrings("", text(&screen, 0, &buffer));
    try std.testing.expectEqualStrings("3333", text(&screen, 1, &buffer));
    screen.insertLines(1);
    try std.testing.expectEqualStrings("", text(&screen, 1, &buffer));
}

test "alternate screen keeps the primary and its cursor" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer screen.deinit();
    var buffer: [64]u8 = undefined;
    printAll(&screen, "ab");
    screen.useAlternate(true, true, true);
    try std.testing.expectEqualStrings("", text(&screen, 0, &buffer));
    printAll(&screen, "\nxy");
    screen.useAlternate(false, true, true);
    try std.testing.expectEqualStrings("ab", text(&screen, 0, &buffer));
    try std.testing.expectEqual(@as(u16, 2), screen.cursor.x);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor.y);
}

test "resizing keeps the cursor's line and trades rows with the scrollback" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 6, .rows = 4, .scrollback = 10 });
    defer screen.deinit();
    var buffer: [64]u8 = undefined;
    printAll(&screen, "one\ntwo\nthree\nfour");
    try screen.resize(3, 2);
    try std.testing.expectEqual(@as(usize, 2), screen.history.count);
    try std.testing.expectEqualStrings("thr", text(&screen, 0, &buffer));
    try std.testing.expectEqualStrings("fou", text(&screen, 1, &buffer));
    try std.testing.expectEqual(@as(u16, 1), screen.cursor.y);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor.x);
    try screen.resize(6, 4);
    try std.testing.expectEqual(@as(usize, 0), screen.history.count);
    try std.testing.expectEqualStrings("one", text(&screen, 0, &buffer));
    try std.testing.expectEqual(@as(u16, 3), screen.cursor.y);
    // Text cut by the narrower screen stays cut.
    try std.testing.expectEqualStrings("thr", text(&screen, 2, &buffer));
}

test "tabs, charsets and repeat" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer screen.deinit();
    screen.tabForward(1);
    try std.testing.expectEqual(@as(u16, 8), screen.cursor.x);
    screen.tabForward(5);
    try std.testing.expectEqual(@as(u16, 19), screen.cursor.x);
    screen.tabBackward(1);
    try std.testing.expectEqual(@as(u16, 16), screen.cursor.x);
    screen.moveTo(0, 0);
    screen.designate(0, .dec_graphics);
    screen.print('q');
    screen.designate(0, .ascii);
    screen.print('q');
    screen.repeat(2);
    try std.testing.expectEqual(@as(u21, 0x2500), screen.row(0)[0].cp);
    try std.testing.expectEqual(@as(u21, 'q'), screen.row(0)[3].cp);
}

test "the view scrolls back and follows new lines" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 4, .rows = 2, .scrollback = 10 });
    defer screen.deinit();
    printAll(&screen, "a\nb\nc\nd");
    try std.testing.expect(screen.scrollView(5));
    try std.testing.expectEqual(@as(usize, 2), screen.viewportOffset());
    try std.testing.expectEqual(@as(u21, 'a'), screen.rowAt(screen.viewRow(0)).?.cells[0].cp);
    printAll(&screen, "\ne");
    try std.testing.expectEqual(@as(u21, 'a'), screen.rowAt(screen.viewRow(0)).?.cells[0].cp);
    try std.testing.expect(screen.scrollViewToBottom());
    try std.testing.expectEqual(@as(u21, 'd'), screen.rowAt(screen.viewRow(0)).?.cells[0].cp);
}

test "a user's clear keeps the cursor's line at the top" {
    var screen = try Screen.init(std.testing.allocator, .{ .cols = 4, .rows = 3, .scrollback = 10 });
    defer screen.deinit();
    printAll(&screen, "a\nb\nc\nd\n$ x");
    try std.testing.expect(screen.historyCount() > 0);
    try std.testing.expect(screen.clearToCursor());
    try std.testing.expectEqual(@as(usize, 0), screen.historyCount());
    try std.testing.expectEqual(@as(u16, 0), screen.cursor.y);
    try std.testing.expectEqual(@as(u21, '$'), screen.row(0)[0].cp);
    try std.testing.expect(screen.row(1)[0].isBlank());
    screen.useAlternate(true, true, true);
    try std.testing.expect(!screen.clearToCursor());
}
