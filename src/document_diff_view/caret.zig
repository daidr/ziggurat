const std = @import("std");
const diff = @import("ziggurat_document_diff");

pub const Location = struct { index: ?usize = null, inside: bool = false };
pub const Source = struct { side_a: bool, bytes: usize, last_line: usize };

fn bounds(hunk: diff.Hunk, side_a: bool) diff.Side {
    return if (side_a) hunk.a else hunk.b;
}
fn start(selected: diff.Side, source: Source) usize {
    if (selected.lines.start == selected.lines.end and selected.bytes.start == selected.bytes.end and selected.bytes.end == source.bytes) return @min(selected.lines.start, source.last_line);
    return selected.lines.start;
}
/// Borrow accepted, ordered source ranges. Empty EOF ranges belong to the
/// source's real terminal caret line, including text without a final LF.
/// Equal effective starts prefer the last result item. No visible-row lookup,
/// source scan, allocation or selected-hunk state participates in this query.
pub fn locate(hunks: []const diff.Hunk, line: usize, source: Source) Location {
    var unused: usize = 0;
    return locateInner(hunks, line, source, false, &unused);
}
fn locateInner(hunks: []const diff.Hunk, line: usize, source: Source, comptime measured: bool, comparisons: *usize) Location {
    std.debug.assert(line <= source.last_line);
    var low: usize = 0;
    var high = hunks.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (measured) comparisons.* += 1;
        if (start(bounds(hunks[middle], source.side_a), source) <= line) low = middle + 1 else high = middle;
    }
    if (low == 0) return .{};
    const index = low - 1;
    const selected = bounds(hunks[index], source.side_a);
    return .{ .index = index, .inside = if (selected.lines.start == selected.lines.end) start(selected, source) == line else line < selected.lines.end };
}

fn item(a0: usize, a1: usize, b0: usize, b1: usize) diff.Hunk {
    return .{ .a = .{ .lines = .{ .start = a0, .end = a1 }, .bytes = .{ .start = a0 * 2, .end = a1 * 2 } }, .b = .{ .lines = .{ .start = b0, .end = b1 }, .bytes = .{ .start = b0 * 2, .end = b1 * 2 } } };
}
test "caret hunk queries use half open source lines and empty insertion points on both sides" {
    const hunks = [_]diff.Hunk{ item(2, 4, 2, 3), item(6, 6, 5, 7), item(9, 11, 10, 10) };
    const a: Source = .{ .side_a = true, .bytes = 24, .last_line = 12 };
    const b: Source = .{ .side_a = false, .bytes = 22, .last_line = 11 };
    const cases = [_]struct { source: Source, line: usize, index: ?usize, inside: bool }{
        .{ .source = a, .line = 0, .index = null, .inside = false },
        .{ .source = a, .line = 2, .index = 0, .inside = true },
        .{ .source = a, .line = 3, .index = 0, .inside = true },
        .{ .source = a, .line = 4, .index = 0, .inside = false },
        .{ .source = a, .line = 6, .index = 1, .inside = true },
        .{ .source = a, .line = 8, .index = 1, .inside = false },
        .{ .source = a, .line = 10, .index = 2, .inside = true },
        .{ .source = a, .line = 12, .index = 2, .inside = false },
        .{ .source = b, .line = 1, .index = null, .inside = false },
        .{ .source = b, .line = 2, .index = 0, .inside = true },
        .{ .source = b, .line = 3, .index = 0, .inside = false },
        .{ .source = b, .line = 6, .index = 1, .inside = true },
        .{ .source = b, .line = 7, .index = 1, .inside = false },
        .{ .source = b, .line = 10, .index = 2, .inside = true },
        .{ .source = b, .line = 11, .index = 2, .inside = false },
    };
    for (cases) |case| try std.testing.expectEqual(Location{ .index = case.index, .inside = case.inside }, locate(&hunks, case.line, case.source));
    try std.testing.expectEqual(Location{}, locate(&.{}, 0, .{ .side_a = true, .bytes = 0, .last_line = 0 }));
}

test "equal source boundaries and folded EOF points choose the last result item" {
    const equal = [_]diff.Hunk{ item(0, 0, 0, 1), item(0, 0, 1, 2), item(0, 1, 2, 3) };
    try std.testing.expectEqual(Location{ .index = 2, .inside = true }, locate(&equal, 0, .{ .side_a = true, .bytes = 2, .last_line = 0 }));
    const eof = [_]diff.Hunk{ item(0, 1, 0, 1), item(1, 1, 1, 2), item(1, 1, 2, 3) };
    try std.testing.expectEqual(Location{ .index = 2, .inside = true }, locate(&eof, 0, .{ .side_a = true, .bytes = 2, .last_line = 0 }));
    try std.testing.expectEqual(Location{ .index = 0, .inside = true }, locate(eof[0..1], 0, .{ .side_a = true, .bytes = 2, .last_line = 0 }));
    const empty = [_]diff.Hunk{item(0, 0, 0, 3)};
    try std.testing.expectEqual(Location{ .index = 0, .inside = true }, locate(&empty, 0, .{ .side_a = true, .bytes = 0, .last_line = 0 }));
}

fn linear(hunks: []const diff.Hunk, line: usize, source: Source) Location {
    var found: Location = .{};
    for (hunks, 0..) |hunk, at| {
        const selected = if (source.side_a) hunk.a else hunk.b;
        var first = selected.lines.start;
        if (selected.lines.start == selected.lines.end and selected.bytes.start == source.bytes) first = source.last_line;
        if (first > line) continue;
        found = .{ .index = at, .inside = if (selected.lines.start == selected.lines.end) first == line else selected.lines.end > line };
    }
    return found;
}
test "binary source lookup agrees with an independent linear oracle including repeated starts and EOF" {
    var random = std.Random.DefaultPrng.init(0x47f13a);
    var hunks: [128]diff.Hunk = undefined;
    for (0..1000) |_| {
        const count = random.random().uintLessThan(usize, hunks.len + 1);
        var line: usize = 0;
        for (hunks[0..count]) |*hunk| {
            const len = random.random().uintLessThan(usize, 4);
            hunk.* = item(line, line + len, line, line + len);
            line += len + random.random().uintLessThan(usize, 3);
        }
        const final_lf = random.random().boolean();
        const source: Source = .{ .side_a = random.random().boolean(), .bytes = line * 2, .last_line = if (final_lf or line == 0) line else line - 1 };
        for (0..source.last_line + 1) |at| try std.testing.expectEqual(linear(hunks[0..count], at, source), locate(hunks[0..count], at, source));
    }
}

test "65536 hunk queries need at most seventeen metadata comparisons" {
    const hunks = try std.testing.allocator.alloc(diff.Hunk, 65536);
    defer std.testing.allocator.free(hunks);
    for (hunks, 0..) |*hunk, at| hunk.* = item(2 * at + 1, 2 * at + 2, 2 * at + 1, 2 * at + 2);
    const source: Source = .{ .side_a = true, .bytes = (2 * hunks.len + 1) * 2, .last_line = 2 * hunks.len + 1 };
    for ([_]usize{ 0, 1, 65536, source.last_line }) |line| {
        var comparisons: usize = 0;
        try std.testing.expectEqual(linear(hunks, line, source), locateInner(hunks, line, source, true, &comparisons));
        try std.testing.expect(comparisons <= 17);
    }
}
