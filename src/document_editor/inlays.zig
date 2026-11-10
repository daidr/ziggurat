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
