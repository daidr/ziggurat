const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const diff = @import("ziggurat_document_diff");
const viewing = @import("ziggurat_document_diff_view");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
extern fn zlg_test_surrounding(*anyopaque, [*]u8, usize, *usize, *usize) c_int;
extern fn zlg_test_delete_surrounding(*anyopaque, c_int, c_int) c_int;
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const FocusEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, in: i16 };
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 420, .height = 260 };
const original = "header\nleft 😀 a long wrapped original paragraph with two words\r\nremove one\nsame\nlast";
const modified = "header\nreplacement 文 a short paragraph\r\nadded two\nadded three\nsame\nlast";
pub fn Harness(comptime Surface: type) type {
    return struct {
        const Self = @This();
        window: z.Window = undefined,
        context: ui.Context = undefined,
        inbox: *viewing.Inbox,
        view: *Surface = undefined,
        adapters: [2]*editing.Adapter,
        parameters: viewing.Parameters = .{ .font = .{ .size = 16, .wrap = .word_character, .width = 200 } },
        failure: ?anyerror = null,
        expected: ?anyerror = null,
        fail_frame: bool = false,
        close_frame: bool = false,
        viewport: ui.Rect = bounds,
        after_draw: ?*const fn (*Self, *ui.Frame) anyerror!void = null,
        detailed: bool = false,
        pub fn action(_: *anyopaque, _: u64) void {}
        pub fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (value.err) |actual| {
                if (self.expected) |wanted| {
                    if (actual != wanted) self.failure = actual;
                } else self.failure = actual;
            } else if (self.expected != null) self.failure = error.UnexpectedDiagnostic;
        }
        pub fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.view.handleEvent(event, self.viewport, self.parameters) catch |err| {
                self.failure = err;
                return true;
            };
        }
        pub fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.drawChecked(frame) catch |err| {
                self.failure = err;
            };
        }
        pub fn drawChecked(self: *Self, frame: *ui.Frame) !void {
            frame.clear(0xffffff);
            try self.view.draw(frame, self.viewport, .{});
            const coordinator = if (Surface == viewing.EditableUnified) self.view.coordinator() else self.view;
            var exported_rows: [96]viewing.editable.Row = undefined;
            const presentation = try coordinator.copyPresentation(&exported_rows);
            try coordinator.validatePresentation(presentation.epoch);
            try std.testing.expectEqual(self.viewport, presentation.bounds);
            if (presentation.rows.len != 0) try std.testing.expectError(error.CapacityExceeded, coordinator.copyPresentation(exported_rows[0..0]));
            try coordinator.retainClient();
            try std.testing.expectError(error.ClientsAlive, coordinator.close());
            try coordinator.releaseClient();
            if (self.after_draw) |callback| try callback(self, frame);
            try std.testing.expectError(error.ResourceInUse, self.view.close());
            if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
            if (self.close_frame) _ = try self.window.destroy();
        }
        pub fn paint(self: *Self) !void {
            if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else {
                const record = self.window.app.windows.get(self.window.key).?.native.native.?;
                zlg_test_paint(record, @intFromFloat(430 * self.parameters.scale), @intFromFloat(270 * self.parameters.scale));
            }
            if (self.failure) |err| return err;
        }
        pub fn pixel(self: *Self, x: f32, y: f32) !u32 {
            const xx: u32 = @intFromFloat(x * self.parameters.scale);
            const yy: u32 = @intFromFloat(y * self.parameters.scale);
            if (builtin.os.tag == .windows) {
                const color = c.GetPixel(self.context.renderer.dc, @intCast(xx), @intCast(yy));
                if (color == c.CLR_INVALID) return error.NoPixel;
                return ((color & 255) << 16) | (color & 0xff00) | ((color >> 16) & 255);
            }
            return zlc_test_raw_pixel(self.context.renderer.native.?, xx, yy);
        }
        pub fn refresh(self: *Self) !void {
            const job = try self.inbox.begin();
            var released = false;
            defer {
                if (!released) job.release() catch unreachable;
                _ = self.inbox.finish(job.ticket) catch unreachable;
            }
            var result = try diff.compare(std.heap.page_allocator, job.a, job.b, .{});
            defer result.deinit();
            var details: ?viewing.intraline.Result = if (self.detailed) try viewing.intraline.compare(std.heap.page_allocator, job.a, job.b, &result, .{ .cancellation = job.cancellation }) else null;
            defer if (details) |*value| value.deinit();
            try job.release();
            released = true;
            try self.inbox.publishDetailed(job.ticket, &result, if (details) |*value| value else null);
            try self.view.prepare(self.viewport, self.parameters);
        }
        pub fn key(self: *Self, win: usize, gtk: u32) !void {
            if (builtin.os.tag == .windows) {
                // Both backend branches request an unmodified key. Preserve
                // this thread's table so ambient modifiers cannot change it.
                var previous: [256]u8 = undefined;
                try std.testing.expect(c.GetKeyboardState(&previous) != 0);
                defer _ = c.SetKeyboardState(&previous);
                var clean: [256]u8 = @splat(0);
                try std.testing.expect(c.SetKeyboardState(&clean) != 0);
                _ = c.SendMessageW(self.window.nativeHandle(), c.WM_KEYDOWN, win, 0);
            } else {
                const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
                const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
                defer gdk_event_free(event);
                const native: *KeyEvent = @ptrCast(@alignCast(event));
                native.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = 0, .keyval = gtk, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
                var handled: c_int = 0;
                g_signal_emit_by_name(widget, "key-press-event", native, &handled);
                try std.testing.expect(handled != 0);
            }
            if (self.failure) |err| return err;
        }
        pub fn insert(self: *Self) !void {
            if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_CHAR, 'x', 0) else try self.key('X', 'x');
            if (self.failure) |err| return err;
        }
        pub fn focusEvent(self: *Self, focused: bool) !void {
            if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), if (focused) c.WM_SETFOCUS else c.WM_KILLFOCUS, 0, 0) else {
                const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
                const event = gdk_event_new(12) orelse return error.EventAllocationFailed;
                defer gdk_event_free(event);
                const native: *FocusEvent = @ptrCast(@alignCast(event));
                native.* = .{ .kind = 12, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .in = @intFromBool(focused) };
                var handled: c_int = 0;
                g_signal_emit_by_name(widget, if (focused) @as([*:0]const u8, "focus-in-event") else "focus-out-event", native, &handled);
            }
            if (self.failure) |err| return err;
        }
        pub fn click(self: *Self, x: f32, y: f32) !void {
            if (builtin.os.tag == .windows) {
                const xx: u32 = @intFromFloat(x * self.parameters.scale);
                const yy: u32 = @intFromFloat(y * self.parameters.scale);
                const point: isize = @intCast(xx | (yy << 16));
                _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONDOWN, 0, point);
                _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONUP, 0, point);
            } else {
                const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
                const event = gdk_event_new(4) orelse return error.EventAllocationFailed;
                defer gdk_event_free(event);
                const native: *ButtonEvent = @ptrCast(@alignCast(event));
                native.* = .{ .kind = 4, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
                var handled: c_int = 0;
                g_signal_emit_by_name(widget, "button-press-event", native, &handled);
                native.kind = 7;
                g_signal_emit_by_name(widget, "button-release-event", native, &handled);
            }
            if (self.failure) |err| return err;
        }
    };
}
const State = Harness(viewing.EditableSplit);

fn expectText(document: *d.Document, expected: []const u8) !void {
    var bytes: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(expected, bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
}
fn nativeChanges(state: *State) !void {
    const document = state.inbox.pair.b;
    try state.view.focus(.b);
    _ = try state.adapters[1].setSelection(.{ .anchor = 3, .caret = 3 }, .downstream);
    try state.view.prepare(state.viewport, state.parameters);
    if (builtin.os.tag == .windows) {
        var bytes: [12352]u8 align(8) = undefined;
        const offer: *c.RECONVERTSTRING = @ptrCast(&bytes);
        const hwnd = state.window.nativeHandle();
        try std.testing.expect(c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0) > 0);
        offer.dwSize = bytes.len;
        try std.testing.expect(c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer))) > 0);
        offer.dwCompStrOffset = 2;
        offer.dwCompStrLen = 2;
        offer.dwTargetStrOffset = 2;
        offer.dwTargetStrLen = 2;
        try std.testing.expectEqual(@as(isize, 1), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
        try std.testing.expectEqual(d.Selection{ .anchor = 1, .caret = 3 }, try document.selection());
        // No UI input event followed the native reconversion confirmation.
        // The observer must synchronously publish the paired presentation.
        try std.testing.expect(!(try state.view.info()).comparison_required);
        const right: ui.Rect = .{ .x = bounds.x + (bounds.width - 8) / 2 + 8, .y = bounds.y, .width = (bounds.width - 8) / 2, .height = bounds.height };
        const caret = try state.adapters[1].caretRect(right, state.parameters.scale);
        const im = c.ImmGetContext(hwnd) orelse return error.InputContextUnavailable;
        defer _ = c.ImmReleaseContext(hwnd, im);
        var candidate: c.CANDIDATEFORM = undefined;
        try std.testing.expect(c.ImmGetCandidateWindow(im, 0, &candidate) != 0);
        try std.testing.expectEqual(@as(c_int, @intFromFloat(caret.x * state.parameters.scale)), candidate.rcArea.left);
        try std.testing.expectEqual(@as(c_int, @intFromFloat(caret.y * state.parameters.scale)), candidate.rcArea.top);
    } else {
        const record = state.window.app.windows.get(state.window.key).?.native.native.?;
        var bytes: [12288]u8 = undefined;
        var length: usize = 0;
        var cursor: usize = 0;
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_surrounding(record, &bytes, bytes.len, &length, &cursor));
        try std.testing.expectEqual(@as(usize, 3), cursor);
        const before = try document.byteLength();
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_delete_surrounding(record, -1, 1));
        try std.testing.expectEqual(before - 1, try document.byteLength());
        try std.testing.expect((try state.view.info()).comparison_required);
        _ = try state.adapters[1].undo();
        try expectText(document, modified);
        try state.refresh();
    }
    try state.paint();
}

pub fn run(allocator: std.mem.Allocator) !void {
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), original, .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), modified, .{});
    defer b.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter_a = try editing.Adapter.create(allocator, a, engine, .{});
    defer adapter_a.close() catch unreachable;
    const adapter_b = try editing.Adapter.create(allocator, b, engine, .{});
    defer adapter_b.close() catch unreachable;
    const inbox = try viewing.Inbox.create(allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    var state: State = .{ .inbox = inbox, .adapters = .{ adapter_a, adapter_b } };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 270 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    state.view = try viewing.EditableSplit.create(failing.allocator(), inbox, adapter_a, adapter_b, state.window, .{});
    defer state.view.close() catch unreachable;
    try std.testing.expectError(error.ObserverAttached, adapter_a.close());
    try state.refresh();
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try state.paint();
    var storage: [96]viewing.editable.Row = undefined;
    var blank = false;
    var changed = false;
    for (try state.view.rowInfo(&storage)) |row| {
        if (row.hunk == null) continue;
        changed = true;
        const y = bounds.y + row.y + 1;
        if (y < bounds.y or y >= bounds.y + bounds.height) continue;
        try std.testing.expectEqual(if (row.a == null) @as(u32, 0xeeeeee) else 0xffe9e9, try state.pixel(bounds.x + (bounds.width - 8) / 2 - 2, y));
        try std.testing.expectEqual(if (row.b == null) @as(u32, 0xeeeeee) else 0xe5f6e9, try state.pixel(bounds.x + bounds.width - 2, y));
        if (row.a == null or row.b == null) blank = true;
    }
    try std.testing.expect(changed and blank);
    // The actual Adapter visual/caret/hit APIs agree with the same alignment.
    const left_last = try a.line(3);
    const right_last = try b.line(4);
    const left_rect = (try adapter_a.positionRect(try a.version(), left_last.start, .downstream)).?;
    const right_rect = (try adapter_b.positionRect(try b.version(), right_last.start, .downstream)).?;
    try std.testing.expectApproxEqAbs(left_rect.y, right_rect.y, 0.001);
    // Native pointer chooses the sole native text client; native character
    // input edits that same Document and one Adapter undo restores it.
    try state.click(222, bounds.y + 5);
    try std.testing.expectEqual(viewing.Side.b, (try state.view.info()).focused.?);
    const selected = try b.selection();
    const length = try b.byteLength();
    try state.insert();
    try std.testing.expectEqual(length + 1, try b.byteLength());
    try std.testing.expect((try state.view.info()).comparison_required);
    try expectText(a, original);
    _ = try adapter_b.undo();
    try expectText(b, modified);
    try std.testing.expectEqual(selected, try b.selection());
    try state.refresh();
    try state.click(12, bounds.y + 5);
    try std.testing.expectEqual(viewing.Side.a, (try state.view.info()).focused.?);
    try state.key(0x23, 0xff57); // End uses the Adapter's native visual line.
    try std.testing.expect((try a.selection()).caret != 0);
    try state.key(0x76, 0xffc4);
    try state.paint();
    // IME is temporary identity on both panes; cancel restores stamped plans.
    _ = try state.view.handleEvent(.{ .text_preedit = .{ .text = "候\n选", .selection_start = 0, .selection_end = 3 } }, bounds, state.parameters);
    try std.testing.expect((try state.view.info()).composition_identity);
    try std.testing.expect(!(try adapter_a.status()).projection_active and !(try adapter_b.status()).projection_active);
    _ = try state.view.handleEvent(.text_preedit_cancel, bounds, state.parameters);
    try std.testing.expect(!(try state.view.info()).comparison_required);
    try std.testing.expect((try adapter_a.status()).projection_active and (try adapter_b.status()).projection_active);
    try state.paint();
    _ = try state.view.handleEvent(.{ .text_preedit = .{ .text = "候\n选", .selection_start = 0, .selection_end = 3 } }, bounds, state.parameters);
    try state.focusEvent(false);
    try std.testing.expect(try a.composition() == null);
    try std.testing.expect(!(try state.view.info()).composition_identity);
    try state.focusEvent(true);
    try std.testing.expect(state.window.textClientToken() != null);
    // A revert is one target history operation and expires this comparison.
    _ = try state.view.revert(0, .a_to_b);
    try state.view.prepare(bounds, state.parameters);
    try std.testing.expect((try state.view.info()).comparison_required);
    _ = try adapter_b.undo();
    try expectText(b, modified);
    try state.refresh();
    try nativeChanges(&state);
    try @import("document_diff_editable_edges.zig").run(allocator, state.window, state.view, inbox, .{ adapter_a, adapter_b }, bounds, state.parameters, &failing);
    try state.refresh();
    // Foreign allocation failure takes no candidate and publishes neither side.
    const versions = .{ try adapter_a.viewVersion(), try adapter_b.viewVersion() };
    state.viewport.width -= 20;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.view.prepare(state.viewport, state.parameters));
    try std.testing.expectEqual(versions[0], try adapter_a.viewVersion());
    try std.testing.expectEqual(versions[1], try adapter_b.viewVersion());
    failing.fail_index = std.math.maxInt(usize);
    state.viewport = bounds;
    try state.view.prepare(bounds, state.parameters);
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    const frames = state.context.frames;
    try state.paint();
    try std.testing.expectEqual(frames, state.context.frames);
    state.fail_frame = false;
    state.expected = null;
    try state.view.prepare(bounds, state.parameters);
    state.close_frame = true;
    try state.paint();
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try @import("document_diff_editable_edges.zig").closeReentry(allocator, app, engine);
    std.debug.print("editable split native passed: native pointer/key/text, shared caret/alignment, one undo/revert, both-IME identity/cancel, OOM pair rollback, failed Frame/close resources=0\n", .{});
}
