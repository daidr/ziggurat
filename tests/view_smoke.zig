const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ScrollEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, state: c_uint, direction: c_int, device: ?*anyopaque, x_root: f64, y_root: f64, delta_x: f64, delta_y: f64, is_stop: c_uint };
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };

const width = 360;
const height = 480;

const Native = struct {
    fn paint(window: z.Window) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            _ = c.InvalidateRect(hwnd, null, 0);
            _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        } else {
            const scope = window.beginCallback().?;
            defer scope.end();
            zlg_test_paint(scope.record.native.native.?, width, height);
        }
    }
    fn pointer(window: z.Window, down: bool, x: f32, y: f32) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            const px: u16 = @bitCast(@as(i16, @intFromFloat(x * scale)));
            const py: u16 = @bitCast(@as(i16, @intFromFloat(y * scale)));
            const point: c.LPARAM = @intCast(@as(u32, px) | (@as(u32, py) << 16));
            _ = c.SendMessageW(hwnd, if (down) c.WM_LBUTTONDOWN else c.WM_LBUTTONUP, 0, point);
        } else {
            const widget = gtk_bin_get_child(window.nativeHandle().?).?;
            const event = gdk_event_new(if (down) 4 else 7).?;
            defer gdk_event_free(event);
            const native: *ButtonEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = if (down) 4 else 7, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, if (down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), native, &handled);
        }
    }
    /// One wheel notch downwards at a point, which both backends report as 48 DIP.
    fn wheelDown(window: z.Window, x: f32, y: f32) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            var screen: c.POINT = .{ .x = @intFromFloat(x * scale), .y = @intFromFloat(y * scale) };
            _ = c.ClientToScreen(hwnd, &screen);
            const px: u16 = @bitCast(@as(i16, @intCast(screen.x)));
            const py: u16 = @bitCast(@as(i16, @intCast(screen.y)));
            const notch: u16 = @bitCast(@as(i16, -120));
            _ = c.SendMessageW(hwnd, c.WM_MOUSEWHEEL, @as(c.WPARAM, notch) << 16, @intCast(@as(u32, px) | (@as(u32, py) << 16)));
        } else {
            const widget = gtk_bin_get_child(window.nativeHandle().?).?;
            const event = gdk_event_new(31).?;
            defer gdk_event_free(event);
            const native: *ScrollEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 31, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .state = 0, .direction = 1, .device = null, .x_root = 0, .y_root = 0, .delta_x = 0, .delta_y = 0, .is_stop = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "scroll-event", native, &handled);
        }
    }
    fn click(window: z.Window, bounds: view.Rect) void {
        const x = bounds.x + bounds.width / 2;
        const y = bounds.y + bounds.height / 2;
        pointer(window, true, x, y);
        pointer(window, false, x, y);
    }
};

const State = struct {
    count: usize = 0,
    agreed: bool = false,
    level: f64 = 0,
    rows: usize = 2,
    mode: enum { list, grid } = .list,
    amount: f64 = 3,
    list: view.ScrollModel = .{},
    fn build(self: *State, v: *view.View) anyerror!void {
        try v.textf("Count: {d}", .{self.count}, .{});
        try v.row(.{ .gap = 8 });
        if (try v.button("Increment", .{})) self.count += 1;
        if (try v.button("Add row", .{})) self.rows += 1;
        try v.end();
        _ = try v.checkbox(&self.agreed, "Agree", .{});
        try v.radioGroup(.{ .name = "Mode" });
        _ = try v.radio(@TypeOf(self.mode), &self.mode, .list, "List", .{});
        _ = try v.radio(@TypeOf(self.mode), &self.mode, .grid, "Grid", .{});
        try v.end();
        _ = try v.slider(&self.level, .{ .minimum = 0, .maximum = 10, .step = 1 }, .{ .width = 200 });
        _ = try v.stepper(&self.amount, .{ .minimum = 0, .maximum = 9, .step = 1 }, .{ .name = "Amount" });
        try v.scroll(&self.list, .{ .height = 80, .self_align = .stretch, .background = 0xe5e9ed });
        for (0..self.rows) |i| try v.textf("Row {d}", .{i}, .{ .key = i + 1 });
        try v.end();
        try v.grid(&columns, .{ .gap = 8, .self_align = .stretch });
        try v.text("Name", .{});
        try v.text("Value", .{});
        try v.end();
    }
    const columns = [_]view.Track{ view.Track.fixed(80), view.Track.fraction(1) };
};

fn find(host: *const view.Host, kind: view.Kind, nth: usize) !view.Node {
    var seen: usize = 0;
    for (host.view.nodes()) |node| if (node.kind == kind) {
        if (seen == nth) return node;
        seen += 1;
    };
    return error.MissingNode;
}

fn paint(host: *view.Host, window: z.Window) !void {
    const before = host.frames;
    Native.paint(window);
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(before + 1, host.frames);
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var storage: view.Storage(32, 512) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try paint(&host, window);
    const increment = try find(&host, .button, 0);
    try std.testing.expect(increment.bounds.width > 0 and increment.bounds.height > 0);
    try std.testing.expectEqualStrings("Count: 0", (try find(&host, .text, 0)).text);
    // Each activation updates state immediately; none waits for a repaint.
    Native.click(window, increment.bounds);
    Native.click(window, increment.bounds);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try paint(&host, window);
    try std.testing.expectEqualStrings("Count: 2", (try find(&host, .text, 0)).text);
    try std.testing.expectEqual(increment.id, (try find(&host, .button, 0)).id);

    Native.click(window, (try find(&host, .checkbox, 0)).bounds);
    try std.testing.expect(state.agreed);
    try paint(&host, window);
    try std.testing.expect((try find(&host, .checkbox, 0)).checked);

    Native.click(window, (try find(&host, .radio, 1)).bounds);
    try std.testing.expectEqual(.grid, state.mode);
    try paint(&host, window);
    try std.testing.expect((try find(&host, .radio, 1)).checked and !(try find(&host, .radio, 0)).checked);

    const slider = try find(&host, .slider, 0);
    Native.click(window, .{ .x = slider.bounds.x + slider.bounds.width - 2, .y = slider.bounds.y, .width = 0, .height = slider.bounds.height });
    try std.testing.expect(state.level > 5);

    // A keyed row keeps its identity as the list grows.
    try paint(&host, window);
    const last_row = try find(&host, .text, 2);
    Native.click(window, (try find(&host, .button, 1)).bounds);
    try std.testing.expectEqual(@as(usize, 3), state.rows);
    try paint(&host, window);
    try std.testing.expectEqual(last_row.id, (try find(&host, .text, 2)).id);
    try std.testing.expectEqualStrings("Row 2", (try find(&host, .text, 3)).text);

    // The stepper's increment button sits at its far end.
    const stepper = try find(&host, .stepper, 0);
    Native.click(window, .{ .x = stepper.bounds.x + stepper.bounds.width - stepper.bounds.height / 2 - 1, .y = stepper.bounds.y, .width = 2, .height = stepper.bounds.height });
    try std.testing.expectEqual(@as(f64, 4), state.amount);

    // Wheel input over the list scrolls it immediately; elsewhere it does not.
    // An event pass rebuilds the tree without arranging it, so paint before
    // reading bounds again.
    for (0..3) |_| {
        Native.click(window, (try find(&host, .button, 1)).bounds);
        try paint(&host, window);
    }
    const list = try find(&host, .scroll, 0);
    try std.testing.expect(state.list.content.height > state.list.viewport.height);
    Native.wheelDown(window, list.bounds.x + 10, list.bounds.y - 10);
    try std.testing.expectEqual(@as(f32, 0), state.list.offset.y);
    Native.wheelDown(window, list.bounds.x + 10, list.bounds.y + 10);
    try std.testing.expect(state.list.offset.y > 0);
    try paint(&host, window);
    try std.testing.expectEqual(list.bounds.y - state.list.offset.y, (try find(&host, .text, 1)).bounds.y);
    const name = try find(&host, .text, state.rows + 1);
    const value = try find(&host, .text, state.rows + 2);
    try std.testing.expectEqualStrings("Value", value.text);
    try std.testing.expectEqual(name.bounds.y, value.bounds.y);
    try std.testing.expectEqual(name.bounds.x + 88, value.bounds.x);

    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("view native: build, flex layout, immediate activation, bound values, radio group, stepper, wheel scrolling, grid and keyed identity passed\n", .{});
}
