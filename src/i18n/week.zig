const std = @import("std");
const Locale = @import("locale.zig").Locale;
const date = @import("date.zig");

/// How a region counts weeks: the day a week starts on, 0 for Sunday, and
/// the fewest days of a year that its first week holds, so 4 makes weeks
/// in the ISO 8601 way.
pub const Week = struct {
    first_day: u3 = 1,
    min_days: u3 = 1,
};

// Regions whose weeks do not start on Monday, and regions whose first week
// of the year needs four days, after CLDR's week data.
const sunday_regions = [_][]const u8{ "AG", "AS", "BD", "BR", "BS", "BT", "BW", "BZ", "CA", "CN", "CO", "DM", "DO", "ET", "GT", "GU", "HK", "HN", "ID", "IL", "IN", "JM", "JP", "KE", "KH", "KR", "LA", "MH", "MM", "MO", "MT", "MX", "MZ", "NI", "NP", "PA", "PE", "PH", "PK", "PR", "PT", "PY", "SA", "SG", "SV", "TH", "TT", "TW", "UM", "US", "VE", "VI", "WS", "YE", "ZA", "ZW" };
const saturday_regions = [_][]const u8{ "AE", "AF", "BH", "DJ", "DZ", "EG", "IQ", "IR", "JO", "KW", "LY", "OM", "QA", "SD", "SY" };
const four_day_regions = [_][]const u8{ "AD", "AN", "AT", "AX", "BE", "BG", "CH", "CZ", "DE", "DK", "EE", "ES", "FI", "FJ", "FO", "FR", "GB", "GF", "GG", "GI", "GP", "GR", "HU", "IE", "IM", "IS", "IT", "JE", "LI", "LT", "LU", "MC", "MQ", "NL", "NO", "PL", "RE", "RU", "SE", "SJ", "SK", "SM", "VA" };

/// The region a language without one is most likely used in.
const likely_regions = [_]struct { []const u8, []const u8 }{
    .{ "en", "US" }, .{ "de", "DE" }, .{ "fr", "FR" }, .{ "es", "ES" }, .{ "it", "IT" }, .{ "pt", "BR" },
    .{ "nl", "NL" }, .{ "ru", "RU" }, .{ "uk", "UA" }, .{ "pl", "PL" }, .{ "cs", "CZ" }, .{ "sv", "SE" },
    .{ "nb", "NO" }, .{ "no", "NO" }, .{ "fi", "FI" }, .{ "da", "DK" }, .{ "tr", "TR" }, .{ "ja", "JP" },
    .{ "ko", "KR" }, .{ "he", "IL" }, .{ "ar", "EG" }, .{ "fa", "IR" }, .{ "hi", "IN" }, .{ "th", "TH" },
    .{ "vi", "VN" }, .{ "id", "ID" }, .{ "el", "GR" }, .{ "hu", "HU" }, .{ "ro", "RO" },
};

/// The region a locale's weeks follow: its own, or the one its language
/// is most likely used in. Chinese takes Taiwan's in the traditional script.
pub fn region(locale: *const Locale) ?[]const u8 {
    if (locale.region()) |value| return value;
    const language = locale.language();
    if (std.mem.eql(u8, language, "zh")) return if (std.mem.eql(u8, locale.effectiveScript(), "Hant")) "TW" else "CN";
    for (likely_regions) |entry| if (std.mem.eql(u8, entry[0], language)) return entry[1];
    return null;
}

/// The week conventions of a locale's region; Monday and one day without
/// a known region, as CLDR's world default.
pub fn weekFor(locale: *const Locale) Week {
    const code = region(locale) orelse return .{};
    var week: Week = .{};
    if (listed(&sunday_regions, code)) week.first_day = 0;
    if (listed(&saturday_regions, code)) week.first_day = 6;
    if (std.mem.eql(u8, code, "MV")) week.first_day = 5;
    if (listed(&four_day_regions, code)) week.min_days = 4;
    return week;
}

fn listed(list: []const []const u8, code: []const u8) bool {
    for (list) |entry| if (std.ascii.eqlIgnoreCase(entry, code)) return true;
    return false;
}

/// The week of the year of a date and the year that week belongs to: the
/// first week is the first that starts on `week.first_day` and holds at
/// least `week.min_days` days of the year, so a date early in January may
/// fall in the last week of the year before, and one late in December in
/// the first week of the next.
pub const YearWeek = struct { year: i32, week: u8 };
pub fn weekOfYear(year: i32, month: u4, day: u5, week: Week) YearWeek {
    const days = date.daysFromCivil(year, month, day);
    var owner = year;
    var start = firstWeek(owner, week);
    if (days < start) {
        owner -= 1;
        start = firstWeek(owner, week);
    } else {
        const next = firstWeek(owner + 1, week);
        if (days >= next) {
            owner += 1;
            start = next;
        }
    }
    return .{ .year = owner, .week = @intCast(@divFloor(days - start, 7) + 1) };
}

/// The day the first week of `year` starts on, in days since 1970-01-01.
fn firstWeek(year: i32, week: Week) i64 {
    const january = date.daysFromCivil(year, 1, 1);
    // 1970-01-01 was a Thursday.
    const weekday = @mod(january + 4, 7);
    const back = @mod(weekday - @as(i64, week.first_day), 7);
    const start = january - back;
    // A week starting before New Year counts when enough of it is January.
    return if (7 - back >= week.min_days) start else start + 7;
}

test "regions and their week conventions" {
    inline for (.{ .{ "en", 0, 1 }, .{ "en-GB", 1, 4 }, .{ "de-AT", 1, 4 }, .{ "zh", 0, 1 }, .{ "zh-TW", 0, 1 }, .{ "fr-CA", 0, 1 }, .{ "ar", 6, 1 }, .{ "ar-MA", 1, 1 }, .{ "sw", 1, 1 }, .{ "ja", 0, 1 } }) |case| {
        const locale = try Locale.parse(case[0]);
        const week = weekFor(&locale);
        try std.testing.expectEqual(@as(u3, case[1]), week.first_day);
        try std.testing.expectEqual(@as(u3, case[2]), week.min_days);
    }
}

test "week numbers by ISO and by first-day rules" {
    const iso: Week = .{ .first_day = 1, .min_days = 4 };
    try std.testing.expectEqual(YearWeek{ .year = 2020, .week = 53 }, weekOfYear(2021, 1, 3, iso));
    try std.testing.expectEqual(YearWeek{ .year = 2021, .week = 1 }, weekOfYear(2021, 1, 4, iso));
    try std.testing.expectEqual(YearWeek{ .year = 2025, .week = 1 }, weekOfYear(2024, 12, 30, iso));
    try std.testing.expectEqual(YearWeek{ .year = 2024, .week = 10 }, weekOfYear(2024, 3, 5, iso));
    const us: Week = .{ .first_day = 0, .min_days = 1 };
    try std.testing.expectEqual(YearWeek{ .year = 2021, .week = 1 }, weekOfYear(2021, 1, 1, us));
    try std.testing.expectEqual(YearWeek{ .year = 2021, .week = 2 }, weekOfYear(2021, 1, 3, us));
    try std.testing.expectEqual(YearWeek{ .year = 2025, .week = 1 }, weekOfYear(2024, 12, 29, us));
    try std.testing.expectEqual(YearWeek{ .year = 2024, .week = 10 }, weekOfYear(2024, 3, 5, us));
}
