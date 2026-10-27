//! The heights of an editor's paragraphs, measured as they are laid out
//! and estimated for the others, summed in two Fenwick trees: the heights
//! measured, and how many are not, which the estimate multiplies. The top
//! of a paragraph, and the paragraph at a height, take O(log n) whatever
//! the estimate.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Heights = struct {
    /// 1-based.
    measured: std.ArrayList(f64) = .empty,
    unknown: std.ArrayList(i32) = .empty,
    estimate: f64 = 0,

    pub fn deinit(self: *Heights, allocator: Allocator) void {
        self.measured.deinit(allocator);
        self.unknown.deinit(allocator);
    }

    /// Sums the heights `hs`, 0 for those not measured.
    pub fn reset(self: *Heights, allocator: Allocator, hs: []const f32) !void {
        const n = hs.len;
        try self.measured.resize(allocator, n + 1);
        try self.unknown.resize(allocator, n + 1);
        @memset(self.measured.items, 0);
        @memset(self.unknown.items, 0);
        for (hs, 0..) |x, i| {
            if (x > 0) self.measured.items[i + 1] = x else self.unknown.items[i + 1] = 1;
        }
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const j = i + (i & (~i +% 1));
            if (j <= n) {
                self.measured.items[j] += self.measured.items[i];
                self.unknown.items[j] += self.unknown.items[i];
            }
        }
    }

    /// Changes the height measured of paragraph p by dm, and the count of
    /// those not measured by du.
    pub fn add(self: *Heights, p: usize, dm: f64, du: i32) void {
        var i = p + 1;
        while (i < self.measured.items.len) : (i += i & (~i +% 1)) {
            self.measured.items[i] += dm;
            self.unknown.items[i] += du;
        }
    }

    /// The top of paragraph p: the height of those before it.
    pub fn top(self: *const Heights, p: usize) f64 {
        var m: f64 = 0;
        var u: i64 = 0;
        var i = @min(p, self.measured.items.len -| 1);
        while (i > 0) : (i -= i & (~i +% 1)) {
            m += self.measured.items[i];
            u += self.unknown.items[i];
        }
        return m + @as(f64, @floatFromInt(u)) * self.estimate;
    }

    /// The paragraph at y, the last for y past the end.
    pub fn at(self: *const Heights, y: f64) usize {
        const n = self.measured.items.len -| 1;
        if (n == 0) return 0;
        var pos: usize = 0;
        var sum: f64 = 0;
        var step: usize = @as(usize, 1) << @intCast(std.math.log2_int(usize, n));
        while (step > 0) : (step >>= 1) {
            const next = pos + step;
            if (next <= n) {
                const s = sum + self.measured.items[next] + @as(f64, @floatFromInt(self.unknown.items[next])) * self.estimate;
                if (s <= y) {
                    pos = next;
                    sum = s;
                }
            }
        }
        return @min(pos, n - 1);
    }

    /// The sum of the heights measured and how many are not.
    pub fn totals(self: *const Heights) struct { measured: f64, unknown: usize } {
        var m: f64 = 0;
        var u: i64 = 0;
        var i = self.measured.items.len -| 1;
        while (i > 0) : (i -= i & (~i +% 1)) {
            m += self.measured.items[i];
            u += self.unknown.items[i];
        }
        return .{ .measured = m, .unknown = @intCast(@max(u, 0)) };
    }
};

test "tops and paragraphs at heights, measured and estimated" {
    const a = std.testing.allocator;
    var h: Heights = .{ .estimate = 10 };
    defer h.deinit(a);
    try h.reset(a, &.{ 20, 0, 30, 0, 5 });
    try std.testing.expectEqual(@as(f64, 0), h.top(0));
    try std.testing.expectEqual(@as(f64, 20), h.top(1));
    try std.testing.expectEqual(@as(f64, 30), h.top(2));
    try std.testing.expectEqual(@as(f64, 75), h.top(5));
    try std.testing.expectEqual(@as(usize, 2), h.at(35));
    try std.testing.expectEqual(@as(usize, 4), h.at(1000));
    h.add(1, 15, -1);
    try std.testing.expectEqual(@as(f64, 35), h.top(2));
    const t = h.totals();
    try std.testing.expectEqual(@as(f64, 70), t.measured);
    try std.testing.expectEqual(@as(usize, 1), t.unknown);
}
