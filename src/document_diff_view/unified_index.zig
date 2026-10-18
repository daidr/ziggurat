const std = @import("std");
const diff = @import("ziggurat_document_diff");
const aligned = @import("index.zig");
pub const Index = aligned.Index;
pub const Row = aligned.Row;
pub const Kind = enum { common, deleted, added };

pub fn kind(row: Row) Kind {
    if (row.a != null and row.b != null) return .common;
    if (row.a != null) return .deleted;
    std.debug.assert(row.b != null);
    return .added;
}

/// Derive common / deleted / added display records without reading source text.
/// The returned owner reuses the aligned integer Fenwick implementation; each
/// hunk expands to two ordered ranges instead of pairing its source records.
/// byte_limit bounds retained index plus temporary hunk metadata at its peak.
pub fn create(allocator: std.mem.Allocator, result: *const diff.Result, row_limit: usize, byte_limit: usize, estimate: f32) !Index {
    if (row_limit == 0 or row_limit > 2097152 or byte_limit > 1024 * 1024 * 1024) return error.InvalidLimits;
    _ = try aligned.ticks(estimate);
    if (!result.isOwned()) return error.ResultMoved;
    if (result.hunks.len > 65536) return error.CapacityExceeded;
    const count = std.math.mul(usize, result.hunks.len, 2) catch return error.CapacityExceeded;
    const scratch_bytes = std.math.mul(usize, count, @sizeOf(diff.Hunk)) catch return error.CapacityExceeded;
    if (scratch_bytes > byte_limit) return error.CapacityExceeded;
    const expanded = try allocator.alloc(diff.Hunk, count);
    defer allocator.free(expanded);
    for (result.hunks, 0..) |hunk, at| {
        expanded[at * 2] = .{ .a = hunk.a, .b = .{ .lines = .{ .start = hunk.b.lines.start, .end = hunk.b.lines.start }, .bytes = .{ .start = hunk.b.bytes.start, .end = hunk.b.bytes.start } } };
        expanded[at * 2 + 1] = .{ .a = .{ .lines = .{ .start = hunk.a.lines.end, .end = hunk.a.lines.end }, .bytes = .{ .start = hunk.a.bytes.end, .end = hunk.a.bytes.end } }, .b = hunk.b };
    }
    // Borrowed metadata only: never deinit this synthetic descriptor. It owns
    // no Result storage and retains neither Readers nor source text.
    const description: diff.Result = .{ .allocator = allocator, .storage = &.{}, .hunks = expanded, .a = result.a, .b = result.b, .stats = result.stats, .owned = false };
    var value = try Index.create(allocator, &description, row_limit, byte_limit - scratch_bytes, estimate);
    for (value.segments[0..value.segment_count]) |*segment| if (segment.hunk) |ordinal| {
        segment.hunk = ordinal / 2;
    };
    return value;
}

fn fixture(hunks: []const diff.Hunk, a: usize, b: usize) diff.Result {
    return .{ .allocator = std.testing.allocator, .storage = &.{}, .hunks = hunks, .a = .{ .revision = 1, .text_version = 1, .bytes = 0 }, .b = .{ .revision = 1, .text_version = 1, .bytes = 0 }, .stats = .{ .lines_a = a, .lines_b = b } };
}
const replacement: diff.Hunk = .{ .a = .{ .lines = .{ .start = 1, .end = 3 }, .bytes = .{ .start = 2, .end = 6 } }, .b = .{ .lines = .{ .start = 1, .end = 4 }, .bytes = .{ .start = 2, .end = 8 } } };
test "unified rows preserve source order and put deleted records before added records" {
    var model = fixture(&.{replacement}, 5, 6);
    var value = try create(std.testing.allocator, &model, 100, 10000, 20);
    defer value.close();
    const expected: []const Row = &.{ .{ .a = 0, .b = 0, .hunk = null }, .{ .a = 1, .b = null, .hunk = 0 }, .{ .a = 2, .b = null, .hunk = 0 }, .{ .a = null, .b = 1, .hunk = 0 }, .{ .a = null, .b = 2, .hunk = 0 }, .{ .a = null, .b = 3, .hunk = 0 }, .{ .a = 3, .b = 4, .hunk = null }, .{ .a = 4, .b = 5, .hunk = null } };
    try std.testing.expectEqual(expected.len, value.heights.len);
    for (expected, 0..) |row, at| {
        try std.testing.expectEqual(row, value.row(at));
        try std.testing.expectEqual(if (row.a != null and row.b != null) Kind.common else if (row.a != null) Kind.deleted else Kind.added, kind(value.row(at)));
    }
    try std.testing.expectEqual(@as(usize, 1), value.hunkRow(0).?);
    try std.testing.expectEqual(@as(u64, 160 * 64), value.prefix(value.heights.len));
    // The input is borrowed and its real ranges remain unchanged.
    try std.testing.expectEqual(replacement, model.hunks[0]);
}
test "unified height updates use the same fractional Fenwick oracle" {
    var model = fixture(&.{replacement}, 5, 6);
    var value = try create(std.testing.allocator, &model, 100, 10000, 0.01);
    defer value.close();
    var random = std.Random.DefaultPrng.init(721);
    for (0..1000) |_| {
        value.set(random.random().uintLessThan(usize, value.heights.len), random.random().uintLessThan(u64, 100000) + 1);
        var total: u64 = 0;
        for (value.heights, 0..) |height, at| {
            try std.testing.expectEqual(total, value.prefix(at));
            try std.testing.expectEqual(aligned.Anchor{ .row = at }, value.locate(total));
            try std.testing.expectEqual(aligned.Anchor{ .row = at, .inset = height - 1 }, value.locate(total + height - 1));
            total += height;
        }
        try std.testing.expectEqual(total, value.prefix(value.heights.len));
    }
}
fn allocationProbe(allocator: std.mem.Allocator) !void {
    var model = fixture(&.{replacement}, 5, 6);
    var value = try create(allocator, &model, 100, 10000, 20);
    defer value.close();
    try std.testing.expectEqual(@as(usize, 8), value.heights.len);
}
test "unified scratch and retained allocations obey peak budgets and OOM ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
    var model = fixture(&.{replacement}, 5, 6);
    try std.testing.expectError(error.CapacityExceeded, create(std.testing.allocator, &model, 100, 1, 20));
    try std.testing.expectError(error.CapacityExceeded, create(std.testing.allocator, &model, 100, 400, 20));
    try std.testing.expectError(error.RowCapacityExceeded, create(std.testing.allocator, &model, 7, 10000, 20));
    var moved = try model.take();
    defer moved.deinit();
    try std.testing.expectError(error.ResultMoved, create(std.testing.allocator, &model, 100, 10000, 20));
    model = try moved.take();
    model.hunks = &.{};
    model.stats.lines_a = 0;
    model.stats.lines_b = 0;
    var empty = try create(std.testing.allocator, &model, 100, 10000, 20);
    defer empty.close();
    try std.testing.expectEqual(@as(usize, 0), empty.heights.len);
}
test "unified insert only and a hundred thousand common records stay metadata only" {
    var model = fixture(&.{.{ .a = .{ .lines = .{ .start = 0, .end = 0 }, .bytes = .{ .start = 0, .end = 0 } }, .b = .{ .lines = .{ .start = 0, .end = 3 }, .bytes = .{ .start = 0, .end = 6 } } }}, 0, 3);
    var inserted = try create(std.testing.allocator, &model, 100, 10000, 20);
    defer inserted.close();
    try std.testing.expectEqual(@as(usize, 0), inserted.hunkRow(0).?);
    for (0..3) |line| try std.testing.expectEqual(Row{ .a = null, .b = line, .hunk = 0 }, inserted.row(line));
    model.hunks = &.{};
    model.stats.lines_a = 100000;
    model.stats.lines_b = 100000;
    var equal = try create(std.testing.allocator, &model, 100000, 2000000, 20);
    defer equal.close();
    try std.testing.expectEqual(@as(usize, 1), equal.segment_count);
    try std.testing.expect(equal.bytes < 1601000);
    try std.testing.expectEqual(Row{ .a = 99999, .b = 99999, .hunk = null }, equal.row(99999));
}

test "multiple unified hunks agree with an independent linear source record oracle" {
    var random = std.Random.DefaultPrng.init(613);
    for (0..300) |_| {
        var hunks: std.ArrayList(diff.Hunk) = .empty;
        defer hunks.deinit(std.testing.allocator);
        var expected: std.ArrayList(Row) = .empty;
        defer expected.deinit(std.testing.allocator);
        var a: usize = 0;
        var b: usize = 0;
        for (0..random.random().uintLessThan(usize, 40)) |ordinal| {
            const common = random.random().uintLessThan(usize, 6);
            for (0..common) |_| {
                try expected.append(std.testing.allocator, .{ .a = a, .b = b, .hunk = null });
                a += 1;
                b += 1;
            }
            const deleted = random.random().uintLessThan(usize, 6);
            const added = @max(@intFromBool(deleted == 0), random.random().uintLessThan(usize, 6));
            const hunk: diff.Hunk = .{ .a = .{ .lines = .{ .start = a, .end = a + deleted }, .bytes = .{ .start = a * 2, .end = (a + deleted) * 2 } }, .b = .{ .lines = .{ .start = b, .end = b + added }, .bytes = .{ .start = b * 2, .end = (b + added) * 2 } } };
            try hunks.append(std.testing.allocator, hunk);
            for (0..deleted) |_| {
                try expected.append(std.testing.allocator, .{ .a = a, .b = null, .hunk = ordinal });
                a += 1;
            }
            for (0..added) |_| {
                try expected.append(std.testing.allocator, .{ .a = null, .b = b, .hunk = ordinal });
                b += 1;
            }
        }
        for (0..random.random().uintLessThan(usize, 10)) |_| {
            try expected.append(std.testing.allocator, .{ .a = a, .b = b, .hunk = null });
            a += 1;
            b += 1;
        }
        const model = fixture(hunks.items, a, b);
        var value = try create(std.testing.allocator, &model, 10000, 1024 * 1024, 20);
        defer value.close();
        try std.testing.expectEqual(expected.items.len, value.heights.len);
        for (expected.items, 0..) |row, at| try std.testing.expectEqual(row, value.row(at));
        for (hunks.items, 0..) |_, ordinal| {
            const first = for (expected.items, 0..) |row, at| {
                if (row.hunk == ordinal) break at;
            } else return error.MissingOracleHunk;
            try std.testing.expectEqual(first, value.hunkRow(ordinal).?);
        }
    }
}
