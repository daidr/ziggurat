const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const virtual = @import("ziggurat_virtual_list");
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gtk_widget_grab_focus(*anyopaque) void;
extern fn gdk_window_focus(*anyopaque, u32) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlg_resource_count() u32;
const Button = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*f64, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const Motion = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*f64, state: c_uint, is_hint: i16, device: ?*anyopaque, x_root: f64, y_root: f64 };
const Key = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const Scroll = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, state: c_uint, direction: c_int, device: ?*anyopaque, x_root: f64, y_root: f64, delta_x: f64, delta_y: f64, stop_storage: c_uint };
const Focus = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, gained: i16 };
const bounds: ui.Rect = .{ .x = 10, .y = 10, .width = 180, .height = 60 };
const Native = struct {
    fn area(window: z.Window) !*anyopaque {
        return gtk_bin_get_child(window.nativeHandle().?) orelse error.MissingArea;
    }
    fn button(window: z.Window, down: bool, y: f64, time: u32) !void {
        const widget = g_object_ref(try area(window));
        defer g_object_unref(widget);
        const native = g_object_ref(gtk_widget_get_window(widget).?);
        defer g_object_unref(native);
        var event: Button = .{ .kind = if (down) 4 else 7, .window = native, .send_event = 1, .time = time, .x = 20, .y = y, .axes = null, .state = if (down) 0 else 1 << 8, .button = 1, .device = null, .x_root = 20, .y_root = y };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, if (down) "button-press-event" else "button-release-event", &event, &handled);
    }
    fn move(window: z.Window, y: f64, time: u32) !void {
        const widget = g_object_ref(try area(window));
        defer g_object_unref(widget);
        const native = g_object_ref(gtk_widget_get_window(widget).?);
        defer g_object_unref(native);
        var event: Motion = .{ .kind = 3, .window = native, .send_event = 1, .time = time, .x = 20, .y = y, .axes = null, .state = 1 << 8, .is_hint = 0, .device = null, .x_root = 20, .y_root = y };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "motion-notify-event", &event, &handled);
    }
    fn key(window: z.Window, keyval: u32, shift: bool) !void {
        const widget = try area(window);
        var event: Key = .{ .kind = 8, .window = gtk_widget_get_window(widget), .send_event = 1, .time = 0, .state = @intFromBool(shift), .keyval = keyval, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "key-press-event", &event, &handled);
    }
    fn wheel(window: z.Window) !void {
        const widget = try area(window);
        var event: Scroll = .{ .kind = 31, .window = gtk_widget_get_window(widget), .send_event = 1, .time = 0, .x = 20, .y = 20, .state = 0, .direction = 1, .device = null, .x_root = 20, .y_root = 20, .delta_x = 0, .delta_y = 1, .stop_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "scroll-event", &event, &handled);
    }
    fn focusOut(window: z.Window) !void {
        const widget = try area(window);
        var event: Focus = .{ .kind = 12, .window = gtk_widget_get_window(widget), .send_event = 1, .gained = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(widget, "focus-out-event", &event, &handled);
    }
    fn paint(window: z.Window) !void {
        const surface = cairo_image_surface_create(0, 220, 110) orelse return error.SurfaceFailed;
        defer cairo_surface_destroy(surface);
        const cr = cairo_create(surface) orelse return error.ContextFailed;
        defer cairo_destroy(cr);
        var handled: c_int = 0;
        g_signal_emit_by_name(try area(window), "draw", cr, &handled);
    }
};
const Host = struct {
    app: *z.App = undefined,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    control: *virtual.Control = undefined,
    failure: ?anyerror = null,
    started: bool = false,
    wakes: usize = 0,
    stops: usize = 0,
    step: u8 = 0,
    expected_diagnostics: usize = 0,
    diagnostics: usize = 0,
    reject: bool = false,
    allocations: *std.testing.FailingAllocator,
    initial_allocations: usize = 0,
    fn fail(self: *Host, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Linux Control stage={d}: {s}\n", .{ self.step, @errorName(err) });
        self.app.quit();
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.diagnostics += 1;
        if (self.diagnostics > self.expected_diagnostics) self.fail(value.err orelse error.UnexpectedDiagnostic);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        _ = self.control.draw(frame, bounds, "List", .{ .context = self, .draw = row }, .{ .overscan = 0 }) catch |err| {
            self.fail(err);
            return;
        };
        if (self.reject) frame.failure = error.ListCandidateRejected;
    }
    fn row(_: *anyopaque, frame: *ui.Frame, value: virtual.Control.RowView) !void {
        frame.rect(value.row.visible_bounds, if (value.selected) 0x3399cc else 0x226644);
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (!self.started and event == .focus and event.focus) {
            self.started = true;
            self.app.post(.{ .context = self, .call = begin }) catch |err| self.fail(err);
        }
        return false;
    }
    fn edge(ptr: ?*anyopaque, _: z.Window, _: *virtual.Control, start: bool) void {
        const self: *Host = @ptrCast(@alignCast(ptr.?));
        if (start) {
            self.wakes += 1;
            self.app.post(.{ .context = self, .call = deadline }) catch |err| self.fail(err);
        } else self.stops += 1;
    }
    fn begin(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.beginChecked() catch |err| self.fail(err);
    }
    fn beginChecked(self: *Host) !void {
        try Native.paint(self.window);
        try Native.button(self.window, true, 15, 100);
        try Native.button(self.window, false, 15, 101);
        try std.testing.expect(try self.control.selected(1));
        try Native.key(self.window, 0xff54, true);
        try Native.key(self.window, 0xff54, true);
        try std.testing.expectEqual(@as(usize, 3), try self.control.selectedCount());
        try Native.wheel(self.window);
        try std.testing.expectEqual(@as(f64, 48), try self.control.scrollOffset(bounds.height));
        self.reject = true;
        self.expected_diagnostics += 1;
        const generation = self.context.space_generation;
        try Native.paint(self.window);
        try std.testing.expectEqual(generation, self.context.space_generation);
        try Native.button(self.window, true, 15, 150);
        try Native.button(self.window, false, 15, 151);
        try std.testing.expect(try self.control.selected(1));
        self.reject = false;
        _ = try self.control.setScroll(0, bounds.height);
        try Native.paint(self.window);
        try Native.button(self.window, true, 15, 200);
        try Native.move(self.window, 95, 201);
        try std.testing.expectEqual(@as(usize, 1), self.wakes);
        try std.testing.expectEqual(@as(u64, 6), (try self.control.caret()).?.id);
        try std.testing.expectEqual(@as(f64, 0), try self.control.scrollOffset(bounds.height));
    }
    fn deadline(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.deadlineChecked() catch |err| self.fail(err);
    }
    fn deadlineChecked(self: *Host) !void {
        if (self.failure) |err| return err;
        if (self.step == 0) {
            // This task is outside native down/up; it must use held authority.
            _ = try self.control.advanceDragScrolling(0.1);
            try std.testing.expectEqual(@as(u64, 11), (try self.control.caret()).?.id);
            // A second explicit business deadline advances without paint.
            _ = try self.control.advanceDragScrolling(0.1);
            try std.testing.expectEqual(@as(u64, 16), (try self.control.caret()).?.id);
            try Native.paint(self.window);
            try std.testing.expect((try self.control.scrollOffset(bounds.height)) > 0);
            try std.testing.expect((try self.control.caret()).?.id > 6);
            try Native.button(self.window, false, 95, 220);
            std.debug.print("edge first release wakes={d} stops={d} active={any}\n", .{ self.wakes, self.stops, self.context.input_state.active });
            try std.testing.expectEqual(@as(usize, 1), self.stops);
            try Native.button(self.window, true, 15, 300);
            try Native.move(self.window, 95, 301);
            std.debug.print("edge second move wakes={d} stops={d} active={any} drag={any}\n", .{ self.wakes, self.stops, self.context.input_state.active, self.control.drag });
            try std.testing.expectEqual(@as(usize, 2), self.wakes);
            try Native.focusOut(self.window);
            std.debug.print("edge focus out wakes={d} stops={d} active={any} drag={any}\n", .{ self.wakes, self.stops, self.context.input_state.active, self.control.drag });
            try std.testing.expect(self.context.input_state.active == null);
            try std.testing.expectEqual(@as(usize, 2), self.stops);
            self.step = 1;
            return;
        }
        const scroll = try self.control.scrollOffset(bounds.height);
        _ = try self.control.advanceDragScrolling(0.1);
        try std.testing.expectEqual(scroll, try self.control.scrollOffset(bounds.height));
        try std.testing.expectEqual(self.initial_allocations, self.allocations.alloc_index);
        try std.testing.expect(!self.allocations.has_induced_failure);
        try std.testing.expectEqual(self.expected_diagnostics, self.diagnostics);
        self.step = 2;
        self.app.quit();
    }
    fn focus(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.window.perform(.show) catch |err| return self.fail(err);
        gtk_widget_grab_focus(Native.area(self.window) catch |err| return self.fail(err));
        gdk_window_focus(gtk_widget_get_window(self.window.nativeHandle().?).?, 0);
    }
};

fn scenario(allocator: std.mem.Allocator) !void {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var rows: [100]virtual.Row = undefined;
    for (&rows, 0..) |*value, index| value.* = .{ .id = index + 1, .height = 10 };
    var host: Host = .{ .allocations = &failing };
    host.control = try virtual.Control.create(failing.allocator(), std.Thread.getCurrentId(), &rows, .{ .context = &host, .edge_scroll = Host.edge });
    defer host.control.close() catch unreachable;
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    const app_native_baseline = zlg_resource_count();
    host.app = app;
    host.window = try app.createWindow(.{ .width = 220, .height = 110, .native_pointer_clicks = true });
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.render_mode = .gdi;
    host.context.semantics_enabled = false;
    host.context.on_input = Host.input;
    try host.context.attach(host.window);
    try host.context.prepareRecipients(allocator, .{ .recipients = 4 });
    try std.testing.expectError(error.UnsupportedPlatform, host.context.prepareVirtualLists(.{}));
    try host.control.attach(&host.context, 7);
    host.initial_allocations = failing.alloc_index;
    failing.fail_index = failing.alloc_index;
    try app.post(.{ .context = &host, .call = Host.focus });
    try app.run();
    if (host.failure) |err| return err;
    try std.testing.expectEqual(@as(u8, 2), host.step);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try std.testing.expectEqual(app_native_baseline, zlg_resource_count());
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try scenario(gpa.allocator());
    try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("Linux List Control: native pointer/key/wheel, old successful scroll receipt, explicit deadline held drag + focus cancel, no Control allocator use, native full collection UnsupportedPlatform; resources=0\n", .{});
}
