const std = @import("std");
const Locale = @import("locale.zig").Locale;

/// Locale number symbols. `zero` is the code point of the digit zero; the
/// other nine digits follow it contiguously.
pub const Symbols = struct {
    decimal: []const u8 = ".",
    group: []const u8 = ",",
    minus: []const u8 = "-",
    percent: []const u8 = "%",
    zero: u21 = '0',
    primary_group: u8 = 3,
    secondary_group: u8 = 3,
    /// Integers with fewer than `primary_group + min_grouping` digits are
    /// not grouped (2 means 1234 but 12,345).
    min_grouping: u8 = 1,
    percent_prefix: bool = false,
    /// Text between number and percent sign (or sign and number when the
    /// sign is a prefix).
    percent_space: []const u8 = "",
    currency_prefix: bool = true,
    currency_space: []const u8 = "",
    nan: []const u8 = "NaN",
    infinity: []const u8 = "∞",
};

const nbsp = "\u{00A0}";
const nnbsp = "\u{202F}";

const SymbolEntry = struct { tag: []const u8, symbols: Symbols };
/// Matched by the locale fallback chain, so `de-AT` uses `de`.
const symbol_table = [_]SymbolEntry{
    .{ .tag = "en", .symbols = .{} },
    .{ .tag = "en-IN", .symbols = .{ .secondary_group = 2 } },
    .{ .tag = "hi", .symbols = .{ .secondary_group = 2 } },
    .{ .tag = "de", .symbols = .{ .decimal = ",", .group = ".", .percent_space = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "de-CH", .symbols = .{ .decimal = ".", .group = "’", .currency_space = nbsp } },
    .{ .tag = "fr", .symbols = .{ .decimal = ",", .group = nnbsp, .percent_space = nnbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "es", .symbols = .{ .decimal = ",", .group = ".", .min_grouping = 2, .percent_space = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "es-MX", .symbols = .{ .min_grouping = 1 } },
    .{ .tag = "it", .symbols = .{ .decimal = ",", .group = ".", .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "pt", .symbols = .{ .decimal = ",", .group = ".", .currency_space = nbsp } },
    .{ .tag = "pt-PT", .symbols = .{ .decimal = ",", .group = nbsp, .min_grouping = 2, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "nl", .symbols = .{ .decimal = ",", .group = ".", .currency_space = nbsp } },
    .{ .tag = "ru", .symbols = .{ .decimal = ",", .group = nbsp, .percent_space = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "uk", .symbols = .{ .decimal = ",", .group = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "pl", .symbols = .{ .decimal = ",", .group = nbsp, .min_grouping = 2, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "cs", .symbols = .{ .decimal = ",", .group = nbsp, .percent_space = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "sv", .symbols = .{ .decimal = ",", .group = nbsp, .minus = "\u{2212}", .percent_space = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "nb", .symbols = .{ .decimal = ",", .group = nbsp, .minus = "\u{2212}", .percent_space = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "fi", .symbols = .{ .decimal = ",", .group = nbsp, .minus = "\u{2212}", .percent_space = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "da", .symbols = .{ .decimal = ",", .group = ".", .percent_space = nbsp, .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "tr", .symbols = .{ .decimal = ",", .group = ".", .percent_prefix = true } },
    .{ .tag = "ja", .symbols = .{} },
    .{ .tag = "zh", .symbols = .{} },
    .{ .tag = "ko", .symbols = .{} },
    .{ .tag = "he", .symbols = .{ .minus = "\u{200E}-", .currency_prefix = false, .currency_space = nbsp } },
    .{ .tag = "ar", .symbols = .{ .decimal = "٫", .group = "٬", .minus = "\u{061C}-", .percent = "٪\u{061C}", .zero = 0x0660, .currency_prefix = false, .currency_space = nbsp, .nan = "ليس رقمًا" } },
    .{ .tag = "fa", .symbols = .{ .decimal = "٫", .group = "٬", .minus = "\u{200E}\u{2212}", .percent = "٪", .zero = 0x06F0, .percent_prefix = true, .currency_space = nbsp, .nan = "ناعدد" } },
};

pub const root_symbols: Symbols = .{};

/// Symbols for the most specific listed locale on the fallback chain, or
/// the root (`1,234.5`) symbols.
pub fn symbolsFor(locale: *const Locale) *const Symbols {
    const chain = locale.fallbackChain();
    for (chain.slice()) |*candidate| {
        for (&symbol_table) |*entry| if (std.mem.eql(u8, entry.tag, candidate.tag())) return &entry.symbols;
    }
    return &root_symbols;
}

pub const Style = enum { decimal, percent, currency };

pub const Options = struct {
    style: Style = .decimal,
    min_fraction: u8 = 0,
    max_fraction: u8 = 3,
    grouping: bool = true,
    /// Currency symbol or ISO code written as given for `.currency`.
    currency: []const u8 = "",

    pub const integer: Options = .{ .max_fraction = 0 };
    pub const percent: Options = .{ .style = .percent, .max_fraction = 0 };
};

pub const max_fraction_digits = 15;
pub const Error = error{ InvalidOptions, WriteFailed };

/// Plain ASCII digits of a rounded value, before locale symbols. `text` is
/// `[-]digits[.digits]`, suitable for plural operands.
pub const Digits = struct {
    buffer: [400]u8 = undefined,
    len: usize = 0,
    kind: enum { finite, nan, infinite } = .finite,

    pub fn text(self: *const Digits) []const u8 {
        return self.buffer[0..self.len];
    }
    pub fn negative(self: *const Digits) bool {
        return self.len > 0 and self.buffer[0] == '-';
    }
};

fn checkOptions(options: Options) Error!void {
    if (options.max_fraction > max_fraction_digits or options.min_fraction > options.max_fraction) return error.InvalidOptions;
}

/// Rounds the shortest round-trip decimal form of `value` half to even
/// (percent shifts that decimal by two places first, without a binary
/// multiplication) and trims trailing zeros down to `min_fraction`.
pub fn digitsFloat(value: f64, options: Options) Error!Digits {
    try checkOptions(options);
    var out: Digits = .{};
    if (!std.math.isFinite(value)) {
        out.kind = if (std.math.isNan(value)) .nan else .infinite;
        if (std.math.isNegativeInf(value)) {
            out.buffer[0] = '-';
            out.len = 1;
        }
        return out;
    }
    var shortest_buffer: [400]u8 = undefined;
    const shortest = std.fmt.bufPrint(&shortest_buffer, "{d}", .{@abs(value)}) catch unreachable;
    const dot = std.mem.indexOfScalar(u8, shortest, '.');
    var int_digits: []const u8 = shortest[0 .. dot orelse shortest.len];
    var frac_digits: []const u8 = if (dot) |d| shortest[d + 1 ..] else "";
    // Assemble sign, integer and fraction at buffer[1..] so a carry can use
    // buffer[0]; the shift for percent moves two fraction digits left.
    var digits: [420]u8 = undefined;
    var n: usize = 0;
    @memcpy(digits[n..][0..int_digits.len], int_digits);
    n += int_digits.len;
    if (options.style == .percent) {
        for (0..2) |i| {
            digits[n] = if (i < frac_digits.len) frac_digits[i] else '0';
            n += 1;
        }
        frac_digits = frac_digits[@min(2, frac_digits.len)..];
    }
    int_digits = std.mem.trimLeft(u8, digits[0..n], "0");
    if (int_digits.len == 0) int_digits = "0";
    var len: usize = 0;
    const text = out.buffer[1..];
    if (value < 0) {
        text[0] = '-';
        len = 1;
    }
    @memcpy(text[len..][0..int_digits.len], int_digits);
    len += int_digits.len;
    const kept = @min(frac_digits.len, options.max_fraction);
    if (kept > 0) {
        text[len] = '.';
        @memcpy(text[len + 1 ..][0..kept], frac_digits[0..kept]);
        len += 1 + kept;
    }
    if (frac_digits.len > kept) {
        const rest = frac_digits[kept..];
        const above_half = rest[0] > '5' or (rest[0] == '5' and std.mem.trimRight(u8, rest[1..], "0").len > 0);
        const tie = rest[0] == '5' and !above_half;
        if (above_half or (tie and (text[len - 1] - '0') % 2 == 1)) len = incrementLast(&out.buffer, len);
    }
    std.mem.copyForwards(u8, out.buffer[0..len], out.buffer[1..][0..len]);
    const point = std.mem.indexOfScalar(u8, out.buffer[0..len], '.');
    const have = if (point) |p| len - p - 1 else 0;
    if (have < options.min_fraction) {
        if (point == null) {
            out.buffer[len] = '.';
            len += 1;
        }
        @memset(out.buffer[len..][0 .. options.min_fraction - have], '0');
        len += options.min_fraction - have;
    }
    out.len = trimFraction(out.buffer[0..len], options.min_fraction);
    if (out.negative() and allZero(out.text()[1..])) {
        std.mem.copyForwards(u8, out.buffer[0 .. out.len - 1], out.buffer[1..out.len]);
        out.len -= 1;
    }
    return out;
}

/// Adds one unit in the last place of the `[-]digits[.digits]` text stored
/// at `buffer[1..][0..len]`, using `buffer[0]` for a carried leading digit.
/// Returns the new length; the text then starts at `buffer[1]`.
fn incrementLast(buffer: []u8, len: usize) usize {
    const text = buffer[1..][0..len];
    var index = len;
    while (index > 0) {
        index -= 1;
        switch (text[index]) {
            '.' => continue,
            '9' => text[index] = '0',
            '0'...'8' => {
                text[index] += 1;
                return len;
            },
            else => break, // sign
        }
    }
    // All digits carried: insert a leading 1 after an optional sign.
    const sign: usize = if (text[0] == '-') 1 else 0;
    std.mem.copyBackwards(u8, buffer[1 + sign + 1 ..][0 .. len - sign], text[sign..len]);
    buffer[1 + sign] = '1';
    return len + 1;
}

pub fn digitsInt(value: i64, options: Options) Error!Digits {
    try checkOptions(options);
    var out: Digits = .{};
    const written = if (options.style == .percent)
        std.fmt.bufPrint(&out.buffer, "{d}00", .{value}) catch unreachable
    else
        std.fmt.bufPrint(&out.buffer, "{d}", .{value}) catch unreachable;
    out.len = written.len;
    if (value == 0) out.len = 1;
    if (options.min_fraction > 0) {
        out.buffer[out.len] = '.';
        @memset(out.buffer[out.len + 1 ..][0..options.min_fraction], '0');
        out.len += 1 + options.min_fraction;
    }
    return out;
}

fn allZero(text: []const u8) bool {
    for (text) |c| if (c != '0' and c != '.') return false;
    return true;
}

fn trimFraction(text: []const u8, min_fraction: u8) usize {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return text.len;
    var end = text.len;
    while (end > dot + 1 + min_fraction and text[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    return end;
}

/// Writes prepared digits with the locale's grouping, separators, digit
/// set and style affixes.
pub fn writeDigits(writer: *std.Io.Writer, symbols: *const Symbols, digits: *const Digits, options: Options) Error!void {
    const negative = digits.negative();
    const body = if (negative) digits.text()[1..] else digits.text();
    if (options.style == .currency and options.currency.len > 0 and symbols.currency_prefix) {
        if (negative) try writer.writeAll(symbols.minus);
        try writer.writeAll(options.currency);
        try writer.writeAll(symbols.currency_space);
    } else if (negative) try writer.writeAll(symbols.minus);
    if (options.style == .percent and symbols.percent_prefix) {
        try writer.writeAll(symbols.percent);
        try writer.writeAll(symbols.percent_space);
    }
    if (digits.kind != .finite) {
        try writer.writeAll(if (digits.kind == .nan) symbols.nan else symbols.infinity);
    } else {
        const dot = std.mem.indexOfScalar(u8, body, '.');
        const int_part = body[0 .. dot orelse body.len];
        try writeGrouped(writer, symbols, int_part, options.grouping);
        if (dot) |d| {
            try writer.writeAll(symbols.decimal);
            for (body[d + 1 ..]) |c| try writeDigit(writer, symbols, c);
        }
    }
    if (options.style == .percent and !symbols.percent_prefix) {
        try writer.writeAll(symbols.percent_space);
        try writer.writeAll(symbols.percent);
    }
    if (options.style == .currency and options.currency.len > 0 and !symbols.currency_prefix) {
        try writer.writeAll(symbols.currency_space);
        try writer.writeAll(options.currency);
    }
}

fn writeDigit(writer: *std.Io.Writer, symbols: *const Symbols, c: u8) Error!void {
    if (symbols.zero == '0') return writer.writeByte(c);
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(symbols.zero + (c - '0'), &encoded) catch unreachable;
    try writer.writeAll(encoded[0..len]);
}

fn writeGrouped(writer: *std.Io.Writer, symbols: *const Symbols, int_part: []const u8, grouping: bool) Error!void {
    const primary = symbols.primary_group;
    if (!grouping or int_part.len < @as(usize, primary) + symbols.min_grouping) {
        for (int_part) |c| try writeDigit(writer, symbols, c);
        return;
    }
    // Positions counted from the right: a separator follows the first
    // group of `primary` digits, then every `secondary` digits.
    const head_len = int_part.len - primary;
    const secondary = symbols.secondary_group;
    var first = head_len % secondary;
    if (first == 0) first = secondary;
    var index: usize = 0;
    while (index < head_len) {
        const take = if (index == 0) first else secondary;
        for (int_part[index..][0..take]) |c| try writeDigit(writer, symbols, c);
        try writer.writeAll(symbols.group);
        index += take;
    }
    for (int_part[head_len..]) |c| try writeDigit(writer, symbols, c);
}

pub fn formatFloat(writer: *std.Io.Writer, locale: *const Locale, value: f64, options: Options) Error!void {
    const digits = try digitsFloat(value, options);
    try writeDigits(writer, symbolsFor(locale), &digits, options);
}

pub fn formatInt(writer: *std.Io.Writer, locale: *const Locale, value: i64, options: Options) Error!void {
    const digits = try digitsInt(value, options);
    try writeDigits(writer, symbolsFor(locale), &digits, options);
}

pub const ParseError = error{InvalidNumber};

/// Reads a decimal number as a person types it in `locale`: an optional
/// sign (the locale's minus, ASCII `-` or `+`, or U+2212), digits in ASCII
/// or the locale's digit set, group separators only before the decimal
/// separator, and the locale's decimal separator. A `.` is a decimal
/// separator too where the locale does not group with it. Surrounding
/// spaces are ignored; anything else, or no digit, is `InvalidNumber`.
pub fn parseFloat(locale: *const Locale, text: []const u8) ParseError!f64 {
    const symbols = symbolsFor(locale);
    var ascii: [max_parse_length]u8 = undefined;
    var len: usize = 0;
    var rest = trimSpaces(text);
    var digits: usize = 0;
    var seen_decimal = false;
    var signed = false;
    while (rest.len > 0) {
        if (!signed and len == 0 and digits == 0) {
            if (skipMinus(symbols, rest)) |after| {
                ascii[0] = '-';
                len = 1;
                rest = after;
                signed = true;
                continue;
            }
            if (rest[0] == '+') {
                rest = rest[1..];
                signed = true;
                continue;
            }
        }
        if (len == ascii.len) return error.InvalidNumber;
        if (std.mem.startsWith(u8, rest, symbols.decimal) or (rest[0] == '.' and !std.mem.eql(u8, symbols.group, "."))) {
            if (seen_decimal) return error.InvalidNumber;
            seen_decimal = true;
            ascii[len] = '.';
            len += 1;
            rest = rest[if (std.mem.startsWith(u8, rest, symbols.decimal)) symbols.decimal.len else 1..];
            continue;
        }
        if (!seen_decimal and digits > 0) if (skipGroup(symbols, rest)) |after| {
            rest = after;
            continue;
        };
        const length = std.unicode.utf8ByteSequenceLength(rest[0]) catch return error.InvalidNumber;
        if (length > rest.len) return error.InvalidNumber;
        const codepoint = std.unicode.utf8Decode(rest[0..length]) catch return error.InvalidNumber;
        const digit: u8 = if (codepoint >= '0' and codepoint <= '9')
            @intCast(codepoint - '0')
        else if (codepoint >= symbols.zero and codepoint <= symbols.zero + 9)
            @intCast(codepoint - symbols.zero)
        else
            return error.InvalidNumber;
        ascii[len] = '0' + digit;
        len += 1;
        digits += 1;
        rest = rest[length..];
    }
    if (digits == 0) return error.InvalidNumber;
    return std.fmt.parseFloat(f64, ascii[0..len]) catch error.InvalidNumber;
}
/// Longest number `parseFloat` reads, in ASCII digits and signs.
pub const max_parse_length = 64;

fn trimSpaces(text: []const u8) []const u8 {
    var rest = text;
    while (true) {
        const before = rest.len;
        for ([_][]const u8{ " ", "\t", "\u{00A0}", "\u{202F}" }) |space| {
            while (std.mem.startsWith(u8, rest, space)) rest = rest[space.len..];
            while (std.mem.endsWith(u8, rest, space)) rest = rest[0 .. rest.len - space.len];
        }
        if (rest.len == before) return rest;
    }
}
fn skipMinus(symbols: *const Symbols, text: []const u8) ?[]const u8 {
    var rest = text;
    // Direction marks around a minus are invisible to the person typing.
    for ([_][]const u8{ "\u{200E}", "\u{200F}", "\u{061C}" }) |mark| {
        if (std.mem.startsWith(u8, rest, mark)) rest = rest[mark.len..];
    }
    for ([_][]const u8{ symbols.minus, "-", "\u{2212}" }) |minus| {
        if (std.mem.startsWith(u8, rest, minus)) return rest[minus.len..];
    }
    // A locale minus may itself start with a direction mark.
    if (std.mem.startsWith(u8, text, symbols.minus)) return text[symbols.minus.len..];
    return null;
}
fn skipGroup(symbols: *const Symbols, text: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, text, symbols.group)) return text[symbols.group.len..];
    // Locales grouping with a space accept any of the spaces people type.
    const spaced = std.mem.eql(u8, symbols.group, "\u{00A0}") or std.mem.eql(u8, symbols.group, "\u{202F}");
    if (spaced) for ([_][]const u8{ " ", "\u{00A0}", "\u{202F}" }) |space| {
        if (std.mem.startsWith(u8, text, space)) return text[space.len..];
    };
    return null;
}

test "parsing numbers as typed in a locale" {
    const cases = .{
        .{ "en", "1,234.5", 1234.5 },
        .{ "en", " -42 ", -42.0 },
        .{ "en", "+3", 3.0 },
        .{ "en", ".5", 0.5 },
        .{ "de", "1.234,5", 1234.5 },
        .{ "de", "-0,25", -0.25 },
        .{ "fr", "1\u{202F}234,5", 1234.5 },
        .{ "fr", "1 234.5", 1234.5 },
        .{ "sv", "\u{2212}5", -5.0 },
        .{ "ar-EG", "١٬٢٣٤٫٥", 1234.5 },
        .{ "ar-EG", "12.5", 12.5 },
        .{ "he", "\u{200E}-7", -7.0 },
    };
    inline for (cases) |case| {
        const locale = try Locale.parse(case[0]);
        try std.testing.expectEqual(@as(f64, case[2]), try parseFloat(&locale, case[1]));
    }
    const en = try Locale.parse("en");
    for ([_][]const u8{ "", " ", "-", "1.2.3", "12a", "1,2.3,4", "--1", "1-" }) |bad| {
        try std.testing.expectError(error.InvalidNumber, parseFloat(&en, bad));
    }
    const de = try Locale.parse("de");
    try std.testing.expectError(error.InvalidNumber, parseFloat(&de, "1,2,3"));
}

fn expectFloat(tag: []const u8, value: f64, options: Options, expected: []const u8) !void {
    const locale = try Locale.parse(tag);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try formatFloat(&writer, &locale, value, options);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

fn expectInt(tag: []const u8, value: i64, options: Options, expected: []const u8) !void {
    const locale = try Locale.parse(tag);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try formatInt(&writer, &locale, value, options);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "decimal grouping and separators" {
    try expectInt("en-US", 1234567, .{}, "1,234,567");
    try expectInt("en", -42, .{}, "-42");
    try expectInt("en", 0, .{}, "0");
    try expectInt("en", std.math.minInt(i64), .{}, "-9,223,372,036,854,775,808");
    try expectInt("de-AT", 1234567, .{}, "1.234.567");
    try expectInt("fr", 1234567, .{}, "1\u{202F}234\u{202F}567");
    try expectInt("es", 1234, .{}, "1234");
    try expectInt("es", 12345, .{}, "12.345");
    try expectInt("es-MX", 1234, .{}, "1,234");
    try expectInt("en-IN", 123456789, .{}, "12,34,56,789");
    try expectInt("de-CH", 1234567, .{}, "1’234’567");
    try expectInt("en", 1234567, .{ .grouping = false }, "1234567");
    try expectInt("sv", -5, .{}, "\u{2212}5");
    try expectInt("ar-EG", 1234, .{}, "١٬٢٣٤");
    try expectInt("xx", 1234, .{}, "1,234");
    try expectInt("en", 3, .{ .min_fraction = 2 }, "3.00");
}

test "fraction rounding and trimming" {
    try expectFloat("en", 1234.5678, .{}, "1,234.568");
    try expectFloat("en", 1.5, .{ .min_fraction = 2 }, "1.50");
    try expectFloat("en", 2.0, .{}, "2");
    try expectFloat("en", 0.125, .{ .max_fraction = 2 }, "0.12");
    try expectFloat("en", 0.375, .{ .max_fraction = 2 }, "0.38");
    try expectFloat("en", 2.5, .integer, "2");
    try expectFloat("en", 3.5, .integer, "4");
    try expectFloat("en", -0.5, .integer, "0");
    try expectFloat("en", 9.5, .integer, "10");
    try expectFloat("en", -99.5, .integer, "-100");
    try expectFloat("en", 0.995, .{ .max_fraction = 2 }, "1");
    try expectFloat("en", 0.985, .{ .max_fraction = 2 }, "0.98");
    try expectFloat("en", 0.98500001, .{ .max_fraction = 2 }, "0.99");
    try expectFloat("en", 0.07, .percent, "7%");
    try expectFloat("en", 0.0005, .percent, "0%");
    try expectFloat("en", 1e-7, .{ .max_fraction = 15 }, "0.0000001");
    try expectFloat("en", 1.5e21, .integer, "1,500,000,000,000,000,000,000");
    try expectFloat("de", -0.0001, .{}, "0");
    try expectFloat("de", -1234.5, .{}, "-1.234,5");
    try expectFloat("ru", 1234.5, .{}, "1\u{00A0}234,5");
    try expectFloat("en", std.math.nan(f64), .{}, "NaN");
    try expectFloat("en", -std.math.inf(f64), .{}, "-∞");
    try std.testing.expectError(error.InvalidOptions, expectFloat("en", 1, .{ .max_fraction = 16 }, ""));
    try std.testing.expectError(error.InvalidOptions, expectFloat("en", 1, .{ .min_fraction = 3, .max_fraction = 2 }, ""));
}

test "percent and currency affixes" {
    try expectFloat("en", 0.256, .percent, "26%");
    try expectFloat("de", 0.256, .percent, "26\u{00A0}%");
    try expectFloat("fr", 0.5, .percent, "50\u{202F}%");
    try expectFloat("tr", 0.5, .percent, "%50");
    try expectInt("en", 3, .percent, "300%");
    try expectFloat("en", -1234.5, .{ .style = .currency, .currency = "$", .min_fraction = 2, .max_fraction = 2 }, "-$1,234.50");
    try expectFloat("de", 1234.5, .{ .style = .currency, .currency = "€", .min_fraction = 2, .max_fraction = 2 }, "1.234,50\u{00A0}€");
    const digits = try digitsFloat(1.5, .{ .min_fraction = 2 });
    try std.testing.expectEqualStrings("1.50", digits.text());
}
