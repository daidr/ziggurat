const std = @import("std");
const Locale = @import("locale.zig").Locale;

/// A point in time and the caller-chosen UTC offset to display it in. The
/// module has no time zone database; the host supplies the offset in effect.
pub const Instant = struct {
    unix_seconds: i64,
    utc_offset_minutes: i16 = 0,
};

/// Proleptic Gregorian fields for years 1 through 9999.
pub const Civil = struct {
    year: u16,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
    second: u6,
    /// 0 is Sunday.
    weekday: u3,
};

pub const min_unix_seconds: i64 = -62135596800; // 0001-01-01T00:00:00Z
pub const max_unix_seconds: i64 = 253402300799; // 9999-12-31T23:59:59Z
pub const max_offset_minutes = 18 * 60;

pub const Error = error{ OutOfRange, InvalidPattern, WriteFailed };

pub fn civil(instant: Instant) Error!Civil {
    if (@abs(instant.utc_offset_minutes) > max_offset_minutes) return error.OutOfRange;
    const local = instant.unix_seconds +| @as(i64, instant.utc_offset_minutes) * 60;
    if (local < min_unix_seconds or local > max_unix_seconds) return error.OutOfRange;
    const days = @divFloor(local, 86400);
    const seconds: u32 = @intCast(local - days * 86400);
    // Days to civil date, era-based (400-year cycles from 0000-03-01).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(seconds / 3600),
        .minute = @intCast(seconds / 60 % 60),
        .second = @intCast(seconds % 60),
        .weekday = @intCast(@mod(days + 4, 7)),
    };
}

pub const Style = enum { short, medium, long, full };

/// Names and CLDR-style patterns for one locale. Month names are the
/// format-context forms used inside dates (Russian genitive, for example).
pub const Data = struct {
    months_wide: [12][]const u8,
    months_abbr: [12][]const u8,
    weekdays_wide: [7][]const u8,
    weekdays_abbr: [7][]const u8,
    am_pm: [2][]const u8 = .{ "AM", "PM" },
    date: [4][]const u8,
    time: [2][]const u8,
    /// `{1}` is the date and `{0}` the time.
    date_time: []const u8 = "{1} {0}",
    /// A month and its year, as a calendar's title: `MMMM y`.
    month_year: []const u8 = "MMMM y",
    /// Month names standing alone, for `LLLL`, where the language inflects
    /// them inside dates; null uses `months_wide`.
    months_standalone: ?[12][]const u8 = null,

    pub fn datePattern(self: *const Data, style: Style) []const u8 {
        return self.date[@intFromEnum(style)];
    }
    /// Long and full time styles would add a zone name; without zone data
    /// they use the medium pattern.
    pub fn timePattern(self: *const Data, style: Style) []const u8 {
        return self.time[if (style == .short) 0 else 1];
    }
};

const numbered_months = [12][]const u8{ "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" };

/// Root data is neutral and numeric (ISO-like `2024-03-05`).
pub const root_data: Data = .{
    .months_wide = .{ "M01", "M02", "M03", "M04", "M05", "M06", "M07", "M08", "M09", "M10", "M11", "M12" },
    .months_abbr = .{ "M01", "M02", "M03", "M04", "M05", "M06", "M07", "M08", "M09", "M10", "M11", "M12" },
    .weekdays_wide = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    .weekdays_abbr = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    .date = .{ "y-MM-dd", "y-MM-dd", "y-MM-dd", "y-MM-dd, EEEE" },
    .time = .{ "HH:mm", "HH:mm:ss" },
    .month_year = "y-MM",
};

const english_months = [12][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const english_months_abbr = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const english_weekdays = [7][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const english_weekdays_abbr = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

const DataEntry = struct { tag: []const u8, data: Data };
/// Matched by the locale fallback chain, so `de-AT` uses `de`.
const data_table = [_]DataEntry{
    .{ .tag = "en", .data = .{
        .months_wide = english_months,
        .months_abbr = english_months_abbr,
        .weekdays_wide = english_weekdays,
        .weekdays_abbr = english_weekdays_abbr,
        .date = .{ "M/d/yy", "MMM d, y", "MMMM d, y", "EEEE, MMMM d, y" },
        .time = .{ "h:mm\u{202F}a", "h:mm:ss\u{202F}a" },
        .date_time = "{1}, {0}",
    } },
    .{ .tag = "en-GB", .data = .{
        .months_wide = english_months,
        .months_abbr = english_months_abbr,
        .weekdays_wide = english_weekdays,
        .weekdays_abbr = english_weekdays_abbr,
        .am_pm = .{ "am", "pm" },
        .date = .{ "dd/MM/y", "d MMM y", "d MMMM y", "EEEE d MMMM y" },
        .time = .{ "HH:mm", "HH:mm:ss" },
        .date_time = "{1}, {0}",
    } },
    .{ .tag = "de", .data = .{
        .months_wide = .{ "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember" },
        .months_abbr = .{ "Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez." },
        .weekdays_wide = .{ "Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag" },
        .weekdays_abbr = .{ "So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa." },
        .date = .{ "dd.MM.yy", "dd.MM.y", "d. MMMM y", "EEEE, d. MMMM y" },
        .time = .{ "HH:mm", "HH:mm:ss" },
        .date_time = "{1}, {0}",
    } },
    .{ .tag = "fr", .data = .{
        .months_wide = .{ "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre" },
        .months_abbr = .{ "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc." },
        .weekdays_wide = .{ "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi" },
        .weekdays_abbr = .{ "dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam." },
        .date = .{ "dd/MM/y", "d MMM y", "d MMMM y", "EEEE d MMMM y" },
        .time = .{ "HH:mm", "HH:mm:ss" },
    } },
    .{ .tag = "es", .data = .{
        .months_wide = .{ "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre" },
        .months_abbr = .{ "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic" },
        .weekdays_wide = .{ "domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado" },
        .weekdays_abbr = .{ "dom", "lun", "mar", "mié", "jue", "vie", "sáb" },
        .date = .{ "d/M/yy", "d MMM y", "d 'de' MMMM 'de' y", "EEEE, d 'de' MMMM 'de' y" },
        .time = .{ "H:mm", "H:mm:ss" },
        .date_time = "{1}, {0}",
        .month_year = "MMMM 'de' y",
    } },
    .{ .tag = "it", .data = .{
        .months_wide = .{ "gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre" },
        .months_abbr = .{ "gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic" },
        .weekdays_wide = .{ "domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato" },
        .weekdays_abbr = .{ "dom", "lun", "mar", "mer", "gio", "ven", "sab" },
        .date = .{ "dd/MM/yy", "d MMM y", "d MMMM y", "EEEE d MMMM y" },
        .time = .{ "HH:mm", "HH:mm:ss" },
        .date_time = "{1}, {0}",
    } },
    .{ .tag = "pt", .data = .{
        .months_wide = .{ "janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro" },
        .months_abbr = .{ "jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez." },
        .weekdays_wide = .{ "domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado" },
        .weekdays_abbr = .{ "dom.", "seg.", "ter.", "qua.", "qui.", "sex.", "sáb." },
        .date = .{ "dd/MM/y", "d 'de' MMM 'de' y", "d 'de' MMMM 'de' y", "EEEE, d 'de' MMMM 'de' y" },
        .time = .{ "HH:mm", "HH:mm:ss" },
        .month_year = "MMMM 'de' y",
    } },
    .{ .tag = "ru", .data = .{
        .months_wide = .{ "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря" },
        .months_abbr = .{ "янв.", "февр.", "мар.", "апр.", "мая", "июн.", "июл.", "авг.", "сент.", "окт.", "нояб.", "дек." },
        .weekdays_wide = .{ "воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота" },
        .weekdays_abbr = .{ "вс", "пн", "вт", "ср", "чт", "пт", "сб" },
        .date = .{ "dd.MM.y", "d MMM y 'г'.", "d MMMM y 'г'.", "EEEE, d MMMM y 'г'." },
        .time = .{ "HH:mm", "HH:mm:ss" },
        .date_time = "{1}, {0}",
        .month_year = "LLLL y 'г'.",
        .months_standalone = .{ "январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь" },
    } },
    .{ .tag = "ja", .data = .{
        .months_wide = numbered_months,
        .months_abbr = numbered_months,
        .weekdays_wide = .{ "日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日" },
        .weekdays_abbr = .{ "日", "月", "火", "水", "木", "金", "土" },
        .am_pm = .{ "午前", "午後" },
        .date = .{ "y/MM/dd", "y/MM/dd", "y年M月d日", "y年M月d日EEEE" },
        .time = .{ "H:mm", "H:mm:ss" },
        .month_year = "y年M月",
    } },
    .{ .tag = "zh", .data = .{
        .months_wide = .{ "一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月" },
        .months_abbr = numbered_months,
        .weekdays_wide = .{ "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" },
        .weekdays_abbr = .{ "周日", "周一", "周二", "周三", "周四", "周五", "周六" },
        .am_pm = .{ "上午", "下午" },
        .date = .{ "y/M/d", "y年M月d日", "y年M月d日", "y年M月d日EEEE" },
        .time = .{ "HH:mm", "HH:mm:ss" },
        .month_year = "y年M月",
    } },
    .{ .tag = "zh-Hant", .data = .{
        .months_wide = numbered_months,
        .months_abbr = numbered_months,
        .weekdays_wide = .{ "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" },
        .weekdays_abbr = .{ "週日", "週一", "週二", "週三", "週四", "週五", "週六" },
        .am_pm = .{ "上午", "下午" },
        .date = .{ "y/M/d", "y年M月d日", "y年M月d日", "y年M月d日 EEEE" },
        .time = .{ "ah:mm", "ah:mm:ss" },
        .month_year = "y年M月",
    } },
    .{ .tag = "ko", .data = .{
        .months_wide = .{ "1월", "2월", "3월", "4월", "5월", "6월", "7월", "8월", "9월", "10월", "11월", "12월" },
        .months_abbr = .{ "1월", "2월", "3월", "4월", "5월", "6월", "7월", "8월", "9월", "10월", "11월", "12월" },
        .weekdays_wide = .{ "일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일" },
        .weekdays_abbr = .{ "일", "월", "화", "수", "목", "금", "토" },
        .am_pm = .{ "오전", "오후" },
        .date = .{ "yy. M. d.", "y. M. d.", "y년 MMMM d일", "y년 MMMM d일 EEEE" },
        .time = .{ "a h:mm", "a h:mm:ss" },
        .month_year = "y년 MMMM",
    } },
};

/// Data for the most specific listed locale on the fallback chain, or the
/// numeric root data.
pub fn dataFor(locale: *const Locale) *const Data {
    const chain = locale.fallbackChain();
    for (chain.slice()) |*candidate| {
        for (&data_table) |*entry| if (std.mem.eql(u8, entry.tag, candidate.tag())) return &entry.data;
    }
    return &root_data;
}

/// Formats with a CLDR-style pattern: y, yy, yyyy; M/L 1-4 (LLLL is the
/// standalone month name); d, dd; E/c 1-4
/// (1-3 abbreviated); a; h, hh, H, HH; m, mm; s, ss; and 'quoted' text with
/// '' for an apostrophe. Other ASCII letters are rejected.
pub fn formatPattern(writer: *std.Io.Writer, data: *const Data, pattern: []const u8, value: Civil) Error!void {
    var index: usize = 0;
    while (index < pattern.len) {
        const c = pattern[index];
        if (c == '\'') {
            if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                try writer.writeByte('\'');
                index += 2;
                continue;
            }
            // Quoted text runs to the next lone apostrophe; '' inside it
            // is a literal apostrophe.
            index += 1;
            while (true) {
                if (index >= pattern.len) return error.InvalidPattern;
                if (pattern[index] == '\'') {
                    if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                        try writer.writeByte('\'');
                        index += 2;
                        continue;
                    }
                    index += 1;
                    break;
                }
                try writer.writeByte(pattern[index]);
                index += 1;
            }
            continue;
        }
        if (!std.ascii.isAlphabetic(c)) {
            try writer.writeByte(c);
            index += 1;
            continue;
        }
        var count: usize = 1;
        while (index + count < pattern.len and pattern[index + count] == c) count += 1;
        index += count;
        switch (c) {
            'y' => if (count == 2) try pad(writer, value.year % 100, 2) else try pad(writer, value.year, count),
            'M', 'L' => switch (count) {
                1, 2 => try pad(writer, value.month, count),
                3 => try writer.writeAll(data.months_abbr[value.month - 1]),
                4 => try writer.writeAll(if (c == 'L') if (data.months_standalone) |names| names[value.month - 1] else data.months_wide[value.month - 1] else data.months_wide[value.month - 1]),
                else => return error.InvalidPattern,
            },
            'd' => if (count <= 2) try pad(writer, value.day, count) else return error.InvalidPattern,
            'E', 'c' => switch (count) {
                1, 2, 3 => try writer.writeAll(data.weekdays_abbr[value.weekday]),
                4 => try writer.writeAll(data.weekdays_wide[value.weekday]),
                else => return error.InvalidPattern,
            },
            'a' => if (count == 1) try writer.writeAll(data.am_pm[if (value.hour < 12) 0 else 1]) else return error.InvalidPattern,
            'h' => if (count <= 2) try pad(writer, if (value.hour % 12 == 0) 12 else value.hour % 12, count) else return error.InvalidPattern,
            'H' => if (count <= 2) try pad(writer, value.hour, count) else return error.InvalidPattern,
            'm' => if (count <= 2) try pad(writer, value.minute, count) else return error.InvalidPattern,
            's' => if (count <= 2) try pad(writer, value.second, count) else return error.InvalidPattern,
            else => return error.InvalidPattern,
        }
    }
}

fn pad(writer: *std.Io.Writer, value: u32, width: usize) Error!void {
    var buffer: [10]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    var missing = width -| digits.len;
    while (missing > 0) : (missing -= 1) try writer.writeByte('0');
    try writer.writeAll(digits);
}

/// Days since 1970-01-01 of a proleptic Gregorian date; `month` is 1-12.
pub fn daysFromCivil(year: i32, month: u4, day: u5) i64 {
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Whether a locale writes the time of day in 12 hours with a day period
/// or in 24 hours, from its short time pattern.
pub const HourCycle = enum { h12, h23 };
pub fn hourCycle(locale: *const Locale) HourCycle {
    var quoted = false;
    for (dataFor(locale).timePattern(.short)) |c| {
        if (c == '\'') quoted = !quoted;
        if (quoted) continue;
        if (c == 'h' or c == 'K') return .h12;
        if (c == 'H' or c == 'k') return .h23;
    }
    return .h23;
}

/// Formats `value`, a date and time of day, with the locale's title of
/// its month, as `March 2024` or `2024年3月`.
pub fn formatMonthYear(writer: *std.Io.Writer, locale: *const Locale, value: Civil) Error!void {
    const data = dataFor(locale);
    try formatPattern(writer, data, data.month_year, value);
}

pub fn formatDate(writer: *std.Io.Writer, locale: *const Locale, instant: Instant, style: Style) Error!void {
    const data = dataFor(locale);
    try formatPattern(writer, data, data.datePattern(style), try civil(instant));
}

pub fn formatTime(writer: *std.Io.Writer, locale: *const Locale, instant: Instant, style: Style) Error!void {
    const data = dataFor(locale);
    try formatPattern(writer, data, data.timePattern(style), try civil(instant));
}

/// Joins the date and time styles with the locale's date-time glue.
pub fn formatDateTime(writer: *std.Io.Writer, locale: *const Locale, instant: Instant, date_style: Style, time_style: Style) Error!void {
    const data = dataFor(locale);
    const value = try civil(instant);
    const glue = data.date_time;
    var index: usize = 0;
    while (index < glue.len) {
        if (index + 3 <= glue.len and glue[index] == '{' and glue[index + 2] == '}' and (glue[index + 1] == '0' or glue[index + 1] == '1')) {
            const pattern = if (glue[index + 1] == '1') data.datePattern(date_style) else data.timePattern(time_style);
            try formatPattern(writer, data, pattern, value);
            index += 3;
        } else {
            try writer.writeByte(glue[index]);
            index += 1;
        }
    }
}

fn expectDate(tag: []const u8, instant: Instant, style: Style, expected: []const u8) !void {
    const locale = try Locale.parse(tag);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try formatDate(&writer, &locale, instant, style);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

// 2024-03-05T14:07:09Z, a Tuesday.
const sample: Instant = .{ .unix_seconds = 1709647629 };

test "civil conversion against known instants" {
    const epoch = try civil(.{ .unix_seconds = 0 });
    try std.testing.expectEqual(Civil{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .weekday = 4 }, epoch);
    try std.testing.expectEqual(Civil{ .year = 2024, .month = 3, .day = 5, .hour = 14, .minute = 7, .second = 9, .weekday = 2 }, try civil(sample));
    try std.testing.expectEqual(Civil{ .year = 2000, .month = 2, .day = 29, .hour = 23, .minute = 59, .second = 59, .weekday = 2 }, try civil(.{ .unix_seconds = 951868799 }));
    try std.testing.expectEqual(Civil{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .weekday = 3 }, try civil(.{ .unix_seconds = -1 }));
    try std.testing.expectEqual(Civil{ .year = 1, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .weekday = 1 }, try civil(.{ .unix_seconds = min_unix_seconds }));
    try std.testing.expectEqual(Civil{ .year = 9999, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .weekday = 5 }, try civil(.{ .unix_seconds = max_unix_seconds }));
    // An offset moves the local date across midnight.
    try std.testing.expectEqual(@as(u5, 6), (try civil(.{ .unix_seconds = sample.unix_seconds, .utc_offset_minutes = 600 })).day);
    try std.testing.expectError(error.OutOfRange, civil(.{ .unix_seconds = max_unix_seconds + 1 }));
    try std.testing.expectError(error.OutOfRange, civil(.{ .unix_seconds = 0, .utc_offset_minutes = 18 * 60 + 1 }));
    try std.testing.expectError(error.OutOfRange, civil(.{ .unix_seconds = std.math.maxInt(i64), .utc_offset_minutes = 60 }));
}

test "locale date styles" {
    try expectDate("en-US", sample, .short, "3/5/24");
    try expectDate("en", sample, .medium, "Mar 5, 2024");
    try expectDate("en", sample, .full, "Tuesday, March 5, 2024");
    try expectDate("en-GB", sample, .long, "5 March 2024");
    try expectDate("de-AT", sample, .full, "Dienstag, 5. März 2024");
    try expectDate("fr-CA", sample, .long, "5 mars 2024");
    try expectDate("es", sample, .long, "5 de marzo de 2024");
    try expectDate("ru", sample, .long, "5 марта 2024 г.");
    try expectDate("ja", sample, .full, "2024年3月5日火曜日");
    try expectDate("zh-CN", sample, .full, "2024年3月5日星期二");
    try expectDate("zh-TW", sample, .short, "2024/3/5");
    try expectDate("ko", sample, .long, "2024년 3월 5일");
    try expectDate("sw", sample, .medium, "2024-03-05");
    try expectDate("en", .{ .unix_seconds = -62135596800 }, .short, "1/1/01");
}

test "time and date-time joining" {
    const en = try Locale.parse("en");
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try formatTime(&writer, &en, sample, .short);
    try std.testing.expectEqualStrings("2:07\u{202F}PM", writer.buffered());
    writer = .fixed(&buffer);
    try formatDateTime(&writer, &en, .{ .unix_seconds = 1709596800 }, .medium, .short);
    try std.testing.expectEqualStrings("Mar 5, 2024, 12:00\u{202F}AM", writer.buffered());
    const tw = try Locale.parse("zh-TW");
    writer = .fixed(&buffer);
    try formatDateTime(&writer, &tw, sample, .long, .short);
    try std.testing.expectEqualStrings("2024年3月5日 下午2:07", writer.buffered());
    const de = try Locale.parse("de");
    writer = .fixed(&buffer);
    try formatTime(&writer, &de, sample, .full);
    try std.testing.expectEqualStrings("14:07:09", writer.buffered());
}

test "days from civil dates, hour cycles and month titles" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 19787), daysFromCivil(2024, 3, 5));
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try std.testing.expectEqual(@divFloor(min_unix_seconds, 86400), daysFromCivil(1, 1, 1));
    try std.testing.expectEqual(@as(u5, 29), (try civil(.{ .unix_seconds = daysFromCivil(2000, 2, 29) * 86400 })).day);
    inline for (.{ .{ "en", HourCycle.h12 }, .{ "en-GB", HourCycle.h23 }, .{ "zh-TW", HourCycle.h12 }, .{ "zh", HourCycle.h23 }, .{ "ko", HourCycle.h12 }, .{ "sw", HourCycle.h23 } }) |case| {
        const locale = try Locale.parse(case[0]);
        try std.testing.expectEqual(case[1], hourCycle(&locale));
    }
    var buffer: [64]u8 = undefined;
    inline for (.{ .{ "en", "March 2024" }, .{ "zh-CN", "2024年3月" }, .{ "ru", "март 2024 г." }, .{ "es", "marzo de 2024" }, .{ "ko", "2024년 3월" }, .{ "sw", "2024-03" } }) |case| {
        const locale = try Locale.parse(case[0]);
        var writer: std.Io.Writer = .fixed(&buffer);
        try formatMonthYear(&writer, &locale, try civil(sample));
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}

test "pattern letters and quoting" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const value = try civil(sample);
    try formatPattern(&writer, &root_data, "yyyy-MM-dd'T'HH:mm:ss 'o''clock' ''", value);
    try std.testing.expectEqualStrings("2024-03-05T14:07:09 o'clock '", writer.buffered());
    for ([_][]const u8{ "MMMMM", "'unterminated", "Q", "ddd", "aa" }) |bad| {
        writer = .fixed(&buffer);
        try std.testing.expectError(error.InvalidPattern, formatPattern(&writer, &root_data, bad, value));
    }
}
