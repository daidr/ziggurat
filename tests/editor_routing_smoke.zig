const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = @import("ziggurat_c_win32");
const bounds = [_]ui.Rect{
    .{ .x = 0, .y = 0, .width = 100, .height = 40 },
    .{ .x = 120, .y = 0, .width = 100, .height = 40 },
};
const State = struct {
    editors: [2]*ui.editor.Editor,
    frame: ?*ui.Frame = null,
    clicks: usize = 0,
    err: ?anyerror = null,
    fn measure(_: *anyopaque, text: []const u8) !f32 {
        return @as(f32, @floatFromInt(try std.unicode.utf8CountCodepoints(text))) * 10;
    }
    fn paint(ptr: *anyopaque, command: ui.editor.PaintCommand) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const frame = self.frame orelse return error.NoFrame;
        switch (command) {
            .text => |text| frame.label(text.bounds, text.text, 0x182430),
            .selection => |rect| frame.rect(rect, 0xccccff),
            .composition, .caret => |rect| frame.rect(rect, 0x000000),
        }
    }
    fn surface(self: *State) ui.editor.Surface {
        return .{ .context = self, .line_height = 20, .measure = measure, .paint = paint };
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        var consumed = false;
        // Every editor sees outside presses so an earlier focused editor blurs
        // even when the new target occurs earlier in the routing order.
        for (self.editors, bounds) |editor, rect| {
            const handled = editor.handleEvent(event, rect, self.surface()) catch |err| {
                self.err = err;
                return true;
            };
            consumed = handled or consumed;
        }
        return consumed;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.frame = frame;
        defer self.frame = null;
        frame.clear(0xffffff);
        for (self.editors, bounds) |editor, rect| editor.draw(rect, self.surface()) catch |err| {
            self.err = err;
        };
        frame.button(1, .{ .x = 240, .y = 0, .width = 100, .height = 40 }, "Apply") catch |err| {
            self.err = err;
        };
    }
    fn action(ptr: *anyopaque, _: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.clicks += 1;
    }
};
fn click(hwnd: c.HWND, x: c_int) void {
    const dpi: c_int = @intCast(c.GetDpiForWindow(hwnd));
    const point: c.LPARAM = (@as(c.LPARAM, c.MulDiv(10, dpi, 96)) << 16) | @as(c.LPARAM, c.MulDiv(x, dpi, 96));
    _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, 0, point);
    _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, point);
}
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    var first = try ui.editor.Editor.init(allocator.allocator(), .{ .autofocus = true }, "");
    defer first.deinit();
    var second = try ui.editor.Editor.init(allocator.allocator(), .{}, "");
    defer second.deinit();
    var state: State = .{ .editors = .{ &first, &second } };
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var context = ui.Context.init(&state, State.draw, State.action);
    context.render_mode = .gdi;
    context.on_input = State.input;
    const window = try app.createWindow(.{ .width = 400, .height = 100 });
    try context.attach(window);
    const hwnd: c.HWND = window.nativeHandle();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    click(hwnd, 250);
    try std.testing.expectEqual(1, state.clicks);
    try std.testing.expect(!first.focused and !second.focused);
    click(hwnd, 10);
    try std.testing.expect(first.focused and !second.focused);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 'A', 0);
    click(hwnd, 130);
    try std.testing.expect(!first.focused and second.focused);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 'B', 0);
    click(hwnd, 10);
    try std.testing.expect(first.focused and !second.focused);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 'C', 0);
    try std.testing.expectEqualStrings("AC", first.buffer.text());
    try std.testing.expectEqualStrings("B", second.buffer.text());
    click(hwnd, 250);
    try std.testing.expectEqual(2, state.clicks);
    try std.testing.expect(!first.focused and !second.focused);
    try std.testing.expect(state.err == null);
    _ = try window.destroy();
    std.debug.print("editor routing smoke passed: focused editor to button activates on first click, both editor focus directions and native text routing\n", .{});
}
