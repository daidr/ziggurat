//! Measures how long input takes to be painted in native UI: from when an
//! event arrives to when the frame showing it has been painted. It needs a
//! desktop session.
//!
//!     zig build input-latency -- [--mode type,scroll,drag,anim] [--runs 6] [--events 300] [--warmup 30]
//!
//! Each run is a process of its own with a window of native UI: typing
//! into a line of text (a character every 60 to 140 ms), scrolling a list
//! of a million rows with the wheel (an event every 4 to 12 ms), dragging a
//! box (the same), or animating a box with no input (anim). Events come
//! from another thread through `App.post`, as the platform's arrive through
//! the main loop, at any time within a frame, and reach the window's
//! content through `Window.emitEvent`, the path native input takes; an
//! event is taken to arrive when it is posted, so the time the main thread
//! was busy counts.
//!
//! The frame showing an event is the next one the main thread paints after
//! handling it. A run prints the latency's mean and percentiles in
//! milliseconds, and the means of what it is made of: waiting for the main
//! thread (queue), handling the event (handle), and from then to the end of
//! the paint of the frame showing it (paint), which includes waiting for
//! the platform's next paint. Neither Windows nor GTK reports here when a
//! frame reaches the display, so the time from the paint to the screen,
//! the compositor's, is not part of it. For anim, a run prints the
//! intervals between painted frames and the time a paint takes.
//!
//! The summary gives the median of the runs' figures: compare medians of
//! several runs, alternating builds.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

pub const Mode = enum { type, scroll, drag, anim };

const Options = struct {
    modes: []const Mode = &.{ .type, .scroll, .drag, .anim },
    runs: usize = 6,
    events: usize = 300,
    warmup: usize = 30,
};

/// One run's figures, in milliseconds; the child prints it as JSON.
pub const Result = struct {
    mode: Mode,
    count: usize = 0,
    mean: f64 = 0,
    p50: f64 = 0,
    p90: f64 = 0,
    p99: f64 = 0,
    max: f64 = 0,
    queue: f64 = 0,
    handle: f64 = 0,
    paint: f64 = 0,
};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    var options: Options = .{};
    var child_mode: ?Mode = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (index + 1 >= args.len) return usage();
        const value = args[index + 1];
        index += 1;
        if (std.mem.eql(u8, arg, "--mode")) {
            options.modes = parseModes(allocator, value) catch return usage();
        } else if (std.mem.eql(u8, arg, "--runs")) {
            options.runs = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--events")) {
            options.events = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            options.warmup = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--run")) {
            child_mode = std.meta.stringToEnum(Mode, value) orelse return usage();
        } else return usage();
    }
    if (options.runs == 0 or options.events == 0 or options.modes.len == 0) return usage();
    if (child_mode) |mode| {
        const result = try runOnce(allocator, mode, options.events, options.warmup);
        try std.fs.File.stdout().writeAll(try std.json.Stringify.valueAlloc(allocator, result, .{}));
        try std.fs.File.stdout().writeAll("\n");
        return;
    }
    const self = try std.fs.selfExePathAlloc(allocator);
    for (options.modes) |mode| {
        const results = try allocator.alloc(Result, options.runs);
        for (results, 0..) |*result, run| {
            const output = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ self, "--run", @tagName(mode), "--events", try std.fmt.allocPrint(allocator, "{d}", .{options.events}), "--warmup", try std.fmt.allocPrint(allocator, "{d}", .{options.warmup}) }, .max_output_bytes = 64 * 1024 });
            const ok = switch (output.term) {
                .Exited => |code| code == 0,
                else => false,
            };
            if (!ok) {
                std.debug.print("input-latency: the {s} run failed\n{s}", .{ @tagName(mode), output.stderr });
                std.process.exit(1);
            }
            result.* = try std.json.parseFromSliceLeaky(Result, allocator, std.mem.trim(u8, output.stdout, " \r\n"), .{});
            std.debug.print("{s} run {d}: {f}\n", .{ @tagName(mode), run + 1, describe(result.*) });
        }
        std.debug.print("{s} median: {f}\n", .{ @tagName(mode), describe(summary(allocator, results)) });
    }
}

fn usage() void {
    std.debug.print("usage: input-latency [--mode type,scroll,drag,anim] [--runs N] [--events N] [--warmup N]\n", .{});
    std.process.exit(2);
}

pub fn parseModes(allocator: std.mem.Allocator, text: []const u8) ![]const Mode {
    var modes: std.ArrayList(Mode) = .empty;
    errdefer modes.deinit(allocator);
    var parts = std.mem.tokenizeScalar(u8, text, ',');
    while (parts.next()) |part| try modes.append(allocator, std.meta.stringToEnum(Mode, std.mem.trim(u8, part, " ")) orelse return error.UnknownMode);
    return modes.toOwnedSlice(allocator);
}

const Description = struct {
    result: Result,
    pub fn format(self: Description, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const r = self.result;
        if (r.mode == .anim) return w.print("{d} frames, interval mean {d:.2} ms, p50 {d:.2}, p90 {d:.2}, p99 {d:.2}, max {d:.2}; paint {d:.2} ms", .{ r.count, r.mean, r.p50, r.p90, r.p99, r.max, r.paint });
        try w.print("{d} events, mean {d:.2} ms, p50 {d:.2}, p90 {d:.2}, p99 {d:.2}, max {d:.2}; queue {d:.2}, handle {d:.2}, paint {d:.2}", .{ r.count, r.mean, r.p50, r.p90, r.p99, r.max, r.queue, r.handle, r.paint });
    }
};

fn describe(result: Result) Description {
    return .{ .result = result };
}

/// The median of each figure across runs.
pub fn summary(allocator: std.mem.Allocator, results: []const Result) Result {
    var out: Result = .{ .mode = results[0].mode, .count = results[0].count };
    const values = allocator.alloc(f64, results.len) catch return out;
    defer allocator.free(values);
    inline for (.{ "mean", "p50", "p90", "p99", "max", "queue", "handle", "paint" }) |name| {
        for (results, values) |r, *v| v.* = @field(r, name);
        std.mem.sort(f64, values, {}, std.sort.asc(f64));
        const n = values.len;
        @field(out, name) = if (n % 2 == 1) values[n / 2] else (values[n / 2 - 1] + values[n / 2]) / 2;
    }
    return out;
}

/// Percentile `p` (0 to 1) of sorted values, nearest rank.
pub fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(sorted.len))));
    return sorted[@min(sorted.len - 1, @max(rank, 1) - 1)];
}

// ---------------------------------------------------------------- a run

const row_height: f32 = 24;
const rows: usize = 1_000_000;
const box_size: f32 = 80;

const Sample = struct {
    bench: *Bench,
    index: usize,
    posted: u64 = 0,
    ran: u64 = 0,
    handled: u64 = 0,
    painted: u64 = 0,
    event: z.Event = .{ .focus = true },
};

/// A frame drawn: when, and the samples it shows.
const Frame = struct { begun: u64, first: usize, end: usize };

const Bench = struct {
    mode: Mode,
    window: z.Window = undefined,
    app: *z.App = undefined,
    content: ui.Context = undefined,
    start: std.time.Instant,
    samples: []Sample,
    warmup: usize,
    /// Samples handled and not yet painted start here.
    unpainted: usize = 0,
    handled: usize = 0,
    started: bool = false,
    finished: bool = false,
    worker: ?std.Thread = null,
    text: [64]u8 = undefined,
    text_len: usize = 0,
    scroll: f32 = 0,
    box: z.Point = .{ .x = 40, .y = 40 },
    /// The last frame drawn, until it is known to be painted.
    pending: ?Frame = null,
    /// Paint start and end of each frame, for anim.
    frames: std.ArrayList([2]u64) = .empty,
    allocator: std.mem.Allocator,

    fn now(self: *const Bench) u64 {
        const instant = std.time.Instant.now() catch return 0;
        return instant.since(self.start);
    }

    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Bench = @ptrCast(@alignCast(ptr));
        const begun = self.now();
        const width = @as(f32, @floatFromInt(frame.size.width)) / frame.size.scale;
        const height = @as(f32, @floatFromInt(frame.size.height)) / frame.size.scale;
        frame.clear(0xffffff);
        switch (self.mode) {
            .type => {
                frame.label(.{ .x = 24, .y = 24, .width = width - 48, .height = 28 }, "Typing", 0x5f6b7a);
                frame.label(.{ .x = 24, .y = 60, .width = width - 48, .height = 28 }, self.text[0..self.text_len], 0x182430);
            },
            .scroll => {
                const first: usize = @intFromFloat(@max(0, self.scroll / row_height));
                const offset = self.scroll - @as(f32, @floatFromInt(first)) * row_height;
                var buffer: [32]u8 = undefined;
                var y = -offset;
                var row = first;
                while (y < height and row < rows) : ({
                    y += row_height;
                    row += 1;
                }) {
                    if (row % 2 == 1) frame.rect(.{ .x = 0, .y = y, .width = width, .height = row_height }, 0xf2f4f7);
                    frame.label(.{ .x = 16, .y = y + 2, .width = width - 32, .height = row_height - 4 }, std.fmt.bufPrint(&buffer, "Row {d}", .{row + 1}) catch "", 0x182430);
                }
            },
            .drag, .anim => {
                if (self.mode == .anim) {
                    const t = @as(f32, @floatFromInt(begun)) / std.time.ns_per_s;
                    self.box = .{ .x = (width - box_size) * (0.5 + 0.5 * @sin(t * 2)), .y = (height - box_size) * 0.5 };
                }
                frame.rect(.{ .x = self.box.x, .y = self.box.y, .width = box_size, .height = box_size }, 0x4f7cff);
            },
        }
        // The frame is painted once the renderer has replayed and presented
        // it, after this callback: a task posted now runs after that, and
        // reads how long the whole frame took.
        if (self.pending) |previous| self.finishFrame(previous, begun);
        self.pending = .{ .begun = begun, .first = self.unpainted, .end = self.handled };
        self.unpainted = self.handled;
        self.post(.{ .context = self, .call = framePainted });
    }

    fn framePainted(ptr: *anyopaque) void {
        const self: *Bench = @ptrCast(@alignCast(ptr));
        const frame = self.pending orelse return;
        self.finishFrame(frame, frame.begun + self.content.frameStats().last.total_ns);
    }

    fn finishFrame(self: *Bench, frame: Frame, painted: u64) void {
        self.pending = null;
        if (self.finished) return;
        if (self.mode == .anim) {
            self.frames.append(self.allocator, .{ frame.begun, painted }) catch {};
            if (self.frames.items.len >= self.samples.len + self.warmup) {
                self.finished = true;
                return self.post(.{ .context = self, .call = quit });
            }
            // The next frame as soon as the platform paints again.
            return self.window.invalidate();
        }
        // The frame shows every event handled before it began.
        for (self.samples[frame.first..frame.end]) |*sample| sample.painted = painted;
        if (!self.started) {
            self.started = true;
            self.post(.{ .context = self, .call = startWorker });
        }
        if (frame.end == self.samples.len) {
            self.finished = true;
            self.post(.{ .context = self, .call = quit });
        }
    }

    fn post(self: *Bench, task: z.Task) void {
        self.app.post(task) catch |err| std.debug.panic("post: {s}", .{@errorName(err)});
    }
    fn invalidate(ptr: *anyopaque) void {
        const self: *Bench = @ptrCast(@alignCast(ptr));
        self.window.invalidate();
    }
    fn quit(ptr: *anyopaque) void {
        const self: *Bench = @ptrCast(@alignCast(ptr));
        self.app.quit();
    }
    fn startWorker(ptr: *anyopaque) void {
        const self: *Bench = @ptrCast(@alignCast(ptr));
        self.worker = std.Thread.spawn(.{}, produce, .{self}) catch |err| std.debug.panic("thread: {s}", .{@errorName(err)});
    }

    /// The other thread: post the events at random intervals.
    fn produce(self: *Bench) void {
        var prng: std.Random.DefaultPrng = .init(std.crypto.random.int(u64));
        const random = prng.random();
        const low: u64, const high: u64 = if (self.mode == .type) .{ 60, 140 } else .{ 4, 12 };
        for (self.samples) |*sample| {
            std.Thread.sleep(random.intRangeAtMost(u64, low * std.time.ns_per_ms, high * std.time.ns_per_ms));
            sample.posted = self.now();
            self.app.post(.{ .context = sample, .call = deliver }) catch return;
        }
    }

    fn deliver(ptr: *anyopaque) void {
        const sample: *Sample = @ptrCast(@alignCast(ptr));
        const self = sample.bench;
        sample.ran = self.now();
        self.window.emitEvent(sample.event) catch |err| std.debug.panic("emit: {s}", .{@errorName(err)});
        sample.handled = self.now();
        self.handled = sample.index + 1;
    }

    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Bench = @ptrCast(@alignCast(ptr));
        switch (event) {
            .text_input => |text| {
                if (self.text_len + text.text.len > self.text.len) self.text_len = 0;
                @memcpy(self.text[self.text_len..][0..text.text.len], text.text);
                self.text_len += text.text.len;
                return true;
            },
            .wheel => |wheel| {
                self.scroll = std.math.clamp(self.scroll - wheel.delta.y, 0, @as(f32, @floatFromInt(rows)) * row_height);
                return true;
            },
            .pointer_down, .pointer_up => return true,
            .pointer_move => |point| {
                self.box = .{ .x = point.x - box_size / 2, .y = point.y - box_size / 2 };
                return true;
            },
            else => return false,
        }
    }
    fn action(_: *anyopaque, _: u64) void {}
};

fn events(samples: []Sample, mode: Mode) void {
    const letters = "abcdefghijklmnopqrstuvwxyz ";
    for (samples, 0..) |*sample, i| {
        const angle = @as(f32, @floatFromInt(i)) * 0.05;
        sample.event = switch (mode) {
            .type => .{ .text_input = .{ .text = letters[i % letters.len ..][0..1], .producer = .application } },
            .scroll => .{ .wheel = .{ .position = .{ .x = 200, .y = 200 }, .delta = .{ .x = 0, .y = if ((i / 100) % 2 == 0) -40 else 40 } } },
            .drag => if (i == 0)
                .{ .pointer_down = .{ .position = .{ .x = 80, .y = 80 } } }
            else if (i == samples.len - 1)
                .{ .pointer_up = .{ .position = .{ .x = 80, .y = 80 } } }
            else
                .{ .pointer_move = .{ .x = 300 + 150 * @cos(angle), .y = 220 + 120 * @sin(angle) } },
            .anim => .{ .focus = true },
        };
    }
}

fn runOnce(allocator: std.mem.Allocator, mode: Mode, count: usize, warmup: usize) !Result {
    const samples = try allocator.alloc(Sample, if (mode == .anim) count else count + warmup);
    var bench: Bench = .{ .mode = mode, .start = try std.time.Instant.now(), .samples = samples, .warmup = warmup, .allocator = allocator };
    for (samples, 0..) |*sample, i| sample.* = .{ .bench = &bench, .index = i };
    events(samples, mode);
    bench.content = ui.Context.init(&bench, Bench.draw, Bench.action);
    bench.content.on_input = Bench.input;
    // The time of each frame tells when it was painted.
    bench.content.setFrameStats(.{ .enabled = true, .slow_ns = null });
    const app = try z.App.init(allocator);
    defer app.deinit();
    bench.app = app;
    const window = try app.createWindow(.{ .title = "Input latency", .width = 640, .height = 480 });
    bench.window = window;
    try bench.content.attach(window);
    window.show();
    try app.run();
    if (bench.worker) |thread| thread.join();
    if (!bench.finished) return error.Unfinished;
    return measure(allocator, mode, &bench);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn measure(allocator: std.mem.Allocator, mode: Mode, bench: *const Bench) !Result {
    var result: Result = .{ .mode = mode };
    var values: std.ArrayList(f64) = .empty;
    if (mode == .anim) {
        const frames = bench.frames.items[bench.warmup..];
        var paint: f64 = 0;
        for (frames[1..], 1..) |frame, i| try values.append(allocator, ms(frame[0] - frames[i - 1][0]));
        for (frames) |frame| paint += ms(frame[1] - frame[0]);
        result.paint = paint / @as(f64, @floatFromInt(frames.len));
    } else {
        const measured = bench.samples[bench.warmup..];
        for (measured) |sample| {
            try values.append(allocator, ms(sample.painted - sample.posted));
            result.queue += ms(sample.ran - sample.posted);
            result.handle += ms(sample.handled - sample.ran);
            result.paint += ms(sample.painted - sample.handled);
        }
        const n: f64 = @floatFromInt(measured.len);
        result.queue /= n;
        result.handle /= n;
        result.paint /= n;
    }
    std.mem.sort(f64, values.items, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (values.items) |v| sum += v;
    result.count = values.items.len;
    result.mean = if (values.items.len == 0) 0 else sum / @as(f64, @floatFromInt(values.items.len));
    result.p50 = percentile(values.items, 0.5);
    result.p90 = percentile(values.items, 0.9);
    result.p99 = percentile(values.items, 0.99);
    result.max = if (values.items.len == 0) 0 else values.items[values.items.len - 1];
    return result;
}

test "percentiles, medians and modes" {
    const sorted = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(f64, 5), percentile(&sorted, 0.5));
    try std.testing.expectEqual(@as(f64, 9), percentile(&sorted, 0.9));
    try std.testing.expectEqual(@as(f64, 10), percentile(&sorted, 0.99));
    const results = [_]Result{ .{ .mode = .type, .mean = 3 }, .{ .mode = .type, .mean = 1 }, .{ .mode = .type, .mean = 2 } };
    try std.testing.expectEqual(@as(f64, 2), summary(std.testing.allocator, &results).mean);
    const modes = try parseModes(std.testing.allocator, "type, anim");
    defer std.testing.allocator.free(modes);
    try std.testing.expectEqualSlices(Mode, &.{ .type, .anim }, modes);
    try std.testing.expectError(error.UnknownMode, parseModes(std.testing.allocator, "type,hover"));
}
