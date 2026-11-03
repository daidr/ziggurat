//! A complete list of 257 rows as VoiceOver reads it through
//! NSAccessibility: every row, in view or not, with its label, index and
//! choice; choosing an offscreen row reaches the list and shows once the
//! next frame publishes it; scrolling a row into view gives it a frame in
//! the window without moving the focus; rows of a replaced model stand for
//! nothing while the new ones read on.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const virtual = @import("ziggurat_virtual_list");

extern fn zlm_test_paint(*anyopaque) void;
extern fn zua_test_element(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn zua_test_row(element: *anyopaque, row: c_int) c_int;
extern fn zua_test_list_row(list: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn zua_test_release(?*anyopaque) void;
extern fn zua_test_row_state(row: *anyopaque, handle: *anyopaque, selected: *c_int, shown: *c_int, focused: *c_int) c_int;
extern fn zua_test_row_act(row: *anyopaque, kind: c_int) void;
extern fn zua_test_list_count(list: *anyopaque, which: c_int) c_int;
extern fn zlm_test_make_key(*anyopaque) c_int;

const viewport: ui.Rect = .{ .x = 10, .y = 10, .width = 180, .height = 60 };
const RowState = struct { index: c_int, selected: bool, shown: bool, focused: bool };

const Host = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    control: *virtual.Control = undefined,
    rows: [257]virtual.Row = undefined,
    labels: [257]virtual.Control.Label = undefined,
    text: [257][16]u8 = undefined,
    changes: usize = 0,
    last_handle: ?*anyopaque = null,
    failure: ?anyerror = null,

    fn action(_: *anyopaque, _: u64) void {}
    fn changed(ptr: ?*anyopaque, _: z.Window, _: *virtual.Control, _: virtual.Control.Change) void {
        const self: *Host = @ptrCast(@alignCast(ptr.?));
        self.changes += 1;
    }
    fn row(_: *anyopaque, frame: *ui.Frame, value: virtual.Control.RowView) !void {
        frame.rect(value.row.visible_bounds, if (value.selected) 0x3399cc else 0x226644);
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        _ = self.control.draw(frame, viewport, "Complete list", .{ .context = self, .draw = row }, .{}) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }
    /// The window's NSWindow, or the last one it had once it closed: a row
    /// that stands for nothing answers before its window is asked about.
    fn handle(self: *Host) *anyopaque {
        if (self.window.nativeHandle()) |native| self.last_handle = native;
        return self.last_handle.?;
    }
    /// Draws a frame, which publishes the tree and the list's model.
    fn paint(self: *Host) !void {
        self.window.invalidate();
        zlm_test_paint(self.window.app.windows.get(self.window.key).?.native.native.?);
        if (self.failure) |err| return err;
    }
    fn catalog(self: *Host) !void {
        const input = try self.control.snapshotCatalog(self.window.app.allocator, &self.labels, .{});
        defer input.close();
        const prepared = try virtual.Control.NativeCatalog.prepare(input, 1024 * 1024);
        errdefer prepared.close();
        try self.control.installCatalog(prepared);
    }
    fn list(self: *Host) !*anyopaque {
        return zua_test_element(self.handle(), "Complete list") orelse error.MissingList;
    }
    fn find(self: *Host, name: [*:0]const u8) !*anyopaque {
        return zua_test_list_row(try self.list(), name) orelse {
            std.debug.print("no row named {s}\n", .{name});
            return error.MissingRow;
        };
    }
    fn state(self: *Host, element: *anyopaque) !RowState {
        var selected: c_int = 0;
        var shown: c_int = 0;
        var focused: c_int = 0;
        const index = zua_test_row_state(element, self.handle(), &selected, &shown, &focused);
        if (index < 0) return error.StaleRow;
        return .{ .index = index, .selected = selected != 0, .shown = shown != 0, .focused = focused != 0 };
    }
};

pub fn main() !void {
    if (comptime !ui.capabilities.accessibility) {
        std.debug.print("macOS complete list: this build leaves accessibility out; skipped\n", .{});
        return;
    }
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var host: Host = .{};
    for (&host.rows, &host.labels, &host.text, 0..) |*value, *label, *text, index| {
        value.* = .{ .id = index + 1, .height = 10 };
        label.* = .{ .id = index + 1, .text = try std.fmt.bufPrint(text, "row {d}", .{index + 1}) };
    }
    const app = try z.App.init(allocator);
    defer app.deinit();
    host.window = try app.createWindow(.{ .title = "Complete list", .width = 220, .height = 110 });
    host.window.show();
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    try host.context.attach(host.window);
    try host.context.prepareRecipients(allocator, .{ .recipients = 4 });
    try host.context.prepareVirtualLists(.{ .lists = 1, .model_bytes = 1024 * 1024 });
    host.control = try virtual.Control.create(allocator, std.Thread.getCurrentId(), &host.rows, .{ .native_semantics = true, .context = &host, .changed = Host.changed });
    defer host.control.close() catch unreachable;
    try host.control.attach(&host.context, 7);
    try host.catalog();
    try host.paint();

    // Every row, built or not, with how many the list has and which show.
    const list = try host.list();
    try std.testing.expectEqual(@as(c_int, 257), zua_test_row(list, 0));
    try std.testing.expectEqual(@as(c_int, 257), zua_test_list_count(list, 2));
    try std.testing.expectEqual(@as(c_int, 6), zua_test_list_count(list, 1));
    try std.testing.expectEqual(@as(c_int, 0), zua_test_list_count(list, 0));
    const first = try host.find("row 1");
    defer zua_test_release(first);
    try std.testing.expectEqual(RowState{ .index = 0, .selected = false, .shown = true, .focused = false }, try host.state(first));
    const old = try host.find("row 257");
    defer zua_test_release(old);
    try std.testing.expectEqual(RowState{ .index = 256, .selected = false, .shown = false, .focused = false }, try host.state(old));

    // Choosing the offscreen row reaches the list at once; assistive
    // technology reads it chosen once a frame publishes it.
    zua_test_row_act(old, 1);
    try std.testing.expect(try host.control.selected(257));
    try std.testing.expectEqual(@as(usize, 1), try host.control.selectedCount());
    try std.testing.expectEqual(@as(c_int, 0), zua_test_list_count(list, 0));
    try host.paint();
    try std.testing.expectEqual(@as(c_int, 1), zua_test_list_count(list, 0));
    try std.testing.expect((try host.state(old)).selected);

    // Scrolling it into view gives it a frame in the window; the focus
    // stays where it was.
    zua_test_row_act(old, 2);
    try std.testing.expect((try host.control.scrollOffset(viewport.height)) > 0);
    try host.paint();
    const revealed = try host.state(old);
    try std.testing.expect(revealed.shown and revealed.selected);
    try std.testing.expect(host.context.input_state.focused == null);
    try std.testing.expect(!(try host.state(first)).shown);

    // A replaced model: the old row of the same ID stands for nothing, the
    // new one reads on, unchosen.
    const before = try host.control.rowToken(257);
    _ = try host.control.replace(host.rows[0..256], viewport.height);
    _ = try host.control.replace(&host.rows, viewport.height);
    try std.testing.expect(before.incarnation != (try host.control.rowToken(257)).incarnation);
    try host.catalog();
    try host.paint();
    try std.testing.expectError(error.StaleRow, host.state(old));
    const new = try host.find("row 257");
    defer zua_test_release(new);
    try std.testing.expectEqual(@as(c_int, 256), (try host.state(new)).index);
    try std.testing.expect(!(try host.state(new)).selected);
    try std.testing.expectEqual(@as(c_int, 257), zua_test_row(list, 0));
    // A row of the old model chooses nothing.
    zua_test_row_act(old, 1);
    try std.testing.expectEqual(@as(usize, 0), try host.control.selectedCount());
    // Focusing a row of the new one gives the list the focus at that row;
    // assistive technology reads a focus only in the key window.
    if (zlm_test_make_key(host.window.app.windows.get(host.window.key).?.native.native.?) == 0) return error.WindowNotKey;
    zua_test_row_act(new, 3);
    try host.paint();
    try std.testing.expect(host.context.input_state.focused == 7);
    try std.testing.expect((try host.state(new)).focused);

    _ = try host.window.destroy();
    try app.dispatch();
    // Rows asked for after the window closed stand for nothing.
    try std.testing.expectError(error.StaleRow, host.state(new));
    const counts = ui.accessibility.resourceCounts();
    std.debug.print("macOS complete list: 257 rows by range, offscreen choice published after the next frame, reveal without focus, old incarnation refused, row focus; changes={d} actions={d}\n", .{ host.changes, counts.actions });
    try std.testing.expectEqual(@as(u32, 0), counts.actions);
}
