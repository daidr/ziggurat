const std = @import("std");
const z = @import("ziggurat");
const shared = @import("widget_ranges_shared.zig");
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gtk_widget_has_grab(*anyopaque) c_int;
extern fn gtk_grab_remove(*anyopaque) void;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const MotionEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, is_hint: i16, device: ?*anyopaque, x_root: f64, y_root: f64 };
const FocusEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, active: i16 };
const Native = struct {
    fn area(window: z.Window) *anyopaque {
        return gtk_bin_get_child(window.nativeHandle().?).?;
    }
    pub fn paint(window: z.Window) void {
        zlg_test_paint(window.app.windows.get(window.key).?.native.native.?, 320, 300);
    }
    pub fn pointer(window: z.Window, phase: enum { down, move, up }, x: f32, y: f32) !void {
        const widget = area(window);
        const event = gdk_event_new(if (phase == .move) 3 else if (phase == .down) 4 else 7) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        var handled: c_int = 0;
        if (phase == .move) {
            const native: *MotionEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 3, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 1 << 8, .is_hint = 0, .device = null, .x_root = 0, .y_root = 0 };
            g_signal_emit_by_name(widget, "motion-notify-event", native, &handled);
        } else {
            const native: *ButtonEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = if (phase == .down) 4 else 7, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
            g_signal_emit_by_name(widget, if (phase == .down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), native, &handled);
        }
        try std.testing.expect(handled != 0);
        if (phase == .down and !window.isClosed()) try std.testing.expect(gtk_widget_has_grab(widget) != 0);
    }
    pub fn click(window: z.Window, x: f32, y: f32) !void {
        try pointer(window, .down, x, y);
        try pointer(window, .up, x, y);
    }
    pub fn cancel(window: z.Window) void {
        const widget = area(window);
        if (gtk_widget_has_grab(widget) != 0) gtk_grab_remove(widget);
        const event = gdk_event_new(12) orelse unreachable;
        defer gdk_event_free(event);
        const native: *FocusEvent = @ptrCast(@alignCast(event));
        native.* = .{ .kind = 12, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .active = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "focus-out-event", native, &handled);
        native.active = 1;
        g_signal_emit_by_name(widget, "focus-in-event", native, &handled);
    }
    pub fn key(window: z.Window, input: z.KeyInput) !void {
        const keyval: c_uint = switch (input.key) {
            .left => 0xff51,
            .right => 0xff53,
            .up => 0xff52,
            .down => 0xff54,
            .home => 0xff50,
            .end => 0xff57,
            .page_up => 0xff55,
            .page_down => 0xff56,
            .tab => 0xff09,
            .space => 0x20,
            .enter => 0xff0d,
            .s => 's',
            .q => 'q',
            .c => 'c',
            .f2 => 0xffbf,
            .f3 => 0xffc0,
            else => return error.UnsupportedTestKey,
        };
        const widget = area(window);
        const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const native: *KeyEvent = @ptrCast(@alignCast(event));
        native.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = (if (input.modifiers.shift) @as(c_uint, 1) else 0) | (if (input.modifiers.control) @as(c_uint, 4) else 0) | (if (input.modifiers.alt) @as(c_uint, 8) else 0), .keyval = keyval, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "key-press-event", native, &handled);
    }
};
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    try shared.run(Native, allocator.allocator());
    try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("Linux range widgets native smoke passed: GTK capture/keys, paired bounds, step zones, shortcuts/editor, disable/remove/failure/close; native resources=0\n", .{});
}
