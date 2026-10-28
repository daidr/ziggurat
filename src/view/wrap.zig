//! Line breaking for wrapping text nodes (`Style.wrap`). Lines break after
//! spaces, before and after ideographs, and at newlines; a word wider than a
//! line breaks between characters. Widths come from the host's Measurer, a
//! line at a time, so nothing here allocates.
const std = @import("std");
const view = @import("root.zig");

const Measurer = view.Measurer;
const Font = view.Font;
const Size = view.Size;

/// One line of a wrapped text: `text[start..end]`, with the spaces that end
/// it left out; the next line starts at `next`.
pub const Line = struct { start: usize, end: usize, next: usize };

/// The text ends in an ellipsis where a line limit cuts it.
pub const ellipsis = "\u{2026}";

/// Height of one line of `font`.
pub fn lineHeight(measurer: Measurer, font: ?Font) f32 {
    return measurer.textSize("", font).height;
}

fn wide(code: u21) bool {
    // Ideographs, kana, hangul and fullwidth forms break on either side.
    return (code >= 0x2E80 and code <= 0x9FFF) or (code >= 0xAC00 and code <= 0xD7AF) or (code >= 0xF900 and code <= 0xFAFF) or (code >= 0xFF00 and code <= 0xFFEF) or (code >= 0x20000 and code <= 0x3FFFF);
}
fn decode(text: []const u8, at: usize) struct { code: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return .{ .code = text[at], .len = 1 };
    if (at + len > text.len) return .{ .code = text[at], .len = 1 };
    const code = std.unicode.utf8Decode(text[at .. at + len]) catch return .{ .code = text[at], .len = 1 };
    return .{ .code = code, .len = len };
}
fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

/// The line that starts at `start` and fits `width`; at least one character
/// when anything is left.
pub fn next(text: []const u8, start: usize, width: f32, font: ?Font, measurer: Measurer) Line {
    var fit: ?usize = null;
    var at = start;
    var previous_wide = false;
    while (at < text.len) {
        if (text[at] == '\n') {
            const end = trimEnd(text, start, at);
            if (measurer.textSize(text[start..end], font).width <= width) return .{ .start = start, .end = end, .next = at + 1 };
            break;
        }
        const char = decode(text, at);
        const is_wide = wide(char.code);
        // A break opportunity before this character: after spaces, or on
        // either side of an ideograph.
        if (at > start and ((space(text[at - 1]) and !space(text[at])) or is_wide or previous_wide)) {
            const end = trimEnd(text, start, at);
            if (measurer.textSize(text[start..end], font).width > width) break;
            fit = at;
        }
        previous_wide = is_wide;
        at += char.len;
    }
    if (at >= text.len) {
        const end = trimEnd(text, start, text.len);
        if (measurer.textSize(text[start..end], font).width <= width) return .{ .start = start, .end = end, .next = text.len };
    }
    if (fit) |value| return .{ .start = start, .end = trimEnd(text, start, value), .next = skipSpaces(text, value) };
    // One word wider than the line: as many characters as fit, at least one.
    var end = start + decode(text, start).len;
    while (end < text.len and text[end] != '\n') {
        const after = end + decode(text, end).len;
        if (measurer.textSize(text[start..after], font).width > width) break;
        end = after;
    }
    return .{ .start = start, .end = end, .next = skipSpaces(text, end) };
}

fn trimEnd(text: []const u8, start: usize, end: usize) usize {
    var at = end;
    while (at > start and space(text[at - 1])) at -= 1;
    return at;
}
fn skipSpaces(text: []const u8, at: usize) usize {
    var value = at;
    while (value < text.len and space(text[value])) value += 1;
    return value;
}

/// Size of `text` wrapped at `width`, showing at most `max_lines` lines
/// (0 for all): the widest line and the lines' total height.
pub fn measure(text: []const u8, width: f32, font: ?Font, measurer: Measurer, max_lines: u16) Size {
    const height = lineHeight(measurer, font);
    var size: Size = .{ .width = 0, .height = 0 };
    var start: usize = 0;
    var count: usize = 0;
    while (true) {
        const line = next(text, start, width, font, measurer);
        size.width = @max(size.width, measurer.textSize(text[line.start..line.end], font).width);
        size.height += height;
        count += 1;
        start = line.next;
        if (start >= text.len and !(start > 0 and text[start - 1] == '\n' and start == text.len)) break;
        if (max_lines != 0 and count >= max_lines) break;
    }
    return size;
}

/// The widest piece of `text` no line can break, which a wrapping text
/// needs at the least.
pub fn longestWord(text: []const u8, font: ?Font, measurer: Measurer) f32 {
    var widest: f32 = 0;
    var start: usize = 0;
    var at: usize = 0;
    while (at <= text.len) {
        const boundary = at == text.len or space(text[at]) or text[at] == '\n' or wide(decode(text, at).code);
        if (boundary) {
            if (at > start) widest = @max(widest, measurer.textSize(text[start..at], font).width);
            if (at == text.len) break;
            const len = decode(text, at).len;
            if (wide(decode(text, at).code)) widest = @max(widest, measurer.textSize(text[at .. at + len], font).width);
            at += len;
            start = at;
            continue;
        }
        at += decode(text, at).len;
    }
    return widest;
}

/// Call `draw(context, line_text, line_index, last_cut)` for each line of
/// `text` wrapped at `width`, at most `max_lines` (0 for all). `last_cut` is
/// set on the last line shown when text remains after it.
pub fn each(text: []const u8, width: f32, font: ?Font, measurer: Measurer, max_lines: u16, context: anytype, comptime draw: fn (@TypeOf(context), []const u8, usize, bool) void) void {
    var start: usize = 0;
    var count: usize = 0;
    while (true) {
        const line = next(text, start, width, font, measurer);
        start = line.next;
        const done = start >= text.len and !(start > 0 and text[start - 1] == '\n' and start == text.len);
        const limit = max_lines != 0 and count + 1 >= max_lines;
        draw(context, text[line.start..line.end], count, limit and !done);
        count += 1;
        if (done or limit) break;
    }
}

/// `line` shortened so that it and an ellipsis fit `width`, written with the
/// ellipsis into `out`.
pub fn cut(line: []const u8, width: f32, font: ?Font, measurer: Measurer, out: []u8) []const u8 {
    var end = @min(line.len, out.len -| ellipsis.len);
    while (end > 0 and end < line.len and line[end] & 0xc0 == 0x80) end -= 1;
    while (true) {
        const trimmed = trimEnd(line, 0, end);
        @memcpy(out[0..trimmed], line[0..trimmed]);
        @memcpy(out[trimmed .. trimmed + ellipsis.len], ellipsis);
        const value = out[0 .. trimmed + ellipsis.len];
        if (end == 0 or measurer.textSize(value, font).width <= width) return value;
        end -= 1;
        while (end > 0 and line[end] & 0xc0 == 0x80) end -= 1;
    }
}

const testing = std.testing;

test "lines break at spaces, ideographs and newlines" {
    const m: Measurer = .{};
    // The estimate gives 9 DIP per narrow and 16 per wide character.
    var line = next("alpha beta gamma", 0, 9 * 11, null, m);
    try testing.expectEqualStrings("alpha beta", "alpha beta gamma"[line.start..line.end]);
    try testing.expectEqual(@as(usize, 11), line.next);
    line = next("一二三四", 0, 16 * 2, null, m);
    try testing.expectEqual(@as(usize, 6), line.end);
    line = next("ab\ncd", 0, 1000, null, m);
    try testing.expectEqual(@as(usize, 2), line.end);
    try testing.expectEqual(@as(usize, 3), line.next);
    // A word wider than the line breaks between characters.
    line = next("abcdefgh", 0, 9 * 3, null, m);
    try testing.expectEqual(@as(usize, 3), line.end);
    // One character is always taken.
    line = next("abc", 0, 1, null, m);
    try testing.expectEqual(@as(usize, 1), line.end);
}

test "measure and longest word" {
    const m: Measurer = .{};
    const size = measure("alpha beta gamma", 9 * 11, null, m, 0);
    try testing.expectEqual(@as(f32, 9 * 10), size.width);
    try testing.expectEqual(2 * lineHeight(m, null), size.height);
    try testing.expectEqual(lineHeight(m, null), measure("alpha beta gamma", 9 * 11, null, m, 1).height);
    try testing.expectEqual(@as(f32, 9 * 5), longestWord("alpha beta gamma", null, m));
    var buffer: [64]u8 = undefined;
    const shortened = cut("alpha beta", 9 * 6, null, m, &buffer);
    try testing.expect(m.textSize(shortened, null).width <= 9 * 6);
    try testing.expect(std.mem.endsWith(u8, shortened, ellipsis));
}
