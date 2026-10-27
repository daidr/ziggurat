const std = @import("std");
const zio = @import("ziggurat_io");
const Locale = @import("locale.zig").Locale;
const plural = @import("plural.zig");
const number = @import("number.zig");
const date = @import("date.zig");
const pseudo = @import("pseudo.zig");

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    instant: date.Instant,
};

pub const Arg = struct { name: []const u8, value: Value };

/// Builds an argument array from a struct literal at the call site:
/// `args(.{ .count = 3, .name = "Ana" })`. Integers, floats, strings,
/// `date.Instant` and `Value` fields are accepted.
pub fn args(values: anytype) [zio.fields(@TypeOf(values)).len]Arg {
    const fields = zio.fields(@TypeOf(values));
    var out: [fields.len]Arg = undefined;
    inline for (fields, 0..) |field, i| out[i] = .{ .name = field.name, .value = toValue(@field(values, field.name)) };
    return out;
}

fn toValue(value: anytype) Value {
    const T = @TypeOf(value);
    if (T == Value) return value;
    if (T == date.Instant) return .{ .instant = value };
    switch (@typeInfo(T)) {
        .int, .comptime_int => return .{ .int = @intCast(value) },
        .float, .comptime_float => return .{ .float = @floatCast(value) },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return .{ .string = value };
            if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return .{ .string = value };
        },
        else => {},
    }
    @compileError("unsupported message argument type " ++ @typeName(T));
}

pub const Error = error{ InvalidMessage, NestingTooDeep, MissingArgument, ArgumentType, OutOfRange, WriteFailed };

/// Nesting limit for arguments inside plural/select branches.
pub const max_depth = 8;
pub const max_pattern_len = 16 * 1024;

pub const Options = struct {
    pseudo: pseudo.Mode = .none,
    /// In right-to-left locales, wrap string arguments in first-strong
    /// isolate marks so their own direction cannot reorder the message.
    isolate_arguments: bool = true,
};

/// Checks message syntax: `{name}`, `{n, number[, integer|percent]}`,
/// `{t, date|time[, short|medium|long|full]}`, `{n, plural|selectordinal,
/// [offset:N] =N {...} one {...} other {...}}`, `{s, select, key {...}
/// other {...}}`, `#` inside plural branches and apostrophe quoting.
pub fn validate(pattern: []const u8) Error!void {
    if (pattern.len > max_pattern_len) return error.InvalidMessage;
    var walker: Walker = .{ .pattern = pattern, .context = null };
    try walker.message(0, null, false, false);
}

/// Compile-time form of `validate` for messages known while building.
pub fn comptimeValidate(comptime pattern: []const u8) void {
    comptime {
        @setEvalBranchQuota(200 * pattern.len + 10_000);
        validate(pattern) catch |err| @compileError("invalid message (" ++ @errorName(err) ++ "): " ++ pattern);
    }
}

/// How a message uses an argument.
pub const Kind = enum { simple, number, date, time, plural, selectordinal, select };

/// Told the arguments of a message and the cases of its plural,
/// selectordinal and select arguments, in the order they appear.
pub const Visitor = struct {
    context: *anyopaque,
    argument: *const fn (context: *anyopaque, name: []const u8, kind: Kind) void,
    /// A case of argument `name`: `=0`, a plural category or a select key.
    case: *const fn (context: *anyopaque, name: []const u8, key: []const u8) void,
};

/// Checks the syntax as `validate` does, telling `visitor` what the
/// message holds. Tools read the parameters of messages with it.
pub fn visit(pattern: []const u8, visitor: Visitor) Error!void {
    if (pattern.len > max_pattern_len) return error.InvalidMessage;
    var walker: Walker = .{ .pattern = pattern, .context = null, .visitor = &visitor };
    try walker.message(0, null, false, false);
}

/// Formats a validated or unvalidated pattern without allocation. Syntax
/// errors are reported before any output is written.
pub fn format(writer: *std.Io.Writer, locale: *const Locale, pattern: []const u8, arguments: []const Arg, options: Options) Error!void {
    try validate(pattern);
    const context: Context = .{
        .locale = locale,
        .rules = plural.rulesFor(locale),
        .symbols = number.symbolsFor(locale),
        .arguments = arguments,
        .writer = writer,
        .mode = options.pseudo,
        .isolate = options.isolate_arguments and locale.direction() == .rtl,
    };
    var walker: Walker = .{ .pattern = pattern, .context = &context };
    try pseudo.begin(writer, options.pseudo);
    try walker.message(0, null, true, false);
    try pseudo.end(writer, options.pseudo, walker.literal_code_points);
}

const Context = struct {
    locale: *const Locale,
    rules: plural.Rules,
    symbols: *const number.Symbols,
    arguments: []const Arg,
    writer: *std.Io.Writer,
    mode: pseudo.Mode,
    isolate: bool,

    fn find(self: *const Context, name: []const u8) Error!Value {
        for (self.arguments) |arg| if (std.mem.eql(u8, arg.name, name)) return arg.value;
        return error.MissingArgument;
    }
};

/// The number shown by `#`: the plural value minus its offset.
const PluralValue = struct { value: Value, offset: i64 };

const Walker = struct {
    pattern: []const u8,
    context: ?*const Context,
    visitor: ?*const Visitor = null,
    position: usize = 0,
    literal_code_points: usize = 0,

    fn peek(self: *const Walker) ?u8 {
        return if (self.position < self.pattern.len) self.pattern[self.position] else null;
    }

    fn skipSpace(self: *Walker) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return;
            self.position += 1;
        }
    }

    fn expect(self: *Walker, c: u8) Error!void {
        if (self.peek() != c) return error.InvalidMessage;
        self.position += 1;
    }

    fn identifier(self: *Walker) Error![]const u8 {
        const start = self.position;
        while (self.peek()) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
            self.position += 1;
        }
        if (self.position == start) return error.InvalidMessage;
        return self.pattern[start..self.position];
    }

    fn text(self: *Walker, emit: bool, bytes: []const u8) Error!void {
        if (!emit) return;
        const context = self.context.?;
        try pseudo.writeText(context.writer, context.mode, bytes);
        self.literal_code_points += std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
    }

    /// Walks literal text and arguments up to the end of the pattern or, when
    /// `nested`, up to (not past) the closing brace of a branch.
    fn message(self: *Walker, depth: usize, number_sign: ?PluralValue, emit: bool, nested: bool) Error!void {
        while (self.peek()) |c| switch (c) {
            '}' => return if (nested) {} else error.InvalidMessage,
            '{' => {
                self.position += 1;
                try self.argument(depth + 1, emit);
            },
            '#' => {
                self.position += 1;
                if (number_sign) |sign| {
                    if (emit) try self.writeNumberSign(sign);
                } else try self.text(emit, "#");
            },
            '\'' => try self.apostrophe(emit, number_sign != null),
            else => {
                const start = self.position;
                while (self.peek()) |d| {
                    if (d == '{' or d == '}' or d == '\'' or (d == '#' and number_sign != null)) break;
                    self.position += 1;
                }
                try self.text(emit, self.pattern[start..self.position]);
            },
        };
        if (nested) return error.InvalidMessage;
    }

    /// `''` is an apostrophe. An apostrophe before a syntax character starts
    /// quoted text up to the next lone apostrophe (or the end). Any other
    /// apostrophe is literal.
    fn apostrophe(self: *Walker, emit: bool, in_plural: bool) Error!void {
        const next = if (self.position + 1 < self.pattern.len) self.pattern[self.position + 1] else 0;
        if (next == '\'') {
            self.position += 2;
            return self.text(emit, "'");
        }
        if (!(next == '{' or next == '}' or next == '|' or (next == '#' and in_plural))) {
            self.position += 1;
            return self.text(emit, "'");
        }
        self.position += 1;
        while (self.peek()) |c| {
            if (c == '\'') {
                if (self.position + 1 < self.pattern.len and self.pattern[self.position + 1] == '\'') {
                    self.position += 2;
                    try self.text(emit, "'");
                    continue;
                }
                self.position += 1;
                return;
            }
            const start = self.position;
            while (self.peek()) |d| {
                if (d == '\'') break;
                self.position += 1;
            }
            try self.text(emit, self.pattern[start..self.position]);
        }
    }

    fn argument(self: *Walker, depth: usize, emit: bool) Error!void {
        if (depth > max_depth) return error.NestingTooDeep;
        self.skipSpace();
        const name = try self.identifier();
        self.skipSpace();
        if (self.peek() == '}') {
            self.position += 1;
            self.tell(name, .simple);
            if (emit) try self.writeSimple(name);
            return;
        }
        try self.expect(',');
        self.skipSpace();
        const kind = try self.identifier();
        self.skipSpace();
        if (std.meta.stringToEnum(Kind, kind)) |known| if (known != .simple) self.tell(name, known);
        if (std.mem.eql(u8, kind, "number")) {
            var options: number.Options = .{};
            if (try self.styleName()) |style| {
                if (std.mem.eql(u8, style, "integer")) options = .integer else if (std.mem.eql(u8, style, "percent")) options = .percent else return error.InvalidMessage;
            }
            if (emit) try self.writeNumber(name, options);
        } else if (std.mem.eql(u8, kind, "date") or std.mem.eql(u8, kind, "time")) {
            var date_style: date.Style = .medium;
            if (try self.styleName()) |style| date_style = std.meta.stringToEnum(date.Style, style) orelse return error.InvalidMessage;
            if (emit) try self.writeDate(name, kind[0] == 'd', date_style);
        } else if (std.mem.eql(u8, kind, "plural") or std.mem.eql(u8, kind, "selectordinal")) {
            try self.pluralArgument(name, depth, emit, kind[0] == 's');
        } else if (std.mem.eql(u8, kind, "select")) {
            try self.selectArgument(name, depth, emit);
        } else return error.InvalidMessage;
    }

    /// Optional `, style` then the closing brace.
    fn styleName(self: *Walker) Error!?[]const u8 {
        if (self.peek() == '}') {
            self.position += 1;
            return null;
        }
        try self.expect(',');
        self.skipSpace();
        const value = try self.identifier();
        self.skipSpace();
        try self.expect('}');
        return value;
    }

    fn pluralArgument(self: *Walker, name: []const u8, depth: usize, emit: bool, ordinal: bool) Error!void {
        try self.expect(',');
        self.skipSpace();
        var offset: i64 = 0;
        if (std.mem.startsWith(u8, self.pattern[self.position..], "offset:")) {
            self.position += "offset:".len;
            self.skipSpace();
            offset = try self.integer();
            self.skipSpace();
        }
        const value: ?Value = if (emit) try self.context.?.find(name) else null;
        if (value) |v| if (v != .int and v != .float) return error.ArgumentType;
        const selected = if (value) |v| try self.pluralCategory(v, offset, ordinal) else plural.Category.other;
        const sign: PluralValue = .{ .value = value orelse .{ .int = 0 }, .offset = offset };
        var seen = std.EnumSet(plural.Category).empty;
        var exact_start: ?usize = null;
        var keyword_start: ?usize = null;
        var other_start: ?usize = null;
        while (self.peek() != '}') {
            if (self.peek() == null) return error.InvalidMessage;
            var exact = false;
            var category: plural.Category = .other;
            var exact_value: i64 = 0;
            const key_start = self.position;
            if (self.peek() == '=') {
                self.position += 1;
                exact = true;
                exact_value = try self.integer();
            } else {
                category = plural.Category.parse(try self.identifier()) orelse return error.InvalidMessage;
                if (seen.contains(category)) return error.InvalidMessage;
                seen.insert(category);
            }
            self.tellCase(name, self.pattern[key_start..self.position]);
            self.skipSpace();
            try self.expect('{');
            const start = self.position;
            try self.message(depth, sign, false, true);
            try self.expect('}');
            self.skipSpace();
            if (value) |v| {
                if (exact) {
                    if (exact_start == null and exactMatch(v, exact_value)) exact_start = start;
                } else if (category == .other) {
                    other_start = start;
                } else if (category == selected and keyword_start == null) keyword_start = start;
            }
        }
        if (!seen.contains(.other)) return error.InvalidMessage;
        const end = self.position + 1;
        if (emit) {
            self.position = exact_start orelse keyword_start orelse other_start.?;
            try self.message(depth, sign, true, true);
        }
        self.position = end;
    }

    fn selectArgument(self: *Walker, name: []const u8, depth: usize, emit: bool) Error!void {
        try self.expect(',');
        self.skipSpace();
        const value: ?Value = if (emit) try self.context.?.find(name) else null;
        if (value) |v| if (v != .string) return error.ArgumentType;
        var match_start: ?usize = null;
        var other_start: ?usize = null;
        while (self.peek() != '}') {
            if (self.peek() == null) return error.InvalidMessage;
            const key = try self.identifier();
            self.tellCase(name, key);
            self.skipSpace();
            try self.expect('{');
            const start = self.position;
            try self.message(depth, null, false, true);
            try self.expect('}');
            self.skipSpace();
            if (std.mem.eql(u8, key, "other")) {
                if (other_start != null) return error.InvalidMessage;
                other_start = start;
            } else if (value) |v| {
                if (match_start == null and std.mem.eql(u8, key, v.string)) match_start = start;
            }
        }
        if (other_start == null) return error.InvalidMessage;
        const end = self.position + 1;
        if (emit) {
            self.position = match_start orelse other_start.?;
            try self.message(depth, null, true, true);
        }
        self.position = end;
    }

    fn tell(self: *const Walker, name: []const u8, kind: Kind) void {
        if (self.visitor) |v| v.argument(v.context, name, kind);
    }

    fn tellCase(self: *const Walker, name: []const u8, key: []const u8) void {
        if (self.visitor) |v| v.case(v.context, name, key);
    }

    fn integer(self: *Walker) Error!i64 {
        const start = self.position;
        if (self.peek() == '-') self.position += 1;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            self.position += 1;
        }
        return std.fmt.parseInt(i64, self.pattern[start..self.position], 10) catch error.InvalidMessage;
    }

    fn pluralCategory(self: *Walker, value: Value, offset: i64, ordinal: bool) Error!plural.Category {
        const context = self.context.?;
        const digits = try shiftedDigits(value, offset);
        const operands = plural.Operands.parse(digits.text()) catch return .other;
        return if (ordinal) plural.ordinal(context.locale, operands) else plural.cardinal(context.rules, operands);
    }

    fn writeNumberSign(self: *Walker, sign: PluralValue) Error!void {
        const context = self.context.?;
        const digits = try shiftedDigits(sign.value, sign.offset);
        number.writeDigits(context.writer, context.symbols, &digits, .{}) catch |err| return mapNumberError(err);
    }

    fn writeSimple(self: *Walker, name: []const u8) Error!void {
        const context = self.context.?;
        switch (try context.find(name)) {
            .int, .float => try self.writeNumber(name, .{}),
            .string => |s| {
                if (context.isolate) try context.writer.writeAll("\u{2068}");
                try context.writer.writeAll(s);
                if (context.isolate) try context.writer.writeAll("\u{2069}");
            },
            .instant => |instant| date.formatDateTime(context.writer, context.locale, instant, .short, .short) catch |err| return mapDateError(err),
        }
    }

    fn writeNumber(self: *Walker, name: []const u8, options: number.Options) Error!void {
        const context = self.context.?;
        const digits = switch (try context.find(name)) {
            .int => |i| number.digitsInt(i, options),
            .float => |f| number.digitsFloat(f, options),
            else => return error.ArgumentType,
        } catch |err| return mapNumberError(err);
        number.writeDigits(context.writer, context.symbols, &digits, options) catch |err| return mapNumberError(err);
    }

    fn writeDate(self: *Walker, name: []const u8, is_date: bool, style_value: date.Style) Error!void {
        const context = self.context.?;
        const instant = switch (try context.find(name)) {
            .instant => |instant| instant,
            else => return error.ArgumentType,
        };
        const result = if (is_date) date.formatDate(context.writer, context.locale, instant, style_value) else date.formatTime(context.writer, context.locale, instant, style_value);
        result catch |err| return mapDateError(err);
    }
};

fn exactMatch(value: Value, expected: i64) bool {
    return switch (value) {
        .int => |i| i == expected,
        .float => |f| f == @as(f64, @floatFromInt(expected)),
        else => false,
    };
}

fn shiftedDigits(value: Value, offset: i64) Error!number.Digits {
    return switch (value) {
        .int => |i| number.digitsInt(std.math.sub(i64, i, offset) catch return error.OutOfRange, .{}),
        .float => |f| number.digitsFloat(f - @as(f64, @floatFromInt(offset)), .{}),
        else => error.ArgumentType,
    } catch |err| mapNumberError(err);
}

fn mapNumberError(err: anyerror) Error {
    return switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.ArgumentType => error.ArgumentType,
        error.OutOfRange => error.OutOfRange,
        else => error.InvalidMessage,
    };
}

fn mapDateError(err: date.Error) Error {
    return switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.OutOfRange => error.OutOfRange,
        error.InvalidPattern => error.InvalidMessage,
    };
}

fn expectFormat(tag: []const u8, pattern: []const u8, arguments: []const Arg, expected: []const u8) !void {
    const locale = try Locale.parse(tag);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try format(&writer, &locale, pattern, arguments, .{});
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "simple arguments and quoting" {
    try expectFormat("en", "Hello, {name}!", &args(.{ .name = "Ana" }), "Hello, Ana!");
    try expectFormat("en", "{a} and {b}", &args(.{ .a = 1234, .b = 0.5 }), "1,234 and 0.5");
    try expectFormat("en", "It''s '{literal}' and '#' #", &.{}, "It's {literal} and '#' #");
    try expectFormat("en", "don't", &.{}, "don't");
    try expectFormat("de", "{n, number} / {n, number, integer} / {p, number, percent}", &args(.{ .n = 1234.56, .p = 0.25 }), "1.234,56 / 1.235 / 25\u{00A0}%");
}

test "plural selection, offsets and number sign" {
    const files = "{count, plural, =0 {No files} one {# file} other {# files}}";
    try expectFormat("en", files, &args(.{ .count = 0 }), "No files");
    try expectFormat("en", files, &args(.{ .count = 1 }), "1 file");
    try expectFormat("en", files, &args(.{ .count = 1200 }), "1,200 files");
    try expectFormat("en", files, &args(.{ .count = 1.5 }), "1.5 files");
    const ru = "{n, plural, one {# файл} few {# файла} many {# файлов} other {# файла}}";
    try expectFormat("ru", ru, &args(.{ .n = 21 }), "21 файл");
    try expectFormat("ru", ru, &args(.{ .n = 3 }), "3 файла");
    try expectFormat("ru", ru, &args(.{ .n = 11 }), "11 файлов");
    try expectFormat("ru", ru, &args(.{ .n = 2.5 }), "2,5 файла");
    const guests = "{n, plural, offset:1 =0 {nobody} =1 {{host}} one {{host} and # other} other {{host} and # others}}";
    try expectFormat("en", guests, &args(.{ .n = 1, .host = "Kim" }), "Kim");
    try expectFormat("en", guests, &args(.{ .n = 2, .host = "Kim" }), "Kim and 1 other");
    try expectFormat("en", guests, &args(.{ .n = 5, .host = "Kim" }), "Kim and 4 others");
    try expectFormat("en", "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", &args(.{ .n = 23 }), "23rd");
    try expectFormat("en", "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", &args(.{ .n = 11 }), "11th");
    try expectFormat("ar", "{n, plural, zero {صفر} one {واحد} two {اثنان} few {# قليل} many {# كثير} other {#}}", &args(.{ .n = 3 }), "٣ قليل");
    try expectFormat("en", "{n, plural, other {'#' is #}}", &args(.{ .n = 2 }), "# is 2");
}

test "select, nesting and dates" {
    const pattern = "{gender, select, female {{n, plural, one {She has one} other {She has #}}} male {He has {n}} other {They have {n}}}";
    try expectFormat("en", pattern, &args(.{ .gender = "female", .n = 1 }), "She has one");
    try expectFormat("en", pattern, &args(.{ .gender = "male", .n = 3 }), "He has 3");
    try expectFormat("en", pattern, &args(.{ .gender = "x", .n = 3 }), "They have 3");
    const when: date.Instant = .{ .unix_seconds = 1709647629, .utc_offset_minutes = 60 };
    try expectFormat("en", "Saved {d, date, long} at {d, time, short}", &args(.{ .d = when }), "Saved March 5, 2024 at 3:07\u{202F}PM");
    try expectFormat("de", "{d, date}", &args(.{ .d = when }), "05.03.2024");
    try expectFormat("fr", "{d}", &args(.{ .d = when }), "05/03/2024 15:07");
}

test "errors leave no partial syntax output" {
    const en = try Locale.parse("en");
    var buffer: [64]u8 = undefined;
    for ([_][]const u8{ "{", "}", "{name", "{1x, foo}", "{n, plural, one {x}}", "{n, plural, other {x} other {y}}", "{n, select, a {x}}", "{n, number, money}", "{n, date, tiny}", "{n, plural, other {x}", "{n, plural, =a {x} other {y}}", "{ }", "{n,}" }) |bad| {
        var writer: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectError(error.InvalidMessage, format(&writer, &en, bad, &args(.{ .n = 1 }), .{}));
        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
    try std.testing.expectError(error.NestingTooDeep, validate("{a,select,other{{a,select,other{{a,select,other{{a,select,other{{a,select,other{{a,select,other{{a,select,other{{a,select,other{{a}}}}}}}}}}}}}}}}}}"));
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.MissingArgument, format(&writer, &en, "{x}", &.{}, .{}));
    try std.testing.expectError(error.ArgumentType, format(&writer, &en, "{x, number}", &args(.{ .x = "a" }), .{}));
    try std.testing.expectError(error.ArgumentType, format(&writer, &en, "{x, select, other {}}", &args(.{ .x = 1 }), .{}));
    try std.testing.expectError(error.ArgumentType, format(&writer, &en, "{x, date}", &args(.{ .x = 1 }), .{}));
    try std.testing.expectError(error.OutOfRange, format(&writer, &en, "{x, plural, offset:-1 other {#}}", &args(.{ .x = std.math.maxInt(i64) }), .{}));
    var tiny: [4]u8 = undefined;
    writer = .fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, format(&writer, &en, "too long", &.{}, .{}));
    comptimeValidate("{count, plural, one {# item} other {# items}}");
}

test "pseudolocalization and bidi isolation" {
    const xa = try Locale.parse("en-XA");
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try format(&writer, &xa, "Hi {name}, {n, plural, one {# new} other {# new}}", &args(.{ .name = "Bo", .n = 2 }), .{ .pseudo = .accented });
    try std.testing.expectEqualStrings("[Ĥî Bo, 2 ñéŵ ~~~~]", writer.buffered());
    const he = try Locale.parse("he");
    writer = .fixed(&buffer);
    try format(&writer, &he, "שלום {name}", &args(.{ .name = "Ana" }), .{});
    try std.testing.expectEqualStrings("שלום \u{2068}Ana\u{2069}", writer.buffered());
    writer = .fixed(&buffer);
    try format(&writer, &he, "שלום {name}", &args(.{ .name = "Ana" }), .{ .isolate_arguments = false });
    try std.testing.expectEqualStrings("שלום Ana", writer.buffered());
}

test "visit tells arguments and cases in order" {
    const Recorder = struct {
        buffer: [256]u8 = undefined,
        len: usize = 0,
        fn add(self: *@This(), text: []const u8) void {
            @memcpy(self.buffer[self.len..][0..text.len], text);
            self.len += text.len;
        }
        fn argument(context: *anyopaque, name: []const u8, kind: Kind) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.add(name);
            self.add(":");
            self.add(@tagName(kind));
            self.add(" ");
        }
        fn case(context: *anyopaque, name: []const u8, key: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.add(name);
            self.add("=");
            self.add(key);
            self.add(" ");
        }
    };
    var recorder: Recorder = .{};
    try visit("{who} has {n, plural, offset:1 =0 {none} one {{t, date} #} other {{g, select, a {x} other {y}}}} '{q}'", .{ .context = &recorder, .argument = Recorder.argument, .case = Recorder.case });
    try std.testing.expectEqualStrings("who:simple n:plural n==0 n=one t:date n=other g:select g=a g=other ", recorder.buffer[0..recorder.len]);
    try std.testing.expectError(error.InvalidMessage, visit("{n, plural, one {x}}", .{ .context = &recorder, .argument = Recorder.argument, .case = Recorder.case }));
}
