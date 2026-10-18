const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;

const ButtonEvent = extern struct {
    kind: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    axes: ?*anyopaque,
    state: c_uint,
    button: c_uint,
    device: ?*anyopaque,
    x_root: f64,
    y_root: f64,
};
const KeyEvent = extern struct {
    kind: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    state: c_uint,
    keyval: c_uint,
    length: c_int,
    string: ?[*:0]u8,
    hardware_keycode: u16,
    group: u8,
    modifier_storage: c_uint,
};
fn bounds(y: f32) ui.Rect {
    return .{ .x = 0, .y = y, .width = 180, .height = 32 };
}
const State = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    checked: bool = false,
    switched: bool = false,
    selected: u64 = 4,
    include_removed: bool = true,
    switch_enabled: bool = true,
    close_on_switch: bool = false,
    fail_frame: bool = false,
    nested_paint: bool = false,
    nested_once: bool = false,
    draws: usize = 0,
    pinned: bool = false,
    actions: [10]usize = @splat(0),
    err: ?anyerror = null,
    fn native(self: *State) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn paint(self: *State) void {
        zlg_test_paint(self.native(), 220, 380);
    }
    fn area(self: *State) *anyopaque {
        return gtk_bin_get_child(self.window.nativeHandle().?).?;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        if (self.nested_paint and !self.nested_once) {
            self.nested_once = true;
            self.paint();
        }
        self.drawChecked(frame) catch |err| {
            self.err = err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        try frame.button(1, bounds(0), "Button");
        try frame.checkbox(2, bounds(40), "Checkbox", self.checked, .{});
        try frame.checkbox(3, bounds(80), "Disabled", true, .{ .enabled = false });
        try frame.radioGroup(10, .{ .x = 0, .y = 120, .width = 180, .height = 72 }, "Mode");
        try frame.radio(4, bounds(120), "First", self.selected == 4, .{ .radio_group = 10 });
        try frame.radio(5, bounds(160), "Second", self.selected == 5, .{ .radio_group = 10 });
        try frame.toggleSwitch(6, bounds(200), "Switch", self.switched, .{ .enabled = self.switch_enabled });
        try frame.progress(7, bounds(240), 0.35, .{ .name = "Progress" });
        try frame.pushClip(.{ .x = 0, .y = 280, .width = 180, .height = 0 });
        try frame.checkbox(8, bounds(280), "Clipped", false, .{});
        try frame.popClip();
        if (self.include_removed) try frame.checkbox(9, bounds(320), "Removed", false, .{});
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.window.app.assertOwner();
        if (id >= self.actions.len) {
            self.err = error.UnexpectedAction;
            return;
        }
        self.actions[@intCast(id)] += 1;
        switch (id) {
            1, 9 => {},
            2 => self.checked = !self.checked,
            4, 5 => self.selected = id,
            6 => {
                self.switched = !self.switched;
                if (self.close_on_switch) {
                    _ = self.window.destroy() catch |err| {
                        self.err = err;
                        return;
                    };
                    self.pinned = self.window.isClosed() and self.context.window != null;
                }
            },
            else => self.err = error.UnexpectedAction,
        }
    }
    fn pointer(self: *State, down: bool, y: f64) !void {
        const event = gdk_event_new(if (down) 4 else 7) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const widget = self.area();
        const native_event: *ButtonEvent = @ptrCast(@alignCast(event));
        native_event.* = .{ .kind = if (down) 4 else 7, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = 10, .y = y + 10, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, if (down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), native_event, &handled);
        try std.testing.expect(handled != 0);
    }
    fn click(self: *State, y: f64) !void {
        try self.pointer(true, y);
        try self.pointer(false, y);
    }
    fn key(self: *State, keyval: c_uint) !void {
        const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const widget = self.area();
        const native_event: *KeyEvent = @ptrCast(@alignCast(event));
        native_event.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = 0, .keyval = keyval, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "key-press-event", native_event, &handled);
        try std.testing.expect(handled != 0);
    }
};
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    {
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        var state: State = .{};
        state.window = try app.createWindow(.{ .width = 220, .height = 380 });
        state.context = ui.Context.init(&state, State.draw, State.action);
        try state.context.attach(state.window);
        try std.testing.expect(!(try state.window.state()).visible);
        state.paint();
        try std.testing.expect(state.context.hasSurface());
        const draws = state.draws;
        const command_count = state.context.command_buffer.len;
        state.nested_paint = true;
        state.paint();
        try std.testing.expectEqual(draws + 1, state.draws);
        try std.testing.expectEqual(command_count, state.context.command_buffer.len);
        try std.testing.expectEqual(@as(usize, 9), state.context.input_state.len);
        try std.testing.expect(!state.context.painting and !state.context.repaint_pending);
        state.nested_paint = false;
        try state.click(40);
        try state.click(40);
        try state.click(40);
        try std.testing.expect(state.checked and state.actions[2] == 3);
        try state.click(80);
        try state.click(240);
        try state.click(280);
        try std.testing.expectEqual(@as(usize, 0), state.actions[3] + state.actions[7] + state.actions[8]);
        try state.click(40);
        try state.key(0xff09);
        try std.testing.expectEqual(@as(?u64, 4), state.context.input_state.focused);
        try state.key(0xff53);
        try std.testing.expectEqual(@as(u64, 5), state.selected);
        try state.key(0xff50);
        try std.testing.expectEqual(@as(u64, 4), state.selected);
        try state.key(0xff57);
        try std.testing.expectEqual(@as(u64, 5), state.selected);
        try state.key(0xff09);
        try std.testing.expectEqual(@as(?u64, 6), state.context.input_state.focused);
        try state.key(0x20);
        try std.testing.expect(state.switched);
        try state.key(0xff09);
        try std.testing.expectEqual(@as(?u64, 9), state.context.input_state.focused);
        state.include_removed = false;
        state.fail_frame = true;
        state.paint();
        try std.testing.expect(state.context.input_state.available(9));
        state.include_removed = true;
        state.fail_frame = false;
        state.paint();
        try state.pointer(true, 320);
        state.include_removed = false;
        state.paint();
        try state.pointer(false, 320);
        try state.key(0x20);
        try std.testing.expectEqual(@as(usize, 0), state.actions[9]);
        try state.pointer(true, 200);
        state.switch_enabled = false;
        state.paint();
        try state.pointer(false, 200);
        try std.testing.expectEqual(@as(usize, 1), state.actions[6]);
        state.switch_enabled = true;
        state.close_on_switch = true;
        state.paint();
        try state.click(200);
        try std.testing.expect(state.pinned and state.context.window != null);
        try app.dispatch();
        try std.testing.expect(state.context.window == null and state.err == null);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("Linux widgets smoke passed: GTK pointer/keyboard, checkbox/radio/switch/progress, disabled/clipped/removed/failed frame, callback close; native resources=0\n", .{});
}
