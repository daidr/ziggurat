const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const shaped = @import("ziggurat_shaped_editor");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("imm.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_resource_count() u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
extern fn g_setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 280, .height = 120 };
const State = struct {
    window: z.Window = undefined,
    editor: ui.editor.Editor,
    adapter: shaped.Adapter = undefined,
    context: ui.Context = undefined,
    options: shaped.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character } },
    viewport: ui.Rect = bounds,
    frame: ?*ui.Frame = null,
    err: ?anyerror = null,
    draw_count: usize = 0,
    text_commands: usize = 0,
    failure: bool = false,
    close_in_draw: bool = false,
    transaction_checked: bool = false,
    expected_diagnostic: ?anyerror = null,
    diagnostic_count: usize = 0,
    resize_prepares: usize = 0,
    finish_on_resize: bool = false,
    finish_queued: bool = false,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        // Compare unwrapped error payloads; see docs/toolchain-known-issues.md.
        const matches = if (value.err) |actual| if (self.expected_diagnostic) |wanted| actual == wanted else false else false;
        if (matches) self.diagnostic_count += 1 else self.err = value.err orelse error.UnexpectedDiagnostic;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.draw_count += 1;
        self.frame = frame;
        defer self.frame = null;
        self.drawChecked(frame) catch |err| {
            self.err = err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        try frame.pushClip(self.viewport);
        try self.adapter.draw(self.viewport, self.options.scale, .{ .context = self, .paint = paintCommand });
        try frame.popClip();
        // The adapter's draw has returned, while the Frame still owns its pin.
        try std.testing.expectError(error.ResourceInUse, self.adapter.prepare(self.viewport, self.options));
        self.transaction_checked = true;
        if (self.failure) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
        if (self.close_in_draw) {
            try std.testing.expectEqual(z.CloseResult.deferred, try self.window.destroy());
            try std.testing.expectError(error.ResourceInUse, self.adapter.deinit());
        }
    }
    fn paintCommand(ptr: *anyopaque, command: shaped.PaintCommand) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const frame = self.frame.?;
        switch (command) {
            .text => |value| {
                try frame.preparedText(value.origin, try value.prepared.view(), ui.Color.rgb(0x141414));
                self.text_commands += 1;
            },
            .selection => |rect| frame.rect(rect, 0xb4cfff),
            .composition => |rect| frame.rect(rect, 0x5070b0),
            .caret => |rect| frame.rect(rect, 0),
        }
    }
    fn input(ptr: *anyopaque, _: *ui.Context, value: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        var viewport = self.viewport;
        var options = self.options;
        if (value == .resize) {
            const size = value.resize;
            if (size.width == 0 or size.height == 0) return false;
            options.scale = size.scale;
            viewport.width = @max(1, @as(f32, @floatFromInt(size.width)) / size.scale - 16);
            viewport.height = @max(1, @as(f32, @floatFromInt(size.height)) / size.scale - 16);
        }
        const consumed = self.adapter.handleEvent(value, viewport) catch |err| {
            self.err = err;
            return true;
        };
        _ = self.adapter.prepare(viewport, options) catch |err| {
            self.err = err;
            return true;
        };
        self.viewport = viewport;
        self.options = options;
        if (value == .resize) {
            self.resize_prepares += 1;
            if (self.finish_on_resize and viewport.width == 344 and viewport.height == 184 and !self.finish_queued) {
                self.finish_queued = true;
                self.window.app.post(.{ .context = self, .call = finishTask }) catch |err| {
                    self.err = err;
                };
            }
        }
        const caret = self.adapter.caretRect(viewport, options.scale) catch |err| {
            self.err = err;
            return true;
        };
        self.window.setTextCaret(.{ .x = caret.x, .y = caret.y, .width = caret.width, .height = caret.height }) catch |err| {
            self.err = err;
        };
        return consumed;
    }
    fn cancel(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.window.cancelTextComposition() catch |err| {
            self.err = err;
        };
    }
    fn native(self: *State) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn paint(self: *State) void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else {
            const size = self.window.clientBounds() catch |err| {
                self.err = err;
                return;
            };
            zlg_test_paint(self.native(), size.width, size.height);
        }
    }
    fn finishTask(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.finish() catch |err| {
            self.err = err;
            self.window.app.quit();
        };
    }
    fn finish(self: *State) !void {
        if (self.err) |err| return err;
        try std.testing.expect(self.resize_prepares > 0 and self.viewport.width == 344 and self.viewport.height == 184);
        try std.testing.expectEqual(self.options.scale, self.adapter.snapshot.?.scale);
        try std.testing.expectEqual(self.viewport.width, (try self.adapter.snapshot.?.layout.options()).width);
        self.paint();
        if (self.err) |err| return err;
        const painted = self.context.last_paint_size.?;
        try std.testing.expectEqual(@as(u32, @intFromFloat(360 * self.options.scale)), painted.width);
        try std.testing.expectEqual(@as(u32, @intFromFloat(200 * self.options.scale)), painted.height);
        self.expected_diagnostic = error.InvalidGeometry;
        self.failure = true;
        const completed_frames = self.context.frames;
        self.paint();
        try std.testing.expectEqual(completed_frames, self.context.frames);
        try std.testing.expect(!(try self.adapter.snapshot.?.prepared.inUse()));
        self.failure = false;
        self.expected_diagnostic = null;
        self.close_in_draw = true;
        self.paint();
    }
    fn sendKey(self: *State, code: u32) !void {
        if (builtin.os.tag == .windows) {
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_KEYDOWN, code, 0);
        } else {
            const area = gtk_bin_get_child(self.window.nativeHandle().?).?;
            const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const key_event: *KeyEvent = @ptrCast(@alignCast(event));
            key_event.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(area).?), .send_event = 1, .time = 0, .state = 0, .keyval = code, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(area, "key-press-event", key_event, &handled);
            key_event.kind = 9;
            g_signal_emit_by_name(area, "key-release-event", key_event, &handled);
        }
    }
};
fn cycle(allocator: std.mem.Allocator, gpu: bool) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var state: State = .{ .editor = try ui.editor.Editor.init(allocator, .{ .multiline = true, .autofocus = true }, "abc אבג 中文") };
    defer state.editor.deinit();
    state.adapter = try shaped.Adapter.init(allocator, &state.editor, engine, .{});
    defer state.adapter.deinit() catch unreachable;
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = if (gpu) .warp else .gdi;
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 320, .height = 160 });
    defer _ = state.window.destroy() catch unreachable;
    state.options.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    state.editor.composition_context = &state;
    state.editor.cancel_native_composition = State.cancel;
    _ = try state.adapter.prepare(state.viewport, state.options);
    try state.context.attach(state.window);
    state.paint();
    if (state.err) |err| return err;
    try std.testing.expect(state.draw_count == 1 and state.text_commands == 1 and state.transaction_checked);
    try std.testing.expect(!(try state.adapter.snapshot.?.prepared.inUse()));
    const initial_layout = state.adapter.snapshot.?.layout;
    const stats = try initial_layout.buildStats();
    state.paint();
    try std.testing.expectEqual(initial_layout, state.adapter.snapshot.?.layout);
    try std.testing.expectEqual(stats, try initial_layout.buildStats());
    if (!gpu and builtin.os.tag == .windows) {
        var colored: usize = 0;
        const scale = state.options.scale;
        const width: c_int = @intFromFloat(bounds.width * scale);
        const height: c_int = @intFromFloat(30 * scale);
        var y: c_int = @intFromFloat(bounds.y * scale);
        while (y < height) : (y += 1) {
            var x: c_int = @intFromFloat(bounds.x * scale);
            while (x < width) : (x += 1) if (c.GetPixel(state.context.renderer.dc, x, y) != 0xffffff) {
                colored += 1;
            };
        }
        try std.testing.expect(colored > 50);
    }
    if (builtin.os.tag == .windows and ui.capabilities.gpu and gpu) {
        state.expected_diagnostic = error.DeviceLost;
        state.context.gpu_renderer.injectDeviceLoss();
        const fallbacks = state.context.fallbacks;
        state.paint();
        if (state.err) |err| return err;
        try std.testing.expect(state.context.fallbacks > fallbacks and state.context.gdi_frames > 0);
        try std.testing.expect(!(try state.adapter.snapshot.?.prepared.inUse()));
        state.expected_diagnostic = null;
    }
    _ = try state.editor.buffer.selectAll();
    _ = try state.editor.insertText("");
    _ = try state.adapter.prepare(state.viewport, state.options);
    if (builtin.os.tag == .windows) {
        _ = c.SendMessageW(state.window.nativeHandle(), c.WM_CHAR, 'a', 0);
        _ = c.SendMessageW(state.window.nativeHandle(), c.WM_UNICHAR, 0x0301, 0);
    } else zlg_test_commit(state.native(), "a\xcc\x81");
    try std.testing.expectEqualStrings("a\u{0301}", state.editor.buffer.text());
    try state.sendKey(if (builtin.os.tag == .windows) c.VK_BACK else 0xff08);
    try std.testing.expectEqualStrings("", state.editor.buffer.text());
    if (builtin.os.tag == .linux) {
        try state.sendKey(0xff20);
        try state.sendKey('\'');
        try state.sendKey('e');
        try std.testing.expectEqualStrings("é", state.editor.buffer.text());
    }
    _ = try state.editor.buffer.setComposition("文", .{ .anchor = 3, .caret = 3 });
    state.editor.refresh();
    _ = try state.adapter.prepare(state.viewport, state.options);
    const candidate = try state.adapter.caretRect(state.viewport, state.options.scale);
    try state.window.setTextCaret(.{ .x = candidate.x, .y = candidate.y, .width = candidate.width, .height = candidate.height });
    if (builtin.os.tag == .windows) {
        _ = c.SendMessageW(state.window.nativeHandle(), c.WM_IME_STARTCOMPOSITION, 0, 0);
        _ = c.SendMessageW(state.window.nativeHandle(), c.WM_IME_ENDCOMPOSITION, 0, 0);
    } else _ = try state.adapter.handleEvent(.text_preedit_cancel, state.viewport);
    _ = try state.adapter.prepare(state.viewport, state.options);
    try std.testing.expect(state.editor.buffer.composition() == null);
    if (builtin.os.tag == .windows) {
        try state.window.resize(360, 200);
        try state.finish();
        try app.dispatch();
    } else {
        state.finish_on_resize = true;
        try state.window.perform(.show);
        try state.window.resize(360, 200);
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        try std.testing.expect(!watchdog.expired and state.finish_queued);
    }
    if (state.err) |err| return err;
    try std.testing.expect(state.window.isClosed() and state.context.window == null);
    try std.testing.expect(!(try state.adapter.snapshot.?.prepared.inUse()));
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try std.testing.expectEqual(@as(usize, 0), state.context.command_buffer.preparedTextResources().len);
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const before = text.resourceCounts();
    if (builtin.os.tag == .linux) _ = g_setenv("GTK_IM_MODULE", "simple", 1);
    try cycle(debug.allocator(), false);
    if (builtin.os.tag == .windows and ui.capabilities.gpu) try cycle(debug.allocator(), true);
    try std.testing.expectEqual(before, text.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("shaped editor native passed: real input and prepared paint, candidate caret, failed frame/close release, optional GPU fallback, resources=0\n", .{});
}
