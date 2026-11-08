//! The language the app chose for its users: what a language menu sets
//! (`Choice.set`), kept for the next launches, and read back
//! (`Choice.chosen`) to tell its "System" item apart from the language the
//! system resolves to. `Choice.shown` resolves the language the app shows
//! from it, the user's languages and those the app is written in.
//!
//! A `Choice` belongs to the app, one for the process; it is safe from any
//! thread. `set` takes effect when it returns, so a `chosen` from another
//! thread after it reports it, and after the app quits `chosen` still
//! reports the last choice. Nothing here relabels menus or tells pages: the
//! app gives `shown` to what shows its language (`page_runtime.Host.setLocale`,
//! `menu_roles`, its catalogs' Localizer) when `set` returns.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const i18n = @import("ziggurat_i18n");

/// Chooses the language for one run, and keeps nothing, as a development
/// server's `-lang` does: `ZIGGURAT_LOCALE=de`.
pub const environment_variable = "ZIGGURAT_LOCALE";
/// The file in `Options.directory` that keeps the choice: the tag and a
/// newline, or no file while the app follows the user's languages.
pub const file_name = "locale";
pub const max_directory_bytes = 1024;

pub const Options = struct {
    /// Where the choice is kept for the next launches, such as
    /// `identity.applicationDirectory(.data, id)`; created when the app
    /// first chooses. null keeps nothing (browsers, tests).
    directory: ?[]const u8 = null,
    /// The language chosen for this run, as `ZIGGURAT_LOCALE`: `.process`
    /// reads the variable when the choice is first read.
    environment: union(enum) { process, none, value: []const u8 } = .process,
};

pub const Error = error{ InvalidLocale, DirectoryTooLong };

pub const Choice = struct {
    mutex: zio.Mutex = .{},
    directory: [max_directory_bytes]u8 = undefined,
    directory_len: usize = 0,
    keeps: bool = false,
    environment: ?i18n.Locale = null,
    read_environment: bool = false,
    /// The saved language and the environment's were read.
    loaded: bool = false,
    /// The environment chose the language: `set` saves nothing.
    from_environment: bool = false,
    /// The app runs (`start`): before, `set` under the environment's
    /// language changes nothing, as the language the app starts with
    /// gives way to the run's.
    started: bool = false,
    /// The language chosen, or null to follow the user's.
    override: ?i18n.Locale = null,

    pub fn init(options: Options) Error!Choice {
        var self: Choice = .{};
        if (options.directory) |directory| {
            if (directory.len > max_directory_bytes) return error.DirectoryTooLong;
            @memcpy(self.directory[0..directory.len], directory);
            self.directory_len = directory.len;
            self.keeps = true;
        }
        switch (options.environment) {
            .process => self.read_environment = true,
            .none => {},
            .value => |value| self.environment = parseOptional(value) catch null,
        }
        return self;
    }

    /// The app runs: from now on `set` chooses even while the environment
    /// chose the run's language.
    pub fn start(self: *Choice) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.started = true;
    }

    /// Makes `tag`, a BCP 47 tag such as "de" or "zh-Hant-TW", the language
    /// the app shows, or "" to follow the user's languages again, the
    /// default, and keeps it for the next launches. The pseudo locales
    /// en-XA and ar-XB are kept and shown as they are. While the
    /// environment chose the run's language it keeps nothing, and before
    /// `start` it changes nothing. A tag that names no language is
    /// `error.InvalidLocale`. A failure to save keeps what was saved; the
    /// app shows the language anyway.
    pub fn set(self: *Choice, tag: []const u8) Error!void {
        const locale = try parseOptional(tag);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.load();
        if (self.from_environment and !self.started) return;
        self.override = locale;
        if (!self.from_environment) self.save();
    }

    /// The language the app chose (`set`) as it keeps it, normalized
    /// ("de-AT", "zh-Hans"), or null while the app follows the user's
    /// languages: the one saved in an earlier run until `set` chooses
    /// another, or the environment's for its run. It reports the tag kept
    /// even where the app is not written in it and shows another.
    pub fn chosen(self: *Choice) ?i18n.Locale {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.load();
        return self.override;
    }
    /// `chosen` as a tag, "" while the app follows the user's languages.
    pub fn chosenTag(self: *Choice, buffer: *[i18n.locale.max_tag_len]u8) []const u8 {
        const locale = self.chosen() orelse return "";
        const tag = locale.tag();
        @memcpy(buffer[0..tag.len], tag);
        return buffer[0..tag.len];
    }

    /// The language the app shows, of `available` (those it is written in,
    /// its own first): the pseudo locale chosen, else the first of the one
    /// chosen and the user's `preferred` that one of them matches, else the
    /// app's own.
    pub fn shown(self: *Choice, available: []const i18n.Locale, preferred: []const i18n.Locale) i18n.Locale {
        return resolve(self.chosen(), preferred, available);
    }

    /// Reads the saved language, or the environment's, which wins and is
    /// never saved, once. Under the mutex.
    fn load(self: *Choice) void {
        if (self.loaded) return;
        self.loaded = true;
        var buffer: [256]u8 = undefined;
        if (self.read_environment) self.environment = if (environmentValue(&buffer)) |value| parseOptional(value) catch null else null;
        if (self.environment) |locale| {
            self.override = locale;
            self.from_environment = true;
            return;
        }
        self.override = self.readFile();
    }

    fn path(self: *const Choice, buffer: *[max_directory_bytes + 1 + file_name.len + 4]u8, suffix: []const u8) []const u8 {
        const directory = self.directory[0..self.directory_len];
        @memcpy(buffer[0..directory.len], directory);
        buffer[directory.len] = std.fs.path.sep;
        @memcpy(buffer[directory.len + 1 ..][0..file_name.len], file_name);
        @memcpy(buffer[directory.len + 1 + file_name.len ..][0..suffix.len], suffix);
        return buffer[0 .. directory.len + 1 + file_name.len + suffix.len];
    }
    fn readFile(self: *const Choice) ?i18n.Locale {
        if (!self.keeps or builtin.cpu.arch == .wasm32) return null;
        var buffer: [max_directory_bytes + 1 + file_name.len + 4]u8 = undefined;
        var data: [128]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(zio.io(), self.path(&buffer, ""), &data) catch return null;
        return parseOptional(std.mem.trim(u8, bytes, " \t\r\n")) catch null;
    }
    fn save(self: *const Choice) void {
        if (!self.keeps or builtin.cpu.arch == .wasm32) return;
        var buffer: [max_directory_bytes + 1 + file_name.len + 4]u8 = undefined;
        const file = self.path(&buffer, "");
        const locale = self.override orelse {
            std.Io.Dir.cwd().deleteFile(zio.io(), file) catch {};
            return;
        };
        std.Io.Dir.cwd().createDirPath(zio.io(), self.directory[0..self.directory_len]) catch return;
        var line: [i18n.locale.max_tag_len + 1]u8 = undefined;
        const tag = locale.tag();
        @memcpy(line[0..tag.len], tag);
        line[tag.len] = '\n';
        var atomic = std.Io.Dir.cwd().createFileAtomic(zio.io(), file, .{ .replace = true }) catch return;
        defer atomic.deinit(zio.io());
        atomic.file.writeStreamingAll(zio.io(), line[0 .. tag.len + 1]) catch return;
        atomic.replace(zio.io()) catch {};
    }
};

fn environmentValue(buffer: *[256]u8) ?[]const u8 {
    if (comptime builtin.cpu.arch == .wasm32) {
        return null;
    } else if (comptime builtin.os.tag == .windows) {
        var fixed = std.heap.FixedBufferAllocator.init(buffer);
        return zio.getEnvVarOwned(fixed.allocator(), environment_variable) catch null;
    } else return zio.getenv(environment_variable);
}

/// A tag, or null for "" (blank).
fn parseOptional(tag: []const u8) error{InvalidLocale}!?i18n.Locale {
    const trimmed = std.mem.trim(u8, tag, " \t\r\n");
    if (trimmed.len == 0) return null;
    const locale = try i18n.Locale.parse(trimmed);
    if (locale.isRoot()) return error.InvalidLocale;
    return locale;
}

/// The language shown of `available`: the pseudo locale chosen, else the
/// first of `chosen` and `preferred` one of them matches, else the first.
pub fn resolve(chosen: ?i18n.Locale, preferred: []const i18n.Locale, available: []const i18n.Locale) i18n.Locale {
    if (available.len == 0) return chosen orelse i18n.Locale.parse("en") catch unreachable;
    var want: [17]i18n.Locale = undefined;
    var count: usize = 0;
    if (chosen) |locale| {
        if (i18n.pseudo.modeFor(&locale) != .none) return locale;
        want[0] = locale;
        count = 1;
    }
    for (preferred[0..@min(preferred.len, want.len - count)]) |locale| {
        want[count] = locale;
        count += 1;
    }
    const index = i18n.locale.negotiate(want[0..count], available) orelse 0;
    return available[index];
}

fn expectChosen(choice: *Choice, want: []const u8) !void {
    var buffer: [i18n.locale.max_tag_len]u8 = undefined;
    try std.testing.expectEqualStrings(want, choice.chosenTag(&buffer));
}
fn locales(comptime tags: []const []const u8) [tags.len]i18n.Locale {
    var out: [tags.len]i18n.Locale = undefined;
    for (tags, 0..) |tag, i| out[i] = i18n.Locale.parse(tag) catch unreachable;
    return out;
}

test "the chosen language is what set chose and keeps, empty while following the user's" {
    var choice = try Choice.init(.{ .environment = .none });
    choice.start();
    const available = locales(&.{ "en", "de", "zh-Hans" });
    const preferred = locales(&.{"zh-CN"});
    try expectChosen(&choice, "");
    try std.testing.expectEqualStrings("zh-Hans", choice.shown(&available, &preferred).tag());
    const cases = [_]struct { tag: []const u8, chosen: []const u8, shown: []const u8 }{
        // The language the system resolves to, chosen.
        .{ .tag = "zh-Hans", .chosen = "zh-Hans", .shown = "zh-Hans" },
        // Normalized, as kept, with the language shown.
        .{ .tag = "de_AT", .chosen = "de-AT", .shown = "de" },
        // A language the app is not written in: kept, the user's shown.
        .{ .tag = "ko", .chosen = "ko", .shown = "zh-Hans" },
        .{ .tag = "en-XA", .chosen = "en-XA", .shown = "en-XA" },
        .{ .tag = "", .chosen = "", .shown = "zh-Hans" },
    };
    for (cases) |case| {
        try choice.set(case.tag);
        try expectChosen(&choice, case.chosen);
        try std.testing.expectEqualStrings(case.shown, choice.shown(&available, &preferred).tag());
    }
    try std.testing.expectError(error.InvalidLocale, choice.set("not a tag"));
    try std.testing.expectError(error.InvalidLocale, choice.set("und"));
    try expectChosen(&choice, "");
}

test "another thread reports the choices made before it, and the last after the app is done" {
    var choice = try Choice.init(.{ .environment = .none });
    choice.start();
    try choice.set("de");
    const Reader = struct {
        fn run(c: *Choice, out: *[i18n.locale.max_tag_len]u8, len: *usize) void {
            len.* = c.chosenTag(out).len;
        }
    };
    var out: [i18n.locale.max_tag_len]u8 = undefined;
    var len: usize = 0;
    const thread = try std.Thread.spawn(.{}, Reader.run, .{ &choice, &out, &len });
    thread.join();
    try std.testing.expectEqualStrings("de", out[0..len]);
}

test "the choice is saved for the next launch, and the environment's wins for its run" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try zio.realPathAlloc(dir.dir, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const directory = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(directory);
    {
        var choice = try Choice.init(.{ .directory = directory, .environment = .none });
        choice.start();
        try choice.set("de_CH");
    }
    var data: [64]u8 = undefined;
    try std.testing.expectEqualStrings("de-CH\n", try dir.dir.readFile(zio.io(), "data/" ++ file_name, &data));
    {
        // Read on the first call, as the app starts.
        var choice = try Choice.init(.{ .directory = directory, .environment = .none });
        try expectChosen(&choice, "de-CH");
    }
    {
        var choice = try Choice.init(.{ .directory = directory, .environment = .{ .value = "ja_JP" } });
        try expectChosen(&choice, "ja-JP");
        // Before the app runs, the run's language wins.
        try choice.set("fr");
        try expectChosen(&choice, "ja-JP");
        // While it runs, set chooses another for the run, and keeps nothing.
        choice.start();
        try choice.set("");
        try expectChosen(&choice, "");
    }
    try std.testing.expectEqualStrings("de-CH\n", try dir.dir.readFile(zio.io(), "data/" ++ file_name, &data));
    {
        // Following the user's languages again removes the file.
        var choice = try Choice.init(.{ .directory = directory, .environment = .none });
        choice.start();
        try choice.set("");
        try std.testing.expectError(error.FileNotFound, dir.dir.readFile(zio.io(), "data/" ++ file_name, &data));
        var next = try Choice.init(.{ .directory = directory, .environment = .none });
        try expectChosen(&next, "");
    }
}
