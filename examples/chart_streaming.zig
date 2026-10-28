//! Live chart: two series stream into a fixed-size ring buffer and redraw as
//! each sample lands. A `ziggurat_wake.OneShot` is armed for the next sample
//! only while streaming runs; pausing cancels it, so a paused or idle window
//! does no work at all. Hover the plot (or focus it and use the arrow keys,
//! Home and End) to inspect a sample.
//!
//! Run with `zig build run-chart-streaming`.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const wake = @import("ziggurat_wake");
const chart = @import("ziggurat_chart");
const chart_view = @import("ziggurat_chart_view");

/// Samples kept on screen; older ones are overwritten.
const capacity = 120;
const cpu_color: u32 = 0x2a7fd4;
const memory_color: u32 = 0xd4762a;

const Sample = struct { seconds: f64, cpu: f64, memory: f64 };

/// Fixed-capacity ring buffer: pushing into a full ring drops the oldest.
fn Ring(comptime size: usize) type {
    return struct {
        const Self = @This();
        items: [size]Sample = undefined,
        start: usize = 0,
        len: usize = 0,

        fn push(self: *Self, sample: Sample) void {
            if (self.len < size) {
                self.items[(self.start + self.len) % size] = sample;
                self.len += 1;
            } else {
                self.items[self.start] = sample;
                self.start = (self.start + 1) % size;
            }
        }
        /// The `index`th sample, oldest first.
        fn get(self: *const Self, index: usize) Sample {
            return self.items[(self.start + index) % size];
        }
    };
}

const Interval = enum(u64) {
    fast = 100 * std.time.ns_per_ms,
    medium = 250 * std.time.ns_per_ms,
    slow = 1000 * std.time.ns_per_ms,
};

const Stream = struct {
    window: ?z.Window = null,
    figure: *chart_view.Chart,
    /// Created once the App exists; null in headless tests.
    ticker: ?*wake.OneShot = null,
    token: ?wake.Token = null,
    clock: zio.Timer,
    rng: std.Random.DefaultPrng = .init(0x5eed),
    ring: Ring(capacity) = .{},
    running: bool = true,
    fill: bool = true,
    interval: Interval = .medium,
    cpu: f64 = 30,
    last_error: ?anyerror = null,
    // Chart inputs are borrowed until the next build, so they live here.
    xs: [capacity]f32 = undefined,
    cpu_ys: [capacity]f32 = undefined,
    memory_ys: [capacity]f32 = undefined,
    left: [12]chart.Tick = undefined,
    bottom: [12]chart.Tick = undefined,

    /// Produce one sample: a jittery CPU load with occasional spikes and a
    /// slowly breathing memory curve.
    fn sample(self: *Stream) void {
        const random = self.rng.random();
        const seconds = @as(f64, @floatFromInt(self.clock.read())) / std.time.ns_per_s;
        self.cpu += (random.float(f64) - 0.5) * 12 + (35 - self.cpu) * 0.08;
        if (random.float(f64) < 0.04) self.cpu = 80 + random.float(f64) * 15;
        self.cpu = std.math.clamp(self.cpu, 2, 98);
        const memory = 55 + 15 * @sin(seconds * 0.3) + (random.float(f64) - 0.5) * 4;
        self.ring.push(.{ .seconds = seconds, .cpu = self.cpu, .memory = memory });
    }

    /// Arm the next sample, replacing any pending deadline, or cancel it.
    fn schedule(self: *Stream) void {
        const ticker = self.ticker orelse return;
        if (!self.running) {
            if (self.token) |token| _ = ticker.cancel(token) catch |err| {
                self.last_error = err;
            };
            self.token = null;
            return;
        }
        self.token = ticker.armAfter(@backingInt(self.interval)) catch |err| blk: {
            self.last_error = err;
            break :blk null;
        };
    }

    /// OneShot callback on the main thread: one sample, one repaint, and a
    /// new deadline only while streaming continues.
    fn tick(context: *anyopaque, _: *wake.OneShot, token: wake.Token) void {
        const self: *Stream = @ptrCast(@alignCast(context));
        const current = self.token orelse return;
        if (current.generation != token.generation) return;
        self.token = null;
        self.sample();
        if (self.window) |window| window.invalidate();
        self.schedule();
    }

    fn describe(context: ?*const anyopaque, index: usize, buffer: []u8) []const u8 {
        const self: *const Stream = @ptrCast(@alignCast(context.?));
        const s = self.ring.get(index);
        return std.fmt.bufPrint(buffer, "t = {d:.1} s: CPU {d:.0}%, memory {d:.0}%", .{ s.seconds, s.cpu, s.memory }) catch buffer[0..0];
    }

    fn build(self: *Stream, v: *view.View) anyerror!void {
        try v.text("Streaming chart", .{ .font = view.Font.heading3 });
        try v.row(.{ .gap = 8, .alignment = .center, .self_align = .stretch });
        if (try v.button(if (self.running) "Pause" else "Resume", .{ .width = 96 })) {
            self.running = !self.running;
            self.schedule();
        }
        if (try v.button("Clear", .{ .enabled = self.ring.len > 0 })) self.ring = .{};
        try v.segmented(.{ .name = "Sample interval" });
        var changed = try v.segment(Interval, &self.interval, .fast, "100 ms", .{});
        changed = try v.segment(Interval, &self.interval, .medium, "250 ms", .{}) or changed;
        changed = try v.segment(Interval, &self.interval, .slow, "1 s", .{}) or changed;
        try v.end();
        if (changed) self.schedule();
        _ = try v.checkbox(&self.fill, "Fill CPU", .{});
        try v.spacer(.{});
        try v.textf("{d}/{d} samples", .{ self.ring.len, capacity }, .{ .color = 0x536475 });
        try v.end();

        try self.describeChart();
        try v.embed(self.figure.embed(), .{ .grow = 1, .self_align = .stretch, .key = 1 });

        const selected = self.figure.selected();
        if (selected.len > 0) {
            try v.text(selected, .{ .key = 2 });
        } else if (self.running) {
            try v.textf("Sampling every {d} ms. Hover the plot, or focus it and use the arrow keys.", .{@backingInt(self.interval) / std.time.ns_per_ms}, .{ .color = 0x536475, .key = 3 });
        } else {
            try v.text("Paused: no timer is armed and the window stays idle.", .{ .color = 0x536475, .key = 4 });
        }
    }

    /// Lay the ring out oldest to newest and describe the marks.
    fn describeChart(self: *Stream) !void {
        const figure = self.figure;
        const len = self.ring.len;
        const first = if (len > 0) self.ring.get(0).seconds else 0;
        const last = if (len > 1) self.ring.get(len - 1).seconds else first + 1;
        const x = chart.Linear.init(first, last);
        const y = chart.Linear.init(0, 100);
        figure.begin(.{ .left = try y.ticks(5, &self.left), .bottom = if (len > 1) try x.ticks(6, &self.bottom) else &.{} });
        for (0..len) |i| {
            const s = self.ring.get(i);
            self.xs[i] = x.at(s.seconds);
            self.cpu_ys[i] = y.at(s.cpu);
            self.memory_ys[i] = y.at(s.memory);
        }
        try figure.setLegend(&.{ .{ .label = "CPU", .color = cpu_color }, .{ .label = "Memory", .color = memory_color } });
        if (len < 2) return;
        const cpu = ui.Color.rgb(cpu_color);
        if (self.fill) try figure.add(.{ .area = .{ .xs = self.xs[0..len], .hi = self.cpu_ys[0..len], .color = .{ .r = cpu.r, .g = cpu.g, .b = cpu.b, .a = 48 } } });
        try figure.add(.{ .rule_y = .{ .y = y.at(80), .color = ui.Color.rgb(0xc8ccd2) } });
        try figure.add(.{ .line = .{ .xs = self.xs[0..len], .ys = self.memory_ys[0..len], .color = ui.Color.rgb(memory_color), .curve = .monotone } });
        try figure.add(.{ .line = .{ .xs = self.xs[0..len], .ys = self.cpu_ys[0..len], .color = cpu, .width = 1.5 } });
        figure.select(self.xs[0..len], .{ .context = self, .call = describe });
        if (figure.selection.index) |i| {
            try figure.add(.{ .rule_x = .{ .x = self.xs[i], .color = ui.Color.rgb(0x8a929c) } });
            try figure.add(.{ .point = .{ .x = self.xs[i], .y = self.cpu_ys[i], .color = cpu, .size = 8 } });
            try figure.add(.{ .point = .{ .x = self.xs[i], .y = self.memory_ys[i], .color = ui.Color.rgb(memory_color), .size = 8 } });
        }
    }

    /// Release chart masks before the Context detaches; see docs/chart.md.
    fn onClose(context: *anyopaque, _: z.Window, _: z.CloseReason) z.CloseDecision {
        const self: *Stream = @ptrCast(@alignCast(context));
        self.running = false;
        self.schedule();
        self.figure.deinit();
        return .allow;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const app = try z.App.init(allocator);
    defer app.deinit();

    var figure: chart_view.Chart = undefined;
    var stream: Stream = .{ .figure = &figure, .clock = try zio.Timer.start() };
    var storage: view.Storage(64, 2048) = .{};
    var host = view.Host.init(&stream, Stream.build, storage.buffers(), .{});
    var chart_storage: chart_view.Storage(16, 8, 2) = .{};
    figure = chart_view.Chart.init(&host, allocator, chart_storage.buffers(), .{ .name = "CPU and memory load", .width = 640, .height = 320 });

    const window = try app.createWindow(.{
        .title = "Ziggurat - Streaming chart",
        .width = 820,
        .height = 520,
        .min_width = 480,
        .min_height = 360,
        .on_close = .{ .context = &stream, .request = Stream.onClose },
    });
    stream.window = window;
    try host.attach(window);

    stream.ticker = try wake.OneShot.create(app, allocator, .{ .context = &stream, .fire = Stream.tick }, .{});
    stream.sample();
    stream.schedule();

    window.show();
    try app.run();

    // App stop already cancelled the native timer; the shell is ours to close.
    figure.deinit();
    if (stream.ticker) |ticker| _ = try ticker.close();
    stream.ticker = null;
}

test "the ring keeps the newest samples in order" {
    var ring: Ring(3) = .{};
    for (0..5) |i| ring.push(.{ .seconds = @floatFromInt(i), .cpu = 0, .memory = 0 });
    try std.testing.expectEqual(@as(usize, 3), ring.len);
    try std.testing.expectEqual(@as(f64, 2), ring.get(0).seconds);
    try std.testing.expectEqual(@as(f64, 4), ring.get(2).seconds);
}

test "pause and clear work headlessly" {
    var figure: chart_view.Chart = undefined;
    var stream: Stream = .{ .figure = &figure, .clock = try zio.Timer.start() };
    var chart_host_storage: view.Storage(8, 64) = .{};
    var chart_host = view.Host.init(&stream, Stream.build, chart_host_storage.buffers(), .{});
    var chart_storage: chart_view.Storage(16, 8, 2) = .{};
    figure = chart_view.Chart.init(&chart_host, std.testing.allocator, chart_storage.buffers(), .{});
    defer figure.deinit();
    for (0..4) |_| stream.sample();

    var storage: view.Storage(64, 2048) = .{};
    var h = view.Harness.init(&stream, Stream.build, storage.buffers(), .{});
    try h.render();
    try h.click(.{ .text = "Pause" });
    try std.testing.expect(!stream.running);
    try h.click(.{ .text = "Clear" });
    try std.testing.expectEqual(@as(usize, 0), stream.ring.len);
    try h.click(.{ .text = "1 s" });
    try std.testing.expectEqual(Interval.slow, stream.interval);
}
