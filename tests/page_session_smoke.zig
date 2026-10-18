const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const ui = @import("ziggurat_ui");
const Fixture = @import("scheme_smoke.zig").Fixture;
const Watchdog = @import("watchdog.zig").Watchdog;
const w = @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});
const Dimensions = struct { width: f64, height: f64, marker: u32 };
fn cleanupSession(allocator: std.mem.Allocator, slot: *?*web.PageSession) void {
    const session = slot.* orelse return;
    const result = session.close() catch @panic("Session cleanup failed; storage retained");
    if (result != .closed) @panic("Session cleanup still has a provider/callback obligation");
    // Failed construction intentionally sends no closed notification.
    if (slot.* != null) {
        slot.* = null;
        allocator.destroy(session);
    }
}
const State = struct {
    app: *z.App,
    fixture: *Fixture,
    session: ?*web.PageSession = null,
    a: z.Window = undefined,
    b: z.Window = undefined,
    owner_a: *z.composition.Owner = undefined,
    owner_b: ?*z.composition.Owner = null,
    background: ui.Context = undefined,
    original: ?web.PageId = null,
    previous_region: ?z.composition.Region = null,
    stage: enum { initial, mounted_a, parked, mounted_b, evacuated, remounted } = .initial,
    queued: bool = false,
    done: bool = false,
    ready: u32 = 0,
    closed: u32 = 0,
    checked: u32 = 0,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("page session stage={s}: {s}\n", .{ @tagName(self.stage), @errorName(err) });
        self.app.quit();
    }
    fn event(context: *anyopaque, page: *web.View, event_value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (event_value) {
            .ready => {
                self.ready += 1;
                self.fixture.capture(page) catch |err| self.fail(err);
            },
            .failed => |hr| {
                std.debug.print("page session native HRESULT=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
                self.fail(error.NativeFailed);
            },
            .process_failed => self.fail(error.NativeProcessFailed),
            else => {},
        }
    }
    fn pageEvent(context: *anyopaque, page: *web.View, event_value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (event_value != .completed) return;
        if (!event_value.completed.success or self.original != null) return self.fail(error.UnexpectedNavigation);
        self.original = page.pageId() orelse return self.fail(error.NoPage);
        self.evaluate();
    }
    fn closedEvent(context: *anyopaque, session: *web.PageSession) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.closed += 1;
        self.session = null;
        self.app.allocator.destroy(session);
    }
    fn windowClosed(context: *anyopaque, window: z.Window) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (!std.meta.eql(window, self.b)) return;
        const owner = self.owner_b orelse return;
        self.owner_b = null;
        owner.close() catch |err| self.fail(err);
        if (self.stage == .evacuated) self.queue();
    }
    fn draw(_: *anyopaque, frame: *ui.Frame) void {
        frame.clear(0x123456);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn evaluate(self: *State) void {
        const session = self.session orelse return self.fail(error.PrematureClose);
        if (!std.meta.eql(self.original.?, session.page.pageId().?)) return self.fail(error.GenerationChanged);
        _ = session.page.evaluateJS("({width:innerWidth,height:innerHeight,marker:(window.marker=(window.marker||0)+1)})", .{ .timeout_ms = 10_000 }, .{ .context = self, .complete = completed }) catch |err| self.fail(err);
    }
    fn completed(context: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (value != .json) return self.fail(error.NoScriptResult);
        const parsed = std.json.parseFromSlice(Dimensions, self.app.allocator, value.json, .{}) catch |err| return self.fail(err);
        defer parsed.deinit();
        self.checked += 1;
        const initial_scale = @as(f64, @floatFromInt(w.GetDpiForWindow(self.session.?.native_bridge))) / 96;
        const expected: Dimensions = switch (self.stage) {
            .initial => .{ .width = 620 / initial_scale, .height = 310 / initial_scale, .marker = 1 },
            .mounted_a => .{ .width = 200, .height = 100, .marker = 2 },
            .parked => .{ .width = 200, .height = 100, .marker = 3 },
            .mounted_b => .{ .width = 300, .height = 180, .marker = 4 },
            .remounted => .{ .width = 250, .height = 140, .marker = 5 },
            .evacuated => return self.fail(error.UnexpectedScript),
        };
        if (@abs(parsed.value.width - expected.width) > 1 or @abs(parsed.value.height - expected.height) > 1 or parsed.value.marker != expected.marker) {
            std.debug.print("page session actual={any} expected={any}\n", .{ parsed.value, expected });
            return self.fail(error.WrongDimensions);
        }
        if (self.stage == .mounted_b) {
            const bridge = self.session.?.native_bridge;
            if (w.DestroyWindow(self.b.nativeHandle()) == 0) return self.fail(error.RawDestroyFailed);
            if (w.IsWindow(bridge) == 0 or self.session.?.currentRegion() != null) return self.fail(error.BridgeDestroyedWithParent);
            self.stage = .evacuated;
            // Accepted posts drain before deferred Window cleanup. Continue
            // from its actual closed notification, without a retry/pump loop.
            if (self.owner_b == null) self.queue();
            return;
        } else if (self.stage == .remounted) {
            const session = self.session.?;
            const result = session.close() catch |err| return self.fail(err);
            if (result != .deferred or session.page.native == null or session.page.config == null) return self.fail(error.PrematureClose);
            self.done = true;
            self.app.quit();
            return;
        }
        self.queue();
    }
    fn queue(self: *State) void {
        if (self.queued or self.failure != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.queued = false;
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        const session = self.session orelse return error.PrematureClose;
        switch (self.stage) {
            .initial => {
                const region = try self.owner_a.reserve(.{ .bounds = .{ .x = 10, .y = 20, .width = 200, .height = 100 } });
                try session.attachRegion(region);
                self.previous_region = region;
                try std.testing.expect(w.GetParent(session.native_bridge) == self.a.nativeHandle());
                self.stage = .mounted_a;
            },
            .mounted_a => {
                try session.park();
                try std.testing.expect(session.currentRegion() == null and session.page.window == null and session.page.native != null);
                try std.testing.expectError(error.Closed, self.previous_region.?.snapshot());
                self.stage = .parked;
            },
            .parked => {
                const region = try self.owner_b.?.reserve(.{ .bounds = .{ .x = 30, .y = 40, .width = 300, .height = 180 } });
                try session.attachRegion(region);
                try std.testing.expect(w.GetParent(session.native_bridge) == self.b.nativeHandle());
                self.stage = .mounted_b;
            },
            .evacuated => {
                try std.testing.expect(self.owner_b == null and self.b.isClosed());
                const region = try self.owner_a.reserve(.{ .bounds = .{ .x = 60, .y = 50, .width = 250, .height = 140 } });
                try session.attachRegion(region);
                try std.testing.expect(w.GetParent(session.native_bridge) == self.a.nativeHandle());
                self.stage = .remounted;
            },
            else => return error.UnexpectedStage,
        }
        self.evaluate();
    }
};

const StopState = struct {
    app: *z.App,
    fixture: *Fixture,
    session: ?*web.PageSession = null,
    mounted: bool = false,
    window: z.Window = undefined,
    owner: ?*z.composition.Owner = null,
    destroy_posts: u32 = 0,
    window_closed: bool = false,
    held: ?web.ResourceRequestId = null,
    loaded: bool = false,
    queued: bool = false,
    quit_started: bool = false,
    closed: u32 = 0,
    script_detached: u32 = 0,
    tool_detached: u32 = 0,
    resource_detached: u32 = 0,
    failure: ?anyerror = null,
    fn fail(self: *StopState, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("parked session shutdown: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn event(context: *anyopaque, page: *web.View, value: web.Event) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        switch (value) {
            .ready => self.fixture.capture(page) catch |err| self.fail(err),
            .failed, .process_failed => self.fail(error.NativeFailed),
            else => {},
        }
    }
    fn pageEvent(context: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.NavigationFailed);
        self.loaded = true;
        self.queue();
    }
    fn resource(context: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.path, "/hold")) return;
        if ((responder.window != null) != self.mounted) return self.fail(error.WrongRequestWindow);
        self.held = responder.deferResponse(.{ .timeout_ms = 10_000, .completion = .{ .context = self, .complete = resourceDone } }) catch |err| return self.fail(err);
        self.queue();
    }
    fn queue(self: *StopState) void {
        if (self.queued or !self.loaded or self.held == null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = trigger }) catch |err| self.fail(err);
    }
    fn trigger(context: *anyopaque) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        _ = self.session.?.page.evaluateJS("'trigger'", .{}, .{ .context = self, .complete = triggered }) catch |err| self.fail(err);
    }
    fn triggered(context: *anyopaque, value: web.ScriptResult) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        if (value != .json) return self.fail(error.TriggerFailed);
        const page = &self.session.?.page;
        _ = page.evaluateJS("{const end=Date.now()+250;while(Date.now()<end){};42}", .{ .timeout_ms = 10_000 }, .{ .context = self, .complete = scriptDone }) catch |err| return self.fail(err);
        _ = page.clearBrowsingData(.entire_profile, .{ .timeout_ms = 10_000 }, .{ .context = self, .complete = toolDone }) catch |err| return self.fail(err);
        if (self.mounted) self.app.post(.{ .context = self, .call = destroyAccepted }) catch |err| return self.fail(err);
        self.quit_started = true;
        self.app.quit();
        std.testing.expectError(error.Closed, page.evaluateJS("1", .{}, .{ .context = self, .complete = scriptDone })) catch |err| self.fail(err);
    }
    fn destroyAccepted(context: *anyopaque) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        const handle = self.window.nativeHandle();
        const result = self.window.destroy() catch |err| return self.fail(err);
        if (self.app.phase != .stopping or result != .deferred or w.IsWindow(handle) == 0 or self.session == null or self.session.?.region == null) return self.fail(error.DestroyDidNotRetainProvider);
        self.destroy_posts += 1;
    }
    fn windowClosed(context: *anyopaque, _: z.Window) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        self.window_closed = true;
        // Stop closes physical page resources first; provider detach is allowed
        // to finish later while Window flush owns the old composition slot.
        const counts = web.pageHostResourceCounts();
        if (self.session != null or counts.hosts != 0 or counts.parking_windows != 0 or counts.bridge_windows != 0 or self.script_detached != 1 or self.tool_detached != 1 or self.resource_detached != 1) return self.fail(error.WindowClosedBeforeSession);
        if (self.owner) |owner| {
            self.owner = null;
            owner.close() catch |err| self.fail(err);
        }
    }
    fn scriptDone(context: *anyopaque, value: web.ScriptResult) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        if (!self.quit_started or value != .detached) return self.fail(error.ScriptDidNotDetach);
        self.script_detached += 1;
    }
    fn toolDone(context: *anyopaque, value: web.tools.Result) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        if (!self.quit_started or value != .detached) return self.fail(error.ToolDidNotDetach);
        self.tool_detached += 1;
    }
    fn resourceDone(context: *anyopaque, value: web.resources.Result) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        if (!self.quit_started or value != .detached) return self.fail(error.ResourceDidNotDetach);
        self.resource_detached += 1;
    }
    fn closedEvent(context: *anyopaque, session: *web.PageSession) void {
        const self: *StopState = @ptrCast(@alignCast(context));
        self.closed += 1;
        self.session = null;
        self.app.allocator.destroy(session);
    }
};

fn runStop(allocator: std.mem.Allocator, fixture: *Fixture, mounted: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: StopState = .{ .app = app, .fixture = fixture, .mounted = mounted };
    state.window = try app.createWindow(.{ .on_closed = .{ .context = &state, .notify = StopState.windowClosed } });
    if (mounted) state.owner = try z.composition.Owner.create(allocator, state.window, .{});
    defer if (state.owner) |owner| owner.close() catch @panic("stop owner cleanup failed");
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(allocator, &state, StopState.event);
    errdefer cleanupSession(allocator, &state.session);
    try state.session.?.open(app, .{ .page = .{
        .html = "<!doctype html><script>fetch('/hold').catch(()=>{})</script>",
        .user_data_folder = fixture.profile.?,
        .local = .{ .on_resource = .{ .context = &state, .handle = StopState.resource } },
        .tools = .{ .clear_entire_profile = true },
        .page_listener = .{ .context = &state, .event = StopState.pageEvent },
    }, .on_closed = .{ .context = &state, .notify = StopState.closedEvent } });
    if (state.owner) |owner| try state.session.?.attachRegion(try owner.reserve(.{ .bounds = .{ .x = 10, .y = 20, .width = 240, .height = 160 } }));
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.session == null and state.closed == 1 and state.script_detached == 1 and state.tool_detached == 1 and state.resource_detached == 1);
    try std.testing.expect(state.window_closed and state.owner == null and state.destroy_posts == @intFromBool(mounted));
    try std.testing.expectEqualDeep(web.PageHostResourceCounts{}, web.pageHostResourceCounts());
    const native = web.resourceCounts();
    try std.testing.expect(native.states == 0 and native.handlers == 0 and native.controllers == 0 and web.deferredResourceCount() == 0);
    try std.testing.expect(app.resourceStats().stop_participants == 0);
    std.debug.print("{s} session shutdown passed: three deadlines detached once, accepted destroy posts={d}, stop before provider cleanup, native/host/timer/stop resources=0\n", .{ if (mounted) "mounted" else "parked", state.destroy_posts });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("page session leak");
    const allocator = gpa.allocator();
    var temporary = std.testing.tmpDir(.{});
    var fixture: Fixture = .{ .allocator = allocator, .temporary = &temporary };
    var worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    defer {
        fixture.cleanup = true;
        fixture.err = null;
        worker = std.Thread.spawn(.{}, Fixture.run, .{&fixture}) catch @panic("cleanup worker unavailable");
        worker.join();
        if (fixture.profile) |profile| allocator.free(profile);
        if (!fixture.closed) temporary.cleanup();
        if (fixture.err) |err| std.debug.panic("page session profile cleanup: {s}", .{@errorName(err)});
    }
    if (fixture.err) |err| return err;
    try runMigration(allocator, &fixture);
    try runStop(allocator, &fixture, false);
    try runStop(allocator, &fixture, true);
    try runAllocatorClose(allocator, &fixture);
}

fn runMigration(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .fixture = fixture };
    state.a = try app.createWindow(.{ .width = 480, .height = 320 });
    state.b = try app.createWindow(.{ .width = 480, .height = 320, .on_closed = .{ .context = &state, .notify = State.windowClosed } });
    state.owner_a = try z.composition.Owner.create(allocator, state.a, .{});
    defer state.owner_a.close() catch @panic("owner cleanup failed");
    state.owner_b = try z.composition.Owner.create(allocator, state.b, .{});
    defer if (state.owner_b) |owner| owner.close() catch @panic("second owner cleanup failed");
    state.background = ui.Context.init(&state, State.draw, State.action);
    state.background.render_mode = .gdi;
    state.background.semantics_enabled = false;
    _ = try state.background.attachBackdrop(state.owner_a);
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(allocator, &state, State.event);
    errdefer cleanupSession(allocator, &state.session);
    try state.session.?.open(app, .{ .page = .{ .html = "<!doctype html><title>session</title>", .user_data_folder = fixture.profile.?, .local = .{}, .page_listener = .{ .context = &state, .event = State.pageEvent } }, .initial_size = .{ .width = 620, .height = 310 }, .on_closed = .{ .context = &state, .notify = State.closedEvent } });
    fixture.runtime_started = true;
    const counts = web.pageHostResourceCounts();
    try std.testing.expect(counts.hosts == 1 and counts.parking_windows == 1 and counts.bridge_windows == 1);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.done and state.closed == 1 and state.ready == 1 and state.checked == 5 and state.session == null);
    try std.testing.expectEqualDeep(web.PageHostResourceCounts{}, web.pageHostResourceCounts());
    const native = web.resourceCounts();
    try std.testing.expect(native.states == 0 and native.handlers == 0 and native.controllers == 0);
    try std.testing.expect(app.resourceStats().stop_participants == 0);
    std.debug.print("page session passed: explicit parked initial size, GDI backdrop, two-host mount/park, same DOM/PageId, raw parent destruction inside completion, old Owner immediate free, deferred Session close and all native counts=0\n", .{});
}

const ClosingAllocator = struct {
    backing: std.mem.Allocator,
    state: *ReentryState,
    armed: bool = false,
    fired: bool = false,
    fn allocator(self: *ClosingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn allocate(context: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *ClosingAllocator = @ptrCast(@alignCast(context));
        if (self.armed) {
            self.armed = false;
            self.fired = true;
            const result = self.state.session.?.close() catch |err| {
                self.state.fail(err);
                return null;
            };
            if (result != .deferred) self.state.fail(error.CloseDidNotDefer);
        }
        return self.backing.rawAlloc(size, alignment, address);
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) bool {
        const self: *ClosingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(bytes, alignment, size, address);
    }
    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) ?[*]u8 {
        const self: *ClosingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(bytes, alignment, size, address);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *ClosingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(bytes, alignment, address);
    }
};
const ReentryState = struct {
    app: *z.App,
    fixture: *Fixture,
    session: ?*web.PageSession = null,
    fault: ClosingAllocator = undefined,
    closed: u32 = 0,
    done: bool = false,
    failure: ?anyerror = null,
    fn fail(self: *ReentryState, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("session allocation close: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn event(context: *anyopaque, page: *web.View, value: web.Event) void {
        const self: *ReentryState = @ptrCast(@alignCast(context));
        switch (value) {
            .ready => self.fixture.capture(page) catch |err| self.fail(err),
            .failed, .process_failed => self.fail(error.NativeFailed),
            else => {},
        }
    }
    fn pageEvent(context: *anyopaque, page: *web.View, value: web.PageEvent) void {
        const self: *ReentryState = @ptrCast(@alignCast(context));
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.NavigationFailed);
        self.fault.armed = true;
        std.testing.expectError(error.Closed, page.evaluateJS("'must-not-submit'", .{}, .{ .context = self, .complete = unexpected })) catch |err| return self.fail(err);
        if (!self.fault.fired or self.session == null or page.native == null or page.config == null) return self.fail(error.PrematureRelease);
        self.done = true;
        self.app.quit();
    }
    fn unexpected(_: *anyopaque, _: web.ScriptResult) void {
        @panic("allocation invalidated submission accepted completion ownership");
    }
    fn closedEvent(context: *anyopaque, session: *web.PageSession) void {
        const self: *ReentryState = @ptrCast(@alignCast(context));
        self.closed += 1;
        self.session = null;
        self.app.allocator.destroy(session);
    }
};
fn runAllocatorClose(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var state: ReentryState = .{ .app = app, .fixture = fixture };
    state.fault = .{ .backing = allocator, .state = &state };
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(state.fault.allocator(), &state, ReentryState.event);
    errdefer cleanupSession(allocator, &state.session);
    try state.session.?.open(app, .{ .page = .{ .html = "<!doctype html><title>allocator close</title>", .user_data_folder = fixture.profile.?, .local = .{}, .page_listener = .{ .context = &state, .event = ReentryState.pageEvent } }, .on_closed = .{ .context = &state, .notify = ReentryState.closedEvent } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.done and state.closed == 1 and state.session == null);
    try std.testing.expectEqualDeep(web.PageHostResourceCounts{}, web.pageHostResourceCounts());
    const native = web.resourceCounts();
    try std.testing.expect(native.states == 0 and native.handlers == 0 and native.controllers == 0);
    std.debug.print("session allocation close passed: final UTF16 allocation reentry rejects submission, retains callback storage until unwind, final on_closed frees whole Session; native resources=0\n", .{});
}
