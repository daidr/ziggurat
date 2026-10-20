const std = @import("std");
const d = @import("ziggurat_document");

pub const Kind = enum { background, underline, foreground };
/// Paint-only committed UTF-8 source range. Underline decorates the bottom of
/// selection cells; it is not a font-metric underline or a glyph ink bound.
/// Foreground draws the range's text in `color` instead of the text color,
/// as syntax highlighting does; overlapping foreground ranges draw the text
/// once per range, so callers give each byte at most one.
pub const Marker = struct {
    range: d.Range,
    kind: Kind = .background,
    color: u32,
    thickness: f32 = 1,
};
pub const Entry = struct { marker: Marker, maximum_end: usize };

pub fn validate(items: []const Marker, limit: usize) !void {
    if (items.len > limit) return error.RangeMarkerCapacityExceeded;
    for (items, 0..) |item, index| {
        try validateMarker(item);
        if (index != 0 and item.range.start < items[index - 1].range.start) return error.InvalidRangeMarker;
    }
}
fn validateMarker(item: Marker) !void {
    if (item.range.start >= item.range.end or item.color > 0xffffff or !std.math.isFinite(item.thickness) or item.thickness <= 0 or item.thickness > 16) return error.InvalidRangeMarker;
}
pub fn capture(allocator: std.mem.Allocator, items: []const Marker) ![]Entry {
    const entries = try allocator.alloc(Entry, items.len);
    var maximum: usize = 0;
    for (entries, items) |*entry, marker| {
        maximum = @max(maximum, marker.range.end);
        entry.* = .{ .marker = marker, .maximum_end = maximum };
    }
    return entries;
}
/// Validate the owned capture again after the foreign allocation returned.
pub fn validateOwned(entries: []const Entry, limit: usize) !void {
    if (entries.len > limit) return error.RangeMarkerCapacityExceeded;
    var maximum: usize = 0;
    for (entries, 0..) |entry, index| {
        try validateMarker(entry.marker);
        if (index != 0 and entry.marker.range.start < entries[index - 1].marker.range.start) return error.InvalidRangeMarker;
        maximum = @max(maximum, entry.marker.range.end);
        if (maximum != entry.maximum_end) return error.InvalidRangeMarker;
    }
}
/// Prefix maxima preserve overlapping ranges and skip every definition whose
/// end is at/before this visible run. Equal starts retain caller paint order.
pub fn firstOverlap(entries: []const Entry, start: usize) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (entries[middle].maximum_end <= start) low = middle + 1 else high = middle;
    }
    return low;
}
pub const Work = struct {
    remaining: usize,
    pub fn take(self: *Work, amount: usize) !void {
        if (amount > self.remaining) return error.RangeMarkerWorkExceeded;
        self.remaining -= amount;
    }
};

test "range markers retain overlap order and require bounded source ranges and paint" {
    const items = [_]Marker{
        .{ .range = .{ .start = 0, .end = 100 }, .color = 0 },
        .{ .range = .{ .start = 2, .end = 4 }, .kind = .underline, .color = 0x123456 },
        .{ .range = .{ .start = 2, .end = 8 }, .color = 0xffffff },
        .{ .range = .{ .start = 101, .end = 103 }, .color = 0 },
    };
    try validate(&items, 4);
    const entries = try capture(std.testing.allocator, &items);
    defer std.testing.allocator.free(entries);
    try validateOwned(entries, 4);
    for (0..105) |start| {
        var expected: usize = 0;
        while (expected < entries.len and entries[expected].maximum_end <= start) : (expected += 1) {}
        try std.testing.expectEqual(expected, firstOverlap(entries, start));
    }
    try std.testing.expectEqual(@as(usize, 0), firstOverlap(&.{}, 0));
    try std.testing.expectError(error.RangeMarkerCapacityExceeded, validate(&items, 3));
    var invalid = items;
    invalid[2].range.start = 1;
    try std.testing.expectError(error.InvalidRangeMarker, validate(&invalid, 4));
    inline for (.{ @as(f32, 0), -1, 17, std.math.inf(f32), std.math.nan(f32) }) |thickness| {
        try std.testing.expectError(error.InvalidRangeMarker, validate(&.{.{ .range = .{ .start = 0, .end = 1 }, .color = 0, .thickness = thickness }}, 1));
    }
    try std.testing.expectError(error.InvalidRangeMarker, validate(&.{.{ .range = .{ .start = 1, .end = 1 }, .color = 0 }}, 1));
    try std.testing.expectError(error.InvalidRangeMarker, validate(&.{.{ .range = .{ .start = 2, .end = 1 }, .color = 0 }}, 1));
    try std.testing.expectError(error.InvalidRangeMarker, validate(&.{.{ .range = .{ .start = 0, .end = 1 }, .color = 0x1000000 }}, 1));
    var work: Work = .{ .remaining = 3 };
    try work.take(3);
    try work.take(0);
    try std.testing.expectError(error.RangeMarkerWorkExceeded, work.take(1));
}
