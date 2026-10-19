const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn zlg_resource_count() u32;
extern fn zlg_content_count() c_uint;
extern fn gtk_widget_destroy(*anyopaque) void;

const Probe = struct {
    app: *z.App,
    window: z.Window,
    view: web.View = undefined,
    error_value: ?anyerror = null,
    ready: u32 = 0,
    started: u32 = 0,
    completed: u32 = 0,
    calls: u32 = 0,
    messages: u32 = 0,
    native_errors: u32 = 0,
    closed: u32 = 0,
    detached: u32 = 0,
    raw_close: bool = false,
    fn fail(self: *@This(), err: anyerror) void {
        self.error_value = err;
        std.debug.print("Linux WebView smoke: {s}\n", .{@errorName(err)});
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
                if (self.raw_close) {
                    gtk_widget_destroy(self.window.nativeHandle().?);
                    self.app.quit();
                } else {
                    _ = view.evaluateJS("(()=>{const until=Date.now()+80;while(Date.now()<until){};return 1})()", .{ .timeout_ms = 1 }, .{ .context = self, .complete = timeout }) catch |err| self.fail(err);
                }
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
            .started => self.started += 1,
            .completed => |completed| {
                self.completed += 1;
                if (!completed.success) return self.fail(error.LoadFailed);
                _ = view.evaluateJS("({value:42,text:'你好'})", .{}, .{ .context = self, .complete = script }) catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn script(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (value != .json) return self.fail(error.MissingJson);
        if (self.calls == 1) {
            if (!std.mem.eql(u8, value.json, "{\"value\":42,\"text\":\"你好\"}")) return self.fail(error.WrongJson);
            _ = self.view.evaluateJS("6*7", .{}, .{ .context = self, .complete = script }) catch |err| self.fail(err);
        } else if (self.calls == 2) {
            self.view.setZoom(1.25) catch |err| return self.fail(err);
            const zoom = self.view.zoom() catch |err| return self.fail(err);
            if (zoom != 1.25) return self.fail(error.WrongZoom);
            self.view.setUserAgent("Ziggurat Linux smoke") catch |err| return self.fail(err);
            const agent = self.view.userAgent(self.view.allocator) catch |err| return self.fail(err);
            defer self.view.allocator.free(agent);
            if (!std.mem.eql(u8, agent, "Ziggurat Linux smoke")) return self.fail(error.WrongUserAgent);
            var fault = std.testing.FailingAllocator.init(self.view.allocator, .{ .fail_index = 0 });
            std.testing.expectError(error.OutOfMemory, self.view.userAgent(fault.allocator())) catch |err| return self.fail(err);
            self.devTools() catch |err| return self.fail(err);
            _ = self.view.evaluateJS("throw new Error('controlled failure')", .{}, .{ .context = self, .complete = scriptError }) catch |err| self.fail(err);
        } else self.fail(error.DuplicateCompletion);
    }
    fn devTools(self: *@This()) !void {
        try std.testing.expect(!(try self.view.devToolsEnabled()));
        try std.testing.expectError(error.DevToolsDisabled, self.view.openDevTools());
        try self.view.setDevToolsEnabled(true);
        try std.testing.expect(try self.view.devToolsEnabled());
        try self.view.openDevTools();
        try self.view.openDevTools();
        try std.testing.expectEqual(@as(u32, 1), web.devToolsResourceCount());
        try self.view.setDevToolsEnabled(false);
        try std.testing.expectEqual(@as(u32, 0), web.devToolsResourceCount());
        try std.testing.expectError(error.DevToolsDisabled, self.view.openDevTools());
        // Left shown on purpose: detach must close the engine-owned inspector.
        try self.view.setDevToolsEnabled(true);
        try self.view.openDevTools();
        try std.testing.expectEqual(@as(u32, 1), web.devToolsResourceCount());
    }
    fn scriptError(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .native_failure) return self.fail(error.MissingNativeError);
        const failure = self.view.nativeFailure() orelse return self.fail(error.MissingFailureDomain);
        if (failure != .glib or failure.glib.domain == 0 or failure.glib.code != result.native_failure or self.view.last_hresult != 0) return self.fail(error.WrongFailureDomain);
        self.native_errors += 1;
        self.view.postFor(self.view.pageId().?, "ping") catch |err| self.fail(err);
    }
    fn timeout(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .timed_out) return self.fail(error.WrongTimeoutReason);
        _ = self.view.evaluateJS("42", .{ .timeout_ms = 5000 }, .{ .context = self, .complete = closing }) catch |err| {
            // The logically cancelled native operation still owns its physical
            // slot until its async completion. Shutdown must remain safe either way.
            if (err != error.Full) return self.fail(err);
        };
        self.app.quit();
    }
    fn closing(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .detached) return self.fail(error.WrongDetachReason);
        self.detached += 1;
    }
};
fn run(allocator: std.mem.Allocator, raw_close: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app, .window = undefined, .raw_close = raw_close };
    probe.window = try app.createWindow(.{ .width = 320, .height = 200, .on_closed = .{ .context = &probe, .notify = Probe.closedWindow } });
    probe.view = web.View.init(allocator, &probe, Probe.event);
    try std.testing.expectError(error.ProfileRequired, probe.view.attach(probe.window, .{ .html = "" }));
    try std.testing.expect(probe.view.window == null);
    try probe.view.attach(probe.window, .{ .html = "<!doctype html><title>Linux fixture</title><script>chrome.webview.addEventListener('message',e=>{if(e.data==='ping')chrome.webview.postMessage('roundtrip')});</script>", .storage = .ephemeral, .scripts = .{ .max_pending = 1 }, .page_listener = .{ .context = &probe, .event = Probe.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired);
    if (probe.error_value) |err| return err;
    try std.testing.expect(probe.ready == 1 and probe.started == 1 and probe.completed == 1 and probe.calls == 2 and probe.messages == 1 and probe.native_errors == 1 and probe.closed == 1);
    try std.testing.expect(app.resourceStats().allocated_records == 0);
}
const Drain = struct {
    app: *z.App,
    timer: c_uint = 0,
    fn tick(ptr: *anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const counts = web.resourceCounts();
        if (counts.states != 0 or counts.handlers != 0 or counts.controllers != 0) return 1;
        const local = web.customLocalResourceCounts();
        if (local.budgets != 0 or local.streams != 0 or local.body_bytes != 0) return 1;
        self.timer = 0;
        self.app.quit();
        return 0;
    }
};
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
fn reloadAndRecover(allocator: std.mem.Allocator, recover_process: bool) !void {
    const State = struct {
        app: *z.App,
        window: z.Window,
        view: web.View = undefined,
        recovering: bool,
        old: ?web.PageId = null,
        calls: u32 = 0,
        ready: u32 = 0,
        releases: u32 = 0,
        failures: u32 = 0,
        err: ?anyerror = null,
        fn options(self: *@This()) web.Options {
            return .{ .html = "<title>replacement fixture</title>", .storage = .ephemeral, .page_listener = .{ .context = self, .event = page } };
        }
        fn fail(self: *@This(), err: anyerror) void {
            self.err = err;
            std.debug.print("Linux replacement recover={}: {s}\n", .{ self.recovering, @errorName(err) });
            self.app.quit();
        }
        fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (value) {
                .ready => self.ready += 1,
                .resources_released => self.releases += 1,
                .process_failed => {
                    self.failures += 1;
                    if (!self.recovering or self.failures != 1) return self.fail(error.UnexpectedProcessFailure);
                    view.recover() catch |err| self.fail(err);
                },
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
                self.view.setDevToolsEnabled(true) catch |err| return self.fail(err);
                self.view.openDevTools() catch |err| return self.fail(err);
                if (!self.recovering) return self.view.reload(self.options()) catch |err| self.fail(err);
                @import("linux_webview_process.zig").stop(self.window) catch |err| self.fail(err);
            } else if (self.calls == 2) {
                if (!std.mem.eql(u8, value.json, "\"undefined\"")) return self.fail(error.OldDocumentSurvived);
                // recover keeps the explicit override; reload applies new Options.
                const enabled = self.view.devToolsEnabled() catch |err| return self.fail(err);
                if (enabled != self.recovering or web.devToolsResourceCount() != 0) return self.fail(error.WrongDevToolsReplacement);
                std.testing.expectError(error.StalePage, self.view.postFor(self.old.?, "old generation")) catch |err| return self.fail(err);
                _ = self.window.destroy() catch |err| return self.fail(err);
                self.app.quit();
            } else self.fail(error.DuplicateReplacement);
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .window = try app.createWindow(.{}), .recovering = recover_process };
    state.view = web.View.init(allocator, &state, State.event);
    try state.view.attach(state.window, state.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired);
    if (state.err) |err| return err;
    try std.testing.expect(state.calls == 2 and state.ready == 2 and state.releases == @as(u32, if (recover_process) 0 else 1) and state.failures == @as(u32, if (recover_process) 1 else 0));
}
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    try std.testing.checkAllAllocationFailures(allocator.allocator(), attachAllocationFailure, .{allocator.allocator()});
    try closeBeforeReady(allocator.allocator());
    try run(allocator.allocator(), false);
    try run(allocator.allocator(), true);
    try std.testing.expectEqual(@as(u32, 0), web.devToolsResourceCount());
    try reloadAndRecover(allocator.allocator(), false);
    try reloadAndRecover(allocator.allocator(), true);
    try @import("linux_custom_webview_smoke.zig").runAll(allocator.allocator());
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var drain: Drain = .{ .app = app };
    drain.timer = g_timeout_add(10, Drain.tick, &drain);
    defer if (drain.timer != 0) {
        _ = g_source_remove(drain.timer);
    };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and zlg_content_count() == 0);
    const counts = web.resourceCounts();
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, counts);
    try std.testing.expectEqualDeep(web.custom_local.ResourceCounts{ .budgets = 0, .streams = 0, .body_bytes = 0 }, web.customLocalResourceCounts());
    // App's dispatcher/main-loop/context remain until its explicit deinit.
    try std.testing.expect(zlg_resource_count() == 4);
    std.debug.print("Linux WebView: OOM/early-free, 4 Apps, IPC/scripts/GLib errors/DevTools/deadline/raw-close/reload/recover, native resources=0\n", .{});
}
