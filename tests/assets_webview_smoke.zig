const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const assets = @import("ziggurat_assets");
const Watchdog = @import("watchdog.zig").Watchdog;

const first_html = "<!doctype html><body data-version=one><script>fetch('/data.txt').then(r=>r.text()).then(text=>chrome.webview.postMessage(document.body.dataset.version+':'+text))</script>";
const second_html = "<!doctype html><body data-version=two><script>fetch('/data.txt').then(r=>r.text()).then(text=>chrome.webview.postMessage(document.body.dataset.version+':'+text))</script>";

const Loaded = struct {
    snapshot: assets.Snapshot,
    table: []web.Resource,
    fn load(allocator: std.mem.Allocator, directory: std.Io.Dir) !*Loaded {
        var snapshot = try assets.Snapshot.load(allocator, directory, .{});
        errdefer snapshot.deinit();
        const table = try snapshot.resourceTable(web.Resource, allocator, "/index.html");
        errdefer allocator.free(table);
        const self = try allocator.create(Loaded);
        self.* = .{ .snapshot = snapshot, .table = table };
        return self;
    }
    fn destroy(self: *Loaded, allocator: std.mem.Allocator) void {
        allocator.free(self.table);
        self.snapshot.deinit();
        allocator.destroy(self);
    }
    fn options(self: *const Loaded, profile: []const u8) web.Options {
        return .{ .html = self.snapshot.find("/index.html").?.bytes, .user_data_folder = profile, .local = .{ .resources = self.table } };
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    view: *web.View,
    directory: std.Io.Dir,
    profile: []const u8,
    watcher: *assets.DirectoryWatch,
    watch_token: z.NativeWaitToken = undefined,
    current: *Loaded,
    pending: ?*Loaded = null,
    read_result: ?*Loaded = null,
    read_error: ?anyerror = null,
    worker_post_failed: std.atomic.Value(bool) = .init(false),
    writer_failed: std.atomic.Value(bool) = .init(false),
    write_done: zio.ResetEvent = .{},
    worker: ?std.Thread = null,
    writer: ?std.Thread = null,
    ready_count: usize = 0,
    message_count: usize = 0,
    released_count: usize = 0,
    watch_count: usize = 0,
    tasks: usize = 0,
    failed: bool = false,

    fn fail(self: *State, err: anyerror) void {
        std.debug.print("asset update failed: {s}\n", .{@errorName(err)});
        self.failed = true;
        self.app.quit();
    }
    fn noop(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.tasks += 1;
    }
    fn writeChanged(self: *State) void {
        defer self.write_done.set();
        var atomic = zio.AtomicFile.init(self.directory, "index.html", .{ .write_buffer = &.{} }) catch {
            self.writer_failed.store(true, .release);
            return;
        };
        defer atomic.deinit();
        atomic.file_writer.interface.writeAll(second_html) catch {
            self.writer_failed.store(true, .release);
            return;
        };
        atomic.finish() catch self.writer_failed.store(true, .release);
    }
    fn changed(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.watch_count += 1;
        self.watcher.rearm() catch |err| return self.fail(err);
        self.watch_token = self.app.watchNative(self.watcher.nativeHandle() catch unreachable, .{ .context = self, .call = changed }) catch |err| return self.fail(err);
        // This test edits once. A production caller coalesces notices while its
        // explicit worker runs and rescans once more if changes arrived meanwhile.
        if (self.worker != null) return;
        self.worker = std.Thread.spawn(.{}, readChanged, .{self}) catch |err| return self.fail(err);
    }
    fn readChanged(self: *State) void {
        self.write_done.wait();
        self.read_result = Loaded.load(self.allocator, self.directory) catch |err| blk: {
            self.read_error = err;
            break :blk null;
        };
        self.app.post(.{ .context = self, .call = applyChanged }) catch {
            if (self.read_result) |loaded| loaded.destroy(self.allocator);
            self.read_result = null;
            self.worker_post_failed.store(true, .release);
        };
    }
    fn applyChanged(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.read_error) |err| return self.fail(err);
        const loaded = self.read_result orelse return self.fail(error.NoSnapshot);
        self.read_result = null;
        if (self.current.snapshot.sameContent(&loaded.snapshot)) {
            loaded.destroy(self.allocator);
            return self.fail(error.UnchangedSnapshot);
        }
        self.view.reload(loaded.options(self.profile)) catch |err| {
            loaded.destroy(self.allocator);
            return self.fail(err);
        };
        self.pending = loaded;
        std.testing.expectError(error.RecoveryInProgress, self.view.reload(loaded.options(self.profile))) catch |err| return self.fail(err);
        std.testing.expectError(error.RecoveryInProgress, self.view.recover()) catch |err| return self.fail(err);
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => self.ready_count += 1,
            .resources_released => {
                const previous = self.current;
                self.current = self.pending orelse return self.fail(error.NoPendingSnapshot);
                self.pending = null;
                // Native close cleared old callbacks before this notification.
                previous.destroy(self.allocator);
                self.released_count += 1;
            },
            .message => |message| {
                self.message_count += 1;
                if (self.message_count == 1) {
                    std.testing.expectEqualStrings("one:memory-resource", message) catch |err| return self.fail(err);
                    var invalid = self.current.options(self.profile);
                    invalid.local.?.host = "invalid/host";
                    std.testing.expectError(error.InvalidLocalHost, view.reload(invalid)) catch |err| return self.fail(err);
                    const owner_allocator = view.allocator;
                    var failing = std.testing.FailingAllocator.init(owner_allocator, .{ .fail_index = 0 });
                    view.allocator = failing.allocator();
                    const failed_allocation = view.reload(self.current.options(self.profile));
                    view.allocator = owner_allocator;
                    std.testing.expectError(error.OutOfMemory, failed_allocation) catch |err| return self.fail(err);
                    for (0..256) |_| self.app.post(.{ .context = self, .call = noop }) catch |err| return self.fail(err);
                    std.testing.expectError(error.Full, view.reload(self.current.options(self.profile))) catch |err| return self.fail(err);
                    if (!view.ready or view.recovering or view.pending_config != null) return self.fail(error.ReloadWasNotTransactional);
                    self.writer = std.Thread.spawn(.{}, writeChanged, .{self}) catch |err| return self.fail(err);
                } else {
                    std.testing.expectEqualStrings("two:memory-resource", message) catch |err| return self.fail(err);
                    if (self.ready_count != 2 or self.released_count != 1 or self.message_count != 2) return self.fail(error.ReloadOrder);
                    _ = view.window.?.destroy() catch |err| return self.fail(err);
                }
            },
            .failed, .process_failed => self.fail(error.NativeFailed),
            .policy_request => self.fail(error.UnexpectedPolicy),
        }
    }
};

fn queuedReloadClose(allocator: std.mem.Allocator, profile: []const u8) !void {
    const Probe = struct {
        app: *z.App,
        ready: usize = 0,
        released: usize = 0,
        messages: usize = 0,
        failed: bool = false,
        fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (value) {
                .ready => self.ready += 1,
                .resources_released => self.released += 1,
                .message => |message| {
                    if (!std.mem.eql(u8, message, "reused-ok")) self.failed = true;
                    self.messages += 1;
                    _ = view.window.?.destroy() catch {
                        self.app.quit();
                        return;
                    };
                },
                .failed, .process_failed => {
                    self.failed = true;
                    self.app.quit();
                },
                .policy_request => {},
            }
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app };
    var view = web.View.init(allocator, &probe, Probe.event);
    const old = try app.createWindow(.{});
    const options: web.Options = .{ .html = "<script>chrome.webview.postMessage('reused-ok')</script>", .user_data_folder = profile, .local = .{} };
    try view.attach(old, options);
    try view.reload(options);
    _ = try old.destroy();
    // The queued task retains native state, not the reusable View address.
    const replacement = try app.createWindow(.{});
    try view.attach(replacement, options);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and !probe.failed);
    try std.testing.expectEqual(1, probe.ready);
    try std.testing.expectEqual(1, probe.messages);
    try std.testing.expectEqual(0, probe.released);
    try std.testing.expectEqual(@as(u32, 0), web.resourceCounts().states);
    try std.testing.expectEqual(@as(u32, 0), web.resourceCounts().handlers);
    try std.testing.expectEqual(@as(u32, 0), web.resourceCounts().controllers);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "AssetsSmoke" });
    defer allocator.free(profile);
    const queued_profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "AssetsQueueSmoke" });
    defer allocator.free(queued_profile);
    try queuedReloadClose(allocator, queued_profile);
    var temporary = zio.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(zio.io(), .{ .sub_path = "index.html", .data = first_html });
    try temporary.dir.writeFile(zio.io(), .{ .sub_path = "data.txt", .data = "memory-resource" });
    const absolute = try zio.realPathAlloc(temporary.dir, ".", allocator);
    defer allocator.free(absolute);
    var watcher = try assets.DirectoryWatch.init(allocator, absolute, null);
    defer watcher.deinit();
    const app = try z.App.init(allocator);
    var app_owned = true;
    defer if (app_owned) app.deinit();
    const current = try Loaded.load(allocator, temporary.dir);
    var view = web.View.init(allocator, undefined, State.event);
    var state: State = .{ .allocator = allocator, .app = app, .view = &view, .directory = temporary.dir, .profile = profile, .watcher = &watcher, .current = current };
    defer {
        // Any accepted App.post has run before run returns; all producers are
        // joined before App.deinit and before their shared storage is freed.
        if (state.writer) |thread| thread.join();
        if (state.worker) |thread| thread.join();
        app.deinit();
        app_owned = false;
        if (state.pending) |loaded| loaded.destroy(allocator);
        if (state.read_result) |loaded| loaded.destroy(allocator);
        state.current.destroy(allocator);
    }
    view.context = &state;
    const window = try app.createWindow(.{});
    try view.attach(window, current.options(profile));
    state.watch_token = try app.watchNative(try watcher.nativeHandle(), .{ .context = &state, .call = State.changed });
    defer _ = app.unwatchNative(state.watch_token);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.writer) |thread| thread.join();
    state.writer = null;
    if (state.worker) |thread| thread.join();
    state.worker = null;
    try std.testing.expect(!watchdog.expired and !state.failed);
    try std.testing.expect(!state.worker_post_failed.load(.acquire) and !state.writer_failed.load(.acquire));
    try std.testing.expect(state.watch_count != 0);
    try std.testing.expectEqual(256, state.tasks);
    try std.testing.expectEqual(2, state.ready_count);
    try std.testing.expectEqual(2, state.message_count);
    try std.testing.expectEqual(1, state.released_count);
    try std.testing.expectEqual(@as(u32, 0), web.resourceCounts().states);
    try std.testing.expectEqual(@as(u32, 0), web.resourceCounts().handlers);
    try std.testing.expectEqual(@as(u32, 0), web.resourceCounts().controllers);
    std.debug.print("asset WebView smoke passed: real directory notification -> worker snapshot -> posted reload -> updated DOM; invalid/OOM/Full rollback; old snapshot released; queued close/reuse; COM=0\n", .{});
}
