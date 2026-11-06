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

/// How many lines `text` takes wrapped at `width`, counting up to `limit`.
pub fn lineCount(text: []const u8, width: f32, font: ?Font, measurer: Measurer, limit: usize) usize {
    var start: usize = 0;
    var count: usize = 0;
    while (count < limit) {
        const line = next(text, start, width, font, measurer);
        count += 1;
        start = line.next;
        if (start >= text.len and !(start > 0 and text[start - 1] == '\n' and start == text.len)) break;
    }
    return count;
}

/// How close to the narrowest width that keeps a text's lines as many
/// `balanced` finds it, in DIP.
pub const balance_step: f32 = 0.25;

/// The width to wrap `text` at so that its lines are about as wide as each
/// other (`Style.balance`): the narrowest that keeps them as many as
/// wrapping at `width` takes, found by bisection. A text on one line, or
/// one `max_lines` cuts, wraps at `width`.
pub fn balanced(text: []const u8, width: f32, font: ?Font, measurer: Measurer, max_lines: u16) f32 {
    if (!(width > 0) or !std.math.isFinite(width)) return width;
    const cap: usize = if (max_lines != 0) @as(usize, max_lines) + 1 else 4096;
    const count = lineCount(text, width, font, measurer, cap);
    if (count <= 1 or (max_lines != 0 and count > max_lines)) return width;
    // The lines hold the whole text, which takes no less than its width
    // over as many lines, nor less than its widest word.
    const total = measurer.textSize(text, font).width;
    var lo = @min(@max(total / @as(f32, @floatFromInt(count)) / 2, longestWord(text, font, measurer) - balance_step), width);
    var hi = width;
    while (hi - lo > balance_step) {
        const mid = (lo + hi) / 2;
        if (lineCount(text, mid, font, measurer, count + 1) <= count) hi = mid else lo = mid;
    }
    return hi;
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
    eachWith(text, width, font, measurer, max_lines, false, context, draw);
}

/// Whether `pretty` can rewrap `text` at `width`: it wraps, and onto no
/// more lines than `max_lines` shows.
fn prettyApplies(text: []const u8, width: f32, font: ?Font, measurer: Measurer, max_lines: u16) bool {
    if (!(width > 0) or !std.math.isFinite(width)) return false;
    if (max_lines == 0) return true;
    return lineCount(text, width, font, measurer, @as(usize, max_lines) + 1) <= max_lines;
}

/// Words of `line`, up to two: its runs between spaces.
fn words(line: []const u8) usize {
    var count: usize = 0;
    var in = false;
    for (line) |byte| {
        if (space(byte)) {
            in = false;
        } else if (!in) {
            in = true;
            count += 1;
            if (count > 1) return count;
        }
    }
    return count;
}

/// Where the last two lines of `paragraph` (text without newlines) wrapped
/// at `width` start, and the narrower width to wrap them at so that the
/// last holds more than one word (`Style.pretty`): the widest that does,
/// found by bisection as `balanced` does, as long as they stay two lines
/// broken at a space. Null when the last line holds more already, or the
/// line before has no word to spare.
pub fn prettyTail(paragraph: []const u8, width: f32, font: ?Font, measurer: Measurer) ?struct { from: usize, width: f32 } {
    if (!(width > 0) or !std.math.isFinite(width)) return null;
    var start: usize = 0;
    var before: ?usize = null;
    var last: Line = undefined;
    var count: usize = 0;
    while (true) {
        const line = next(paragraph, start, width, font, measurer);
        if (count > 0) before = last.start;
        last = line;
        count += 1;
        start = line.next;
        if (start >= paragraph.len) break;
    }
    if (count < 2 or words(paragraph[last.start..last.end]) > 1) return null;
    const from = before.?;
    const rest = paragraph[from..];
    var best: ?f32 = null;
    var lo: f32 = 1;
    var hi = width;
    while (hi - lo > balance_step) {
        const mid = (lo + hi) / 2;
        const lines = lineCount(rest, mid, font, measurer, 3);
        const tail = lastLine(rest, mid, font, measurer);
        if (lines > 2 or words(rest[tail.start..tail.end]) > 1) {
            lo = mid;
            best = mid;
        } else hi = mid;
    }
    const chosen = best orelse return null;
    if (lineCount(rest, chosen, font, measurer, 3) != 2) return null;
    const second = lastLine(rest, chosen, font, measurer);
    // The line before gave a whole word, not a part of one.
    if (second.start == 0 or !space(rest[second.start - 1])) return null;
    if (words(rest[second.start..second.end]) < 2) return null;
    return .{ .from = from, .width = chosen };
}
fn lastLine(text: []const u8, width: f32, font: ?Font, measurer: Measurer) Line {
    var start: usize = 0;
    while (true) {
        const line = next(text, start, width, font, measurer);
        if (line.next >= text.len) return line;
        start = line.next;
    }
}

/// `each`, with the last line of each paragraph kept from holding a single
/// word when `pretty` (`Style.pretty`) and the text is not cut.
pub fn eachWith(text: []const u8, width: f32, font: ?Font, measurer: Measurer, max_lines: u16, pretty: bool, context: anytype, comptime draw: fn (@TypeOf(context), []const u8, usize, bool) void) void {
    if (pretty and prettyApplies(text, width, font, measurer, max_lines)) {
        var index: usize = 0;
        var paragraphs = std.mem.splitScalar(u8, text, '\n');
        while (paragraphs.next()) |paragraph| {
            const tail = prettyTail(paragraph, width, font, measurer);
            const head_end = if (tail) |value| value.from else paragraph.len;
            var start: usize = 0;
            // The lines before the tail, as they wrap at `width`; an empty
            // paragraph is one empty line.
            while (start < head_end or (start == 0 and paragraph.len == 0)) {
                const line = next(paragraph[0..head_end], start, width, font, measurer);
                draw(context, paragraph[line.start..line.end], index, false);
                index += 1;
                start = line.next;
                if (paragraph.len == 0) break;
            }
            if (tail) |value| {
                const rest = paragraph[value.from..];
                start = 0;
                while (start < rest.len) {
                    const line = next(rest, start, value.width, font, measurer);
                    draw(context, rest[line.start..line.end], index, false);
                    index += 1;
                    start = line.next;
                }
            }
        }
        return;
    }
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

test "balanced lines keep their count at about the same width" {
    const m: Measurer = .{};
    // 9 DIP a character: "aaaa bbbb cccc dd" wraps at 13 characters into
    // a long line and a short one; balanced, into two of about the same.
    const text = "aaaa bbbb cccc dd";
    try testing.expectEqual(@as(usize, 2), lineCount(text, 9 * 15, null, m, 10));
    const width = balanced(text, 9 * 15, null, m, 0);
    try testing.expectEqual(@as(usize, 2), lineCount(text, width, null, m, 10));
    try testing.expect(width < 9 * 10);
    const first = next(text, 0, width, null, m);
    try testing.expectEqualStrings("aaaa bbbb", text[first.start..first.end]);
    // One line, or a cut one, keeps its width.
    try testing.expectEqual(@as(f32, 900), balanced(text, 900, null, m, 0));
    try testing.expectEqual(@as(f32, 9 * 6), balanced(text, 9 * 6, null, m, 2));
}

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

test "pretty lines give the last line a word from the line before" {
    const m: Measurer = .{};
    // 9 DIP a character: at 14 characters "aaaa bbbb cccc dd" leaves "dd"
    // alone on the second line; pretty, "cccc" goes down with it.
    const text = "aaaa bbbb cccc dd";
    const Collect = struct {
        lines: [8][]const u8 = undefined,
        len: usize = 0,
        fn add(self: *@This(), line: []const u8, _: usize, _: bool) void {
            self.lines[self.len] = line;
            self.len += 1;
        }
    };
    var plain: Collect = .{};
    eachWith(text, 9 * 14, null, m, 0, false, &plain, Collect.add);
    try testing.expectEqual(@as(usize, 2), plain.len);
    try testing.expectEqualStrings("dd", plain.lines[1]);
    var pretty: Collect = .{};
    eachWith(text, 9 * 14, null, m, 0, true, &pretty, Collect.add);
    try testing.expectEqual(@as(usize, 2), pretty.len);
    try testing.expectEqualStrings("aaaa bbbb", pretty.lines[0]);
    try testing.expectEqualStrings("cccc dd", pretty.lines[1]);
    // Lines before the last two stay as they are, paragraph by paragraph.
    var long: Collect = .{};
    eachWith("aaaa bbbb cccc dddd ee\nx", 9 * 10, null, m, 0, true, &long, Collect.add);
    try testing.expectEqual(@as(usize, 4), long.len);
    try testing.expectEqualStrings("aaaa bbbb", long.lines[0]);
    try testing.expectEqualStrings("cccc", long.lines[1]);
    try testing.expectEqualStrings("dddd ee", long.lines[2]);
    try testing.expectEqualStrings("x", long.lines[3]);
    // One long word before gives nothing.
    var word: Collect = .{};
    eachWith("aaaaaaaaaaaa dd", 9 * 12, null, m, 0, true, &word, Collect.add);
    try testing.expectEqualStrings("dd", word.lines[word.len - 1]);
}
