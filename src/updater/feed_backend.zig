//! A Backend over the signed feeds of `ziggurat_update`: a check reads the
//! feed and verifies the newest release for this target; an install fetches
//! its signed delta from the retained archive when the feed has one, falls
//! back to the full archive, and publishes it into the managed install root
//! beside the running release. Each job runs on a worker thread this backend
//! starts for it and joins once the job has reported back, so the main
//! thread never waits on the network or the disk.
const std = @import("std");
const z = @import("ziggurat");
const update = @import("ziggurat_update");
const root = @import("root.zig");

pub const Config = struct {
    /// An https:// URL, such as a GitHub release's
    /// `https://github.com/OWNER/NAME/releases/latest/download/feed.json`,
    /// or a local file for tests.
    feed: []const u8,
    public_key: [32]u8,
    identity: []const u8,
    target: []const u8,
    current_version: update.Version,
    /// The managed install root that holds current.json and releases/.
    install_root: []const u8,
    /// False for builds that must not update themselves, such as
    /// development builds or an installation a package manager owns.
    enabled: bool = true,
};

/// Keep at a stable address from init() until deinit(), which must run
/// after `App.run` returns so every posted completion has executed.
pub const FeedBackend = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    config: Config,
    writable: bool,
    thread: ?std.Thread = null,
    /// Set by the worker as its last step.
    done: std.atomic.Value(bool) = .init(true),
    control: update.download.Control = .{},
    updater: ?*root.Updater = null,
    token: root.Token = .{ .generation = 0 },
    job: enum { check, install } = .check,
    /// Release to install, copied by `install`.
    version: update.Version = .{ .major = 0, .minor = 0, .patch = 0 },
    /// Worker results, read on the main thread by the posted tasks.
    mutex: std.Thread.Mutex = .{},
    outcome: Outcome = .none,
    progress: ?update.download.Progress = null,
    progress_posted: bool = false,
    version_text: [root.max_version]u8 = undefined,
    version_len: usize = 0,
    notes: []u8 = &.{},
    relaunch_requested: bool = false,

    const Outcome = union(enum) { none, current, available, failed: anyerror, installed };

    pub fn init(allocator: std.mem.Allocator, app: *z.App, config: Config) FeedBackend {
        return .{ .allocator = allocator, .app = app, .config = config, .writable = probe(config.install_root) };
    }

    /// Cancels and joins a job still running.
    pub fn deinit(self: *FeedBackend) void {
        self.control.cancel();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.allocator.free(self.notes);
        self.notes = &.{};
    }

    pub fn backend(self: *FeedBackend) root.Backend {
        return .{ .context = self, .enabled = enabled, .check = check, .install = install, .cancel = cancel, .relaunch = relaunch };
    }

    /// After `App.run` returned: starts the published release when the user
    /// chose to restart into it. Returns whether it started one.
    pub fn relaunchIfRequested(self: *FeedBackend, argv_tail: []const []const u8) !bool {
        if (!self.relaunch_requested) return false;
        const executable = try update.launch.currentExecutable(self.allocator, self.config.install_root, self.config.identity, self.config.target);
        defer self.allocator.free(executable);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, executable);
        try argv.appendSlice(self.allocator, argv_tail);
        try update.launch.spawnDetached(self.allocator, argv.items, std.fs.path.dirname(executable));
        return true;
    }

    fn probe(path: []const u8) bool {
        var dir = std.fs.cwd().makeOpenPath(path, .{}) catch return false;
        defer dir.close();
        var file = dir.createFile(".ziggurat-update-probe", .{}) catch return false;
        file.close();
        dir.deleteFile(".ziggurat-update-probe") catch {};
        return true;
    }

    fn enabled(ptr: *anyopaque) bool {
        const self: *FeedBackend = @ptrCast(@alignCast(ptr));
        return self.config.enabled and self.writable;
    }

    /// Joins the previous worker, which has already reported back.
    fn ready(self: *FeedBackend) !void {
        if (!self.done.load(.acquire)) return error.Busy;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.control = .{ .context = self, .on_progress = reportProgress };
        self.outcome = .none;
        self.progress = null;
        self.progress_posted = false;
    }

    fn check(ptr: *anyopaque, updater: *root.Updater, token: root.Token) anyerror!void {
        const self: *FeedBackend = @ptrCast(@alignCast(ptr));
        try self.ready();
        self.updater = updater;
        self.token = token;
        self.job = .check;
        self.done.store(false, .release);
        self.thread = std.Thread.spawn(.{}, runCheck, .{self}) catch |err| {
            self.done.store(true, .release);
            return err;
        };
    }

    fn install(ptr: *anyopaque, updater: *root.Updater, token: root.Token, release: root.Release) anyerror!void {
        const self: *FeedBackend = @ptrCast(@alignCast(ptr));
        try self.ready();
        self.version = try update.retention.parseVersion(release.version);
        self.updater = updater;
        self.token = token;
        self.job = .install;
        self.done.store(false, .release);
        self.thread = std.Thread.spawn(.{}, runInstall, .{self}) catch |err| {
            self.done.store(true, .release);
            return err;
        };
    }

    fn cancel(ptr: *anyopaque, _: root.Token) void {
        const self: *FeedBackend = @ptrCast(@alignCast(ptr));
        self.control.cancel();
    }

    fn relaunch(ptr: *anyopaque) void {
        const self: *FeedBackend = @ptrCast(@alignCast(ptr));
        self.relaunch_requested = true;
        _ = self.app.requestQuit();
    }

    // ------------------------------------------------------------ worker

    fn runCheck(self: *FeedBackend) void {
        const outcome: Outcome = self.checkFeed() catch |err| .{ .failed = err };
        self.finish(outcome);
    }

    fn runInstall(self: *FeedBackend) void {
        const outcome: Outcome = if (self.fetch()) .installed else |err| .{ .failed = err };
        self.finish(outcome);
    }

    fn policy(self: *FeedBackend) update.Policy {
        return .{ .identity = self.config.identity, .target = self.config.target, .current_version = self.config.current_version, .public_key = self.config.public_key };
    }

    fn readFeed(self: *FeedBackend, allocator: std.mem.Allocator, client: *std.http.Client) ![]u8 {
        if (std.mem.startsWith(u8, self.config.feed, "https://")) return update.http.get(allocator, client, self.config.feed, update.feed.max_feed_bytes);
        return std.fs.cwd().readFileAlloc(allocator, self.config.feed, update.feed.max_feed_bytes);
    }

    fn checkFeed(self: *FeedBackend) !Outcome {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();
        const bytes = try self.readFeed(allocator, &client);
        if (self.control.isCancelled()) return error.Cancelled;
        const result = try update.feed.check(allocator, bytes, self.policy(), null);
        defer result.deinit();
        const available = switch (result) {
            .current => return .current,
            .available => |value| value,
        };
        const version = available.full.manifest.version;
        const text = try std.fmt.bufPrint(&self.version_text, "{d}.{d}.{d}.{d}", .{ version.major, version.minor, version.patch, version.revision });
        const notes = update.feed.notesFor(self.allocator, bytes, version) catch try self.allocator.dupe(u8, "");
        self.mutex.lock();
        defer self.mutex.unlock();
        self.version_len = text.len;
        self.allocator.free(self.notes);
        self.notes = notes;
        return .available;
    }

    fn fetch(self: *FeedBackend) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var install_root = try std.fs.cwd().makeOpenPath(self.config.install_root, .{ .iterate = true, .no_follow = true });
        defer install_root.close();
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();
        var current = self.policy();
        var retained: ?update.retention.Retained = null;
        defer if (retained) |value| value.file.close();
        if (update.publication.readCurrent(allocator, install_root, self.config.identity, self.config.target)) |published| {
            if (published.version.order(current.current_version) == .gt) current.current_version = published.version;
            retained = update.retention.currentArchive(allocator, install_root, self.config.identity, self.config.target) catch null;
        } else |err| if (err != error.FileNotFound) return err;
        const bytes = try self.readFeed(allocator, &client);
        const result = try update.feed.check(allocator, bytes, current, if (retained) |value| .{ .sha256 = value.sha256 } else null);
        defer result.deinit();
        const available = switch (result) {
            // Another process already published this version.
            .current => return,
            .available => |value| value,
        };
        if (available.full.manifest.version.order(self.version) != .eq) return error.ReleaseChanged;
        var downloads = try install_root.makeOpenPath("downloads", .{ .no_follow = true });
        defer downloads.close();
        var http_source: update.http.Source = .init(&client);
        const v = self.version;
        const archive_name = try std.fmt.allocPrint(allocator, "{s}-{d}.{d}.{d}.{d}.zip", .{ self.config.target, v.major, v.minor, v.patch, v.revision });
        var archive = try downloads.createFile(archive_name, .{ .read = true, .truncate = false });
        defer archive.close();
        var rebuilt = false;
        if (available.delta) |patch| delta: {
            const patch_name = try std.fmt.allocPrint(allocator, "{s}.patch", .{archive_name});
            var patch_file = try downloads.createFile(patch_name, .{ .read = true, .truncate = false });
            defer patch_file.close();
            defer downloads.deleteFile(patch_name) catch {};
            _ = update.download.fetch(patch.manifest.artifact(), http_source.source(), patch_file, &self.control) catch |err| {
                if (err == error.Cancelled) return err;
                break :delta;
            };
            try archive.setEndPos(0);
            var buffer: [16 * 1024]u8 = undefined;
            var writer = archive.writer(&buffer);
            update.delta.applyVerified(&patch, available.full.manifest, retained.?.file, patch_file, &writer.interface, .{}) catch {
                try archive.setEndPos(0);
                break :delta;
            };
            rebuilt = true;
        }
        if (!rebuilt) _ = try update.download.fetch(available.full.manifest, http_source.source(), archive, &self.control);
        if (self.control.isCancelled()) return error.Cancelled;
        self.post(.{ .received = available.full.manifest.bytes, .total = available.full.manifest.bytes });
        _ = try update.publication.publishZip(allocator, install_root, archive, &available.full, .{ .retain_archive = true });
        downloads.deleteFile(archive_name) catch {};
    }

    fn reportProgress(ptr: ?*anyopaque, progress: update.download.Progress) void {
        const self: *FeedBackend = @ptrCast(@alignCast(ptr.?));
        // Completion is reported once the archive is verified.
        if (progress.received >= progress.total) return;
        self.post(progress);
    }

    /// Coalesces progress: at most one progress task is queued, and it
    /// reads the newest value. A full queue drops the intermediate value.
    fn post(self: *FeedBackend, progress: update.download.Progress) void {
        self.mutex.lock();
        self.progress = progress;
        const queued = self.progress_posted;
        self.progress_posted = true;
        self.mutex.unlock();
        if (queued) return;
        self.app.post(.{ .context = self, .call = deliverProgress }) catch {
            self.mutex.lock();
            self.progress_posted = false;
            self.mutex.unlock();
        };
    }

    /// The final report must arrive: a full queue is retried from this
    /// worker, never from the main thread. A closed App drops it.
    fn finish(self: *FeedBackend, outcome: Outcome) void {
        self.mutex.lock();
        self.outcome = outcome;
        self.mutex.unlock();
        while (true) {
            self.app.post(.{ .context = self, .call = deliverOutcome }) catch |err| switch (err) {
                error.Full => {
                    std.Thread.sleep(2 * std.time.ns_per_ms);
                    continue;
                },
                else => {},
            };
            break;
        }
        self.done.store(true, .release);
    }

    // ------------------------------------------------------- main thread

    fn deliverProgress(ptr: *anyopaque) void {
        const self: *FeedBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        const progress = self.progress;
        self.progress_posted = false;
        self.mutex.unlock();
        const updater = self.updater orelse return;
        if (progress) |value| updater.installProgress(self.token, value.received, value.total);
    }

    fn deliverOutcome(ptr: *anyopaque) void {
        const self: *FeedBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        const outcome = self.outcome;
        self.mutex.unlock();
        const updater = self.updater orelse return;
        switch (outcome) {
            .none => {},
            .current => updater.checkFinished(self.token, .current),
            .available => updater.checkFinished(self.token, .{ .available = .{ .version = self.version_text[0..self.version_len], .notes = self.notes } }),
            .failed => |err| switch (err) {
                // Cancelled jobs report nothing; the Updater already moved on.
                error.Cancelled => {},
                else => switch (self.job) {
                    .check => updater.checkFinished(self.token, .{ .failed = err }),
                    .install => updater.installFinished(self.token, err),
                },
            },
            .installed => updater.installFinished(self.token, null),
        }
    }
};
