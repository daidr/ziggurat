const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

extern fn g_timeout_add(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn zlg_region_count() c_uint;

const State = struct {
    app: *z.App,
    session: ?*web.PageSession = null,
    window: z.Window = undefined,
    owner: ?*z.composition.Owner = null,
    loaded: bool = false,
    pending: bool = false,
    queued: bool = false,
    stopping: bool = false,
    closed: usize = 0,
    window_closed: bool = false,
    posts: usize = 0,
    script_detached: usize = 0,
    resource_detached: usize = 0,
    failure: ?anyerror = null,

    fn fail(self: *State, failure: anyerror) void {
        self.failure = self.failure orelse failure;
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.NavigationFailed);
        self.loaded = true;
        self.queue();
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, request.path, "/hold") or self.pending) return self.fail(error.UnexpectedResource);
        if ((responder.window != null) != (self.owner != null)) return self.fail(error.WrongRequestWindow);
        _ = responder.deferResponse(.{ .timeout_ms = 10_000, .completion = .{ .context = self, .complete = resourceDone } }) catch |err| return self.fail(err);
        self.pending = true;
        self.queue();
    }
    fn queue(self: *State) void {
        if (self.queued or !self.loaded or !self.pending) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = trigger }) catch |err| self.fail(err);
    }
    fn trigger(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        // App.quit follows the accepted request in the same owner turn; native
        // completion cannot run before the logical detach disposition is set.
        _ = self.session.?.page.evaluateJS("42", .{ .timeout_ms = 10_000 }, .{ .context = self, .complete = scriptDone }) catch |err| return self.fail(err);
        self.app.post(.{ .context = self, .call = accepted }) catch |err| return self.fail(err);
        self.stopping = true;
        self.app.quit();
    }
    fn accepted(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.app.phase != .stopping or self.posts != 0 or self.session == null) return self.fail(error.AcceptedTaskOrder);
        self.posts += 1;
        if (self.owner != null) {
            const result = self.window.destroy() catch |err| return self.fail(err);
            // The public query revokes a logically closed Window immediately;
            // its stored provider responsibility must survive until Stop drains.
            if (result != .deferred or self.session.?.region == null) self.fail(error.ProviderReleasedBeforeStop);
        }
    }
    fn scriptDone(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!self.stopping or value != .detached) return self.fail(error.ScriptNotDetached);
        self.script_detached += 1;
    }
    fn resourceDone(ptr: *anyopaque, value: web.resources.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!self.stopping or value != .detached) return self.fail(error.ResourceNotDetached);
        self.resource_detached += 1;
    }
    fn sessionClosed(ptr: *anyopaque, session: *web.PageSession) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        self.session = null;
        self.app.allocator.destroy(session);
    }
    fn windowClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.session != null or self.script_detached != 1 or self.resource_detached != 1) {
            std.debug.print("Session stop ordering: session={s} script={d} resource={d} posts={d} stop={} phase={s} pins={d} region={}\n", .{
                if (self.session == null) "null" else "live",                        self.script_detached,                            self.resource_detached,                                        self.posts, self.stopping,
                if (self.session) |session| @tagName(session.phase) else "released", if (self.session) |session| session.pins else 0, if (self.session) |session| session.region != null else false,
            });
            return self.fail(error.WindowClosedBeforeSession);
        }
        self.window_closed = true;
        if (self.owner) |owner| {
            self.owner = null;
            owner.close() catch |err| self.fail(err);
        }
    }
};

fn cleanup(state: *State) void {
    const session = state.session orelse return;
    _ = session.close() catch unreachable;
    if (state.session != null) {
        state.session = null;
        state.app.allocator.destroy(session);
    }
}

fn runMode(allocator: std.mem.Allocator, mounted: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    state.window = try app.createWindow(.{ .on_closed = .{ .context = &state, .notify = State.windowClosed } });
    if (mounted) state.owner = try z.composition.Owner.create(allocator, state.window, .{});
    defer if (state.owner) |owner| {
        owner.detach() catch {};
        owner.close() catch unreachable;
    };
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(allocator, &state, State.event);
    errdefer cleanup(&state);
    try state.session.?.open(app, .{ .page = .{
        .html = "<!doctype html><script>fetch('/hold').catch(()=>{})</script>",
        .storage = .ephemeral,
        .custom_schemes = &.{.{ .name = "asset", .treat_as_secure = true }},
        .local = .{ .scheme = "asset", .on_resource = .{ .context = &state, .handle = State.resource } },
        .page_listener = .{ .context = &state, .event = State.page },
    }, .on_closed = .{ .context = &state, .notify = State.sessionClosed } });
    if (state.owner) |owner| try state.session.?.attachRegion(try owner.reserve(.{ .bounds = .{ .x = 8, .y = 8, .width = 240, .height = 160 } }));
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |failure| return failure;
    try std.testing.expect(!watchdog.expired and state.stopping and state.posts == 1 and state.closed == 1 and state.session == null);
    try std.testing.expect(state.window_closed and state.owner == null and state.script_detached == 1 and state.resource_detached == 1);
    try std.testing.expect(app.resourceStats().stop_participants == 0 and zlg_region_count() == 0);
}

fn noWindows(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(allocator, &state, State.event);
    errdefer cleanup(&state);
    try state.session.?.open(app, .{ .page = .{ .html = "empty app", .storage = .ephemeral }, .on_closed = .{ .context = &state, .notify = State.sessionClosed } });
    try std.testing.expect(app.resourceStats().allocated_records == 0);
    try app.run();
    try std.testing.expect(state.session == null and state.closed == 1 and app.phase == .stopped and app.resourceStats().stop_participants == 0);
}

// Explicit test event loop for late WebKit finish callbacks. Production close
// never polls or pumps a nested loop to wait for physical native references.
const Drain = struct {
    app: *z.App,
    timer: c_uint = 0,
    fn tick(ptr: ?*anyopaque) callconv(.c) c_int {
        const self: *Drain = @ptrCast(@alignCast(ptr.?));
        if (!std.meta.eql(web.resourceCounts(), web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 })) return 1;
        self.timer = 0;
        self.app.quit();
        return 0;
    }
};
pub fn run(allocator: std.mem.Allocator) !void {
    try runMode(allocator, false);
    try runMode(allocator, true);
    try noWindows(allocator);
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var drain: Drain = .{ .app = app };
    drain.timer = g_timeout_add(10, Drain.tick, &drain);
    if (drain.timer == 0) return error.TestTimerFailed;
    defer if (drain.timer != 0) {
        _ = g_source_remove(drain.timer);
    };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and web.deferredResourceCount() == 0 and zlg_region_count() == 0);
    try std.testing.expectEqualDeep(web.custom_local.ResourceCounts{ .budgets = 0, .streams = 0, .body_bytes = 0 }, web.customLocalResourceCounts());
    std.debug.print("Linux Session stop: mounted/parked requests detached once, accepted task once, zero-window shutdown, late native references=0\n", .{});
}
