const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const shared = @import("affine_ui_shared.zig");
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_resource_count() u32;
extern fn zlc_layer_test_pixel(*anyopaque, c_int, u32, u32) u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const MotionEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, is_hint: i16, device: ?*anyopaque, x_root: f64, y_root: f64 };
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const FocusEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, active: i16 };
const Native = struct {
    fn native(window: z.Window) *anyopaque {
        return window.app.windows.get(window.key).?.native.native.?;
    }
    fn area(window: z.Window) *anyopaque {
        return gtk_bin_get_child(window.nativeHandle().?).?;
    }
    pub fn paint(window: z.Window) void {
        const size = window.contentSize() catch unreachable;
        // GTK allocations use logical pixels; contentSize is physical.
        const factor: u32 = @intFromFloat(size.scale);
        std.debug.assert(factor != 0 and size.width % factor == 0 and size.height % factor == 0);
        zlg_test_paint(native(window), size.width / factor, size.height / factor);
        if (!window.isClosed()) std.debug.assert(std.meta.eql(size, window.contentSize() catch unreachable));
    }
    pub fn pointer(window: z.Window, phase: enum { down, move, up }, point: z.Point) !void {
        const widget = area(window);
        const event = gdk_event_new(if (phase == .move) 3 else if (phase == .down) 4 else 7) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        var handled: c_int = 0;
        if (phase == .move) {
            const motion: *MotionEvent = @ptrCast(@alignCast(event));
            motion.* = .{ .kind = 3, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = point.x, .y = point.y, .axes = null, .state = 1 << 8, .is_hint = 0, .device = null, .x_root = 0, .y_root = 0 };
            g_signal_emit_by_name(widget, "motion-notify-event", motion, &handled);
        } else {
            const button: *ButtonEvent = @ptrCast(@alignCast(event));
            button.* = .{ .kind = if (phase == .down) 4 else 7, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = point.x, .y = point.y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
            g_signal_emit_by_name(widget, if (phase == .down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), button, &handled);
        }
        try std.testing.expect(handled != 0);
    }
    pub fn click(window: z.Window, point: z.Point) !void {
        try pointer(window, .down, point);
        try pointer(window, .up, point);
    }
    pub fn key(window: z.Window, key_code: z.KeyCode) void {
        const widget = area(window);
        const event = gdk_event_new(8) orelse unreachable;
        defer gdk_event_free(event);
        const key_event: *KeyEvent = @ptrCast(@alignCast(event));
        key_event.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = 0, .keyval = if (key_code == .space) 0x20 else 0xff09, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "key-press-event", key_event, &handled);
    }
    pub fn text(window: z.Window) void {
        zlg_test_commit(native(window), "中");
    }
    pub fn focus(window: z.Window) void {
        const widget = area(window);
        const event = gdk_event_new(12) orelse unreachable;
        defer gdk_event_free(event);
        const focus_event: *FocusEvent = @ptrCast(@alignCast(event));
        focus_event.* = .{ .kind = 12, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .active = 1 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "focus-in-event", focus_event, &handled);
    }
    pub fn pixel(context: *ui.Context) !u32 {
        return zlc_layer_test_pixel(context.renderer.native.?, 1, 0, 0);
    }
    pub fn checkCaret(_: z.Window, token: ui.SpaceToken, caret: ui.Rect) !void {
        // This validates native cursor-location submission, not an IME candidate UI.
        try token.setTextCaret(caret);
    }
};
const State = shared.Suite(Native);
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    {
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        var state: State = .{};
        try state.init(app, allocator.allocator());
        defer state.editor.deinit();
        defer {
            if (!state.window.isClosed()) _ = state.window.destroy() catch {};
        }
        try state.exercise();
        try State.reentry(app, allocator.allocator());
        _ = try state.window.destroy();
        try std.testing.expectEqual(@as(usize, 1), state.closed);
        try std.testing.expect(state.context == null);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("Linux affine UI passed: GTK transformed controls/editor/IM commit, native caret submission, failed frame/release, immediate Context free; native resources=0\n", .{});
}
