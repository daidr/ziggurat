//! Virtual collections for declarative views: a table whose columns the
//! user resizes, moves and sorts, an outline (a tree of rows, optionally in
//! a table's columns) and a grid view of items. Each one paints only the
//! rows in view, so collections of millions of rows cost what small ones
//! do, and asks the application for a row's content only while it shows.
//!
//! The application owns every state value (`TableState`, `OutlineState`,
//! `GridState`) at a stable address: it must stay valid while any pass that
//! builds the collection runs and until the window stops routing input to
//! it. Rows are known by the keys the application gives them, so the choice
//! (`Selection`) and the place in the list follow items as rows are sorted,
//! inserted or removed. Rows of one collection share one height. The
//! collection is one focusable embedded leaf of the view that draws its rows
//! itself; assistive technology sees it as a table, a tree or a list whose
//! rows in view are its items. Nothing here allocates.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");

const View = view.View;
const Rect = view.Rect;
const Point = view.Point;
const Size = view.Size;
const Theme = view.Theme;
const Font = view.Font;
pub const Error = view.Error || error{ TooManyColumns, RowsFull, InvalidColumns };
pub const SortDirection = view.SortDirection;
pub const ImageView = view.ImageView;

/// Most columns of one table.
pub const max_columns = 64;
/// Most columns a table sorts by at once.
pub const max_sort_keys = 8;
/// Most rows in view that assistive technology sees as items in one frame;
/// the window's semantic tree holds 128 nodes in all.
pub const max_semantic_rows = 40;
/// Most levels of an outline.
pub const max_depth = 64;
/// How far, in rows, a collection looks for the item it kept at its top
/// after the rows change.
pub const anchor_search = 4096;
/// How far back a table looks for the section header of the row at its top.
pub const header_search = 4096;
/// Longest pause, in nanoseconds, between letters typed to find a row.
pub const type_ahead_time: u64 = 1000 * std.time.ns_per_ms;
/// Width of the zone at a column header's trailing edge that resizes it.
pub const resize_zone: f32 = 4;
/// Distance from the top or bottom edge within which a drag scrolls.
pub const edge_zone: f32 = view.drag_scroll_edge;
/// Fastest drag scrolling, in DIP per second.
pub const edge_speed: f32 = 1200;
/// Thickness of the scroll indicators and of the zone that drags them.
pub const scroll_bar: f32 = 6;
const frame_interval: u64 = 16_666_667;
const cell_padding: f32 = 8;
const scratch_len = 512;

pub fn partId(id: u64, part: u64) u64 {
    const value = std.hash.Wyhash.hash(id, std.mem.asBytes(&part));
    return if (value == 0) 1 else value;
}
const header_part: u64 = 0x6865_6164_6572;
const column_part: u64 = 0x636f_6c75_6d6e_0000;

// -------------------------------------------------------------- selection

/// The keys of the chosen items of a collection, kept sorted in storage the
/// application provides; its length is the most that can be chosen at once.
/// Keys of items gone from the collection stay until the application takes
/// them out.
pub const Selection = struct {
    pub const Mode = enum { single, multiple };
    mode: Mode = .single,
    storage: []u64,
    len: usize = 0,
    /// The item a Shift range starts from.
    anchor: ?u64 = null,
    /// The item with the keyboard cursor; in multiple mode it may be
    /// unchosen.
    cursor: ?u64 = null,
    /// Counts changes to the chosen set.
    version: u64 = 0,

    pub fn init(mode: Mode, storage: []u64) Selection {
        return .{ .mode = mode, .storage = storage };
    }
    /// The chosen keys, in ascending order of key.
    pub fn items(self: *const Selection) []const u64 {
        return self.storage[0..self.len];
    }
    fn find(self: *const Selection, key: u64) struct { found: bool, at: usize } {
        var low: usize = 0;
        var high = self.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.storage[middle] < key) low = middle + 1 else high = middle;
        }
        return .{ .found = low < self.len and self.storage[low] == key, .at = low };
    }
    pub fn contains(self: *const Selection, key: u64) bool {
        return self.find(key).found;
    }
    pub fn clear(self: *Selection) void {
        if (self.len == 0) return;
        self.len = 0;
        self.version += 1;
    }
    /// Add `key`; in single mode it replaces the chosen item.
    pub fn add(self: *Selection, key: u64) error{SelectionFull}!void {
        if (self.mode == .single) {
            if (self.len == 1 and self.storage[0] == key) return;
            if (self.storage.len == 0) return error.SelectionFull;
            self.storage[0] = key;
            self.len = 1;
            self.version += 1;
            return;
        }
        const place = self.find(key);
        if (place.found) return;
        if (self.len == self.storage.len) return error.SelectionFull;
        std.mem.copyBackwards(u64, self.storage[place.at + 1 .. self.len + 1], self.storage[place.at..self.len]);
        self.storage[place.at] = key;
        self.len += 1;
        self.version += 1;
    }
    /// Take `key` out; false when it was not chosen.
    pub fn remove(self: *Selection, key: u64) bool {
        const place = self.find(key);
        if (!place.found) return false;
        std.mem.copyForwards(u64, self.storage[place.at .. self.len - 1], self.storage[place.at + 1 .. self.len]);
        self.len -= 1;
        self.version += 1;
        return true;
    }
    /// Choose only `key` and move the cursor and the anchor to it.
    pub fn set(self: *Selection, key: u64) error{SelectionFull}!void {
        if (!(self.len == 1 and self.storage[0] == key)) {
            if (self.storage.len == 0) return error.SelectionFull;
            self.storage[0] = key;
            self.len = 1;
            self.version += 1;
        }
        self.anchor = key;
        self.cursor = key;
    }
    /// Begin adding many keys: append them with `push`, then `commit`
    /// sorts them in. Nothing changes when `commit` is not reached.
    fn push(self: *Selection, tail: *usize, key: u64) error{SelectionFull}!void {
        if (self.len + tail.* == self.storage.len) return error.SelectionFull;
        self.storage[self.len + tail.*] = key;
        tail.* += 1;
    }
    fn commit(self: *Selection, tail: usize) void {
        if (tail == 0) return;
        const all = self.storage[0 .. self.len + tail];
        std.mem.sort(u64, all, {}, std.sort.asc(u64));
        var out: usize = 0;
        for (all, 0..) |key, index| {
            if (index > 0 and key == all[out - 1]) continue;
            all[out] = key;
            out += 1;
        }
        if (out != self.len) self.version += 1;
        self.len = out;
    }
};

// ------------------------------------------------------------------ types

pub const Align = enum { start, center, end };
/// Where a row scrolled to shows in the collection.
pub const ScrollAlign = enum { nearest, start, center, end };

/// One column of a table.
pub const Column = struct {
    /// Identity of the column in `TableState.layout`; 0 uses its title.
    id: u64 = 0,
    title: []const u8,
    /// Width in DIP, or 0 to share the room the other columns leave.
    width: f32 = 0,
    min_width: f32 = 40,
    max_width: f32 = 4096,
    alignment: Align = .start,
    /// A click on the header sorts the rows by the column.
    sortable: bool = false,
    /// The column keeps its place and its width: the user neither moves
    /// nor resizes it. Fixed columns at the start stay in view while the
    /// table scrolls sideways.
    fixed: bool = false,
    /// The column heads its rows, as a spreadsheet's row numbers: with
    /// `cell_select` a click on its cells chooses whole rows and a click on
    /// its header every row. It does not sort.
    row_header: bool = false,

    fn identity(self: Column) u64 {
        return if (self.id != 0) self.id else view.key(self.title);
    }
};
/// One column's place and width, as `TableState.layout` saves them.
pub const ColumnWidth = struct { id: u64, width: f32 };
/// The order a table is sorted in: a column (its index in the columns the
/// table is built with) and a direction.
pub const SortOrder = view.Sort;
/// The columns a table sorts by, the first first.
pub const SortKeys = struct {
    items_storage: [max_sort_keys]SortOrder = undefined,
    len: usize = 0,
    pub fn items(self: *const SortKeys) []const SortOrder {
        return self.items_storage[0..self.len];
    }
    pub fn clear(self: *SortKeys) void {
        self.len = 0;
    }
    pub fn indexOf(self: *const SortKeys, column: usize) ?usize {
        for (self.items(), 0..) |entry, index| if (entry.column == column) return index;
        return null;
    }
    fn remove(self: *SortKeys, at: usize) void {
        std.mem.copyForwards(SortOrder, self.items_storage[at .. self.len - 1], self.items_storage[at + 1 .. self.len]);
        self.len -= 1;
    }
    fn append(self: *SortKeys, entry: SortOrder) void {
        if (self.len == max_sort_keys) return;
        self.items_storage[self.len] = entry;
        self.len += 1;
    }
};
/// A block of chosen cells: the chosen rows times the columns from `anchor`
/// to `cursor` in the order shown, or every column with `all`. Columns are
/// indices into the columns the table is built with.
pub const Cells = struct {
    anchor: usize = 0,
    cursor: usize = 0,
    all: bool = false,
};
/// What a table cell shows. Text is copied while the cell paints, so it may
/// live in the scratch buffer the cell function is given.
pub const Cell = struct {
    text: []const u8 = "",
    /// Text color; the theme's text, or the accent's text when chosen.
    color: ?u32 = null,
    font: ?Font = null,
    /// A square picture before the text, as an icon.
    image: ?ImageView = null,
};
/// The rows of a table or the items of a grid view.
pub const Rows = struct {
    /// Passed to every function below; it stays valid while the collection
    /// is built, paints and takes input.
    context: ?*const anyopaque = null,
    count: usize,
    /// A nonzero key for the item of a row, unique in the collection: the
    /// choice and the place in the list follow it. Without it, the key of
    /// row `i` is `i + 1`.
    key: ?*const fn (?*const anyopaque, usize) u64 = null,
    /// The text of a row: typing its first letters while the collection
    /// has focus chooses it, and assistive technology reads it as the row's
    /// name. A table without it uses the text of its first column.
    label: ?*const fn (?*const anyopaque, usize, []u8) []const u8 = null,
    /// Rows heading sections: they span every column (a table builds them
    /// as column 0) and the one heading the rows at the top stays pinned
    /// there until the next one pushes it away.
    header: ?*const fn (?*const anyopaque, usize) bool = null,
};
/// A table's cell content for a row and a column (an index into the
/// columns the table is built with).
pub const CellSource = struct {
    context: ?*const anyopaque = null,
    call: *const fn (?*const anyopaque, usize, usize, []u8) Cell,
};
/// A cell, by row and column.
pub const CellRef = struct { row: usize, column: usize };
/// Rows dragged to another place: `row` is the row dragged, and `to` the
/// row they go before (the count of rows for the end). With `selection`,
/// the dragged row was chosen, and every chosen row moves.
pub const Move = struct { row: usize, to: usize, selection: bool };

/// What a pass of a collection reports.
pub const Result = struct {
    /// The user changed the choice.
    changed: bool = false,
    /// Enter on the cursor row, or a double click on a row.
    submitted: ?usize = null,
    /// A double click, on the row and the column under the pointer.
    double_clicked: ?CellRef = null,
    /// The user sorted the table again.
    sorted: bool = false,
    /// The user resized or moved columns; save `TableState.layout`.
    arranged: bool = false,
    /// The user dragged rows to another place; move them.
    moved: ?Move = null,
    /// The user opened or closed outline items.
    toggled: bool = false,
    /// A drag is choosing rows while the pointer holds it.
    drag_selecting: bool = false,

    fn merge(self: *Result, other: Result) void {
        self.changed = self.changed or other.changed;
        if (other.submitted) |row| self.submitted = row;
        if (other.double_clicked) |cell| self.double_clicked = cell;
        self.sorted = self.sorted or other.sorted;
        self.arranged = self.arranged or other.arranged;
        if (other.moved) |move| self.moved = move;
        self.toggled = self.toggled or other.toggled;
    }
};

// ------------------------------------------------------------------- core

const Shape = enum { table, outline, grid };
const Request = struct { row: usize, alignment: ScrollAlign };
const Op = enum { set, toggle, range, range_add, cursor };

const Press = union(enum) {
    none,
    rows: struct { index: usize, column: ?usize, deferred: bool, add: bool, reordering: bool = false, selecting: bool = false, row_header: bool = false },
    header: struct { column: usize, moving: bool = false, modifiers: z.KeyModifiers },
    resize: struct { column: usize, start: f32 },
    thumb: struct { vertical: bool, start_scroll: f64, origin: f32 },
};

/// State shared by every collection; reached through its owner.
const Core = struct {
    shape: Shape,
    id: u64 = 0,
    enabled: bool = true,
    name_storage: [128]u8 = undefined,
    name_len: usize = 0,
    rows: Rows = .{ .count = 0 },
    selection: ?*Selection = null,
    row_height: f32 = 28,
    header_height: f32 = 0,
    measurer: view.Measurer = .{},
    drag_select: bool = false,
    reorder: bool = false,
    follow_end: bool = false,
    keep_offset: bool = false,
    round_rows: bool = false,
    // Grid geometry.
    item_width: f32 = 120,
    item_height: f32 = 120,
    gap: f32 = 8,
    grid_columns: usize = 1,
    /// Window bounds of the last paint.
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    placed: bool = false,
    focused: bool = false,
    scroll_y: f64 = 0,
    scroll_x: f32 = 0,
    top_key: u64 = 0,
    top_index: usize = 0,
    top_count: usize = 0,
    content_seen: f64 = -1,
    at_end: bool = true,
    request: ?Request = null,
    cursor_hint: usize = 0,
    anchor_hint: usize = 0,
    hover: ?usize = null,
    press: Press = .none,
    pointer: Point = .{},
    pointer_inside: bool = false,
    edge: Point = .{},
    tick: ?u64 = null,
    drag_base: [256]u64 = undefined,
    drag_base_len: usize = 0,
    drag_base_complete: bool = true,
    reorder_target: ?usize = null,
    pending: Result = .{},
    typed: [32]u8 = undefined,
    typed_len: usize = 0,
    typed_time: u64 = 0,
    typing: [8]u8 = undefined,
    typing_len: usize = 0,
    exposed: [max_semantic_rows]u64 = undefined,
    exposed_len: usize = 0,
    /// The first error that input or paint could not return, such as
    /// `SelectionFull`; the application may clear it.
    last_error: ?anyerror = null,

    fn name(self: *const Core) []const u8 {
        return self.name_storage[0..self.name_len];
    }
    fn setName(self: *Core, value: []const u8) void {
        var length = @min(value.len, self.name_storage.len);
        while (length > 0 and length < value.len and value[length] & 0xc0 == 0x80) length -= 1;
        @memcpy(self.name_storage[0..length], value[0..length]);
        self.name_len = length;
    }
    fn fail(self: *Core, err: anyerror) void {
        if (self.last_error == null) self.last_error = err;
    }

    fn keyAt(self: *const Core, index: usize) u64 {
        if (self.rows.key) |call| return call(self.rows.context, index);
        return @as(u64, index) + 1;
    }
    /// The row of `key`, trying `hint` first.
    fn indexOf(self: *const Core, key: u64, hint: usize) ?usize {
        const count = self.rows.count;
        if (count == 0) return null;
        if (hint < count and self.keyAt(hint) == key) return hint;
        if (self.rows.key == null) return if (key >= 1 and key <= count) @intCast(key - 1) else null;
        for (0..count) |index| if (self.keyAt(index) == key) return index;
        return null;
    }
    fn cursorIndex(self: *Core) ?usize {
        const selection = self.selection orelse return null;
        const key = selection.cursor orelse return null;
        const index = self.indexOf(key, self.cursor_hint) orelse return null;
        self.cursor_hint = index;
        return index;
    }
    fn anchorIndex(self: *Core) ?usize {
        const selection = self.selection orelse return null;
        const key = selection.anchor orelse return null;
        const index = self.indexOf(key, self.anchor_hint) orelse return null;
        self.anchor_hint = index;
        return index;
    }
    fn selected(self: *const Core, index: usize) bool {
        const selection = self.selection orelse return false;
        return selection.contains(self.keyAt(index));
    }
    fn multiple(self: *const Core) bool {
        return if (self.selection) |selection| selection.mode == .multiple else false;
    }

    // Geometry, in coordinates local to the leaf.
    fn bodyTop(self: *const Core) f32 {
        return self.header_height;
    }
    fn bodyHeight(self: *const Core) f32 {
        return @max(0, self.bounds.height - self.header_height);
    }
    fn stride(self: *const Core) f64 {
        return if (self.shape == .grid) self.item_height + self.gap else self.row_height;
    }
    /// Rows of the layout: table rows, or lines of grid items.
    fn lines(self: *const Core) usize {
        if (self.shape != .grid) return self.rows.count;
        return (self.rows.count + self.grid_columns - 1) / self.grid_columns;
    }
    fn contentHeight(self: *const Core) f64 {
        const count: f64 = @floatFromInt(self.lines());
        if (self.shape == .grid) return if (count == 0) 0 else count * self.stride() - self.gap + 2 * self.gap;
        return count * self.stride();
    }
    fn maxScroll(self: *const Core) f64 {
        return @max(0, self.contentHeight() - self.bodyHeight());
    }
    fn clampScroll(self: *Core) void {
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.maxScroll());
    }
    /// Lines that fully fit the body, at least one.
    fn page(self: *const Core) usize {
        const value = @floor(@as(f64, self.bodyHeight()) / self.stride());
        return @max(1, @as(usize, @intFromFloat(@max(0, value))));
    }
    fn lineTop(self: *const Core, line: usize) f64 {
        const offset: f64 = if (self.shape == .grid) self.gap else 0;
        return offset + @as(f64, @floatFromInt(line)) * self.stride();
    }
    fn lineOf(self: *const Core, index: usize) usize {
        return if (self.shape == .grid) index / self.grid_columns else index;
    }
    /// First and one past the last line intersecting the body.
    fn visibleLines(self: *const Core) struct { first: usize, end: usize } {
        const total = self.lines();
        if (total == 0 or self.bodyHeight() <= 0) return .{ .first = 0, .end = 0 };
        const step = self.stride();
        const offset: f64 = if (self.shape == .grid) self.gap else 0;
        const first: usize = @intFromFloat(@max(0, @floor((self.scroll_y - offset) / step)));
        const last: usize = @intFromFloat(@max(0, @ceil((self.scroll_y + self.bodyHeight() - offset) / step)));
        return .{ .first = @min(first, total), .end = @min(@max(last, first + 1), total) };
    }
    fn scrollToLine(self: *Core, line: usize, alignment: ScrollAlign) void {
        const top = self.lineTop(line);
        const height: f64 = if (self.shape == .grid) self.item_height else self.row_height;
        const viewport: f64 = self.bodyHeight();
        const margin: f64 = if (self.shape == .grid) self.gap else 0;
        self.scroll_y = switch (alignment) {
            .start => top - margin,
            .end => top + height + margin - viewport,
            .center => top + height / 2 - viewport / 2,
            .nearest => if (top - margin < self.scroll_y or height + 2 * margin > viewport) top - margin else if (top + height + margin > self.scroll_y + viewport) top + height + margin - viewport else self.scroll_y,
        };
        self.clampScroll();
    }
    fn reveal(self: *Core, index: usize) void {
        if (!self.placed) {
            self.request = .{ .row = index, .alignment = .nearest };
            return;
        }
        self.scrollToLine(self.lineOf(index), .nearest);
    }
    fn resolveRequest(self: *Core) void {
        const request = self.request orelse return;
        if (!self.placed) return;
        self.request = null;
        if (self.rows.count == 0) return;
        self.scrollToLine(self.lineOf(@min(request.row, self.rows.count - 1)), request.alignment);
    }

    /// Keep the item at the top in place, or the end in view, as the rows
    /// change. Runs while building.
    fn follow(self: *Core) void {
        const count = self.rows.count;
        if (!self.placed) return;
        if (self.follow_end and self.at_end) {
            // The paint keeps the end in view.
        } else if (!self.keep_offset and self.rows.key != null and self.top_key != 0 and count > 0 and self.shape != .grid) {
            const old = self.top_index;
            if (old >= count or self.keyAt(old) != self.top_key) {
                const low = old -| anchor_search;
                const high = @min(count, old + anchor_search);
                var found: ?usize = null;
                var distance: usize = 0;
                while (distance <= anchor_search and found == null) : (distance += 1) {
                    if (old >= distance and old - distance >= low and old - distance < high and self.keyAt(old - distance) == self.top_key) found = old - distance;
                    if (found == null and old + distance < high and self.keyAt(old + distance) == self.top_key) found = old + distance;
                }
                if (found) |index| {
                    const delta = (@as(f64, @floatFromInt(index)) - @as(f64, @floatFromInt(old))) * self.stride();
                    self.scroll_y += delta;
                    self.top_index = index;
                }
            }
        }
        self.top_count = count;
        self.clampScroll();
    }
    /// Record what is at the top, after a paint settled the scroll. A
    /// collection following its end goes on showing it as content grows.
    fn settle(self: *Core) void {
        const content = self.contentHeight();
        if (self.follow_end and self.at_end and content != self.content_seen) self.scroll_y = self.maxScroll();
        self.content_seen = content;
        self.clampScroll();
        self.at_end = self.scroll_y >= self.maxScroll() - 0.5;
        const range = self.visibleLines();
        if (range.end > range.first and self.shape != .grid) {
            self.top_index = range.first;
            self.top_key = self.keyAt(range.first);
        } else {
            self.top_key = 0;
        }
    }

    // Choosing.
    fn choose(self: *Core, index: usize, op: Op) void {
        const selection = self.selection orelse return;
        if (index >= self.rows.count) return;
        const key = self.keyAt(index);
        const before = selection.version;
        const multi = selection.mode == .multiple;
        switch (op) {
            .set => selection.set(key) catch |err| self.fail(err),
            .toggle => if (!multi) {
                selection.set(key) catch |err| self.fail(err);
            } else {
                if (!selection.remove(key)) selection.add(key) catch |err| self.fail(err);
                selection.anchor = key;
                selection.cursor = key;
            },
            .cursor => if (multi) {
                selection.cursor = key;
            } else selection.set(key) catch |err| self.fail(err),
            .range, .range_add => if (!multi) {
                selection.set(key) catch |err| self.fail(err);
            } else {
                const from = self.anchorIndex() orelse index;
                if (op == .range) selection.clear();
                self.addRange(from, index);
                selection.anchor = self.keyAt(from);
                selection.cursor = key;
                self.anchor_hint = from;
            },
        }
        self.cursor_hint = index;
        if (selection.version != before) self.pending.changed = true;
    }
    fn addRange(self: *Core, from: usize, to: usize) void {
        const selection = self.selection orelse return;
        const low = @min(from, to);
        const high = @max(from, to);
        var tail: usize = 0;
        var index = low;
        while (index <= high) : (index += 1) {
            selection.push(&tail, self.keyAt(index)) catch |err| {
                self.fail(err);
                break;
            };
        }
        selection.commit(tail);
    }
    fn chooseAll(self: *Core) void {
        const selection = self.selection orelse return;
        if (selection.mode != .multiple or self.rows.count == 0) return;
        if (self.rows.count > selection.storage.len) {
            self.fail(error.SelectionFull);
            return;
        }
        const before = selection.version;
        self.addRange(0, self.rows.count - 1);
        if (selection.cursor == null) selection.cursor = self.keyAt(0);
        if (selection.version != before) self.pending.changed = true;
    }
    /// Move the cursor to `index` as a key with `modifiers` does.
    fn navigate(self: *Core, index: usize, modifiers: z.KeyModifiers) void {
        if (self.rows.count == 0) return;
        const target = @min(index, self.rows.count - 1);
        const op: Op = if (modifiers.shift and modifiers.control) .range_add else if (modifiers.shift) .range else if (modifiers.control) .cursor else .set;
        self.choose(target, op);
        self.reveal(target);
    }

    // Drag choosing.
    fn beginDragChoice(self: *Core, add: bool) void {
        self.drag_base_len = 0;
        self.drag_base_complete = true;
        const selection = self.selection orelse return;
        if (!add) return;
        for (selection.items()) |key| {
            if (self.drag_base_len == self.drag_base.len) {
                self.drag_base_complete = false;
                break;
            }
            self.drag_base[self.drag_base_len] = key;
            self.drag_base_len += 1;
        }
    }
    fn dragChoice(self: *Core, from: usize, to: usize, add: bool) void {
        const selection = self.selection orelse return;
        if (selection.mode == .single) {
            self.choose(to, .set);
            return;
        }
        const before = selection.version;
        if (!add or self.drag_base_complete) {
            selection.clear();
            var tail: usize = 0;
            for (self.drag_base[0..self.drag_base_len]) |key| selection.push(&tail, key) catch break;
            selection.commit(tail);
        }
        self.addRange(from, to);
        selection.anchor = self.keyAt(from);
        selection.cursor = self.keyAt(to);
        self.anchor_hint = from;
        self.cursor_hint = to;
        if (selection.version != before) self.pending.changed = true;
    }

    // Type to find.
    fn typeAhead(self: *Core, now: u64) void {
        if (self.typing_len == 0) return;
        defer self.typing_len = 0;
        if (self.typed_len > 0 and now -| self.typed_time > type_ahead_time) self.typed_len = 0;
        self.typed_time = now;
        for (self.typing[0..self.typing_len]) |char| {
            if (self.typed_len < self.typed.len) {
                self.typed[self.typed_len] = char;
                self.typed_len += 1;
            }
        }
        const count = self.rows.count;
        if (count == 0) return;
        const prefix = self.typed[0..self.typed_len];
        // The same letter again moves to the next row starting with it.
        const repeated = blk: {
            for (prefix[1..]) |char| if (char != prefix[0]) break :blk false;
            break :blk prefix.len > 1;
        };
        const needle = if (repeated) prefix[0..1] else prefix;
        const start = self.cursorIndex() orelse 0;
        const first_offset: usize = if (repeated or prefix.len == 1) 1 else 0;
        var buffer: [scratch_len]u8 = undefined;
        var step: usize = 0;
        while (step < count) : (step += 1) {
            const index = (start + first_offset + step) % count;
            const text = self.labelOf(index, &buffer);
            if (startsWithIgnoreCase(text, needle)) {
                self.choose(index, .set);
                self.reveal(index);
                return;
            }
        }
    }
    fn labelOf(self: *Core, index: usize, buffer: []u8) []const u8 {
        if (self.rows.label) |call| return call(self.rows.context, index, buffer);
        if (self.shape != .grid) {
            const owner = self.table();
            if (owner.cells_source) |source| {
                const column = if (owner.column_count > 0) owner.firstTextColumn() else 0;
                const text = source.call(source.context, index, column, buffer).text;
                return text;
            }
        }
        return "";
    }
    fn table(self: *Core) *TableState {
        return @fieldParentPtr("core", self);
    }
    fn cursorColumn(self: *Core) usize {
        const cells = self.table().cells orelse return 0;
        return cells.cursor;
    }

    fn noteKey(self: *Core, press: z.KeyInput) bool {
        if (press.modifiers.control or press.modifiers.alt or press.modifiers.super) return false;
        const char: u8 = switch (press.key) {
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => 'a' + @as(u8, @intCast(@intFromEnum(press.key) - @intFromEnum(z.KeyCode.a))),
            .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9 => '0' + @as(u8, @intCast(@intFromEnum(press.key) - @intFromEnum(z.KeyCode.digit0))),
            .space => if (self.typed_len > 0) ' ' else return false,
            else => return false,
        };
        if (self.typing_len < self.typing.len) {
            self.typing[self.typing_len] = char;
            self.typing_len += 1;
        }
        return true;
    }

    /// Drag scrolling near or past the body's top and bottom, applied as
    /// passes run; asks for another pass while it continues.
    fn setEdge(self: *Core, local: Point) void {
        const top = self.bodyTop();
        const bottom = top + self.bodyHeight();
        var speed: f32 = 0;
        if (local.y < top + edge_zone) speed = -@min(1, (top + edge_zone - local.y) / (edge_zone * 2)) * edge_speed;
        if (local.y > bottom - edge_zone) speed = @min(1, (local.y - (bottom - edge_zone)) / (edge_zone * 2)) * edge_speed;
        var sideways: f32 = 0;
        if (self.shape != .grid) {
            if (local.x < edge_zone) sideways = -@min(1, (edge_zone - local.x) / (edge_zone * 2)) * edge_speed;
            if (local.x > self.bounds.width - edge_zone) sideways = @min(1, (local.x - (self.bounds.width - edge_zone)) / (edge_zone * 2)) * edge_speed;
        }
        self.edge = .{ .x = sideways, .y = speed };
        if (speed == 0 and sideways == 0) self.tick = null;
    }
    fn stopEdge(self: *Core) void {
        self.edge = .{};
        self.tick = null;
    }

    fn buildSemantics(self: *Core, v: *View) void {
        // Assistive technology chooses, opens and closes the rows it saw.
        for (self.exposed[0..self.exposed_len]) |key| {
            const event = v.takeEvent(partId(self.id, key)) orelse continue;
            if (!self.enabled) continue;
            const index = self.indexOf(key, self.cursor_hint) orelse continue;
            switch (event) {
                .action => self.choose(index, .set),
                .value => |value| if (value.change == .set) {
                    const code: u8 = @intFromFloat(@max(0, value.change.set));
                    const selection = self.selection orelse continue;
                    const before = selection.version;
                    switch (code) {
                        @intFromEnum(view.ItemRequest.deselect) => _ = selection.remove(key),
                        @intFromEnum(view.ItemRequest.add) => selection.add(key) catch |err| self.fail(err),
                        @intFromEnum(view.ItemRequest.collapse), @intFromEnum(view.ItemRequest.expand) => if (self.shape != .grid) {
                            if (self.table().outline) |outline_state| outline_state.setOpen(index, code == @intFromEnum(view.ItemRequest.expand), false);
                        },
                        else => {},
                    }
                    if (selection.version != before) self.pending.changed = true;
                },
                else => {},
            }
        }
    }

    /// The common part of a pass: apply what input and time asked for and
    /// hand over the results.
    fn pass(self: *Core, v: *View) Result {
        self.follow();
        self.typeAhead(v.time());
        self.resolveRequest();
        if (self.edge.x != 0 or self.edge.y != 0) {
            const now = v.time();
            if (self.tick) |last| {
                const seconds: f32 = @floatCast(@min(0.1, @as(f64, @floatFromInt(now -| last)) / std.time.ns_per_s));
                self.scroll_y += self.edge.y * seconds;
                self.clampScroll();
                if (self.shape != .grid) {
                    const table_state = self.table();
                    table_state.scrollSideways(self.edge.x * seconds);
                }
                self.dragTo(self.pointer);
            }
            self.tick = now;
            v.wakeAt(now + frame_interval);
        }
        var result = self.pending;
        self.pending = .{};
        result.drag_selecting = switch (self.press) {
            .rows => |press| press.selecting,
            else => false,
        };
        return result;
    }

    /// Follow a drag at a local point: choose rows or place a reorder.
    fn dragTo(self: *Core, local: Point) void {
        switch (self.press) {
            .rows => |*press| {
                if (press.reordering) {
                    self.reorder_target = self.insertionAt(local);
                    return;
                }
                if (!press.selecting) return;
                const index = self.indexAt(local, true) orelse return;
                self.dragChoice(press.index, index, press.add);
                if (self.shape != .grid) {
                    const t = self.table();
                    if (t.cells) |cells| {
                        if (press.row_header) {
                            cells.all = true;
                        } else if (t.columnAt(local.x)) |column| {
                            if (press.column) |start| cells.anchor = start;
                            cells.cursor = column;
                            cells.all = false;
                        }
                    }
                }
            },
            else => {},
        }
    }
    /// The row under a local point; with `clamp`, the nearest row when the
    /// point is above or below them.
    fn indexAt(self: *const Core, local: Point, clamp: bool) ?usize {
        const count = self.rows.count;
        if (count == 0) return null;
        const y = @as(f64, local.y - self.bodyTop()) + self.scroll_y;
        if (self.shape == .grid) {
            const line_f = @floor((y - self.gap) / self.stride());
            const total_lines = self.lines();
            var line: usize = if (line_f < 0) 0 else @intFromFloat(line_f);
            if (line_f < 0 and !clamp) return null;
            if (line >= total_lines) {
                if (!clamp) return null;
                line = total_lines - 1;
            }
            const width = self.gridItemWidth();
            const column_f = @floor((local.x - self.gap) / (width + self.gap));
            var column: usize = if (column_f < 0) 0 else @intFromFloat(column_f);
            if (!clamp and (column_f < 0 or column >= self.grid_columns)) return null;
            column = @min(column, self.grid_columns - 1);
            if (!clamp) {
                const within_x = local.x - self.gap - @as(f32, @floatFromInt(column)) * (width + self.gap);
                const within_y = y - self.gap - @as(f64, @floatFromInt(line)) * self.stride();
                if (within_x > width or within_y > self.item_height) return null;
            }
            const index = line * self.grid_columns + column;
            return if (index < count) index else if (clamp) count - 1 else null;
        }
        if (y < 0) return if (clamp) 0 else null;
        const index: usize = @intFromFloat(@floor(y / self.row_height));
        if (index >= count) return if (clamp) count - 1 else null;
        return index;
    }
    /// The row a reorder drop at a local point goes before.
    fn insertionAt(self: *const Core, local: Point) usize {
        const y = @as(f64, local.y - self.bodyTop()) + self.scroll_y;
        if (self.shape == .grid) {
            const index = self.indexAt(local, true) orelse return 0;
            const width = self.gridItemWidth();
            const column = index % self.grid_columns;
            const middle = self.gap + @as(f32, @floatFromInt(column)) * (width + self.gap) + width / 2;
            return if (local.x > middle) index + 1 else index;
        }
        const value = @round(y / self.row_height);
        if (value <= 0) return 0;
        return @min(self.rows.count, @as(usize, @intFromFloat(value)));
    }
    fn gridItemWidth(self: *const Core) f32 {
        const columns: f32 = @floatFromInt(self.grid_columns);
        return @max(1, (self.bounds.width - self.gap * (columns + 1)) / columns);
    }

    fn wheel(self: *Core, delta: Point) bool {
        const before = self.scroll_y;
        const before_x = self.scroll_x;
        self.scroll_y += delta.y;
        self.clampScroll();
        if (self.shape != .grid) self.table().scrollSideways(delta.x);
        return self.scroll_y != before or self.scroll_x != before_x;
    }

    /// Keys every collection shares. Null for keys it leaves to its owner.
    fn sharedKey(self: *Core, press: z.KeyInput) ?bool {
        const mods = press.modifiers;
        const count = self.rows.count;
        if (mods.control and !mods.shift and !mods.alt and press.key == .a) {
            if (!self.multiple()) return false;
            self.chooseAll();
            if (self.shape != .grid) if (self.table().cells) |cells| {
                cells.all = true;
            };
            return true;
        }
        if (mods.alt or mods.super) return null;
        switch (press.key) {
            .enter => {
                if (press.repeat) return true;
                const index = self.cursorIndex() orelse return false;
                self.pending.submitted = index;
                return true;
            },
            .space => {
                if (self.typed_len > 0 and !mods.control and !mods.shift) return self.noteKey(press);
                const index = self.cursorIndex() orelse (if (count > 0) @as(usize, 0) else return false);
                self.choose(index, if (mods.control) .toggle else if (mods.shift) .range else .set);
                return true;
            },
            .home => {
                self.navigate(0, mods);
                return count > 0;
            },
            .end => {
                if (count == 0) return false;
                self.navigate(count - 1, mods);
                return true;
            },
            else => {},
        }
        if (self.noteKey(press)) return true;
        return null;
    }
};

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    for (prefix, text[0..prefix.len]) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    return true;
}
fn contains(rect: Rect, point: Point) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}
fn inset(rect: Rect, amount: f32) Rect {
    return .{ .x = rect.x + amount, .y = rect.y + amount, .width = @max(0, rect.width - 2 * amount), .height = @max(0, rect.height - 2 * amount) };
}
fn lastNode(v: *const View) *const view.Node {
    const all = v.nodes();
    return &all[all.len - 1];
}
fn focusedOn(frame: *ui.Frame, id: u64) bool {
    return frame.context.input_state.focused == id;
}
fn shift(rect: Rect, origin: Rect) Rect {
    return .{ .x = rect.x + origin.x, .y = rect.y + origin.y, .width = rect.width, .height = rect.height };
}
fn ring(frame: *ui.Frame, bounds: Rect, width: f32, color: u32) void {
    const w = @min(width, @min(bounds.width, bounds.height) / 2);
    frame.rect(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = w }, color);
    frame.rect(.{ .x = bounds.x, .y = bounds.y + bounds.height - w, .width = bounds.width, .height = w }, color);
    frame.rect(.{ .x = bounds.x, .y = bounds.y + w, .width = w, .height = @max(0, bounds.height - 2 * w) }, color);
    frame.rect(.{ .x = bounds.x + bounds.width - w, .y = bounds.y + w, .width = w, .height = @max(0, bounds.height - 2 * w) }, color);
}
/// A filled triangle from bounded strips, pointing right, down or up.
fn triangle(frame: *ui.Frame, bounds: Rect, direction: enum { right, down, up, left }, color: u32) void {
    const strips: f32 = 6;
    for (0..6) |i| {
        const t = @as(f32, @floatFromInt(i)) / strips;
        const narrow = 0.5 * t;
        switch (direction) {
            .down => frame.rect(.{ .x = bounds.x + bounds.width * narrow, .y = bounds.y + bounds.height * t, .width = bounds.width * (1 - 2 * narrow), .height = bounds.height / strips }, color),
            .up => frame.rect(.{ .x = bounds.x + bounds.width * narrow, .y = bounds.y + bounds.height * (1 - t - 1 / strips), .width = bounds.width * (1 - 2 * narrow), .height = bounds.height / strips }, color),
            .right => frame.rect(.{ .x = bounds.x + bounds.width * t, .y = bounds.y + bounds.height * narrow, .width = bounds.width / strips, .height = bounds.height * (1 - 2 * narrow) }, color),
            .left => frame.rect(.{ .x = bounds.x + bounds.width * (1 - t - 1 / strips), .y = bounds.y + bounds.height * narrow, .width = bounds.width / strips, .height = bounds.height * (1 - 2 * narrow) }, color),
        }
    }
}

fn paintScrollIndicators(frame: *ui.Frame, core: *const Core, origin: Rect, content_width: f32, view_width: f32, palette: ui.theme.Palette) void {
    const body: Rect = .{ .x = origin.x, .y = origin.y + core.bodyTop(), .width = origin.width, .height = core.bodyHeight() };
    const content = core.contentHeight();
    if (content > body.height and body.height > 0) {
        const track = body.height;
        const length: f32 = @floatCast(@max(16, @as(f64, track) * @as(f64, body.height) / content));
        const max = core.maxScroll();
        const ratio: f32 = if (max > 0) @floatCast(core.scroll_y / max) else 0;
        frame.roundedRect(.{ .x = body.x + body.width - scroll_bar - 1, .y = body.y + (track - length) * ratio, .width = scroll_bar, .height = length }, scroll_bar / 2, ui.Color.rgb(palette.track));
    }
    if (content_width > view_width and view_width > 0) {
        const length = @max(16, view_width * view_width / content_width);
        const max = content_width - view_width;
        const ratio = if (max > 0) core.scroll_x / max else 0;
        frame.roundedRect(.{ .x = body.x + (view_width - length) * ratio, .y = body.y + body.height - scroll_bar - 1, .width = length, .height = scroll_bar }, scroll_bar / 2, ui.Color.rgb(palette.track));
    }
}

// ------------------------------------------------------------------ table

pub const TableOptions = struct {
    /// Height of every row; the header is as high.
    row_height: f32 = 28,
    /// Show the header row of column titles.
    header: bool = true,
    /// Choose blocks of cells, with `cells`; needs a multiple `Selection`.
    cell_select: bool = false,
    /// A drag from a row chooses the rows it crosses, scrolling near the
    /// edges; needs a multiple `Selection`. Not with `reorder`.
    drag_select: bool = false,
    /// The user drags rows to another place; `Result.moved` reports it.
    reorder: bool = false,
    /// Start at the end and keep it in view as rows come, until the user
    /// scrolls away; scrolling back follows it again.
    follow_end: bool = false,
    /// Keep the scroll offset as rows change, rather than the item at the
    /// top, for rows sorted again as they change.
    keep_offset: bool = false,
    /// Round chosen and hovered rows at the theme's radius.
    round_rows: bool = false,
    /// Text extents for alignment and for fitting a column to its cells.
    measurer: view.Measurer = .{},
    /// Style of the leaf; `Style.name` names the table.
    style: view.Style = .{},
};

/// A table's state, owned by the application at a stable address.
pub const TableState = struct {
    core: Core = .{ .shape = .table },
    /// The choice; set before building. A single selection chooses one row.
    selection: ?*Selection = null,
    /// The column the rows are sorted by, kept the first of `sort_by`.
    sort: ?*?SortOrder = null,
    /// Sorting by several columns: Ctrl- or Shift-clicks add columns.
    sort_by: ?*SortKeys = null,
    /// The chosen block of cells, with `TableOptions.cell_select`.
    cells: ?*Cells = null,
    // The columns' place and width by id, in the order shown.
    ids: [max_columns]u64 = undefined,
    widths: [max_columns]f32 = undefined,
    order: [max_columns]u8 = undefined,
    column_count: usize = 0,
    restore_storage: [max_columns]ColumnWidth = undefined,
    restore_len: ?usize = null,
    /// The columns of this pass, borrowed while it paints and takes input.
    columns: []const Column = &.{},
    cells_source: ?CellSource = null,
    outline: ?*OutlineState = null,
    drag_column_x: f32 = 0,
    move_target: ?usize = null,

    /// The table's column layout in the order shown: each column's id and
    /// width (0 while it shares the room left). Save it as it changes.
    pub fn layout(self: *const TableState, out: []ColumnWidth) []ColumnWidth {
        const count = @min(out.len, self.column_count);
        for (0..count) |position| {
            const column = self.order[position];
            out[position] = .{ .id = self.ids[column], .width = self.widths[column] };
        }
        return out[0..count];
    }
    /// Restore a saved layout from the next pass: known columns take its
    /// order and widths, others follow in their own order.
    pub fn restore(self: *TableState, saved: []const ColumnWidth) void {
        const count = @min(saved.len, max_columns);
        @memcpy(self.restore_storage[0..count], saved[0..count]);
        self.restore_len = count;
    }
    /// Show row `row` at the start, center or end of the table, or scroll
    /// as little as shows it with `nearest`.
    pub fn scrollTo(self: *TableState, row: usize, alignment: ScrollAlign) void {
        self.core.request = .{ .row = row, .alignment = alignment };
        self.core.resolveRequest();
    }
    pub fn scrollIntoView(self: *TableState, row: usize) void {
        self.scrollTo(row, .nearest);
    }
    pub fn scrollToEnd(self: *TableState) void {
        self.core.scroll_y = std.math.floatMax(f64);
        self.core.clampScroll();
        self.core.at_end = true;
    }
    /// The first and the last rows in view, as of the last paint.
    pub fn visible(self: *const TableState) struct { first: usize, last: usize } {
        const range = self.core.visibleLines();
        return .{ .first = range.first, .last = if (range.end > 0) range.end - 1 else 0 };
    }
    /// Whether the end of the rows shows.
    pub fn atEnd(self: *const TableState) bool {
        return self.core.scroll_y >= self.core.maxScroll() - 0.5;
    }
    pub fn scrollOffset(self: *const TableState) f64 {
        return self.core.scroll_y;
    }
    pub fn setScrollOffset(self: *TableState, offset: f64) void {
        self.core.scroll_y = offset;
        self.core.clampScroll();
    }
    /// Choose the rows from the one Shift extends from to `row`, as a
    /// Shift-click on it does.
    pub fn extendTo(self: *TableState, row: usize) void {
        self.core.choose(row, .range);
    }
    /// Whether a cell is in the chosen block, for text of its own color on
    /// the accent.
    pub fn cellSelected(self: *TableState, row: usize, column: usize) bool {
        if (!self.core.selected(row)) return false;
        const cells = self.cells orelse return true;
        if (cells.all) return true;
        const at = self.positionOf(column) orelse return false;
        const a = self.positionOf(cells.anchor) orelse return false;
        const b = self.positionOf(cells.cursor) orelse return false;
        return at >= @min(a, b) and at <= @max(a, b);
    }
    /// The columns of the chosen block, as indices in the order shown.
    pub fn selectedColumns(self: *const TableState, out: []usize) []usize {
        const cells = self.cells orelse return out[0..0];
        var len: usize = 0;
        const a = self.positionOf(cells.anchor) orelse 0;
        const b = self.positionOf(cells.cursor) orelse 0;
        for (0..self.column_count) |position| {
            if (!cells.all and (position < @min(a, b) or position > @max(a, b))) continue;
            if (len == out.len) break;
            out[len] = self.order[position];
            len += 1;
        }
        return out[0..len];
    }
    /// Choose every row and the columns from `from` to `to` (indices into
    /// the columns), for the application's own commands.
    pub fn selectColumns(self: *TableState, from: usize, to: usize) void {
        self.core.chooseAll();
        const cells = self.cells orelse return;
        cells.anchor = from;
        cells.cursor = to;
        cells.all = false;
    }

    fn positionOf(self: *const TableState, column: usize) ?usize {
        for (self.order[0..self.column_count], 0..) |entry, position| if (entry == column) return position;
        return null;
    }
    fn firstTextColumn(self: *const TableState) usize {
        for (self.order[0..self.column_count]) |column| if (column < self.columns.len and !self.columns[column].row_header) return column;
        return if (self.column_count > 0) self.order[0] else 0;
    }

    /// Bring the kept layout in line with this pass's columns.
    fn sync(self: *TableState, columns: []const Column) Error!void {
        if (columns.len > max_columns) return error.TooManyColumns;
        var same = columns.len == self.column_count;
        if (same) for (columns, 0..) |column, index| {
            if (self.ids[index] != column.identity()) same = false;
        };
        if (!same) {
            var ids: [max_columns]u64 = undefined;
            var widths: [max_columns]f32 = undefined;
            var order: [max_columns]u8 = undefined;
            var placed: usize = 0;
            var taken: [max_columns]bool = @splat(false);
            for (columns, 0..) |column, index| {
                ids[index] = column.identity();
                widths[index] = column.width;
                for (0..index) |earlier| if (ids[earlier] == ids[index]) return error.InvalidColumns;
                // A column seen before keeps its width.
                for (0..self.column_count) |old| if (self.ids[old] == ids[index]) {
                    widths[index] = self.widths[old];
                };
            }
            // Columns seen before keep their order; new ones follow.
            for (self.order[0..self.column_count]) |old| {
                for (columns, 0..) |_, index| if (!taken[index] and ids[index] == self.ids[old]) {
                    order[placed] = @intCast(index);
                    taken[index] = true;
                    placed += 1;
                };
            }
            for (0..columns.len) |index| if (!taken[index]) {
                order[placed] = @intCast(index);
                placed += 1;
            };
            @memcpy(self.ids[0..columns.len], ids[0..columns.len]);
            @memcpy(self.widths[0..columns.len], widths[0..columns.len]);
            @memcpy(self.order[0..columns.len], order[0..columns.len]);
            self.column_count = columns.len;
        }
        if (self.restore_len) |count| {
            self.restore_len = null;
            var placed: usize = 0;
            var taken: [max_columns]bool = @splat(false);
            var order: [max_columns]u8 = undefined;
            for (self.restore_storage[0..count]) |saved| {
                for (0..self.column_count) |index| if (!taken[index] and self.ids[index] == saved.id) {
                    taken[index] = true;
                    order[placed] = @intCast(index);
                    placed += 1;
                    self.widths[index] = if (columns[index].fixed) columns[index].width else saved.width;
                };
            }
            for (0..self.column_count) |index| if (!taken[index]) {
                order[placed] = @intCast(index);
                placed += 1;
            };
            @memcpy(self.order[0..self.column_count], order[0..self.column_count]);
        }
        // Fixed columns keep their place in the given order.
        for (columns, 0..) |column, index| if (column.fixed) {
            self.widths[index] = column.width;
            const at = self.positionOf(index).?;
            if (at != index and index < self.column_count) {
                const other = self.order[index];
                self.order[index] = @intCast(index);
                self.order[at] = other;
            }
        };
        self.columns = columns;
    }

    const Geometry = struct {
        x: [max_columns]f32 = undefined,
        width: [max_columns]f32 = undefined,
        /// Fixed columns at the start, which do not scroll sideways.
        frozen: usize = 0,
        frozen_width: f32 = 0,
        content: f32 = 0,
    };
    /// Each shown position's x (in content coordinates, before scrolling)
    /// and width for a table `available` wide.
    fn geometry(self: *const TableState, available: f32) Geometry {
        var out: Geometry = .{};
        var fixed_total: f32 = 0;
        var sharing: usize = 0;
        for (self.order[0..self.column_count]) |column| {
            if (self.widths[column] > 0) fixed_total += self.clampWidth(column, self.widths[column]) else sharing += 1;
        }
        const share = if (sharing > 0) @max(0, available - fixed_total) / @as(f32, @floatFromInt(sharing)) else 0;
        var x: f32 = 0;
        var frozen = true;
        for (self.order[0..self.column_count], 0..) |column, position| {
            const width = if (self.widths[column] > 0) self.clampWidth(column, self.widths[column]) else self.clampWidth(column, share);
            out.x[position] = x;
            out.width[position] = width;
            if (frozen and column < self.columns.len and self.columns[column].fixed) {
                out.frozen = position + 1;
                out.frozen_width = x + width;
            } else frozen = false;
            x += width;
        }
        out.content = x;
        return out;
    }
    fn clampWidth(self: *const TableState, column: usize, width: f32) f32 {
        if (column >= self.columns.len) return width;
        const spec = self.columns[column];
        return std.math.clamp(width, spec.min_width, @max(spec.min_width, spec.max_width));
    }
    /// Screen x (local) of a shown position.
    fn screenX(self: *const TableState, g: *const Geometry, position: usize) f32 {
        return if (position < g.frozen) g.x[position] else g.x[position] - self.core.scroll_x;
    }
    fn columnAt(self: *const TableState, x: f32) ?usize {
        const g = self.geometry(self.core.bounds.width);
        for (0..self.column_count) |position| {
            const left = self.screenX(&g, position);
            if (position >= g.frozen and left + g.width[position] <= g.frozen_width) continue;
            if (x >= left and x < left + g.width[position]) return self.order[position];
        }
        return null;
    }
    fn scrollSideways(self: *TableState, delta: f32) void {
        const g = self.geometry(self.core.bounds.width);
        const max = @max(0, g.content - self.core.bounds.width);
        self.core.scroll_x = std.math.clamp(self.core.scroll_x + delta, 0, max);
    }
    fn revealColumn(self: *TableState, column: usize) void {
        const g = self.geometry(self.core.bounds.width);
        const position = self.positionOf(column) orelse return;
        if (position < g.frozen) return;
        const left = g.x[position] - g.frozen_width;
        const view_width = self.core.bounds.width - g.frozen_width;
        if (left < self.core.scroll_x) self.core.scroll_x = left else if (left + g.width[position] > self.core.scroll_x + view_width) self.core.scroll_x = left + g.width[position] - view_width;
        self.scrollSideways(0);
    }

    fn cellText(self: *TableState, row: usize, column: usize, buffer: []u8) Cell {
        const source = self.cells_source orelse return .{};
        return source.call(source.context, row, column, buffer);
    }

    /// Fit a column to its title and the cells in view.
    fn fit(self: *TableState, column: usize) void {
        const core = &self.core;
        const spec = self.columns[column];
        var width = core.measurer.textSize(spec.title, null).width + 2 * cell_padding + (if (spec.sortable) @as(f32, 12) else 0);
        const range = core.visibleLines();
        var buffer: [scratch_len]u8 = undefined;
        var row = range.first;
        while (row < range.end) : (row += 1) {
            const cell = self.cellText(row, column, &buffer);
            var extent = core.measurer.textSize(cell.text, cell.font).width + 2 * cell_padding;
            if (cell.image != null) extent += core.row_height;
            if (self.outline != null and column == 0) extent += self.outline.?.indentOf(row) + core.row_height;
            width = @max(width, extent);
        }
        self.setWidth(column, @ceil(width));
    }
    fn setWidth(self: *TableState, column: usize, width: f32) void {
        // Columns before it that share the room keep their widths, so its
        // edge follows the pointer.
        const g = self.geometry(self.core.bounds.width);
        const position = self.positionOf(column) orelse return;
        for (self.order[0..position], 0..) |earlier, at| if (self.widths[earlier] == 0) {
            self.widths[earlier] = g.width[at];
        };
        self.widths[column] = self.clampWidth(column, width);
        self.core.pending.arranged = true;
    }
    fn sortClick(self: *TableState, column: usize, modifiers: z.KeyModifiers) void {
        if (column >= self.columns.len or !self.columns[column].sortable or self.columns[column].row_header) return;
        if (self.sort_by) |keys| {
            const at = keys.indexOf(column);
            if (modifiers.control or modifiers.shift) {
                if (at) |index| {
                    if (keys.items_storage[index].direction == .ascending) keys.items_storage[index].direction = .descending else keys.remove(index);
                } else keys.append(.{ .column = column });
            } else if (at != null and at.? == 0) {
                const entry = &keys.items_storage[0];
                entry.direction = if (entry.direction == .ascending) .descending else .ascending;
                keys.len = 1;
            } else {
                keys.len = 0;
                keys.append(.{ .column = column });
            }
            if (self.sort) |single| single.* = if (keys.len > 0) keys.items_storage[0] else null;
        } else if (self.sort) |single| {
            if (single.*) |current| {
                if (current.column == column) {
                    single.* = .{ .column = column, .direction = if (current.direction == .ascending) .descending else .ascending };
                } else single.* = .{ .column = column };
            } else single.* = .{ .column = column };
        } else return;
        self.core.pending.sorted = true;
    }
    fn sortOf(self: *const TableState, column: usize) ?struct { direction: SortDirection, place: usize } {
        if (self.sort_by) |keys| {
            const at = keys.indexOf(column) orelse return null;
            return .{ .direction = keys.items_storage[at].direction, .place = at };
        }
        const single = self.sort orelse return null;
        const current = single.* orelse return null;
        if (current.column != column) return null;
        return .{ .direction = current.direction, .place = 0 };
    }
    fn sortCount(self: *const TableState) usize {
        if (self.sort_by) |keys| return keys.len;
        return 0;
    }
    /// Move the column being dragged to shown position `target`; fixed
    /// columns keep their places.
    fn moveColumn(self: *TableState, column: usize, target: usize) void {
        const from = self.positionOf(column) orelse return;
        if (target == from) return;
        var movable: [max_columns]u8 = undefined;
        var slots: [max_columns]usize = undefined;
        var count: usize = 0;
        var from_slot: usize = 0;
        var to_slot: usize = 0;
        for (self.order[0..self.column_count], 0..) |entry, position| {
            if (entry < self.columns.len and self.columns[entry].fixed) continue;
            if (position == from) from_slot = count;
            if (position <= target) to_slot = count;
            movable[count] = entry;
            slots[count] = position;
            count += 1;
        }
        if (count == 0) return;
        if (target < slots[0]) to_slot = 0;
        if (to_slot == from_slot) return;
        const moving = movable[from_slot];
        if (from_slot < to_slot) {
            std.mem.copyForwards(u8, movable[from_slot..to_slot], movable[from_slot + 1 .. to_slot + 1]);
        } else {
            std.mem.copyBackwards(u8, movable[to_slot + 1 .. from_slot + 1], movable[to_slot..from_slot]);
        }
        movable[to_slot] = moving;
        for (0..count) |slot| self.order[slots[slot]] = movable[slot];
        self.core.pending.arranged = true;
    }
    /// The shown position a column dragged to local x goes to.
    fn positionAt(self: *const TableState, x: f32) usize {
        const g = self.geometry(self.core.bounds.width);
        for (0..self.column_count) |position| {
            const left = self.screenX(&g, position);
            if (x < left + g.width[position]) return position;
        }
        return if (self.column_count > 0) self.column_count - 1 else 0;
    }

    fn embed(self: *TableState) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .focusable = true, .input = input };
    }
    fn measure(ptr: *anyopaque, _: Theme) view.layout.Measurement {
        const self: *TableState = @ptrCast(@alignCast(ptr));
        var width: f32 = 0;
        for (self.columns, 0..) |column, index| width += if (self.widths[index] > 0) self.widths[index] else @max(column.min_width, 80);
        const rows: f32 = @floatCast(@min(@as(f64, @floatFromInt(self.core.rows.count)) * self.core.row_height, 16384));
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = @max(width, 120), .height = self.core.header_height + rows } };
    }
    fn place(ptr: *anyopaque, _: u64, bounds: Rect) void {
        const self: *TableState = @ptrCast(@alignCast(ptr));
        self.core.bounds = bounds;
        self.core.placed = true;
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *TableState = @ptrCast(@alignCast(ptr));
        const core = &self.core;
        core.bounds = bounds;
        core.placed = true;
        core.resolveRequest();
        core.clampScroll();
        self.scrollSideways(0);
        core.settle();
        const theme = frame.currentTheme();
        const palette = theme.palette;
        const focused = focusedOn(frame, id) and core.enabled;
        core.focused = focused;
        const outline_state = self.outline;
        const tree_look = outline_state != null and core.header_height == 0 and self.column_count <= 1;
        try frame.semantic(.{ .id = id, .role = if (tree_look) .tree else .table, .name = core.name(), .bounds = bounds, .enabled = core.enabled, .focused = focused and core.cursorIndex() == null, .multiple = core.multiple() });
        frame.rect(bounds, palette.inset);
        try frame.pushClip(bounds);
        const g = self.geometry(bounds.width);
        const cursor = core.cursorIndex();
        const block = self.cells != null;

        // Rows.
        const body: Rect = .{ .x = bounds.x, .y = bounds.y + core.bodyTop(), .width = bounds.width, .height = core.bodyHeight() };
        try frame.pushClip(body);
        const range = core.visibleLines();
        core.exposed_len = 0;
        var buffer: [scratch_len]u8 = undefined;
        var name_buffer: [scratch_len]u8 = undefined;
        var row = range.first;
        while (row < range.end) : (row += 1) {
            const top: f32 = @floatCast(core.lineTop(row) - core.scroll_y);
            const rect: Rect = .{ .x = bounds.x, .y = body.y + top, .width = bounds.width, .height = core.row_height };
            try self.paintRow(frame, id, row, rect, &g, cursor, focused, block, &buffer, &name_buffer);
        }
        // The section header of the rows at the top stays pinned.
        if (core.rows.header) |is_header| if (range.end > range.first) {
            var at = range.first;
            var found: ?usize = null;
            var steps: usize = 0;
            while (steps < header_search) : (steps += 1) {
                if (is_header(core.rows.context, at)) {
                    found = at;
                    break;
                }
                if (at == 0) break;
                at -= 1;
            }
            if (found) |header_row| {
                const natural: f32 = @floatCast(core.lineTop(header_row) - core.scroll_y);
                if (natural < 0) {
                    var top: f32 = 0;
                    // The next header pushes it away.
                    var next = range.first + 1;
                    while (next < range.end) : (next += 1) if (is_header(core.rows.context, next)) {
                        const next_top: f32 = @floatCast(core.lineTop(next) - core.scroll_y);
                        top = @min(0, next_top - core.row_height);
                        break;
                    };
                    const rect: Rect = .{ .x = bounds.x, .y = body.y + top, .width = bounds.width, .height = core.row_height };
                    try self.paintHeaderRow(frame, header_row, rect, &buffer, palette);
                }
            }
        };
        // Where dragged rows would go.
        if (core.reorder_target) |target| {
            const y: f32 = @floatCast(core.lineTop(target) - core.scroll_y);
            frame.rect(.{ .x = bounds.x, .y = body.y + y - 1, .width = bounds.width, .height = 2 }, palette.focus);
        }
        try frame.popClip();

        // Header.
        if (core.header_height > 0) {
            const header: Rect = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = core.header_height };
            frame.rect(header, palette.control);
            frame.rect(.{ .x = header.x, .y = header.y + header.height - 1, .width = header.width, .height = 1 }, palette.border);
            const header_id = partId(id, header_part);
            try frame.semantic(.{ .id = header_id, .parent = id, .role = .table_header, .name = "", .bounds = header });
            var place_buffer: [16]u8 = undefined;
            for (0..self.column_count) |position| {
                const column = self.order[position];
                const spec = self.columns[column];
                const left = self.screenX(&g, position);
                if (position >= g.frozen and left + g.width[position] <= g.frozen_width) continue;
                var cell: Rect = .{ .x = bounds.x + left, .y = header.y, .width = g.width[position], .height = header.height };
                if (position >= g.frozen and left < g.frozen_width) {
                    const cut = g.frozen_width - left;
                    cell.x += cut;
                    cell.width -= cut;
                }
                if (cell.x > bounds.x + bounds.width) continue;
                const sort = self.sortOf(column);
                const moving = switch (core.press) {
                    .header => |press| press.moving and press.column == column,
                    else => false,
                };
                if (moving) frame.rect(cell, palette.pressed);
                const text_color = if (core.enabled) palette.text else palette.disabled_text;
                var text_rect = inset(cell, 0);
                text_rect.x += cell_padding;
                text_rect.width = @max(0, text_rect.width - 2 * cell_padding);
                if (sort) |order| {
                    const side: f32 = 8;
                    const mark: Rect = .{ .x = cell.x + cell.width - cell_padding - side, .y = cell.y + (cell.height - side) / 2, .width = side, .height = side };
                    triangle(frame, mark, if (order.direction == .ascending) .up else .down, text_color);
                    text_rect.width = @max(0, text_rect.width - side - 4);
                    if (self.sortCount() > 1) {
                        const digits = std.fmt.bufPrint(&place_buffer, "{d}", .{order.place + 1}) catch "";
                        frame.labelFont(.{ .x = mark.x - 12, .y = cell.y, .width = 12, .height = cell.height }, digits, text_color, .{ .size = 11 });
                        text_rect.width = @max(0, text_rect.width - 12);
                    }
                }
                frame.labelFont(self.aligned(text_rect, spec.title, null, spec.alignment), spec.title, text_color, .{ .weight = .semibold });
                frame.rect(.{ .x = cell.x + cell.width - 1, .y = cell.y + 4, .width = 1, .height = @max(0, cell.height - 8) }, palette.track);
                const value: []const u8 = if (sort) |order| @tagName(order.direction) else "";
                try frame.semantic(.{ .id = partId(id, column_part ^ self.ids[column]), .parent = header_id, .role = .column_header, .name = spec.title, .value = value, .bounds = cell, .enabled = core.enabled, .read_only = true });
            }
            if (self.move_target) |target| if (target < self.column_count) {
                const x = self.screenX(&g, target);
                frame.rect(.{ .x = bounds.x + x - 1, .y = header.y, .width = 2, .height = header.height }, palette.focus);
            };
        }
        paintScrollIndicators(frame, core, bounds, g.content, bounds.width, palette);
        if (!core.enabled) {} else if (focused and cursor == null) ring(frame, bounds, theme.metrics.border, palette.focus);
        try frame.popClip();
    }

    fn aligned(self: *const TableState, rect: Rect, text: []const u8, font: ?Font, alignment: Align) Rect {
        if (alignment == .start) return rect;
        const width = @min(rect.width, self.core.measurer.textSize(text, font).width + 2);
        return switch (alignment) {
            .start => rect,
            .center => .{ .x = rect.x + (rect.width - width) / 2, .y = rect.y, .width = width, .height = rect.height },
            .end => .{ .x = rect.x + rect.width - width, .y = rect.y, .width = width, .height = rect.height },
        };
    }

    fn paintHeaderRow(self: *TableState, frame: *ui.Frame, row: usize, rect: Rect, buffer: []u8, palette: ui.theme.Palette) !void {
        frame.rect(rect, palette.control);
        frame.rect(.{ .x = rect.x, .y = rect.y + rect.height - 1, .width = rect.width, .height = 1 }, palette.track);
        const cell = self.cellText(row, 0, buffer);
        frame.labelFont(.{ .x = rect.x + cell_padding, .y = rect.y, .width = @max(0, rect.width - 2 * cell_padding), .height = rect.height }, cell.text, cell.color orelse palette.text, cell.font orelse .{ .weight = .semibold });
    }

    fn paintRow(self: *TableState, frame: *ui.Frame, id: u64, row: usize, rect: Rect, g: *const Geometry, cursor: ?usize, focused: bool, block: bool, buffer: []u8, name_buffer: []u8) !void {
        const core = &self.core;
        const theme = frame.currentTheme();
        const palette = theme.palette;
        const key = core.keyAt(row);
        const chosen = core.selected(row);
        const at_cursor = cursor != null and cursor.? == row;
        const radius: f32 = if (core.round_rows) 4 else 0;
        const accent = if (core.enabled) palette.accent else palette.disabled_accent;
        const is_section = if (core.rows.header) |call| call(core.rows.context, row) else false;
        if (is_section) {
            try self.paintHeaderRow(frame, row, rect, buffer, palette);
        } else {
            if (chosen and !block) {
                frame.roundedRect(rect, radius, ui.Color.rgb(accent));
            } else if (core.hover != null and core.hover.? == row and core.enabled) {
                frame.roundedRect(rect, radius, ui.Color.rgb(palette.control));
            }
            const outline_state = self.outline;
            for (0..self.column_count) |position| {
                const column = self.order[position];
                const spec = self.columns[column];
                const left = self.screenX(g, position);
                if (position >= g.frozen and left + g.width[position] <= g.frozen_width) continue;
                var cell_rect: Rect = .{ .x = rect.x + left, .y = rect.y, .width = g.width[position], .height = rect.height };
                if (position >= g.frozen and left < g.frozen_width) {
                    const cut = g.frozen_width - left;
                    cell_rect.x += cut;
                    cell_rect.width -= cut;
                }
                if (cell_rect.x > rect.x + rect.width) continue;
                if (position < g.frozen) frame.rect(cell_rect, if (spec.row_header) palette.control else palette.inset);
                const in_block = block and chosen and self.cellSelected(row, column);
                const whole = block and chosen and spec.row_header and self.cells.?.all;
                if (in_block or whole) frame.rect(cell_rect, accent);
                var content = cell_rect;
                content.x += cell_padding;
                content.width = @max(0, content.width - 2 * cell_padding);
                const foreground_default = if (!core.enabled) palette.disabled_text else if ((chosen and !block) or in_block or whole) palette.on_accent else palette.text;
                if (outline_state) |state| if (column == 0) {
                    const indent = state.indentOf(row);
                    const entry = state.rows_buffer[row];
                    const side = @min(rect.height, 12);
                    const mark: Rect = .{ .x = content.x + indent, .y = rect.y + (rect.height - side) / 2, .width = side, .height = side };
                    if (entry.branch) triangle(frame, inset(mark, 2), if (entry.open) .down else .right, foreground_default);
                    const used = indent + side + 4;
                    content.x += used;
                    content.width = @max(0, content.width - used);
                };
                const cell = self.cellText(row, column, buffer);
                if (cell.image) |picture| {
                    const side = @min(rect.height - 6, content.width);
                    if (side > 0) try frame.image(.{ .x = content.x, .y = rect.y + (rect.height - side) / 2, .width = side, .height = side }, picture, .{ .fit = .contain });
                    content.x += side + 6;
                    content.width = @max(0, content.width - side - 6);
                }
                const color = if ((chosen and !block) or in_block or whole) palette.on_accent else cell.color orelse foreground_default;
                frame.labelFont(self.aligned(content, cell.text, cell.font, spec.alignment), cell.text, color, cell.font orelse .{});
                if (block and at_cursor and focused and core.cursorColumn() == column) ring(frame, cell_rect, theme.metrics.border, palette.focus);
            }
            if (focused and at_cursor and !block) ring(frame, rect, theme.metrics.border, if (chosen) palette.on_accent else palette.focus);
        }
        if (core.exposed_len < max_semantic_rows and rect.y + rect.height > core.bounds.y + core.bodyTop() and rect.y < core.bounds.y + core.bounds.height) {
            const label = core.labelOf(row, name_buffer);
            const part = partId(id, key);
            const tree_look = self.outline != null and core.header_height == 0 and self.column_count <= 1;
            const entry: ?OutlineRow = if (self.outline) |state| state.rows_buffer[row] else null;
            try frame.semantic(.{
                .id = part,
                .parent = id,
                .role = if (tree_look) .tree_item else .table_row,
                .name = label,
                .bounds = rect,
                .enabled = core.enabled,
                .focused = focused and at_cursor,
                .checked = chosen,
                .multiple = core.multiple(),
                .expanded = if (entry) |value| (if (value.branch) value.open else null) else null,
            });
            core.exposed[core.exposed_len] = key;
            core.exposed_len += 1;
        }
    }

    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *TableState = @ptrCast(@alignCast(ptr));
        const core = &self.core;
        switch (event) {
            .pointer_move => |point| {
                const hit = if (point.y >= core.bodyTop()) core.indexAt(point, false) else null;
                if (std.meta.eql(hit, core.hover)) return false;
                core.hover = hit;
                return true;
            },
            .pointer_leave => {
                if (core.hover == null) return false;
                core.hover = null;
                return true;
            },
            .pointer_down => |press| return self.pointerDown(press),
            .pointer_drag => |drag| return self.pointerDrag(drag),
            .pointer_up => |point| return self.pointerUp(point),
            .pointer_cancel => {
                core.press = .none;
                core.reorder_target = null;
                self.move_target = null;
                core.stopEdge();
                return true;
            },
            .wheel => |wheel| return core.wheel(wheel.delta),
            .key => |press| return self.onKey(press),
        }
    }

    fn resizeEdgeAt(self: *const TableState, x: f32) ?usize {
        const g = self.geometry(self.core.bounds.width);
        var position = self.column_count;
        while (position > 0) {
            position -= 1;
            const column = self.order[position];
            if (self.columns[column].fixed) continue;
            const edge = self.screenX(&g, position) + g.width[position];
            if (@abs(x - edge) <= resize_zone) return column;
        }
        return null;
    }

    fn pointerDown(self: *TableState, press: view.PointerPress) bool {
        const core = &self.core;
        const point = press.position;
        const mods = press.modifiers;
        core.pointer = point;
        // The scroll indicator drags.
        if (point.y >= core.bodyTop() and point.x >= core.bounds.width - scroll_bar - 4 and core.maxScroll() > 0) {
            core.press = .{ .thumb = .{ .vertical = true, .start_scroll = core.scroll_y, .origin = point.y } };
            return true;
        }
        if (point.y < core.header_height) {
            if (self.resizeEdgeAt(point.x)) |column| {
                if (press.count >= 2) {
                    self.fit(column);
                    core.press = .none;
                } else core.press = .{ .resize = .{ .column = column, .start = self.geometry(core.bounds.width).width[self.positionOf(column).?] } };
                return true;
            }
            const column = self.columnAt(point.x) orelse return true;
            if (self.columns[column].row_header) {
                if (self.cells) |cells| {
                    core.chooseAll();
                    cells.all = true;
                }
                return true;
            }
            core.press = .{ .header = .{ .column = column, .modifiers = mods } };
            return true;
        }
        const index = core.indexAt(point, false) orelse {
            // A press below the rows clears the choice.
            if (core.selection) |selection| if (selection.len > 0 and !mods.control and !mods.shift) {
                selection.clear();
                core.pending.changed = true;
            };
            core.press = .none;
            return true;
        };
        const column = self.columnAt(point.x);
        // An outline item's arrow opens or closes it.
        if (self.outline) |state| if (column != null and column.? == 0 and state.rows_buffer[index].branch) {
            const g = self.geometry(core.bounds.width);
            const position = self.positionOf(0).?;
            const left = self.screenX(&g, position) + cell_padding + state.indentOf(index);
            if (point.x >= left - 2 and point.x < left + @min(core.row_height, 12) + 4) {
                state.setOpen(index, !state.rows_buffer[index].open, mods.alt);
                core.press = .none;
                return true;
            }
        };
        if (core.rows.header) |is_header| if (is_header(core.rows.context, index)) {
            core.press = .none;
            return true;
        };
        const row_header = column != null and self.columns[column.?].row_header and self.cells != null;
        if (press.count >= 2 and !mods.shift and !mods.control) {
            core.pending.submitted = index;
            core.pending.double_clicked = .{ .row = index, .column = column orelse self.firstTextColumn() };
        }
        var deferred = false;
        if (mods.control and !mods.shift) {
            core.choose(index, .toggle);
        } else if (mods.shift) {
            core.choose(index, if (mods.control) .range_add else .range);
            if (self.cells) |cells| if (column) |c| {
                if (!row_header) {
                    cells.cursor = c;
                    cells.all = false;
                }
            };
        } else if (core.selected(index) and (core.reorder or core.drag_select) and core.multiple() and press.count < 2) {
            // A press on a chosen row waits for the release, so a drag of
            // the choice keeps it.
            deferred = true;
        } else {
            core.choose(index, .set);
            if (self.cells) |cells| if (column) |c| {
                if (!row_header) {
                    cells.anchor = c;
                    cells.cursor = c;
                }
                cells.all = row_header;
            };
        }
        const selecting = !core.reorder and (core.drag_select or self.cells != null) and core.multiple();
        if (selecting) core.beginDragChoice(mods.control);
        core.press = .{ .rows = .{ .index = index, .column = column, .deferred = deferred, .add = mods.control, .row_header = row_header } };
        if (row_header) if (self.cells) |cells| {
            cells.all = true;
        };
        return true;
    }

    fn pointerDrag(self: *TableState, drag: view.PointerDrag) bool {
        const core = &self.core;
        core.pointer = drag.position;
        switch (core.press) {
            .none => return false,
            .thumb => |thumb| {
                const track = core.bodyHeight();
                const content = core.contentHeight();
                if (track <= 0) return false;
                const length = @max(16, @as(f64, track) * track / content);
                const ratio = core.maxScroll() / @max(1, @as(f64, track) - length);
                core.scroll_y = thumb.start_scroll + @as(f64, drag.position.y - thumb.origin) * ratio;
                core.clampScroll();
                return true;
            },
            .resize => |resize| {
                self.setWidth(resize.column, resize.start + (drag.position.x - drag.origin.x));
                return true;
            },
            .header => |*header| {
                if (!drag.dragging) return false;
                if (self.columns[header.column].fixed) return false;
                header.moving = true;
                self.move_target = self.positionAt(drag.position.x);
                return true;
            },
            .rows => |*rows| {
                if (!drag.dragging) return false;
                if (core.reorder and !rows.reordering and !rows.selecting) {
                    rows.reordering = true;
                    rows.deferred = false;
                } else if (!rows.selecting and !rows.reordering and (core.drag_select or self.cells != null) and core.multiple()) {
                    rows.selecting = true;
                    rows.deferred = false;
                }
                core.setEdge(drag.position);
                core.dragTo(drag.position);
                return true;
            },
        }
    }

    fn pointerUp(self: *TableState, point: Point) bool {
        const core = &self.core;
        // A copy, not an alias of the field cleared next.
        var pressed = core.press;
        _ = &pressed;
        core.press = .none;
        core.stopEdge();
        switch (pressed) {
            .header => |header| {
                if (header.moving) {
                    if (self.move_target) |target| self.moveColumn(header.column, target);
                    self.move_target = null;
                } else if (point.y < core.header_height and self.columnAt(point.x) == header.column) self.sortClick(header.column, header.modifiers);
            },
            .rows => |rows| {
                if (rows.reordering) {
                    var target = core.reorder_target orelse core.insertionAt(point);
                    _ = &target;
                    core.reorder_target = null;
                    if (target != rows.index and target != rows.index + 1) core.pending.moved = .{ .row = rows.index, .to = target, .selection = core.selected(rows.index) };
                } else if (rows.deferred) {
                    core.choose(rows.index, .set);
                    if (self.cells) |cells| if (rows.column) |c| {
                        cells.anchor = c;
                        cells.cursor = c;
                        cells.all = false;
                    };
                }
            },
            else => {},
        }
        return true;
    }

    fn onKey(self: *TableState, press: z.KeyInput) bool {
        const core = &self.core;
        const mods = press.modifiers;
        const count = core.rows.count;
        if (core.sharedKey(press)) |handled| return handled;
        const current = core.cursorIndex();
        switch (press.key) {
            .up, .down, .page_up, .page_down => {
                if (count == 0) return false;
                const page = core.page();
                const from = current orelse (if (press.key == .up or press.key == .page_up) count else 0);
                const start_missing = current == null;
                const target: usize = switch (press.key) {
                    .up => if (start_missing) count - 1 else from -| 1,
                    .down => if (start_missing) 0 else @min(count - 1, from + 1),
                    .page_up => if (start_missing) 0 else from -| page,
                    else => if (start_missing) @min(count - 1, page) else @min(count - 1, from + page),
                };
                core.navigate(target, mods);
                if (self.cells) |cells| if (!mods.shift) {
                    cells.anchor = cells.cursor;
                    cells.all = false;
                };
                return true;
            },
            .left, .right => {
                if (self.outline) |state| {
                    const index = current orelse return false;
                    return state.arrow(index, press.key == .right, mods.shift);
                }
                if (self.cells) |cells| {
                    const position = self.positionOf(cells.cursor) orelse 0;
                    const next = if (press.key == .left) position -| 1 else @min(self.column_count -| 1, position + 1);
                    cells.cursor = self.order[next];
                    cells.all = false;
                    if (!mods.shift) {
                        cells.anchor = cells.cursor;
                        if (current) |index| core.choose(index, .set);
                    }
                    self.revealColumn(cells.cursor);
                    core.pending.changed = true;
                    return true;
                }
                const before = core.scroll_x;
                self.scrollSideways(if (press.key == .left) -40 else 40);
                return core.scroll_x != before;
            },
            else => return false,
        }
    }
};

/// A table of `rows` under `columns`: `cell` gives what a row shows in a
/// column. Only the rows in view paint, all of one height. A click or the
/// arrows choose a row of `state.selection`, Ctrl-click adds or takes one
/// out, Shift-click and Shift with the arrows choose from the anchor, and
/// Ctrl+A chooses all; Enter or a double click submits. The user resizes
/// columns by dragging a header's trailing edge (a double click fits it),
/// moves them by dragging a header and sorts by clicking a sortable one.
pub fn table(v: *View, state: *TableState, columns: []const Column, rows: Rows, cell: CellSource, options: TableOptions) Error!Result {
    try state.sync(columns);
    state.cells_source = cell;
    state.outline = null;
    return buildTable(v, state, rows, options);
}

fn buildTable(v: *View, state: *TableState, rows: Rows, options: TableOptions) Error!Result {
    const core = &state.core;
    if (options.reorder and options.drag_select) return error.InvalidValue;
    if (!std.math.isFinite(options.row_height) or options.row_height <= 0) return error.InvalidValue;
    if (options.cell_select and state.cells == null) return error.InvalidValue;
    if (!options.cell_select) state.cells = null;
    core.rows = rows;
    core.selection = state.selection;
    core.row_height = options.row_height;
    core.header_height = if (options.header and state.column_count > 0) options.row_height else 0;
    core.measurer = options.measurer;
    core.drag_select = options.drag_select;
    core.reorder = options.reorder;
    if (options.follow_end and !core.follow_end and !core.placed) core.at_end = true;
    core.follow_end = options.follow_end;
    core.keep_offset = options.keep_offset;
    core.round_rows = options.round_rows;
    core.setName(options.style.name);
    if (core.hover) |hover| if (hover >= rows.count) {
        core.hover = null;
    };
    var result = core.pass(v);
    try v.embed(state.embed(), options.style);
    const leaf = lastNode(v);
    core.id = leaf.id;
    core.enabled = leaf.style.enabled;
    core.buildSemantics(v);
    // Assistive technology sorts by invoking a column header.
    if (core.header_height > 0) for (0..state.column_count) |column| {
        if (v.takeEvent(partId(leaf.id, column_part ^ state.ids[column]))) |event| if (event == .action and core.enabled) state.sortClick(column, .{});
    };
    result.merge(core.pending);
    core.pending = .{};
    return result;
}

// ---------------------------------------------------------------- outline

/// The tree an outline shows. Items are nonzero keys, unique in the tree.
pub const Tree = struct {
    /// Passed to every function below; it stays valid while the outline is
    /// built, paints and takes input.
    context: ?*const anyopaque = null,
    /// How many children `parent` has, or how many items are at the top
    /// for null; an item with none is a leaf without an arrow.
    count: *const fn (?*const anyopaque, ?u64) usize,
    /// Child `index` of `parent`, or of the top for null.
    child: *const fn (?*const anyopaque, ?u64, usize) u64,
    /// The text of an item: its row's name, what typing finds and, in an
    /// outline without columns, what the row shows.
    label: *const fn (?*const anyopaque, u64, []u8) []const u8,
    /// Changes when the tree's items change, so the rows are gathered
    /// again; opening and closing items needs no change.
    revision: u64 = 0,
};
/// One shown row of an outline.
pub const OutlineRow = struct {
    key: u64,
    depth: u16,
    branch: bool,
    open: bool,
    /// The row of the parent item, or `none` at the top.
    parent: u32,
    pub const none = std.math.maxInt(u32);
};
/// An outline table's cell content for an item and a column.
pub const OutlineCellSource = struct {
    context: ?*const anyopaque = null,
    call: *const fn (?*const anyopaque, u64, usize, []u8) Cell,
};

pub const OutlineOptions = struct {
    row_height: f32 = 28,
    /// Width each level adds before a row's arrow; 0 for 16 DIP.
    indent: f32 = 0,
    /// Show the header row in an outline table.
    header: bool = true,
    drag_select: bool = false,
    keep_offset: bool = false,
    round_rows: bool = false,
    measurer: view.Measurer = .{},
    style: view.Style = .{},
};

/// An outline's state, owned by the application at a stable address. Its
/// rows are gathered into `rows_buffer`, which bounds how many can show.
pub const OutlineState = struct {
    table: TableState = .{ .core = .{ .shape = .outline } },
    /// The items showing their children; set before building.
    open: ?*Selection = null,
    /// Room for the shown rows, provided by the application.
    rows_buffer: []OutlineRow = &.{},
    rows_len: usize = 0,
    tree: ?Tree = null,
    cells_source: ?OutlineCellSource = null,
    indent: f32 = 16,
    gathered: bool = false,
    seen_revision: u64 = 0,
    seen_open: u64 = 0,
    stale: bool = true,

    /// The rows shown, as of the last pass.
    pub fn rows(self: *const OutlineState) []const OutlineRow {
        return self.rows_buffer[0..self.rows_len];
    }
    /// The item of a shown row.
    pub fn item(self: *const OutlineState, row: usize) ?u64 {
        return if (row < self.rows_len) self.rows_buffer[row].key else null;
    }
    pub fn depth(self: *const OutlineState, row: usize) u16 {
        return if (row < self.rows_len) self.rows_buffer[row].depth else 0;
    }
    /// The choice of rows, by item, as for a table.
    pub fn selection(self: *OutlineState) ?*Selection {
        return self.table.selection;
    }
    pub fn scrollTo(self: *OutlineState, row: usize, alignment: ScrollAlign) void {
        self.table.scrollTo(row, alignment);
    }

    fn indentOf(self: *const OutlineState, row: usize) f32 {
        return self.indent * @as(f32, @floatFromInt(self.depth(row)));
    }

    /// Gather the rows of open items, depth first.
    fn gather(self: *OutlineState) Error!void {
        const tree = self.tree orelse return;
        const open = self.open orelse return error.InvalidValue;
        self.rows_len = 0;
        const Frame = struct { parent: ?u64, row: u32, index: usize, count: usize };
        var stack: [max_depth + 1]Frame = undefined;
        var top: usize = 1;
        stack[0] = .{ .parent = null, .row = OutlineRow.none, .index = 0, .count = tree.count(tree.context, null) };
        while (top > 0) {
            const frame = &stack[top - 1];
            if (frame.index == frame.count) {
                top -= 1;
                continue;
            }
            const key = tree.child(tree.context, frame.parent, frame.index);
            frame.index += 1;
            if (self.rows_len == self.rows_buffer.len) return error.RowsFull;
            const children = tree.count(tree.context, key);
            const is_open = children > 0 and open.contains(key);
            self.rows_buffer[self.rows_len] = .{ .key = key, .depth = @intCast(top - 1), .branch = children > 0, .open = is_open, .parent = frame.row };
            const row: u32 = @intCast(self.rows_len);
            self.rows_len += 1;
            if (is_open and top <= max_depth) {
                stack[top] = .{ .parent = key, .row = row, .index = 0, .count = children };
                top += 1;
            }
        }
        self.seen_open = open.version;
        self.seen_revision = tree.revision;
        self.stale = false;
        self.table.core.rows.count = self.rows_len;
    }

    /// Open or close the item of `row`; with `all`, every item inside too.
    /// Closing an item whose descendant had the cursor moves it there.
    fn setOpen(self: *OutlineState, row: usize, value: bool, all: bool) void {
        const open = self.open orelse return;
        const tree = self.tree orelse return;
        if (row >= self.rows_len) return;
        const entry = self.rows_buffer[row];
        if (!entry.branch) return;
        const core = &self.table.core;
        const before = open.version;
        if (!value) {
            if (core.cursorIndex()) |cursor| if (cursor > row and self.within(cursor, row)) {
                core.choose(row, .set);
            };
        }
        if (all) {
            self.setSubtree(entry.key, value, tree, open, 0);
        } else if (value) {
            open.add(entry.key) catch |err| core.fail(err);
        } else _ = open.remove(entry.key);
        if (open.version != before) {
            core.pending.toggled = true;
            self.stale = true;
            self.gather() catch |err| core.fail(err);
        }
    }
    fn setSubtree(self: *OutlineState, key: u64, value: bool, tree: Tree, open: *Selection, level: usize) void {
        const children = tree.count(tree.context, key);
        if (children == 0) return;
        if (value) open.add(key) catch |err| {
            self.table.core.fail(err);
            return;
        } else _ = open.remove(key);
        if (level >= max_depth) return;
        for (0..children) |index| self.setSubtree(tree.child(tree.context, key, index), value, tree, open, level + 1);
    }
    /// Whether `row` lies inside the item of `ancestor`.
    fn within(self: *const OutlineState, row: usize, ancestor: usize) bool {
        var at = self.rows_buffer[row].parent;
        while (at != OutlineRow.none) {
            if (at == ancestor) return true;
            at = self.rows_buffer[at].parent;
        }
        return false;
    }
    /// Right opens the item or goes to its first child; Left closes it or
    /// goes to its parent; with `all`, they open or close all inside.
    fn arrow(self: *OutlineState, row: usize, right: bool, all: bool) bool {
        const core = &self.table.core;
        const entry = self.rows_buffer[row];
        if (right) {
            if (entry.branch and (!entry.open or all)) {
                self.setOpen(row, true, all);
            } else if (entry.branch and row + 1 < self.rows_len) {
                core.choose(row + 1, .set);
                core.reveal(row + 1);
            } else return false;
        } else {
            if (entry.branch and entry.open) {
                self.setOpen(row, false, all);
            } else if (entry.parent != OutlineRow.none) {
                core.choose(entry.parent, .set);
                core.reveal(entry.parent);
            } else return false;
        }
        return true;
    }

    fn keyOf(context: ?*const anyopaque, row: usize) u64 {
        const self: *const OutlineState = @ptrCast(@alignCast(context.?));
        return if (row < self.rows_len) self.rows_buffer[row].key else 0;
    }
    fn labelOf(context: ?*const anyopaque, row: usize, buffer: []u8) []const u8 {
        const self: *const OutlineState = @ptrCast(@alignCast(context.?));
        const tree = self.tree orelse return "";
        if (row >= self.rows_len) return "";
        return tree.label(tree.context, self.rows_buffer[row].key, buffer);
    }
    fn cellOf(context: ?*const anyopaque, row: usize, column: usize, buffer: []u8) Cell {
        const self: *const OutlineState = @ptrCast(@alignCast(context.?));
        if (row >= self.rows_len) return .{};
        const key = self.rows_buffer[row].key;
        if (self.cells_source) |source| return source.call(source.context, key, column, buffer);
        const tree = self.tree orelse return .{};
        return .{ .text = tree.label(tree.context, key, buffer) };
    }
};

const outline_column = [_]Column{.{ .id = 1, .title = "" }};

/// A tree of items: the items at the top, and below each open item its
/// children, indented, with an arrow that opens and closes it. Only the
/// rows in view paint. A click on an arrow opens or closes its item (with
/// Alt, all inside it too); Right opens the item at the cursor or goes to
/// its first child, Left closes it or goes to its parent, and with Shift
/// they open and close all inside. Rows are chosen as a table's are.
pub fn outline(v: *View, state: *OutlineState, tree: Tree, options: OutlineOptions) Error!Result {
    state.cells_source = null;
    return buildOutline(v, state, tree, &outline_column, false, options);
}

/// An outline in a table's columns, the first of which shows the arrows,
/// indented as the items are deep; `cell` gives what an item shows in a
/// column. The user sorts, resizes and moves the columns as in a table.
pub fn outlineTable(v: *View, state: *OutlineState, columns: []const Column, tree: Tree, cell: OutlineCellSource, options: OutlineOptions) Error!Result {
    state.cells_source = cell;
    return buildOutline(v, state, tree, columns, options.header, options);
}

fn buildOutline(v: *View, state: *OutlineState, tree: Tree, columns: []const Column, header: bool, options: OutlineOptions) Error!Result {
    if (state.open == null) return error.InvalidValue;
    const table_state = &state.table;
    try table_state.sync(columns);
    table_state.outline = state;
    table_state.cells = null;
    table_state.cells_source = .{ .context = state, .call = OutlineState.cellOf };
    state.tree = tree;
    state.indent = if (options.indent > 0) options.indent else 16;
    if (state.stale or state.seen_revision != tree.revision or state.seen_open != state.open.?.version or !state.gathered) {
        state.gathered = true;
        try state.gather();
    }
    return buildTable(v, table_state, .{ .context = state, .count = state.rows_len, .key = OutlineState.keyOf, .label = OutlineState.labelOf }, .{
        .row_height = options.row_height,
        .header = header,
        .drag_select = options.drag_select,
        .keep_offset = options.keep_offset,
        .round_rows = options.round_rows,
        .measurer = options.measurer,
        .style = options.style,
    });
}

// ------------------------------------------------------------- grid view

/// What a grid item shows: a picture above a line of text.
pub const GridItem = struct {
    text: []const u8 = "",
    color: ?u32 = null,
    image: ?ImageView = null,
};
pub const ItemSource = struct {
    context: ?*const anyopaque = null,
    call: *const fn (?*const anyopaque, usize, []u8) GridItem,
};
pub const GridOptions = struct {
    /// Items are at least this wide and share the width left over.
    min_item_width: f32 = 120,
    item_height: f32 = 120,
    /// Space between items and around them.
    gap: f32 = 8,
    drag_select: bool = false,
    /// The user drags items to another place; `Result.moved` reports it.
    reorder: bool = false,
    measurer: view.Measurer = .{},
    style: view.Style = .{},
};
/// A grid view's state, owned by the application at a stable address.
pub const GridState = struct {
    core: Core = .{ .shape = .grid },
    selection: ?*Selection = null,
    item_source: ?ItemSource = null,

    pub fn scrollTo(self: *GridState, index: usize, alignment: ScrollAlign) void {
        self.core.request = .{ .row = index, .alignment = alignment };
        self.core.resolveRequest();
    }
    pub fn columns(self: *const GridState) usize {
        return self.core.grid_columns;
    }
    pub fn scrollOffset(self: *const GridState) f64 {
        return self.core.scroll_y;
    }
    /// The first and the last items of the lines in view.
    pub fn visible(self: *const GridState) struct { first: usize, last: usize } {
        const range = self.core.visibleLines();
        const count = self.core.rows.count;
        if (range.end == 0 or count == 0) return .{ .first = 0, .last = 0 };
        return .{ .first = range.first * self.core.grid_columns, .last = @min(count, range.end * self.core.grid_columns) - 1 };
    }

    fn layoutColumns(self: *GridState, width: f32) void {
        const core = &self.core;
        const value = @floor((width - core.gap) / (core.item_width + core.gap));
        core.grid_columns = if (value >= 1 and std.math.isFinite(value)) @intFromFloat(@min(value, 4096)) else 1;
    }
    fn embed(self: *GridState) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .focusable = true, .input = input };
    }
    fn measure(ptr: *anyopaque, _: Theme) view.layout.Measurement {
        const self: *GridState = @ptrCast(@alignCast(ptr));
        const core = &self.core;
        const width = core.item_width * 3 + core.gap * 4;
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = width, .height = @floatCast(@min(core.contentHeight(), 16384)) } };
    }
    fn place(ptr: *anyopaque, _: u64, bounds: Rect) void {
        const self: *GridState = @ptrCast(@alignCast(ptr));
        self.core.bounds = bounds;
        self.core.placed = true;
        self.layoutColumns(bounds.width);
    }
    fn itemRect(self: *const GridState, index: usize) Rect {
        const core = &self.core;
        const line = index / core.grid_columns;
        const column = index % core.grid_columns;
        const width = core.gridItemWidth();
        const top: f32 = @floatCast(core.lineTop(line) - core.scroll_y);
        return .{ .x = core.gap + @as(f32, @floatFromInt(column)) * (width + core.gap), .y = top, .width = width, .height = core.item_height };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *GridState = @ptrCast(@alignCast(ptr));
        const core = &self.core;
        core.bounds = bounds;
        core.placed = true;
        self.layoutColumns(bounds.width);
        core.resolveRequest();
        core.settle();
        const theme = frame.currentTheme();
        const palette = theme.palette;
        const focused = focusedOn(frame, id) and core.enabled;
        core.focused = focused;
        const cursor = core.cursorIndex();
        try frame.semantic(.{ .id = id, .role = .list, .name = core.name(), .bounds = bounds, .enabled = core.enabled, .focused = focused and cursor == null, .multiple = core.multiple() });
        frame.rect(bounds, palette.inset);
        try frame.pushClip(bounds);
        const range = core.visibleLines();
        core.exposed_len = 0;
        var buffer: [scratch_len]u8 = undefined;
        var name_buffer: [scratch_len]u8 = undefined;
        var line = range.first;
        while (line < range.end) : (line += 1) {
            for (0..core.grid_columns) |column| {
                const index = line * core.grid_columns + column;
                if (index >= core.rows.count) break;
                const rect = shift(self.itemRect(index), bounds);
                const chosen = core.selected(index);
                const at_cursor = cursor != null and cursor.? == index;
                if (chosen) {
                    frame.roundedRect(rect, 6, ui.Color.rgb(if (core.enabled) palette.accent else palette.disabled_accent));
                } else if (core.hover != null and core.hover.? == index and core.enabled) frame.roundedRect(rect, 6, ui.Color.rgb(palette.control));
                const source = self.item_source orelse break;
                const item_value = source.call(source.context, index, &buffer);
                const text_height: f32 = if (item_value.text.len > 0) 24 else 0;
                if (item_value.image) |picture| {
                    const area = inset(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = @max(0, rect.height - text_height) }, 6);
                    if (area.width > 0 and area.height > 0) try frame.image(area, picture, .{ .fit = .contain });
                }
                if (item_value.text.len > 0) {
                    const color = if (!core.enabled) palette.disabled_text else if (chosen) palette.on_accent else item_value.color orelse palette.text;
                    const width = @min(rect.width - 8, core.measurer.textSize(item_value.text, null).width + 2);
                    const text_rect: Rect = .{ .x = rect.x + (rect.width - width) / 2, .y = rect.y + rect.height - text_height - 2, .width = @max(0, width), .height = text_height };
                    frame.label(text_rect, item_value.text, color);
                }
                if (focused and at_cursor) ring(frame, rect, theme.metrics.border, if (chosen) palette.on_accent else palette.focus);
                if (core.exposed_len < max_semantic_rows and rect.y + rect.height > bounds.y and rect.y < bounds.y + bounds.height) {
                    const key = core.keyAt(index);
                    const label = if (core.rows.label) |call| call(core.rows.context, index, &name_buffer) else item_value.text;
                    try frame.semantic(.{ .id = partId(id, key), .parent = id, .role = .list_item, .name = label, .bounds = rect, .enabled = core.enabled, .focused = focused and at_cursor, .checked = chosen, .multiple = core.multiple() });
                    core.exposed[core.exposed_len] = key;
                    core.exposed_len += 1;
                }
            }
        }
        if (core.reorder_target) |target| {
            const at = if (target < core.rows.count) shift(self.itemRect(target), bounds) else blk: {
                const last = shift(self.itemRect(core.rows.count - 1), bounds);
                break :blk Rect{ .x = last.x + last.width + core.gap, .y = last.y, .width = last.width, .height = last.height };
            };
            frame.rect(.{ .x = at.x - core.gap / 2 - 1, .y = at.y, .width = 2, .height = at.height }, palette.focus);
        }
        paintScrollIndicators(frame, core, bounds, 0, bounds.width, palette);
        if (focused and cursor == null) ring(frame, bounds, theme.metrics.border, palette.focus);
        try frame.popClip();
    }

    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *GridState = @ptrCast(@alignCast(ptr));
        const core = &self.core;
        switch (event) {
            .pointer_move => |point| {
                const hit = core.indexAt(point, false);
                if (std.meta.eql(hit, core.hover)) return false;
                core.hover = hit;
                return true;
            },
            .pointer_leave => {
                if (core.hover == null) return false;
                core.hover = null;
                return true;
            },
            .pointer_down => |press| {
                const mods = press.modifiers;
                core.pointer = press.position;
                const index = core.indexAt(press.position, false) orelse {
                    if (core.selection) |selection| if (selection.len > 0 and !mods.control and !mods.shift) {
                        selection.clear();
                        core.pending.changed = true;
                    };
                    core.press = .none;
                    return true;
                };
                if (press.count >= 2 and !mods.shift and !mods.control) core.pending.submitted = index;
                var deferred = false;
                if (mods.control and !mods.shift) {
                    core.choose(index, .toggle);
                } else if (mods.shift) {
                    core.choose(index, if (mods.control) .range_add else .range);
                } else if (core.selected(index) and (core.reorder or core.drag_select) and core.multiple() and press.count < 2) {
                    deferred = true;
                } else core.choose(index, .set);
                if (core.drag_select and !core.reorder and core.multiple()) core.beginDragChoice(mods.control);
                core.press = .{ .rows = .{ .index = index, .column = null, .deferred = deferred, .add = mods.control } };
                return true;
            },
            .pointer_drag => |drag| {
                core.pointer = drag.position;
                switch (core.press) {
                    .rows => |*rows| {
                        if (!drag.dragging) return false;
                        if (core.reorder and !rows.reordering) {
                            rows.reordering = true;
                            rows.deferred = false;
                        } else if (!rows.selecting and !rows.reordering and core.drag_select and core.multiple()) {
                            rows.selecting = true;
                            rows.deferred = false;
                        }
                        core.setEdge(drag.position);
                        core.dragTo(drag.position);
                        return true;
                    },
                    else => return false,
                }
            },
            .pointer_up => |point| {
                // A copy, not an alias of the field cleared next.
                var pressed = core.press;
                _ = &pressed;
                core.press = .none;
                core.stopEdge();
                switch (pressed) {
                    .rows => |rows| if (rows.reordering) {
                        var target = core.reorder_target orelse core.insertionAt(point);
                        _ = &target;
                        core.reorder_target = null;
                        if (target != rows.index and target != rows.index + 1) core.pending.moved = .{ .row = rows.index, .to = target, .selection = core.selected(rows.index) };
                    } else if (rows.deferred) core.choose(rows.index, .set),
                    else => {},
                }
                return true;
            },
            .pointer_cancel => {
                core.press = .none;
                core.reorder_target = null;
                core.stopEdge();
                return true;
            },
            .wheel => |wheel| return core.wheel(wheel.delta),
            .key => |press| {
                if (core.sharedKey(press)) |handled| return handled;
                const count = core.rows.count;
                if (count == 0) return false;
                const columns_n = core.grid_columns;
                const current = core.cursorIndex();
                const from = current orelse 0;
                const page = core.page() * columns_n;
                const target: usize = switch (press.key) {
                    .left => if (current == null) 0 else from -| 1,
                    .right => if (current == null) 0 else @min(count - 1, from + 1),
                    .up => if (current == null) 0 else if (from >= columns_n) from - columns_n else from,
                    .down => if (current == null) 0 else if (from + columns_n < count) from + columns_n else from,
                    .page_up => if (current == null) 0 else from -| page,
                    .page_down => if (current == null) 0 else @min(count - 1, from + page),
                    else => return false,
                };
                core.navigate(target, press.modifiers);
                return true;
            },
        }
    }
};

/// A grid of `items`, as many columns as fit items at least
/// `min_item_width` wide, in lines of `item_height`; only the lines in view
/// paint. A click or the arrows (in both directions) choose an item,
/// Ctrl-click adds or takes one out, Shift-click and Shift with the arrows
/// choose from the anchor in item order, Ctrl+A chooses all, and Enter or a
/// double click submits. Assistive technology reads it as a list.
pub fn gridView(v: *View, state: *GridState, items: Rows, item: ItemSource, options: GridOptions) Error!Result {
    const core = &state.core;
    if (options.reorder and options.drag_select) return error.InvalidValue;
    if (!std.math.isFinite(options.min_item_width) or options.min_item_width <= 0 or !std.math.isFinite(options.item_height) or options.item_height <= 0 or !std.math.isFinite(options.gap) or options.gap < 0) return error.InvalidValue;
    core.rows = items;
    core.selection = state.selection;
    state.item_source = item;
    core.item_width = options.min_item_width;
    core.item_height = options.item_height;
    core.gap = options.gap;
    core.measurer = options.measurer;
    core.drag_select = options.drag_select;
    core.reorder = options.reorder;
    core.setName(options.style.name);
    if (core.placed) state.layoutColumns(core.bounds.width);
    if (core.hover) |hover| if (hover >= items.count) {
        core.hover = null;
    };
    var result = core.pass(v);
    try v.embed(state.embed(), options.style);
    const leaf = lastNode(v);
    core.id = leaf.id;
    core.enabled = leaf.style.enabled;
    core.buildSemantics(v);
    result.merge(core.pending);
    core.pending = .{};
    return result;
}

test {
    _ = @import("collections_tests.zig");
}
