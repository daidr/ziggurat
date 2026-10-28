const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = @import("ziggurat_c_win32");

const State = struct {
    editor: ui.editor.Editor,
    err: ?anyerror = null,
    detached: usize = 0,
    button_activations: usize = 0,
    fn measure(_: *anyopaque, text: []const u8) !f32 {
        return @as(f32, @floatFromInt(try std.unicode.utf8CountCodepoints(text))) * 10;
    }
    fn paint(_: *anyopaque, _: ui.editor.PaintCommand) !void {}
    fn surface(self: *State) ui.editor.Surface {
        return .{ .context = self, .line_height = 20, .measure = measure, .paint = paint };
    }
    fn event(ptr: *anyopaque, _: z.Window, ev: z.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const consumed = self.editor.handleEvent(ev, .{ .x = 0, .y = 0, .width = 300, .height = 200 }, self.surface()) catch |err| {
            self.err = err;
            return;
        };
        if (!consumed and ev == .key and ev.key == .activate) self.button_activations += 1;
    }
    fn detach(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.detached += 1;
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{ .editor = try ui.editor.Editor.init(allocator.allocator(), .{ .multiline = true, .autofocus = true }, "") };
    defer state.editor.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    try window.setContent(.{ .context = &state, .event = State.event, .detach = State.detach });
    const hwnd: c.HWND = @ptrCast(window.nativeHandle());

    // Exercise the registered native window procedure, not a direct editor call.
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xd83d, 0);
    try std.testing.expectEqualStrings("", state.editor.buffer.text());
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xde00, 0);
    _ = c.SendMessageW(hwnd, c.WM_UNICHAR, 0x4e2d, 0);
    try std.testing.expectEqualStrings("😀中", state.editor.buffer.text());
    try std.testing.expectEqual(@as(isize, 1), c.SendMessageW(hwnd, c.WM_UNICHAR, c.UNICODE_NOCHAR, 0));
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 1, 0);
    try std.testing.expectEqualStrings("😀中", state.editor.buffer.text());
    _ = c.SendMessageW(hwnd, c.WM_KEYDOWN, c.VK_SPACE, 0);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, ' ', 0);
    try std.testing.expectEqualStrings("😀中 ", state.editor.buffer.text());
    try std.testing.expectEqual(0, state.button_activations);
    _ = c.SendMessageW(hwnd, c.WM_KEYDOWN, c.VK_BACK, 0);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 8, 0);
    try std.testing.expectEqualStrings("😀中", state.editor.buffer.text());
    _ = c.SendMessageW(hwnd, c.WM_CHAR, '\r', 0);
    try std.testing.expectEqualStrings("😀中\n", state.editor.buffer.text());

    // Own an isolated input context; candidate geometry must not depend on an
    // installed language engine or change another window's active composition.
    const context = c.ImmCreateContext() orelse return error.InputContextUnavailable;
    const previous = c.ImmAssociateContext(hwnd, context);
    defer {
        _ = c.ImmAssociateContext(hwnd, previous);
        std.debug.assert(c.ImmDestroyContext(context) != 0);
    }
    try window.setTextCaret(.{ .x = 10, .y = 20, .width = 1, .height = 20 });
    var form = std.mem.zeroes(c.COMPOSITIONFORM);
    try std.testing.expect(c.ImmGetCompositionWindow(context, &form) != 0);
    const dpi = c.GetDpiForWindow(hwnd);
    try std.testing.expectEqual(c.MulDiv(10, @intCast(dpi), 96), form.ptCurrentPos.x);
    try std.testing.expectEqual(c.MulDiv(40, @intCast(dpi), 96), form.ptCurrentPos.y);

    // This verifies native cancellation routing. It does not impersonate typing
    // through a real IME language engine or verify its candidate UI visually.
    _ = try state.editor.buffer.setComposition("文", .{ .anchor = 3, .caret = 3 });
    state.editor.refresh();
    _ = c.SendMessageW(hwnd, c.WM_IME_STARTCOMPOSITION, 0, 0);
    _ = c.SendMessageW(hwnd, c.WM_IME_ENDCOMPOSITION, 0, 0);
    try std.testing.expect(state.editor.buffer.composition() == null);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xd83d, 0);
    _ = c.SendMessageW(hwnd, c.WM_KILLFOCUS, 0, 0);
    _ = c.SendMessageW(hwnd, c.WM_SETFOCUS, 0, 0);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 'X', 0);
    try std.testing.expectEqualStrings("😀中\nX", state.editor.buffer.text());
    try std.testing.expect(state.err == null);
    _ = try window.destroy();
    try std.testing.expectEqual(1, state.detached);
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
    std.debug.print("editor native smoke passed: WM_CHAR surrogate/WM_UNICHAR, controls, focus and preedit cancellation, IMM candidate geometry; real IME typing and visual quality not verified\n", .{});
}
