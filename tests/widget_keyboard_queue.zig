const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const shared = @import("widget_ranges_shared.zig");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @import("ziggurat_c_win32");
const checkpoint_message = c.WM_APP + 91;
const Queue = struct {
    state: *shared.State,
    stage: u32 = 0,
    err: ?anyerror = null,
    fn message(ptr: *anyopaque, window: z.Window, kind: u32, _: usize, _: isize) ?isize {
        if (kind != checkpoint_message) return null;
        const self: *Queue = @ptrCast(@alignCast(ptr));
        self.advance(window) catch |err| {
            self.err = err;
            window.app.quit();
        };
        return 0;
    }
    fn detach(_: *anyopaque) void {}
    fn advance(self: *Queue, window: z.Window) !void {
        const state = self.state;
        if (self.stage == 0) {
            try std.testing.expectEqual(@as(usize, 1), state.actions[31]);
            try std.testing.expectEqual(@as(usize, 0), state.text_events);
            try std.testing.expectEqualStrings("AB", state.editor.buffer.text());
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            const x: c.LPARAM = @intFromFloat(10 * scale);
            const y: c.LPARAM = @intFromFloat(250 * scale);
            _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, 0, x | (y << 16));
            _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, x | (y << 16));
            _ = try state.editor.buffer.selectAll();
            try postKey(window, c.VK_SPACE);
            try postKey(window, c.VK_RETURN);
            try postKey(window, 'A');
            try postKey(window, c.VK_F3);
            self.stage = 1;
            if (c.PostMessageW(hwnd, checkpoint_message, 0, 0) == 0) return error.PostFailed;
        } else if (self.stage == 1) {
            // TranslateMessage posts CHAR behind previously posted messages.
            // This queue marker observes it without a nested message pump.
            self.stage = 2;
            if (c.PostMessageW(window.nativeHandle(), checkpoint_message, 0, 0) == 0) return error.PostFailed;
        } else {
            // A consumed bare shortcut generated no CHAR; Space inserted once;
            // Enter was consumed by a single-line editor; ordinary text still
            // passed TranslateMessage and the text adapter exactly once.
            try std.testing.expectEqualStrings(" a", state.editor.buffer.text());
            try std.testing.expectEqual(@as(usize, 1), state.text_events);
            try std.testing.expectEqual(@as(usize, 1), state.actions[35]);
            try std.testing.expectEqual(@as(usize, 0), state.actions[30]);
            self.stage = 3;
            window.app.quit();
        }
    }
};
fn postKey(window: z.Window, code: c.WPARAM) !void {
    const hwnd: c.HWND = window.nativeHandle();
    if (c.PostMessageW(hwnd, c.WM_KEYDOWN, code, 1) == 0 or c.PostMessageW(hwnd, c.WM_KEYUP, code, 1 | @as(c.LPARAM, 1) << 31) == 0) return error.PostFailed;
}
pub fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: shared.State = .{ .editor = try ui.editor.Editor.init(allocator, .{}, "AB") };
    defer state.editor.deinit();
    try state.attach(app);
    var queue: Queue = .{ .state = &state };
    try state.window.setService(.{ .context = &queue, .message = Queue.message, .native_destroying = Queue.detach });
    var previous: [256]u8 = undefined;
    if (c.GetKeyboardState(&previous) == 0) return error.KeyboardStateUnavailable;
    defer _ = c.SetKeyboardState(&previous);
    var clean: [256]u8 = @splat(0);
    if (c.SetKeyboardState(&clean) == 0) return error.KeyboardStateUnavailable;
    _ = c.InvalidateRect(state.window.nativeHandle(), null, 0);
    _ = c.SendMessageW(state.window.nativeHandle(), c.WM_PAINT, 0, 0);
    try postKey(state.window, 'Q');
    if (c.PostMessageW(state.window.nativeHandle(), checkpoint_message, 0, 0) == 0) return error.PostFailed;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (queue.err) |err| return err;
    if (state.err) |err| return err;
    try std.testing.expectEqual(@as(u32, 3), queue.stage);
    try std.testing.expectEqual(@as(usize, 1), state.closed);
    std.debug.print("queued keyboard smoke passed: pre-translation shortcut suppression, one editor Space, single-line Enter, normal CHAR and F3\n", .{});
}
