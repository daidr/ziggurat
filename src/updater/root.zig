//! The update window: checks for a newer version in the background, shows it
//! with its release notes and offers to install it, skip it or be reminded
//! later; downloads it with a progress bar that can be cancelled, then offers
//! to restart into it. A check the user asks for, from a "Check for Updates"
//! menu item, shows the window at once and also reports that the app is up to
//! date, that the check failed, or that this build cannot update itself.
//!
//! Everything here runs on the App's main thread. Network and disk work
//! belongs to a `Backend`, which starts it and reports back through
//! `checkFinished`, `installProgress` and `installFinished` on the main
//! thread; `FeedBackend` does it with the signed feeds of `ziggurat_update`
//! on a worker thread it starts per job. Automatic checks are timed by a
//! `Scheduler`, such as `WakeScheduler`.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
pub const strings = @import("strings.zig");
pub const prefs = @import("prefs.zig");
pub const FeedBackend = @import("feed_backend.zig").FeedBackend;
pub const WakeScheduler = @import("wake_scheduler.zig").WakeScheduler;
pub const Strings = strings.Strings;
pub const Language = strings.Language;

test {
    _ = strings;
    _ = prefs;
    _ = @import("tests.zig");
}

/// Longest release notes kept, in bytes; longer notes are cut at a line.
pub const max_notes = 16 * 1024;
pub const max_detail = 256;
pub const max_version = prefs.max_version;

/// A newer version a check found. Copied by `checkFinished`.
pub const Release = struct {
    version: []const u8,
    /// Plain text; blank lines separate paragraphs.
    notes: []const u8 = "",
};

/// Names one job a Backend runs. Completions with an older token are
/// ignored, so a cancelled job can still finish without harm.
pub const Token = struct { generation: u64 };

pub const CheckResult = union(enum) {
    current,
    available: Release,
    failed: anyerror,
};

/// The work behind the window. Every function is called on the main thread;
/// `check` and `install` start work and return without waiting for it.
pub const Backend = struct {
    context: *anyopaque,
    /// Whether this build can update itself: built with an update feed and
    /// able to write where it is installed.
    enabled: *const fn (*anyopaque) bool,
    /// Completes once with `Updater.checkFinished(token, ...)`.
    check: *const fn (*anyopaque, *Updater, Token) anyerror!void,
    /// Reports `Updater.installProgress` and completes once with
    /// `Updater.installFinished`. The release is borrowed during the call.
    install: *const fn (*anyopaque, *Updater, Token, Release) anyerror!void,
    /// Asks the job to stop; its completion may still arrive and is ignored.
    cancel: *const fn (*anyopaque, Token) void,
    /// Starts the installed version, typically by quitting the App and
    /// launching it once `App.run` returns.
    relaunch: *const fn (*anyopaque) void,
};

/// Times automatic checks: `arm` replaces any earlier deadline with one
/// `seconds` from now, after which the host calls `Updater.timerFired`.
pub const Scheduler = struct {
    context: *anyopaque,
    arm: *const fn (*anyopaque, u64) anyerror!void,
    cancel: *const fn (*anyopaque) void,
};

pub const Options = struct {
    app_name: []const u8,
    current_version: []const u8,
    /// BCP 47 tag or POSIX locale of the window's language; texts follow
    /// the closest shipped language, then `languages`, then English.
    locale: []const u8 = "en",
    /// Application texts by language, overriding or adding to the shipped
    /// ones. Must outlive the Updater.
    languages: []const Language = &.{},
    /// Seconds between automatic checks.
    interval: u64 = std.time.s_per_day,
    /// Seconds after start() before the first automatic check, so a version
    /// released since the last run shows soon after launch.
    first_check_delay: u64 = 10,
    /// Default for the user's automatic-check choice until one is saved.
    automatic_checks: bool = true,
    /// Where updater.json is kept; null keeps choices for this run only.
    /// Borrowed until deinit.
    state_dir: ?std.fs.Dir = null,
    scheduler: ?Scheduler = null,
    /// Epoch seconds; replaced by tests.
    now: *const fn () i64 = defaultNow,
    /// Called after a saved choice or the last-check time changed, for a
    /// preferences page that shows them.
    on_change: ?z.Task = null,
};

fn defaultNow() i64 {
    return std.time.timestamp();
}

pub const Screen = enum { idle, unavailable, checking, up_to_date, check_failed, available, downloading, installing, install_failed, ready };

const Job = enum { none, check, install };

/// Window sizes in DIP: status screens and the release screen with notes.
pub const Size = struct { width: u32, height: u32 };
pub const status_size: Size = .{ .width = 440, .height = 190 };
pub const release_size: Size = .{ .width = 560, .height = 440 };

/// Keep at a stable address from start() until deinit(). Main thread only.
pub const Updater = struct {
    app: *z.App,
    backend: Backend,
    options: Options,
    text: Strings,
    prefs: prefs.Prefs = .{},
    started: bool = false,
    /// Epoch seconds of the last failed automatic check; 0 after a success.
    failed_at: i64 = 0,
    launch_checked: bool = false,

    screen: Screen = .idle,
    /// The user asked for this session: the window shows from the start.
    user: bool = false,
    shown: bool = false,
    job: Job = .none,
    generation: u64 = 0,
    version: [max_version]u8 = undefined,
    version_len: usize = 0,
    notes: [max_notes]u8 = undefined,
    notes_len: usize = 0,
    detail: [max_detail]u8 = undefined,
    detail_len: usize = 0,
    received: u64 = 0,
    total: u64 = 0,
    /// The checkbox of the release screen.
    automatic_choice: bool = false,
    /// A version installed during this run, which runs at the next launch.
    installed: [max_version]u8 = undefined,
    installed_len: usize = 0,

    window: ?z.Window = null,
    /// A window was destroyed and its on_closed has not run yet.
    closing: bool = false,
    /// Show the window once the previous one has closed.
    reopen: bool = false,
    host: view.Host = undefined,
    storage: view.Storage(160, 24 * 1024) = .{},
    notes_scroll: view.ScrollModel = .{},
    /// The size the window was given, release or status.
    release_layout: bool = false,
    last_error: ?anyerror = null,

    pub fn init(app: *z.App, backend: Backend, options: Options) Updater {
        return .{ .app = app, .backend = backend, .options = options, .text = strings.resolve(options.locale, options.languages) };
    }

    /// Reads the saved choices and schedules automatic checks.
    pub fn start(self: *Updater) void {
        self.app.assertOwner();
        if (self.options.state_dir) |dir| self.prefs = prefs.load(dir);
        self.started = true;
        self.schedule();
    }

    /// Ends any session and closes its window; a running job is cancelled.
    pub fn deinit(self: *Updater) void {
        self.started = false;
        if (self.options.scheduler) |scheduler| scheduler.cancel(scheduler.context);
        self.finish();
    }

    /// The label of a "Check for Updates" menu item in the window's language.
    pub fn menuLabel(self: *const Updater) []const u8 {
        return self.text.menu_item;
    }

    /// A check the user asked for: the window shows at once and reports the
    /// outcome, and shows versions the user skipped. During a check already
    /// under way, its window comes forward instead.
    pub fn checkForUpdates(self: *Updater) void {
        self.begin(true);
    }

    /// The Scheduler's deadline passed: check in the background.
    pub fn timerFired(self: *Updater) void {
        self.begin(false);
    }

    pub fn automaticChecks(self: *const Updater) bool {
        return self.prefs.automatic_checks orelse self.options.automatic_checks;
    }
    pub fn setAutomaticChecks(self: *Updater, on: bool) void {
        var next = self.prefs;
        next.automatic_checks = on;
        self.store(next);
        self.schedule();
    }
    /// Whether updates found in the background install without asking.
    pub fn automaticDownloads(self: *const Updater) bool {
        return self.prefs.automatic_downloads;
    }
    pub fn setAutomaticDownloads(self: *Updater, on: bool) void {
        var next = self.prefs;
        next.automatic_downloads = on;
        self.store(next);
    }
    /// Epoch seconds of the last successful check, or 0.
    pub fn lastCheck(self: *const Updater) i64 {
        return self.prefs.last_check;
    }
    pub fn currentToken(self: *const Updater) ?Token {
        return if (self.job == .none) null else .{ .generation = self.generation };
    }
    pub fn releaseVersion(self: *const Updater) []const u8 {
        return self.version[0..self.version_len];
    }
    pub fn releaseNotes(self: *const Updater) []const u8 {
        return self.notes[0..self.notes_len];
    }

    fn begin(self: *Updater, user: bool) void {
        self.app.assertOwner();
        if (self.screen != .idle) {
            if (user) {
                self.user = true;
                self.show();
            }
            return;
        }
        if (!user and self.installed_len != 0) return;
        if (self.options.scheduler) |scheduler| scheduler.cancel(scheduler.context);
        self.user = user;
        self.shown = false;
        self.launch_checked = true;
        if (!self.backend.enabled(self.backend.context)) {
            if (!user) return self.finish();
            self.set(.unavailable);
            return self.show();
        }
        if (self.installed_len != 0) {
            @memcpy(self.version[0..self.installed_len], self.installed[0..self.installed_len]);
            self.version_len = self.installed_len;
            self.set(.ready);
            return self.show();
        }
        self.set(.checking);
        if (user) self.show();
        self.startJob(.check);
        self.backend.check(self.backend.context, self, .{ .generation = self.generation }) catch |err| {
            self.job = .none;
            self.checkFailed(err);
        };
    }

    fn startJob(self: *Updater, job: Job) void {
        self.generation += 1;
        self.job = job;
    }
    fn live(self: *const Updater, token: Token, job: Job) bool {
        return self.job == job and token.generation == self.generation;
    }

    /// The Backend's answer to `check`. Stale tokens are ignored.
    pub fn checkFinished(self: *Updater, token: Token, result: CheckResult) void {
        self.app.assertOwner();
        if (!self.live(token, .check)) return;
        self.job = .none;
        switch (result) {
            .failed => |err| self.checkFailed(err),
            .current => {
                self.succeeded();
                if (!self.user) return self.finish();
                self.set(.up_to_date);
                self.show();
            },
            .available => |release| {
                self.succeeded();
                self.keepRelease(release);
                const skipped = std.mem.eql(u8, self.prefs.skippedVersion(), self.releaseVersion());
                if (!self.user) {
                    if (skipped) return self.finish();
                    if (self.prefs.automatic_downloads) return self.install();
                }
                self.automatic_choice = self.prefs.automatic_downloads;
                self.notes_scroll = .{};
                self.set(.available);
                self.show();
            },
        }
    }

    fn checkFailed(self: *Updater, err: anyerror) void {
        self.failed_at = self.options.now();
        if (!self.user) return self.finish();
        self.keepDetail(err);
        self.set(.check_failed);
        self.show();
    }
    fn succeeded(self: *Updater) void {
        self.failed_at = 0;
        var next = self.prefs;
        next.last_check = self.options.now();
        self.store(next);
    }

    /// Bytes of the current download; `received == total` means the
    /// download is complete and installation runs.
    pub fn installProgress(self: *Updater, token: Token, received: u64, total: u64) void {
        self.app.assertOwner();
        if (!self.live(token, .install)) return;
        self.received = @min(received, total);
        self.total = total;
        self.set(if (total != 0 and received >= total) .installing else .downloading);
    }

    /// The Backend's answer to `install`; null reports success.
    pub fn installFinished(self: *Updater, token: Token, failure: ?anyerror) void {
        self.app.assertOwner();
        if (!self.live(token, .install)) return;
        self.job = .none;
        if (failure) |err| {
            if (!self.user and !self.shown) return self.finish();
            self.keepDetail(err);
            self.set(.install_failed);
            return self.show();
        }
        @memcpy(self.installed[0..self.version_len], self.version[0..self.version_len]);
        self.installed_len = self.version_len;
        if (!self.user and !self.shown) return self.finish();
        self.set(.ready);
        self.show();
    }

    fn install(self: *Updater) void {
        self.received = 0;
        self.total = 0;
        self.set(.downloading);
        self.startJob(.install);
        self.backend.install(self.backend.context, self, .{ .generation = self.generation }, .{ .version = self.releaseVersion(), .notes = self.releaseNotes() }) catch |err| {
            self.installFinished(.{ .generation = self.generation }, err);
        };
    }

    pub const Action = enum { ok, cancel, skip, remind_later, install, later, relaunch };

    /// What a button of the current screen does; the window's buttons call
    /// it, and so can an application that draws its own.
    pub fn respond(self: *Updater, action: Action) void {
        self.app.assertOwner();
        switch (self.screen) {
            .idle => return,
            .checking, .downloading => if (action != .cancel) return,
            .installing => return,
            .available => if (action != .skip and action != .remind_later and action != .install) return,
            .ready => if (action != .later and action != .relaunch) return,
            .unavailable, .up_to_date, .check_failed, .install_failed => if (action != .ok) return,
        }
        switch (action) {
            .ok, .later => self.finish(),
            .cancel => self.finish(),
            .skip, .remind_later, .install => {
                var next = self.prefs;
                next.automatic_downloads = self.automatic_choice;
                if (action == .skip) next.setSkipped(self.releaseVersion());
                self.store(next);
                if (action == .install) self.install() else self.finish();
            },
            .relaunch => {
                self.backend.relaunch(self.backend.context);
                self.finish();
            },
        }
    }

    /// Ends the session: cancels its job, closes its window and schedules
    /// the next automatic check.
    fn finish(self: *Updater) void {
        if (self.job != .none) {
            self.backend.cancel(self.backend.context, .{ .generation = self.generation });
            self.job = .none;
            // A late completion of the cancelled job finds a newer generation.
            self.generation += 1;
        }
        self.screen = .idle;
        self.user = false;
        self.shown = false;
        self.reopen = false;
        if (self.window) |window| {
            self.window = null;
            self.closing = true;
            _ = window.destroy() catch |err| {
                self.last_error = err;
            };
        }
        self.schedule();
    }

    fn schedule(self: *Updater) void {
        const scheduler = self.options.scheduler orelse return;
        if (!self.started or self.screen != .idle or self.installed_len != 0 or !self.automaticChecks() or !self.backend.enabled(self.backend.context)) {
            scheduler.cancel(scheduler.context);
            return;
        }
        scheduler.arm(scheduler.context, self.nextDelay()) catch |err| {
            self.last_error = err;
        };
    }

    /// Seconds until the next automatic check is due.
    pub fn nextDelay(self: *const Updater) u64 {
        const first = self.options.first_check_delay;
        if (!self.launch_checked) return first;
        const now = self.options.now();
        const due = prefs.nextCheck(self.prefs.last_check, self.failed_at, @intCast(self.options.interval), now);
        return @max(first, @as(u64, @intCast(@max(due - now, 0))));
    }

    fn store(self: *Updater, next: prefs.Prefs) void {
        if (next.eql(&self.prefs)) return;
        self.prefs = next;
        if (self.options.state_dir) |dir| prefs.save(dir, &self.prefs) catch |err| {
            self.last_error = err;
        };
        if (self.options.on_change) |task| task.call(task.context);
    }

    fn keepRelease(self: *Updater, release: Release) void {
        self.version_len = @min(release.version.len, max_version);
        @memcpy(self.version[0..self.version_len], release.version[0..self.version_len]);
        var notes = release.notes;
        if (notes.len > max_notes) {
            notes = notes[0..max_notes];
            // Cut at a line end, else at a character boundary.
            if (std.mem.lastIndexOfScalar(u8, notes, '\n')) |line| notes = notes[0..line] else {
                var end = notes.len;
                while (end > 0 and (notes[end - 1] & 0xc0) == 0x80) end -= 1;
                notes = notes[0..if (end > 0) end - 1 else 0];
            }
        }
        if (!std.unicode.utf8ValidateSlice(notes)) notes = "";
        @memcpy(self.notes[0..notes.len], notes);
        self.notes_len = notes.len;
    }
    fn keepDetail(self: *Updater, err: anyerror) void {
        const name = @errorName(err);
        self.detail_len = @min(name.len, max_detail);
        @memcpy(self.detail[0..self.detail_len], name[0..self.detail_len]);
    }

    fn set(self: *Updater, screen: Screen) void {
        self.screen = screen;
        if (self.window) |window| {
            const release = screen == .available and self.notes_len != 0;
            if (release != self.release_layout) {
                self.release_layout = release;
                const size = if (release) release_size else status_size;
                window.resize(size.width, size.height) catch |err| {
                    self.last_error = err;
                };
            }
            window.invalidate();
        }
    }

    /// Shows the window, creating it on first use, and brings it forward
    /// when the user asked for the session.
    fn show(self: *Updater) void {
        if (self.screen == .idle) return;
        self.shown = true;
        if (self.window) |window| {
            if (self.user) window.perform(.focus) catch {};
            return;
        }
        if (self.closing) {
            self.reopen = true;
            return;
        }
        self.open() catch |err| {
            self.last_error = err;
            // Without a window nobody can answer; end the session.
            self.finish();
        };
    }

    fn open(self: *Updater) !void {
        self.release_layout = self.screen == .available and self.notes_len != 0;
        const size = if (self.release_layout) release_size else status_size;
        self.host = view.Host.init(self, build, self.storage.buffers(), .{ .root = .{ .padding = view.Insets.all(20), .gap = 10, .alignment = .stretch } });
        // The pure test backend has no native window for UI Automation.
        if (builtin.is_test) self.host.context.semantics_enabled = false;
        const window = try self.app.createWindow(.{
            .title = self.text.title,
            .width = size.width,
            .height = size.height,
            .resizable = false,
            .on_closed = .{ .context = self, .notify = closed },
        });
        self.host.attach(window) catch |err| {
            _ = window.destroy() catch {};
            self.closing = true;
            return err;
        };
        self.window = window;
        window.show();
    }

    fn closed(ptr: *anyopaque, window: z.Window) void {
        const self: *Updater = @ptrCast(@alignCast(ptr));
        if (self.window) |current| if (std.meta.eql(current, window)) {
            // Closed by the user: the same as cancelling or dismissing.
            self.window = null;
            self.finish();
            return;
        };
        self.closing = false;
        if (self.reopen) {
            self.reopen = false;
            self.show();
        }
    }

    // ---------------------------------------------------------------- view

    fn format(self: *const Updater, buffer: []u8, template: []const u8) []const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        var downloaded: [32]u8 = undefined;
        var total: [32]u8 = undefined;
        const arguments = [_]strings.Argument{
            .{ .name = "app", .value = self.options.app_name },
            .{ .name = "version", .value = self.releaseVersion() },
            .{ .name = "current", .value = self.options.current_version },
            .{ .name = "downloaded", .value = strings.megabytes(&downloaded, self.received, self.text.decimal) catch "" },
            .{ .name = "total", .value = strings.megabytes(&total, self.total, self.text.decimal) catch "" },
        };
        strings.render(&writer, template, &arguments) catch {};
        return writer.buffered();
    }

    const Button = struct { label: []const u8 = "", action: Action = .ok };
    const Content = struct {
        title: []const u8,
        message: []const u8 = "",
        detail: []const u8 = "",
        bar: ?f32 = null,
        /// In display order; the last is the default.
        buttons: [3]Button = .{ .{}, .{}, .{} },
        count: usize = 0,

        fn with(self: Content, buttons: []const Button) Content {
            var result = self;
            for (buttons, 0..) |item, index| result.buttons[index] = item;
            result.count = buttons.len;
            return result;
        }
    };

    fn content(self: *const Updater, title_buffer: []u8, message_buffer: []u8) ?Content {
        const t = &self.text;
        const ok = [_]Button{.{ .label = t.ok, .action = .ok }};
        const cancel = [_]Button{.{ .label = t.cancel, .action = .cancel }};
        return switch (self.screen) {
            .idle => null,
            .checking => (Content{ .title = t.checking }).with(&cancel),
            .up_to_date => (Content{ .title = t.up_to_date, .message = self.format(message_buffer, t.up_to_date_message) }).with(&ok),
            .unavailable => (Content{ .title = t.unavailable, .message = self.format(message_buffer, t.unavailable_message) }).with(&ok),
            .check_failed => (Content{ .title = t.failed, .message = t.check_failed, .detail = self.detail[0..self.detail_len] }).with(&ok),
            .install_failed => (Content{ .title = t.failed, .message = t.install_failed, .detail = self.detail[0..self.detail_len] }).with(&ok),
            .available => (Content{ .title = self.format(title_buffer, t.available), .message = self.format(message_buffer, t.available_message) }).with(&.{
                .{ .label = t.skip, .action = .skip },
                .{ .label = t.remind_later, .action = .remind_later },
                .{ .label = t.install, .action = .install },
            }),
            .downloading => (Content{
                .title = t.downloading,
                .message = if (self.total != 0) self.format(message_buffer, t.progress) else "",
                .bar = if (self.total != 0) @floatCast(@as(f64, @floatFromInt(self.received)) / @as(f64, @floatFromInt(self.total))) else 0,
            }).with(&cancel),
            .installing => Content{ .title = t.installing, .bar = 1 },
            .ready => (Content{ .title = t.ready, .message = self.format(message_buffer, t.ready_message) }).with(&.{
                .{ .label = t.later, .action = .later },
                .{ .label = t.relaunch, .action = .relaunch },
            }),
        };
    }

    /// The window's view, for a Host or a test Harness.
    pub fn build(self: *Updater, v: *view.View) anyerror!void {
        var title_buffer: [512]u8 = undefined;
        var message_buffer: [1024]u8 = undefined;
        const shown = self.content(&title_buffer, &message_buffer) orelse return;
        const t = &self.text;
        const width: f32 = @floatFromInt((if (self.release_layout) release_size else status_size).width - 40);
        try v.text(shown.title, .{});
        if (shown.message.len != 0) try wrapped(v, shown.message, width, .{});
        if (shown.detail.len != 0) try v.text(shown.detail, .{ .color = 0x7b8794 });
        if (shown.bar) |fraction| try v.progress(fraction, .{ .self_align = .stretch, .name = shown.title });
        if (self.screen == .available) {
            if (self.notes_len != 0) {
                try v.text(t.release_notes, .{});
                try v.scroll(&self.notes_scroll, .{ .grow = 1, .padding = view.Insets.all(8), .border = 0xcbd2d9, .radius = 4, .name = t.release_notes });
                try wrapped(v, self.releaseNotes(), width - 24, .{});
                try v.end();
            } else try v.spacer(.{});
            _ = try v.checkbox(&self.automatic_choice, t.automatic_downloads, .{});
        } else try v.spacer(.{});
        try v.row(.{ .gap = 8, .alignment = .center });
        // With three choices, the one that dismisses for good sits apart.
        var first: usize = 0;
        var pressed: ?Action = null;
        if (shown.count == 3) {
            if (try v.button(shown.buttons[0].label, .{})) pressed = shown.buttons[0].action;
            first = 1;
        }
        try v.spacer(.{});
        for (shown.buttons[first..shown.count]) |item| {
            if (try v.button(item.label, .{ .min_width = 88 })) pressed = item.action;
        }
        try v.end();
        // After the tree is complete: a response can close the window.
        if (pressed) |action| self.respond(action);
    }
};

/// Emits `text` as lines that fit `width` by the view's estimate: blank
/// lines separate paragraphs, words break at spaces and wide characters
/// break anywhere.
pub fn wrapped(v: *view.View, text: []const u8, width: f32, style: view.Style) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r ");
        if (line.len == 0) {
            try v.spacer(.{ .height = 6, .grow = 0 });
            continue;
        }
        var start: usize = 0;
        while (start < line.len) {
            const end = breakAt(line[start..], width);
            try v.text(std.mem.trim(u8, line[start..][0..end], " "), style);
            start += end;
            while (start < line.len and line[start] == ' ') start += 1;
        }
    }
}

/// Bytes of `text` that fit `width`, at least one character.
pub fn breakAt(text: []const u8, width: f32) usize {
    var used: f32 = 0;
    var last_space: ?usize = null;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + length, text.len);
        const codepoint = std.unicode.utf8Decode(text[index..end]) catch 0xfffd;
        const advance: f32 = if (codepoint >= 0x1100) 16 else 9;
        if (used + advance > width and index > 0) {
            if (codepoint == ' ') return index;
            if (last_space) |space| return space;
            return index;
        }
        if (codepoint == ' ') last_space = index;
        used += advance;
        index = end;
    }
    return text.len;
}
