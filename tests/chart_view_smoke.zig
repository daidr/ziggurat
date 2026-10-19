const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const chart = @import("ziggurat_chart");
const chart_view = @import("ziggurat_chart_view");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;

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

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" };

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
        self.chart.value = "June: 57 sales";
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
    try std.testing.expect(stats.software.resident_entries >= 5 and stats.software.draws > 0);

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
    std.debug.print("chart view native: deferred mask preparation, reuse, data refresh and release passed\n", .{});
}
