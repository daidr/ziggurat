const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const code = @import("ziggurat_code_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_resource_count() u32;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 400, .height = 210 };
const State = struct {
    window: z.Window = undefined,
    presenter: *code.Presenter = undefined,
    context: ui.Context = undefined,
    parameters: editing.Parameters = .{ .font = .{ .size = 16, .wrap = .word_character, .width = bounds.width } },
    failure: ?anyerror = null,
    expected: ?anyerror = null,
    fail_frame: bool = false,
    close_frame: bool = false,
    paints: usize = 0,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.err) |actual| {
            if (self.expected) |wanted| {
                if (actual != wanted) self.failure = actual;
            } else self.failure = actual;
        } else if (self.expected != null) self.failure = error.UnexpectedDiagnostic;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        try self.presenter.draw(frame, bounds, .{});
        self.paints += 1;
        try std.testing.expectError(error.ResourceInUse, self.presenter.close());
        try std.testing.expectError(error.ResourceInUse, self.presenter.prepare(bounds, self.parameters));
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
        if (self.close_frame) _ = try self.window.destroy();
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        return self.presenter.handleEvent(event, bounds, self.parameters) catch |err| {
            self.failure = err;
            return true;
        };
    }
    fn native(self: *State) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn paint(self: *State) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else zlg_test_paint(self.native(), @intFromFloat(430 * self.parameters.scale), @intFromFloat(240 * self.parameters.scale));
        if (self.failure) |err| return err;
    }
    fn pixel(self: *State, x: f32, y: f32) !u32 {
        const xx: u32 = @intFromFloat(x * self.parameters.scale);
        const yy: u32 = @intFromFloat(y * self.parameters.scale);
        if (builtin.os.tag == .windows) {
            const value = c.GetPixel(self.context.renderer.dc, @intCast(xx), @intCast(yy));
            if (value == c.CLR_INVALID) return error.NoPixel;
            return ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
        }
        // Coordinates above are already physical pixels on both backends.
        return zlc_test_raw_pixel(self.context.renderer.native.?, xx, yy);
    }
    fn key(self: *State, win: usize, gtk: u32) !void {
        if (builtin.os.tag == .windows) {
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_KEYDOWN, win, 0);
        } else {
            const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
            const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native_event: *KeyEvent = @ptrCast(@alignCast(event));
            native_event.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = 0, .keyval = gtk, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "key-press-event", native_event, &handled);
            try std.testing.expect(handled != 0);
        }
        if (self.failure) |err| return err;
    }
    fn commitByte(self: *State, value: u8) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_CHAR, value, 0) else _ = try self.presenter.handleEvent(.{ .text_input = .{ .text = &.{value}, .producer = .application } }, bounds, self.parameters);
        if (self.failure) |err| return err;
    }
    fn click(self: *State, x: f32, y: f32) !void {
        if (builtin.os.tag == .windows) {
            const xx: u32 = @intFromFloat(x * self.parameters.scale);
            const yy: u32 = @intFromFloat(y * self.parameters.scale);
            const pos: isize = @intCast(xx | (yy << 16));
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONDOWN, 0, pos);
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONUP, 0, pos);
        } else {
            const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
            const event = gdk_event_new(4) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native_event: *ButtonEvent = @ptrCast(@alignCast(event));
            native_event.* = .{ .kind = 4, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "button-press-event", native_event, &handled);
            native_event.kind = 7;
            g_signal_emit_by_name(widget, "button-release-event", native_event, &handled);
        }
        if (self.failure) |err| return err;
    }
};
fn publish(broker: *code.Broker, data: code.results.Data, position: usize) !void {
    const job = try broker.begin(std.meta.activeTag(data), position);
    try job.release();
    defer _ = broker.finish(job.ticket) catch unreachable;
    var result = try code.OwnedResult.init(std.heap.page_allocator, data, job.limits);
    defer result.deinit();
    try broker.publish(job.ticket, &result);
}
const Delivery = struct {
    job: code.Job,
    app: *z.App,
    result: ?code.OwnedResult = null,
    failure: ?anyerror = null,
    delivered: bool = false,
    fn worker(self: *Delivery) void {
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn work(self: *Delivery) !void {
        var bytes: [64]u8 = undefined;
        const length = try self.job.reader.read(.{ .start = 0, .end = try self.job.reader.byteLength() }, &bytes);
        if (length == 0 or try self.job.isCancelled()) return error.UnexpectedInput;
        self.result = try code.OwnedResult.init(std.heap.page_allocator, .{ .diagnostics = &.{.{ .range = .{ .start = 0, .end = 3 }, .message = "unresolved symbol" }} }, self.job.limits);
        try self.job.release();
        try self.app.post(.{ .context = self, .call = deliver });
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *Delivery = @ptrCast(@alignCast(ptr));
        defer _ = self.job.ticket.broker.finish(self.job.ticket) catch unreachable;
        defer self.result.?.deinit();
        self.job.ticket.broker.publish(self.job.ticket, &self.result.?) catch |err| {
            self.failure = err;
            return;
        };
        self.delivered = true;
    }
};
fn expectText(doc: *d.Document, expected: []const u8) !void {
    var bytes: [128]u8 = undefined;
    try std.testing.expectEqualStrings(expected, bytes[0..try doc.read(.{ .start = 0, .end = try doc.byteLength() }, &bytes)]);
}
fn run(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc 😀 אבג e\u{301}\r\nxyz", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    var state: State = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 240 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    _ = try adapter.setSelection(.{ .anchor = 3, .caret = 3 }, .downstream);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    state.presenter = try code.Presenter.create(failing.allocator(), broker, adapter, engine, state.window, .{});
    defer state.presenter.close() catch unreachable;
    try std.testing.expectError(error.ClientsAlive, adapter.close());
    try std.testing.expectError(error.ClientsAlive, broker.close());
    try state.presenter.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try adapter.bind(state.window);
    defer adapter.unbind() catch unreachable;
    // The child runs on a separate, never-activated Windows desktop. Native
    // focus/capture requires a shown window there; no user desktop is changed.
    if (builtin.os.tag == .windows) state.window.show();
    var delivery: Delivery = .{ .job = try broker.begin(.diagnostics, 0), .app = app };
    const worker = try std.Thread.spawn(.{}, Delivery.worker, .{&delivery});
    worker.join();
    if (delivery.failure) |err| return err;
    try std.testing.expect(!delivery.delivered and broker.outstanding == 1);
    try app.dispatch();
    if (delivery.failure) |err| return err;
    try std.testing.expect(delivery.delivered and broker.outstanding == 0);
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect((try state.presenter.overlayInfo()).diagnostics > 0);
    try state.paint();
    var diagnostic_rects: [32]t.Rect = undefined;
    const underline = (try adapter.rangeRects(try document.version(), .{ .start = 0, .end = 3 }, &diagnostic_rects))[0];
    try std.testing.expectEqual(@as(u32, 0xd52b32), try state.pixel(underline.x + underline.width * 0.5, underline.y + underline.height - 1 / state.parameters.scale));
    // Projection uses the same prepared cells as ordinary selections.
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = 3 }, .downstream);
    try state.presenter.prepare(bounds, state.parameters);
    var ordinary: [64]ui.Rect = undefined;
    var projected: [64]t.Rect = undefined;
    const marks = try adapter.selectionRects(&ordinary);
    const rects = try adapter.rangeRects(try document.version(), .{ .start = 0, .end = 3 }, &projected);
    try std.testing.expect(marks.len != 0 and marks.len == rects.len);
    for (marks, rects) |a, q| try std.testing.expect(a.x == q.x and a.y == q.y and a.width == q.width and a.height == q.height);
    for ([_]d.Range{ .{ .start = 4, .end = 8 }, .{ .start = 0, .end = try document.byteLength() }, .{ .start = 9, .end = 15 } }) |range| {
        _ = try adapter.setSelection(.{ .anchor = range.start, .caret = range.end }, .downstream);
        try state.presenter.prepare(bounds, state.parameters);
        const expected = try adapter.selectionRects(&ordinary);
        const projected_rects = try adapter.rangeRects(try document.version(), range, &projected);
        try std.testing.expect(expected.len != 0 and expected.len == projected_rects.len);
        for (expected, projected_rects) |a, q| try std.testing.expect(a.x == q.x and a.y == q.y and a.width == q.width and a.height == q.height);
    }
    var sentinel = [_]t.Rect{.{ .x = -123, .y = -456 }};
    try std.testing.expectError(error.RectangleCapacityExceeded, adapter.rangeRects(try document.version(), .{ .start = 0, .end = 3 }, sentinel[0..0]));
    try std.testing.expectEqual(@as(f32, -123), sentinel[0].x);
    _ = try adapter.setSelection(.{ .anchor = 3, .caret = 3 }, .downstream);
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect((try broker.display(.diagnostics)) != null);
    try publish(broker, .{ .hover = .{ .range = .{ .start = 0, .end = 3 }, .text = "symbol documentation\nUTF8: 中 😀" } }, 1);
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect((try state.presenter.overlayInfo()).hover);
    try state.paint();
    var info = try state.presenter.overlayInfo();
    const hover_box = info.popup.?;
    try std.testing.expectEqual(@as(u32, 0xf3f5f8), try state.pixel(hover_box.x + hover_box.width - 2, hover_box.y + 1));
    const geometry = try adapter.projectionVersion();
    _ = try adapter.setSelection(.{ .anchor = 1, .caret = 2 }, .downstream);
    try std.testing.expectError(error.LayoutRequired, state.presenter.overlayInfo());
    failing.fail_index = failing.alloc_index;
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expectEqual(geometry, try adapter.projectionVersion());
    try std.testing.expect((try state.presenter.overlayInfo()).hover and (try state.presenter.overlayInfo()).diagnostics > 0);
    _ = try adapter.setSelection(.{ .anchor = 3, .caret = 3 }, .downstream);
    try state.presenter.prepare(bounds, state.parameters);
    failing.fail_index = std.math.maxInt(usize);
    var changed_font = state.parameters;
    changed_font.font.weight = 600;
    try state.presenter.prepare(bounds, changed_font);
    try std.testing.expect(geometry != try adapter.projectionVersion());
    try state.presenter.prepare(bounds, state.parameters);
    const before_scroll = try adapter.projectionVersion();
    try std.testing.expect(try adapter.scrollBy(.{ .x = 5 }));
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect(before_scroll != try adapter.projectionVersion());
    try std.testing.expect(try adapter.scrollBy(.{ .x = -5 }));
    try state.presenter.prepare(bounds, state.parameters);
    const items: []const code.Completion = &.{
        .{ .label = "first", .edits = &.{ .{ .range = .{ .start = 0, .end = 3 }, .text = "first" }, .{ .range = .{ .start = 24, .end = 24 }, .text = "!" } } },
        .{ .label = "second", .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "second" }} },
    };
    // End position is computed from committed bytes; no display offsets leak.
    var copy = [_]d.Replacement{ items[0].edits[0], .{ .range = .{ .start = try document.byteLength(), .end = try document.byteLength() }, .text = "!" } };
    var complete = [_]code.Completion{ items[0], items[1] };
    complete[0].edits = &copy;
    try publish(broker, .{ .completion = &complete }, 3);
    try state.presenter.prepare(bounds, state.parameters);
    info = try state.presenter.overlayInfo();
    try std.testing.expectEqual(@as(usize, 2), info.completion_rows);
    failing.fail_index = failing.alloc_index;
    try state.paint(); // draw has no Presenter allocation.
    failing.fail_index = std.math.maxInt(usize);
    const row = info.popup_rows[0];
    try std.testing.expectEqual(@as(u32, 0xd4e5ff), try state.pixel(row.x + row.width - 2, row.y + 1));
    var ink = false;
    for (0..18) |y| for (0..72) |x| {
        const pixel = try state.pixel(row.x + 4 + @as(f32, @floatFromInt(x)), row.y + 2 + @as(f32, @floatFromInt(y)));
        if (pixel != 0xd4e5ff and pixel != 0xf3f5f8 and pixel != 0xffffff) ink = true;
    };
    try std.testing.expect(ink);
    failing.fail_index = failing.alloc_index;
    try state.key(0x28, 0xff54); // native down selects next completion.
    try std.testing.expectEqual(@as(usize, 1), (try state.presenter.overlayInfo()).selected_completion);
    try state.key(0x26, 0xff52);
    failing.fail_index = std.math.maxInt(usize);
    try state.key(0x0d, 0xff0d); // no extra newline/text event.
    try expectText(document, "first 😀 אבג e\u{301}\r\nxyz!");
    _ = try adapter.undo();
    try expectText(document, "abc 😀 אבג e\u{301}\r\nxyz");
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect((try broker.display(.diagnostics)) == null);
    try publish(broker, .{ .completion = &.{items[1]} }, 3);
    try state.presenter.prepare(bounds, state.parameters);
    info = try state.presenter.overlayInfo();
    try state.click(info.popup_rows[0].x + 12, info.popup_rows[0].y + 8);
    try expectText(document, "second 😀 אבג e\u{301}\r\nxyz");
    _ = try adapter.undo();
    try state.presenter.prepare(bounds, state.parameters);
    // IME preview hides committed ranges, then cancel restores them.
    try publish(broker, .{ .diagnostics = &.{.{ .range = .{ .start = 0, .end = 3 }, .message = "still current" }} }, 0);
    if (state.window.textClientToken() == null) try adapter.bind(state.window);
    _ = try state.presenter.handleEvent(.{ .text_preedit = .{ .text = "候选", .selection_start = 6, .selection_end = 6 } }, bounds, state.parameters);
    try std.testing.expect(try document.composition() != null);
    try std.testing.expectEqual(@as(usize, 0), (try state.presenter.overlayInfo()).diagnostics);
    _ = try state.presenter.handleEvent(.text_preedit_cancel, bounds, state.parameters);
    try std.testing.expect((try state.presenter.overlayInfo()).diagnostics > 0);
    // A failed candidate never masquerades as a current drawing snapshot.
    try publish(broker, .{ .hover = .{ .range = .{ .start = 0, .end = 3 }, .text = "new hover" } }, 0);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.presenter.prepare(bounds, state.parameters));
    try std.testing.expectError(error.LayoutRequired, state.presenter.overlayInfo());
    failing.fail_index = std.math.maxInt(usize);
    try state.presenter.prepare(bounds, state.parameters);
    // A valid result can point into a hidden body; it must not intercept keys.
    try publish(broker, .{ .hover = .{ .range = .{ .start = 0, .end = 0 }, .text = "" } }, 0);
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    try adapter.setFolds(try document.version(), &.{.{ .id = 1, .header = 0, .end = try document.byteLength(), .collapsed = true }});
    try publish(broker, .{ .completion = &.{items[1]} }, try document.byteLength());
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 0), (try state.presenter.overlayInfo()).completion_rows);
    try std.testing.expectError(error.NoCompletion, state.presenter.acceptCompletion(0));
    try std.testing.expect(!try state.presenter.handleEvent(.{ .key_input = .{ .key = .escape } }, bounds, state.parameters));
    try adapter.setFolds(try document.version(), &.{});
    const short: ui.Rect = .{ .x = 8, .y = 8, .width = 400, .height = 16 };
    const small: editing.Parameters = .{ .font = .{ .size = 8, .wrap = .word_character, .width = 400 }, .scale = state.parameters.scale };
    try publish(broker, .{ .completion = &.{items[1]} }, 0);
    try state.presenter.prepare(short, small);
    try std.testing.expectEqual(@as(usize, 0), (try state.presenter.overlayInfo()).completion_rows);
    try std.testing.expectError(error.NoCompletion, state.presenter.acceptCompletion(0));
    try std.testing.expect(!try state.presenter.handleEvent(.{ .key_input = .{ .key = .escape } }, short, small));
    try publish(broker, .{ .completion = &.{} }, 0);
    try state.presenter.prepare(bounds, state.parameters);
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    try state.paint();
    state.fail_frame = false;
    state.expected = null;
    try state.presenter.prepare(bounds, state.parameters); // failed frame released leases.
    state.close_frame = true;
    try state.paint();
    try app.dispatch();
    try std.testing.expect(state.window.isClosed() and state.context.window == null);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

const CloseReentry = struct {
    source: std.mem.Allocator,
    adapter: *editing.Adapter = undefined,
    presenter: ?*code.Presenter = null,
    final_adapter_pinned: bool = false,
    window: z.Window = undefined,
    armed: bool = false,
    inside_free: bool = false,
    self_released: bool = false,
    closed: bool = false,
    raw: bool = false,
    fn allocator(self: *CloseReentry) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CloseReentry = @ptrCast(@alignCast(ptr));
        return self.source.rawAlloc(len, alignment, ra);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *CloseReentry = @ptrCast(@alignCast(ptr));
        return self.source.rawResize(bytes, alignment, len, ra);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *CloseReentry = @ptrCast(@alignCast(ptr));
        return self.source.rawRemap(bytes, alignment, len, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CloseReentry = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            self.inside_free = true;
            if (self.raw) {
                if (builtin.os.tag == .windows) std.debug.assert(c.DestroyWindow(self.window.nativeHandle()) != 0) else gtk_widget_destroy(self.window.nativeHandle().?);
            } else _ = self.window.destroy() catch unreachable;
            std.debug.assert(!self.closed);
            self.inside_free = false;
        }
        if (self.presenter != null and bytes.ptr == @as([*]u8, @ptrCast(self.presenter.?))) {
            std.testing.expectError(error.ClientsAlive, self.adapter.close()) catch unreachable;
            self.final_adapter_pinned = true;
            self.self_released = true;
        }
        self.source.rawFree(bytes, alignment, ra);
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *CloseReentry = @ptrCast(@alignCast(ptr));
        std.debug.assert(!self.inside_free and self.self_released);
        self.closed = true;
    }
};
fn closeReentry(allocator: std.mem.Allocator, raw: bool) !void {
    var state: CloseReentry = .{ .source = allocator, .raw = raw };
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    state.window = try app.createWindow(.{ .on_closed = .{ .context = &state, .notify = CloseReentry.onClosed } });
    const presenter = try code.Presenter.create(state.allocator(), broker, adapter, engine, state.window, .{});
    state.adapter = adapter;
    state.presenter = presenter;
    try publish(broker, .{ .hover = .{ .range = .{ .start = 0, .end = 1 }, .text = "owned layout" } }, 0);
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    try presenter.prepare(bounds, .{});
    state.armed = true;
    try presenter.close();
    try std.testing.expect(state.self_released and state.final_adapter_pinned and !state.inside_free and !state.closed);
    try app.dispatch();
    try std.testing.expect(state.closed and state.window.isClosed());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn completionSnippets(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc tail", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{ .metadata_history = 0 });
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    var state: State = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 240 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    state.presenter = try code.Presenter.create(failing.allocator(), broker, adapter, engine, state.window, .{});
    defer state.presenter.close() catch unreachable;
    _ = try adapter.setSelection(.{ .anchor = 2, .caret = 2 }, .downstream);
    try state.presenter.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try adapter.bind(state.window);
    defer adapter.unbind() catch unreachable;
    if (builtin.os.tag == .windows) state.window.show();
    const item: code.Completion = .{ .label = "with mirrors", .insertion = .{ .snippet = 1 }, .edits = &.{ .{ .range = .{ .start = 0, .end = 0 }, .text = "import;\n" }, .{ .range = .{ .start = 1, .end = 3 }, .text = "${1:猫}=$1;${2|red,green|};$0" }, .{ .range = .{ .start = 8, .end = 8 }, .text = "!" } } };
    try publish(broker, .{ .completion = &.{item} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    const revision = try document.version();
    try std.testing.expectError(error.SnippetsDisabled, state.presenter.acceptCompletionOutcome(0));
    try std.testing.expectEqual(revision, try document.version());
    var enable_failures: usize = 0;
    for (0..32) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        state.presenter.enableSnippets(.{}) catch |err| {
            if (err != error.OutOfMemory) return err;
            enable_failures += 1;
            try std.testing.expect(state.presenter.snippet_session == null);
            continue;
        };
        break;
    } else return error.NoSuccessfulSnippetPolicy;
    try std.testing.expect(enable_failures > 1);
    var accept_failures: usize = 0;
    for (0..128) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        const outcome = state.presenter.acceptCompletionOutcome(0) catch |err| {
            if (err != error.OutOfMemory) return err;
            accept_failures += 1;
            try std.testing.expectEqual(revision, try document.version());
            try expectText(document, "abc tail");
            try std.testing.expect(!(try state.presenter.snippetStatus()).active);
            try std.testing.expect(state.presenter.snippet_template == null);
            continue;
        };
        try std.testing.expect(outcome.snippet_active and !outcome.stale_after_commit);
        try std.testing.expectEqual(revision + 1, outcome.committed_revision);
        break;
    } else return error.NoSuccessfulSnippetAcceptance;
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(accept_failures > 2);
    try expectText(document, "import;\na猫=猫;red; tail!");
    try std.testing.expectError(error.ClientsAlive, state.presenter.snippet_template.?.close());
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect(broker.stored[@intFromEnum(code.Kind.completion)] == null);
    failing.fail_index = failing.alloc_index;
    try state.paint();
    failing.fail_index = std.math.maxInt(usize);
    try state.commitByte('x');
    try expectText(document, "import;\nax=x;red; tail!");
    try state.key(0x09, 0xff09);
    try std.testing.expectEqual(@as(?u16, 2), (try state.presenter.snippetStatus()).id);
    _ = try state.presenter.chooseSnippet(1);
    try state.presenter.prepare(bounds, state.parameters);
    try expectText(document, "import;\nax=x;green; tail!");
    try state.key(0x09, 0xff09);
    try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
    for (0..3) |_| _ = try adapter.undo();
    try expectText(document, "abc tail");
    try state.presenter.prepare(bounds, state.parameters);
    // Acceptance via the visible popup uses the same Session path.
    try publish(broker, .{ .completion = &.{item} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    try state.key(0x09, 0xff09);
    try std.testing.expect((try state.presenter.lastAcceptance()).?.snippet_active);
    try std.testing.expect((try state.presenter.snippetStatus()).active);
    _ = try state.presenter.handleEvent(.{ .text_preedit = .{ .text = "候选", .selection_start = 6, .selection_end = 6 } }, bounds, state.parameters);
    try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
    try std.testing.expect(try document.composition() != null);
    _ = try state.presenter.handleEvent(.text_preedit_cancel, bounds, state.parameters);
    _ = try adapter.undo();
    try state.presenter.prepare(bounds, state.parameters);
    // Ordinary format never interprets dollar syntax, even when enabled.
    try publish(broker, .{ .completion = &.{.{ .label = "literal", .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "$1" }} }} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    _ = try state.presenter.acceptCompletion(0);
    try expectText(document, "$1 tail");
    _ = try adapter.undo();
    try state.presenter.prepare(bounds, state.parameters);
    try publish(broker, .{ .completion = &.{item} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    _ = try adapter.setSelection(.{}, .downstream);
    try std.testing.expectError(error.LayoutRequired, state.presenter.acceptCompletionOutcome(0));
    try expectText(document, "abc tail");
    try state.presenter.prepare(bounds, state.parameters);
    try publish(broker, .{ .completion = &.{item} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    _ = try state.presenter.acceptCompletionOutcome(0);
    _ = try adapter.setSelection(.{}, .downstream);
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
    try publish(broker, .{ .completion = &.{.{ .label = "unsupported", .insertion = .{ .snippet = 0 }, .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "${NAME}" }} }} }, 0);
    try state.presenter.prepare(bounds, state.parameters);
    const before_invalid = try document.version();
    try std.testing.expectError(error.UnsupportedVariable, state.presenter.acceptCompletionOutcome(0));
    try std.testing.expectEqual(before_invalid, try document.version());
    try publish(broker, .{ .completion = &.{item} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    _ = try state.presenter.acceptCompletionOutcome(0);
    try std.testing.expect((try state.presenter.snippetStatus()).active);
    const service_revision = try document.version();
    try broker.invalidateAll();
    try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
    try std.testing.expectEqual(service_revision, try document.version());
    _ = try adapter.undo();
    try state.presenter.prepare(bounds, state.parameters);
    try publish(broker, .{ .completion = &.{item} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    _ = try state.presenter.acceptCompletionOutcome(0);
    try std.testing.expect((try state.presenter.snippetStatus()).active);
    const accepted = try broker.begin(.hover, 0);
    try accepted.release();
    try broker.stop();
    try std.testing.expectEqual(@as(usize, 1), broker.outstanding);
    const stopped_revision = try document.version();
    try std.testing.expectError(error.Closed, state.presenter.handleEvent(.{ .text_input = .{ .text = "never", .producer = .application } }, bounds, state.parameters));
    try std.testing.expectEqual(stopped_revision, try document.version());
    try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
    try std.testing.expectError(error.Closed, state.presenter.chooseSnippet(0));
    try state.presenter.cancelSnippet();
    // The stopped service Presenter does not stop the independent Adapter.
    _ = try adapter.replace(.{ .start = 0, .end = 0 }, "P");
    try std.testing.expectEqual(stopped_revision + 1, try document.version());
    try std.testing.expect(try broker.finish(accepted.ticket));
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
    _ = try state.window.destroy();
    try app.dispatch();
}
const CompletionHook = struct {
    source: std.mem.Allocator,
    document: *d.Document,
    presenter: ?*code.Presenter = null,
    broker: ?*code.Broker = null,
    window: z.Window = undefined,
    failing: *std.testing.FailingAllocator,
    mode: enum { before, after, layout, close_before, close_after, quit_before },
    armed: bool = false,
    triggered: bool = false,
    expected: u64 = 0,
    failure: ?anyerror = null,
    fn allocator(self: *CompletionHook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn callback(self: *CompletionHook, freeing: bool) void {
        if (!self.armed or self.triggered) return;
        const after = self.mode == .after or self.mode == .layout or self.mode == .close_after;
        if (after != freeing) return;
        const revision = self.document.version() catch return;
        if (after and revision != self.expected + 1) return;
        self.triggered = true;
        self.checked() catch |err| {
            self.failure = err;
        };
    }
    fn checked(self: *CompletionHook) !void {
        try std.testing.expectError(error.Busy, self.presenter.?.close());
        try std.testing.expectError(error.Busy, self.broker.?.stop());
        switch (self.mode) {
            .before, .after => {
                const end = try self.document.byteLength();
                try self.document.replace(.{ .start = end, .end = end }, "!");
            },
            .layout => self.failing.fail_index = self.failing.alloc_index,
            .close_before, .close_after => _ = try self.window.destroy(),
            .quit_before => {
                self.window.app.quit();
                try std.testing.expect(!self.window.isClosed());
            },
        }
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CompletionHook = @ptrCast(@alignCast(ptr));
        self.callback(false);
        return self.source.rawAlloc(length, alignment, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CompletionHook = @ptrCast(@alignCast(ptr));
        self.callback(true);
        self.source.rawFree(bytes, alignment, ret);
    }
};
fn completionReentry(allocator: std.mem.Allocator, mode: @FieldType(CompletionHook, "mode")) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var hook: CompletionHook = .{ .source = failing.allocator(), .document = document, .failing = &failing, .mode = mode };
    const adapter = try editing.Adapter.create(hook.allocator(), document, engine, .{ .metadata_history = 0 });
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    hook.broker = broker;
    var state: State = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 240 });
    defer _ = state.window.destroy() catch unreachable;
    hook.window = state.window;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    state.presenter = try code.Presenter.create(hook.allocator(), broker, adapter, engine, state.window, .{});
    defer state.presenter.close() catch unreachable;
    hook.presenter = state.presenter;
    _ = try adapter.setSelection(.{}, .downstream);
    try state.presenter.enableSnippets(.{});
    try state.presenter.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try adapter.bind(state.window);
    defer adapter.unbind() catch unreachable;
    if (builtin.os.tag == .windows) state.window.show();
    try publish(broker, .{ .completion = &.{.{ .label = "template", .insertion = .{ .snippet = 0 }, .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "${1:猫}=$1$0" }} }} }, 0);
    try state.presenter.prepare(bounds, state.parameters);
    hook.expected = try document.version();
    hook.armed = true;
    if (mode == .before or mode == .close_before or mode == .quit_before) {
        try std.testing.expectError(if (mode == .before) error.StaleRevision else error.Closed, state.presenter.acceptCompletionOutcome(0));
        try std.testing.expectEqual(hook.expected + @as(u64, if (mode == .before) 1 else 0), try document.version());
        try expectText(document, if (mode == .before) "abc!" else "abc");
        try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
    } else if (mode == .layout) {
        try state.key(0x09, 0xff09);
        failing.fail_index = std.math.maxInt(usize);
        const outcome = (try state.presenter.lastAcceptance()).?;
        try std.testing.expect(outcome.edit.changed and outcome.layout_error != null);
        try std.testing.expect((try state.presenter.lastLayoutError()) != null);
        try expectText(document, "猫=猫");
        try std.testing.expectEqual(hook.expected + 1, try document.version());
        try state.presenter.prepare(bounds, state.parameters);
        try std.testing.expect((try state.presenter.snippetStatus()).active);
    } else {
        const outcome = try state.presenter.acceptCompletionOutcome(0);
        try std.testing.expect(outcome.edit.changed);
        try std.testing.expectEqual(hook.expected + 1, outcome.committed_revision);
        if (mode == .after) {
            try std.testing.expect(outcome.stale_after_commit and !outcome.snippet_active and outcome.edit.index_required);
            try std.testing.expectEqual(hook.expected + 2, outcome.revision);
            try expectText(document, "猫=猫!");
            try std.testing.expect(state.presenter.snippet_template == null);
            try adapter.reindex();
            _ = try adapter.undo();
            try expectText(document, "猫=猫");
            _ = try adapter.undo();
            try expectText(document, "abc");
        } else {
            try std.testing.expect(state.window.isClosed());
            try expectText(document, "猫=猫");
        }
    }
    hook.armed = false;
    if (hook.failure) |err| return err;
    try std.testing.expect(hook.triggered);
    if (mode == .quit_before) try app.finishShutdown() else {
        _ = try state.window.destroy();
        try app.dispatch();
    }
}
const ResolverHook = struct {
    mode: enum { normal, changed, closed, quit, cancelled, unsupported },
    state: *State,
    document: *d.Document,
    broker: *code.Broker,
    cancellation: *code.snippets.Cancellation,
    calls: usize = 0,
    fn resolve(ptr: *anyopaque, name: []const u8, writer: *code.snippets.ValueWriter) !code.snippets.Resolution {
        const self: *ResolverHook = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        try std.testing.expectEqualStrings("NAME", name);
        try std.testing.expectError(error.Busy, self.state.presenter.close());
        try std.testing.expectError(error.Busy, self.state.presenter.snippet_session.?.close());
        try std.testing.expectError(error.Busy, self.state.presenter.snippet_session.?.cancel());
        try std.testing.expectError(error.Busy, self.broker.stop());
        try writer.writeAll("猫");
        switch (self.mode) {
            .normal => {},
            .changed => {
                const length = try self.document.byteLength();
                try self.document.replace(.{ .start = length, .end = length }, "!");
            },
            .closed => _ = try self.state.window.destroy(),
            .quit => self.state.window.app.quit(),
            .cancelled => self.cancellation.request(),
            .unsupported => return .unsupported,
        }
        return .value;
    }
};
fn nestedCompletion(allocator: std.mem.Allocator, mode: @FieldType(ResolverHook, "mode")) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{ .metadata_history = 0 });
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    var state: State = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 240 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    state.presenter = try code.Presenter.create(allocator, broker, adapter, engine, state.window, .{});
    defer state.presenter.close() catch unreachable;
    var cancellation: code.snippets.Cancellation = .{};
    var resolver: ResolverHook = .{ .state = &state, .document = document, .broker = broker, .mode = mode, .cancellation = &cancellation };
    try state.presenter.enableSnippets(.{ .expansion = .{ .resolver = .{ .context = &resolver, .resolve = ResolverHook.resolve }, .cancellation = &cancellation } });
    _ = try adapter.setSelection(.{}, .downstream);
    try state.presenter.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try adapter.bind(state.window);
    defer adapter.unbind() catch unreachable;
    if (builtin.os.tag == .windows) state.window.show();
    const item: code.Completion = .{ .label = "nested", .insertion = .{ .snippet = 0 }, .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "${1:A${2:${NAME}}} $1 $2$0" }} };
    try publish(broker, .{ .completion = &.{item} }, 0);
    try state.presenter.prepare(bounds, state.parameters);
    const revision = try document.version();
    if (mode == .normal) {
        const outcome = try state.presenter.acceptCompletionOutcome(0);
        try std.testing.expect(outcome.snippet_active and !outcome.stale_after_commit);
        try std.testing.expectEqual(revision + 1, outcome.committed_revision);
        try expectText(document, "A猫 A猫 猫");
        try std.testing.expectError(error.ClientsAlive, state.presenter.snippet_session.?.close());
        try std.testing.expectError(error.ClientsAlive, state.presenter.snippet_template.?.close());
        try state.presenter.prepare(bounds, state.parameters);
        try std.testing.expect(broker.stored[@intFromEnum(code.Kind.completion)] == null);
        try state.paint();
        try state.key(0x09, 0xff09);
        try state.commitByte('x');
        try expectText(document, "Ax Ax x");
        try std.testing.expectEqual(@as(usize, 3), try document.selectionCount());
        try std.testing.expect(try state.presenter.handleEvent(.{ .key_input = .{ .key = .tab, .modifiers = .{ .shift = true } } }, bounds, state.parameters));
        try state.commitByte('p');
        try expectText(document, "p p x");
        try state.key(0x09, 0xff09);
        try std.testing.expectEqual(@as(usize, 1), try document.selectionCount());
        try state.commitByte('q');
        try expectText(document, "p p q");
        try state.key(0x09, 0xff09);
        try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
        for (0..4) |_| _ = try adapter.undo();
        try expectText(document, "abc");
        try std.testing.expectEqual(@as(usize, 1), resolver.calls);
        try state.presenter.prepare(bounds, state.parameters);
        try publish(broker, .{ .completion = &.{item} }, 0);
        try state.presenter.prepare(bounds, state.parameters);
        _ = try state.presenter.acceptCompletionOutcome(0);
        _ = try state.presenter.handleEvent(.{ .text_preedit = .{ .text = "候选", .selection_start = 6, .selection_end = 6 } }, bounds, state.parameters);
        try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
        try std.testing.expect(try document.composition() != null);
        _ = try state.presenter.handleEvent(.text_preedit_cancel, bounds, state.parameters);
        _ = try adapter.undo();
        try expectText(document, "abc");
        try std.testing.expectEqual(@as(usize, 2), resolver.calls);
    } else {
        const expected = switch (mode) {
            .changed => error.StaleRevision,
            .closed, .quit => error.Closed,
            .cancelled => error.Cancelled,
            .unsupported => error.UnsupportedVariable,
            .normal => unreachable,
        };
        try std.testing.expectError(expected, state.presenter.acceptCompletionOutcome(0));
        try std.testing.expectEqual(revision + @as(u64, if (mode == .changed) 1 else 0), try document.version());
        try expectText(document, if (mode == .changed) "abc!" else "abc");
        try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
        try std.testing.expectEqual(@as(usize, 1), resolver.calls);
    }
    if (state.failure) |err| return err;
    if (mode == .quit) try app.finishShutdown() else {
        _ = try state.window.destroy();
        try app.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn transformedCompletion(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc tail", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{ .metadata_history = 0 });
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    var state: State = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 240 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    state.presenter = try code.Presenter.create(allocator, broker, adapter, engine, state.window, .{});
    defer state.presenter.close() catch unreachable;
    var calls: usize = 0;
    const Variable = struct {
        fn resolve(ptr: *anyopaque, name: []const u8, writer: *code.snippets.ValueWriter) !code.snippets.Resolution {
            const count: *usize = @ptrCast(@alignCast(ptr));
            count.* += 1;
            if (!std.mem.eql(u8, name, "FILE")) return .unsupported;
            try writer.writeAll("cat.txt");
            return .value;
        }
    };
    try state.presenter.enableSnippets(.{ .session = .{ .transforms = .{} }, .expansion = .{ .resolver = .{ .context = &calls, .resolve = Variable.resolve } } });
    _ = try adapter.setSelection(.{ .anchor = 2, .caret = 2 }, .downstream);
    try state.presenter.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try adapter.bind(state.window);
    defer adapter.unbind() catch unreachable;
    if (builtin.os.tag == .windows) state.window.show();
    const item: code.Completion = .{ .label = "transform", .insertion = .{ .snippet = 1 }, .edits = &.{ .{ .range = .{ .start = 0, .end = 0 }, .text = "import;\n" }, .{ .range = .{ .start = 1, .end = 3 }, .text = "${FILE/(.*)\\..+$/${1:/upcase}/} ${1:ab} ${1/(.*)/${1:/upcase}/} ${1/(.*)/<$1>/} ${2:x}$0" }, .{ .range = .{ .start = 8, .end = 8 }, .text = "!" } } };
    try publish(broker, .{ .completion = &.{item} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    const accepted = try state.presenter.acceptCompletionOutcome(0);
    try std.testing.expect(accepted.snippet_active and !accepted.stale_after_commit);
    try expectText(document, "import;\naCAT ab ab ab x tail!");
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect(broker.stored[@intFromEnum(code.Kind.completion)] == null);
    try std.testing.expectError(error.ClientsAlive, state.presenter.snippet_template.?.close());
    try state.paint();
    const revision = try document.version();
    try state.key(0x09, 0xff09);
    try std.testing.expectEqual(revision + 1, try document.version());
    try expectText(document, "import;\naCAT ab AB <ab> x tail!");
    try std.testing.expect(try state.presenter.handleEvent(.{ .key_input = .{ .key = .tab, .modifiers = .{ .shift = true } } }, bounds, state.parameters));
    try state.commitByte('z');
    try expectText(document, "import;\naCAT z z z x tail!");
    try state.key(0x09, 0xff09);
    try expectText(document, "import;\naCAT z Z <z> x tail!");
    try state.key(0x09, 0xff09);
    try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
    for (0..4) |_| _ = try adapter.undo();
    try expectText(document, "abc tail");
    try std.testing.expectEqual(@as(usize, 1), calls);
    try state.presenter.prepare(bounds, state.parameters);
    try publish(broker, .{ .completion = &.{item} }, 2);
    try state.presenter.prepare(bounds, state.parameters);
    _ = try state.presenter.acceptCompletionOutcome(0);
    _ = try state.presenter.handleEvent(.{ .text_preedit = .{ .text = "候选", .selection_start = 6, .selection_end = 6 } }, bounds, state.parameters);
    try std.testing.expect(!(try state.presenter.snippetStatus()).active and state.presenter.snippet_template == null);
    try expectText(document, "import;\naCAT ab ab ab x tail!");
    _ = try state.presenter.handleEvent(.text_preedit_cancel, bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 2), calls);
    if (state.failure) |err| return err;
    _ = try state.window.destroy();
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn isolatedWindows() !void {
    var name: [80]u8 = undefined;
    const text = try std.fmt.bufPrint(&name, "Ziggurat.CodeEditor.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, text);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null);
    if (desktop == null) return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    command[0] = '"';
    @memcpy(command[1 .. count + 1], executable[0..count]);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
    @memcpy(command[count + 1 .. count + 1 + suffix.len], suffix);
    command[count + 1 + suffix.len] = 0;
    var startup = std.mem.zeroes(c.STARTUPINFOW);
    startup.cb = @sizeOf(c.STARTUPINFOW);
    startup.lpDesktop = &wide;
    startup.dwFlags = c.STARTF_USESTDHANDLES;
    startup.hStdInput = c.GetStdHandle(c.STD_INPUT_HANDLE);
    startup.hStdOutput = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    startup.hStdError = c.GetStdHandle(c.STD_ERROR_HANDLE);
    var process: c.PROCESS_INFORMATION = undefined;
    if (c.CreateProcessW(&executable, &command, null, null, c.TRUE, c.CREATE_NO_WINDOW, null, null, &startup, &process) == 0) return error.CreateTestProcessFailed;
    defer _ = c.CloseHandle(process.hThread);
    defer _ = c.CloseHandle(process.hProcess);
    if (c.WaitForSingleObject(process.hProcess, 60000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0 or exit_code != 0) return error.TestProcessFailed;
}
pub fn main() !void {
    if (builtin.os.tag == .windows) {
        const args = try std.process.argsAlloc(std.heap.page_allocator);
        defer std.process.argsFree(std.heap.page_allocator, args);
        if (args.len == 1) return isolatedWindows();
        if (args.len != 2 or !std.mem.eql(u8, args[1], "--desktop-child")) return error.InvalidArgument;
    }
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const before = t.resourceCounts();
    try run(debug.allocator());
    try completionSnippets(debug.allocator());
    try transformedCompletion(debug.allocator());
    inline for (std.meta.tags(@FieldType(ResolverHook, "mode"))) |mode| try nestedCompletion(debug.allocator(), mode);
    inline for (std.meta.tags(@FieldType(CompletionHook, "mode"))) |mode| try completionReentry(debug.allocator(), mode);
    try closeReentry(debug.allocator(), false);
    try closeReentry(debug.allocator(), true);
    try std.testing.expectEqual(before, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("code editor native passed: explicit worker/post, diagnostics/hover/completion pixels, native keyboard/pointer, atomic additional edits/undo, nested resolver/mirrors/close/cancel, IME, OOM, failed frame/close resources=0\n", .{});
}
