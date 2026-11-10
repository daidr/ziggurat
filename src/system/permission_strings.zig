//! Texts of the permission guide panel and the permissions' names in the
//! languages the module ships, merged with application overrides, as the
//! update window's are. `{app}` and `{permission}` name the arguments of the
//! panel's sentence, so a translation can order them as its grammar needs;
//! both show in bold.
const std = @import("std");
const zio = @import("ziggurat_io");

/// One language. Empty fields fall back to the shipped language, then to
/// English.
pub const Strings = struct {
    /// {app} {permission}
    guide_drag: []const u8 = "",
    /// Under the app the user drags.
    guide_drag_hint: []const u8 = "",
    accessibility: []const u8 = "",
    /// What macOS 27 calls Accessibility.
    device_control_and_data_access: []const u8 = "",
    screen_recording: []const u8 = "",
    input_monitoring: []const u8 = "",
    full_disk_access: []const u8 = "",
    app_management: []const u8 = "",
    developer_tools: []const u8 = "",
    microphone: []const u8 = "",
    camera: []const u8 = "",
    calendars: []const u8 = "",
    reminders: []const u8 = "",
    bluetooth: []const u8 = "",
    media_apple_music: []const u8 = "",

    /// Fills empty fields from `fallback`.
    pub fn merge(self: Strings, fallback: Strings) Strings {
        var result = self;
        inline for (zio.fields(Strings)) |field| {
            if (@field(result, field.name).len == 0) @field(result, field.name) = @field(fallback, field.name);
        }
        return result;
    }
};

pub const Language = struct { tag: []const u8, strings: Strings };

pub const english: Strings = .{
    .guide_drag = "Drag {app} to the list above to allow {permission}.",
    .guide_drag_hint = "Drag",
    .accessibility = "Accessibility",
    .device_control_and_data_access = "Device Control and Data Access",
    .screen_recording = "Screen Recording",
    .input_monitoring = "Input Monitoring",
    .full_disk_access = "Full Disk Access",
    .app_management = "App Management",
    .developer_tools = "Developer Tools",
    .microphone = "Microphone",
    .camera = "Camera",
    .calendars = "Calendars",
    .reminders = "Reminders",
    .bluetooth = "Bluetooth",
    .media_apple_music = "Media & Apple Music",
};

pub const languages = [_]Language{
    .{ .tag = "en", .strings = english },
    .{ .tag = "ja", .strings = .{
        .guide_drag = "{app}を上のリストにドラッグして{permission}を許可してください。",
        .guide_drag_hint = "ドラッグ",
        .accessibility = "アクセシビリティ",
        .device_control_and_data_access = "デバイス制御とデータアクセス",
        .screen_recording = "画面収録",
        .input_monitoring = "入力監視",
        .full_disk_access = "フルディスクアクセス",
        .app_management = "アプリケーション管理",
        .developer_tools = "デベロッパーツール",
        .microphone = "マイク",
        .camera = "カメラ",
        .calendars = "カレンダー",
        .reminders = "リマインダー",
        .bluetooth = "Bluetooth",
        .media_apple_music = "メディアとApple Music",
    } },
    .{ .tag = "zh-Hans", .strings = .{
        .guide_drag = "将{app}拖入上方列表以允许{permission}。",
        .guide_drag_hint = "拖入",
        .accessibility = "辅助功能",
        .device_control_and_data_access = "设备控制与数据访问",
        .screen_recording = "屏幕录制",
        .input_monitoring = "输入监控",
        .full_disk_access = "完全磁盘访问权限",
        .app_management = "应用管理",
        .developer_tools = "开发者工具",
        .microphone = "麦克风",
        .camera = "相机",
        .calendars = "日历",
        .reminders = "提醒事项",
        .bluetooth = "蓝牙",
        .media_apple_music = "媒体与 Apple Music",
    } },
    .{ .tag = "zh-Hant", .strings = .{
        .guide_drag = "將{app}拖入上方列表以允許{permission}。",
        .guide_drag_hint = "拖入",
        .accessibility = "輔助功能",
        .device_control_and_data_access = "裝置控制與資料存取",
        .screen_recording = "螢幕錄製",
        .input_monitoring = "輸入監控",
        .full_disk_access = "完整磁碟存取",
        .app_management = "應用程式管理",
        .developer_tools = "開發者工具",
        .microphone = "麥克風",
        .camera = "相機",
        .calendars = "行事曆",
        .reminders = "提醒事項",
        .bluetooth = "藍牙",
        .media_apple_music = "媒體與 Apple Music",
    } },
};

/// The shipped language closest to `locale`, such as "zh-TW" or "ja_JP":
/// Chinese picks its script from the script or region, other languages
/// match on the primary subtag, and anything else is English.
pub fn shipped(locale: []const u8) Language {
    var primary_buffer: [8]u8 = undefined;
    const end = std.mem.indexOfAny(u8, locale, "-_.@") orelse locale.len;
    if (end == 0 or end > primary_buffer.len) return languages[0];
    const primary = std.ascii.lowerString(&primary_buffer, locale[0..end]);
    if (std.mem.eql(u8, primary, "zh")) {
        const rest = locale[end..];
        const traditional = for ([_][]const u8{ "hant", "tw", "hk", "mo" }) |needle| {
            if (std.ascii.findIgnoreCase(rest, needle) != null) break true;
        } else false;
        return find(if (traditional) "zh-Hant" else "zh-Hans").?;
    }
    return find(primary) orelse languages[0];
}

pub fn find(tag: []const u8) ?Language {
    for (languages) |language| if (std.ascii.eqlIgnoreCase(language.tag, tag)) return language;
    return null;
}

/// The strings for `locale`: application overrides for the exact or primary
/// tag first, then the shipped language, then English.
pub fn resolve(locale: []const u8, overrides: []const Language) Strings {
    const base = shipped(locale);
    var result = base.strings.merge(english);
    const end = std.mem.indexOfAny(u8, locale, "-_.@") orelse locale.len;
    for (overrides) |language| {
        const matches = std.ascii.eqlIgnoreCase(language.tag, locale) or std.ascii.eqlIgnoreCase(language.tag, base.tag) or std.ascii.eqlIgnoreCase(language.tag, locale[0..end]);
        if (matches) result = language.strings.merge(result);
    }
    return result;
}

/// Marks where the app's and the permission's names go in `sentence`.
pub const app_mark = 0x01;
pub const permission_mark = 0x02;

/// `template` with {app} and {permission} replaced by their marks, which
/// the panel shows as the names in bold, NUL-terminated.
pub fn marked(buffer: []u8, template: []const u8) error{ ArgumentTooLong, InvalidText }![:0]u8 {
    if (buffer.len == 0) return error.ArgumentTooLong;
    if (!std.unicode.utf8ValidateSlice(template)) return error.InvalidText;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    var rest = template;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "{app}")) {
            writer.writeByte(app_mark) catch return error.ArgumentTooLong;
            rest = rest["{app}".len..];
        } else if (std.mem.startsWith(u8, rest, "{permission}")) {
            writer.writeByte(permission_mark) catch return error.ArgumentTooLong;
            rest = rest["{permission}".len..];
        } else {
            if (rest[0] < 0x20) return error.InvalidText;
            writer.writeByte(rest[0]) catch return error.ArgumentTooLong;
            rest = rest[1..];
        }
    }
    const length = writer.buffered().len;
    buffer[length] = 0;
    return buffer[0..length :0];
}

/// One piece of the panel's sentence.
pub const Run = struct { text: []const u8, bold: bool = false };

/// The runs of a marked sentence with the names in place.
pub fn runs(sentence: []const u8, app: []const u8, permission: []const u8, out: []Run) ![]Run {
    var count: usize = 0;
    var start: usize = 0;
    for (sentence, 0..) |byte, index| {
        if (byte != app_mark and byte != permission_mark) continue;
        if (count + 2 > out.len) return error.TooManyRuns;
        if (index > start) {
            out[count] = .{ .text = sentence[start..index] };
            count += 1;
        }
        out[count] = .{ .text = if (byte == app_mark) app else permission, .bold = true };
        count += 1;
        start = index + 1;
    }
    if (start < sentence.len) {
        if (count == out.len) return error.TooManyRuns;
        out[count] = .{ .text = sentence[start..] };
        count += 1;
    }
    return out[0..count];
}

test "the panel speaks the closest shipped language, which the app's texts override" {
    try std.testing.expectEqualStrings("Drag {app} to the list above to allow {permission}.", resolve("en-US", &.{}).guide_drag);
    try std.testing.expectEqualStrings("辅助功能", resolve("zh-CN", &.{}).accessibility);
    try std.testing.expectEqualStrings("輔助功能", resolve("zh-TW", &.{}).accessibility);
    try std.testing.expectEqualStrings("輔助功能", resolve("zh-Hant-HK", &.{}).accessibility);
    try std.testing.expectEqualStrings("画面収録", resolve("ja_JP.UTF-8", &.{}).screen_recording);
    try std.testing.expectEqualStrings("Camera", resolve("de", &.{}).camera);
    const overrides = [_]Language{.{ .tag = "zh-Hans", .strings = .{ .guide_drag_hint = "拖动" } }};
    const strings = resolve("zh-CN", &overrides);
    try std.testing.expectEqualStrings("拖动", strings.guide_drag_hint);
    try std.testing.expectEqualStrings("将{app}拖入上方列表以允许{permission}。", strings.guide_drag);
}

test "the names keep their bold in the order a translation gives them" {
    var buffer: [128]u8 = undefined;
    var out: [8]Run = undefined;
    const english_runs = try runs(try marked(&buffer, english.guide_drag), "MyApp", "Accessibility", &out);
    try std.testing.expectEqual(5, english_runs.len);
    try std.testing.expectEqualStrings("Drag ", english_runs[0].text);
    try std.testing.expect(english_runs[1].bold and std.mem.eql(u8, english_runs[1].text, "MyApp"));
    try std.testing.expect(english_runs[3].bold and std.mem.eql(u8, english_runs[3].text, "Accessibility"));
    try std.testing.expectEqualStrings(".", english_runs[4].text);
    // The permission before the app, and nothing around them.
    const reordered = try runs(try marked(&buffer, "{permission}: {app}"), "笔记", "辅助功能", &out);
    try std.testing.expectEqual(3, reordered.len);
    try std.testing.expect(reordered[0].bold and std.mem.eql(u8, reordered[0].text, "辅助功能"));
    try std.testing.expectEqualStrings(": ", reordered[1].text);
    try std.testing.expect(reordered[2].bold and std.mem.eql(u8, reordered[2].text, "笔记"));
    const japanese = try runs(try marked(&buffer, find("ja").?.strings.guide_drag), "Notes", "アクセシビリティ", &out);
    try std.testing.expectEqualStrings("Notes", japanese[0].text);
    try std.testing.expect(japanese[0].bold);
    try std.testing.expectError(error.InvalidText, marked(&buffer, "a\x01b"));
}
