const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const update = @import("ziggurat_update");
const u = @import("root.zig");

const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;

/// Records what the Updater asks of its Backend.
const Fake = struct {
    enabled: bool = true,
    checks: usize = 0,
    installs: usize = 0,
    cancels: usize = 0,
    relaunches: usize = 0,
    token: u.Token = .{ .generation = 0 },
    installing: [32]u8 = undefined,
    installing_len: usize = 0,
    fail_start: ?anyerror = null,

    fn backend(self: *Fake) u.Backend {
        return .{ .context = self, .enabled = enabledFn, .check = check, .install = install, .cancel = cancel, .relaunch = relaunch };
    }
    fn enabledFn(ptr: *anyopaque) bool {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        return self.enabled;
    }
    fn check(ptr: *anyopaque, _: *u.Updater, token: u.Token) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (self.fail_start) |err| return err;
        self.checks += 1;
        self.token = token;
    }
    fn install(ptr: *anyopaque, _: *u.Updater, token: u.Token, release: u.Release) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        self.installs += 1;
        self.token = token;
        @memcpy(self.installing[0..release.version.len], release.version);
        self.installing_len = release.version.len;
    }
    fn cancel(ptr: *anyopaque, _: u.Token) void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        self.cancels += 1;
    }
    fn relaunch(ptr: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        self.relaunches += 1;
    }
};

const Timer = struct {
    armed: ?u64 = null,
    arms: usize = 0,
    fn scheduler(self: *Timer) u.Scheduler {
        return .{ .context = self, .arm = arm, .cancel = cancel };
    }
    fn arm(ptr: *anyopaque, seconds: u64) anyerror!void {
        const self: *Timer = @ptrCast(@alignCast(ptr));
        self.armed = seconds;
        self.arms += 1;
    }
    fn cancel(ptr: *anyopaque) void {
        const self: *Timer = @ptrCast(@alignCast(ptr));
        self.armed = null;
    }
};

var fixed_now: i64 = 1_800_000_000;
fn now() i64 {
    return fixed_now;
}

const Fixture = struct {
    app: *z.App,
    fake: Fake = .{},
    timer: Timer = .{},
    updater: u.Updater = undefined,
    storage: view.Storage(160, 24 * 1024) = .{},
    harness: view.Harness = undefined,

    fn init(self: *Fixture, configured: u.Options) !void {
        self.* = .{ .app = try z.App.init(std.testing.allocator) };
        var with = configured;
        with.scheduler = self.timer.scheduler();
        with.now = now;
        self.updater = u.Updater.init(self.app, self.fake.backend(), with);
        self.harness = view.Harness.init(&self.updater, u.Updater.build, self.storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 560, .height = 440 } });
        self.updater.start();
    }
    fn deinit(self: *Fixture) void {
        self.updater.deinit();
        self.app.deinit();
    }
    fn render(self: *Fixture) !void {
        try self.harness.render();
    }
    /// Whether `text` shows, within one node or wrapped across several.
    fn has(self: *Fixture, text: []const u8) !bool {
        try self.render();
        var joined: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&joined);
        for (self.harness.nodes()) |node| if (node.kind == .text) {
            writer.writeAll(node.text) catch break;
            writer.writeByte(' ') catch break;
        };
        return std.mem.indexOf(u8, writer.buffered(), text) != null;
    }
    fn click(self: *Fixture, label: []const u8) !void {
        try self.render();
        try self.harness.click(.{ .kind = .button, .text = label });
    }
    fn settle(self: *Fixture) !void {
        try self.app.dispatch();
    }
};

const options: u.Options = .{ .app_name = "Notes", .current_version = "1.0.0.0" };

test "a check the user asks for reports that the app is up to date" {
    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    try equal(@as(?u64, 10), f.timer.armed);
    f.updater.checkForUpdates();
    try equal(u.Screen.checking, f.updater.screen);
    try expect(f.updater.window != null);
    try expect(try f.has("Checking for updates…"));
    // A second request while checking only brings the window forward.
    f.updater.checkForUpdates();
    try equal(1, f.fake.checks);
    f.updater.checkFinished(f.fake.token, .current);
    try expect(try f.has("You’re up to date"));
    try expect(try f.has("Notes 1.0.0.0 is the newest version available."));
    try equal(fixed_now, f.updater.lastCheck());
    try f.click("OK");
    try equal(u.Screen.idle, f.updater.screen);
    try expect(f.updater.window == null);
    try f.settle();
    try expect(!f.updater.closing);
    // The next check is an interval after this one.
    try equal(@as(?u64, std.time.s_per_day), f.timer.armed);
}

test "a release found in the background offers to install, downloads and offers a restart" {
    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    f.updater.timerFired();
    try expect(f.updater.window == null);
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "1.1.0.0", .notes = "Faster start.\n\nFixes a crash when saving." } });
    try equal(u.Screen.available, f.updater.screen);
    try expect(f.updater.window != null);
    try expect(try f.has("A new version of Notes is available"));
    try expect(try f.has("Notes 1.1.0.0 is available. You have 1.0.0.0."));
    try expect(try f.has("Fixes a crash when saving."));
    try equal(3, f.harness.count(.{ .kind = .button }));
    try f.harness.click(.{ .kind = .checkbox });
    try f.click("Install Update");
    try equal(1, f.fake.installs);
    try strings("1.1.0.0", f.fake.installing[0..f.fake.installing_len]);
    // The checkbox is saved as the user's choice.
    try expect(f.updater.automaticDownloads());
    try equal(u.Screen.downloading, f.updater.screen);
    f.updater.installProgress(f.fake.token, 1024 * 1024, 4 * 1024 * 1024);
    try expect(try f.has("1.0 MB of 4.0 MB"));
    try expect(f.harness.count(.{ .kind = .progress }) == 1);
    f.updater.installProgress(f.fake.token, 4 * 1024 * 1024, 4 * 1024 * 1024);
    try expect(try f.has("Installing update…"));
    // Nothing can be pressed while files are swapped in.
    try equal(0, f.harness.count(.{ .kind = .button }));
    f.updater.installFinished(f.fake.token, null);
    try expect(try f.has("Notes 1.1.0.0 is installed. It runs the next time Notes starts."));
    try f.click("Restart Now");
    try equal(1, f.fake.relaunches);
    try equal(u.Screen.idle, f.updater.screen);
    // Installed: background checks stop, and the user is offered the restart again.
    try equal(@as(?u64, null), f.timer.armed);
    f.updater.timerFired();
    try equal(1, f.fake.checks);
    f.updater.checkForUpdates();
    try equal(u.Screen.ready, f.updater.screen);
}

test "a skipped version stays quiet in the background but shows when the user asks" {
    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    f.updater.timerFired();
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "1.2.0.0" } });
    // Without notes the window keeps the status size.
    try expect(!f.updater.release_layout);
    try f.click("Skip This Version");
    try strings("1.2.0.0", f.updater.prefs.skippedVersion());
    try equal(u.Screen.idle, f.updater.screen);
    f.updater.timerFired();
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "1.2.0.0" } });
    try equal(u.Screen.idle, f.updater.screen);
    f.updater.checkForUpdates();
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "1.2.0.0" } });
    try equal(u.Screen.available, f.updater.screen);
    try f.click("Remind Me Later");
    try equal(u.Screen.idle, f.updater.screen);
    try equal(0, f.fake.installs);
}

test "automatic downloads install in the background without a window" {
    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    f.updater.setAutomaticDownloads(true);
    f.updater.timerFired();
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "2.0.0.0" } });
    try equal(1, f.fake.installs);
    try expect(f.updater.window == null);
    f.updater.installFinished(f.fake.token, null);
    try equal(u.Screen.idle, f.updater.screen);
    try expect(f.updater.window == null);
    f.updater.checkForUpdates();
    try expect(try f.has("Ready to restart"));
    try f.click("Later");
    try equal(0, f.fake.relaunches);
}

test "cancelling a download or closing the window stops the job and ignores its late result" {
    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    f.updater.checkForUpdates();
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "1.1.0.0" } });
    try f.click("Install Update");
    const stale = f.fake.token;
    try f.click("Cancel");
    try equal(1, f.fake.cancels);
    try equal(u.Screen.idle, f.updater.screen);
    f.updater.installProgress(stale, 1, 2);
    f.updater.installFinished(stale, null);
    try equal(u.Screen.idle, f.updater.screen);
    try equal(@as(usize, 0), f.updater.installed_len);

    // A window the user closes cancels like the Cancel button.
    try f.settle();
    f.updater.checkForUpdates();
    const window = f.updater.window.?;
    _ = try window.destroy();
    try f.settle();
    try equal(2, f.fake.cancels);
    try equal(u.Screen.idle, f.updater.screen);
    f.updater.checkFinished(f.fake.token, .current);
    try equal(u.Screen.idle, f.updater.screen);
}

test "failures show their cause to the user and retry sooner in the background" {
    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    f.updater.timerFired();
    f.updater.checkFinished(f.fake.token, .{ .failed = error.ConnectionRefused });
    try expect(f.updater.window == null);
    try equal(fixed_now, f.updater.failed_at);
    // Never checked successfully: retried an hour after the failure.
    try equal(@as(?u64, 3600), f.timer.armed);
    f.updater.checkForUpdates();
    f.updater.checkFinished(f.fake.token, .{ .failed = error.InvalidSignature });
    try expect(try f.has("Update failed"));
    try expect(try f.has("InvalidSignature"));
    try f.click("OK");
    // A job that cannot start fails at once.
    f.fake.fail_start = error.Busy;
    f.updater.checkForUpdates();
    try equal(u.Screen.check_failed, f.updater.screen);
    try f.click("OK");
    f.fake.fail_start = null;
    f.updater.checkForUpdates();
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "1.1.0.0" } });
    try f.click("Install Update");
    f.updater.installFinished(f.fake.token, error.DiskFull);
    try expect(try f.has("The update could not be downloaded or installed."));
}

test "builds that cannot update say so only when asked" {
    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    f.fake.enabled = false;
    f.updater.timerFired();
    try equal(0, f.fake.checks);
    f.updater.checkForUpdates();
    try expect(try f.has("Updates unavailable"));
    try f.click("OK");
}

test "automatic checks follow the user's choice and changes are announced" {
    const Counter = struct {
        count: usize = 0,
        fn changed(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
    };
    var counter: Counter = .{};
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var with = options;
    with.state_dir = temp.dir;
    with.on_change = .{ .context = &counter, .call = Counter.changed };
    var f: Fixture = undefined;
    try f.init(with);
    defer f.deinit();
    try expect(f.updater.automaticChecks());
    f.updater.setAutomaticChecks(false);
    try equal(@as(?u64, null), f.timer.armed);
    f.updater.setAutomaticChecks(false);
    try equal(1, counter.count);
    f.updater.setAutomaticChecks(true);
    try equal(@as(?u64, 10), f.timer.armed);
    try equal(2, counter.count);
    // Saved for the next run.
    try expect(u.prefs.load(temp.dir).automatic_checks.?);
}

test "the window speaks the closest shipped language and application texts" {
    var with = options;
    with.locale = "zh_CN.UTF-8";
    with.languages = &.{.{ .tag = "zh-Hans", .strings = .{ .install = "现在更新" } }};
    var f: Fixture = undefined;
    try f.init(with);
    defer f.deinit();
    try strings("检查更新…", f.updater.menuLabel());
    f.updater.checkForUpdates();
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "1.1.0.0" } });
    try expect(try f.has("Notes 有新版本可用"));
    try equal(1, f.harness.count(.{ .kind = .button, .text = "现在更新" }));
}

test "long text wraps at spaces and wide characters break anywhere" {
    try equal(@as(usize, 5), u.breakAt("hello world", 60));
    try equal(@as(usize, 11), u.breakAt("hello world", 200));
    try equal(@as(usize, 3), u.breakAt("abcdefgh", 30));
    // Three CJK characters of 16 DIP fit in 50.
    try equal(@as(usize, 9), u.breakAt("一二三四五", 50));
    try equal(@as(usize, 1), u.breakAt("w", 1));
}

test "release notes are kept within bounds at a line end" {
    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    const long = try std.testing.allocator.alloc(u8, u.max_notes + 100);
    defer std.testing.allocator.free(long);
    @memset(long, 'a');
    long[100] = '\n';
    f.updater.checkForUpdates();
    f.updater.checkFinished(f.fake.token, .{ .available = .{ .version = "1.1.0.0", .notes = long } });
    try equal(@as(usize, 100), f.updater.releaseNotes().len);
}

// ------------------------------------------------------------ FeedBackend

fn waitDone(backend: *u.FeedBackend, app: *z.App) !void {
    var spins: usize = 0;
    while (!backend.done.load(.acquire)) : (spins += 1) {
        if (spins > 5000) return error.Timeout;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try app.dispatch();
}

test "the feed backend checks a signed feed and installs into the managed root" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const identity = "org.ziggurat.UpdaterTest";
    const target = "linux-x86_64";
    const key = try update.Ed25519.KeyPair.generateDeterministic(@splat(21));
    const zip = try update.archive.buildPackage(allocator, .{ .name = "Notes", .identity = identity, .target = target, .version = .{ .major = 1, .minor = 1, .patch = 0 }, .executable = "notes" }, &.{.{ .name = "notes", .bytes = "new build" }});
    defer allocator.free(zip);
    var manifest: update.Manifest = .{ .identity = identity, .target = target, .version = .{ .major = 1, .minor = 1, .patch = 0 }, .url = "https://updates.example.invalid/notes.zip", .bytes = zip.len, .sha256 = undefined, .signature = undefined };
    std.crypto.hash.sha2.Sha256.hash(zip, &manifest.sha256, .{});
    const signed = try update.sign(allocator, manifest, key);
    defer allocator.free(signed);
    const feed = try update.feed.buildWithNotes(allocator, identity, &.{signed}, &.{}, &.{.{ .version = manifest.version, .text = "Faster start." }});
    defer allocator.free(feed);
    try temp.dir.writeFile(.{ .sub_path = "feed.json", .data = feed });
    const base = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const feed_path = try std.fs.path.join(allocator, &.{ base, "feed.json" });
    defer allocator.free(feed_path);
    const install_root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(install_root);

    var f: Fixture = undefined;
    try f.init(options);
    defer f.deinit();
    var backend = u.FeedBackend.init(allocator, f.app, .{ .feed = feed_path, .public_key = key.public_key.toBytes(), .identity = identity, .target = target, .current_version = .{ .major = 1, .minor = 0, .patch = 0 }, .install_root = install_root });
    defer backend.deinit();
    f.updater.backend = backend.backend();
    try expect(f.updater.backend.enabled(f.updater.backend.context));
    f.updater.checkForUpdates();
    try waitDone(&backend, f.app);
    try equal(u.Screen.available, f.updater.screen);
    try strings("1.1.0.0", f.updater.releaseVersion());
    try strings("Faster start.", f.updater.releaseNotes());

    // A newer release appeared between the check and the install: the
    // install refuses to fetch something other than what the user accepted.
    manifest.version.minor = 2;
    const newer = try update.sign(allocator, manifest, key);
    defer allocator.free(newer);
    const newer_feed = try update.feed.build(allocator, identity, &.{newer}, &.{});
    defer allocator.free(newer_feed);
    try temp.dir.writeFile(.{ .sub_path = "feed.json", .data = newer_feed });
    try f.click("Install Update");
    try waitDone(&backend, f.app);
    try equal(u.Screen.install_failed, f.updater.screen);
    try expect(try f.has("ReleaseChanged"));
    try f.click("OK");
    try temp.dir.writeFile(.{ .sub_path = "feed.json", .data = feed });

    // A disabled configuration never runs a job.
    var disabled = u.FeedBackend.init(allocator, f.app, .{ .feed = feed_path, .public_key = key.public_key.toBytes(), .identity = identity, .target = target, .current_version = .{ .major = 1, .minor = 1, .patch = 0 }, .install_root = install_root, .enabled = false });
    defer disabled.deinit();
    try expect(!disabled.backend().enabled(&disabled));
    // Up to date against the same feed.
    var current = u.FeedBackend.init(allocator, f.app, .{ .feed = feed_path, .public_key = key.public_key.toBytes(), .identity = identity, .target = target, .current_version = .{ .major = 1, .minor = 1, .patch = 0 }, .install_root = install_root });
    defer current.deinit();
    try f.settle();
    f.updater.backend = current.backend();
    f.updater.checkForUpdates();
    try waitDone(&current, f.app);
    try equal(u.Screen.up_to_date, f.updater.screen);
}
