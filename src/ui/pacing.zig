//! Whether frames wait for the display. They do, unless the
//! `ZIGGURAT_UNCAPPED` environment variable asks otherwise: a frame that
//! follows another draws at the display's next refresh, as the swap chain's
//! room, the Metal layer's display sync or GTK's frame clock says, so every
//! scene cheaper than a refresh shows the display's rate. Uncapped, as
//! benchmarks, profilers and apps that want the least latency ask for, the
//! next frame starts as soon as the last was presented, and the frame rate
//! tells how much of a refresh a scene leaves. An idle window still draws
//! nothing: only the frames asked for come sooner.
//!
//! The renderers read the same variable themselves (`pacing.h`): Direct3D
//! presents with sync interval 0 into three buffers, torn where DXGI allows
//! it; Metal's layer turns its display sync off; on Linux GTK's frame clock
//! is told a refresh of a microsecond, and on X11 the GLX swap interval of
//! the window GDK paints is 0. Browsers ignore it: requestAnimationFrame
//! paces their frames.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");

pub const env_name = "ZIGGURAT_UNCAPPED";

/// Whether `value`, the variable's, asks for frames uncapped: 1 (or true,
/// on, yes) does; nothing, 0 (false, off, no) or another value does not.
pub fn setting(value: ?[]const u8) bool {
    const text = std.mem.trim(u8, value orelse return false, " \t");
    for ([_][]const u8{ "1", "true", "on", "yes" }) |word| if (std.ascii.eqlIgnoreCase(text, word)) return true;
    return false;
}

var cached: enum(u8) { unknown, paced, uncapped } = .unknown;

/// Whether frames present without waiting for the display, read from the
/// environment once, on the main thread; false in browsers.
pub fn uncapped() bool {
    if (cached == .unknown) cached = if (read()) .uncapped else .paced;
    return cached == .uncapped;
}
/// Set it, for tests.
pub fn setUncappedForTest(value: bool) void {
    cached = if (value) .uncapped else .paced;
}

fn read() bool {
    if (builtin.cpu.arch.isWasm()) return false;
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: [*]u16, size: u32) callconv(.winapi) u32;
        };
        var wide: [9]u16 = undefined;
        const len = kernel32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(env_name), &wide, wide.len);
        if (len == 0 or len >= wide.len) return false;
        var narrow: [8]u8 = undefined;
        for (wide[0..len], 0..) |unit, i| narrow[i] = if (unit < 128) @intCast(unit) else '?';
        return setting(narrow[0..len]);
    }
    if (builtin.link_libc or builtin.os.tag == .linux) return setting(zio.getenv(env_name));
    return false;
}

/// Counts frames that follow each other while they are uncapped, for the
/// rate they come at, which the display's refreshes no longer cap.
pub const Rate = struct {
    from: ?zio.Instant = null,
    last: ?zio.Instant = null,
    frames: u32 = 0,

    /// A pause between frames longer than this starts the count anew: the
    /// time a window idled tells nothing of how fast it draws.
    pub const gap_ns: u64 = 250 * std.time.ns_per_ms;

    /// Count a frame that ran from `start` to `end`. Once frames followed
    /// each other for a second, returns how many came a second and counts
    /// anew. A pause longer than `gap_ns` starts the count anew, and so
    /// does a frame that took longer, as one that waited on the system:
    /// counted, it would have the second it ends in tell a few frames a
    /// second, as if the frames after it came that slowly too.
    pub fn count(self: *Rate, start: zio.Instant, end: zio.Instant) ?f64 {
        if (end.since(start) > gap_ns) {
            self.* = .{ .from = end, .last = end };
            return null;
        }
        if (self.from == null or self.last == null or start.since(self.last.?) > gap_ns) {
            self.from = start;
            self.frames = 0;
        }
        self.frames += 1;
        self.last = end;
        const elapsed = end.since(self.from.?);
        if (elapsed < std.time.ns_per_s) return null;
        const rate = @as(f64, @floatFromInt(self.frames)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
        self.from = end;
        self.frames = 0;
        return rate;
    }
};

test "the setting turns frames uncapped only when asked" {
    try std.testing.expect(!setting(null));
    try std.testing.expect(!setting(""));
    try std.testing.expect(!setting("0"));
    try std.testing.expect(!setting("off"));
    try std.testing.expect(!setting("soon"));
    try std.testing.expect(setting("1"));
    try std.testing.expect(setting(" Yes "));
    try std.testing.expect(setting("TRUE"));
}

test "the rate counts frames that follow each other for a second" {
    var rate: Rate = .{};
    const at = struct {
        fn ms(value: i96) zio.Instant {
            return .{ .timestamp = value * std.time.ns_per_ms };
        }
    }.ms;
    // Frames of 2 ms, one after another: 500 a second.
    var t: i96 = 1000;
    var reported: ?f64 = null;
    while (reported == null) : (t += 2) reported = rate.count(at(t), at(t + 2));
    try std.testing.expectApproxEqAbs(@as(f64, 500), reported.?, 1);
    // A pause starts the count anew.
    _ = rate.count(at(t + 1000), at(t + 1002));
    try std.testing.expectEqual(@as(u32, 1), rate.frames);
    // So does a frame that took longer than the gap.
    try std.testing.expectEqual(@as(?f64, null), rate.count(at(t + 1002), at(t + 1400)));
    try std.testing.expectEqual(@as(u32, 0), rate.frames);
}
