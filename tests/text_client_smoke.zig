const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const shaped = @import("ziggurat_shaped_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("imm.h");
}) else struct {};
extern fn zlg_test_surrounding(*anyopaque, [*]u8, usize, *usize, *usize) c_int;
extern fn zlg_test_delete_surrounding(*anyopaque, c_int, c_int) c_int;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_resource_count() u32;
extern fn gtk_widget_destroy(*anyopaque) void;
const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 300, .height = 150 };
const State = struct {
    window: z.Window = undefined,
    editor: ui.editor.Editor,
    adapter: shaped.Adapter = undefined,
    binding: ui.editor.TextBinding = undefined,
    parameters: shaped.Parameters = .{ .font = .{ .size = 18 } },
    failure: ?anyerror = null,
    updates: usize = 0,
    fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        _ = self.adapter.handleEvent(value, bounds) catch |err| {
            self.failure = err;
            return;
        };
        self.update() catch |err| {
            self.failure = err;
        };
    }
    fn detach(_: *anyopaque) void {}
    fn update(self: *State) !void {
        _ = try self.adapter.prepare(bounds, self.parameters);
        const caret = try self.adapter.caretRect(bounds, self.parameters.scale);
        try self.window.setTextCaret(.{ .x = caret.x, .y = caret.y, .width = caret.width, .height = caret.height });
        self.updates += 1;
    }
    fn changed(ptr: *anyopaque, _: z.Window) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        try self.update();
    }
    fn native(self: *State) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
};
fn check(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var state: State = .{ .editor = try ui.editor.Editor.init(allocator, .{ .multiline = true, .autofocus = true }, "a😀中bc") };
    defer state.editor.deinit();
    state.adapter = try shaped.Adapter.init(allocator, &state.editor, engine, .{});
    defer state.adapter.deinit() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    state.window = try app.createWindow(.{});
    defer _ = state.window.destroy() catch unreachable;
    try state.window.setContent(.{ .context = &state, .event = State.event, .detach = State.detach });
    state.binding = ui.editor.TextBinding.init(&state.editor, std.Thread.getCurrentId());
    state.binding.changed = .{ .context = &state, .call = State.changed };
    try state.binding.bind(state.window);
    defer state.binding.unbind() catch unreachable;
    _ = try state.editor.buffer.setSelection(.{ .anchor = 1, .caret = 8 });
    try state.update();
    const original_updates = state.updates;
    if (builtin.os.tag == .windows) {
        const hwnd = state.window.nativeHandle();
        const needed = c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0);
        try std.testing.expect(needed > 0);
        var bytes: [12352]u8 align(8) = undefined;
        const offer: *c.RECONVERTSTRING = @ptrCast(&bytes);
        offer.dwSize = bytes.len;
        try std.testing.expectEqual(needed, c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, @bitCast(@intFromPtr(offer))));
        try std.testing.expectEqual(@as(u32, 6), offer.dwStrLen);
        try std.testing.expectEqual(@as(u32, 2), offer.dwCompStrOffset);
        try std.testing.expectEqual(@as(u32, 3), offer.dwCompStrLen);
        offer.dwSize = bytes.len;
        _ = c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer)));
        offer.dwCompStrOffset = 6;
        offer.dwCompStrLen = 1;
        offer.dwTargetStrOffset = 6;
        offer.dwTargetStrLen = 1;
        try std.testing.expectEqual(@as(isize, 1), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
        try std.testing.expectEqual(ui.editor.Selection{ .anchor = 5, .caret = 8 }, state.editor.buffer.selection());
        try std.testing.expect(state.updates > original_updates);
        try std.testing.expectEqual(state.editor.displaySelection(), state.adapter.snapshot.?.geometry.source);
        _ = c.SendMessageW(hwnd, c.WM_UNICHAR, 0x6587, 0);
        try std.testing.expectEqualStrings("a😀文bc", state.editor.buffer.text());
        try std.testing.expect(try state.editor.buffer.undo());
        state.editor.refresh();
        try state.update();
        try std.testing.expectEqualStrings("a😀中bc", state.editor.buffer.text());
        offer.dwSize = bytes.len;
        _ = c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer)));
        const before = state.editor.buffer.selection();
        offer.dwCompStrOffset = 4;
        offer.dwCompStrLen = 1; // Splits the emoji surrogate.
        offer.dwTargetStrOffset = 4;
        offer.dwTargetStrLen = 1;
        try std.testing.expectEqual(@as(isize, 0), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
        try std.testing.expectEqual(before, state.editor.buffer.selection());
        offer.dwSize = bytes.len;
        _ = c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer)));
        _ = try state.editor.buffer.setSelection(.{ .anchor = 0, .caret = 0 });
        try std.testing.expectEqual(@as(isize, 0), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
        _ = c.SendMessageW(hwnd, c.WM_KILLFOCUS, 0, 0);
        try std.testing.expect(state.window.textClientToken() == null and state.binding.token == null);
        try state.binding.bind(state.window);
        try std.testing.expectEqual(@as(isize, 0), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
    } else {
        var storage: [12288]u8 = undefined;
        var length: usize = 0;
        var cursor: usize = 0;
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_surrounding(state.native(), &storage, storage.len, &length, &cursor));
        try std.testing.expectEqualStrings("a😀中bc", storage[0..length]);
        try std.testing.expectEqual(@as(usize, 8), cursor);
        const selection_before_zero = state.editor.buffer.selection();
        const revision_before_zero = state.editor.buffer.revision;
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_delete_surrounding(state.native(), 0, 0));
        try std.testing.expectEqual(selection_before_zero, state.editor.buffer.selection());
        try std.testing.expectEqual(revision_before_zero, state.editor.buffer.revision);
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_delete_surrounding(state.native(), -2, 2));
        try std.testing.expectEqualStrings("abc", state.editor.buffer.text());
        try std.testing.expect(state.updates > original_updates);
        try std.testing.expectEqual(state.editor.displaySelection(), state.adapter.snapshot.?.geometry.source);
        try std.testing.expect(try state.editor.buffer.undo());
        state.editor.refresh();
        try state.update();
        try std.testing.expectEqualStrings("a😀中bc", state.editor.buffer.text());
        try std.testing.expectEqual(@as(c_int, 0), zlg_test_delete_surrounding(state.native(), -100000, 1));
        try std.testing.expectEqualStrings("a😀中bc", state.editor.buffer.text());
        _ = try state.editor.buffer.setComposition("文", .{ .anchor = 3, .caret = 3 });
        state.editor.refresh();
        try std.testing.expectEqual(@as(c_int, 0), zlg_test_delete_surrounding(state.native(), -1, 1));
        try std.testing.expect(state.editor.buffer.composition() != null);
        _ = state.editor.buffer.cancelComposition();
        state.editor.refresh();
        zlg_test_commit(state.native(), "文");
        try std.testing.expectEqualStrings("a文bc", state.editor.buffer.text());
    }
    if (state.failure) |err| return err;
    // Enter the real native request, then destroy its window from the client
    // callback. Unbinding must wait until that callback has returned.
    const Closing = struct {
        in_read: bool = false,
        unbound_count: usize = 0,
        fn read(ptr: *anyopaque, window: z.Window, destination: []u8) !z.text.Snapshot {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.in_read = true;
            defer self.in_read = false;
            if (builtin.os.tag == .windows) {
                try std.testing.expect(c.DestroyWindow(window.nativeHandle()) != 0);
            } else gtk_widget_destroy(window.nativeHandle().?);
            destination[0] = 'x';
            try std.testing.expectEqual(@as(usize, 0), self.unbound_count);
            return .{ .range = .{ .start = 0, .end = 1 }, .selection = .{ .anchor = 1, .caret = 1 }, .revision = 1, .bytes = 1 };
        }
        fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
            return .applied;
        }
        fn unbound(ptr: *anyopaque, _: z.Window, reason: z.text.UnbindReason) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.testing.expect(!self.in_read and reason == .closed) catch unreachable;
            self.unbound_count += 1;
        }
    };
    var closing: Closing = .{};
    _ = try state.window.setTextClient(.{ .context = &closing, .owner = std.Thread.getCurrentId(), .read = Closing.read, .change = Closing.change, .unbound = Closing.unbound });
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(isize, 0), c.SendMessageW(state.window.nativeHandle(), c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0));
    } else {
        var storage: [32]u8 = undefined;
        var length: usize = 0;
        var cursor: usize = 0;
        try std.testing.expectEqual(@as(c_int, 0), zlg_test_surrounding(state.native(), &storage, storage.len, &length, &cursor));
    }
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), closing.unbound_count);
    try std.testing.expect(state.window.isClosed());
    try std.testing.expect(state.binding.token == null);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    try check(allocator.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("native text client passed: bounded committed context, UTF16 reconversion/scalar surrounding deletion, explicit preparation, stale/focus/close and undo\n", .{});
}
