//! Line breaking for wrapping text nodes (`Style.wrap`). Lines break after
//! spaces, before and after ideographs, and at newlines; a word wider than a
//! line breaks between characters. Widths come from the host's Measurer, a
//! line at a time, so nothing here allocates.
const std = @import("std");
const view = @import("root.zig");

const Measurer = view.Measurer;
const Font = view.Font;
const Size = view.Size;

/// What lines keep whole beyond what they always do. `words` keeps the
/// words of a language written with spaces between them whole though
/// Unicode's line breaking allows breaks within them, as Korean, whose
/// lines break between words and not between any two syllables: as CSS's
/// `word-break: keep-all`, a break between two letters or digits is left
/// out, and lines break at spaces and around punctuation; a word wider than
/// a line still breaks within it, as CSS's `overflow-wrap` has it. See
/// `keepsWords`.
///
/// `spaces` keeps the spaces lines end with, with their advance, as CSS's
/// `white-space: break-spaces` does (`Style.preserve_spaces`): a line may
/// break after any space, and the spaces before a break stay on the line
/// they end, taking room there, rather than going.
pub const Keep = struct {
    words: bool = false,
    spaces: bool = false,
};

/// Whether lines of text in `lang`, a BCP 47 tag, break between words
/// only, keeping them whole: Korean's ("ko", "ko-KR", "ko_KR").
pub fn keepsWords(lang: []const u8) bool {
    const end = std.mem.indexOfAny(u8, lang, "-_") orelse lang.len;
    return std.ascii.eqlIgnoreCase(lang[0..end], "ko");
}

/// Whether `code` is a letter or digit a word kept whole holds, as
/// browsers take them for `keep-all`: but those of the scripts written
/// without spaces between words, as Thai, whose breaks come from a
/// dictionary. Marks go with the letter they are on (`isMark`).
pub fn wordInside(code: u21) bool {
    if (code < 0x80) return std.ascii.isAlphanumeric(@intCast(code));
    // Punctuation, symbols and spaces of the Latin and general blocks.
    if (code < 0xC0 or code == 0xD7 or code == 0xF7) return code == 0xAA or code == 0xB2 or code == 0xB3 or code == 0xB5 or code == 0xB9 or code == 0xBA or (code >= 0xBC and code <= 0xBE);
    return switch (code) {
        // Thai, Lao; Myanmar; Khmer; Tai Le, New Tai Lue, Khmer symbols,
        // Tai Tham; Myanmar Extended-B, -A and Tai Viet; Ahom.
        0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x1950...0x1AAF, 0xA9E0...0xA9FF, 0xAA60...0xAADF, 0x11700...0x1174F => false,
        // General punctuation, symbols and arrows, CJK symbols and
        // punctuation, halfwidth and fullwidth punctuation.
        0x2000...0x2BFF, 0x2E00...0x2E7F, 0x3000...0x303F, 0xFE10...0xFE6F, 0xFF00...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65, 0xFFE0...0xFFEF => false,
        else => !isMark(code),
    };
}

/// Marks that go with the letter before them.
pub fn isMark(code: u21) bool {
    return switch (code) {
        0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x0900...0x0903, 0x093A...0x094F, 0x0951...0x0957, 0x0962, 0x0963, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x200C, 0x200D, 0x20D0...0x20FF, 0x302A...0x302F, 0x3099, 0x309A, 0xFE00...0xFE0F, 0xFE20...0xFE2F => true,
        else => false,
    };
}

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
pub fn next(text: []const u8, start: usize, width: f32, font: ?Font, measurer: Measurer, keep: Keep) Line {
    var fit: ?usize = null;
    var at = start;
    var previous_wide = false;
    // The letter or digit before, its marks passed over, of a word kept
    // whole (`Keep.words`).
    var previous_inside = false;
    while (at < text.len) {
        if (text[at] == '\n') {
            const end = trimEnd(keep, text, start, at);
            if (measurer.partWidth(text, start, end, font) <= width) return .{ .start = start, .end = end, .next = at + 1 };
            break;
        }
        const char = decode(text, at);
        const is_wide = wide(char.code);
        const mark = isMark(char.code);
        const inside = keep.words and !mark and wordInside(char.code);
        // A break opportunity before this character: after spaces, or on
        // either side of an ideograph, but within a word kept whole.
        if (at > start and !mark and ((space(text[at - 1]) and (keep.spaces or !space(text[at]))) or ((is_wide or previous_wide) and !(inside and previous_inside)))) {
            const end = trimEnd(keep, text, start, at);
            if (measurer.partWidth(text, start, end, font) > width) break;
            fit = at;
        }
        if (!mark) {
            previous_wide = is_wide;
            previous_inside = inside;
        }
        at += char.len;
    }
    if (at >= text.len) {
        const end = trimEnd(keep, text, start, text.len);
        if (measurer.partWidth(text, start, end, font) <= width) return .{ .start = start, .end = end, .next = text.len };
    }
    if (fit) |value| return .{ .start = start, .end = trimEnd(keep, text, start, value), .next = skipSpaces(keep, text, value) };
    // One word wider than the line: as many characters as fit, at least one.
    var end = start + decode(text, start).len;
    while (end < text.len and text[end] != '\n') {
        const after = end + decode(text, end).len;
        if (measurer.textSize(text[start..after], font).width > width) break;
        end = after;
    }
    return .{ .start = start, .end = end, .next = skipSpaces(keep, text, end) };
}

fn trimEnd(keep: Keep, text: []const u8, start: usize, end: usize) usize {
    if (keep.spaces) return end;
    var at = end;
    while (at > start and space(text[at - 1])) at -= 1;
    return at;
}
fn skipSpaces(keep: Keep, text: []const u8, at: usize) usize {
    if (keep.spaces) return at;
    var value = at;
    while (value < text.len and space(text[value])) value += 1;
    return value;
}

/// Size of `text` wrapped at `width`, showing at most `max_lines` lines
/// (0 for all): the widest line and the lines' total height.
pub fn measure(text: []const u8, width: f32, font: ?Font, measurer: Measurer, keep: Keep, max_lines: u16) Size {
    const height = lineHeight(measurer, font);
    var size: Size = .{ .width = 0, .height = 0 };
    var start: usize = 0;
    var count: usize = 0;
    while (true) {
        const line = next(text, start, width, font, measurer, keep);
        size.width = @max(size.width, measurer.partWidth(text, line.start, line.end, font));
        size.height += height;
        count += 1;
        start = line.next;
        if (start >= text.len and !(start > 0 and text[start - 1] == '\n' and start == text.len)) break;
        if (max_lines != 0 and count >= max_lines) break;
    }
    return size;
}

/// How many lines `text` takes wrapped at `width`, counting up to `limit`.
pub fn lineCount(text: []const u8, width: f32, font: ?Font, measurer: Measurer, keep: Keep, limit: usize) usize {
    var start: usize = 0;
    var count: usize = 0;
    while (count < limit) {
        const line = next(text, start, width, font, measurer, keep);
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
pub fn balanced(text: []const u8, width: f32, font: ?Font, measurer: Measurer, keep: Keep, max_lines: u16) f32 {
    if (!(width > 0) or !std.math.isFinite(width)) return width;
    const cap: usize = if (max_lines != 0) @as(usize, max_lines) + 1 else 4096;
    const count = lineCount(text, width, font, measurer, keep, cap);
    if (count <= 1 or (max_lines != 0 and count > max_lines)) return width;
    // The lines hold the whole text, which takes no less than its width
    // over as many lines, nor less than its widest word.
    const total = measurer.textSize(text, font).width;
    var lo = @min(@max(total / @as(f32, @floatFromInt(count)) / 2, longestWord(text, font, measurer, keep) - balance_step), width);
    var hi = width;
    while (hi - lo > balance_step) {
        const mid = (lo + hi) / 2;
        if (lineCount(text, mid, font, measurer, keep, count + 1) <= count) hi = mid else lo = mid;
    }
    return hi;
}

/// The widest piece of `text` no line can break, which a wrapping text
/// needs at the least.
pub fn longestWord(text: []const u8, font: ?Font, measurer: Measurer, keep: Keep) f32 {
    var widest: f32 = 0;
    var start: usize = 0;
    var at: usize = 0;
    while (at <= text.len) {
        const code = if (at < text.len) decode(text, at).code else 0;
        // Ideographs are words alone, unless words are kept whole: then a
        // run of letters among them is one.
        const alone = at < text.len and wide(code) and !(keep.words and wordInside(code));
        if (at == text.len or space(text[at]) or text[at] == '\n' or alone) {
            if (at > start) widest = @max(widest, measurer.textSize(text[start..at], font).width);
            if (at == text.len) break;
            const len = decode(text, at).len;
            if (alone) widest = @max(widest, measurer.textSize(text[at .. at + len], font).width);
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
pub fn each(text: []const u8, width: f32, font: ?Font, measurer: Measurer, keep: Keep, max_lines: u16, context: anytype, comptime draw: fn (@TypeOf(context), []const u8, usize, bool) void) void {
    eachWith(text, width, font, measurer, keep, max_lines, false, context, draw);
}

/// Whether `pretty` can rewrap `text` at `width`: it wraps, and onto no
/// more lines than `max_lines` shows.
fn prettyApplies(text: []const u8, width: f32, font: ?Font, measurer: Measurer, keep: Keep, max_lines: u16) bool {
    if (!(width > 0) or !std.math.isFinite(width)) return false;
    if (max_lines == 0) return true;
    return lineCount(text, width, font, measurer, keep, @as(usize, max_lines) + 1) <= max_lines;
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
pub fn prettyTail(paragraph: []const u8, width: f32, font: ?Font, measurer: Measurer, keep: Keep) ?struct { from: usize, width: f32 } {
    if (!(width > 0) or !std.math.isFinite(width)) return null;
    var start: usize = 0;
    var before: ?usize = null;
    var last: Line = undefined;
    var count: usize = 0;
    while (true) {
        const line = next(paragraph, start, width, font, measurer, keep);
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
        const lines = lineCount(rest, mid, font, measurer, keep, 3);
        const tail = lastLine(rest, mid, font, measurer, keep);
        if (lines > 2 or words(rest[tail.start..tail.end]) > 1) {
            lo = mid;
            best = mid;
        } else hi = mid;
    }
    const chosen = best orelse return null;
    if (lineCount(rest, chosen, font, measurer, keep, 3) != 2) return null;
    const second = lastLine(rest, chosen, font, measurer, keep);
    // The line before gave a whole word, not a part of one.
    if (second.start == 0 or !space(rest[second.start - 1])) return null;
    if (words(rest[second.start..second.end]) < 2) return null;
    return .{ .from = from, .width = chosen };
}
fn lastLine(text: []const u8, width: f32, font: ?Font, measurer: Measurer, keep: Keep) Line {
    var start: usize = 0;
    while (true) {
        const line = next(text, start, width, font, measurer, keep);
        if (line.next >= text.len) return line;
        start = line.next;
    }
}

/// `each`, with the last line of each paragraph kept from holding a single
/// word when `pretty` (`Style.pretty`) and the text is not cut.
pub fn eachWith(text: []const u8, width: f32, font: ?Font, measurer: Measurer, keep: Keep, max_lines: u16, pretty: bool, context: anytype, comptime draw: fn (@TypeOf(context), []const u8, usize, bool) void) void {
    if (pretty and prettyApplies(text, width, font, measurer, keep, max_lines)) {
        var index: usize = 0;
        var paragraphs = std.mem.splitScalar(u8, text, '\n');
        while (paragraphs.next()) |paragraph| {
            const tail = prettyTail(paragraph, width, font, measurer, keep);
            const head_end = if (tail) |value| value.from else paragraph.len;
            var start: usize = 0;
            // The lines before the tail, as they wrap at `width`; an empty
            // paragraph is one empty line.
            while (start < head_end or (start == 0 and paragraph.len == 0)) {
                const line = next(paragraph[0..head_end], start, width, font, measurer, keep);
                draw(context, paragraph[line.start..line.end], index, false);
                index += 1;
                start = line.next;
                if (paragraph.len == 0) break;
            }
            if (tail) |value| {
                const rest = paragraph[value.from..];
                start = 0;
                while (start < rest.len) {
                    const line = next(rest, start, value.width, font, measurer, keep);
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
        const line = next(text, start, width, font, measurer, keep);
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
        const trimmed = trimEnd(.{}, line, 0, end);
        @memcpy(out[0..trimmed], line[0..trimmed]);
        @memcpy(out[trimmed .. trimmed + ellipsis.len], ellipsis);
        const value = out[0 .. trimmed + ellipsis.len];
        if (end == 0 or measurer.textSize(value, font).width <= width) return value;
        end -= 1;
        while (end > 0 and line[end] & 0xc0 == 0x80) end -= 1;
    }
}

/// `text` with its middle cut out so that its start, an ellipsis and its
/// end fit `width`, about as wide on each side of the ellipsis, written
/// into `out`; `text` itself when it fits. Characters are kept whole.
pub fn cutMiddle(text: []const u8, width: f32, font: ?Font, measurer: Measurer, out: []u8) []const u8 {
    if (measurer.textSize(text, font).width <= width) return text;
    if (out.len < ellipsis.len) return text[0..0];
    const room = out.len - ellipsis.len;
    var head: usize = 0;
    var tail: usize = text.len;
    var head_width: f32 = 0;
    var tail_width: f32 = 0;
    var head_done = false;
    var tail_done = false;
    // Grow the narrower side by a character at a time while the whole fits.
    while (!(head_done and tail_done)) {
        if (!head_done and (tail_done or head_width <= tail_width)) {
            var after = head + 1;
            while (after < tail and text[after] & 0xc0 == 0x80) after += 1;
            if (after > tail or after + (text.len - tail) > room or measurer.textSize(compose(text, after, tail, out), font).width > width) {
                head_done = true;
                continue;
            }
            head = after;
            head_width = measurer.textSize(text[0..head], font).width;
        } else {
            if (tail <= head) {
                tail_done = true;
                continue;
            }
            var previous = tail - 1;
            while (previous > head and text[previous] & 0xc0 == 0x80) previous -= 1;
            if (head + (text.len - previous) > room or measurer.textSize(compose(text, head, previous, out), font).width > width) {
                tail_done = true;
                continue;
            }
            tail = previous;
            tail_width = measurer.textSize(text[tail..], font).width;
        }
    }
    return compose(text, head, tail, out);
}
/// The start of `text` to `head`, an ellipsis and its end from `tail`.
fn compose(text: []const u8, head: usize, tail: usize, out: []u8) []const u8 {
    const end_len = text.len - tail;
    @memcpy(out[0..head], text[0..head]);
    @memcpy(out[head .. head + ellipsis.len], ellipsis);
    @memcpy(out[head + ellipsis.len .. head + ellipsis.len + end_len], text[tail..]);
    return out[0 .. head + ellipsis.len + end_len];
}

const testing = std.testing;

test "a middle cut keeps the start and the end, about as wide each" {
    const m: Measurer = .{};
    var buffer: [128]u8 = undefined;
    // 9 DIP a character: 13 characters fit with the ellipsis between.
    const path = "/Users/me/Documents/Reports/summary-final.pdf";
    const shown = cutMiddle(path, 9 * 13, null, m, &buffer);
    try testing.expect(m.textSize(shown, null).width <= 9 * 13);
    try testing.expect(std.mem.startsWith(u8, shown, "/Users"));
    try testing.expect(std.mem.endsWith(u8, shown, "l.pdf"));
    try testing.expect(std.mem.indexOf(u8, shown, ellipsis) != null);
    // Text that fits is left whole; characters are never split.
    try testing.expectEqualStrings("short", cutMiddle("short", 100, null, m, &buffer));
    const ideographs = cutMiddle("\u{4e00}\u{4e8c}\u{4e09}\u{56db}\u{4e94}\u{516d}\u{4e03}", 9 * 4, null, m, &buffer);
    try testing.expect(std.unicode.utf8ValidateSlice(ideographs));
    try testing.expect(std.mem.indexOf(u8, ideographs, ellipsis) != null);
}

test "balanced lines keep their count at about the same width" {
    const m: Measurer = .{};
    // 9 DIP a character: "aaaa bbbb cccc dd" wraps at 13 characters into
    // a long line and a short one; balanced, into two of about the same.
    const text = "aaaa bbbb cccc dd";
    try testing.expectEqual(@as(usize, 2), lineCount(text, 9 * 15, null, m, .{}, 10));
    const width = balanced(text, 9 * 15, null, m, .{}, 0);
    try testing.expectEqual(@as(usize, 2), lineCount(text, width, null, m, .{}, 10));
    try testing.expect(width < 9 * 10);
    const first = next(text, 0, width, null, m, .{});
    try testing.expectEqualStrings("aaaa bbbb", text[first.start..first.end]);
    // One line, or a cut one, keeps its width.
    try testing.expectEqual(@as(f32, 900), balanced(text, 900, null, m, .{}, 0));
    try testing.expectEqual(@as(f32, 9 * 6), balanced(text, 9 * 6, null, m, .{}, 2));
}

test "lines break at spaces, ideographs and newlines" {
    const m: Measurer = .{};
    // The estimate gives 9 DIP per narrow and 16 per wide character.
    var line = next("alpha beta gamma", 0, 9 * 11, null, m, .{});
    try testing.expectEqualStrings("alpha beta", "alpha beta gamma"[line.start..line.end]);
    try testing.expectEqual(@as(usize, 11), line.next);
    line = next("一二三四", 0, 16 * 2, null, m, .{});
    try testing.expectEqual(@as(usize, 6), line.end);
    line = next("ab\ncd", 0, 1000, null, m, .{});
    try testing.expectEqual(@as(usize, 2), line.end);
    try testing.expectEqual(@as(usize, 3), line.next);
    // A word wider than the line breaks between characters.
    line = next("abcdefgh", 0, 9 * 3, null, m, .{});
    try testing.expectEqual(@as(usize, 3), line.end);
    // One character is always taken.
    line = next("abc", 0, 1, null, m, .{});
    try testing.expectEqual(@as(usize, 1), line.end);
}

test "measure and longest word" {
    const m: Measurer = .{};
    const size = measure("alpha beta gamma", 9 * 11, null, m, .{}, 0);
    try testing.expectEqual(@as(f32, 9 * 10), size.width);
    try testing.expectEqual(2 * lineHeight(m, null), size.height);
    try testing.expectEqual(lineHeight(m, null), measure("alpha beta gamma", 9 * 11, null, m, .{}, 1).height);
    try testing.expectEqual(@as(f32, 9 * 5), longestWord("alpha beta gamma", null, m, .{}));
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
    eachWith(text, 9 * 14, null, m, .{}, 0, false, &plain, Collect.add);
    try testing.expectEqual(@as(usize, 2), plain.len);
    try testing.expectEqualStrings("dd", plain.lines[1]);
    var pretty: Collect = .{};
    eachWith(text, 9 * 14, null, m, .{}, 0, true, &pretty, Collect.add);
    try testing.expectEqual(@as(usize, 2), pretty.len);
    try testing.expectEqualStrings("aaaa bbbb", pretty.lines[0]);
    try testing.expectEqualStrings("cccc dd", pretty.lines[1]);
    // Lines before the last two stay as they are, paragraph by paragraph.
    var long: Collect = .{};
    eachWith("aaaa bbbb cccc dddd ee\nx", 9 * 10, null, m, .{}, 0, true, &long, Collect.add);
    try testing.expectEqual(@as(usize, 4), long.len);
    try testing.expectEqualStrings("aaaa bbbb", long.lines[0]);
    try testing.expectEqualStrings("cccc", long.lines[1]);
    try testing.expectEqualStrings("dddd ee", long.lines[2]);
    try testing.expectEqualStrings("x", long.lines[3]);
    // One long word before gives nothing.
    var word: Collect = .{};
    eachWith("aaaaaaaaaaaa dd", 9 * 12, null, m, .{}, 0, true, &word, Collect.add);
    try testing.expectEqualStrings("dd", word.lines[word.len - 1]);
}

test "Korean lines break between words, as keep-all, and long words still break" {
    const m: Measurer = .{};
    const korean: Keep = .{ .words = keepsWords("ko-KR") };
    try testing.expect(korean.words);
    try testing.expect(keepsWords("KO") and keepsWords("ko_KR") and !keepsWords("kok") and !keepsWords("ja") and !keepsWords(""));
    // 16 DIP a syllable: "한국어 문장입니다" at 5 syllables breaks inside
    // the second word between any two syllables, and between words when
    // they are kept whole.
    const text = "한국어 문장입니다";
    var line = next(text, 0, 16 * 5, null, m, .{});
    try testing.expectEqualStrings("한국어 문", text[line.start..line.end]);
    line = next(text, 0, 16 * 5, null, m, korean);
    try testing.expectEqualStrings("한국어", text[line.start..line.end]);
    try testing.expectEqualStrings("문장입니다", text[line.next..]);
    // Punctuation still breaks: after the comma.
    const listed = "가나,다라마바";
    line = next(listed, 0, 16 * 4, null, m, korean);
    try testing.expectEqualStrings("가나,", listed[line.start..line.end]);
    // A word wider than the line breaks within it.
    line = next("가나다라마바사", 0, 16 * 3, null, m, korean);
    try testing.expectEqual(@as(usize, 9), line.end);
    // Its words are what the text needs at the least.
    try testing.expectEqual(@as(f32, 16 * 5), longestWord(text, null, m, korean));
    try testing.expectEqual(@as(f32, 16), longestWord(text, null, m, .{}));
    // Han characters and Thai: digits and Latin letters next to Hangul
    // keep with it; English is unchanged.
    try testing.expect(wordInside('가') and wordInside('a') and wordInside('7') and wordInside('漢'));
    try testing.expect(!wordInside(',') and !wordInside('。') and !wordInside(0x0E01) and !wordInside(0x0301));
    line = next("alpha beta gamma", 0, 9 * 11, null, m, korean);
    try testing.expectEqualStrings("alpha beta", "alpha beta gamma"[line.start..line.end]);
}

test "kept spaces stay on the lines they end and take room there, as break-spaces" {
    const m: Measurer = .{};
    const spaced: Keep = .{ .spaces = true };
    // 9 DIP a character.
    var line = next("ab   cd", 0, 9 * 4, null, m, spaced);
    try testing.expectEqualStrings("ab  ", "ab   cd"[line.start..line.end]);
    try testing.expectEqual(line.end, line.next);
    line = next("ab   cd", line.next, 9 * 4, null, m, spaced);
    try testing.expectEqualStrings(" cd", "ab   cd"[line.start..line.end]);
    // Without, the spaces ending a line go.
    line = next("ab   cd", 0, 9 * 4, null, m, .{});
    try testing.expectEqualStrings("ab", "ab   cd"[line.start..line.end]);
    try testing.expectEqualStrings("cd", "ab   cd"[line.next..]);
    try testing.expectEqual(@as(f32, 9 * 6), measure("ab cd ", 9 * 20, null, m, spaced, 0).width);
}

test "wrapping takes the widths of lines from the measurer's shaped paragraph where it knows them" {
    const Counting = struct {
        parts: usize = 0,
        fn part(context: ?*anyopaque, whole: []const u8, start: usize, end: usize, _: ?Font) ?f32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.parts += 1;
            _ = whole;
            return @floatFromInt(9 * (end - start));
        }
    };
    var counting: Counting = .{};
    const m: Measurer = .{ .context = &counting, .measure_part = Counting.part };
    const line = next("one two three", 0, 9 * 8, null, m, .{});
    try testing.expectEqualStrings("one two", "one two three"[line.start..line.end]);
    try testing.expect(counting.parts >= 2);
}
