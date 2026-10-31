//! Runtime language switching with `ziggurat_i18n`.
//!
//! One application-owned Catalog holds English, Chinese, Arabic (right to
//! left) and Russian messages. Picking a language rebuilds the Localizer and
//! the next build pass describes the whole view in that language: plural
//! categories (Arabic has six, Russian four), locale number and percent
//! formatting, long dates and times, an English-only ordinal, and the window
//! title. The initial language comes from the system locale.
//!
//! Run with `zig build run-i18n`.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const i18n = @import("ziggurat_i18n");

const Language = enum { en, zh, ar, ru };
const languages = [_]struct { language: Language, tag: []const u8, name: []const u8 }{
    .{ .language = .en, .tag = "en", .name = "English" },
    .{ .language = .zh, .tag = "zh", .name = "中文" },
    .{ .language = .ar, .tag = "ar", .name = "العربية" },
    .{ .language = .ru, .tag = "ru", .name = "Русский" },
};

const english = [_]i18n.Entry{
    .{ .key = "title", .message = "Ziggurat — Localization" },
    .{ .key = "language", .message = "Language" },
    .{ .key = "greeting", .message = "Hello, {name}!" },
    .{ .key = "count", .message = "Number of files" },
    .{ .key = "files", .message = "{count, plural, =0 {No files} one {# file} other {# files}} selected" },
    .{ .key = "size", .message = "Total size: {bytes, number} bytes" },
    .{ .key = "progress", .message = "Upload {ratio, number, percent} complete" },
    .{ .key = "place", .message = "You finished {place, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}." },
    .{ .key = "today", .message = "Today is {now, date, full}." },
    .{ .key = "time", .message = "Time (UTC): {now, time, short}" },
    .{ .key = "direction", .message = "Text direction: left to right" },
    .{ .key = "fallback", .message = "Messages missing from a translation fall back to English." },
};
const chinese = [_]i18n.Entry{
    .{ .key = "title", .message = "Ziggurat — 本地化" },
    .{ .key = "language", .message = "语言" },
    .{ .key = "greeting", .message = "你好，{name}！" },
    .{ .key = "count", .message = "文件数量" },
    .{ .key = "files", .message = "{count, plural, =0 {未选择文件} other {已选择 # 个文件}}" },
    .{ .key = "size", .message = "总大小：{bytes, number} 字节" },
    .{ .key = "progress", .message = "上传已完成 {ratio, number, percent}" },
    .{ .key = "place", .message = "你获得了第 {place} 名。" },
    .{ .key = "today", .message = "今天是 {now, date, full}。" },
    .{ .key = "time", .message = "时间（UTC）：{now, time, short}" },
    .{ .key = "direction", .message = "文字方向：从左到右" },
};
const arabic = [_]i18n.Entry{
    .{ .key = "title", .message = "Ziggurat — الترجمة" },
    .{ .key = "language", .message = "اللغة" },
    .{ .key = "greeting", .message = "مرحبًا، {name}!" },
    .{ .key = "count", .message = "عدد الملفات" },
    .{ .key = "files", .message = "{count, plural, =0 {لم يتم تحديد أي ملف} one {تم تحديد ملف واحد} two {تم تحديد ملفين} few {تم تحديد # ملفات} many {تم تحديد # ملفًا} other {تم تحديد # ملف}}" },
    .{ .key = "size", .message = "الحجم الإجمالي: {bytes, number} بايت" },
    .{ .key = "progress", .message = "اكتمل التحميل بنسبة {ratio, number, percent}" },
    .{ .key = "place", .message = "لقد حللت في المركز {place}." },
    .{ .key = "today", .message = "اليوم هو {now, date, full}." },
    .{ .key = "time", .message = "الوقت (UTC): {now, time, short}" },
    .{ .key = "direction", .message = "اتجاه النص: من اليمين إلى اليسار" },
};
const russian = [_]i18n.Entry{
    .{ .key = "title", .message = "Ziggurat — Локализация" },
    .{ .key = "language", .message = "Язык" },
    .{ .key = "greeting", .message = "Привет, {name}!" },
    .{ .key = "count", .message = "Количество файлов" },
    .{ .key = "files", .message = "{count, plural, =0 {Файлы не выбраны} one {Выбран # файл} few {Выбрано # файла} many {Выбрано # файлов} other {Выбрано # файла}}" },
    .{ .key = "size", .message = "Общий размер: {bytes, number} байт" },
    .{ .key = "progress", .message = "Загрузка завершена на {ratio, number, percent}" },
    .{ .key = "place", .message = "Вы заняли {place}-е место." },
    .{ .key = "today", .message = "Сегодня {now, date, full}." },
    .{ .key = "time", .message = "Время (UTC): {now, time, short}" },
    .{ .key = "direction", .message = "Направление текста: слева направо" },
};
comptime {
    for (.{ &english, &chinese, &arabic, &russian }) |entries| i18n.catalog.comptimeValidate(entries);
}

const Demo = struct {
    catalog: *const i18n.Catalog,
    localizer: i18n.Localizer,
    language: Language = .en,
    /// Set once the window exists, so a language change can retitle it.
    window: ?z.Window = null,
    files: f64 = 3,
    /// Fixed so a sample screenshot or test reads the same every run; the
    /// time line below uses the clock.
    sample_bytes: i64 = 1234567,

    fn init(catalog: *const i18n.Catalog, language: Language) Demo {
        var demo: Demo = .{ .catalog = catalog, .localizer = undefined };
        demo.select(language);
        return demo;
    }

    /// Bind a new Localizer; formatting after this uses the new chain and
    /// does not allocate.
    fn select(self: *Demo, language: Language) void {
        self.language = language;
        const locale = i18n.Locale.parse(languages[@backingInt(language)].tag) catch unreachable;
        self.localizer = i18n.Localizer.init(self.catalog, locale, .{});
    }

    fn retitle(self: *Demo) void {
        const window = self.window orelse return;
        var buffer: [128]u8 = undefined;
        const title = self.localizer.bufPrint(&buffer, "title", &.{}) catch return;
        window.setTitle(title) catch {};
    }

    /// Format one message into a stack buffer; `View.text` copies it.
    fn line(self: *Demo, v: *view.View, key: []const u8, arguments: []const i18n.Arg, style: view.Style) !void {
        var buffer: [512]u8 = undefined;
        try v.text(try self.localizer.bufPrint(&buffer, key, arguments), style);
    }

    fn build(self: *Demo, v: *view.View) anyerror!void {
        // Layout mirroring is not available yet, so right-to-left text is
        // aligned to the trailing edge instead.
        const rtl = self.localizer.direction() == .rtl;
        const text_style: view.Style = .{ .self_align = if (rtl) .end else .start };
        const count: i64 = @intFromFloat(self.files);
        const now: i18n.Instant = .{ .unix_seconds = zio.timestamp() };

        try self.line(v, "language", &.{}, text_style);
        try v.segmented(.{ .name = "Language" });
        for (languages) |entry| {
            if (try v.segment(Language, &self.language, entry.language, entry.name, .{})) {
                self.select(entry.language);
                self.retitle();
            }
        }
        try v.end();

        try self.line(v, "greeting", &i18n.args(.{ .name = "Ada" }), .{ .self_align = text_style.self_align, .font = view.Font.heading3 });
        try v.row(.{ .gap = 12, .alignment = .center, .self_align = .stretch });
        try self.line(v, "count", &.{}, .{});
        _ = try v.stepper(&self.files, .{ .minimum = 0, .maximum = 25, .step = 1 }, .{});
        try v.end();
        try self.line(v, "files", &i18n.args(.{ .count = count }), text_style);
        try self.line(v, "size", &i18n.args(.{ .bytes = self.sample_bytes * count }), text_style);
        try self.line(v, "progress", &i18n.args(.{ .ratio = @as(f64, @floatFromInt(count)) / 25.0 }), text_style);
        try self.line(v, "place", &i18n.args(.{ .place = @max(count, 1) }), text_style);
        try self.line(v, "today", &i18n.args(.{ .now = now }), text_style);
        try self.line(v, "time", &i18n.args(.{ .now = now }), text_style);
        try self.line(v, "direction", &.{}, text_style);
        try v.spacer(.{});
        // This key exists only in English, so other languages show the
        // source message.
        try self.line(v, "fallback", &.{}, .{ .self_align = text_style.self_align, .color = 0x536475 });
    }
};

/// The supported language closest to the system setting, else English.
fn systemLanguage(catalog: *const i18n.Catalog) Language {
    const preferred = i18n.locale.system() orelse return .en;
    const chosen = catalog.negotiate(&.{preferred});
    for (languages) |entry| if (std.mem.eql(u8, chosen.tag(), entry.tag)) return entry.language;
    return .en;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = i18n.Catalog.init(allocator, try i18n.Locale.parse("en"));
    defer catalog.deinit();
    try catalog.addEntries(try i18n.Locale.parse("en"), &english, null);
    try catalog.addEntries(try i18n.Locale.parse("zh"), &chinese, null);
    try catalog.addEntries(try i18n.Locale.parse("ar"), &arabic, null);
    try catalog.addEntries(try i18n.Locale.parse("ru"), &russian, null);

    var demo = Demo.init(&catalog, systemLanguage(&catalog));
    var storage: view.Storage(64, 4096) = .{};
    var host = view.Host.init(&demo, Demo.build, storage.buffers(), .{});

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Ziggurat — Localization", .width = 640, .height = 520 });
    demo.window = window;
    demo.retitle();
    try host.attach(window);
    window.show();
    try app.run();
    demo.window = null;
}

test "switching language rebuilds every message" {
    var catalog = i18n.Catalog.init(std.testing.allocator, try i18n.Locale.parse("en"));
    defer catalog.deinit();
    try catalog.addEntries(try i18n.Locale.parse("en"), &english, null);
    try catalog.addEntries(try i18n.Locale.parse("zh"), &chinese, null);
    try catalog.addEntries(try i18n.Locale.parse("ar"), &arabic, null);
    try catalog.addEntries(try i18n.Locale.parse("ru"), &russian, null);
    var demo = Demo.init(&catalog, .en);
    var storage: view.Storage(64, 4096) = .{};
    var h = view.Harness.init(&demo, Demo.build, storage.buffers(), .{});
    try h.render();
    _ = try h.find(.{ .text = "3 files selected" });
    try h.click(.{ .text = "中文" });
    try std.testing.expectEqual(Language.zh, demo.language);
    _ = try h.find(.{ .text = "已选择 3 个文件" });
    try h.click(.{ .text = "Русский" });
    _ = try h.find(.{ .text = "Выбрано 3 файла" });
    try h.change(.{ .kind = .stepper }, .{ .steps = 2 });
    _ = try h.find(.{ .text = "Выбрано 5 файлов" });
}
