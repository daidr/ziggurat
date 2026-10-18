const std = @import("std");
const diff = @import("ziggurat_document_diff");
pub const units: f64 = 64;
pub const Segment = struct { first: usize, count: usize, a: usize, b: usize, count_a: usize, count_b: usize, hunk: ?usize };
pub const Row = struct { a: ?usize, b: ?usize, hunk: ?usize };
pub const Anchor = struct { row: usize = 0, inset: u64 = 0 };
/// Dense integer height/Fenwick planes plus compact hunk segments. Construction
/// touches metadata only, never document lines/text or native shaping.
pub const Index = struct {
    allocator: std.mem.Allocator,
    segments: []Segment,
    segment_count: usize,
    heights: []u64,
    tree: []u64,
    bytes: usize,
    pub fn create(allocator: std.mem.Allocator, result: *const diff.Result, row_limit: usize, byte_limit: usize, estimate: f32) !Index {
        if (row_limit == 0 or row_limit > 2097152 or byte_limit > 1024 * 1024 * 1024) return error.InvalidLimits;
        const initial = try ticks(estimate);
        const capacity = std.math.add(usize, try mul(result.hunks.len, 2), 1) catch return error.CapacityExceeded;
        const segment_bytes = try mul(capacity, @sizeOf(Segment));
        if (segment_bytes > byte_limit) return error.CapacityExceeded;
        const segments = try allocator.alloc(Segment, capacity);
        errdefer allocator.free(segments);
        var count: usize = 0;
        var total: usize = 0;
        var a: usize = 0;
        var b: usize = 0;
        for (result.hunks, 0..) |hunk, at| {
            if (hunk.a.lines.start < a or hunk.b.lines.start < b or hunk.a.lines.start - a != hunk.b.lines.start - b or hunk.a.lines.end < hunk.a.lines.start or hunk.b.lines.end < hunk.b.lines.start) return error.InvalidResult;
            try segment(segments, &count, &total, a, b, hunk.a.lines.start - a, hunk.b.lines.start - b, null, row_limit);
            try segment(segments, &count, &total, hunk.a.lines.start, hunk.b.lines.start, hunk.a.lines.end - hunk.a.lines.start, hunk.b.lines.end - hunk.b.lines.start, at, row_limit);
            a = hunk.a.lines.end;
            b = hunk.b.lines.end;
        }
        if (a > result.stats.lines_a or b > result.stats.lines_b or result.stats.lines_a - a != result.stats.lines_b - b) return error.InvalidResult;
        try segment(segments, &count, &total, a, b, result.stats.lines_a - a, result.stats.lines_b - b, null, row_limit);
        const bytes = std.math.add(usize, segment_bytes, try mul(try std.math.add(usize, try mul(total, 2), 1), @sizeOf(u64))) catch return error.CapacityExceeded;
        if (bytes > byte_limit) return error.CapacityExceeded;
        const heights = try allocator.alloc(u64, total);
        errdefer allocator.free(heights);
        const tree = try allocator.alloc(u64, total + 1);
        @memset(heights, initial);
        @memset(tree, 0);
        for (1..tree.len) |i| {
            tree[i] += initial;
            const parent = i + lowbit(i);
            if (parent < tree.len) tree[parent] += tree[i];
        }
        return .{ .allocator = allocator, .segments = segments, .segment_count = count, .heights = heights, .tree = tree, .bytes = bytes };
    }
    pub fn close(self: *Index) void {
        self.allocator.free(self.segments);
        self.allocator.free(self.heights);
        self.allocator.free(self.tree);
    }
    pub fn row(self: *const Index, at: usize) Row {
        std.debug.assert(at < self.heights.len);
        var low: usize = 0;
        var high = self.segment_count;
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            if (self.segments[middle].first <= at) low = middle else high = middle;
        }
        const value = self.segments[low];
        const offset = at - value.first;
        return .{ .a = if (offset < value.count_a) value.a + offset else null, .b = if (offset < value.count_b) value.b + offset else null, .hunk = value.hunk };
    }
    pub fn hunkRow(self: *const Index, hunk: usize) ?usize {
        for (self.segments[0..self.segment_count]) |value| if (value.hunk == hunk) return value.first;
        return null;
    }
    pub fn prefix(self: *const Index, end: usize) u64 {
        var at = end;
        var total: u64 = 0;
        while (at != 0) : (at -= lowbit(at)) total += self.tree[at];
        return total;
    }
    pub fn set(self: *Index, at: usize, height: u64) void {
        std.debug.assert(at < self.heights.len and height > 0 and height <= 64000000);
        const previous = self.heights[at];
        self.heights[at] = height;
        var i = at + 1;
        while (i < self.tree.len) : (i += lowbit(i)) {
            if (height >= previous) self.tree[i] += height - previous else self.tree[i] -= previous - height;
        }
    }
    pub fn locate(self: *const Index, offset: u64) Anchor {
        if (self.heights.len == 0) return .{};
        const target = @min(offset, self.prefix(self.heights.len) - 1);
        var at: usize = 0;
        var sum: u64 = 0;
        var bit = std.math.floorPowerOfTwo(usize, self.heights.len);
        while (bit != 0) : (bit >>= 1) {
            const next = at + bit;
            if (next < self.tree.len and self.tree[next] <= target - sum) {
                at = next;
                sum += self.tree[next];
            }
        }
        return .{ .row = at, .inset = target - sum };
    }
    pub fn position(self: *const Index, anchor: Anchor) u64 {
        if (self.heights.len == 0) return 0;
        const at = @min(anchor.row, self.heights.len - 1);
        return self.prefix(at) + @min(anchor.inset, self.heights[at] - 1);
    }
    pub fn clamp(self: *const Index, offset: u64, viewport: u64) Anchor {
        return self.locate(@min(offset, self.prefix(self.heights.len) -| viewport));
    }
};
fn lowbit(i: usize) usize {
    return i & (~i + 1);
}
fn mul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.CapacityExceeded;
}
pub fn ticks(height: f32) !u64 {
    if (!std.math.isFinite(height) or height <= 0 or height > 1000000) return error.InvalidHeight;
    return @intFromFloat(@ceil(@as(f64, height) * units));
}
pub fn dip(height: u64) f64 {
    return @as(f64, @floatFromInt(height)) / units;
}
fn segment(segments: []Segment, count: *usize, total: *usize, a: usize, b: usize, na: usize, nb: usize, hunk: ?usize, limit: usize) !void {
    const length = @max(na, nb);
    if (length == 0) return;
    if (length > limit -| total.*) return error.RowCapacityExceeded;
    segments[count.*] = .{ .first = total.*, .count = length, .a = a, .b = b, .count_a = na, .count_b = nb, .hunk = hunk };
    count.* += 1;
    total.* += length;
}
test "aligned metadata pairs insertion blanks without reading source and Fenwick matches linear" {
    var result: diff.Result = .{ .allocator = std.testing.allocator, .storage = &.{}, .hunks = &.{.{ .a = .{ .lines = .{ .start = 1, .end = 1 }, .bytes = .{ .start = 2, .end = 2 } }, .b = .{ .lines = .{ .start = 1, .end = 3 }, .bytes = .{ .start = 2, .end = 6 } } }}, .a = .{ .revision = 0, .text_version = 0, .bytes = 6 }, .b = .{ .revision = 0, .text_version = 0, .bytes = 10 }, .stats = .{ .lines_a = 3, .lines_b = 5 } };
    var index = try Index.create(std.testing.allocator, &result, 100, 10000, 20);
    defer index.close();
    try std.testing.expectEqual(@as(usize, 5), index.heights.len);
    try std.testing.expectEqual(Row{ .a = null, .b = 1, .hunk = 0 }, index.row(1));
    try std.testing.expectEqual(Row{ .a = 1, .b = 3, .hunk = null }, index.row(3));
    var random = std.Random.DefaultPrng.init(771);
    for (0..1000) |_| {
        const at = random.random().uintLessThan(usize, index.heights.len);
        index.set(at, random.random().uintLessThan(u64, 100000) + 1);
        var sum: u64 = 0;
        for (index.heights, 0..) |height, i| {
            try std.testing.expectEqual(sum, index.prefix(i));
            try std.testing.expectEqual(Anchor{ .row = i, .inset = 0 }, index.locate(sum));
            try std.testing.expectEqual(Anchor{ .row = i, .inset = height - 1 }, index.locate(sum + height - 1));
            sum += height;
        }
        try std.testing.expectEqual(sum, index.prefix(index.heights.len));
    }
}

fn metadata(lines: usize) diff.Result {
    return .{ .allocator = std.testing.allocator, .storage = &.{}, .hunks = &.{}, .a = .{ .revision = 1, .text_version = 1, .bytes = 0 }, .b = .{ .revision = 1, .text_version = 1, .bytes = 0 }, .stats = .{ .lines_a = lines, .lines_b = lines } };
}
fn allocationProbe(allocator: std.mem.Allocator) !void {
    var result = metadata(100);
    var index = try Index.create(allocator, &result, 100, 20000, 0.1);
    defer index.close();
    try std.testing.expectEqual(@as(u64, 7), index.heights[0]);
    try std.testing.expectEqual(@as(u64, 700), index.prefix(100));
}
test "index allocation failures, exact fractional ticks and explicit hard limits" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
    var result = metadata(100);
    try std.testing.expectError(error.RowCapacityExceeded, Index.create(std.testing.allocator, &result, 99, 20000, 20));
    try std.testing.expectError(error.CapacityExceeded, Index.create(std.testing.allocator, &result, 100, 100, 20));
    try std.testing.expectError(error.InvalidHeight, Index.create(std.testing.allocator, &result, 100, 20000, std.math.nan(f32)));
    result.stats.lines_b += 1;
    try std.testing.expectError(error.InvalidResult, Index.create(std.testing.allocator, &result, 100, 20000, 20));
    var empty = metadata(0);
    var index = try Index.create(std.testing.allocator, &empty, 1, 1000, 20);
    defer index.close();
    try std.testing.expectEqual(@as(usize, 0), index.heights.len);
    try std.testing.expectEqual(Anchor{}, index.locate(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 0), index.position(.{ .row = 100, .inset = 100 }));
}
test "one hundred thousand equal rows use constant segment metadata and bounded integer totals" {
    var result = metadata(100000);
    var index = try Index.create(std.testing.allocator, &result, 100000, 2000000, 1000000);
    defer index.close();
    try std.testing.expectEqual(@as(usize, 1), index.segment_count);
    try std.testing.expect(index.bytes < 1600100);
    try std.testing.expectEqual(@as(u64, 6400000000000), index.prefix(100000));
    for ([_]usize{ 0, 1, 31000, 99999 }) |row| {
        try std.testing.expectEqual(Row{ .a = row, .b = row, .hunk = null }, index.row(row));
        const position = index.prefix(row);
        try std.testing.expectEqual(Anchor{ .row = row, .inset = 1 }, index.locate(position + 1));
        index.set(row, 1);
        try std.testing.expectEqual(Anchor{ .row = row }, index.locate(position));
        try std.testing.expectEqual(Anchor{ .row = row }, index.clamp(position, 0));
    }
}
