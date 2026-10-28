//! Word boundaries without a dictionary: a word is a run of letters,
//! digits and underscores, as in the scripts written with spaces between
//! words (Latin, Cyrillic, Greek, Hangul…), except that each Han
//! ideograph, Hiragana and Katakana is a word of its own. Chinese and
//! Japanese are written without spaces, and only a dictionary finds their
//! words; a character at a time is what platforms do without one, rather
//! than a whole clause as one word. Thai keeps its runs: its vowels are
//! combining marks, which a rune at a time would split from their
//! syllables.
const std = @import("std");

/// Whether `r` is part of a word: a letter, a digit or an underscore. Past
/// ASCII, anything but spaces and punctuation.
pub fn isWordRune(r: u21) bool {
    if (r < 0x80) return std.ascii.isAlphanumeric(@intCast(r)) or r == '_';
    return !isSpace(r) and !isPunctuation(r);
}

/// Whether `r` is a word on its own: a Han ideograph (with the iteration
/// marks 々 and 〇), a Hiragana or a Katakana (with the prolonged sound
/// mark ー).
pub fn standsAlone(r: u21) bool {
    return switch (r) {
        // Han: radicals, iteration and number marks, the unified
        // ideographs, their extensions and compatibility forms.
        0x2e80...0x2fdf, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303b, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xf900...0xfaff, 0x20000...0x3fffd => true,
        // Hiragana and Katakana, but their combining voicing marks.
        0x3041...0x3096, 0x309d...0x309f, 0x30a1...0x30fa, 0x30fc...0x30ff, 0x31f0...0x31ff, 0xff66...0xff9d, 0x1b000...0x1b16f => true,
        else => false,
    };
}

/// Whether `a` and `b`, next to each other, are in different words or
/// runs of other runes: one is part of a word and the other not, or
/// either is a word on its own. A change from Latin to Han, or from kana
/// to kanji, is a boundary so.
pub fn boundary(a: u21, b: u21) bool {
    return isWordRune(a) != isWordRune(b) or standsAlone(a) or standsAlone(b);
}

pub fn isSpace(r: u21) bool {
    return switch (r) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

pub fn isPunctuation(r: u21) bool {
    return switch (r) {
        0x2010...0x2027, 0x2030...0x205e, 0x3001...0x3003, 0x3008...0x3011, 0x3014...0x301f, 0xff01...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65, 0xfffc => true,
        else => false,
    };
}

test "ideographs and kana are words alone; other scripts keep their runs" {
    try std.testing.expect(boundary('汉', '字'));
    try std.testing.expect(boundary('a', '汉'));
    try std.testing.expect(boundary('ひ', 'ら'));
    try std.testing.expect(boundary('カ', 'ー'));
    try std.testing.expect(!boundary('a', 'b'));
    try std.testing.expect(!boundary('한', '국'));
    try std.testing.expect(!boundary(' ', ','));
    try std.testing.expect(boundary('a', ' '));
    try std.testing.expect(!isWordRune('。'));
    try std.testing.expect(!standsAlone(0x3099));
}
