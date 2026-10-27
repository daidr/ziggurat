const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

const root_html =
    \\<!doctype html><meta charset="utf-8"><title>Root 文档</title><script>
    \\chrome.webview.addEventListener('message', e => {
    \\ if(e.data === 'probe-denied') location.href='/denied';
    \\ else if(e.data === 'probe-auto') location.href='/two';
    \\ else chrome.webview.postMessage(e.data);
    \\});
    \\chrome.webview.postMessage('boot');
    \\</script>
;
const second_html =
    \\<!doctype html><meta charset="utf-8"><title>Second 文档</title><script>
    \\chrome.webview.addEventListener('message', e => chrome.webview.postMessage(e.data));
    \\chrome.webview.postMessage('boot');
    \\</script>
;
const resources: []const web.Resource = &.{.{ .path = "/two", .mime = "text/html; charset=utf-8", .bytes = second_html }};

const State = struct {
    app: ?*z.App = null,
    view: *web.View = undefined,
    step: u8 = 0,
    generation: u64 = 0,
    previous: ?web.PageId = null,
    current: ?web.PageId = null,
    boot: bool = false,
    completed: bool = false,
    dom: bool = false,
    title: bool = false,
    source: bool = false,
    queued: bool = false,
    denied: bool = false,
    done: bool = false,
    failed: bool = false,
    allocation_fault: *std.testing.FailingAllocator = undefined,
    metadata_faults: usize = 0,
    missing_started_uri: bool = false,
    allow_scripts: bool = false,

    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.operation != .utf8 or value.err == null or value.err.? != error.OutOfMemory) return self.fail(error.UnexpectedDiagnostic);
        self.metadata_faults += 1;
        self.allocation_fault.fail_index = std.math.maxInt(usize);
    }

    fn fail(self: *State, err: anyerror) void {
        std.debug.print("page smoke step={d}: {s}\n", .{ self.step, @errorName(err) });
        self.failed = true;
        if (self.app) |app| app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                if (view.pageId() != null) return self.fail(error.PrematurePageId);
                if (self.previous) |old| {
                    view.postFor(old, "stale") catch |err| {
                        if (err != error.StalePage) self.fail(err);
                        return;
                    };
                    self.fail(error.StalePageAccepted);
                }
            },
            .message => |text| {
                if (std.mem.eql(u8, text, "boot")) self.boot = true else return self.fail(error.UnexpectedMessage);
                self.check();
            },
            .policy_request => |request| {
                if (self.step != 0 or request.kind != .navigation or !std.mem.endsWith(u8, request.uri, "/denied")) {
                    std.debug.print("policy kind={s} uri={s} detail={d}\n", .{ @tagName(request.kind), request.uri, request.native_detail });
                    return self.fail(error.UnexpectedPolicy);
                }
                self.denied = true;
                self.check();
            },
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .started => |start| {
                if (start.uri == null) self.missing_started_uri = true;
                if (start.redirected or start.id.generation <= self.generation) return self.fail(error.InvalidGeneration);
                self.generation = start.id.generation;
                self.current = start.id;
                self.boot = false;
                self.completed = false;
                self.dom = false;
                self.title = false;
                self.source = false;
                if (!view.loading) return self.fail(error.LoadingMissing);
                if (self.previous) |old| {
                    view.postFor(old, "stale") catch |err| {
                        if (err != error.StalePage) self.fail(err);
                        if (self.step == 5) self.close(view);
                        return;
                    };
                    return self.fail(error.StalePageAccepted);
                }
                if (self.step == 5) self.close(view);
            },
            .completed => |result| {
                if (!result.success or result.id.generation != self.generation or view.loading) return self.fail(error.LoadFailed);
                self.completed = true;
            },
            .dom_ready => |id| {
                if (id.generation != self.generation) return self.fail(error.StaleDom);
                self.dom = true;
            },
            .source_changed => |change| {
                if (!std.mem.startsWith(u8, change.uri orelse return self.fail(error.MissingSource), "https://app.ziggurat.invalid/")) return self.fail(error.InvalidSource);
                self.source = true;
            },
            .title_changed => |change| {
                const expected = if (self.step == 0 or self.step == 2) "Root 文档" else "Second 文档";
                if (std.mem.eql(u8, change.title orelse return self.fail(error.MissingTitle), expected)) self.title = true;
            },
            .history_changed, .audible_changed => {},
        }
        self.check();
    }
    fn close(self: *State, view: *web.View) void {
        self.done = true;
        const result = view.window.?.destroy() catch |err| return self.fail(err);
        if (result != .deferred or view.window == null) self.fail(error.CloseNotPinned);
    }
    fn check(self: *State) void {
        if (self.failed or self.done or self.queued or !self.completed or !self.boot or !self.dom or !self.title or !self.source) return;
        if (!self.allow_scripts) {
            if (self.step > 0 and !self.view.can_go_back and self.step != 2) return;
            if (self.step == 2 and !self.view.can_go_forward) return;
        }
        self.queued = true;
        self.app.?.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const view = self.view;
        self.queued = false;
        if (self.allow_scripts and self.step == 1) return self.close(view);
        if (self.step == 0 and self.allow_scripts) {
            self.previous = self.current;
            self.step = 1;
            view.postFor(self.current.?, "probe-auto") catch |err| self.fail(err);
            return;
        }
        if (self.step == 0 and !self.denied) {
            view.navigateLocal("/../escape") catch |err| {
                if (err != error.InvalidResourcePath) return self.fail(err);
                view.post("probe-denied") catch |post_err| self.fail(post_err);
                return;
            };
            return self.fail(error.InvalidPathAccepted);
        }
        self.previous = self.current;
        self.step += 1;
        switch (self.step) {
            1 => view.navigateLocal("/two") catch |err| self.fail(err),
            2 => view.goBack() catch |err| self.fail(err),
            3 => view.goForward() catch |err| self.fail(err),
            4 => view.refresh() catch |err| self.fail(err),
            5 => {
                view.stop() catch |err| return self.fail(err);
                view.navigateLocal("/") catch |err| self.fail(err);
            },
            else => self.fail(error.InvalidStep),
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const local = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PageSmoke" });
    defer allocator.free(profile);
    var state: State = .{};
    var allocation_fault = std.testing.FailingAllocator.init(allocator, .{});
    var view = web.View.init(allocation_fault.allocator(), &state, State.event);
    var previous: ?web.PageId = null;
    var generation: u64 = 0;
    for (0..3) |cycle| {
        state.app = null;
        const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
        defer app.deinit();
        state = .{ .app = app, .view = &view, .previous = previous, .generation = generation, .allocation_fault = &allocation_fault, .allow_scripts = cycle == 2 };
        const window = try app.createWindow(.{});
        try view.attach(window, .{
            .html = root_html,
            .user_data_folder = profile,
            .local = .{ .resources = resources },
            .policy = .{ .navigation = .notify },
            .page_listener = .{ .context = &state, .event = State.page },
            .allow_local_navigation = state.allow_scripts,
        });
        allocation_fault.fail_index = allocation_fault.alloc_index;
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        if (watchdog.expired) std.debug.print("page timeout step={d} generation={d} boot={} completed={} dom={} title={} source={} denied={} back={} forward={}\n", .{ state.step, state.generation, state.boot, state.completed, state.dom, state.title, state.source, state.denied, view.can_go_back, view.can_go_forward });
        try std.testing.expect(!watchdog.expired and !state.failed and state.done);
        try std.testing.expect(state.missing_started_uri);
        try std.testing.expectEqual(@as(usize, 1), state.metadata_faults);
        previous = state.current;
        generation = state.generation;
        try std.testing.expect(view.pageId() == null);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        const counts = web.resourceCounts();
        try std.testing.expectEqual(@as(u32, 0), counts.states);
        try std.testing.expectEqual(@as(u32, 0), counts.handlers);
        try std.testing.expectEqual(@as(u32, 0), counts.controllers);
    }
    try std.testing.expectEqual(allocation_fault.allocated_bytes, allocation_fault.freed_bytes);
    std.debug.print("page smoke passed: local navigation/history/refresh, load/DOM/source/title, stale generations, metadata OOM, policy and callback close; COM=0\n", .{});
}
