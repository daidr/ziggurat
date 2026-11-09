//! How long a window leaves the GPU alone after a frame it did not finish
//! in time. Such a frame leaves the driver wedged rather than the device
//! gone: another frame submitted at once waits the same timeout through,
//! with the window showing nothing all the while. The frames in between
//! draw in memory. Each timeout soon after another doubles the rest, up to
//! half a minute; one long after the last starts again at a second.
const std = @import("std");

pub const first_ms: i64 = 1000;
pub const longest_ms: i64 = 30_000;
/// A timeout this long after the last one counts as the first again.
pub const forget_ms: i64 = 60_000;

pub const Rest = struct {
    /// The GPU may draw again from this time on (milliseconds).
    until: i64 = 0,
    /// The rest the last timeout began, and when it came.
    last_rest: i64 = 0,
    last: ?i64 = null,
    timeouts: u64 = 0,

    pub fn allowed(self: *const Rest, now: i64) bool {
        return now >= self.until;
    }
    /// A frame did not finish in time at `now`.
    pub fn timedOut(self: *Rest, now: i64) void {
        const soon = if (self.last) |last| now - last < forget_ms else false;
        self.last_rest = if (soon) @min(self.last_rest * 2, longest_ms) else first_ms;
        self.last = now;
        self.until = now + self.last_rest;
        self.timeouts += 1;
    }
};

test "a timeout rests the GPU, longer for each soon after another" {
    var rest: Rest = .{};
    try std.testing.expect(rest.allowed(0));
    rest.timedOut(10_000);
    try std.testing.expect(!rest.allowed(10_500));
    try std.testing.expect(rest.allowed(11_000));
    rest.timedOut(12_000);
    try std.testing.expectEqual(@as(i64, 14_000), rest.until);
    rest.timedOut(15_000);
    try std.testing.expectEqual(@as(i64, 19_000), rest.until);
    for (0..8) |_| rest.timedOut(rest.until);
    try std.testing.expectEqual(longest_ms, rest.last_rest);
    // Long after the last, the rest starts again at a second.
    const later = rest.until + forget_ms;
    rest.timedOut(later);
    try std.testing.expectEqual(later + first_ms, rest.until);
    try std.testing.expectEqual(@as(u64, 12), rest.timeouts);
}
