const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const chart = @import("ziggurat_chart");
const chart_view = @import("ziggurat_chart_view");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const MotionEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, is_hint: i16, device: ?*anyopaque, x_root: f64, y_root: f64 };
const ScrollEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, state: c_uint, direction: c_int, device: ?*anyopaque, x_root: f64, y_root: f64, delta_x: f64, delta_y: f64, stop_storage: c_uint };
const FocusEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, active: i16 };

const width = 480;
const height = 320;

fn nativePaint(window: z.Window) void {
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

/// Native pointer input in window DIP, through the platform's own
/// capture: SetCapture on Windows and a GTK grab on Linux.
const Native = struct {
    fn area(window: z.Window) *anyopaque {
        return gtk_bin_get_child(window.nativeHandle().?).?;
    }
    fn lparam(window: z.Window, point: view.Point) c.LPARAM {
        const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96;
        const px: u16 = @bitCast(@as(i16, @intFromFloat(@round(point.x * scale))));
        const py: u16 = @bitCast(@as(i16, @intFromFloat(@round(point.y * scale))));
        return @intCast(@as(u32, px) | (@as(u32, py) << 16));
    }
    fn pointer(window: z.Window, phase: enum { down, move, up }, point: view.Point) !void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            _ = c.SendMessageW(hwnd, switch (phase) {
                .down => c.WM_LBUTTONDOWN,
                .move => c.WM_MOUSEMOVE,
                .up => c.WM_LBUTTONUP,
            }, if (phase == .up) 0 else c.MK_LBUTTON, lparam(window, point));
            if (phase == .down) try std.testing.expect(c.GetCapture() == hwnd);
            return;
        }
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
            button.* = .{ .kind = if (phase == .down) 4 else 7, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = point.x, .y = point.y, .axes = null, .state = if (phase == .up) 1 << 8 else 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
            g_signal_emit_by_name(widget, if (phase == .down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), button, &handled);
        }
    }
    /// One wheel notch up, toward zooming in.
    fn wheel(window: z.Window, point: view.Point) !void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            var screen: c.POINT = .{ .x = @intFromFloat(@round(point.x * scale)), .y = @intFromFloat(@round(point.y * scale)) };
            _ = c.ClientToScreen(hwnd, &screen);
            const position: u32 = @as(u32, @as(u16, @bitCast(@as(i16, @intCast(screen.x))))) | (@as(u32, @as(u16, @bitCast(@as(i16, @intCast(screen.y))))) << 16);
            _ = c.SendMessageW(hwnd, c.WM_MOUSEWHEEL, @as(usize, @as(u16, @bitCast(@as(i16, 120)))) << 16, @intCast(position));
            return;
        }
        const event = gdk_event_new(31) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const native: *ScrollEvent = @ptrCast(@alignCast(event));
        native.* = .{ .kind = 31, .window = g_object_ref(gtk_widget_get_window(area(window)).?), .send_event = 1, .time = 0, .x = point.x, .y = point.y, .state = 0, .direction = 0, .device = null, .x_root = 0, .y_root = 0, .delta_x = 0, .delta_y = -1, .stop_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(area(window), "scroll-event", native, &handled);
    }
    /// The window loses the press: the capture is cancelled on Windows and
    /// keyboard focus leaves on Linux.
    fn lose(window: z.Window) void {
        if (builtin.os.tag == .windows) {
            _ = c.ReleaseCapture();
            _ = c.SendMessageW(window.nativeHandle(), c.WM_CANCELMODE, 0, 0);
            return;
        }
        const event = gdk_event_new(12) orelse unreachable;
        defer gdk_event_free(event);
        const focus_event: *FocusEvent = @ptrCast(@alignCast(event));
        focus_event.* = .{ .kind = 12, .window = g_object_ref(gtk_widget_get_window(area(window)).?), .send_event = 1, .active = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(area(window), "focus-out-event", focus_event, &handled);
    }
};

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" };

fn describe(_: ?*const anyopaque, index: usize, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}: point {d}", .{ months[index], index }) catch buffer[0..0];
}

const State = struct {
    chart: *chart_view.Chart = undefined,
    sales: [6]f64 = .{ 12, 30, 22, 48, 41, 57 },
    xs: [6]f32 = undefined,
    ys: [6]f32 = undefined,
    left: [16]chart.Tick = undefined,
    bottom: [6]chart.Tick = undefined,
    slices: [3]chart.Slice = undefined,
    pie: bool = true,

    fn build(self: *State, v: *view.View) anyerror!void {
        const x = chart.Band.init(&months).padding(0.3, 0.15);
        const y = chart.Linear.init(0, chart.extent(&self.sales).hi).nice(4);
        const accent = ui.Color.rgb(0x2a7fd4);
        self.chart.begin(.{ .left = try y.ticks(4, &self.left), .bottom = try x.ticks(&self.bottom) });
        for (self.sales, 0..) |value, i| {
            try self.chart.add(.{ .bar = .{ .x = x.band(i), .y = y.span(0, value), .color = accent, .radius = 3 } });
            self.xs[i] = x.at(i);
            self.ys[i] = y.at(value);
        }
        try self.chart.add(.{ .area = .{ .xs = &self.xs, .hi = &self.ys, .color = .{ .r = 0xd4, .g = 0x7f, .b = 0x2a, .a = 60 }, .curve = .monotone } });
        try self.chart.add(.{ .line = .{ .xs = &self.xs, .ys = &self.ys, .color = ui.Color.rgb(0xd47f2a), .curve = .monotone } });
        if (self.pie) for (try chart.pie(&.{ 1, 2, 3 }, 0.02, &self.slices)) |slice| {
            try self.chart.add(.{ .sector = .{ .slice = slice, .color = .{ .r = 0x40, .g = 0xa0, .b = 0x60, .a = 80 }, .inner = 0.5, .outer = 0.9 } });
        };
        try self.chart.add(.{ .rule_y = .{ .y = y.at(40), .color = ui.Color.rgb(0xcc3333) } });
        try self.chart.add(.{ .label = .{ .x = x.at(5), .y = y.at(self.sales[5]), .text = "57" } });
        try self.chart.setLegend(&.{ .{ .label = "Sales", .color = 0x2a7fd4 }, .{ .label = "Trend", .color = 0xd47f2a } });
        self.chart.select(&self.xs, .{ .call = describe });
        if (self.chart.selection.index) |i| try self.chart.add(.{ .rule_x = .{ .x = self.xs[i], .color = ui.Color.rgb(0x888888) } });
        try v.text("Sales by month", .{});
        try v.embed(self.chart.embed(), .{ .grow = 1, .self_align = .stretch, .key = 1 });
    }
};

fn paint(host: *view.Host, window: z.Window) !void {
    const before = host.frames;
    nativePaint(window);
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(before + 1, host.frames);
}

fn prepared(slots: []const chart_view.Slot) usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (slot.prepared != null) count += 1;
    }
    return count;
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var storage: view.Storage(16, 512) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);

    var chart_storage: chart_view.Storage(16, 8, 4) = .{};
    var figure = chart_view.Chart.init(&host, allocator, chart_storage.buffers(), .{ .name = "Monthly sales", .grid = .{ .vertical = true } });
    state.chart = &figure;
    errdefer figure.deinit();

    // The first frame paints the frame-drawn marks and finds every mask
    // stale; preparation is posted and lands before the next frame.
    try paint(&host, window);
    try std.testing.expect(figure.queued);
    try std.testing.expectEqual(@as(usize, 0), prepared(&chart_storage.slots));
    try app.dispatch();
    if (figure.last_error) |err| return err;
    try std.testing.expectEqual(@as(usize, 5), prepared(&chart_storage.slots));
    const area = figure.area;
    try std.testing.expect(area.width > 200 and area.height > 100);
    const scale = (try window.contentSize()).scale;
    for (chart_storage.slots[0..5]) |slot| {
        try std.testing.expectEqual(scale, slot.scale);
        try std.testing.expectEqual(area.width, slot.width);
    }

    // An unchanged chart paints its masks and posts nothing.
    const identity = chart_storage.slots[1].prepared.?.identity;
    try paint(&host, window);
    try std.testing.expect(!figure.queued);
    try paint(&host, window);
    try std.testing.expect(!figure.queued);
    try std.testing.expectEqual(identity, chart_storage.slots[1].prepared.?.identity);
    const stats = try host.context.coverageStats();
    // GDI draws masks directly and keeps none resident, so count requests.
    try std.testing.expect(stats.software.upload_requests >= 5 and stats.software.draws > 0);

    // The pointer over the plot chooses the nearest month, a press there
    // makes the chart take the focus, and leaving clears the choice.
    const middle: view.Point = .{ .x = area.x + area.width * state.xs[3], .y = area.y + area.height / 2 };
    try std.testing.expect(host.view.embedPointerMove(middle));
    try std.testing.expectEqual(@as(?usize, 3), figure.selection.index);
    try std.testing.expectEqualStrings("Apr: point 3", figure.selected());
    const press = host.view.pointerPress(middle, .{}, host.time(), false);
    try std.testing.expect(press.consumed and press.focus != null);
    _ = host.view.captureRelease(middle);
    try paint(&host, window);
    try std.testing.expect(host.view.embedPointerMove(null));
    try std.testing.expectEqual(@as(?usize, null), figure.selection.index);
    try paint(&host, window);

    // A native drag across the plot brushes along x; the capture follows
    // it out of the window, where it ends at the area's left edge.
    figure.options.interaction = .{ .brush = .x, .zoom = .x };
    const y_mid = area.y + area.height / 2;
    try Native.pointer(window, .down, .{ .x = area.x + area.width * 0.5, .y = y_mid });
    try Native.pointer(window, .move, .{ .x = area.x + area.width * 0.3, .y = y_mid });
    try std.testing.expect(figure.press == .brush and figure.dragged);
    try Native.pointer(window, .move, .{ .x = -30, .y = y_mid });
    try Native.pointer(window, .up, .{ .x = -30, .y = y_mid });
    if (host.last_error) |err| return err;
    try std.testing.expect(host.view.capture == null);
    const brush = figure.brush orelse return error.BrushMissing;
    try std.testing.expectApproxEqAbs(@as(f32, 0), brush.x.lo, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), brush.x.hi, 0.01);
    try paint(&host, window);

    // A lost press gives the brush being dragged up and keeps the last one.
    try Native.pointer(window, .down, .{ .x = area.x + area.width * 0.6, .y = y_mid });
    try Native.pointer(window, .move, .{ .x = area.x + area.width * 0.9, .y = y_mid });
    Native.lose(window);
    try std.testing.expect(host.view.capture == null and figure.press == .none);
    try std.testing.expectEqual(brush, figure.brush.?);
    try paint(&host, window);

    // The wheel zooms around the pointer, and the masks for the new zoom
    // are prepared before the next frame, which posts nothing.
    try Native.wheel(window, .{ .x = area.x + area.width * 0.25, .y = y_mid });
    if (figure.last_error) |err| return err;
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), figure.zoom.x.hi - figure.zoom.x.lo, 1e-3);
    // The line and area follow the zoom; the slices stay whole.
    for (chart_storage.slots[0..2]) |slot| try std.testing.expectEqual(figure.zoom.x, slot.zoom.x);
    for (chart_storage.slots[2..5]) |slot| try std.testing.expect(slot.zoom.whole());
    try std.testing.expectEqual(@as(usize, 5), prepared(&chart_storage.slots));
    try paint(&host, window);
    try std.testing.expect(!figure.queued);
    // A double press shows the whole plot again.
    for (0..2) |_| {
        try Native.pointer(window, .down, middle);
        try Native.pointer(window, .up, middle);
    }
    try std.testing.expect(figure.zoom.whole() and figure.brush == null);
    try paint(&host, window);
    try std.testing.expect(!figure.queued);
    figure.options.interaction = .{};

    // New data prepares the line and area again; the slices keep theirs.
    // Dropping the pie releases its masks.
    const slice_identity = chart_storage.slots[2].prepared.?.identity;
    state.sales[2] = 5;
    state.pie = false;
    try paint(&host, window);
    try std.testing.expect(figure.queued);
    try app.dispatch();
    if (figure.last_error) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), prepared(&chart_storage.slots));
    try std.testing.expect(chart_storage.slots[1].prepared.?.identity != identity);
    try std.testing.expect(slice_identity != chart_storage.slots[0].prepared.?.identity);
    try paint(&host, window);
    try std.testing.expect(!figure.queued);

    figure.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared(&chart_storage.slots));
    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("chart view native: deferred mask preparation, reuse, captured brushing, wheel zoom, data refresh and release passed\n", .{});
}
