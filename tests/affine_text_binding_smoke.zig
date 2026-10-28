const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const shaped = @import("ziggurat_shaped_editor");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_test_surrounding(*anyopaque, [*]u8, usize, *usize, *usize) c_int;
extern fn zlg_test_delete_surrounding(*anyopaque, c_int, c_int) c_int;
extern fn zlg_resource_count() u32;

const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 180, .height = 80 };
const extent: ui.layout.Size = .{ .width = 200, .height = 100 };
const original = "pre😀post";
const State = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    editor: ui.editor.Editor,
    adapter: shaped.Adapter = undefined,
    binding: ui.editor.TextBinding = undefined,
    parameters: shaped.Parameters = .{ .font = .{ .size = 18 } },
    frame: ?*ui.Frame = null,
    matrix: ui.affine.Affine = .{ .xx = 0.8, .yx = 0.3, .xy = -0.2, .yy = 0.9, .x0 = 64, .y0 = 18 },
    omit: bool = false,
    plain: bool = false,
    fail_frame: bool = false,
    sync_committed: bool = false,
    clear_in_changed: bool = false,
    failure: ?anyerror = null,
    paint_error: ?anyerror = null,
    changed_count: usize = 0,
    committed_count: usize = 0,
    fn action(_: *anyopaque, _: u64) void {}
    fn query(_: *anyopaque, _: z.Window, _: usize, _: isize) ?isize {
        return null;
    }
    fn phase(ptr: *anyopaque, _: z.Window, value: ui.AccessibilityPhase) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .committed) return;
        self.committed_count += 1;
        if (self.sync_committed and !self.omit and !self.plain) self.syncCaret() catch |err| {
            self.failure = err;
        };
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.operation == .paint) self.paint_error = value.err;
    }
    fn surface(ptr: *anyopaque, command: shaped.PaintCommand) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const frame = self.frame.?;
        switch (command) {
            .text => |text| try frame.preparedText(text.origin, try text.prepared.view(), ui.Color.rgb(0x202020)),
            .selection => |rect| frame.rect(rect, 0xc7ddff),
            .composition => |rect| frame.rect(rect, 0x385ca8),
            .caret => |rect| frame.rect(rect, 0x202020),
        }
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        if (self.plain) return;
        try frame.beginTransform(extent, self.matrix);
        if (!self.omit) try frame.captureSpace(70, bounds);
        try frame.pushClip(bounds);
        self.frame = frame;
        defer self.frame = null;
        try self.adapter.draw(bounds, self.parameters.scale, .{ .context = self, .paint = surface });
        try frame.popClip();
        try frame.endTransform();
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn changed(ptr: *anyopaque, _: z.Window) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.changed_count += 1;
        if (self.clear_in_changed) {
            try self.binding.clearCommittedSpace();
            return;
        }
        _ = try self.adapter.prepare(bounds, self.parameters);
        try self.syncCaret();
    }
    fn syncCaret(self: *State) !void {
        try self.binding.setTextCaret(try self.adapter.caretRect(bounds, self.parameters.scale));
    }
    fn native(self: *State) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn paint(self: *State) !void {
        self.paint_error = null;
        if (builtin.os.tag == .windows) {
            _ = c.InvalidateRect(self.window.nativeHandle(), null, 0);
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        } else {
            const size = try self.window.contentSize();
            const scale: u32 = @intFromFloat(size.scale);
            zlg_test_paint(self.native(), size.width / scale, size.height / scale);
        }
        if (self.failure) |err| return err;
        if (!self.fail_frame) if (self.paint_error) |err| return err;
    }
    fn contextRead(self: *State) !void {
        var storage: [128]u8 = undefined;
        const result = try self.window.readTextClient(self.binding.token.?, &storage);
        try std.testing.expectEqualStrings(self.editor.buffer.text(), storage[0..result.bytes]);
        const selection = self.editor.buffer.selection();
        try std.testing.expectEqual(z.text.Selection{ .anchor = try self.editor.buffer.utf16Offset(selection.anchor), .caret = try self.editor.buffer.utf16Offset(selection.caret) }, result.selection);
        if (builtin.os.tag == .windows) {
            try std.testing.expect(c.SendMessageW(self.window.nativeHandle(), c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0) > 0);
        } else {
            var length: usize = 0;
            var cursor: usize = 0;
            try std.testing.expect(zlg_test_surrounding(self.native(), &storage, storage.len, &length, &cursor) != 0);
            try std.testing.expectEqualStrings(self.editor.buffer.text(), storage[0..length]);
        }
    }
    fn rejected(self: *State, expected: anyerror) !void {
        const before = self.editor.buffer.revision;
        const selected = self.editor.buffer.selection();
        var storage: [128]u8 = @splat(0x5a);
        try std.testing.expectError(expected, self.window.readTextClient(self.binding.token.?, &storage));
        try std.testing.expect(std.mem.allEqual(u8, &storage, 0x5a));
        try std.testing.expectError(expected, self.window.changeTextClient(self.binding.token.?, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "X" } }));
        try std.testing.expectError(expected, self.binding.setTextCaret(.{ .x = 8, .y = 8, .width = 1, .height = 18 }));
        try std.testing.expectEqual(before, self.editor.buffer.revision);
        try std.testing.expectEqualDeep(selected, self.editor.buffer.selection());
        if (builtin.os.tag == .windows) {
            try std.testing.expectEqual(@as(isize, 0), c.SendMessageW(self.window.nativeHandle(), c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0));
        } else {
            var length: usize = 0;
            var cursor: usize = 0;
            try std.testing.expectEqual(@as(c_int, 0), zlg_test_surrounding(self.native(), &storage, storage.len, &length, &cursor));
            try std.testing.expectEqual(@as(c_int, 0), zlg_test_delete_surrounding(self.native(), -1, 1));
            try std.testing.expectEqual(before, self.editor.buffer.revision);
        }
    }
    fn nativeChange(self: *State) !void {
        if (builtin.os.tag == .windows) {
            var storage: [1024]u8 align(4) = @splat(0);
            const offer: *c.RECONVERTSTRING = @ptrCast(@alignCast(&storage));
            offer.dwSize = storage.len;
            try std.testing.expect(c.SendMessageW(self.window.nativeHandle(), c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer))) > 0);
            offer.dwCompStrOffset = 0;
            offer.dwCompStrLen = 3;
            offer.dwTargetStrOffset = 0;
            offer.dwTargetStrLen = 3;
            try std.testing.expectEqual(@as(isize, 1), c.SendMessageW(self.window.nativeHandle(), c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
            try std.testing.expectEqualDeep(ui.editor.Selection{ .anchor = 0, .caret = 3 }, self.editor.buffer.selection());
            _ = try self.editor.buffer.setSelection(.{ .anchor = 7, .caret = 3 });
        } else {
            try std.testing.expectEqual(@as(c_int, 1), zlg_test_delete_surrounding(self.native(), -1, 1));
            try std.testing.expectEqualStrings("pr😀post", self.editor.buffer.text());
            try std.testing.expect(try self.editor.buffer.undo());
            try std.testing.expectEqualStrings(original, self.editor.buffer.text());
            try std.testing.expectEqualDeep(ui.editor.Selection{ .anchor = 7, .caret = 3 }, self.editor.buffer.selection());
        }
        self.editor.refresh();
        _ = try self.adapter.prepare(bounds, self.parameters);
    }
    fn caretOracle(self: *State) !void {
        const caret = try self.adapter.caretRect(bounds, self.parameters.scale);
        const token = try self.context.committedSpace(70);
        _ = try token.windowBounds(caret);
        if (builtin.os.tag == .windows) {
            const hwnd = self.window.nativeHandle();
            const im = c.ImmCreateContext() orelse return error.InputContextUnavailable;
            const previous = c.ImmAssociateContext(hwnd, im);
            defer {
                _ = c.ImmAssociateContext(hwnd, previous);
                std.debug.assert(c.ImmDestroyContext(im) != 0);
            }
            try self.binding.setTextCaret(caret);
            const expected = try token.windowBounds(caret);
            var actual = std.mem.zeroes(c.COMPOSITIONFORM);
            try std.testing.expect(c.ImmGetCompositionWindow(im, &actual) != 0);
            const scale = self.parameters.scale;
            try std.testing.expectEqual(@as(c.LONG, @intFromFloat(expected.x * scale)), actual.ptCurrentPos.x);
            try std.testing.expectEqual(@as(c.LONG, @intFromFloat(expected.y * scale)) + @as(c.LONG, @intFromFloat(expected.height * scale)), actual.ptCurrentPos.y);
        } else try self.binding.setTextCaret(caret);
    }
};

fn run(allocator: std.mem.Allocator) !void {
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var fault = std.testing.FailingAllocator.init(allocator, .{});
    var state: State = .{ .editor = try ui.editor.Editor.init(fault.allocator(), .{ .autofocus = true }, original) };
    defer state.editor.deinit();
    state.adapter = try shaped.Adapter.init(fault.allocator(), &state.editor, engine, .{});
    defer state.adapter.deinit() catch unreachable;
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 320, .height = 220 });
    defer {
        _ = state.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    state.parameters.scale = (try state.window.contentSize()).scale;
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    const options: ui.layers.TransformOptions = .{ .layers = .{ .size = try state.window.contentSize(), .max_depth = 4 }, .source_size = extent };
    try state.context.prepareTransforms(allocator, options);
    const phase = try state.context.installAccessibilitySource(.{ .context = &state, .query = State.query, .phase = State.phase });
    defer if (state.context.window != null) {
        _ = state.context.clearAccessibilitySource(phase) catch unreachable;
    };
    state.binding = ui.editor.TextBinding.init(&state.editor, std.Thread.getCurrentId());
    state.binding.changed = .{ .context = &state, .call = State.changed };
    try state.binding.bind(state.window);
    defer state.binding.unbind() catch unreachable;
    _ = try state.editor.buffer.setSelection(.{ .anchor = 7, .caret = 3 });
    state.editor.refresh();
    _ = try state.adapter.prepare(bounds, state.parameters);
    try state.contextRead(); // unconfigured default path remains available
    try state.paint();
    const first = try state.context.committedSpace(70);
    try state.binding.setCommittedSpace(first);
    state.sync_committed = true;
    try std.testing.expect(try state.binding.hasCommittedSpace());
    try state.contextRead();
    try state.caretOracle();
    try state.nativeChange();
    const calls = state.changed_count;
    try std.testing.expectEqual(z.text.ChangeResult.applied, try state.window.changeTextClient(state.binding.token.?, .{ .replace = .{ .range = .{ .start = 3, .end = 5 }, .text = "中" } }));
    try std.testing.expectEqualStrings("pre中post", state.editor.buffer.text());
    try std.testing.expectEqual(calls + 1, state.changed_count);
    try std.testing.expect(try state.editor.buffer.undo());
    try std.testing.expectEqualDeep(ui.editor.Selection{ .anchor = 7, .caret = 3 }, state.editor.buffer.selection());
    state.editor.refresh();
    _ = try state.adapter.prepare(bounds, state.parameters);
    try state.paint();
    // Failed front cannot retire the last successful coordinate authority.
    const committed = state.committed_count;
    state.matrix.x0 += 19;
    state.omit = true;
    state.fail_frame = true;
    try state.paint();
    try std.testing.expectEqual(committed, state.committed_count);
    try state.contextRead();
    try state.caretOracle();
    state.fail_frame = false;
    try state.paint();
    try state.rejected(error.SpaceNotFound);
    state.omit = false;
    try state.paint(); // stable ID follows this successful front again
    try state.contextRead();
    try state.caretOracle();
    // Both explicit revocation and release/recreate block body mutation.
    try state.binding.clearCommittedSpace();
    try std.testing.expect(!try state.binding.hasCommittedSpace());
    try state.rejected(error.StaleSpace);
    try state.binding.setCommittedSpace(try state.context.committedSpace(70));
    state.plain = true;
    try state.paint();
    try state.context.releaseTransforms();
    try state.context.prepareTransforms(allocator, options);
    state.plain = false;
    state.sync_committed = false;
    try state.paint();
    try state.rejected(error.StaleSpace);
    try std.testing.expectError(error.StaleSpace, state.binding.setCommittedSpace(first));
    try state.binding.setCommittedSpace(try state.context.committedSpace(70));
    try state.contextRead();
    // Reads and the preallocated business edit allocate no binding storage.
    state.binding.changed = null;
    fault.fail_index = fault.alloc_index;
    var storage: [128]u8 = undefined;
    _ = try state.window.readTextClient(state.binding.token.?, &storage);
    try std.testing.expectEqual(z.text.ChangeResult.applied, try state.window.changeTextClient(state.binding.token.?, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "P" } }));
    fault.fail_index = std.math.maxInt(usize);
    try std.testing.expect(try state.editor.buffer.undo());
    try std.testing.expectEqualStrings(original, state.editor.buffer.text());
    state.editor.refresh();
    _ = try state.adapter.prepare(bounds, state.parameters);
    state.binding.changed = .{ .context = &state, .call = State.changed };
    state.clear_in_changed = true;
    try std.testing.expectEqual(z.text.ChangeResult.applied, try state.window.changeTextClient(state.binding.token.?, .{ .select = .{ .anchor = 6, .caret = 3 } }));
    try std.testing.expectEqualDeep(ui.editor.Selection{ .anchor = 8, .caret = 3 }, state.editor.buffer.selection());
    try state.rejected(error.StaleSpace);
    try state.binding.setCommittedSpace(try state.context.committedSpace(70));
    state.clear_in_changed = false;
    _ = try state.editor.buffer.setComposition("文", .{ .anchor = 3, .caret = 3 });
    const scope = state.window.beginCallback().?;
    try std.testing.expectEqual(z.CloseResult.deferred, try state.window.destroy());
    try std.testing.expectError(error.UnbindPending, state.binding.unbind());
    try std.testing.expect(state.binding.token != null and try state.binding.hasCommittedSpace());
    scope.end();
    try app.dispatch();
    try std.testing.expect(state.binding.token == null and !try state.binding.hasCommittedSpace() and state.editor.buffer.composition() == null);
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const before = t.resourceCounts();
    try run(allocator);
    try std.testing.expectEqual(before, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("affine retained TextBinding: sole buffer/directed UTF16 selection, native contexts, success/failed fronts, revoked/recreated spaces, mapped caret, no binding allocation and deferred unbound resources=0\n", .{});
}
