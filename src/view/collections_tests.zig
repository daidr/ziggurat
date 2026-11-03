const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const collections = @import("collections.zig");

const View = view.View;
const Harness = view.Harness;
const Selection = collections.Selection;
const testing = std.testing;

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};
const Storage = view.Storage(64, 2048);

fn press(key: z.KeyCode) z.KeyInput {
    return .{ .key = key };
}
fn with(key: z.KeyCode, modifiers: z.KeyModifiers) z.KeyInput {
    return .{ .key = key, .modifiers = modifiers };
}

test "a selection keeps its keys sorted and adds ranges at once" {
    var storage: [8]u64 = undefined;
    var selection = Selection.init(.multiple, &storage);
    try selection.add(30);
    try selection.add(10);
    try selection.add(20);
    try selection.add(10);
    try testing.expectEqualSlices(u64, &.{ 10, 20, 30 }, selection.items());
    try testing.expect(selection.contains(20));
    try testing.expect(selection.remove(20));
    try testing.expect(!selection.contains(20));
    try selection.set(5);
    try testing.expectEqualSlices(u64, &.{5}, selection.items());
    try testing.expectEqual(@as(?u64, 5), selection.anchor);
    var single_storage: [1]u64 = undefined;
    var single = Selection.init(.single, &single_storage);
    try single.add(1);
    try single.add(2);
    try testing.expectEqualSlices(u64, &.{2}, single.items());
}

// ------------------------------------------------------------------ table

const columns = [_]collections.Column{
    .{ .title = "Name" },
    .{ .title = "Size", .width = 100, .alignment = .end, .sortable = true },
    .{ .title = "Kind", .width = 120, .sortable = true },
};

const Files = struct {
    count: usize = 100_000,
    /// Keys of the rows, when the test moves them.
    ids: ?[]const u64 = null,
    state: collections.TableState = .{},
    selection: Selection = undefined,
    storage: [256]u64 = undefined,
    sort: ?collections.SortOrder = null,
    sort_by: collections.SortKeys = .{},
    multi_sort: bool = false,
    cells: collections.Cells = .{},
    options: collections.TableOptions = .{ .style = .{ .grow = 1, .self_align = .stretch, .name = "Files" } },
    result: collections.Result = .{},
    submitted: ?usize = null,
    double: ?collections.CellRef = null,
    moved: ?collections.Move = null,
    changes: usize = 0,
    sorts: usize = 0,
    arranged: usize = 0,
    selecting: bool = false,
    use_columns: []const collections.Column = &columns,

    fn init(self: *Files, mode: Selection.Mode) void {
        self.selection = Selection.init(mode, &self.storage);
    }
    fn key(context: ?*const anyopaque, row: usize) u64 {
        const self: *const Files = @ptrCast(@alignCast(context.?));
        if (self.ids) |ids| return ids[row];
        return @as(u64, row) * 10 + 7;
    }
    fn label(context: ?*const anyopaque, row: usize, buffer: []u8) []const u8 {
        const self: *const Files = @ptrCast(@alignCast(context.?));
        const names = [_][]const u8{ "alpha", "beta", "bravo", "charlie", "delta" };
        _ = self;
        if (row < names.len) return names[row];
        return std.fmt.bufPrint(buffer, "file {d}", .{row}) catch "";
    }
    fn cell(context: ?*const anyopaque, row: usize, column: usize, buffer: []u8) collections.Cell {
        _ = context;
        return .{ .text = std.fmt.bufPrint(buffer, "r{d}c{d}", .{ row, column }) catch "" };
    }
    fn build(self: *Files, v: *View) anyerror!void {
        self.state.selection = &self.selection;
        self.state.sort = &self.sort;
        self.state.sort_by = if (self.multi_sort) &self.sort_by else null;
        self.state.cells = if (self.options.cell_select) &self.cells else null;
        const result = try collections.table(v, &self.state, self.use_columns, .{ .context = self, .count = self.count, .key = key, .label = label }, .{ .context = self, .call = cell }, self.options);
        if (result.changed) self.changes += 1;
        if (result.sorted) self.sorts += 1;
        if (result.arranged) self.arranged += 1;
        if (result.submitted) |row| self.submitted = row;
        if (result.double_clicked) |at| self.double = at;
        if (result.moved) |move| self.moved = move;
        self.selecting = result.drag_selecting;
    }
};

const Fixture = struct {
    storage: Storage = .{},
    context: ui.Context = undefined,
    dummy: u8 = 0,
    h: Harness = undefined,

    fn start(self: *Fixture, app: anytype) !void {
        const App = @TypeOf(app.*);
        self.h = Harness.init(app, App.build, self.storage.buffers(), .{});
        self.context = ui.Context.init(&self.dummy, Windowless.draw, Windowless.action);
        try self.h.attachInput(&self.context);
    }
    fn leaf(self: *const Fixture) !*const view.Node {
        return self.h.find(.{ .kind = .embed });
    }
    /// Press and release at a point inside the leaf, given relative to it.
    fn click(self: *Fixture, x: f32, y: f32, modifiers: z.KeyModifiers) !void {
        const b = (try self.leaf()).bounds;
        try self.h.press(b.x + x, b.y + y, modifiers);
        try self.h.release(b.x + x, b.y + y);
        // Clicks far apart in time do not count together.
        try self.h.advance(std.time.ns_per_s);
    }
    fn rowY(row: usize) f32 {
        return 28 + @as(f32, @floatFromInt(row)) * 28 + 14;
    }
};

test "a table of many rows paints only the rows in view and chooses by key" {
    var app: Files = .{};
    app.init(.multiple);
    var f: Fixture = .{};
    try f.start(&app);
    const leaf = try f.leaf();
    try testing.expectEqual(@as(f32, 592), leaf.bounds.width);
    // Assistive technology sees the rows in view, not all 100,000.
    try testing.expect(app.state.core.exposed_len > 10 and app.state.core.exposed_len < 20);
    try testing.expectEqual(@as(u64, 7), app.state.core.exposed[0]);

    try f.click(50, Fixture.rowY(2), .{});
    try testing.expectEqualSlices(u64, &.{27}, app.selection.items());
    try testing.expectEqual(@as(?u64, 27), app.selection.cursor);
    try testing.expectEqual(@as(usize, 1), app.changes);
    try testing.expectEqual(leaf.id, f.h.focused().?.id);

    // Shift and Ctrl choose ranges and single rows.
    try f.click(50, Fixture.rowY(5), .{ .shift = true });
    try testing.expectEqualSlices(u64, &.{ 27, 37, 47, 57 }, app.selection.items());
    try f.click(50, Fixture.rowY(3), .{ .control = true });
    try testing.expectEqualSlices(u64, &.{ 27, 47, 57 }, app.selection.items());

    // Keys move the cursor and scroll it into view.
    try testing.expect(try f.h.key(press(.down)));
    try testing.expectEqualSlices(u64, &.{47}, app.selection.items());
    try testing.expect(try f.h.key(press(.end)));
    try testing.expectEqualSlices(u64, &.{99_999 * 10 + 7}, app.selection.items());
    try testing.expect(app.state.atEnd());
    try testing.expectEqual(@as(usize, 99_999), app.state.visible().last);
    try testing.expect(try f.h.key(with(.up, .{ .shift = true })));
    try testing.expect(try f.h.key(with(.up, .{ .shift = true })));
    try testing.expectEqual(@as(usize, 3), app.selection.len);
    try testing.expect(try f.h.key(press(.home)));
    try testing.expectEqual(@as(f64, 0), app.state.scrollOffset());
    try testing.expect(try f.h.key(press(.page_down)));
    const page: usize = 14; // rows that fit the 404 DIP body
    try testing.expectEqualSlices(u64, &.{@as(u64, page) * 10 + 7}, app.selection.items());
    // Ctrl moves without choosing; Ctrl+Space adds the row there.
    try testing.expect(try f.h.key(with(.down, .{ .control = true })));
    try testing.expect(try f.h.key(with(.space, .{ .control = true })));
    try testing.expectEqual(@as(usize, 2), app.selection.len);
    try testing.expect(try f.h.key(press(.enter)));
    try testing.expectEqual(@as(?usize, page + 1), app.submitted);
    // There are more rows than the selection holds.
    try testing.expect(try f.h.key(with(.a, .{ .control = true })));
    try testing.expectEqual(@as(?anyerror, error.SelectionFull), app.state.core.last_error);
    app.state.core.last_error = null;
    app.count = 100;
    try f.h.render();
    try testing.expect(try f.h.key(with(.a, .{ .control = true })));
    try testing.expectEqual(@as(usize, 100), app.selection.len);
}

test "the wheel scrolls a table and a double click submits the row under it" {
    var app: Files = .{};
    app.init(.single);
    var f: Fixture = .{};
    try f.start(&app);
    const b = (try f.leaf()).bounds;
    try f.h.wheel(b.x + 50, b.y + 100, .{ .x = 0, .y = 280 });
    try testing.expectEqual(@as(f64, 280), app.state.scrollOffset());
    try testing.expectEqual(@as(usize, 10), app.state.visible().first);
    // Two presses at one place, close in time, are a double click.
    try f.h.press(b.x + 50, b.y + Fixture.rowY(1), .{});
    try f.h.release(b.x + 50, b.y + Fixture.rowY(1));
    try f.h.press(b.x + 50, b.y + Fixture.rowY(1), .{});
    try f.h.release(b.x + 50, b.y + Fixture.rowY(1));
    try testing.expectEqual(@as(?usize, 11), app.submitted);
    try testing.expectEqual(@as(usize, 11), app.double.?.row);
    try testing.expectEqual(@as(usize, 0), app.double.?.column);
    try testing.expectEqualSlices(u64, &.{117}, app.selection.items());
    // A wheel past the top is left to the containers around the table.
    try f.h.wheel(b.x + 50, b.y + 100, .{ .x = 0, .y = -1000 });
    try testing.expectEqual(@as(f64, 0), app.state.scrollOffset());
    try testing.expectError(error.NotFound, f.h.wheel(b.x + 50, b.y + 100, .{ .x = 0, .y = -10 }));
}

test "typing the first letters of a row chooses it" {
    var app: Files = .{};
    app.init(.single);
    app.count = 20;
    var f: Fixture = .{};
    try f.start(&app);
    try f.h.focus(.{ .kind = .embed });
    try testing.expect(try f.h.key(press(.b)));
    try testing.expectEqualSlices(u64, &.{17}, app.selection.items());
    try testing.expect(try f.h.key(press(.r)));
    try testing.expectEqualSlices(u64, &.{27}, app.selection.items());
    try f.h.advance(2 * std.time.ns_per_s);
    try testing.expect(try f.h.key(press(.d)));
    try testing.expectEqualSlices(u64, &.{47}, app.selection.items());
    // The same letter again goes on to the next row with it.
    try f.h.advance(2 * std.time.ns_per_s);
    try testing.expect(try f.h.key(press(.b)));
    try testing.expect(try f.h.key(press(.b)));
    try testing.expectEqualSlices(u64, &.{27}, app.selection.items());
}

test "headers sort, resize, fit and move their columns" {
    var app: Files = .{};
    app.init(.single);
    var f: Fixture = .{};
    try f.start(&app);
    // Name shares what Size (100) and Kind (120) leave of 592.
    const size_x: f32 = 372;
    try f.click(size_x + 30, 14, .{});
    try testing.expectEqual(collections.SortOrder{ .column = 1, .direction = .ascending }, app.sort.?);
    try f.click(size_x + 30, 14, .{});
    try testing.expectEqual(collections.SortOrder{ .column = 1, .direction = .descending }, app.sort.?);
    try testing.expectEqual(@as(usize, 2), app.sorts);
    // Name does not sort.
    try f.click(30, 14, .{});
    try testing.expectEqual(@as(usize, 1), app.sort.?.column);

    // Drag Size's trailing edge 40 DIP to the right.
    const b = (try f.leaf()).bounds;
    try f.h.drag(b.x + size_x + 100, b.y + 14, b.x + size_x + 140, b.y + 14, 4);
    var saved: [8]collections.ColumnWidth = undefined;
    var layout = app.state.layout(&saved);
    try testing.expectEqual(@as(usize, 3), layout.len);
    // Name, which shared the room, keeps its width as Size grows.
    try testing.expectEqual(@as(f32, 372), layout[0].width);
    try testing.expectEqual(@as(f32, 140), layout[1].width);
    try testing.expect(app.arranged > 0);
    try f.h.advance(std.time.ns_per_s);

    // A double click on the edge fits Size to its title and cells.
    const edge = b.x + size_x + 140;
    try f.h.press(edge, b.y + 14, .{});
    try f.h.release(edge, b.y + 14);
    try f.h.press(edge, b.y + 14, .{});
    try f.h.release(edge, b.y + 14);
    layout = app.state.layout(&saved);
    try testing.expect(layout[1].width < 140 and layout[1].width >= 40);
    try f.h.advance(std.time.ns_per_s);

    // Drag Kind's header over Name: it moves to the front.
    const kind_x = 372 + layout[1].width + 30;
    try f.h.drag(b.x + kind_x, b.y + 14, b.x + 20, b.y + 14, 6);
    layout = app.state.layout(&saved);
    try testing.expectEqual(view.key("Kind"), layout[0].id);
    try testing.expectEqual(view.key("Name"), layout[1].id);
    // A move is not a sort.
    try testing.expectEqual(@as(usize, 2), app.sorts);

    // A layout restores by id.
    const restored = [_]collections.ColumnWidth{ .{ .id = view.key("Size"), .width = 90 }, .{ .id = view.key("Name"), .width = 0 } };
    app.state.restore(&restored);
    try f.h.render();
    layout = app.state.layout(&saved);
    try testing.expectEqual(view.key("Size"), layout[0].id);
    try testing.expectEqual(@as(f32, 90), layout[0].width);
    try testing.expectEqual(view.key("Name"), layout[1].id);
    try testing.expectEqual(view.key("Kind"), layout[2].id);
}

test "Ctrl- and Shift-clicks sort by several columns" {
    var app: Files = .{};
    app.init(.single);
    app.multi_sort = true;
    var f: Fixture = .{};
    try f.start(&app);
    try f.click(372 + 30, 14, .{});
    try f.click(472 + 30, 14, .{ .control = true });
    try testing.expectEqual(@as(usize, 2), app.sort_by.len);
    try testing.expectEqual(@as(usize, 1), app.sort.?.column);
    try f.click(472 + 30, 14, .{ .shift = true });
    try testing.expectEqual(SortDirection.descending, app.sort_by.items()[1].direction);
    try f.click(472 + 30, 14, .{ .control = true });
    try testing.expectEqual(@as(usize, 1), app.sort_by.len);
    // A plain click on the first reverses it and sorts by it alone.
    try f.click(372 + 30, 14, .{});
    try testing.expectEqual(SortDirection.descending, app.sort.?.direction);
}
const SortDirection = collections.SortDirection;

test "assistive technology chooses rows and sorts by column headers" {
    var app: Files = .{};
    app.init(.multiple);
    var f: Fixture = .{};
    try f.start(&app);
    const id = (try f.leaf()).id;
    try f.h.send(.{ .action = collections.partId(id, 37) });
    try testing.expectEqualSlices(u64, &.{37}, app.selection.items());
    try f.h.send(.{ .value = .{ .id = collections.partId(id, 47), .change = .{ .set = @backingInt(view.ItemRequest.add) } } });
    try testing.expectEqualSlices(u64, &.{ 37, 47 }, app.selection.items());
    try f.h.send(.{ .value = .{ .id = collections.partId(id, 37), .change = .{ .set = @backingInt(view.ItemRequest.deselect) } } });
    try testing.expectEqualSlices(u64, &.{47}, app.selection.items());
    try f.h.send(.{ .action = collections.partId(id, 0x636f_6c75_6d6e_0000 ^ view.key("Kind")) });
    try testing.expectEqual(@as(usize, 2), app.sort.?.column);
}

test "a table keeps the item at its top as rows come above it" {
    var ids: [200]u64 = undefined;
    for (&ids, 0..) |*id, index| id.* = 1000 + index;
    var app: Files = .{};
    app.init(.single);
    app.ids = ids[50..150];
    app.count = 100;
    var f: Fixture = .{};
    try f.start(&app);
    app.state.setScrollOffset(280);
    try f.h.render();
    try testing.expectEqual(@as(usize, 10), app.state.visible().first);
    // Ten older rows load above.
    app.ids = ids[40..150];
    app.count = 110;
    try f.h.render();
    try testing.expectEqual(@as(f64, 560), app.state.scrollOffset());
    try testing.expectEqual(@as(usize, 20), app.state.visible().first);
    // With keep_offset, the offset stays.
    app.options.keep_offset = true;
    app.ids = ids[30..150];
    app.count = 120;
    try f.h.render();
    try testing.expectEqual(@as(f64, 560), app.state.scrollOffset());
}

test "a table that follows its end keeps new rows in view" {
    var app: Files = .{};
    app.init(.single);
    app.count = 100;
    app.options.follow_end = true;
    var f: Fixture = .{};
    try f.start(&app);
    try f.h.render();
    try testing.expect(app.state.atEnd());
    app.count = 120;
    try f.h.render();
    try testing.expect(app.state.atEnd());
    try testing.expectEqual(@as(usize, 119), app.state.visible().last);
    // Scrolled away, it stays where the user left it.
    const b = (try f.leaf()).bounds;
    try f.h.wheel(b.x + 50, b.y + 100, .{ .x = 0, .y = -100 });
    const offset = app.state.scrollOffset();
    app.count = 130;
    try f.h.render();
    try testing.expectEqual(offset, app.state.scrollOffset());
    app.state.scrollToEnd();
    app.count = 140;
    try f.h.render();
    try testing.expect(app.state.atEnd());
}

test "scroll requests show a row at the start, center, end or nearest" {
    var app: Files = .{};
    app.init(.single);
    var f: Fixture = .{};
    try f.start(&app);
    // The body is 432 - 28 high.
    app.state.scrollTo(100, .start);
    try testing.expectEqual(@as(f64, 2800), app.state.scrollOffset());
    app.state.scrollTo(100, .end);
    try testing.expectEqual(@as(f64, 2800 + 28 - 404), app.state.scrollOffset());
    app.state.scrollTo(100, .center);
    try testing.expectEqual(@as(f64, 2800 + 14 - 202), app.state.scrollOffset());
    app.state.scrollIntoView(100);
    try testing.expectEqual(@as(f64, 2800 + 14 - 202), app.state.scrollOffset());
    app.state.scrollIntoView(0);
    try testing.expectEqual(@as(f64, 0), app.state.scrollOffset());
    app.state.scrollToEnd();
    try testing.expect(app.state.atEnd());
}

test "dragging over rows chooses them and scrolls near the edge" {
    var app: Files = .{};
    app.init(.multiple);
    app.options.drag_select = true;
    var f: Fixture = .{};
    try f.start(&app);
    const b = (try f.leaf()).bounds;
    try f.h.press(b.x + 50, b.y + Fixture.rowY(1), .{});
    try f.h.moveTo(b.x + 50, b.y + Fixture.rowY(2));
    try f.h.moveTo(b.x + 50, b.y + Fixture.rowY(4));
    try testing.expect(app.selecting);
    try testing.expectEqualSlices(u64, &.{ 17, 27, 37, 47 }, app.selection.items());
    try f.h.moveTo(b.x + 50, b.y + Fixture.rowY(3));
    try testing.expectEqualSlices(u64, &.{ 17, 27, 37 }, app.selection.items());
    // Past the bottom the table scrolls as time passes.
    try f.h.moveTo(b.x + 50, b.y + b.height + 20);
    try f.h.advance(100 * std.time.ns_per_ms);
    try f.h.advance(100 * std.time.ns_per_ms);
    try testing.expect(app.state.scrollOffset() > 0);
    try testing.expect(f.h.deadline() != null);
    try testing.expect(app.selection.len > 14);
    try f.h.release(b.x + 50, b.y + b.height + 20);
    try testing.expect(!app.selecting);
    const kept = app.selection.len;
    try f.h.advance(100 * std.time.ns_per_ms);
    try testing.expectEqual(kept, app.selection.len);
}

test "rows drag to another place" {
    var app: Files = .{};
    app.init(.multiple);
    app.options.reorder = true;
    app.count = 10;
    var f: Fixture = .{};
    try f.start(&app);
    const b = (try f.leaf()).bounds;
    try f.h.drag(b.x + 50, b.y + Fixture.rowY(1), b.x + 50, b.y + 28 + 28 * 4 + 2, 5);
    try testing.expectEqual(collections.Move{ .row = 1, .to = 4, .selection = true }, app.moved.?);
    // Dropped where it was, nothing moves.
    app.moved = null;
    try f.h.advance(std.time.ns_per_s);
    try f.h.drag(b.x + 50, b.y + Fixture.rowY(2), b.x + 50, b.y + Fixture.rowY(2) + 8, 3);
    try testing.expect(app.moved == null);
}

const sheet_columns = [_]collections.Column{
    .{ .title = "#", .width = 48, .fixed = true, .row_header = true },
    .{ .title = "A", .width = 200 },
    .{ .title = "B", .width = 200 },
    .{ .title = "C", .width = 200 },
};

test "a table chooses blocks of cells" {
    var app: Files = .{};
    app.init(.multiple);
    app.use_columns = &sheet_columns;
    app.options.cell_select = true;
    app.count = 50;
    var f: Fixture = .{};
    try f.start(&app);
    try f.click(60, Fixture.rowY(1), .{});
    try testing.expectEqual(collections.Cells{ .anchor = 1, .cursor = 1 }, app.cells);
    try testing.expect(app.state.cellSelected(1, 1));
    try testing.expect(!app.state.cellSelected(1, 2));
    // Shift-click extends the rows and the columns.
    try f.click(260, Fixture.rowY(3), .{ .shift = true });
    try testing.expectEqual(@as(usize, 2), app.cells.cursor);
    try testing.expect(app.state.cellSelected(2, 2));
    try testing.expect(!app.state.cellSelected(4, 2));
    var buffer: [4]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, app.state.selectedColumns(&buffer));
    // Keys move and extend the cursor column.
    try testing.expect(try f.h.key(with(.right, .{ .shift = true })));
    try testing.expectEqual(@as(usize, 3), app.cells.cursor);
    try testing.expect(app.state.cellSelected(3, 3));
    try testing.expect(try f.h.key(press(.left)));
    try testing.expectEqual(collections.Cells{ .anchor = 2, .cursor = 2 }, app.cells);
    try testing.expectEqual(@as(usize, 1), app.selection.len);
    // The row header chooses whole rows, and its header every row.
    try f.click(20, Fixture.rowY(5), .{});
    try testing.expect(app.cells.all);
    try testing.expect(app.state.cellSelected(5, 3));
    try f.click(20, 14, .{});
    try testing.expectEqual(@as(usize, 50), app.selection.len);
    app.state.selectColumns(2, 3);
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, app.state.selectedColumns(&buffer));
    // Fixed columns stay as the table scrolls sideways; the others move.
    const b = (try f.leaf()).bounds;
    // Moving the cursor to C scrolled as far right as the columns go.
    try testing.expectEqual(@as(f32, 648 - 592), app.state.core.scroll_x);
    try f.h.wheel(b.x + 100, b.y + 100, .{ .x = -30, .y = 0 });
    try testing.expectEqual(@as(f32, 26), app.state.core.scroll_x);
    try f.click(20, Fixture.rowY(0), .{});
    try testing.expect(app.cells.all);
}

// ---------------------------------------------------------------- outline

const Folders = struct {
    // 1 has 2 and 3; 2 has 4 and 5; 3, 4, 5 and 6 are leaves.
    state: collections.OutlineState = .{},
    open: Selection = undefined,
    open_storage: [16]u64 = undefined,
    selection: Selection = undefined,
    selection_storage: [16]u64 = undefined,
    rows: [32]collections.OutlineRow = undefined,
    toggles: usize = 0,
    columns: bool = false,

    fn init(self: *Folders) void {
        self.open = Selection.init(.multiple, &self.open_storage);
        self.selection = Selection.init(.single, &self.selection_storage);
        self.state.open = &self.open;
        self.state.rows_buffer = &self.rows;
        self.state.table.selection = &self.selection;
    }
    fn count(_: ?*const anyopaque, parent: ?u64) usize {
        const p = parent orelse return 2;
        return switch (p) {
            1, 2 => 2,
            else => 0,
        };
    }
    fn child(_: ?*const anyopaque, parent: ?u64, index: usize) u64 {
        const p = parent orelse return if (index == 0) 1 else 6;
        return if (p == 1) 2 + index else 4 + index;
    }
    fn label(_: ?*const anyopaque, item: u64, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "item {d}", .{item}) catch "";
    }
    fn cell(_: ?*const anyopaque, item: u64, column: usize, buffer: []u8) collections.Cell {
        return .{ .text = std.fmt.bufPrint(buffer, "{d}/{d}", .{ item, column }) catch "" };
    }
    fn build(self: *Folders, v: *View) anyerror!void {
        const tree: collections.Tree = .{ .count = count, .child = child, .label = label };
        const options: collections.OutlineOptions = .{ .style = .{ .grow = 1, .self_align = .stretch } };
        const result = if (self.columns)
            try collections.outlineTable(v, &self.state, &columns, tree, .{ .call = cell }, options)
        else
            try collections.outline(v, &self.state, tree, options);
        if (result.toggled) self.toggles += 1;
    }
    fn keys(self: *const Folders, out: []u64) []u64 {
        for (self.state.rows(), 0..) |row, index| out[index] = row.key;
        return out[0..self.state.rows().len];
    }
};

test "an outline opens and closes its items" {
    var app: Folders = .{};
    app.init();
    var f: Fixture = .{};
    try f.start(&app);
    var buffer: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 1, 6 }, app.keys(&buffer));
    // The arrow of item 1 opens it, without choosing it.
    try f.click(8 + 6, 14, .{});
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 6 }, app.keys(&buffer));
    try testing.expectEqual(@as(usize, 0), app.selection.len);
    try testing.expectEqual(@as(u16, 1), app.state.depth(1));
    // A click on the row chooses it; Right opens 2, then goes to its child.
    try f.click(100, 28 + 14, .{});
    try testing.expectEqualSlices(u64, &.{2}, app.selection.items());
    try testing.expect(try f.h.key(press(.right)));
    try testing.expectEqualSlices(u64, &.{ 1, 2, 4, 5, 3, 6 }, app.keys(&buffer));
    try testing.expect(try f.h.key(press(.right)));
    try testing.expectEqualSlices(u64, &.{4}, app.selection.items());
    // Left goes to the parent, then closes it.
    try testing.expect(try f.h.key(press(.left)));
    try testing.expectEqualSlices(u64, &.{2}, app.selection.items());
    try testing.expect(try f.h.key(press(.left)));
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 6 }, app.keys(&buffer));
    // Closing an item whose child has the cursor chooses the item.
    try testing.expect(try f.h.key(press(.down)));
    try testing.expectEqualSlices(u64, &.{3}, app.selection.items());
    try f.click(8 + 6, 14, .{});
    try testing.expectEqualSlices(u64, &.{ 1, 6 }, app.keys(&buffer));
    try testing.expectEqualSlices(u64, &.{1}, app.selection.items());
    // Shift+Right opens everything inside.
    try testing.expect(try f.h.key(with(.right, .{ .shift = true })));
    try testing.expectEqualSlices(u64, &.{ 1, 2, 4, 5, 3, 6 }, app.keys(&buffer));
    try testing.expect(try f.h.key(with(.left, .{ .shift = true })));
    try testing.expectEqualSlices(u64, &.{ 1, 6 }, app.keys(&buffer));
    try testing.expectEqual(@as(usize, 0), app.open.len);
    // Assistive technology opens items too.
    const id = (try f.leaf()).id;
    try f.h.send(.{ .value = .{ .id = collections.partId(id, 1), .change = .{ .set = @backingInt(view.ItemRequest.expand) } } });
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 6 }, app.keys(&buffer));
    try testing.expect(app.toggles >= 6);
}

test "an outline table shows its arrows in the first column" {
    var app: Folders = .{};
    app.init();
    app.columns = true;
    var f: Fixture = .{};
    try f.start(&app);
    var buffer: [8]u64 = undefined;
    // Below the header row.
    try f.click(8 + 6, 28 + 14, .{ .alt = true });
    try testing.expectEqualSlices(u64, &.{ 1, 2, 4, 5, 3, 6 }, app.keys(&buffer));
    try f.click(100, 28 * 3 + 14, .{});
    try testing.expectEqualSlices(u64, &.{4}, app.selection.items());
}

// ------------------------------------------------------------------- grid

const Photos = struct {
    count: usize = 1000,
    state: collections.GridState = .{},
    selection: Selection = undefined,
    storage: [64]u64 = undefined,
    submitted: ?usize = null,

    fn item(_: ?*const anyopaque, index: usize, buffer: []u8) collections.GridItem {
        return .{ .text = std.fmt.bufPrint(buffer, "photo {d}", .{index}) catch "" };
    }
    fn build(self: *Photos, v: *View) anyerror!void {
        self.state.selection = &self.selection;
        const result = try collections.gridView(v, &self.state, .{ .count = self.count }, .{ .call = item }, .{ .min_item_width = 140, .item_height = 100, .style = .{ .grow = 1, .self_align = .stretch } });
        if (result.submitted) |index| self.submitted = index;
    }
};

test "a grid view lays items in as many columns as fit and moves in both directions" {
    var app: Photos = .{};
    app.selection = Selection.init(.multiple, &app.storage);
    var f: Fixture = .{};
    try f.start(&app);
    // 592 wide fits (592 - 8) / 148 = 3 columns of items at least 140 wide.
    try testing.expectEqual(@as(usize, 3), app.state.columns());
    try f.click(8 + 10, 8 + 10, .{});
    try testing.expectEqualSlices(u64, &.{1}, app.selection.items());
    try testing.expect(try f.h.key(press(.right)));
    try testing.expect(try f.h.key(press(.down)));
    try testing.expectEqualSlices(u64, &.{5}, app.selection.items());
    try testing.expect(try f.h.key(with(.down, .{ .shift = true })));
    try testing.expectEqualSlices(u64, &.{ 5, 6, 7, 8 }, app.selection.items());
    try testing.expect(try f.h.key(press(.end)));
    try testing.expectEqualSlices(u64, &.{1000}, app.selection.items());
    try testing.expect(app.state.visible().last == 999);
    try testing.expect(try f.h.key(press(.enter)));
    try testing.expectEqual(@as(?usize, 999), app.submitted);
    // Narrower, it has fewer columns.
    try f.h.resize(.{ .x = 0, .y = 0, .width = 400, .height = 480 });
    try f.h.render();
    try testing.expectEqual(@as(usize, 2), app.state.columns());
}

test "a table's scroll bar drags from where its thumb is pressed, to either end" {
    var app: Files = .{};
    app.init(.single);
    var f: Fixture = .{};
    try f.start(&app);
    const b = (try f.leaf()).bounds;
    const x = b.x + b.width - 3;
    // Pressed on the thumb at the top and dragged past the bottom: the end.
    try f.h.drag(x, b.y + 32, x, b.y + b.height + 200, 4);
    try testing.expect(app.state.scrollOffset() > 0);
    const most = app.state.scrollOffset();
    try f.h.drag(x, b.y + b.height - 6, x, b.y + b.height + 100, 2);
    try testing.expectEqual(most, app.state.scrollOffset());
    // And back above the top: the start, no row chosen.
    try f.h.drag(x, b.y + b.height - 6, x, b.y - 500, 4);
    try testing.expectEqual(@as(f64, 0), app.state.scrollOffset());
    try testing.expectEqual(@as(usize, 0), app.selection.items().len);
}
