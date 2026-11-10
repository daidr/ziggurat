//! Inlays: text shown in the lines that is not the Document's, as the type a
//! language server infers for a variable, a diagnostic or a blame at the end
//! of a line, or a suggestion after the caret. They are shaped into the
//! visible text at committed source bytes and drawn muted; carets, selections,
//! hit testing, accessibility and the native text client see only the
//! Document's bytes.
const std = @import("std");
const cache = @import("cache.zig");

/// How an inlay takes the caret. A `hint` sits before the source byte it is
/// at: a caret there shows after it, and a selection ending there does not
/// cover it. `trailing` text, as a diagnostic or a blame at a line's end, is
/// shown like a hint but treated like a suggestion: the caret stays before
/// it, and a selection to the end of the line does not cover it.
pub const Kind = enum { hint, trailing };
/// `offset` is a committed UTF-8 byte of the Document, `text` one line of at
/// most `max_text` bytes.
pub const Inlay = struct { offset: usize, text: []const u8, kind: Kind = .hint };
pub const max_text = 1024;

pub const Entry = struct { offset: usize, start: usize, len: usize, ghost: bool };
/// An owned set: the entries in offset order and their texts in one buffer.
pub const Set = struct {
    entries: []Entry = &.{},
    bytes: []u8 = &.{},
    pub fn free(self: *Set, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.bytes);
        self.* = .{};
    }
    pub fn text(self: *const Set, entry: Entry) []const u8 {
        return self.bytes[entry.start..][0..entry.len];
    }
};

pub fn validateText(value: []const u8) !void {
    if (value.len == 0 or value.len > max_text) return error.InvalidInlay;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidInlay;
}

/// Validate `definitions`, ascending by offset, and copy them.
pub fn capture(allocator: std.mem.Allocator, definitions: []const Inlay, limit: usize) !Set {
    if (definitions.len > limit) return error.InlayCapacityExceeded;
    var total: usize = 0;
    for (definitions, 0..) |item, at| {
        try validateText(item.text);
        if (at > 0 and item.offset < definitions[at - 1].offset) return error.InvalidOrder;
        total += item.text.len;
    }
    const entries = try allocator.alloc(Entry, definitions.len);
    errdefer allocator.free(entries);
    const bytes = try allocator.alloc(u8, total);
    var start: usize = 0;
    for (definitions, entries) |item, *entry| {
        @memcpy(bytes[start..][0..item.text.len], item.text);
        entry.* = .{ .offset = item.offset, .start = start, .len = item.text.len, .ghost = item.kind == .trailing };
        start += item.text.len;
    }
    return .{ .entries = entries, .bytes = bytes };
}

/// One replacement of an edit: source bytes `start..end` became `len` bytes.
/// An edit's changes ascend and do not overlap.
pub const Change = struct { start: usize, end: usize, len: usize };

/// Move the inlays of `set` with an edit's `changes`, or back with them when
/// `inverse` (an undo), as text typed at an inlay's byte goes before it and
/// an inlay in replaced text goes to the replacement's end.
pub fn move(set: *Set, changes: []const Change) void {
    moveDirected(set, changes, false);
}
pub fn moveBack(set: *Set, changes: []const Change) void {
    moveDirected(set, changes, true);
}
fn moveDirected(set: *Set, changes: []const Change, inverse: bool) void {
    const Span = struct { src_start: usize, src_end: usize, dst_end: usize };
    var next: usize = 0;
    var shift: i128 = 0;
    var last: ?Span = null;
    for (set.entries) |*entry| {
        while (next < changes.len) {
            const change = changes[next];
            const moved: usize = @intCast(@as(i128, change.start) + shift);
            const src_start = if (inverse) moved else change.start;
            if (src_start > entry.offset) break;
            const dst_start = if (inverse) change.start else moved;
            last = .{
                .src_start = src_start,
                .src_end = src_start + if (inverse) change.len else change.end - change.start,
                .dst_end = dst_start + if (inverse) change.end - change.start else change.len,
            };
            shift += @as(i128, change.len) - @as(i128, change.end - change.start);
            next += 1;
        }
        const span = last orelse continue;
        const after = entry.offset > span.src_end or (entry.offset == span.src_end and span.src_end > span.src_start);
        entry.offset = if (after) span.dst_end + (entry.offset - span.src_end) else span.dst_end;
    }
}

/// The text a suggestion shows: its first line, and " …" when there are more,
/// cut at a character to fit `buffer`, which holds at least 8 bytes.
pub fn suggestionShown(value: []const u8, buffer: []u8) []const u8 {
    const end = std.mem.indexOfAny(u8, value, "\r\n");
    const line = value[0 .. end orelse value.len];
    const room = if (end == null and line.len <= buffer.len) buffer.len else buffer.len - " …".len;
    var cut = @min(line.len, room);
    while (cut > 0 and cut < line.len and line[cut] & 0xC0 == 0x80) cut -= 1;
    @memcpy(buffer[0..cut], line[0..cut]);
    if (cut == line.len and end == null) return buffer[0..cut];
    @memcpy(buffer[cut..][0.." …".len], " …");
    return buffer[0 .. cut + " …".len];
}

/// Append to `out` the inlays at source bytes `start..end` of a batch, with
/// `suggestion` at its offset, relative to `start`. An inlay at `end` belongs
/// to the batch after, unless `last`.
pub const Shown = struct { offset: usize, text: []const u8 };
pub fn select(allocator: std.mem.Allocator, out: *std.ArrayList(cache.Inlay), set: ?*const Set, suggestion: ?Shown, start: usize, end: usize, last: bool) !void {
    const inside = struct {
        fn f(offset: usize, from: usize, to: usize, final: bool) bool {
            return offset >= from and (offset < to or (final and offset == to));
        }
    }.f;
    var placed = suggestion == null or !inside(suggestion.?.offset, start, end, last);
    if (set) |value| for (value.entries) |entry| {
        if (!inside(entry.offset, start, end, last)) continue;
        // A suggestion goes after the hints at its byte, where the caret is.
        if (!placed and suggestion.?.offset < entry.offset) {
            try out.append(allocator, .{ .at = suggestion.?.offset - start, .text = suggestion.?.text, .ghost = true });
            placed = true;
        }
        try out.append(allocator, .{ .at = entry.offset - start, .text = value.text(entry), .ghost = entry.ghost });
    };
    if (!placed) try out.append(allocator, .{ .at = suggestion.?.offset - start, .text = suggestion.?.text, .ghost = true });
    // At one byte, hints go before ghosts: the caret shows between them.
    std.sort.insertion(cache.Inlay, out.items, {}, struct {
        fn less(_: void, a: cache.Inlay, b: cache.Inlay) bool {
            return a.at < b.at or (a.at == b.at and !a.ghost and b.ghost);
        }
    }.less);
}

test "inlays move with edits and back with their undo" {
    const allocator = std.testing.allocator;
    var set = try capture(allocator, &.{ .{ .offset = 0, .text = "a" }, .{ .offset = 3, .text = "b" }, .{ .offset = 5, .text = "c" }, .{ .offset = 9, .text = "d" } }, 8);
    defer set.free(allocator);
    // Insert 2 bytes at 3, replace 5..7 by 4 bytes.
    const changes = [_]Change{ .{ .start = 3, .end = 3, .len = 2 }, .{ .start = 5, .end = 7, .len = 4 } };
    move(&set, &changes);
    const offsets = struct {
        fn f(value: *const Set) [4]usize {
            var out: [4]usize = undefined;
            for (value.entries, &out) |entry, *item| item.* = entry.offset;
            return out;
        }
    }.f;
    try std.testing.expectEqual([4]usize{ 0, 5, 11, 13 }, offsets(&set));
    moveBack(&set, &changes);
    try std.testing.expectEqual([4]usize{ 0, 3, 7, 9 }, offsets(&set));
}

test "inlays are checked, copied in order and chosen by batch" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidInlay, capture(allocator, &.{.{ .offset = 0, .text = "" }}, 8));
    try std.testing.expectError(error.InvalidInlay, capture(allocator, &.{.{ .offset = 0, .text = "a\nb" }}, 8));
    try std.testing.expectError(error.InvalidOrder, capture(allocator, &.{ .{ .offset = 4, .text = "a" }, .{ .offset = 2, .text = "b" } }, 8));
    try std.testing.expectError(error.InlayCapacityExceeded, capture(allocator, &.{ .{ .offset = 0, .text = "a" }, .{ .offset = 1, .text = "b" } }, 1));
    var set = try capture(allocator, &.{ .{ .offset = 2, .text = ": i32" }, .{ .offset = 5, .text = "  blame", .kind = .trailing } }, 8);
    defer set.free(allocator);
    try std.testing.expectEqualStrings("  blame", set.text(set.entries[1]));
    try std.testing.expect(set.entries[1].ghost and !set.entries[0].ghost);
    var out: std.ArrayList(cache.Inlay) = .empty;
    defer out.deinit(allocator);
    try select(allocator, &out, &set, .{ .offset = 2, .text = "x" }, 1, 5, false);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings(": i32", out.items[0].text);
    try std.testing.expectEqualStrings("x", out.items[1].text);
    try std.testing.expectEqual(@as(usize, 1), out.items[1].at);
    out.clearRetainingCapacity();
    try select(allocator, &out, &set, null, 1, 5, true);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(usize, 4), out.items[1].at);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("if x {", suggestionShown("if x {", &buffer));
    try std.testing.expectEqualStrings("if x { …", suggestionShown("if x {\n}", &buffer));
    var small: [9]u8 = undefined;
    try std.testing.expectEqualStrings("ab\u{4e2d} …", suggestionShown("ab\u{4e2d}\u{6587}xyz", &small));
    try std.testing.expectEqualStrings(" …", suggestionShown("\nnext", &small));
}
