//! Which language the text engine is told for Han characters. The
//! language of a text decides the glyphs of the scripts it writes, which
//! some fonts draw apart by language, as the Han characters Chinese and
//! Japanese share, and the fonts the system falls back to for them. Han
//! characters in a text of a language that does not write them, as a
//! Chinese name in an English sentence, keep the glyphs the system picks
//! for them by the user's settings, as browsers keep them (Chromium's
//! LayoutLocale::LocaleForHan).
//!
//! On Windows the user's settings are more than the locale DirectWrite
//! falls back by. Its fallback for English draws Chinese text in Yu Gothic
//! UI, a Japanese font, where it has the characters, and in Microsoft
//! JhengHei UI, a Traditional Chinese one, where it lacks them: strokes of
//! two weights in one label. A user of English Windows who reads Chinese
//! lists it among their preferred languages, so Han characters in no
//! language that writes them take the first of those that does
//! (`userLanguage`), as Chromium takes the first of its accepted
//! languages. Text in Japanese or Chinese keeps its language.
const std = @import("std");

/// Whether a language, as a BCP 47 tag or a POSIX locale, writes Han
/// characters: Chinese, with its languages of other codes, Japanese and
/// Korean.
pub fn writesHan(lang: []const u8) bool {
    const end = std.mem.indexOfAny(u8, lang, "-_") orelse lang.len;
    const base = lang[0..end];
    const languages = [_][]const u8{ "zh", "ja", "ko", "yue", "cmn", "wuu", "hak", "nan", "gan", "hsn", "lzh", "cjy", "cpx", "czh", "czo", "mnp", "cdo" };
    for (languages) |name| if (std.ascii.eqlIgnoreCase(base, name)) return true;
    return false;
}

/// Whether `r` is a Han character, or a mark of punctuation or a
/// full-width form that the languages writing Han draw apart.
pub fn isCjk(r: u21) bool {
    return switch (r) {
        0x3000...0x303f, 0xff00...0xffef => true,
        // Han: radicals, ideographic description, the unified ideographs,
        // their extensions and compatibility forms.
        0x2e80...0x2fdf, 0x31c0...0x31ef, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xf900...0xfaff, 0x16fe2, 0x16fe3, 0x16ff0, 0x16ff1, 0x20000...0x3134f => true,
        else => false,
    };
}

/// The language Han characters in no language that writes them are drawn
/// in, given the locale the engine falls back by and the languages the
/// user prefers, in order: null when the locale writes them, which the
/// engine draws them in already, else the first preferred language that
/// writes them, else null for the system's own choice.
pub fn userLanguage(locale: []const u8, preferred: []const []const u8) ?[]const u8 {
    if (writesHan(locale)) return null;
    for (preferred) |lang| if (writesHan(lang)) return lang;
    return null;
}

/// A run of UTF-16 code units, from `start` to `end`.
pub const Run = extern struct { start: u32, end: u32 };

/// The runs of Han characters, and their punctuation, of UTF-16 `text` in
/// language `base`, which the engine is to be told in the user's language
/// for them (`userLanguage`): none when `base` writes them. At most
/// `out.len` runs; the rest of the text keeps the base language.
pub fn runs(text: []const u16, base: []const u8, out: []Run) []Run {
    if (writesHan(base)) return out[0..0];
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        var r: u21 = text[i];
        var n: usize = 1;
        if (text[i] >= 0xd800 and text[i] < 0xdc00 and i + 1 < text.len and text[i + 1] >= 0xdc00 and text[i + 1] < 0xe000) {
            r = 0x10000 + ((@as(u21, text[i]) - 0xd800) << 10) + (text[i + 1] - 0xdc00);
            n = 2;
        }
        if (isCjk(r)) {
            if (count > 0 and out[count - 1].end == i) {
                out[count - 1].end = @intCast(i + n);
            } else {
                if (count == out.len) break;
                out[count] = .{ .start = @intCast(i), .end = @intCast(i + n) };
                count += 1;
            }
        }
        i += n;
    }
    return out[0..count];
}

/// Splits a list of languages the system gives as strings each ended by a
/// NUL, ended by another (a Windows multi-string), into `out`.
pub fn splitMultiString(list: []const u8, out: [][]const u8) [][]const u8 {
    var count: usize = 0;
    var pieces = std.mem.splitScalar(u8, list, 0);
    while (pieces.next()) |piece| {
        if (piece.len == 0) continue;
        if (count == out.len) break;
        out[count] = piece;
        count += 1;
    }
    return out[0..count];
}

test "languages that write Han" {
    for ([_][]const u8{ "zh", "zh-Hans", "zh_TW", "ja-JP", "KO", "yue-HK", "cmn" }) |lang| try std.testing.expect(writesHan(lang));
    for ([_][]const u8{ "", "en", "en-US", "fr_FR", "vi", "zhx" }) |lang| try std.testing.expect(!writesHan(lang));
}

test "Han characters take the first preferred language that writes them" {
    try std.testing.expectEqualStrings("zh-Hans-CN", userLanguage("en-US", &.{ "en-US", "zh-Hans-CN", "ja-JP" }).?);
    try std.testing.expectEqualStrings("ja", userLanguage("en-GB", &.{ "fr-FR", "ja" }).?);
    // A locale that writes them keeps them; no such language, the system's.
    try std.testing.expect(userLanguage("zh-CN", &.{"ja-JP"}) == null);
    try std.testing.expect(userLanguage("ja-JP", &.{"zh-Hans"}) == null);
    try std.testing.expect(userLanguage("en-US", &.{ "en-US", "de-DE" }) == null);
    try std.testing.expect(userLanguage("en-US", &.{}) == null);
}

test "the Han runs of a text in a language that does not write them" {
    var buffer: [64]u16 = undefined;
    var out: [8]Run = undefined;
    const text = buffer[0..try std.unicode.utf8ToUtf16Le(&buffer, "Hi 我们说话，ok 𠀀!")];
    const found = runs(text, "en", &out);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(Run{ .start = 3, .end = 8 }, found[0]);
    // A supplementary ideograph is both of its units.
    try std.testing.expectEqual(Run{ .start = 11, .end = 13 }, found[1]);
    try std.testing.expectEqual(@as(usize, 2), runs(text, "", &out).len);
    // Text in Chinese or Japanese keeps its language.
    try std.testing.expectEqual(@as(usize, 0), runs(text, "zh-Hans", &out).len);
    try std.testing.expectEqual(@as(usize, 0), runs(text, "ja", &out).len);
    // Bounded: the runs past `out` keep the base language.
    try std.testing.expectEqual(@as(usize, 1), runs(text, "en", out[0..1]).len);
}

test "a system's multi-string of languages" {
    var out: [4][]const u8 = undefined;
    const found = splitMultiString("en-US\x00zh-Hans-CN\x00\x00", &out);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("zh-Hans-CN", found[1]);
}
