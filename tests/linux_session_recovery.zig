const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zlg_region_count() c_uint;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
extern fn webkit_web_view_terminate_web_process(*anyopaque) void;

const State = struct {
    app: *z.App,
    window: z.Window,
    session: web.PageSession = undefined,
    recovering: bool,
    parked: bool,
    old: ?web.PageId = null,
    calls: u32 = 0,
    ready: u32 = 0,
    releases: u32 = 0,
    failures: u32 = 0,
    err: ?anyerror = null,
    fn options(self: *State) web.Options {
        return .{ .html = "<style>html,body{margin:0}</style><title>Session replacement</title>", .storage = .ephemeral, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("Linux Session replacement recover={} parked={}: {s}\n", .{ self.recovering, self.parked, @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
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
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.ReplacementLoadFailed);
        if (self.old == null) self.old = view.pageId();
        _ = view.evaluateJS(if (self.calls == 0) "globalThis.saved=7;7" else "({saved:typeof saved,width:innerWidth,height:innerHeight})", .{}, .{ .context = self, .complete = complete }) catch |err| self.fail(err);
    }
    fn complete(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .json) return self.fail(error.ReplacementScriptFailed);
        self.calls += 1;
        if (self.calls == 1) {
            if (!std.mem.eql(u8, value.json, "7")) return self.fail(error.BadInitialScript);
            if (self.recovering) {
                const widget = @import("linux_webview_process.zig").ownedWidget(self.window) catch |err| return self.fail(err);
                _ = g_object_ref(widget);
                defer g_object_unref(widget);
                if (self.parked) self.session.park() catch |err| return self.fail(err);
                // Termination can synchronously invalidate the old controller;
                // park the live page first, then terminate only this owned view.
                webkit_web_view_terminate_web_process(widget);
            } else if (self.parked) self.session.park() catch |err| return self.fail(err);
            if (!self.recovering) self.session.page.reload(self.options()) catch |err| self.fail(err);
        } else if (self.calls == 2) {
            const Dimensions = struct { saved: []const u8, width: u32, height: u32 };
            const parsed = std.json.parseFromSlice(Dimensions, self.session.page.allocator, value.json, .{}) catch |err| return self.fail(err);
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.saved, "undefined")) return self.fail(error.OldDocumentSurvived);
            if (parsed.value.width != 280 or parsed.value.height != 160) return self.fail(error.ReplacementViewportChanged);
            if ((self.session.currentRegion() == null) != self.parked or (self.session.page.window == null) != self.parked) return self.fail(error.ReplacementHostChanged);
            std.testing.expectError(error.StalePage, self.session.page.postFor(self.old.?, "old generation")) catch |err| return self.fail(err);
            _ = self.session.close() catch |err| return self.fail(err);
            _ = self.window.destroy() catch |err| return self.fail(err);
            self.app.quit();
        } else self.fail(error.DuplicateReplacement);
    }
};

fn runMode(allocator: std.mem.Allocator, recovering: bool, parked: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .window = try app.createWindow(.{ .width = 400, .height = 280 }), .recovering = recovering, .parked = parked };
    const owner = try z.composition.Owner.create(allocator, state.window, .{ .capacity = 1 });
    defer {
        owner.detach() catch {};
        owner.close() catch unreachable;
    }
    state.session = web.PageSession.init(allocator, &state, State.event);
    defer _ = state.session.close() catch unreachable;
    try state.session.open(app, .{ .page = state.options() });
    try state.session.attachRegion(try owner.reserve(.{ .bounds = .{ .x = 12, .y = 10, .width = 280, .height = 160 } }));
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.err) |err| return err;
    try std.testing.expect(!watchdog.expired and state.calls == 2 and state.ready == 2);
    try std.testing.expectEqual(@as(u32, if (recovering) 1 else 0), state.failures);
    try std.testing.expectEqual(@as(u32, if (recovering) 0 else 1), state.releases);
    try std.testing.expect(state.session.phase == .closed and app.resourceStats().allocated_records == 0 and app.resourceStats().stop_participants == 0 and zlg_region_count() == 0);
}

pub fn run(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |recovering| {
        for ([_]bool{ false, true }) |parked| try runMode(allocator, recovering, parked);
    }
    std.debug.print("Linux Session replacement: mounted/parked reload and owned WebProcess recovery, viewport preserved, stale PageId rejected\n", .{});
}
