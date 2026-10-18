const std = @import("std");
const tree = @import("tree.zig");

pub const Range = struct { start: usize, end: usize };
pub const Selection = struct {
    anchor: usize = 0,
    caret: usize = 0,
    pub fn range(self: Selection) Range {
        return .{ .start = @min(self.anchor, self.caret), .end = @max(self.anchor, self.caret) };
    }
};
pub const View = struct { items: []const Selection, primary: usize };
const Many = struct { refs: usize = 1, primary: usize, items: []Selection };

/// Single selection stays inline. Multiple selections are immutable shared
/// versions; all retain/release operations belong to the document owner.
pub const Set = union(enum) {
    single: Selection,
    multiple: *Many,
    pub fn count(self: Set) usize {
        return switch (self) {
            .single => 1,
            .multiple => |value| value.items.len,
        };
    }
    pub fn primaryIndex(self: Set) usize {
        return switch (self) {
            .single => 0,
            .multiple => |value| value.primary,
        };
    }
    pub fn at(self: Set, index: usize) Selection {
        return switch (self) {
            .single => |value| blk: {
                std.debug.assert(index == 0);
                break :blk value;
            },
            .multiple => |value| value.items[index],
        };
    }
    pub fn primary(self: Set) Selection {
        return self.at(self.primaryIndex());
    }
    pub fn retain(self: Set) Set {
        if (self == .multiple) self.multiple.refs += 1;
        return self;
    }
    pub fn release(self: Set, memory: *tree.Memory) void {
        if (self != .multiple) return;
        const value = self.multiple;
        std.debug.assert(value.refs > 0);
        value.refs -= 1;
        if (value.refs != 0) return;
        memory.free(Selection, value.items);
        memory.destroy(Many, value);
    }
    pub fn copy(self: Set, destination: []Selection) !View {
        if (destination.len < self.count()) return error.CapacityExceeded;
        for (destination[0..self.count()], 0..) |*value, index| value.* = self.at(index);
        return .{ .items = destination[0..self.count()], .primary = self.primaryIndex() };
    }
    pub fn eql(a: Set, b: Set) bool {
        if (a.count() != b.count() or a.primaryIndex() != b.primaryIndex()) return false;
        for (0..a.count()) |index| if (!std.meta.eql(a.at(index), b.at(index))) return false;
        return true;
    }
};

/// Input order is document order. Equal starts and overlapping ranges are
/// rejected, including a collapsed caret at a range's start/interior.
/// Adjacent non-overlapping ranges are accepted, as is a caret at a prior end.
pub fn validate(items: []const Selection, primary: usize, limit: usize) !void {
    if (items.len == 0 or primary >= items.len) return error.InvalidSelections;
    if (items.len > limit) return error.CapacityExceeded;
    var previous: ?Range = null;
    for (items) |value| {
        const range = value.range();
        if (previous) |before| if (range.start <= before.start or range.start < before.end) return error.OverlappingSelections;
        previous = range;
    }
}
pub fn create(memory: *tree.Memory, items: []const Selection, primary: usize, limit: usize) !Set {
    try validate(items, primary, limit);
    if (items.len == 1) return .{ .single = items[0] };
    const value = try memory.create(Many);
    errdefer memory.destroy(Many, value);
    const owned = try memory.alloc(Selection, items.len);
    @memcpy(owned, items);
    value.* = .{ .primary = primary, .items = owned };
    return .{ .multiple = value };
}

pub const Record = struct { selected: Selection, primary: bool };
pub fn normalize(input: []const Selection, primary: usize, scratch: []Record, output: []Selection) !View {
    if (input.len == 0 or primary >= input.len) return error.InvalidSelections;
    if (scratch.len < input.len or output.len < input.len) return error.CapacityExceeded;
    for (input, 0..) |selected, at| scratch[at] = .{ .selected = selected, .primary = at == primary };
    const records = scratch[0..input.len];
    std.mem.sort(Record, records, {}, struct {
        fn less(_: void, a: Record, b: Record) bool {
            const x = a.selected.range();
            const y = b.selected.range();
            return x.start < y.start or (x.start == y.start and (x.end < y.end or (x.end == y.end and a.primary and !b.primary)));
        }
    }.less);
    var group = records[0];
    var low = group.selected.range().start;
    var high = group.selected.range().end;
    var count: usize = 0;
    var result_primary: usize = 0;
    for (records[1..]) |record| {
        const range = record.selected.range();
        if (range.start < high or range.start == low or (range.start == high and (low == high or range.start == range.end))) {
            high = @max(high, range.end);
            if (record.primary) group = record;
            continue;
        }
        output[count] = if (group.selected.anchor <= group.selected.caret) .{ .anchor = low, .caret = high } else .{ .anchor = high, .caret = low };
        if (group.primary) result_primary = count;
        count += 1;
        group = record;
        low = range.start;
        high = range.end;
    }
    output[count] = if (group.selected.anchor <= group.selected.caret) .{ .anchor = low, .caret = high } else .{ .anchor = high, .caret = low };
    if (group.primary) result_primary = count;
    return .{ .items = output[0 .. count + 1], .primary = result_primary };
}
pub fn normalized(memory: *tree.Memory, input: []const Selection, primary: usize, limit: usize) !Set {
    if (input.len == 0 or primary >= input.len) return error.InvalidSelections;
    if (input.len > limit) return error.CapacityExceeded;
    if (input.len == 1) return .{ .single = input[0] };
    const scratch = try memory.alloc(Record, input.len);
    defer memory.free(Record, scratch);
    const output = try memory.alloc(Selection, input.len);
    defer memory.free(Selection, output);
    const result = try normalize(input, primary, scratch, output);
    return create(memory, result.items, result.primary, limit);
}

pub const Affinity = enum { before, after };
pub const Replacement = struct { range: Range, text: []const u8 };
/// Map an original scalar boundary through sorted, disjoint edits. Endpoints
/// within a replacement collapse to its end; a boundary exactly at its start
/// follows the explicit affinity. No signed byte delta can overflow.
pub fn mapPosition(position: usize, edits: []const Replacement, affinity: Affinity) !usize {
    var old_end: usize = 0;
    var new_end: usize = 0;
    for (edits) |edit| {
        if (position < edit.range.start or (position == edit.range.start and affinity == .before)) return std.math.add(usize, new_end, position - old_end) catch error.CapacityExceeded;
        const start = std.math.add(usize, new_end, edit.range.start - old_end) catch return error.CapacityExceeded;
        const end = std.math.add(usize, start, edit.text.len) catch return error.CapacityExceeded;
        if (position < edit.range.end) return end;
        old_end = edit.range.end;
        new_end = end;
    }
    return std.math.add(usize, new_end, position - old_end) catch error.CapacityExceeded;
}

test "selection versions validate before allocation and retain immutable primary direction" {
    var memory: tree.Memory = .{ .allocator = std.testing.allocator, .limits = .{ .live_bytes = 65536, .nodes = 100, .candidate_bytes = 65536 } };
    const input = [_]Selection{ .{ .anchor = 2, .caret = 0 }, .{ .anchor = 4, .caret = 4 }, .{ .anchor = 8, .caret = 6 } };
    const set = try create(&memory, &input, 2, 64);
    defer set.release(&memory);
    const held = set.retain();
    defer held.release(&memory);
    try std.testing.expectEqual(input[2], held.primary());
    var output: [3]Selection = undefined;
    try std.testing.expectEqualDeep(View{ .items = &input, .primary = 2 }, try set.copy(&output));
    var short: [2]Selection = @splat(.{ .anchor = 9, .caret = 9 });
    try std.testing.expectError(error.CapacityExceeded, set.copy(&short));
    try std.testing.expectEqual(@as(usize, 9), short[0].caret);
    try std.testing.expectError(error.OverlappingSelections, validate(&.{ .{ .caret = 3 }, .{ .anchor = 2, .caret = 4 } }, 0, 64));
    try std.testing.expectError(error.OverlappingSelections, validate(&.{ .{}, .{} }, 0, 64));
    try std.testing.expectError(error.InvalidSelections, validate(&.{}, 0, 64));
}
test "mapping positions uses ordered original coordinates without signed deltas" {
    const edits = [_]Replacement{ .{ .range = .{ .start = 2, .end = 4 }, .text = "abcde" }, .{ .range = .{ .start = 8, .end = 10 }, .text = "" }, .{ .range = .{ .start = 12, .end = 12 }, .text = "XY" } };
    try std.testing.expectEqual(@as(usize, 2), try mapPosition(2, &edits, .before));
    try std.testing.expectEqual(@as(usize, 7), try mapPosition(2, &edits, .after));
    try std.testing.expectEqual(@as(usize, 7), try mapPosition(3, &edits, .before));
    try std.testing.expectEqual(@as(usize, 7), try mapPosition(4, &edits, .before));
    try std.testing.expectEqual(@as(usize, 11), try mapPosition(9, &edits, .after));
    try std.testing.expectEqual(@as(usize, 13), try mapPosition(12, &edits, .before));
    try std.testing.expectEqual(@as(usize, 15), try mapPosition(12, &edits, .after));
    try std.testing.expectEqual(@as(usize, 16), try mapPosition(13, &edits, .after));
}

test "normalization merges overlap and duplicate carets while preserving primary direction" {
    const input = [_]Selection{ .{ .anchor = 10, .caret = 7 }, .{ .anchor = 2, .caret = 5 }, .{ .anchor = 8, .caret = 4 }, .{ .anchor = 20, .caret = 20 }, .{ .anchor = 20, .caret = 20 } };
    var scratch: [input.len]Record = undefined;
    var out: [input.len]Selection = undefined;
    const result = try normalize(&input, 0, &scratch, &out);
    try std.testing.expectEqual(@as(usize, 0), result.primary);
    try std.testing.expectEqualSlices(Selection, &.{ .{ .anchor = 10, .caret = 2 }, .{ .anchor = 20, .caret = 20 } }, result.items);
    const second = try normalize(&input, 4, &scratch, &out);
    try std.testing.expectEqual(@as(usize, 1), second.primary);
}
