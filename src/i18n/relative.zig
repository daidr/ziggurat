//! Relative times, as Intl.RelativeTimeFormat writes them: -3 minutes is
//! "3 minutes ago", 2 days "in 2 days", with CLDR's words, plural forms,
//! patterns and the locale's digits (cldr_relative.zig). The caller picks
//! the unit and computes its value: months and years are calendar units,
//! not fixed durations, and nothing here reads a clock or starts a timer.

const std = @import("std");
const Locale = @import("locale.zig").Locale;
const plural = @import("plural.zig");
const number = @import("number.zig");
const cldr = @import("cldr_relative.zig");

pub const Unit = enum { second, minute, hour, day, week, month, quarter, year };

/// How a relative time names its unit: `long` "3 minutes ago", `short`
/// "3 min. ago", `narrow` the shortest, "3m ago" in English.
pub const Style = enum { long, short, narrow };

/// The defaults write full names and always a number, as
/// Intl.RelativeTimeFormat does.
pub const Options = struct {
    style: Style = .long,
    /// Words such as "yesterday", "today", "tomorrow" and "now" where the
    /// locale has them, as Intl's numeric "auto"; other values still take
    /// a number. As ICU does, the value is rounded to hundredths before a
    /// word is looked for, so 1.001 days is "tomorrow".
    auto: bool = false,
};

pub const Error = error{ InvalidValue, WriteFailed };

fn dataFor(locale: *const Locale) *const cldr.Locale {
    const chain = locale.fallbackChain();
    for (chain.slice()) |*candidate| {
        for (&cldr.locales) |*entry| if (std.mem.eql(u8, entry.tag, candidate.tag())) return entry;
    }
    return &cldr.locales[0];
}

/// Writes `value` `unit`s relative to now in `locale`. The number is
/// rounded to at most three fraction digits, ties to even, and its plural
/// form is that of the number written; a negative zero is in the past.
/// NaN and the infinities are `error.InvalidValue`.
pub fn format(writer: *std.Io.Writer, locale: *const Locale, value: f64, unit: Unit, options: Options) Error!void {
    if (!std.math.isFinite(value)) return error.InvalidValue;
    const data = &dataFor(locale).styles[@backingInt(options.style)][@backingInt(unit)];
    if (options.auto and value > -2.1 and value < 2.1) {
        const hundredths: i32 = @intFromFloat(@round(value * 100));
        if (@rem(hundredths, 100) == 0) {
            if (data.words[@intCast(@divTrunc(hundredths, 100) + 2)]) |word| return writer.writeAll(word);
        }
    }
    const magnitude = @abs(value);
    const digits = number.digitsFloat(magnitude, .{}) catch return error.InvalidValue;
    const category = plural.cardinal(plural.rulesFor(locale), plural.Operands.parse(digits.text()) catch return error.InvalidValue);
    const patterns = if (std.math.signbit(value)) &data.past else &data.future;
    const pattern = patterns[@backingInt(category)] orelse patterns[@backingInt(plural.Category.other)] orelse for (patterns) |found| {
        if (found) |text| break text;
    } else return error.InvalidValue;
    for (pattern, 0..) |byte, index| {
        if (byte != 1) continue;
        try writer.writeAll(pattern[0..index]);
        number.formatFloat(writer, locale, magnitude, .{}) catch |err| return switch (err) {
            error.WriteFailed => error.WriteFailed,
            error.InvalidOptions => unreachable,
        };
        return writer.writeAll(pattern[index + 1 ..]);
    }
    try writer.writeAll(pattern);
}

fn expect(tag: []const u8, value: f64, unit: Unit, options: Options, want: []const u8) !void {
    const locale = try Locale.parse(tag);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try format(&writer, &locale, value, unit, options);
    try std.testing.expectEqualStrings(want, writer.buffered());
}

test "relative times take CLDR's words, plural forms and digits" {
    try expect("en", -3, .minute, .{}, "3 minutes ago");
    try expect("en", 2, .day, .{}, "in 2 days");
    try expect("en", -1, .day, .{ .auto = true }, "yesterday");
    try expect("en", 1.001, .day, .{ .auto = true }, "tomorrow");
    try expect("en", 0, .second, .{ .auto = true }, "now");
    try expect("en", -@as(f64, 0), .second, .{}, "0 seconds ago");
    try expect("en", 3, .day, .{ .auto = true }, "in 3 days");
    try expect("en", -3, .minute, .{ .style = .short }, "3 min. ago");
    try expect("de", 1234.5, .hour, .{}, "in 1.234,5 Stunden");
    try expect("ru", -5, .year, .{}, "5 лет назад");
    try expect("ru", -1, .year, .{}, "1 год назад");
    try std.testing.expectError(error.InvalidValue, expect("en", std.math.nan(f64), .day, .{}, ""));
}

test "relative times match the engine's CLDR (testdata/relative.json)" {
    const parsed = try std.json.parseFromSlice([]const std.json.Value, std.testing.allocator, @embedFile("testdata/relative.json"), .{});
    defer parsed.deinit();
    // Locales whose plain numbers differ from the engine's are left out.
    var skipped: [64][]const u8 = undefined;
    var skipped_len: usize = 0;
    for (parsed.value) |row| {
        const items = row.array.items;
        if (!std.mem.eql(u8, items[1].string, "decimal")) continue;
        const locale = try Locale.parse(items[0].string);
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try number.formatFloat(&writer, &locale, 1234.5, .{});
        if (!std.mem.eql(u8, writer.buffered(), items[6].string)) {
            skipped[skipped_len] = items[0].string;
            skipped_len += 1;
        }
    }
    var failures: usize = 0;
    var checked: usize = 0;
    rows: for (parsed.value) |row| {
        const items = row.array.items;
        if (std.mem.eql(u8, items[1].string, "decimal")) continue;
        for (skipped[0..skipped_len]) |tag| if (std.mem.eql(u8, tag, items[0].string)) continue :rows;
        checked += 1;
        const locale = try Locale.parse(items[0].string);
        var value: f64 = switch (items[4]) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => unreachable,
        };
        if (items[5].bool) value = -value;
        const options: Options = .{ .style = std.meta.stringToEnum(Style, items[1].string).?, .auto = std.mem.eql(u8, items[2].string, "auto") };
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try format(&writer, &locale, value, std.meta.stringToEnum(Unit, items[3].string).?, options);
        if (!std.mem.eql(u8, writer.buffered(), items[6].string)) {
            failures += 1;
            if (failures <= 100) std.debug.print("{s} {s} {s} {s} {d}: got \"{s}\", want \"{s}\"\n", .{ items[0].string, items[1].string, items[2].string, items[3].string, value, writer.buffered(), items[6].string });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expect(checked > parsed.value.len / 2);
}
