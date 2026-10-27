//! Per-frame timing of the paint path and a log of slow frames. Off by
//! default; enabled with `Context.setFrameStats` or, when a window is
//! attached, the `ZIGGURAT_FRAME_STATS` environment variable:
//! `1`/`on`/`true`/`yes` logs frames slower than 8 ms, a number logs frames
//! slower than that many milliseconds, `all` logs every frame, and
//! `0`/`off`/`false`/`no` keeps timing off. Timing reads a monotonic clock
//! a few times per frame; it allocates nothing.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

pub const env_name = "ZIGGURAT_FRAME_STATS";
pub const default_slow_ns: u64 = 8 * std.time.ns_per_ms;
const log = std.log.scoped(.ziggurat_frames);

pub const Options = struct {
    /// Time frames and keep the totals in `Stats`.
    enabled: bool = false,
    /// Log frames that take at least this long; null logs none, 0 logs all.
    slow_ns: ?u64 = default_slow_ns,
};

/// Where one frame's time went, in nanoseconds: recording the frame
/// (`build`), checking it against the renderer's limits (`preflight`), and
/// replaying and presenting it (`render`).
pub const Sample = struct {
    build_ns: u64 = 0,
    preflight_ns: u64 = 0,
    render_ns: u64 = 0,
    total_ns: u64 = 0,
    commands: usize = 0,
    /// Replayed on the software planes, including GPU frames that hold
    /// software-only commands.
    software: bool = false,
};
pub const Stats = struct {
    frames: u64 = 0,
    slow: u64 = 0,
    total_ns: u64 = 0,
    last: Sample = .{},
    worst: Sample = .{},
    pub fn meanNs(self: Stats) u64 {
        return if (self.frames == 0) 0 else self.total_ns / self.frames;
    }
};

/// Parse a setting as described at the top of this file; null is unset.
pub fn parse(value: ?[]const u8) Options {
    const text = std.mem.trim(u8, value orelse return .{}, " \t");
    const lower = struct {
        fn eql(a: []const u8, b: []const u8) bool {
            return std.ascii.eqlIgnoreCase(a, b);
        }
    };
    if (text.len == 0) return .{};
    for ([_][]const u8{ "0", "off", "false", "no" }) |word| if (lower.eql(text, word)) return .{};
    for ([_][]const u8{ "1", "on", "true", "yes" }) |word| if (lower.eql(text, word)) return .{ .enabled = true };
    if (lower.eql(text, "all")) return .{ .enabled = true, .slow_ns = 0 };
    const threshold = std.fmt.parseFloat(f64, text) catch return .{};
    if (!std.math.isFinite(threshold) or threshold < 0 or threshold > 60_000) return .{};
    return .{ .enabled = true, .slow_ns = @intFromFloat(threshold * std.time.ns_per_ms) };
}
/// Read `ZIGGURAT_FRAME_STATS` without allocating.
pub fn fromEnvironment() Options {
    if (builtin.os.tag == .windows) {
        const wide = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral(env_name)) orelse return .{};
        var narrow: [32]u8 = undefined;
        if (wide.len > narrow.len) return .{};
        for (wide, 0..) |unit, i| narrow[i] = if (unit < 128) @intCast(unit) else '?';
        return parse(narrow[0..wide.len]);
    }
    if (builtin.link_libc or builtin.os.tag == .linux) return parse(zio.getenv(env_name));
    return .{};
}

/// Marks taken through one frame.
pub const Clock = struct {
    start: ?zio.Instant = null,
    build: ?zio.Instant = null,
    preflight: ?zio.Instant = null,
    software: bool = true,

    pub fn begin(enabled: bool) Clock {
        return .{ .start = if (enabled) zio.Instant.now() catch null else null };
    }
    pub fn markBuild(self: *Clock) void {
        if (self.start != null) self.build = zio.Instant.now() catch null;
    }
    pub fn markPreflight(self: *Clock) void {
        if (self.start != null) self.preflight = zio.Instant.now() catch null;
    }
};

/// Close `clock`'s frame into `stats`, logging it when it is slow. Frames
/// that stopped before they were recorded leave no sample.
pub fn finish(stats: *Stats, options: Options, clock: *const Clock, commands: usize) void {
    const start = clock.start orelse return;
    const build = clock.build orelse return;
    const end = zio.Instant.now() catch return;
    const preflight = clock.preflight orelse end;
    const sample: Sample = .{
        .build_ns = build.since(start),
        .preflight_ns = preflight.since(build),
        .render_ns = end.since(preflight),
        .total_ns = end.since(start),
        .commands = commands,
        .software = clock.software,
    };
    record(stats, options, sample);
}
pub fn record(stats: *Stats, options: Options, sample: Sample) void {
    stats.frames +%= 1;
    stats.total_ns +%= sample.total_ns;
    stats.last = sample;
    if (sample.total_ns >= stats.worst.total_ns) stats.worst = sample;
    const threshold = options.slow_ns orelse return;
    if (sample.total_ns < threshold) return;
    stats.slow +%= 1;
    if (builtin.is_test) return;
    log.info("frame {d}: {d:.2} ms (build {d:.2}, preflight {d:.2}, render {d:.2}), {d} commands, {s}", .{
        stats.frames,         ms(sample.total_ns), ms(sample.build_ns),                        ms(sample.preflight_ns),
        ms(sample.render_ns), sample.commands,     if (sample.software) "software" else "gpu",
    });
}
fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

test "settings parse words, thresholds and all" {
    try std.testing.expectEqual(Options{}, parse(null));
    try std.testing.expectEqual(Options{}, parse("off"));
    try std.testing.expectEqual(Options{}, parse("No"));
    try std.testing.expectEqual(Options{ .enabled = true }, parse("1"));
    try std.testing.expectEqual(Options{ .enabled = true }, parse(" YES "));
    try std.testing.expectEqual(Options{ .enabled = true, .slow_ns = 0 }, parse("all"));
    try std.testing.expectEqual(Options{ .enabled = true, .slow_ns = 16_500_000 }, parse("16.5"));
    try std.testing.expectEqual(Options{}, parse("-3"));
    try std.testing.expectEqual(Options{}, parse("soon"));
}

test "samples total, keep the worst and count slow frames" {
    var stats: Stats = .{};
    const options: Options = .{ .enabled = true, .slow_ns = 10 };
    record(&stats, options, .{ .build_ns = 2, .preflight_ns = 1, .render_ns = 3, .total_ns = 6 });
    record(&stats, options, .{ .build_ns = 9, .preflight_ns = 1, .render_ns = 2, .total_ns = 12, .software = true });
    record(&stats, options, .{ .total_ns = 3 });
    try std.testing.expectEqual(@as(u64, 3), stats.frames);
    try std.testing.expectEqual(@as(u64, 1), stats.slow);
    try std.testing.expectEqual(@as(u64, 7), stats.meanNs());
    try std.testing.expectEqual(@as(u64, 12), stats.worst.total_ns);
    try std.testing.expectEqual(@as(u64, 3), stats.last.total_ns);
    var clock = Clock.begin(false);
    clock.markBuild();
    finish(&stats, options, &clock, 0);
    try std.testing.expectEqual(@as(u64, 3), stats.frames);
}
