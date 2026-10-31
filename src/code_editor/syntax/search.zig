//! Words and whole-word searches over a text, as multi-caret commands use
//! them: the word at a caret, and the next or previous occurrence of a
//! selection's text, wrapping around the text's ends.
const std = @import("std");
const lex = @import("lexer.zig");

pub const Class = enum { word, space, punctuation };

/// The class of a scalar: letters, digits, _ and `extra` make words.
pub fn classOf(c: u21, extra: []const u8) Class {
    if (c == '_' or (c >= '0' and c <= '9') or lex.isLetter(c) or lex.isMark(c)) return .word;
    if (c < 0x80 and std.mem.indexOfScalar(u8, extra, @intCast(c)) != null) return .word;
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c or c == 0x85 or c == 0xa0 or c == 0x1680 or
        (c >= 0x2000 and c <= 0x200a) or c == 0x2028 or c == 0x2029 or c == 0x202f or c == 0x205f or c == 0x3000) return .space;
    return .punctuation;
}

const Scalar = struct { c: u21, size: usize };
fn scalarAt(text: []const u8, at: usize) Scalar {
    const size = @min(lex.sequenceLength(text[at]), text.len - at);
    const c = std.unicode.utf8Decode(text[at .. at + size]) catch return .{ .c = 0xfffd, .size = 1 };
    return .{ .c = c, .size = size };
}
fn scalarBefore(text: []const u8, at: usize) Scalar {
    var start = at - 1;
    while (start > 0 and at - start < 4 and text[start] & 0xc0 == 0x80) start -= 1;
    const value = scalarAt(text, start);
    if (start + value.size != at) return .{ .c = 0xfffd, .size = 1 };
    return .{ .c = value.c, .size = at - start };
}

/// Whether `c` is a word on its own: a Han ideograph (with the iteration
/// marks 々 and 〇), a Hiragana or a Katakana (with the prolonged sound
/// mark ー). Chinese and Japanese are written without spaces, and only a
/// dictionary finds their words; a character at a time is what platforms
/// do without one.
pub fn standsAlone(c: u21) bool {
    return switch (c) {
        0x2e80...0x2fdf, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303b, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xf900...0xfaff, 0x20000...0x3fffd => true,
        0x3041...0x3096, 0x309d...0x309f, 0x30a1...0x30fa, 0x30fc...0x30ff, 0x31f0...0x31ff, 0xff66...0xff9d, 0x1b000...0x1b16f => true,
        else => false,
    };
}

/// The run of one class around `at` in a line: the class of the scalar at
/// it, or of the one before it at the end of a word. Each ideograph and
/// kana is a word alone.
pub fn wordAt(line: []const u8, at_input: usize, extra: []const u8) struct { start: usize, end: usize } {
    const at = @min(at_input, line.len);
    var class: Class = undefined;
    // The word holding `at` starts at it, or ends there.
    var from_before = false;
    if (at < line.len) {
        class = classOf(scalarAt(line, at).c, extra);
        if (class != .word and at > 0 and classOf(scalarBefore(line, at).c, extra) == .word) {
            class = .word;
            from_before = true;
        }
    } else if (at > 0) {
        class = classOf(scalarBefore(line, at).c, extra);
        from_before = true;
    } else return .{ .start = at, .end = at };
    if (class == .word) {
        const c = if (from_before) scalarBefore(line, at) else scalarAt(line, at);
        if (standsAlone(c.c)) return if (from_before) .{ .start = at - c.size, .end = at } else .{ .start = at, .end = at + c.size };
    }
    var start = at;
    while (start > 0) {
        const previous = scalarBefore(line, start);
        if (classOf(previous.c, extra) != class or (class == .word and standsAlone(previous.c))) break;
        start -= previous.size;
    }
    var end = at;
    while (end < line.len) {
        const next = scalarAt(line, end);
        if (classOf(next.c, extra) != class or (class == .word and standsAlone(next.c))) break;
        end += next.size;
    }
    return .{ .start = start, .end = end };
}

/// Whether `start..end` of text is not part of a longer word.
pub fn isWholeWord(text: []const u8, start: usize, end: usize, extra: []const u8) bool {
    if (start > 0 and classOf(scalarBefore(text, start).c, extra) == .word) return false;
    if (end < text.len and classOf(scalarAt(text, end).c, extra) == .word) return false;
    return true;
}

/// A predicate a match must also pass, as not being selected already.
pub const Filter = struct {
    context: *const anyopaque,
    call: *const fn (*const anyopaque, usize, usize) bool,
};

fn accepted(text: []const u8, at: usize, query: []const u8, whole: bool, extra: []const u8, filter: ?Filter) bool {
    if (whole and !isWholeWord(text, at, at + query.len, extra)) return false;
    if (filter) |value| if (!value.call(value.context, at, at + query.len)) return false;
    return true;
}

/// The first match of `query` at or after `at` that passes, wrapping round
/// to the start.
pub fn forward(text: []const u8, query: []const u8, at_input: usize, whole: bool, extra: []const u8, filter: ?Filter) ?usize {
    if (query.len == 0) return null;
    const at = @min(at_input, text.len);
    return findForward(text, query, at, text.len, whole, extra, filter) orelse findForward(text, query, 0, at, whole, extra, filter);
}
fn findForward(text: []const u8, query: []const u8, from_input: usize, limit: usize, whole: bool, extra: []const u8, filter: ?Filter) ?usize {
    var from = from_input;
    while (from < limit) {
        const found = std.mem.indexOfPos(u8, text, from, query) orelse return null;
        if (found >= limit) return null;
        if (accepted(text, found, query, whole, extra, filter)) return found;
        from = found + 1;
    }
    return null;
}

/// The last match of `query` starting before `before` that passes, wrapping
/// round to the end.
pub fn backward(text: []const u8, query: []const u8, before_input: usize, whole: bool, extra: []const u8, filter: ?Filter) ?usize {
    if (query.len == 0) return null;
    const before = @min(before_input, text.len);
    return findBackward(text, query, 0, before, whole, extra, filter) orelse findBackward(text, query, before, text.len, whole, extra, filter);
}
/// Matches starting in low..high, the last first.
fn findBackward(text: []const u8, query: []const u8, low: usize, high_input: usize, whole: bool, extra: []const u8, filter: ?Filter) ?usize {
    var high = high_input;
    while (high > low) {
        const window = @min(text.len, high - 1 + query.len);
        const found = std.mem.lastIndexOf(u8, text[0..window], query) orelse return null;
        if (found < low) return null;
        if (accepted(text, found, query, whole, extra, filter)) return found;
        high = found;
    }
    return null;
}

test "words and whole-word searches wrap and filter" {
    const text = "foo bar foobar foo_x foo";
    try std.testing.expectEqual(@as(usize, 4), wordAt(text, 5, "").start);
    try std.testing.expectEqual(@as(usize, 7), wordAt(text, 7, "").end);
    try std.testing.expectEqual(@as(usize, 0), wordAt("héllo wörld", 3, "").start);
    try std.testing.expectEqual(@as(usize, 6), wordAt("héllo wörld", 3, "").end);
    try std.testing.expectEqual(@as(?usize, 21), forward(text, "foo", 1, true, "", null));
    try std.testing.expectEqual(@as(?usize, 8), forward(text, "foo", 1, false, "", null));
    try std.testing.expectEqual(@as(?usize, 0), forward(text, "foo", 22, true, "", null));
    try std.testing.expectEqual(@as(?usize, 0), backward(text, "foo", 21, true, "", null));
    try std.testing.expectEqual(@as(?usize, 21), backward(text, "foo", 0, true, "", null));
    try std.testing.expectEqual(@as(?usize, 15), backward(text, "foo", 21, false, "", null));
    try std.testing.expect(isWholeWord("a-b", 0, 1, ""));
    try std.testing.expect(!isWholeWord("a-b", 0, 1, "-"));
    try std.testing.expectEqual(Class.space, classOf(0x3000, ""));
}

test "each ideograph and kana is a word of its own" {
    // "日本語text", 3 bytes an ideograph.
    const line = "日本語text";
    try std.testing.expectEqual(@as(usize, 3), wordAt(line, 3, "").start);
    try std.testing.expectEqual(@as(usize, 6), wordAt(line, 3, "").end);
    // At the end of an ideograph before a space, that ideograph.
    try std.testing.expectEqual(@as(usize, 6), wordAt("日本語 x", 9, "").start);
    try std.testing.expectEqual(@as(usize, 9), wordAt("日本語 x", 9, "").end);
    // Latin after Han is a word of its own.
    try std.testing.expectEqual(@as(usize, 9), wordAt(line, 9, "").start);
    try std.testing.expectEqual(@as(usize, 9), wordAt(line, 10, "").start);
    try std.testing.expectEqual(@as(usize, 13), wordAt(line, 10, "").end);
    // Hangul keeps its runs.
    try std.testing.expectEqual(@as(usize, 6), wordAt("한국 말", 3, "").end);
}
