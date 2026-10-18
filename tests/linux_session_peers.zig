const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn zlg_region_count() c_uint;
extern fn zlg_resource_count() c_uint;
extern fn g_timeout_add(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;

/// A separate, explicit test App receives only late native releases. This does
/// not run inside another App loop or make production teardown wait for GIO.
pub fn drain(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    const Drain = struct {
        app: *z.App,
        timer: c_uint = 0,
        fn tick(ptr: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            if (!std.meta.eql(web.resourceCounts(), web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }) or
                !std.meta.eql(web.fileResourceCounts(), web.FileResourceCounts{ .streams = 0, .controls = 0, .budgets = 0 }) or
                web.deferredResourceCount() != 0) return 1;
            self.timer = 0;
            self.app.quit();
            return 0;
        }
    };
    var state: Drain = .{ .app = app };
    state.timer = g_timeout_add(10, Drain.tick, &state);
    if (state.timer == 0) return error.TestTimerFailed;
    defer if (state.timer != 0) {
        _ = g_source_remove(state.timer);
    };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and state.timer == 0 and zlg_region_count() == 0);
    try std.testing.expectEqualDeep(web.custom_local.ResourceCounts{ .budgets = 0, .streams = 0, .body_bytes = 0 }, web.customLocalResourceCounts());
}

const Source = struct {
    state: *State,
    index: u8,
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *Source = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed, .process_failed => self.state.fail(error.PeerNativeFailure),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *Source = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success or self.state.loaded[self.index]) return self.state.fail(error.PeerDocumentReloaded);
        self.state.loaded[self.index] = true;
        self.state.ids[self.index] = view.pageId() orelse return self.state.fail(error.PeerMissingPage);
        self.state.schedule();
    }
    fn script(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Source = @ptrCast(@alignCast(ptr));
        const state = self.state;
        const bit = @as(u8, 1) << @intCast(self.index);
        if (state.waiting & bit == 0 or result != .json or !std.mem.eql(u8, result.json, "true")) return state.fail(error.PeerIdentityChanged);
        if (!std.meta.eql(state.ids[self.index], state.sessions[self.index].page.pageId())) return state.fail(error.PeerPageIdChanged);
        state.waiting &= ~bit;
        state.checks += 1;
        if (state.waiting == 0) state.schedule();
    }
    fn closed(ptr: *anyopaque, _: *web.PageSession) void {
        const self: *Source = @ptrCast(@alignCast(ptr));
        self.state.closed[self.index] += 1;
    }
};
const State = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    windows: [2]z.Window = undefined,
    owners: [2]?*z.composition.Owner = @splat(null),
    sources: [3]Source = undefined,
    sessions: [3]web.PageSession = undefined,
    ids: [3]?web.PageId = @splat(null),
    loaded: [3]bool = @splat(false),
    closed: [3]u32 = @splat(0),
    stage: enum { initial, shared, parked_one, closed_one, replaced_shared, raw_wait, evacuated, remounted, done } = .initial,
    waiting: u8 = 0,
    queued: bool = false,
    checks: u32 = 0,
    raw_closed: bool = false,
    failure: ?anyerror = null,

    fn fail(self: *State, failure: anyerror) void {
        self.failure = self.failure orelse failure;
        self.app.quit();
    }
    fn schedule(self: *State) void {
        if (self.queued or self.failure != null or self.stage == .done) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.failure != null) return;
        self.step() catch |err| self.fail(err);
    }
    fn open(self: *State, index: u8) !void {
        const htmls = [_][]const u8{
            "<script>globalThis.identity={index:0};globalThis.original=identity;</script>",
            "<script>globalThis.identity={index:1};globalThis.original=identity;</script>",
            "<script>globalThis.identity={index:2};globalThis.original=identity;</script>",
        };
        try self.sessions[index].open(self.app, .{ .page = .{ .html = htmls[index], .storage = .ephemeral, .page_listener = .{ .context = &self.sources[index], .event = Source.page } }, .on_closed = .{ .context = &self.sources[index], .notify = Source.closed } });
    }
    fn mount(self: *State, index: u8, host: usize, column: usize) !void {
        const owner = self.owners[host] orelse return error.PeerOwnerGone;
        const region = try owner.reserve(.{ .bounds = .{ .x = if (column == 0) 4 else 252, .y = 4, .width = 240, .height = 160 } });
        errdefer _ = region.remove() catch false;
        try self.sessions[index].attachRegion(region);
    }
    fn evaluate(self: *State, indices: []const u8) !void {
        try std.testing.expect(self.waiting == 0);
        for (indices) |index| self.waiting |= @as(u8, 1) << @intCast(index);
        for (indices) |index| {
            var buffer: [96]u8 = undefined;
            const script = try std.fmt.bufPrint(&buffer, "identity === original && identity.index === {d}", .{index});
            _ = try self.sessions[index].page.evaluateJS(script, .{}, .{ .context = &self.sources[index], .complete = Source.script });
        }
    }
    fn windowClosed(ptr: *anyopaque, window: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const index: usize = if (std.meta.eql(window, self.windows[0])) 0 else 1;
        if (self.owners[index]) |owner| {
            self.owners[index] = null;
            owner.close() catch |err| return self.fail(err);
        }
        if (index == 0 and self.stage == .raw_wait) {
            self.raw_closed = true;
            self.stage = .evacuated;
            self.schedule();
        }
    }
    fn step(self: *State) !void {
        if (self.waiting != 0) return;
        switch (self.stage) {
            .initial => {
                if (!self.loaded[0] or !self.loaded[1]) return;
                try self.mount(0, 0, 0);
                try self.mount(1, 0, 1);
                try std.testing.expectEqual(@as(c_uint, 3), zlg_region_count());
                self.stage = .shared;
                try self.evaluate(&.{ 0, 1 });
            },
            .shared => {
                try self.sessions[0].park();
                try std.testing.expect(self.sessions[0].currentRegion() == null and self.sessions[1].currentRegion() != null);
                try std.testing.expectEqual(@as(c_uint, 2), zlg_region_count());
                self.stage = .parked_one;
                try self.evaluate(&.{ 0, 1 });
            },
            .parked_one => {
                try std.testing.expectEqual(web.PageSession.CloseResult.closed, try self.sessions[0].close());
                try std.testing.expect(self.closed[0] == 1 and self.sessions[1].currentRegion() != null);
                try std.testing.expectEqual(@as(c_uint, 2), zlg_region_count());
                self.stage = .closed_one;
                try self.open(2);
                try self.evaluate(&.{1});
            },
            .closed_one => {
                if (!self.loaded[2]) return;
                try self.mount(2, 0, 0);
                try std.testing.expectEqual(@as(c_uint, 3), zlg_region_count());
                self.stage = .replaced_shared;
                try self.evaluate(&.{ 1, 2 });
            },
            .replaced_shared => {
                self.stage = .raw_wait;
                gtk_widget_destroy(self.windows[0].nativeHandle().?);
                try std.testing.expect(self.sessions[1].page.native != null and self.sessions[2].page.native != null);
            },
            .raw_wait => {},
            .evacuated => {
                try std.testing.expect(self.raw_closed and self.owners[0] == null and zlg_region_count() == 0);
                try std.testing.expect(self.sessions[1].currentRegion() == null and self.sessions[2].currentRegion() == null);
                try self.mount(1, 1, 0);
                try self.mount(2, 1, 1);
                self.stage = .remounted;
                try self.evaluate(&.{ 1, 2 });
            },
            .remounted => {
                try std.testing.expectEqual(web.PageSession.CloseResult.closed, try self.sessions[1].close());
                try std.testing.expect(self.sessions[2].currentRegion() != null and zlg_region_count() == 2);
                try std.testing.expectEqual(web.PageSession.CloseResult.closed, try self.sessions[2].close());
                self.stage = .done;
                _ = try self.windows[1].destroy();
                self.app.quit();
            },
            .done => {},
        }
    }
    fn cleanup(self: *State) void {
        for (&self.sessions) |*session| _ = session.close() catch unreachable;
        for (&self.owners) |*slot| if (slot.*) |owner| {
            slot.* = null;
            owner.detach() catch {};
            owner.close() catch unreachable;
        };
    }
};

fn peers(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .allocator = allocator };
    for (&state.sources, &state.sessions, 0..) |*source, *session, index| {
        source.* = .{ .state = &state, .index = @intCast(index) };
        session.* = web.PageSession.init(allocator, source, Source.event);
    }
    defer state.cleanup();
    for (&state.windows, &state.owners) |*window, *owner| {
        window.* = try app.createWindow(.{ .width = 520, .height = 200, .on_closed = .{ .context = &state, .notify = State.windowClosed } });
        owner.* = try z.composition.Owner.create(allocator, window.*, .{ .capacity = 2 });
    }
    try state.open(0);
    try state.open(1);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |failure| return failure;
    try std.testing.expect(!watchdog.expired and state.stage == .done and state.checks == 9);
    try std.testing.expectEqualDeep([_]u32{ 1, 1, 1 }, state.closed);
    try std.testing.expect(app.resourceStats().allocated_records == 0 and app.resourceStats().stop_participants == 0 and zlg_region_count() == 0);
}
pub fn run(allocator: std.mem.Allocator) !void {
    try peers(allocator);
    try drain(allocator);
    try std.testing.expectEqual(@as(c_uint, 0), zlg_resource_count());
    std.debug.print("Linux Session peers: two real documents share a layer, independent park/close, whole-layer raw evacuation and two rehosts preserve DOM/PageId; resources=0\n", .{});
}
