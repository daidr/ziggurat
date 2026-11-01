const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const ui = @import("ziggurat_ui");
const wake = @import("ziggurat_wake");
const view_timer = @import("ziggurat_view_timer");
const graphics = @import("ziggurat_view_graphics");
const video = @import("ziggurat_view_video");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ScrollEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, state: c_uint, direction: c_int, device: ?*anyopaque, x_root: f64, y_root: f64, delta_x: f64, delta_y: f64, is_stop: c_uint };
const MotionEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, is_hint: i16, device: ?*anyopaque, x_root: f64, y_root: f64 };
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };

const width = 360;
const height = 800;

const Native = struct {
    fn paint(window: z.Window) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            _ = c.InvalidateRect(hwnd, null, 0);
            _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        } else {
            const scope = window.beginCallback().?;
            defer scope.end();
            zlg_test_paint(scope.record.native.native.?, width, height);
        }
    }
    fn pointer(window: z.Window, down: bool, x: f32, y: f32) void {
        button(window, down, false, x, y);
    }
    /// The primary button, or with `secondary` the secondary one.
    fn button(window: z.Window, down: bool, secondary: bool, x: f32, y: f32) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            const px: u16 = @bitCast(@as(i16, @intFromFloat(x * scale)));
            const py: u16 = @bitCast(@as(i16, @intFromFloat(y * scale)));
            const point: c.LPARAM = @intCast(@as(u32, px) | (@as(u32, py) << 16));
            const message: c.UINT = if (secondary) (if (down) c.WM_RBUTTONDOWN else c.WM_RBUTTONUP) else if (down) c.WM_LBUTTONDOWN else c.WM_LBUTTONUP;
            _ = c.SendMessageW(hwnd, message, 0, point);
        } else {
            const widget = gtk_bin_get_child(window.nativeHandle().?).?;
            const event = gdk_event_new(if (down) 4 else 7).?;
            defer gdk_event_free(event);
            const native: *ButtonEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = if (down) 4 else 7, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = if (secondary) 3 else 1, .device = null, .x_root = 0, .y_root = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, if (down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), native, &handled);
        }
    }
    fn move(window: z.Window, x: f32, y: f32) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            const px: u16 = @bitCast(@as(i16, @intFromFloat(x * scale)));
            const py: u16 = @bitCast(@as(i16, @intFromFloat(y * scale)));
            _ = c.SendMessageW(hwnd, c.WM_MOUSEMOVE, 0, @intCast(@as(u32, px) | (@as(u32, py) << 16)));
        } else {
            const widget = gtk_bin_get_child(window.nativeHandle().?).?;
            const event = gdk_event_new(3).?;
            defer gdk_event_free(event);
            const native: *MotionEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 3, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .is_hint = 0, .device = null, .x_root = 0, .y_root = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "motion-notify-event", native, &handled);
        }
    }
    /// One wheel notch downwards at a point, which both backends report as 48 DIP.
    fn wheelDown(window: z.Window, x: f32, y: f32) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            var screen: c.POINT = .{ .x = @intFromFloat(x * scale), .y = @intFromFloat(y * scale) };
            _ = c.ClientToScreen(hwnd, &screen);
            const px: u16 = @bitCast(@as(i16, @intCast(screen.x)));
            const py: u16 = @bitCast(@as(i16, @intCast(screen.y)));
            const notch: u16 = @bitCast(@as(i16, -120));
            _ = c.SendMessageW(hwnd, c.WM_MOUSEWHEEL, @as(c.WPARAM, notch) << 16, @intCast(@as(u32, px) | (@as(u32, py) << 16)));
        } else {
            const widget = gtk_bin_get_child(window.nativeHandle().?).?;
            const event = gdk_event_new(31).?;
            defer gdk_event_free(event);
            const native: *ScrollEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 31, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .state = 0, .direction = 1, .device = null, .x_root = 0, .y_root = 0, .delta_x = 0, .delta_y = 0, .is_stop = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "scroll-event", native, &handled);
        }
    }
    fn click(window: z.Window, bounds: view.Rect) void {
        const x = bounds.x + bounds.width / 2;
        const y = bounds.y + bounds.height / 2;
        pointer(window, true, x, y);
        pointer(window, false, x, y);
    }
};

const State = struct {
    count: usize = 0,
    agreed: bool = false,
    level: f64 = 0,
    rows: usize = 2,
    mode: enum { list, grid } = .list,
    amount: f64 = 3,
    list: view.ScrollModel = .{},
    section: enum { general, advanced } = .general,
    pane: f64 = 0.5,
    zoom: enum { small, large } = .small,
    more: bool = false,
    opened: usize = 0,
    score: u8 = 0,
    font: usize = 0,
    forward: usize = 0,
    fn build(self: *State, v: *view.View) anyerror!void {
        try v.textf("Count: {d}", .{self.count}, .{});
        try v.toolbar(.{ .gap = 8, .name = "Actions" });
        if (try v.button("Increment", .{})) self.count += 1;
        if (try v.button("Add row", .{})) self.rows += 1;
        try v.end();
        _ = try v.checkbox(&self.agreed, "Agree", .{});
        try v.radioGroup(.{ .name = "Mode" });
        _ = try v.radio(@TypeOf(self.mode), &self.mode, .list, "List", .{});
        _ = try v.radio(@TypeOf(self.mode), &self.mode, .grid, "Grid", .{});
        try v.end();
        _ = try v.slider(&self.level, .{ .minimum = 0, .maximum = 10, .step = 1 }, .{ .width = 200 });
        _ = try v.stepper(&self.amount, .{ .minimum = 0, .maximum = 9, .step = 1 }, .{ .name = "Amount" });
        try v.scroll(&self.list, .{ .height = 80, .self_align = .stretch, .background = 0xe5e9ed });
        for (0..self.rows) |i| try v.textf("Row {d}", .{i}, .{ .key = i + 1 });
        try v.end();
        try v.grid(&columns, .{ .gap = 8, .self_align = .stretch });
        try v.text("Name", .{});
        try v.text("Value", .{});
        try v.end();
        try v.tabs(.{ .name = "Sections" });
        _ = try v.tab(@TypeOf(self.section), &self.section, .general, "General", .{});
        _ = try v.tab(@TypeOf(self.section), &self.section, .advanced, "Advanced", .{});
        try v.end();
        _ = try v.split(.row, &self.pane, .{ .minimum = 0.1, .maximum = 0.9 }, .{ .height = 40, .self_align = .stretch, .name = "Panes" });
        try v.column(.{ .background = 0xe5e9ed });
        try v.end();
        try v.column(.{ .background = 0xd5dde5 });
        try v.end();
        try v.end();
        try v.row(.{ .gap = 8, .alignment = .center });
        try v.segmented(.{ .name = "Zoom" });
        _ = try v.segment(@TypeOf(self.zoom), &self.zoom, .small, "Small", .{});
        _ = try v.segment(@TypeOf(self.zoom), &self.zoom, .large, "Large", .{});
        try v.end();
        try v.badge("New", .{});
        if (try v.link("Help", .{})) self.opened += 1;
        try v.end();
        _ = try v.disclosure(&self.more, "More", .{});
        if (self.more) try v.text("Extra", .{});
        try v.row(.{ .gap = 8, .alignment = .center });
        _ = try v.rating(&self.score, 5, .{ .name = "Score" });
        try v.meter(3, .{ .minimum = 0, .maximum = 4 }, .{}, .{ .name = "Level", .grow = 1 });
        try v.end();
        try v.row(.{ .gap = 8, .alignment = .center });
        try v.comboBox(fonts[self.font], .{ .name = "Font", .width = 140 });
        for (fonts, 0..) |font, i| _ = try v.comboOption(usize, &self.font, i, font, .{});
        try v.end();
        try v.tooltip("Typeface");
        if (try v.navButton(.forward, .{})) self.forward += 1;
        try v.avatar("Ada Lovelace", null, .{});
        try v.end();
    }
    const fonts = [_][]const u8{ "Serif", "Sans", "Mono" };
    const columns = [_]view.Track{ view.Track.fixed(80), view.Track.fraction(1) };
};

fn find(host: *const view.Host, kind: view.Kind, nth: usize) !view.Node {
    var seen: usize = 0;
    for (host.view.nodes()) |node| if (node.kind == kind) {
        if (seen == nth) return node;
        seen += 1;
    };
    return error.MissingNode;
}

fn paint(host: *view.Host, window: z.Window) !void {
    const before = host.frames;
    Native.paint(window);
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(before + 1, host.frames);
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var storage: view.Storage(64, 512) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try paint(&host, window);
    const increment = try find(&host, .button, 0);
    try std.testing.expect(increment.bounds.width > 0 and increment.bounds.height > 0);
    try std.testing.expectEqualStrings("Count: 0", (try find(&host, .text, 0)).text);
    // Each activation updates state immediately; none waits for a repaint.
    Native.click(window, increment.bounds);
    Native.click(window, increment.bounds);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try paint(&host, window);
    try std.testing.expectEqualStrings("Count: 2", (try find(&host, .text, 0)).text);
    try std.testing.expectEqual(increment.id, (try find(&host, .button, 0)).id);

    Native.click(window, (try find(&host, .checkbox, 0)).bounds);
    try std.testing.expect(state.agreed);
    try paint(&host, window);
    try std.testing.expect((try find(&host, .checkbox, 0)).checked);

    Native.click(window, (try find(&host, .radio, 1)).bounds);
    try std.testing.expectEqual(.grid, state.mode);
    try paint(&host, window);
    try std.testing.expect((try find(&host, .radio, 1)).checked and !(try find(&host, .radio, 0)).checked);

    const slider = try find(&host, .slider, 0);
    Native.click(window, .{ .x = slider.bounds.x + slider.bounds.width - 2, .y = slider.bounds.y, .width = 0, .height = slider.bounds.height });
    try std.testing.expect(state.level > 5);

    // A keyed row keeps its identity as the list grows.
    try paint(&host, window);
    const last_row = try find(&host, .text, 2);
    Native.click(window, (try find(&host, .button, 1)).bounds);
    try std.testing.expectEqual(@as(usize, 3), state.rows);
    try paint(&host, window);
    try std.testing.expectEqual(last_row.id, (try find(&host, .text, 2)).id);
    try std.testing.expectEqualStrings("Row 2", (try find(&host, .text, 3)).text);

    // The stepper's increment button sits at its far end.
    const stepper = try find(&host, .stepper, 0);
    Native.click(window, .{ .x = stepper.bounds.x + stepper.bounds.width - stepper.bounds.height / 2 - 1, .y = stepper.bounds.y, .width = 2, .height = stepper.bounds.height });
    try std.testing.expectEqual(@as(f64, 4), state.amount);

    // Wheel input over the list scrolls it immediately; elsewhere it does not.
    // An event pass rebuilds the tree without arranging it, so paint before
    // reading bounds again.
    for (0..3) |_| {
        Native.click(window, (try find(&host, .button, 1)).bounds);
        try paint(&host, window);
    }
    const list = try find(&host, .scroll, 0);
    try std.testing.expect(state.list.content.height > state.list.viewport.height);
    Native.wheelDown(window, list.bounds.x + 10, list.bounds.y - 10);
    try std.testing.expectEqual(@as(f32, 0), state.list.offset.y);
    Native.wheelDown(window, list.bounds.x + 10, list.bounds.y + 10);
    try std.testing.expect(state.list.offset.y > 0);
    try paint(&host, window);
    try std.testing.expectEqual(list.bounds.y - state.list.offset.y, (try find(&host, .text, 1)).bounds.y);
    const name = try find(&host, .text, state.rows + 1);
    const value = try find(&host, .text, state.rows + 2);
    try std.testing.expectEqualStrings("Value", value.text);
    try std.testing.expectEqual(name.bounds.y, value.bounds.y);
    try std.testing.expectEqual(name.bounds.x + 88, value.bounds.x);

    // A tab selects on click, and the divider follows a captured drag.
    Native.click(window, (try find(&host, .tab, 1)).bounds);
    try std.testing.expectEqual(.advanced, state.section);
    try paint(&host, window);
    try std.testing.expect((try find(&host, .tab, 1)).checked and !(try find(&host, .tab, 0)).checked);
    const split = try find(&host, .split, 0);
    const divider = host.view.divider(&split).?;
    const y = divider.y + divider.height / 2;
    Native.pointer(window, true, divider.x + divider.width / 2, y);
    Native.pointer(window, false, split.bounds.x + view.split_divider / 2 + (split.bounds.width - view.split_divider) * 0.75, y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), state.pane, 0.02);
    try paint(&host, window);
    const pane = try find(&host, .column, 1);
    try std.testing.expectEqual(@round((split.bounds.width - view.split_divider) * @as(f32, @floatCast(state.pane))), pane.bounds.width);
    // The pointer over the divider shows the resize arrow, over a button
    // the default one.
    const moved = host.view.divider(&(try find(&host, .split, 0))).?;
    Native.move(window, moved.x + moved.width / 2, moved.y + moved.height / 2);
    try std.testing.expectEqual(z.Cursor.resize_ew, window.currentCursor());
    const button = try find(&host, .button, 0);
    Native.move(window, button.bounds.x + 2, button.bounds.y + 2);
    try std.testing.expectEqual(z.Cursor.default, window.currentCursor());

    // Segments, links and disclosures activate through native clicks.
    Native.click(window, (try find(&host, .segment, 1)).bounds);
    try std.testing.expectEqual(.large, state.zoom);
    try paint(&host, window);
    Native.click(window, (try find(&host, .link, 0)).bounds);
    try std.testing.expectEqual(@as(usize, 1), state.opened);
    try paint(&host, window);
    const more = try find(&host, .disclosure, 0);
    try std.testing.expect(more.bounds.y + more.bounds.height <= height);
    Native.click(window, more.bounds);
    try std.testing.expect(state.more);
    try paint(&host, window);
    try std.testing.expect((try find(&host, .disclosure, 0)).checked);
    try std.testing.expectEqualStrings("Extra", (try find(&host, .text, state.rows + 3)).text);

    // Pressing a rating mark sets the score to that mark.
    const rating = try find(&host, .rating, 0);
    try std.testing.expect(rating.bounds.y + rating.bounds.height <= height);
    const fourth = ui.widgets.ratingMark(rating.bounds, 5, 3);
    Native.click(window, .{ .x = fourth.x + 2, .y = fourth.y, .width = 0, .height = fourth.height });
    try std.testing.expectEqual(@as(u8, 4), state.score);
    try paint(&host, window);
    try std.testing.expectEqual(@as(f64, 4), (try find(&host, .rating, 0)).value);

    // A combo box opens its list over the content above or below it; a
    // press on an option picks it and closes the list.
    const combo = try find(&host, .combo_box, 0);
    try std.testing.expect(combo.bounds.y + combo.bounds.height <= height);
    Native.click(window, combo.bounds);
    try paint(&host, window);
    try std.testing.expect((try find(&host, .popup, 0)).checked and (try find(&host, .combo_box, 0)).checked);
    Native.click(window, (try find(&host, .list_item, 2)).bounds);
    try std.testing.expectEqual(@as(usize, 2), state.font);
    try paint(&host, window);
    try std.testing.expect(!(try find(&host, .popup, 0)).checked);
    try std.testing.expectEqualStrings("Mono", (try find(&host, .combo_box, 0)).text);
    Native.click(window, (try find(&host, .nav_button, 0)).bounds);
    try std.testing.expectEqual(@as(usize, 1), state.forward);

    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
}

/// A tree, a sortable table, a token field and an interactive embedded leaf
/// driven by native presses.
const Collections = struct {
    pressed: ?view.Point = null,
    open: bool = false,
    tree_storage: [2]u64 = undefined,
    tree: view.Selection = undefined,
    sort: ?view.Sort = null,
    table_storage: [4]u64 = undefined,
    table: view.Selection = undefined,
    order: [3]u64 = .{ 1, 2, 3 },
    tags: [3][]const u8 = .{ "red", "green", "blue" },
    tag_count: usize = 3,
    fn build(self: *Collections, v: *view.View) anyerror!void {
        try v.tree(&self.tree, .{ .name = "Folders", .self_align = .stretch });
        _ = try v.treeItem(1, &self.open, "Projects", .{});
        if (self.open) {
            _ = try v.treeItem(2, null, "Ziggurat", .{});
            try v.end();
        }
        try v.end();
        _ = try v.treeItem(3, null, "Archive", .{});
        try v.end();
        try v.end();
        const columns = [_]view.Column{ .{ .title = "Name" }, .{ .title = "Size" } };
        if (try v.table(&columns, &self.sort, &self.table, .{ .name = "Files", .self_align = .stretch })) std.mem.reverse(u64, &self.order);
        for (self.order) |id| {
            _ = try v.tableRow(id, names[id - 1], .{});
            try v.text(names[id - 1], .{});
            try v.textf("{d} KB", .{id * 10}, .{});
            try v.end();
        }
        try v.end();
        try v.tokenField(.{ .name = "Tags", .self_align = .stretch });
        var index: usize = 0;
        while (index < self.tag_count) {
            if (try v.token(self.tags[index], .{ .key = view.key(self.tags[index]) })) {
                std.mem.copyForwards([]const u8, self.tags[index .. self.tag_count - 1], self.tags[index + 1 .. self.tag_count]);
                self.tag_count -= 1;
            } else index += 1;
        }
        try v.end();
        try v.embed(.{ .context = self, .measure = Leaf.measure, .paint = Leaf.paint, .focusable = true, .input = Leaf.input }, .{ .key = 9, .name = "Chart" });
    }
    const Leaf = struct {
        fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
            return .{ .minimum = .{ .width = 80, .height = 40 }, .preferred = .{ .width = 80, .height = 40 } };
        }
        fn paint(_: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
            frame.rect(bounds, 0x336699);
        }
        fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
            const self: *Collections = @ptrCast(@alignCast(ptr));
            switch (event) {
                .pointer_down => |press| self.pressed = press.position,
                else => return false,
            }
            return true;
        }
    };
    const names = [_][]const u8{ "alpha.txt", "beta.txt", "gamma.txt" };
};

fn runCollections(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Collections = .{};
    state.tree = .init(.single, &state.tree_storage);
    state.table = .init(.multiple, &state.table_storage);
    var storage: view.Storage(64, 512) = .{};
    var host = view.Host.init(&state, Collections.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try paint(&host, window);
    // The triangle expands a tree item; a press elsewhere selects it.
    const projects = try find(&host, .tree_row, 0);
    const mark = ui.widgets.treeExpander(projects.bounds, 0, host.context.currentTheme().metrics.indicator_size);
    Native.click(window, mark);
    try std.testing.expect(state.open);
    try std.testing.expectEqual(@as(usize, 0), state.tree.len);
    try paint(&host, window);
    try std.testing.expectEqualStrings("Ziggurat", (try find(&host, .tree_row, 1)).text);
    Native.click(window, (try find(&host, .tree_row, 2)).bounds);
    try std.testing.expectEqualSlices(u64, &.{3}, state.tree.items());
    try paint(&host, window);
    try std.testing.expect((try find(&host, .tree_row, 2)).checked);

    // A header press sorts; a row press selects that item.
    Native.click(window, (try find(&host, .column_header, 1)).bounds);
    try std.testing.expectEqual(@as(?view.Sort, .{ .column = 1 }), state.sort);
    try paint(&host, window);
    try std.testing.expectEqual(@as(?view.SortDirection, .ascending), (try find(&host, .column_header, 1)).sort);
    try std.testing.expectEqualStrings("gamma.txt", (try find(&host, .table_row, 0)).text);
    Native.click(window, (try find(&host, .table_row, 1)).bounds);
    try std.testing.expectEqualSlices(u64, &.{2}, state.table.items());
    try paint(&host, window);
    const header = try find(&host, .column_header, 1);
    var cell: ?view.Node = null;
    for (host.view.nodes()) |node| if (node.kind == .text and std.mem.eql(u8, node.text, "30 KB")) {
        cell = node;
    };
    try std.testing.expectEqual(header.bounds.x, cell.?.bounds.x);

    // The end of a token is its remove button.
    const green = try find(&host, .token, 1);
    Native.click(window, .{ .x = green.bounds.x + green.bounds.width - 4, .y = green.bounds.y, .width = 0, .height = green.bounds.height });
    try std.testing.expectEqual(@as(usize, 2), state.tag_count);
    try paint(&host, window);
    try std.testing.expectEqualStrings("blue", (try find(&host, .token, 1)).text);

    // A consumed press reaches the leaf in local coordinates and focuses it;
    // an announcement paints as a status.
    const chart = try find(&host, .embed, 0);
    Native.click(window, chart.bounds);
    try std.testing.expectApproxEqAbs(chart.bounds.width / 2, state.pressed.?.x, 0.5);
    try std.testing.expectEqual(@as(?u64, chart.id), host.context.input_state.focused);
    host.announce("Chart selected");
    try paint(&host, window);

    _ = try window.destroy();
    try app.dispatch();
}

/// A routed page with history buttons, icons and an SVG picture whose
/// pixels are prepared in tasks posted after paint.
const Pictures = struct {
    router: view.Router = undefined,
    logo: graphics.SvgImage = undefined,
    fn build(self: *Pictures, v: *view.View) anyerror!void {
        try v.row(.{ .gap = 4 });
        _ = try v.backButton(&self.router, .{});
        _ = try v.forwardButton(&self.router, .{});
        try v.icon(.home, .{ .name = "Home" }, .{});
        try v.end();
        const page = try v.route(&self.router, .{});
        if (page.match("/")) {
            page.title("Start");
            if (try v.button("Open", .{})) try self.router.push("/details");
        } else if (page.match("/details")) {
            page.title("Details");
            try v.icon(.arrow_right, .{}, .{});
            try v.svg(self.logo.picture(), .{ .alt = "Logo" }, .{ .width = 96, .height = 48 });
        }
        try v.end();
    }
};

fn runPictures(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Pictures = .{};
    var entries: [4]view.RouteEntry = undefined;
    state.router = try .init(&entries, "/");
    var storage: view.Storage(32, 256) = .{};
    var host = view.Host.init(&state, Pictures.build, storage.buffers(), .{});
    var icons = graphics.Icons.init(allocator, &host);
    host.view.icons = icons.painter();
    host.context.render_mode = .gdi;
    state.logo = try .init(allocator, &host, "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='24'><rect width='48' height='24' fill='currentColor'/></svg>", .{});
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);

    // The first frame finds the icon missing and prepares it after paint.
    try paint(&host, window);
    try std.testing.expect(icons.queued and (try find(&host, .nav_button, 0)).style.enabled == false);
    try app.dispatch();
    if (icons.last_error) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), icons.count());
    try paint(&host, window);
    try std.testing.expect(!icons.queued);

    Native.click(window, (try find(&host, .button, 0)).bounds);
    try std.testing.expectEqualStrings("/details", state.router.location());
    try paint(&host, window);
    try std.testing.expect(state.logo.queued and !state.logo.ready());
    try app.dispatch();
    if (icons.last_error) |err| return err;
    if (state.logo.last_error) |err| return err;
    try std.testing.expect(state.logo.ready());
    try std.testing.expectEqual(@as(usize, 2), icons.count());
    const shown = try find(&host, .svg, 0);
    try std.testing.expectEqual(@as(f32, 96), shown.bounds.width);
    try paint(&host, window);
    try std.testing.expect(!state.logo.queued and !icons.queued);

    // The Back button returns to the first page.
    Native.click(window, (try find(&host, .nav_button, 0)).bounds);
    try std.testing.expectEqualStrings("/", state.router.location());
    try paint(&host, window);
    try std.testing.expect(state.router.canGoForward());

    icons.deinit();
    state.logo.deinit();
    try std.testing.expectEqual(@as(usize, 0), icons.count());
    _ = try window.destroy();
    try app.dispatch();
}

/// A toast that expires through the native one-shot timer, with the window
/// repainting only for that deadline.
const Expiring = struct {
    app: *z.App,
    host: *view.Host = undefined,
    queue: view.Toasts(2) = .{},
    shown: bool = false,
    quitting: bool = false,
    fn build(self: *Expiring, v: *view.View) anyerror!void {
        try v.text("Notices", .{});
        _ = try v.toasts(&self.queue, .{});
        if (self.queue.len > 0) self.shown = true;
        if (self.shown and self.queue.len == 0 and !self.quitting) {
            self.quitting = true;
            try self.app.post(.{ .context = self, .call = quit });
        }
    }
    fn quit(ptr: *anyopaque) void {
        const self: *Expiring = @ptrCast(@alignCast(ptr));
        self.app.quit();
    }
};

fn runTimer(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Expiring = .{ .app = app };
    _ = try state.queue.show("Saved", .{ .duration = 30 * std.time.ns_per_ms });
    var storage: view.Storage(16, 128) = .{};
    var host = view.Host.init(&state, Expiring.build, storage.buffers(), .{});
    state.host = &host;
    host.context.render_mode = .gdi;
    var timer = view_timer.Timer.init(&host);
    const window = try app.createWindow(.{ .width = 240, .height = 160 });
    try host.attach(window);
    try timer.attach(app, allocator);
    try window.setClientBounds(.{ .position = .{ .x = -16000, .y = -16000 }, .width = 240, .height = 160 });
    try window.perform(.show);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (host.last_error) |err| return err;
    if (timer.last_error) |err| return err;
    try std.testing.expect(state.shown and state.queue.len == 0);
    // Nothing is left to wait for, so the window goes idle.
    try std.testing.expectEqual(@as(?u64, null), host.view.wake);
    try timer.close();
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
}

/// A harness frame drawn to pixels: the background, a colored panel and a
/// button, as a window would show them.
const Swatch = struct {
    fn build(_: *Swatch, v: *view.View) anyerror!void {
        try v.column(.{ .width = 40, .height = 30, .background = 0x2050c0 });
        try v.end();
        _ = try v.button("Go", .{});
    }
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

fn runImage(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Swatch = .{};
    var storage: view.Storage(8, 64) = .{};
    var h = view.Harness.init(&state, Swatch.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 80 }, .options = .{ .background = 0xffffff } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Swatch.draw, Swatch.action);
    try h.attachInput(&context);
    const surface = try ui.offscreen.Surface.create(app, allocator, .{ .size = .{ .width = 200, .height = 160, .scale = 2 } });
    defer surface.close() catch unreachable;
    const snapshot = try h.image(surface);
    defer snapshot.close() catch unreachable;
    const shown = try snapshot.view();
    const level = shown.levels[0];
    try std.testing.expectEqual(@as(u32, 200), level.width);
    const pixelAt = struct {
        fn get(l: @TypeOf(level), x: usize, y: usize) u32 {
            const value = l.pixels[y * l.stride + x * 4 ..][0..4];
            return @as(u32, value[0]) | (@as(u32, value[1]) << 8) | (@as(u32, value[2]) << 16);
        }
    }.get;
    // BGRA: the panel inside its 40 x 30 DIP box, the background beside it.
    const panel = (try h.find(.{ .kind = .column, .nth = 1 })).bounds;
    try std.testing.expectEqual(@as(u32, 0x2050c0), pixelAt(level, @intFromFloat((panel.x + 10) * 2), @intFromFloat((panel.y + 10) * 2)));
    try std.testing.expectEqual(@as(u32, 0xffffff), pixelAt(level, 196, 156));

    // With the inspector open, its panel's toolbar takes the right of the
    // window and the content the rest; builds without it skip this.
    if (!view.inspector.enabled) return;
    var tools: view.Inspector = .{};
    var wide = view.Harness.init(&state, Swatch.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 600, .height = 300 }, .options = .{ .background = 0xffffff, .inspector = &tools } });
    var wide_context = ui.Context.init(&dummy, Swatch.draw, Swatch.action);
    try wide.attachInput(&wide_context);
    try std.testing.expect(try wide.key(.{ .key = .f12 }));
    try std.testing.expectEqual(@as(f32, 600 - view.inspector.default_width), wide.view.root().bounds.width);
    const panel_surface = try ui.offscreen.Surface.create(app, allocator, .{ .size = .{ .width = 600, .height = 300, .scale = 1 } });
    defer panel_surface.close() catch unreachable;
    const panel_image = try wide.image(panel_surface);
    defer panel_image.close() catch unreachable;
    const panel_level = (try panel_image.view()).levels[0];
    try std.testing.expectEqual(@as(u32, 0xf1f3f4), pixelAt(panel_level, 600 - 200, 2));
    try std.testing.expectEqual(@as(u32, 0xffffff), pixelAt(panel_level, 600 - 200, 290));
}

/// A menu that a native secondary press opens over its anchor, hovered
/// open to a submenu and chosen from with a native press.
const Menu = struct {
    chosen: usize = 0,
    level: usize = 0,
    fn build(self: *Menu, v: *view.View) anyerror!void {
        try v.column(.{ .height = 120, .self_align = .stretch, .padding = .all(8) });
        try v.text("Document", .{});
        try v.end();
        if (try v.popoverMenu(.{ .name = "Document" })) {
            if (try v.menuItem("Rename", .{ .shortcut = "F2" }, .{})) self.chosen += 1;
            try v.menuSeparator();
            if (try v.submenu("Zoom", .{})) {
                for ([_][]const u8{ "Small", "Large" }, 0..) |label, i| {
                    if (try v.menuItem(label, .{ .checked = self.level == i, .radio = true }, .{ .key = i })) self.level = i;
                }
            }
            try v.end();
        }
        try v.end();
    }
};

fn boundsOfText(host: *view.Host, kind: view.Kind, text: []const u8) ?view.Rect {
    for (host.view.nodes()) |*node| if (node.kind == kind and std.mem.eql(u8, node.text, text)) return node.bounds;
    return null;
}

fn runMenu(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Menu = .{};
    var storage: view.Storage(32, 512) = .{};
    var host = view.Host.init(&state, Menu.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    // Secondary presses travel the native press path on every platform.
    const window = try app.createWindow(.{ .width = width, .height = height, .native_pointer_clicks = true });
    try host.attach(window);
    try paint(&host, window);
    try std.testing.expect(boundsOfText(&host, .menu_item, "Rename") == null);
    const anchor = boundsOfText(&host, .text, "Document").?;
    Native.button(window, true, true, anchor.x + 2, anchor.y + 30);
    Native.button(window, false, true, anchor.x + 2, anchor.y + 30);
    try paint(&host, window);
    const rename = boundsOfText(&host, .menu_item, "Rename") orelse return error.MenuNotOpen;
    try std.testing.expect(rename.x >= anchor.x + 2 and rename.y >= anchor.y + 30);
    // The pointer over the submenu's item opens it beside the item.
    const zoom = boundsOfText(&host, .menu_item, "Zoom").?;
    Native.move(window, zoom.x + 10, zoom.y + zoom.height / 2);
    try paint(&host, window);
    const large = boundsOfText(&host, .menu_item, "Large") orelse return error.SubmenuNotOpen;
    try std.testing.expect(large.x >= zoom.x + zoom.width);
    Native.click(window, large);
    try paint(&host, window);
    try std.testing.expectEqual(@as(usize, 1), state.level);
    try std.testing.expect(boundsOfText(&host, .menu_item, "Rename") == null);
    // Opened again, a press outside closes it and chooses nothing.
    Native.button(window, true, true, anchor.x + 2, anchor.y + 30);
    Native.button(window, false, true, anchor.x + 2, anchor.y + 30);
    try paint(&host, window);
    try std.testing.expect(boundsOfText(&host, .menu_item, "Rename") != null);
    Native.click(window, .{ .x = 4, .y = height - 40, .width = 4, .height = 4 });
    try paint(&host, window);
    try std.testing.expect(boundsOfText(&host, .menu_item, "Rename") == null);
    try std.testing.expectEqual(@as(usize, 0), state.chosen);
    _ = try window.destroy();
    try app.dispatch();
}

/// The inspector in a window: open, the content narrower, and a click on
/// its close button closes it through the Host's routing.
fn runInspector(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Swatch = .{};
    var storage: view.Storage(8, 64) = .{};
    var tools: view.Inspector = .{};
    var host = view.Host.init(&state, Swatch.build, storage.buffers(), .{ .inspector = &tools });
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try paint(&host, window);
    try std.testing.expectEqual(@as(f32, width), host.view.root().bounds.width);
    tools.toggle();
    try paint(&host, window);
    try std.testing.expectEqual(@as(f32, width / 2), host.view.root().bounds.width);
    try std.testing.expect(tools.len == host.view.nodes().len);
    Native.click(window, tools.layout().close);
    try std.testing.expect(!tools.open);
    try paint(&host, window);
    try std.testing.expectEqual(@as(f32, width), host.view.root().bounds.width);
    _ = try window.destroy();
    try app.dispatch();
}

/// A video in a window: its first frame uploads in the task posted after
/// the first paint, and the next one when the host clock reaches it.
const Clip = struct {
    player: *video.Player = undefined,
    now: u64 = 0,
    at: u8 = 0,
    fn build(self: *Clip, v: *view.View) anyerror!void {
        try self.player.show(v, .{ .alt = "Clip" }, .{ .width = 60, .height = 40 });
    }
    fn time(ptr: ?*anyopaque) u64 {
        const self: *Clip = @ptrCast(@alignCast(ptr.?));
        return self.now;
    }
    fn decoder(self: *Clip) video.Decoder {
        return .{ .context = self, .width = 3, .height = 2, .next = next, .rewind = rewind };
    }
    fn next(ptr: *anyopaque, pixels: []u8) anyerror!?u64 {
        const self: *Clip = @ptrCast(@alignCast(ptr));
        if (self.at == 3) return null;
        @memset(pixels, 0x40 * (self.at + 1));
        self.at += 1;
        return 40 * std.time.ns_per_ms;
    }
    fn rewind(ptr: *anyopaque) anyerror!void {
        const self: *Clip = @ptrCast(@alignCast(ptr));
        self.at = 0;
    }
};

fn runVideo(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Clip = .{};
    var storage: view.Storage(8, 64) = .{};
    var host = view.Host.init(&state, Clip.build, storage.buffers(), .{ .clock = .{ .context = &state, .now = Clip.time } });
    host.context.render_mode = .gdi;
    var player = try video.Player.init(allocator, &host, state.decoder());
    state.player = &player;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    defer player.deinit();
    try paint(&host, window);
    try std.testing.expectEqual(view.Kind.svg, host.view.nodes()[1].kind);
    try app.dispatch();
    if (player.last_error) |err| return err;
    try std.testing.expect(player.image.view() != null);
    try paint(&host, window);
    try std.testing.expectEqual(view.Kind.image, host.view.nodes()[1].kind);
    const first = player.image.committed;
    state.now = 45 * std.time.ns_per_ms;
    try paint(&host, window);
    try app.dispatch();
    if (player.last_error) |err| return err;
    try std.testing.expectEqual(@as(u8, 2), state.at);
    try std.testing.expect(player.image.committed != first);
    try paint(&host, window);
}

/// A window zoomed twice: the view is laid out in half the window's DIPs,
/// and a native press lands on the button drawn twice as large.
const Zoomed = struct {
    clicks: usize = 0,
    fn build(self: *Zoomed, v: *view.View) anyerror!void {
        if (try v.button("Zoomed", .{})) self.clicks += 1;
    }
};

fn runZoom(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Zoomed = .{};
    var storage: view.Storage(8, 64) = .{};
    var host = view.Host.init(&state, Zoomed.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try paint(&host, window);
    const unzoomed = host.view.root().bounds.width;
    try window.setZoom(2);
    try paint(&host, window);
    try std.testing.expectApproxEqAbs(unzoomed / 2, host.view.root().bounds.width, 0.5);
    const button = boundsOfText(&host, .button, "Zoomed").?;
    const x = (button.x + button.width / 2) * 2;
    const y = (button.y + button.height / 2) * 2;
    Native.pointer(window, true, x, y);
    Native.pointer(window, false, x, y);
    try paint(&host, window);
    try std.testing.expectEqual(@as(usize, 1), state.clicks);
}

/// A label that counts frames over a still page: after the first frame the
/// software plane draws again only the label's rectangle.
const Counter = struct {
    count: usize = 0,
    label: [32]u8 = undefined,
    fn build(self: *Counter, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .gap = 8, .padding = .all(12) });
        try v.text("A page that stays the same", .{});
        _ = try v.button("Still", .{});
        try v.text(try std.fmt.bufPrint(&self.label, "Frame {d}", .{self.count}), .{});
        try v.end();
    }
};

fn runDamage(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) return;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Counter = .{};
    var storage: view.Storage(16, 128) = .{};
    var host = view.Host.init(&state, Counter.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try paint(&host, window);
    try paint(&host, window);
    try std.testing.expect(host.context.damageStats().last.isNone());
    state.count += 1;
    try paint(&host, window);
    const stats = host.context.damageStats();
    try std.testing.expect(stats.partial_frames >= 2);
    try std.testing.expect(!stats.last.full and stats.last.len >= 1);
    const size = try window.contentSize();
    try std.testing.expect(stats.last.pixels(size.width, size.height) * 4 < @as(u64, size.width) * size.height);
}

/// A card kept as one image beside a label that counts frames: the card
/// is drawn into its image once, and again only when its content changes,
/// while its button still takes presses.
const Kept = struct {
    cache: *ui.Cache,
    count: usize = 0,
    title: []const u8 = "Kept card",
    clicks: usize = 0,
    label: [32]u8 = undefined,
    fn build(self: *Kept, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .gap = 8, .padding = .all(12) });
        try v.column(.{ .gap = 6, .padding = .all(10), .background = 0x2050a0, .border = 0x102850, .radius = 8, .cache = self.cache });
        try v.text(self.title, .{ .color = 0xffffff });
        if (try v.button("Inside", .{})) self.clicks += 1;
        try v.end();
        try v.text(try std.fmt.bufPrint(&self.label, "Frame {d}", .{self.count}), .{});
        try v.end();
    }
};

fn runCache(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) return;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Kept = .{ .cache = try ui.Cache.create(app, allocator) };
    var storage: view.Storage(16, 128) = .{};
    var host = view.Host.init(&state, Kept.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    defer state.cache.destroy() catch unreachable;
    try paint(&host, window);
    try paint(&host, window);
    state.count += 1;
    try paint(&host, window);
    var stats = state.cache.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.renders);
    try std.testing.expectEqual(@as(u64, 2), stats.reuses);
    try std.testing.expect(stats.width > 0 and stats.height > 0);
    // The label changed, not the card: the frame drew the label alone.
    try std.testing.expect(!host.context.damageStats().last.full);
    state.title = "Changed card";
    try paint(&host, window);
    try paint(&host, window);
    stats = state.cache.stats();
    try std.testing.expectEqual(@as(u64, 2), stats.renders);
    try std.testing.expectEqual(@as(u64, 3), stats.reuses);
    const button = boundsOfText(&host, .button, "Inside").?;
    Native.pointer(window, true, button.x + button.width / 2, button.y + button.height / 2);
    Native.pointer(window, false, button.x + button.width / 2, button.y + button.height / 2);
    try paint(&host, window);
    try std.testing.expectEqual(@as(usize, 1), state.clicks);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    try runCollections(gpa.allocator());
    try runPictures(gpa.allocator());
    try runTimer(gpa.allocator());
    try runImage(gpa.allocator());
    try runMenu(gpa.allocator());
    try runVideo(gpa.allocator());
    try runDamage(gpa.allocator());
    try runCache(gpa.allocator());
    try runZoom(gpa.allocator());
    if (view.inspector.enabled) try runInspector(gpa.allocator());
    if (builtin.os.tag == .windows) {
        try @import("view_uia.zig").run(gpa.allocator());
        try @import("view_uia.zig").runCollections(gpa.allocator());
    }
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("view native: build, flex layout, immediate activation, bound values, radio group, stepper, wheel scrolling, grid, tabs, split drag, toolbar, segments, link, disclosure, rating, meter, combo box, navigation button, tree, sortable table, token removal, embedded leaf input, routed pages with history buttons, deferred icon and SVG preparation, timed toast expiry, context menu with submenu, video frames committed after paint, a zoomed window laid out and pressed in its own DIPs, a changed label redrawn alone, a card kept as one image, keyed identity and harness frames drawn to pixels and the inspector panel passed\n", .{});
}
