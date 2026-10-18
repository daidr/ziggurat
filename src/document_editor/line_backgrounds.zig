const std = @import("std");

/// A complete logical paragraph identified by its committed UTF-8 byte start.
/// One color applies to its full wrapped height and the viewport width.
pub const Background = struct { paragraph: usize, color: u32 };

pub fn validate(items: []const Background, limit: usize) !void {
    if (items.len > limit) return error.LineBackgroundCapacityExceeded;
    for (items, 0..) |item, index| {
        if (item.color > 0xffffff) return error.InvalidLineBackground;
        if (index != 0 and item.paragraph <= items[index - 1].paragraph) return error.InvalidLineBackground;
    }
}

pub fn lowerBound(items: []const Background, paragraph: usize) usize {
    var lo: usize = 0;
    var hi = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].paragraph < paragraph) lo = mid + 1 else hi = mid;
    }
    return lo;
}

test "line backgrounds require unique source order, RGB colors and explicit capacity" {
    const items = [_]Background{ .{ .paragraph = 0, .color = 0 }, .{ .paragraph = 4, .color = 0xffffff }, .{ .paragraph = 10, .color = 0x123456 } };
    try validate(&items, 3);
    try std.testing.expectError(error.LineBackgroundCapacityExceeded, validate(&items, 2));
    try std.testing.expectError(error.InvalidLineBackground, validate(&.{ .{ .paragraph = 2, .color = 0 }, .{ .paragraph = 2, .color = 1 } }, 2));
    try std.testing.expectError(error.InvalidLineBackground, validate(&.{ .{ .paragraph = 2, .color = 0 }, .{ .paragraph = 1, .color = 1 } }, 2));
    try std.testing.expectError(error.InvalidLineBackground, validate(&.{.{ .paragraph = 0, .color = 0x1000000 }}, 1));
    for (0..12) |position| {
        var expected: usize = 0;
        while (expected < items.len and items[expected].paragraph < position) : (expected += 1) {}
        try std.testing.expectEqual(expected, lowerBound(&items, position));
    }
    try std.testing.expectEqual(@as(usize, 0), lowerBound(&.{}, 0));
}
