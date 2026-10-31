const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);

const fixture = "<!doctype html><title>macOS fixture</title><script>chrome.webview.addEventListener('message',e=>{if(e.data==='ping')chrome.webview.postMessage('roundtrip')});</script>";

/// One page through its life: ready before the document, start, commit,
/// title and completion, JSON scripts and a script error with its native
/// code, zoom, user agent, mute, an IPC round trip, a script deadline and
/// detach of a pending script when the window closes.
/// Refuses every allocation, without recording where.
const refusing: std.mem.Allocator.VTable = .{ .alloc = std.mem.Allocator.noAlloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = std.mem.Allocator.noFree };

const Probe = struct {
    app: *z.App,
    window: z.Window,
    view: web.View = undefined,
    error_value: ?anyerror = null,
    ready: u32 = 0,
    started: u32 = 0,
    completed: u32 = 0,
    titles: u32 = 0,
    calls: u32 = 0,
    messages: u32 = 0,
    native_errors: u32 = 0,
    closed: u32 = 0,
    detached: u32 = 0,
    fn fail(self: *@This(), err: anyerror) void {
        if (self.error_value == null) self.error_value = err;
        std.debug.print("macOS WebView smoke: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn closedWindow(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        std.debug.assert(self.view.window == null);
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.ready += 1;
                std.testing.expectError(error.NavigationPending, view.refresh()) catch |err| return self.fail(err);
                std.testing.expectError(error.NotReady, view.post("not committed")) catch |err| return self.fail(err);
            },
            .message => |text| {
                self.messages += 1;
                if (!std.mem.eql(u8, text, "roundtrip")) return self.fail(error.UnexpectedMessage);
                _ = view.evaluateJS("(()=>{const until=Date.now()+80;while(Date.now()<until){};return 1})()", .{ .timeout_ms = 1 }, .{ .context = self, .complete = timeout }) catch |err| self.fail(err);
            },
            .failed => {
                std.debug.print("native failure: {any}\n", .{view.nativeFailure()});
                self.fail(error.NativeFailure);
            },
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .started => |started| {
                self.started += 1;
                if (started.uri == null or !std.mem.eql(u8, started.uri.?, "about:blank")) return self.fail(error.WrongStartUri);
            },
            .title_changed => |changed| {
                if (changed.title) |title| if (std.mem.eql(u8, title, "macOS fixture")) {
                    self.titles += 1;
                };
            },
            .completed => |completed| {
                self.completed += 1;
                if (!completed.success) return self.fail(error.LoadFailed);
                _ = view.evaluateJS("({value:42,text:'你好',title:document.title})", .{}, .{ .context = self, .complete = script }) catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn script(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (value != .json) return self.fail(error.MissingJson);
        if (self.calls == 1) {
            if (!std.mem.eql(u8, value.json, "{\"value\":42,\"text\":\"你好\",\"title\":\"macOS fixture\"}")) {
                std.debug.print("json {s}\n", .{value.json});
                return self.fail(error.WrongJson);
            }
            _ = self.view.evaluateJS("6*7", .{}, .{ .context = self, .complete = script }) catch |err| self.fail(err);
        } else if (self.calls == 2) {
            if (!std.mem.eql(u8, value.json, "42")) return self.fail(error.WrongJson);
            self.settings() catch |err| return self.fail(err);
            _ = self.view.evaluateJS("throw new Error('controlled failure')", .{}, .{ .context = self, .complete = scriptError }) catch |err| self.fail(err);
        } else self.fail(error.DuplicateCompletion);
    }
    fn settings(self: *@This()) !void {
        try self.view.setZoom(1.25);
        try std.testing.expectEqual(@as(f64, 1.25), try self.view.zoom());
        try self.view.setUserAgent("Ziggurat macOS smoke");
        const agent = try self.view.userAgent(self.view.allocator);
        defer self.view.allocator.free(agent);
        try std.testing.expectEqualStrings("Ziggurat macOS smoke", agent);
        // Not std.testing.FailingAllocator: it records a stack trace on
        // failure, and that walk panics through WebKit frames on Zig 0.17.
        try std.testing.expectError(error.OutOfMemory, self.view.userAgent(std.mem.Allocator{ .ptr = undefined, .vtable = &refusing }));
        try std.testing.expect(!(try self.view.audioMuted()));
        try self.view.setAudioMuted(true);
        try std.testing.expect(try self.view.audioMuted());
        try self.view.setAudioMuted(false);
        try std.testing.expect(!(try self.view.audioMuted()));
        try std.testing.expect(!(try self.view.isAudible()));
    }
    fn scriptError(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .native_failure) return self.fail(error.MissingNativeError);
        const failure = self.view.nativeFailure() orelse return self.fail(error.MissingFailureDomain);
        if (failure != .glib or failure.glib.domain == 0 or failure.glib.code != result.native_failure) return self.fail(error.WrongFailureDomain);
        self.native_errors += 1;
        self.view.postFor(self.view.pageId().?, "ping") catch |err| self.fail(err);
    }
    fn timeout(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .timed_out) return self.fail(error.WrongTimeoutReason);
        _ = self.view.evaluateJS("42", .{ .timeout_ms = 5000 }, .{ .context = self, .complete = closing }) catch |err| {
            // The logically cancelled native operation still owns its slot
            // until its engine completion. Shutdown must be safe either way.
            if (err != error.Full) return self.fail(err);
        };
        _ = self.window.destroy() catch |err| return self.fail(err);
        self.app.quit();
    }
    fn closing(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .detached) return self.fail(error.WrongDetachReason);
        self.detached += 1;
    }
};
fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app, .window = undefined };
    probe.window = try app.createWindow(.{ .width = 320, .height = 200, .on_closed = .{ .context = &probe, .notify = Probe.closedWindow } });
    probe.view = web.View.init(allocator, &probe, Probe.event);
    try std.testing.expectError(error.UnsupportedCapability, probe.view.attach(probe.window, .{ .html = "", .user_data_folder = "/tmp/never" }));
    try std.testing.expectError(error.UnsupportedCapability, probe.view.attach(probe.window, .{ .html = "", .storage = .ephemeral, .tools = .{ .find = true } }));
    try std.testing.expect(probe.view.window == null);
    try probe.view.attach(probe.window, .{ .html = fixture, .storage = .ephemeral, .scripts = .{ .max_pending = 1 }, .page_listener = .{ .context = &probe, .event = Probe.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired);
    if (probe.error_value) |err| return err;
    std.testing.expect(probe.ready == 1 and probe.started == 1 and probe.completed == 1 and probe.titles >= 1 and probe.calls == 2 and probe.messages == 1 and probe.native_errors == 1 and probe.closed == 1) catch |err| {
        std.debug.print("ready {} started {} completed {} titles {} calls {} messages {} errors {} closed {}\n", .{ probe.ready, probe.started, probe.completed, probe.titles, probe.calls, probe.messages, probe.native_errors, probe.closed });
        return err;
    };
}
fn attachAllocationFailure(view_allocator: std.mem.Allocator, core_allocator: std.mem.Allocator) !void {
    const app = try z.App.init(core_allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var marker: u8 = 0;
    var view = web.View.init(view_allocator, &marker, struct {
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {
            @panic("closed-before-initialization callback");
        }
    }.event);
    view.attach(window, .{ .html = "<title>allocation rollback</title>", .storage = .ephemeral, .user_agent = "owned metadata" }) catch |err| {
        try std.testing.expect(view.window == null and view.native == null and view.config == null and view.attachment_phase == .detached);
        return err;
    };
    _ = try window.destroy();
    try std.testing.expect(view.window == null and view.native == null and view.config == null);
}
fn closeBeforeReady(allocator: std.mem.Allocator) !void {
    const Early = struct {
        allocator: std.mem.Allocator,
        count: *u32,
        view: web.View = undefined,
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {
            @panic("late callback entered freed owner");
        }
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.view.window == null);
            self.count.* += 1;
            self.allocator.destroy(self);
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var count: u32 = 0;
    const owner = try allocator.create(Early);
    owner.* = .{ .allocator = allocator, .count = &count };
    owner.view = web.View.init(allocator, owner, Early.event);
    const window = try app.createWindow(.{ .on_closed = .{ .context = owner, .notify = Early.closed } });
    try owner.view.attach(window, .{ .html = "<title>never started</title>", .storage = .ephemeral });
    try std.testing.expectEqual(z.CloseResult.closed, try window.destroy());
    try std.testing.expect(count == 1 and app.resourceStats().allocated_records == 0);
}
/// reload replaces the document with a new generation: old globals are gone
/// and posts to the old page are stale.
fn reload(allocator: std.mem.Allocator) !void {
    const State = struct {
        app: *z.App,
        window: z.Window,
        view: web.View = undefined,
        old: ?web.PageId = null,
        calls: u32 = 0,
        ready: u32 = 0,
        releases: u32 = 0,
        err: ?anyerror = null,
        fn options(self: *@This()) web.Options {
            return .{ .html = "<title>replacement fixture</title>", .storage = .ephemeral, .page_listener = .{ .context = self, .event = page } };
        }
        fn fail(self: *@This(), err: anyerror) void {
            if (self.err == null) self.err = err;
            std.debug.print("macOS replacement: {s}\n", .{@errorName(err)});
            self.app.quit();
        }
        fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (value) {
                .ready => self.ready += 1,
                .resources_released => self.releases += 1,
                .process_failed => self.fail(error.UnexpectedProcessFailure),
                .failed => self.fail(error.UnexpectedNativeFailure),
                else => {},
            }
        }
        fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (value != .completed) return;
            if (!value.completed.success) return self.fail(error.ReplacementLoadFailed);
            if (self.old == null) self.old = view.pageId();
            _ = view.evaluateJS(if (self.calls == 0) "globalThis.saved=7;7" else "typeof saved", .{}, .{ .context = self, .complete = complete }) catch |err| self.fail(err);
        }
        fn complete(ptr: *anyopaque, value: web.ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (value != .json) return self.fail(error.ReplacementScriptFailed);
            self.calls += 1;
            if (self.calls == 1) {
                if (!std.mem.eql(u8, value.json, "7")) return self.fail(error.BadInitialScript);
                return self.view.reload(self.options()) catch |err| self.fail(err);
            } else if (self.calls == 2) {
                if (!std.mem.eql(u8, value.json, "\"undefined\"")) return self.fail(error.OldDocumentSurvived);
                std.testing.expectError(error.StalePage, self.view.postFor(self.old.?, "old generation")) catch |err| return self.fail(err);
                _ = self.window.destroy() catch |err| return self.fail(err);
                self.app.quit();
            } else self.fail(error.DuplicateReplacement);
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .window = try app.createWindow(.{}) };
    state.view = web.View.init(allocator, &state, State.event);
    try state.view.attach(state.window, state.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired);
    if (state.err) |err| return err;
    try std.testing.expect(state.calls == 2 and state.ready == 2 and state.releases == 1);
}
/// Engine completions of closed pages still arrive after close; waits for
/// them and the pages' native records to drain.
const Drain = struct {
    app: *z.App,
    ticks: u32 = 0,
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const counts = web.resourceCounts();
        if (counts.states == 0 and counts.handlers == 0 and counts.controllers == 0) return self.app.quit();
        self.ticks += 1;
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (!web.backendCapabilities().page_lifecycle) return error.SkipZigTest;
    std.debug.print("macOS WebView: {s}\n", .{"allocation failures"});
    try std.testing.checkAllAllocationFailures(allocator.allocator(), attachAllocationFailure, .{allocator.allocator()});
    std.debug.print("macOS WebView: {s}\n", .{"close before ready"});
    try closeBeforeReady(allocator.allocator());
    std.debug.print("macOS WebView: {s}\n", .{"page"});
    try run(allocator.allocator());
    std.debug.print("macOS WebView: {s}\n", .{"reload"});
    try reload(allocator.allocator());
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var drain: Drain = .{ .app = app };
    try app.post(.{ .context = &drain, .call = Drain.tick });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired);
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, web.resourceCounts());
    std.debug.print("macOS WebView: OOM/early-free, events, IPC, scripts and errors, zoom/UA/mute, deadline, detach, reload, native records=0\n", .{});
}
