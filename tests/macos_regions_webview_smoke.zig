//! Pages in rectangles of one macOS window: two regions keep their documents
//! through moves, fractional bounds, hiding and an empty viewport; a removed
//! region's page closes and a fresh one takes its place. A page session then
//! lives parked without a window, mounts into a region at whole points and
//! parks again with its size, refusing an old attachment.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_test_frame(*anyopaque, *i32, *i32, *i32, *i32, *c_int) c_int;
extern fn zwk_session_park(*anyopaque, u64) c_int;
extern fn zwk_session_size(*anyopaque, *u32, *u32) c_int;

const a_bounds: z.Rect = .{ .x = 12, .y = 18, .width = 160, .height = 100 };
const b_bounds: z.Rect = .{ .x = 200, .y = 36, .width = 170, .height = 110 };

const Frame = struct { x: i32, y: i32, width: i32, height: i32, shown: bool };
fn frame(native: *anyopaque) !Frame {
    var value: Frame = undefined;
    var shown: c_int = 0;
    if (zwk_test_frame(native, &value.x, &value.y, &value.width, &value.height, &shown) != 0) return error.NativeClosed;
    value.shown = shown != 0;
    return value;
}
/// The view covers whole points around the rectangle, in pixels.
fn expectFrame(native: *anyopaque, points: z.Rect, scale: f32, shown: bool) !void {
    const actual = try frame(native);
    const s: i32 = @intFromFloat(scale);
    const expected: Frame = .{ .x = @as(i32, @intFromFloat(points.x)) * s, .y = @as(i32, @intFromFloat(points.y)) * s, .width = @as(i32, @intFromFloat(points.width)) * s, .height = @as(i32, @intFromFloat(points.height)) * s, .shown = shown };
    if (!std.meta.eql(expected, actual)) {
        std.debug.print("frame expected={any} actual={any}\n", .{ expected, actual });
        return error.RegionGeometryMismatch;
    }
}

const Node = struct {
    state: *State,
    index: usize,
    view: web.View = undefined,
    region: z.composition.Region = undefined,
    original: ?web.PageId = null,
    loads: u32 = 0,
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value == .failed or value == .process_failed) self.state.fail(error.NativeFailure);
    }
    fn options(self: *Node) web.Options {
        return .{
            .html = if (self.index == 0) "<title>A</title><p>original</p>" else "<title>B</title><p>modified</p>",
            .storage = .ephemeral,
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success) return self.state.fail(error.LoadFailed);
        self.loads += 1;
        if (self.loads == 1) {
            self.original = view.pageId();
            _ = view.evaluateJS(if (self.index == 0) "globalThis.saved=42;42" else "globalThis.saved=13;13", .{}, .{ .context = self, .complete = initial }) catch |err| self.state.fail(err);
        } else self.state.fail(error.UnexpectedReload);
    }
    fn initial(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, if (self.index == 0) "42" else "13")) return self.state.fail(error.BadInitialValue);
        self.state.initial += 1;
        if (self.state.initial == 2) self.state.app.post(.{ .context = self.state, .call = State.updateTask }) catch |err| self.state.fail(err);
    }
    fn preserved(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, if (self.index == 0) "42" else "13")) return self.state.fail(error.DocumentRecreated);
        self.state.preserved += 1;
        if (self.state.preserved == 2) self.state.app.post(.{ .context = self.state, .call = State.replaceTask }) catch |err| self.state.fail(err);
    }
    fn detached(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .detached) return self.state.fail(error.WrongCloseReason);
        self.state.detached += 1;
    }
    fn replaced(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success) return self.state.fail(error.LoadFailed);
        _ = self.view.evaluateJS("typeof saved", .{}, .{ .context = self.state, .complete = State.rebuilt }) catch |err| self.state.fail(err);
    }
};

const State = struct {
    app: *z.App,
    window: z.Window,
    owner: *z.composition.Owner,
    scale: f32 = 1,
    nodes: [2]Node = undefined,
    initial: u32 = 0,
    preserved: u32 = 0,
    detached: u32 = 0,
    finished: bool = false,
    err: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("macOS regions: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn updateTask(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.update() catch |err| self.fail(err);
    }
    fn update(self: *State) !void {
        const a = self.nodes[0].view.native.?;
        const b = self.nodes[1].view.native.?;
        try expectFrame(a, a_bounds, self.scale, true);
        try expectFrame(b, b_bounds, self.scale, true);
        var moved = a_bounds;
        moved.x = 24;
        moved.y = 28;
        moved.width = 151;
        moved.height = 83;
        try self.nodes[0].region.update(.{ .bounds = moved });
        try expectFrame(a, moved, self.scale, true);
        const two = self.scale == 2;
        try self.nodes[0].region.update(.{ .bounds = .{ .x = 12.25, .y = 19.75, .width = 150.25, .height = 83.5 } });
        try expectFrame(a, .{ .x = 12, .y = 20, .width = 151, .height = if (two) 84 else 83 }, self.scale, true);
        try self.nodes[0].region.update(.{ .bounds = .{ .x = -3.25, .y = 20, .width = 10.5, .height = 40 } });
        try expectFrame(a, .{ .x = if (two) -4 else -3, .y = 20, .width = if (two) 12 else 10, .height = 40 }, self.scale, true);
        try self.nodes[0].region.update(.{ .bounds = moved });
        try expectFrame(a, moved, self.scale, true);
        try self.nodes[1].region.update(.{ .bounds = b_bounds, .visible = false });
        try expectFrame(b, b_bounds, self.scale, false);
        try self.nodes[1].region.update(.{ .bounds = b_bounds });
        try expectFrame(b, b_bounds, self.scale, true);
        // An empty viewport hides the page and keeps its last size.
        var empty = moved;
        empty.width = 0;
        try self.nodes[0].region.update(.{ .bounds = empty });
        try expectFrame(a, moved, self.scale, false);
        try self.nodes[0].region.update(.{ .bounds = moved });
        try expectFrame(a, moved, self.scale, true);
        for (&self.nodes) |*node| {
            try std.testing.expectEqual(node.original.?.generation, node.view.pageId().?.generation);
            _ = try node.view.evaluateJS("saved", .{}, .{ .context = node, .complete = Node.preserved });
        }
    }
    fn replaceTask(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.replace() catch |err| self.fail(err);
    }
    fn replace(self: *State) !void {
        const a = &self.nodes[0];
        _ = try a.view.evaluateJS("99", .{}, .{ .context = a, .complete = Node.detached });
        const stale = a.region;
        try std.testing.expect(try a.region.remove());
        if (a.view.native != null or a.view.config != null or self.detached != 1) return error.RemovedRegionStillOpen;
        try std.testing.expectError(error.StalePage, a.view.postFor(a.original.?, "stale"));
        try std.testing.expect(self.nodes[1].view.pageId() != null);
        a.region = try self.owner.reserve(.{ .bounds = a_bounds });
        try std.testing.expect(a.region.index == stale.index and a.region.generation != stale.generation);
        try std.testing.expectError(error.Closed, stale.snapshot());
        var options = a.options();
        options.page_listener = .{ .context = a, .event = Node.replaced };
        try a.view.attachRegion(a.region, options);
        try expectFrame(a.view.native.?, a_bounds, self.scale, true);
    }
    fn rebuilt(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, "\"undefined\"")) return self.fail(error.OldDocumentRetained);
        _ = self.nodes[1].view.evaluateJS("saved", .{}, .{ .context = self, .complete = finish }) catch |err| self.fail(err);
    }
    fn finish(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, "13")) return self.fail(error.PeerDocumentChanged);
        const b = &self.nodes[1];
        _ = b.view.evaluateJS("88", .{}, .{ .context = b, .complete = Node.detached }) catch |err| return self.fail(err);
        _ = self.window.destroy() catch |err| return self.fail(err);
        self.finished = true;
        self.app.quit();
    }
};

fn regions(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 400, .height = 240 });
    const owner = try z.composition.Owner.create(allocator, window, .{ .capacity = 2 });
    defer {
        owner.detach() catch {};
        owner.close() catch unreachable;
    }
    var state: State = .{ .app = app, .window = window, .owner = owner };
    state.scale = (try window.contentSize()).scale;
    try std.testing.expect(state.scale == 1 or state.scale == 2);
    for (&state.nodes, 0..) |*node, index| {
        node.* = .{ .state = &state, .index = index };
        node.view = web.View.init(allocator, node, Node.event);
    }
    for (&state.nodes) |*node| {
        node.region = try owner.reserve(.{ .bounds = if (node.index == 0) a_bounds else b_bounds });
        try node.view.attachRegion(node.region, node.options());
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.err) |err| return err;
    try std.testing.expect(!watchdog.expired and state.finished and state.detached == 2);
}

fn sessionEvent(_: *anyopaque, _: *web.View, _: web.Event) void {}
fn observed(session: *web.PageSession) !web.PageSession.PixelSize {
    var actual: web.PageSession.PixelSize = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zwk_session_size(session.page.native.?, &actual.width, &actual.height));
    return actual;
}
fn extent(start: f32, length: f32, scale: f32) u32 {
    const physical_first = @round(@as(f64, start) * scale);
    const physical_last = @round((@as(f64, start) + length) * scale);
    return @intFromFloat((@ceil(physical_last / scale) - @floor(physical_first / scale)) * scale);
}

fn sessions(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 400, .height = 280 });
    const scale = (try window.contentSize()).scale;
    var context: u8 = 0;
    var invalid = web.PageSession.init(allocator, &context, sessionEvent);
    try std.testing.expectError(error.InvalidViewport, invalid.open(app, .{ .page = .{ .html = "invalid", .storage = .ephemeral }, .initial_size = .{ .width = 0, .height = 1 } }));
    try std.testing.expect(invalid.phase == .closed and app.resourceStats().stop_participants == 0);
    if (scale > 1) {
        var unrepresentable = web.PageSession.init(allocator, &context, sessionEvent);
        try std.testing.expectError(error.NativeGeometryNotApplied, unrepresentable.open(app, .{ .page = .{ .html = "not rounded", .storage = .ephemeral }, .initial_size = .{ .width = @as(u32, @intFromFloat(scale)) + 1, .height = 20 } }));
        try std.testing.expect(unrepresentable.phase == .closed and unrepresentable.page.native == null and app.resourceStats().stop_participants == 0);
    }
    const owner = try z.composition.Owner.create(allocator, window, .{ .capacity = 2 });
    defer {
        owner.detach() catch {};
        owner.close() catch unreachable;
    }
    var session = web.PageSession.init(allocator, &context, sessionEvent);
    try session.open(app, .{ .page = .{ .html = "geometry", .storage = .ephemeral } });
    defer _ = session.close() catch unreachable;
    const native = session.page.native.?;
    const parked_size = try observed(&session);
    try std.testing.expect(!(try frame(native)).shown);

    const too_large: z.composition.Viewport = .{ .bounds = .{ .x = 1, .y = 2, .width = 100_000, .height = 20 } };
    const rejected = try owner.reserve(too_large);
    try std.testing.expectError(error.InvalidNativeArgument, session.attachRegion(rejected));
    try std.testing.expect(session.currentRegion() == null and session.page.native == native and session.page.window == null);
    try std.testing.expect(!(try frame(native)).shown);
    try std.testing.expectEqualDeep(parked_size, try observed(&session));
    try std.testing.expect(try rejected.remove());

    const viewport: z.composition.Viewport = .{ .bounds = .{ .x = -3.25, .y = 7.5, .width = 20.5, .height = 14.75 } };
    const region = try owner.reserve(viewport);
    try session.attachRegion(region);
    const expected: web.PageSession.PixelSize = .{ .width = extent(viewport.bounds.x, viewport.bounds.width, scale), .height = extent(viewport.bounds.y, viewport.bounds.height, scale) };
    try std.testing.expectEqualDeep(expected, try observed(&session));
    try std.testing.expectEqualDeep(expected, session.last_size);
    try std.testing.expect((try frame(native)).shown);
    // An old attachment is refused while the current one stays.
    try std.testing.expectEqual(@as(c_int, 4), zwk_session_park(native, session.attachment_epoch - 1));
    try std.testing.expect((try frame(native)).shown);
    try std.testing.expectError(error.InvalidNativeArgument, region.update(too_large));
    try std.testing.expectEqualDeep(viewport, (try region.snapshot()).viewport);
    try std.testing.expectEqualDeep(expected, try observed(&session));

    // Hidden in its region, then parked: out of the window, size kept.
    try region.update(.{ .bounds = viewport.bounds, .visible = false });
    try std.testing.expect(!(try frame(native)).shown);
    try region.update(viewport);
    try std.testing.expect((try frame(native)).shown);
    try session.park();
    try std.testing.expectError(error.Closed, region.snapshot());
    try std.testing.expect(!(try frame(native)).shown);
    try std.testing.expectEqualDeep(expected, try observed(&session));
    const replacement = try owner.reserve(viewport);
    const epoch = session.attachment_epoch;
    try session.attachRegion(replacement);
    try std.testing.expectEqual(epoch + 1, session.attachment_epoch);
    try std.testing.expectEqualDeep(expected, try observed(&session));
    try std.testing.expect((try frame(native)).shown);
    try std.testing.expectEqual(web.PageSession.CloseResult.closed, try session.close());
    try std.testing.expect(app.resourceStats().stop_participants == 0);
    _ = try window.destroy();
}

/// The pages' records end once the engine lets go of the closed views.
const Drain = struct {
    app: *z.App,
    rounds: usize = 0,
    fn clean() bool {
        const counts = web.resourceCounts();
        return counts.states == 0 and counts.handlers == 0 and counts.controllers == 0;
    }
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.rounds += 1;
        if (clean() or self.rounds == 3000) return self.app.quit();
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};
fn drain(allocator: std.mem.Allocator) !void {
    // A stopped App takes no posts, so a fresh one turns the run loop.
    const app = try z.App.init(allocator);
    defer app.deinit();
    var value: Drain = .{ .app = app };
    try app.post(.{ .context = &value, .call = Drain.tick });
    try app.run();
    if (!Drain.clean()) return error.ViewRecordsRemain;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    try regions(allocator);
    try sessions(allocator);
    try drain(allocator);
    std.debug.print("macOS regions: two documents through move/fraction/hide/empty, remove and replace; session parked, mounted at whole points, parked again; records=0\n", .{});
}
