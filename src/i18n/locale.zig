const std = @import("std");
const builtin = @import("builtin");

/// Longest canonical tag kept by a Locale. Extensions and private-use
/// subtags are dropped while parsing, so ordinary tags stay far below this.
pub const max_tag_len = 32;
/// Upper bound of a fallback chain: tag, without variants, inferred script,
/// script-only and language-only entries.
pub const max_chain = 6;

pub const Direction = enum { ltr, rtl };

pub const ParseError = error{InvalidLocale};

/// Canonical BCP 47 language tag value: lowercase language, titlecase script,
/// uppercase region and lowercase variants. The root locale has an empty tag.
/// It is a plain value with no allocation or global registry.
pub const Locale = struct {
    bytes: [max_tag_len]u8 = undefined,
    len: u8 = 0,
    language_len: u8 = 0,
    script_start: u8 = 0,
    script_len: u8 = 0,
    region_start: u8 = 0,
    region_len: u8 = 0,
    variants_len: u8 = 0,

    pub const root: Locale = .{};

    /// Accepts `-` or `_` separators, case-insensitive subtags, a POSIX
    /// `.codeset` or `@modifier` suffix, and the `und`/`root` names. Extension
    /// and private-use sequences are ignored. `C` and `POSIX` are root.
    pub fn parse(text: []const u8) ParseError!Locale {
        var source = text;
        if (std.mem.indexOfAny(u8, source, ".@")) |end| source = source[0..end];
        if (source.len == 0) return error.InvalidLocale;
        if (std.ascii.eqlIgnoreCase(source, "root") or std.ascii.eqlIgnoreCase(source, "c") or std.ascii.eqlIgnoreCase(source, "posix")) return root;
        var parts = std.mem.tokenizeAny(u8, source, "-_");
        if (std.mem.indexOf(u8, source, "--") != null or std.mem.indexOf(u8, source, "__") != null) return error.InvalidLocale;
        if (source[0] == '-' or source[0] == '_' or source[source.len - 1] == '-' or source[source.len - 1] == '_') return error.InvalidLocale;
        const lang_part = parts.next() orelse return error.InvalidLocale;
        if (lang_part.len < 2 or lang_part.len > 8 or !allAlpha(lang_part)) return error.InvalidLocale;
        var script_part: ?[]const u8 = null;
        var region_part: ?[]const u8 = null;
        var variant_parts: [4][]const u8 = undefined;
        var variant_count: usize = 0;
        while (parts.next()) |part| {
            if (part.len == 1) break; // extension or private use: ignored
            if (script_part == null and region_part == null and variant_count == 0 and part.len == 4 and allAlpha(part)) {
                script_part = part;
            } else if (region_part == null and variant_count == 0 and ((part.len == 2 and allAlpha(part)) or (part.len == 3 and allDigit(part)))) {
                region_part = part;
            } else if ((part.len >= 5 and part.len <= 8 and allAlnum(part)) or (part.len == 4 and std.ascii.isDigit(part[0]) and allAlnum(part))) {
                if (variant_count == variant_parts.len) return error.InvalidLocale;
                variant_parts[variant_count] = part;
                variant_count += 1;
            } else return error.InvalidLocale;
        }
        if (std.ascii.eqlIgnoreCase(lang_part, "und") and script_part == null and region_part == null and variant_count == 0) return root;
        const lang: []const u8 = if (std.ascii.eqlIgnoreCase(lang_part, "und")) "" else lang_part;
        return compose(lang, script_part, region_part, variant_parts[0..variant_count]);
    }

    pub fn tag(self: *const Locale) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn isRoot(self: *const Locale) bool {
        return self.len == 0;
    }
    pub fn language(self: *const Locale) []const u8 {
        return self.bytes[0..self.language_len];
    }
    pub fn script(self: *const Locale) ?[]const u8 {
        return if (self.script_len == 0) null else self.bytes[self.script_start..][0..self.script_len];
    }
    pub fn region(self: *const Locale) ?[]const u8 {
        return if (self.region_len == 0) null else self.bytes[self.region_start..][0..self.region_len];
    }
    pub fn variants(self: *const Locale) ?[]const u8 {
        return if (self.variants_len == 0) null else self.bytes[self.len - self.variants_len .. self.len];
    }
    pub fn eql(a: *const Locale, b: *const Locale) bool {
        return std.mem.eql(u8, a.tag(), b.tag());
    }

    /// The explicit script, otherwise the most likely script for the language
    /// and region from a small built-in table (Latn when unknown).
    pub fn effectiveScript(self: *const Locale) []const u8 {
        return self.script() orelse likelyScript(self.language(), self.region());
    }

    /// Writing direction from the explicit or likely script. The pseudo
    /// region `XB` is right-to-left, matching the bidi pseudolocale.
    pub fn direction(self: *const Locale) Direction {
        if (self.region()) |r| if (std.mem.eql(u8, r, "XB")) return .rtl;
        const s = self.effectiveScript();
        for (rtl_scripts) |candidate| if (std.mem.eql(u8, s, candidate)) return .rtl;
        return .ltr;
    }

    /// Candidate tags from most to least specific. Root is not included; a
    /// catalog appends its own default chain. A language is not reached from
    /// a non-default script (zh-Hant never falls back to zh).
    pub fn fallbackChain(self: *const Locale) Chain {
        var chain: Chain = .{};
        if (self.isRoot()) return chain;
        const lang = self.language();
        const region_value = self.region();
        const explicit_script = self.script();
        const effective = self.effectiveScript();
        const default_script = likelyScript(lang, null);
        const default_script_matches = std.mem.eql(u8, effective, default_script);
        chain.push(self.*);
        chain.push(compose(lang, explicit_script, region_value, &.{}) catch unreachable);
        if (region_value) |r| {
            if (explicit_script == null and !default_script_matches) chain.push(compose(lang, effective, r, &.{}) catch unreachable);
            if (explicit_script != null and default_script_matches) chain.push(compose(lang, null, r, &.{}) catch unreachable);
        }
        if (!default_script_matches) {
            chain.push(compose(lang, effective, null, &.{}) catch unreachable);
            return chain;
        }
        if (explicit_script) |s| chain.push(compose(lang, s, null, &.{}) catch unreachable);
        chain.push(compose(lang, null, null, &.{}) catch unreachable);
        return chain;
    }

    pub fn format(self: Locale, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(if (self.isRoot()) "root" else self.tag());
    }
};

pub const Chain = struct {
    items: [max_chain]Locale = undefined,
    len: usize = 0,

    pub fn slice(self: *const Chain) []const Locale {
        return self.items[0..self.len];
    }
    fn push(self: *Chain, locale: Locale) void {
        for (self.items[0..self.len]) |*existing| if (existing.eql(&locale)) return;
        std.debug.assert(self.len < max_chain);
        self.items[self.len] = locale;
        self.len += 1;
    }
};

fn compose(language: []const u8, script: ?[]const u8, region: ?[]const u8, variants: []const []const u8) ParseError!Locale {
    var out: Locale = .{};
    var w: usize = 0;
    const put = struct {
        fn f(buf: *[max_tag_len]u8, at: *usize, part: []const u8, mode: enum { lower, upper, title }) ParseError!void {
            if (at.* + part.len > max_tag_len) return error.InvalidLocale;
            for (part, 0..) |c, i| buf[at.* + i] = switch (mode) {
                .lower => std.ascii.toLower(c),
                .upper => std.ascii.toUpper(c),
                .title => if (i == 0) std.ascii.toUpper(c) else std.ascii.toLower(c),
            };
            at.* += part.len;
        }
        fn sep(buf: *[max_tag_len]u8, at: *usize) ParseError!void {
            if (at.* == 0) return;
            if (at.* + 1 > max_tag_len) return error.InvalidLocale;
            buf[at.*] = '-';
            at.* += 1;
        }
    };
    if (language.len == 0) {
        try put.f(&out.bytes, &w, "und", .lower);
        out.language_len = 0;
    } else {
        try put.f(&out.bytes, &w, language, .lower);
        out.language_len = @intCast(language.len);
    }
    if (script) |s| {
        try put.sep(&out.bytes, &w);
        out.script_start = @intCast(w);
        out.script_len = @intCast(s.len);
        try put.f(&out.bytes, &w, s, .title);
    }
    if (region) |r| {
        try put.sep(&out.bytes, &w);
        out.region_start = @intCast(w);
        out.region_len = @intCast(r.len);
        try put.f(&out.bytes, &w, r, .upper);
    }
    const before_variants = w;
    for (variants) |v| {
        try put.sep(&out.bytes, &w);
        try put.f(&out.bytes, &w, v, .lower);
    }
    out.len = @intCast(w);
    out.variants_len = if (variants.len == 0) 0 else @intCast(w - before_variants - 1);
    return out;
}

const rtl_scripts = [_][]const u8{ "Arab", "Hebr", "Thaa", "Syrc", "Nkoo", "Adlm", "Rohg", "Mand", "Samr", "Mend" };

const ScriptEntry = struct { language: []const u8, script: []const u8 };
const likely_scripts = [_]ScriptEntry{
    .{ .language = "ar", .script = "Arab" }, .{ .language = "fa", .script = "Arab" },  .{ .language = "ur", .script = "Arab" },
    .{ .language = "ps", .script = "Arab" }, .{ .language = "ckb", .script = "Arab" }, .{ .language = "sd", .script = "Arab" },
    .{ .language = "ug", .script = "Arab" }, .{ .language = "he", .script = "Hebr" },  .{ .language = "iw", .script = "Hebr" },
    .{ .language = "yi", .script = "Hebr" }, .{ .language = "dv", .script = "Thaa" },  .{ .language = "syr", .script = "Syrc" },
    .{ .language = "ru", .script = "Cyrl" }, .{ .language = "uk", .script = "Cyrl" },  .{ .language = "be", .script = "Cyrl" },
    .{ .language = "bg", .script = "Cyrl" }, .{ .language = "mk", .script = "Cyrl" },  .{ .language = "sr", .script = "Cyrl" },
    .{ .language = "kk", .script = "Cyrl" }, .{ .language = "mn", .script = "Cyrl" },  .{ .language = "el", .script = "Grek" },
    .{ .language = "hy", .script = "Armn" }, .{ .language = "ka", .script = "Geor" },  .{ .language = "hi", .script = "Deva" },
    .{ .language = "mr", .script = "Deva" }, .{ .language = "ne", .script = "Deva" },  .{ .language = "bn", .script = "Beng" },
    .{ .language = "ta", .script = "Taml" }, .{ .language = "te", .script = "Telu" },  .{ .language = "th", .script = "Thai" },
    .{ .language = "lo", .script = "Laoo" }, .{ .language = "km", .script = "Khmr" },  .{ .language = "my", .script = "Mymr" },
    .{ .language = "am", .script = "Ethi" }, .{ .language = "ja", .script = "Jpan" },  .{ .language = "ko", .script = "Kore" },
    .{ .language = "zh", .script = "Hans" },
};

/// Small likely-subtags table for direction and fallback decisions. It is
/// not a complete likely-subtags database.
pub fn likelyScript(language: []const u8, region: ?[]const u8) []const u8 {
    if (std.mem.eql(u8, language, "zh")) {
        if (region) |r| for ([_][]const u8{ "TW", "HK", "MO" }) |hant| if (std.mem.eql(u8, r, hant)) return "Hant";
        return "Hans";
    }
    for (likely_scripts) |entry| if (std.mem.eql(u8, entry.language, language)) return entry.script;
    return "Latn";
}

/// Picks the first available locale for the first requested locale that can
/// use one: exact fallback-chain matches first, then the same language and
/// effective script (so `en` selects `en-US` and `zh-HK` selects `zh-TW`).
pub fn negotiate(requested: []const Locale, available: []const Locale) ?usize {
    for (requested) |*want| {
        const chain = want.fallbackChain();
        for (chain.slice()) |*candidate| {
            for (available, 0..) |*have, index| if (have.eql(candidate)) return index;
        }
        if (want.isRoot()) continue;
        for (available, 0..) |*have, index| {
            if (std.mem.eql(u8, have.language(), want.language()) and std.mem.eql(u8, have.effectiveScript(), want.effectiveScript())) return index;
        }
    }
    return null;
}

/// Interprets one POSIX locale value such as `de_DE.UTF-8@euro`. `C`,
/// `POSIX` and empty values carry no language and return null.
pub fn fromPosix(value: []const u8) ?Locale {
    const locale = Locale.parse(value) catch return null;
    return if (locale.isRoot()) null else locale;
}

/// The user's display locale from the operating system, read when called.
/// Linux uses LC_ALL, LC_MESSAGES and LANG in that order; Windows queries
/// the user default locale name. Returns null when nothing usable is set.
pub fn system() ?Locale {
    switch (builtin.os.tag) {
        .windows => {
            var wide: [85]u16 = undefined;
            const count = GetUserDefaultLocaleName(&wide, wide.len);
            if (count <= 1) return null;
            var narrow: [85]u8 = undefined;
            for (wide[0..@intCast(count - 1)], 0..) |c, i| {
                if (c > 0x7f) return null;
                narrow[i] = @intCast(c);
            }
            return fromPosix(narrow[0..@intCast(count - 1)]);
        },
        .linux => {
            for ([_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
                const value = std.posix.getenv(name) orelse continue;
                if (value.len == 0) continue;
                return fromPosix(value);
            }
            return null;
        },
        else => return null,
    }
}

extern "kernel32" fn GetUserDefaultLocaleName(name: [*]u16, capacity: c_int) callconv(.winapi) c_int;

fn allAlpha(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}
fn allDigit(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
fn allAlnum(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn expectChain(tag: []const u8, expected: []const []const u8) !void {
    const locale = try Locale.parse(tag);
    const chain = locale.fallbackChain();
    try std.testing.expectEqual(expected.len, chain.len);
    for (expected, chain.slice()) |want, *have| try std.testing.expectEqualStrings(want, have.tag());
}

test "parse canonicalizes case, separators and POSIX suffixes" {
    const a = try Locale.parse("ZH_hant_tw");
    try std.testing.expectEqualStrings("zh-Hant-TW", a.tag());
    try std.testing.expectEqualStrings("zh", a.language());
    try std.testing.expectEqualStrings("Hant", a.script().?);
    try std.testing.expectEqualStrings("TW", a.region().?);
    try std.testing.expectEqualStrings("de-DE", (try Locale.parse("de_DE.UTF-8@euro")).tag());
    try std.testing.expectEqualStrings("es-419", (try Locale.parse("es-419")).tag());
    try std.testing.expectEqualStrings("de-CH-1996", (try Locale.parse("de-ch-1996")).tag());
    try std.testing.expectEqualStrings("1996", (try Locale.parse("de-ch-1996")).variants().?);
    try std.testing.expectEqualStrings("en-US", (try Locale.parse("en-US-u-ca-gregory")).tag());
    try std.testing.expect((try Locale.parse("und")).isRoot());
    try std.testing.expect((try Locale.parse("C.UTF-8")).isRoot());
    try std.testing.expect(fromPosix("POSIX") == null);
    for ([_][]const u8{ "", "e", "en--US", "en-", "-en", "en-USA1", "toolonglanguage", "en-Latn-Latn" }) |bad|
        try std.testing.expectError(error.InvalidLocale, Locale.parse(bad));
}

test "fallback chains keep scripts apart" {
    try expectChain("en-US", &.{ "en-US", "en" });
    try expectChain("de-CH-1996", &.{ "de-CH-1996", "de-CH", "de" });
    try expectChain("zh-TW", &.{ "zh-TW", "zh-Hant-TW", "zh-Hant" });
    try expectChain("zh-Hant-HK", &.{ "zh-Hant-HK", "zh-Hant" });
    try expectChain("zh-Hans-CN", &.{ "zh-Hans-CN", "zh-CN", "zh-Hans", "zh" });
    try expectChain("zh-CN", &.{ "zh-CN", "zh" });
    try expectChain("sr-Latn-RS", &.{ "sr-Latn-RS", "sr-Latn" });
    try expectChain("ar", &.{"ar"});
    try std.testing.expectEqual(@as(usize, 0), Locale.root.fallbackChain().len);
}

test "direction follows script and pseudo region" {
    try std.testing.expectEqual(Direction.rtl, (try Locale.parse("ar-EG")).direction());
    try std.testing.expectEqual(Direction.rtl, (try Locale.parse("he")).direction());
    try std.testing.expectEqual(Direction.rtl, (try Locale.parse("fa-IR")).direction());
    try std.testing.expectEqual(Direction.ltr, (try Locale.parse("az-Latn")).direction());
    try std.testing.expectEqual(Direction.rtl, (try Locale.parse("az-Arab")).direction());
    try std.testing.expectEqual(Direction.rtl, (try Locale.parse("en-XB")).direction());
    try std.testing.expectEqual(Direction.ltr, (try Locale.parse("en-XA")).direction());
    try std.testing.expectEqual(Direction.ltr, Locale.root.direction());
}

test "negotiation prefers chains, then language and script" {
    const available = [_]Locale{ try Locale.parse("en-US"), try Locale.parse("fr"), try Locale.parse("zh-TW"), try Locale.parse("zh-CN") };
    const pick = struct {
        fn f(avail: []const Locale, tags: []const []const u8) !?usize {
            var requested: [4]Locale = undefined;
            for (tags, 0..) |t, i| requested[i] = try Locale.parse(t);
            return negotiate(requested[0..tags.len], avail);
        }
    }.f;
    try std.testing.expectEqual(@as(?usize, 1), try pick(&available, &.{"fr-CA"}));
    try std.testing.expectEqual(@as(?usize, 0), try pick(&available, &.{"en"}));
    try std.testing.expectEqual(@as(?usize, 0), try pick(&available, &.{"en-GB"}));
    try std.testing.expectEqual(@as(?usize, 2), try pick(&available, &.{"zh-HK"}));
    try std.testing.expectEqual(@as(?usize, 3), try pick(&available, &.{"zh-SG"}));
    try std.testing.expectEqual(@as(?usize, 1), try pick(&available, &.{ "ja", "fr" }));
    try std.testing.expectEqual(@as(?usize, null), try pick(&available, &.{"ja"}));
}

test "system locale query returns a usable tag or null" {
    if (system()) |found| try std.testing.expect(!found.isRoot());
}
