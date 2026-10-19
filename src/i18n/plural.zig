const std = @import("std");
const Locale = @import("locale.zig").Locale;

pub const Category = enum {
    zero,
    one,
    two,
    few,
    many,
    other,

    pub fn parse(name: []const u8) ?Category {
        return std.meta.stringToEnum(Category, name);
    }
};

/// Plural operands of a formatted decimal: integer digits `i`, visible
/// fraction digit count `v`, visible fraction digits `f` and the same
/// without trailing zeros `t`. The sign is ignored, as in plural rules.
pub const Operands = struct {
    i: u64,
    v: u8 = 0,
    f: u64 = 0,
    t: u64 = 0,

    pub const max_fraction_digits = 18;

    pub fn fromInt(value: i64) Operands {
        return .{ .i = @abs(value) };
    }

    /// Parses `[-]digits[.digits]` exactly as it will be displayed, so
    /// `1.0` and `1` select different categories where the language
    /// distinguishes them. Integer parts above u64 are rejected.
    pub fn parse(text: []const u8) error{InvalidNumber}!Operands {
        var digits = text;
        if (digits.len > 0 and (digits[0] == '-' or digits[0] == '+')) digits = digits[1..];
        const dot = std.mem.indexOfScalar(u8, digits, '.');
        const int_part = digits[0 .. dot orelse digits.len];
        const frac_part = if (dot) |d| digits[d + 1 ..] else "";
        if (int_part.len == 0 or (dot != null and frac_part.len == 0) or frac_part.len > max_fraction_digits) return error.InvalidNumber;
        const i = std.fmt.parseUnsigned(u64, int_part, 10) catch return error.InvalidNumber;
        var f: u64 = 0;
        for (frac_part) |c| {
            if (!std.ascii.isDigit(c)) return error.InvalidNumber;
            f = f * 10 + (c - '0');
        }
        var t = f;
        while (t != 0 and t % 10 == 0) t /= 10;
        return .{ .i = i, .v = @intCast(frac_part.len), .f = f, .t = t };
    }

    /// The integer value of `n` when it has no non-zero fraction digits.
    fn integer(self: Operands) ?u64 {
        return if (self.f == 0) self.i else null;
    }
};

/// Built-in rule families. Locales outside the table use `other_only`,
/// which keeps messages correct for languages without plural inflection
/// and selects `other` everywhere else.
pub const Rules = enum {
    other_only,
    one_i1_v0, // en, de, nl, sv, fi, et, ...
    one_n1, // el, hu, tr, bg, nb, ...
    one_i0_or_n1, // hi, bn, fa, zu, ...
    one_i01, // fr, pt (Brazil): i = 0,1 plus the million form
    romance_i1, // it, ca, es-like with i = 1, v = 0 plus million form
    spanish, // n = 1 plus million form
    portugal, // pt-PT: i = 1, v = 0 plus million form
    danish,
    east_slavic, // ru, uk
    belarusian,
    polish,
    czech, // cs, sk
    south_slavic, // hr, sr, bs
    slovenian,
    lithuanian,
    latvian,
    romanian,
    arabic,
    hebrew,
    irish,
    welsh,
};

const RuleEntry = struct { language: []const u8, rules: Rules };
const rule_table = [_]RuleEntry{
    .{ .language = "en", .rules = .one_i1_v0 },    .{ .language = "de", .rules = .one_i1_v0 },    .{ .language = "nl", .rules = .one_i1_v0 },
    .{ .language = "sv", .rules = .one_i1_v0 },    .{ .language = "fi", .rules = .one_i1_v0 },    .{ .language = "et", .rules = .one_i1_v0 },
    .{ .language = "ur", .rules = .one_i1_v0 },    .{ .language = "fy", .rules = .one_i1_v0 },    .{ .language = "ga", .rules = .irish },
    .{ .language = "el", .rules = .one_n1 },       .{ .language = "hu", .rules = .one_n1 },       .{ .language = "tr", .rules = .one_n1 },
    .{ .language = "bg", .rules = .one_n1 },       .{ .language = "nb", .rules = .one_n1 },       .{ .language = "no", .rules = .one_n1 },
    .{ .language = "nn", .rules = .one_n1 },       .{ .language = "az", .rules = .one_n1 },       .{ .language = "ka", .rules = .one_n1 },
    .{ .language = "kk", .rules = .one_n1 },       .{ .language = "sq", .rules = .one_n1 },       .{ .language = "eu", .rules = .one_n1 },
    .{ .language = "hi", .rules = .one_i0_or_n1 }, .{ .language = "bn", .rules = .one_i0_or_n1 }, .{ .language = "fa", .rules = .one_i0_or_n1 },
    .{ .language = "gu", .rules = .one_i0_or_n1 }, .{ .language = "kn", .rules = .one_i0_or_n1 }, .{ .language = "mr", .rules = .one_n1 },
    .{ .language = "zu", .rules = .one_i0_or_n1 }, .{ .language = "am", .rules = .one_i0_or_n1 }, .{ .language = "fr", .rules = .one_i01 },
    .{ .language = "pt", .rules = .one_i01 },      .{ .language = "it", .rules = .romance_i1 },   .{ .language = "ca", .rules = .romance_i1 },
    .{ .language = "es", .rules = .spanish },      .{ .language = "da", .rules = .danish },       .{ .language = "ru", .rules = .east_slavic },
    .{ .language = "uk", .rules = .east_slavic },  .{ .language = "be", .rules = .belarusian },   .{ .language = "pl", .rules = .polish },
    .{ .language = "cs", .rules = .czech },        .{ .language = "sk", .rules = .czech },        .{ .language = "hr", .rules = .south_slavic },
    .{ .language = "sr", .rules = .south_slavic }, .{ .language = "bs", .rules = .south_slavic }, .{ .language = "sl", .rules = .slovenian },
    .{ .language = "lt", .rules = .lithuanian },   .{ .language = "lv", .rules = .latvian },      .{ .language = "ro", .rules = .romanian },
    .{ .language = "ar", .rules = .arabic },       .{ .language = "he", .rules = .hebrew },       .{ .language = "iw", .rules = .hebrew },
    .{ .language = "cy", .rules = .welsh },
};

pub fn rulesFor(locale: *const Locale) Rules {
    const language = locale.language();
    if (std.mem.eql(u8, language, "pt")) {
        if (locale.region()) |r| if (std.mem.eql(u8, r, "PT")) return .portugal;
    }
    for (rule_table) |entry| if (std.mem.eql(u8, entry.language, language)) return entry.rules;
    return .other_only;
}

fn in(value: u64, low: u64, high: u64) bool {
    return value >= low and value <= high;
}

fn millionForm(o: Operands) bool {
    return o.v == 0 and o.i != 0 and o.i % 1_000_000 == 0;
}

pub fn cardinal(rules: Rules, o: Operands) Category {
    const n = o.integer();
    const iv0 = o.v == 0;
    return switch (rules) {
        .other_only => .other,
        .one_i1_v0 => if (o.i == 1 and iv0) .one else .other,
        .one_n1 => if (n == 1) .one else .other,
        .one_i0_or_n1 => if (o.i == 0 or n == 1) .one else .other,
        .one_i01 => if (o.i <= 1) .one else if (millionForm(o)) .many else .other,
        .romance_i1, .portugal => if (o.i == 1 and iv0) .one else if (millionForm(o)) .many else .other,
        .spanish => if (n == 1) .one else if (millionForm(o)) .many else .other,
        .danish => if (n == 1 or (o.t != 0 and o.i <= 1)) .one else .other,
        .east_slavic => if (!iv0) .other else if (o.i % 10 == 1 and o.i % 100 != 11) .one else if (in(o.i % 10, 2, 4) and !in(o.i % 100, 12, 14)) .few else .many,
        .belarusian => if (n) |x| (if (x % 10 == 1 and x % 100 != 11) .one else if (in(x % 10, 2, 4) and !in(x % 100, 12, 14)) .few else .many) else .other,
        .polish => if (o.i == 1 and iv0) .one else if (!iv0) .other else if (in(o.i % 10, 2, 4) and !in(o.i % 100, 12, 14)) .few else .many,
        .czech => if (!iv0) .many else if (o.i == 1) .one else if (in(o.i, 2, 4)) .few else .other,
        .south_slavic => if ((iv0 and o.i % 10 == 1 and o.i % 100 != 11) or (o.f % 10 == 1 and o.f % 100 != 11)) .one else if ((iv0 and in(o.i % 10, 2, 4) and !in(o.i % 100, 12, 14)) or (in(o.f % 10, 2, 4) and !in(o.f % 100, 12, 14))) .few else .other,
        .slovenian => if (!iv0) .few else if (o.i % 100 == 1) .one else if (o.i % 100 == 2) .two else if (in(o.i % 100, 3, 4)) .few else .other,
        .lithuanian => if (o.f != 0) .many else if (o.i % 10 == 1 and !in(o.i % 100, 11, 19)) .one else if (in(o.i % 10, 2, 9) and !in(o.i % 100, 11, 19)) .few else .other,
        .latvian => blk: {
            if ((n != null and (o.i % 10 == 0 or in(o.i % 100, 11, 19))) or (o.v == 2 and in(o.f % 100, 11, 19))) break :blk .zero;
            if ((n != null and o.i % 10 == 1 and o.i % 100 != 11) or (o.v == 2 and o.f % 10 == 1 and o.f % 100 != 11) or (o.v != 2 and o.f % 10 == 1)) break :blk .one;
            break :blk .other;
        },
        .romanian => if (o.i == 1 and iv0) .one else if (!iv0 or n == 0 or (n != null and in(o.i % 100, 1, 19))) .few else .other,
        .arabic => if (n) |x| (if (x == 0) .zero else if (x == 1) .one else if (x == 2) .two else if (in(x % 100, 3, 10)) .few else if (in(x % 100, 11, 99)) .many else .other) else .other,
        .hebrew => if ((o.i == 1 and iv0) or (o.i == 0 and !iv0)) .one else if (o.i == 2 and iv0) .two else .other,
        .irish => if (n) |x| (if (x == 1) .one else if (x == 2) .two else if (in(x, 3, 6)) .few else if (in(x, 7, 10)) .many else .other) else .other,
        .welsh => if (n) |x| (if (x == 0) .zero else if (x == 1) .one else if (x == 2) .two else if (x == 3) .few else if (x == 6) .many else .other) else .other,
    };
}

/// Ordinal categories for `selectordinal`. Built in for English, French,
/// Italian and Swedish; every other language selects `other`.
pub fn ordinal(locale: *const Locale, o: Operands) Category {
    const n = o.integer() orelse return .other;
    const language = locale.language();
    if (std.mem.eql(u8, language, "en")) {
        if (n % 10 == 1 and n % 100 != 11) return .one;
        if (n % 10 == 2 and n % 100 != 12) return .two;
        if (n % 10 == 3 and n % 100 != 13) return .few;
        return .other;
    }
    if (std.mem.eql(u8, language, "fr")) return if (n == 1) .one else .other;
    if (std.mem.eql(u8, language, "it")) return if (n == 11 or n == 8 or n == 80 or n == 800) .many else .other;
    if (std.mem.eql(u8, language, "sv")) return if ((n % 10 == 1 or n % 10 == 2) and n % 100 != 11 and n % 100 != 12) .one else .other;
    return .other;
}

fn expectCardinal(tag: []const u8, text: []const u8, expected: Category) !void {
    const locale = try Locale.parse(tag);
    try std.testing.expectEqual(expected, cardinal(rulesFor(&locale), try Operands.parse(text)));
}

test "operands keep visible fraction digits" {
    const o = try Operands.parse("-12.500");
    try std.testing.expectEqual(@as(u64, 12), o.i);
    try std.testing.expectEqual(@as(u8, 3), o.v);
    try std.testing.expectEqual(@as(u64, 500), o.f);
    try std.testing.expectEqual(@as(u64, 5), o.t);
    for ([_][]const u8{ "", ".5", "1.", "1.2.3", "a", "18446744073709551616", "0.1234567890123456789" }) |bad|
        try std.testing.expectError(error.InvalidNumber, Operands.parse(bad));
}

test "cardinal rule samples" {
    try expectCardinal("en", "1", .one);
    try expectCardinal("en", "1.0", .other);
    try expectCardinal("en", "0", .other);
    try expectCardinal("fr", "0", .one);
    try expectCardinal("fr", "1.5", .one);
    try expectCardinal("fr", "2", .other);
    try expectCardinal("fr", "1000000", .many);
    try expectCardinal("pt", "0", .one);
    try expectCardinal("pt-PT", "0", .other);
    try expectCardinal("es", "1", .one);
    try expectCardinal("es", "2000000", .many);
    try expectCardinal("it", "1", .one);
    try expectCardinal("da", "0.1", .one);
    try expectCardinal("ru", "1", .one);
    try expectCardinal("ru", "21", .one);
    try expectCardinal("ru", "11", .many);
    try expectCardinal("ru", "3", .few);
    try expectCardinal("ru", "13", .many);
    try expectCardinal("ru", "25", .many);
    try expectCardinal("ru", "1.5", .other);
    try expectCardinal("pl", "1", .one);
    try expectCardinal("pl", "22", .few);
    try expectCardinal("pl", "21", .many);
    try expectCardinal("pl", "12", .many);
    try expectCardinal("cs", "3", .few);
    try expectCardinal("cs", "1.5", .many);
    try expectCardinal("hr", "0.1", .one);
    try expectCardinal("sl", "102", .two);
    try expectCardinal("lt", "0.5", .many);
    try expectCardinal("lt", "12", .other);
    try expectCardinal("lv", "10", .zero);
    try expectCardinal("lv", "21", .one);
    try expectCardinal("ro", "0", .few);
    try expectCardinal("ro", "101", .few);
    try expectCardinal("ro", "120", .other);
    try expectCardinal("ar", "0", .zero);
    try expectCardinal("ar", "2", .two);
    try expectCardinal("ar", "103", .few);
    try expectCardinal("ar", "111", .many);
    try expectCardinal("ar", "100", .other);
    try expectCardinal("he", "2", .two);
    try expectCardinal("he", "0.5", .one);
    try expectCardinal("ga", "7", .many);
    try expectCardinal("cy", "6", .many);
    try expectCardinal("ja", "1", .other);
    try expectCardinal("zh-Hant", "1", .other);
    try expectCardinal("hi", "0", .one);
    try expectCardinal("tr", "1", .one);
}

test "ordinal rule samples" {
    const en = try Locale.parse("en-US");
    try std.testing.expectEqual(Category.one, ordinal(&en, .fromInt(21)));
    try std.testing.expectEqual(Category.two, ordinal(&en, .fromInt(42)));
    try std.testing.expectEqual(Category.few, ordinal(&en, .fromInt(103)));
    try std.testing.expectEqual(Category.other, ordinal(&en, .fromInt(111)));
    try std.testing.expectEqual(Category.other, ordinal(&en, .fromInt(12)));
    const it = try Locale.parse("it");
    try std.testing.expectEqual(Category.many, ordinal(&it, .fromInt(800)));
    const de = try Locale.parse("de");
    try std.testing.expectEqual(Category.other, ordinal(&de, .fromInt(1)));
}
