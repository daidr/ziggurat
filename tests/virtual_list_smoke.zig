const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const virtual = @import("ziggurat_virtual_list");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const ScrollEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, state: c_uint, direction: c_int, device: ?*anyopaque, x_root: f64, y_root: f64, delta_x: f64, delta_y: f64, stop_storage: c_uint };
const viewport: ui.Rect = .{ .x = 10, .y = 10, .width = 200, .height = 96 };
const selected_color = 0x3399cc;
const normal_color = 0x226644;
const Mode = enum { normal, callback_error, frame_error, clips, offsets, full, capacity, closed };
const State = struct {
    window: z.Window = undefined,
    list: ?*virtual.List,
    ui_context: ui.Context = undefined,
    scroll: f64 = 0,
    selected: u64 = 1,
    action_id: u64 = 0,
    callbacks: usize = 0,
    mode: Mode = .normal,
    expected: ?anyerror = null,
    diagnostics: usize = 0,
    err: ?anyerror = null,
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        // Compare unwrapped error payloads; see docs/toolchain-known-issues.md.
        const matches = if (value.err) |actual| if (self.expected) |wanted| actual == wanted else false else false;
        if (matches) self.diagnostics += 1 else self.err = value.err orelse error.UnexpectedDiagnostic;
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.list.?.close() catch |err| {
            self.err = err;
            return;
        };
        self.list = null;
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.action_id = id;
        if ((self.list.?.indexOf(id) catch return) != null) self.selected = id;
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.handle(event) catch |err| {
            self.err = err;
        };
        return event == .wheel or event == .key_input;
    }
    fn handle(self: *State, event: z.Event) !void {
        const list = self.list.?;
        switch (event) {
            .wheel => |motion| {
                self.scroll = try list.clampScroll(self.scroll + motion.delta.y, viewport.height);
                self.window.invalidate();
            },
            .key_input => |input_key| {
                const at = (try list.indexOf(self.selected)) orelse 0;
                const next = switch (input_key.key) {
                    .down => @min((try list.count()) - 1, at + 1),
                    .up => at -| 1,
                    .end => (try list.count()) - 1,
                    .home => 0,
                    else => return,
                };
                self.selected = (try list.row(next)).id;
                self.scroll = try list.reveal(self.selected, self.scroll, viewport.height, .nearest);
                self.window.invalidate();
            },
            else => {},
        }
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.callbacks = 0;
        self.paintList(frame) catch |err| {
            self.err = err;
        };
    }
    fn paintList(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        try frame.pushClip(.{ .x = 0, .y = 0, .width = 250, .height = 140 });
        try frame.pushOffset(.{ .x = 1, .y = 2 });
        const result = self.list.?.render(frame, if (self.mode == .full) .{ .x = 10, .y = 10, .width = 200, .height = 10 } else viewport, self.scroll, .{ .overscan = if (self.mode == .full) 0 else 2, .max_visible = if (self.mode == .capacity) 1 else 128 }, .{ .context = self, .draw = row });
        try std.testing.expectEqual(@as(usize, 1), frame.clips.len);
        try std.testing.expectEqual(@as(usize, 1), frame.offset_depth);
        try std.testing.expectEqual(ui.layout.Point{ .x = 1, .y = 2 }, frame.offset);
        if (self.expected) |expected| try std.testing.expectError(expected, result) else {
            const range = try result;
            try std.testing.expect(self.callbacks > 0 and self.callbacks <= 128);
            try std.testing.expectEqual(self.callbacks, range.end - range.first);
        }
        try frame.popOffset();
        frame.popClip() catch |err| {
            if (self.mode != .full or err != error.CommandsFull) return err;
        };
    }
    fn row(ptr: *anyopaque, frame: *ui.Frame, value: virtual.RowView) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.callbacks += 1;
        try std.testing.expectError(error.Busy, self.list.?.close());
        try std.testing.expectError(error.Busy, self.list.?.replace(&.{}));
        try std.testing.expectError(error.Busy, self.list.?.setHeight(value.id, 10));
        try std.testing.expectError(error.Busy, self.list.?.render(frame, viewport, 0, .{}, .{ .context = self, .draw = row }));
        try frame.button(if (self.mode == .normal or self.mode == .closed) value.id else value.id + 10000, value.bounds, "");
        frame.rect(value.visible_bounds, if (value.id == self.selected) selected_color else normal_color);
        switch (self.mode) {
            .normal, .capacity => {},
            .callback_error => return error.RowFailure,
            .frame_error => frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0),
            .clips => try frame.pushClip(value.visible_bounds),
            .offsets => try frame.pushOffset(.{ .y = 8 }),
            .full => while (frame.context.command_buffer.len < frame.context.command_buffer.storage.len) frame.rect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, 0),
            .closed => try std.testing.expectEqual(z.CloseResult.deferred, try self.window.destroy()),
        }
    }
    fn nativePaint(self: *State) !void {
        if (builtin.os.tag == .windows) {
            _ = c.InvalidateRect(self.window.nativeHandle(), null, 0);
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        } else {
            const scale: u32 = @intCast(gtk_widget_get_scale_factor(self.window.nativeHandle().?));
            zlg_test_paint(self.window.app.windows.get(self.window.key).?.native.native.?, 260 * scale, 160 * scale);
        }
        if (self.err) |err| return err;
    }
    fn pixel(self: *State, x: u32, y: u32) !u32 {
        if (builtin.os.tag == .windows) {
            const value = c.GetPixel(self.ui_context.renderer.dc, @intCast(x), @intCast(y));
            if (value == c.CLR_INVALID) return error.NoPixel;
            return ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
        }
        return zlc_test_raw_pixel(self.ui_context.renderer.native.?, x, y);
    }
};
fn area(window: z.Window) *anyopaque {
    return gtk_bin_get_child(window.nativeHandle().?).?;
}
fn click(window: z.Window, x: f32, y: f32) !void {
    if (builtin.os.tag == .windows) {
        const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96;
        const px: u16 = @bitCast(@as(i16, @intFromFloat(x * scale)));
        const py: u16 = @bitCast(@as(i16, @intFromFloat(y * scale)));
        const point: c.LPARAM = @intCast(@as(u32, px) | (@as(u32, py) << 16));
        _ = c.SendMessageW(window.nativeHandle(), c.WM_LBUTTONDOWN, 0, point);
        _ = c.SendMessageW(window.nativeHandle(), c.WM_LBUTTONUP, 0, point);
    } else {
        const event = gdk_event_new(4) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const native: *ButtonEvent = @ptrCast(@alignCast(event));
        native.* = .{ .kind = 4, .window = g_object_ref(gtk_widget_get_window(area(window)).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(area(window), "button-press-event", native, &handled);
        native.kind = 7;
        g_signal_emit_by_name(area(window), "button-release-event", native, &handled);
    }
}
fn wheel(window: z.Window) !void {
    if (builtin.os.tag == .windows) _ = c.SendMessageW(window.nativeHandle(), c.WM_MOUSEWHEEL, @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16, 0) else {
        const event = gdk_event_new(31) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const native: *ScrollEvent = @ptrCast(@alignCast(event));
        native.* = .{ .kind = 31, .window = g_object_ref(gtk_widget_get_window(area(window)).?), .send_event = 1, .time = 0, .x = 20, .y = 20, .state = 0, .direction = 1, .device = null, .x_root = 0, .y_root = 0, .delta_x = 0, .delta_y = 1, .stop_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(area(window), "scroll-event", native, &handled);
    }
}
fn key(window: z.Window, end: bool) !void {
    if (builtin.os.tag == .windows) _ = c.SendMessageW(window.nativeHandle(), c.WM_KEYDOWN, if (end) c.VK_END else c.VK_DOWN, 0) else {
        const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const native: *KeyEvent = @ptrCast(@alignCast(event));
        native.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(area(window)).?), .send_event = 1, .time = 0, .state = 0, .keyval = if (end) 0xff57 else 0xff54, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(area(window), "key-press-event", native, &handled);
    }
}
fn cycle(allocator: std.mem.Allocator) !void {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var rows: [1000]virtual.Row = undefined;
    for (&rows, 0..) |*row, index| row.* = .{ .id = index + 1, .height = if (index % 2 == 0) 20 else 30 };
    var state: State = .{ .list = try virtual.List.create(failing.allocator(), std.Thread.getCurrentId(), &rows, .{}) };
    defer if (state.list) |list| list.close() catch unreachable;
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 260, .height = 160, .on_closed = .{ .context = &state, .notify = State.closed } });
    state.ui_context = ui.Context.init(&state, State.draw, State.action);
    state.ui_context.render_mode = .gdi;
    state.ui_context.on_input = State.input;
    try state.ui_context.attach(state.window);
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    try state.nativePaint();
    const scale = state.ui_context.last_paint_size.?.scale;
    try std.testing.expectEqual(@as(u32, selected_color), try state.pixel(@intFromFloat(16 * scale), @intFromFloat(16 * scale)));
    try click(state.window, 20, 40);
    try std.testing.expectEqual(@as(u64, 2), state.action_id);
    try state.nativePaint();
    try std.testing.expectEqual(@as(u32, selected_color), try state.pixel(@intFromFloat(20 * scale), @intFromFloat(40 * scale)));
    try wheel(state.window);
    try std.testing.expectEqual(@as(f64, 48), state.scroll);
    try key(state.window, true);
    try std.testing.expectEqual(@as(u64, 1000), state.selected);
    try std.testing.expectEqual((try state.list.?.visibleRange(state.scroll, viewport.height)).end, 1000);
    try state.nativePaint();
    try std.testing.expectEqual(allocations, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    // Stable selection follows ID across reorder; anchor resolves independently.
    const place = try state.list.?.anchor(state.scroll, viewport.height);
    std.mem.reverse(virtual.Row, &rows);
    try state.list.?.replace(&rows);
    state.scroll = try state.list.?.resolve(place, viewport.height);
    try std.testing.expectEqual(@as(u64, 1000), state.selected);
    state.scroll = 0;
    try state.nativePaint();
    for ([_]Mode{ .callback_error, .frame_error, .clips, .offsets, .full, .capacity }) |mode| {
        const previous = state.ui_context.frames;
        state.mode = mode;
        state.expected = switch (mode) {
            .callback_error => error.RowFailure,
            .frame_error => error.InvalidGeometry,
            .full => error.CommandsFull,
            .capacity => error.VisibleCapacityExceeded,
            else => error.UnbalancedRowFrame,
        };
        try state.nativePaint();
        try std.testing.expectEqual(previous, state.ui_context.frames);
        try std.testing.expectEqual(@as(usize, if (mode == .capacity) 0 else 1), state.callbacks);
        // Failed rows never publish their hit snapshot; the last frame's row
        // remains clickable even when a failed paint built a different region.
        state.mode = .normal;
        state.expected = null;
        state.action_id = 0;
        try click(state.window, 20, 20);
        try std.testing.expectEqual(@as(u64, 1000), state.action_id);
    }
    state.mode = .closed;
    state.expected = error.Closed;
    try state.nativePaint();
    try app.dispatch();
    try std.testing.expect(state.list == null and state.ui_context.window == null);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    // One per failing mode. The callback-closed frame is discarded silently:
    // closure in progress is not a paint failure.
    try std.testing.expectEqual(@as(usize, 6), state.diagnostics);
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try cycle(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("virtual list native passed: real Frame pixels, pointer/wheel/keyboard stable ID and reveal, Busy/no allocation, failed frame/clips/offsets/capacity/close; resources=0\n", .{});
}
