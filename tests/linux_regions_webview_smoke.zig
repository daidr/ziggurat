const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zrr_layout(*anyopaque, c_int, c_int) c_int;
extern fn zrr_identify(*anyopaque, [*:0]const u8) c_int;
extern fn zrr_bounds(*anyopaque, [*:0]const u8, c_int, c_int, c_int, c_int, c_int) c_int;
extern fn zlg_region_count() c_uint;
extern fn zlg_content_count() c_uint;
extern fn zlg_resource_count() c_uint;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn zwk_focus(*anyopaque) c_int;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;

const a_bounds: z.Rect = .{ .x = 12, .y = 18, .width = 160, .height = 100 };
const b_bounds: z.Rect = .{ .x = 200, .y = 36, .width = 170, .height = 110 };
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
        } else if (self.index == 0 and self.loads == 2) {
            _ = view.evaluateJS("typeof saved", .{}, .{ .context = self, .complete = rebuilt }) catch |err| self.state.fail(err);
        } else self.state.fail(error.UnexpectedReload);
    }
    fn initial(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, if (self.index == 0) "42" else "13")) return self.state.fail(error.BadInitialValue);
        self.state.initial += 1;
        if (self.state.initial == 2) self.state.update() catch |err| self.state.fail(err);
    }
    fn preserved(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, if (self.index == 0) "42" else "13")) return self.state.fail(error.DocumentRecreated);
        self.state.preserved += 1;
        if (self.state.preserved == 2) self.state.app.post(.{ .context = self.state, .call = State.replaceTask }) catch |err| self.state.fail(err);
    }
    fn rebuilt(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, "\"undefined\"")) return self.state.fail(error.OldDocumentRetained);
        std.testing.expectError(error.StalePage, self.view.postFor(self.original.?, "stale")) catch |err| return self.state.fail(err);
        _ = self.state.nodes[1].view.evaluateJS("saved", .{}, .{ .context = self.state, .complete = State.finish }) catch |err| self.state.fail(err);
    }
    fn detached(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        if (value != .detached) return self.state.fail(error.WrongCloseReason);
        self.state.detached += 1;
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window,
    owner: *z.composition.Owner,
    failing: *std.testing.FailingAllocator,
    raw_close: bool,
    nodes: [2]Node = undefined,
    initial: u32 = 0,
    preserved: u32 = 0,
    detached: u32 = 0,
    closed: u32 = 0,
    timer: c_uint = 0,
    finished: bool = false,
    nodes_ready: bool = false,
    err: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("Linux regions raw={}: {s}\n", .{ self.raw_close, @errorName(err) });
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        self.app.quit();
    }
    fn closedWindow(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        if (self.nodes_ready) std.debug.assert(self.nodes[0].view.window == null and self.nodes[1].view.window == null);
    }
    fn check(self: *State, title: [*:0]const u8, bounds: z.Rect, visible: bool) !void {
        const window = self.window.nativeHandle().?;
        if (zrr_layout(window, 400, 240) != 1) return error.RegionOverlayMissing;
        if (zrr_bounds(window, title, @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.width), @intFromFloat(bounds.height), @intFromBool(visible)) != 1) {
            std.debug.print("region {s} expected={any} visible={}\n", .{ title, bounds, visible });
            return error.RegionGeometryMismatch;
        }
    }
    fn update(self: *State) !void {
        if (zlg_content_count() != 0 or zlg_region_count() != 3) return error.RegionHostCountMismatch;
        try self.check("A", a_bounds, true);
        try self.check("B", b_bounds, true);
        self.failing.fail_index = self.failing.alloc_index;
        const before = self.failing.alloc_index;
        var moved = a_bounds;
        moved.x = 24;
        moved.y = 28;
        moved.width = 151;
        moved.height = 83;
        try self.nodes[0].region.update(.{ .bounds = moved });
        try self.check("A", moved, true);
        const scale = (try self.window.contentSize()).scale;
        try std.testing.expect(scale == 1 or scale == 2);
        try self.nodes[0].region.update(.{ .bounds = .{ .x = 12.25, .y = 19.75, .width = 150.25, .height = 83.5 } });
        try self.check("A", .{ .x = 12, .y = 20, .width = 151, .height = if (scale == 2) 84 else 83 }, true);
        try self.nodes[0].region.update(.{ .bounds = .{ .x = -3.25, .y = 20, .width = 10.5, .height = 40 } });
        try self.check("A", .{ .x = if (scale == 2) -4 else -3, .y = 20, .width = if (scale == 2) 12 else 10, .height = 40 }, true);
        try self.nodes[0].region.update(.{ .bounds = moved });
        try self.check("A", moved, true);
        try self.nodes[1].region.update(.{ .bounds = b_bounds, .visible = false });
        try self.check("B", b_bounds, false);
        if (zwk_focus(self.nodes[1].view.native.?) != 4) return error.NativeInvalidReportedAsOutOfMemory;
        try self.nodes[1].region.update(.{ .bounds = b_bounds });
        try self.check("B", b_bounds, true);
        var empty = moved;
        empty.width = 0;
        try self.nodes[0].region.update(.{ .bounds = empty });
        try self.check("A", empty, false);
        try self.nodes[0].region.update(.{ .bounds = moved });
        try self.check("A", moved, true);
        try std.testing.expectEqual(before, self.failing.alloc_index);
        self.failing.fail_index = std.math.maxInt(usize);
        for (&self.nodes) |*node| {
            try std.testing.expectEqual(node.original.?.generation, node.view.pageId().?.generation);
            _ = try node.view.evaluateJS("saved", .{}, .{ .context = node, .complete = Node.preserved });
        }
    }
    fn replace(self: *State) !void {
        self.failing.fail_index = std.math.maxInt(usize);
        const a = &self.nodes[0];
        _ = try a.view.evaluateJS("99", .{}, .{ .context = a, .complete = Node.detached });
        const scope = try a.view.beginPageCallback(a.original.?);
        var live_scope = true;
        defer if (live_scope) scope.end();
        const stale = a.region;
        try std.testing.expect(try a.region.remove());
        try std.testing.expectError(error.Closed, a.view.postFor(a.original.?, "removed"));
        try std.testing.expect(a.view.native != null);
        scope.end();
        live_scope = false;
        if (a.view.native != null or a.view.config != null or self.detached != 1) return error.RemovedRegionStillPinned;
        try std.testing.expect(zlg_region_count() == 2 and self.nodes[1].view.pageId() != null);
        a.region = try self.owner.reserve(.{ .bounds = a_bounds });
        try std.testing.expect(a.region.index == stale.index and a.region.generation != stale.generation);
        try std.testing.expectError(error.Closed, stale.snapshot());
        self.failing.fail_index = self.failing.alloc_index;
        try std.testing.expectError(error.OutOfMemory, a.view.attachRegion(a.region, a.options()));
        try std.testing.expect(a.view.window == null and a.view.native == null and a.view.config == null);
        self.failing.fail_index = std.math.maxInt(usize);
        try a.view.attachRegion(a.region, a.options());
        try std.testing.expect(zrr_identify(self.window.nativeHandle().?, "A") == 1);
    }
    fn replaceTask(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.replace() catch |err| self.fail(err);
    }
    fn finish(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, "13")) return self.fail(error.PeerDocumentChanged);
        const b = &self.nodes[1];
        _ = b.view.evaluateJS("88", .{}, .{ .context = b, .complete = Node.detached }) catch |err| return self.fail(err);
        if (self.raw_close) gtk_widget_destroy(self.window.nativeHandle().?) else _ = self.window.destroy() catch |err| return self.fail(err);
        self.finished = true;
    }
    fn drain(ptr: *anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(ptr));
        const counts = web.resourceCounts();
        if (!self.finished or self.closed != 1 or counts.states != 0 or counts.handlers != 0 or counts.controllers != 0 or zlg_region_count() != 0) return 1;
        self.timer = 0;
        self.app.quit();
        return 0;
    }
};
fn run(allocator: std.mem.Allocator, raw_close: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{}); // Explicitly dispatch late native cancellation.
    var fault = std.testing.FailingAllocator.init(allocator, .{});
    var state: State = .{ .allocator = allocator, .app = app, .window = undefined, .owner = undefined, .failing = &fault, .raw_close = raw_close };
    const window = try app.createWindow(.{ .width = 400, .height = 240, .on_closed = .{ .context = &state, .notify = State.closedWindow } });
    state.window = window;
    const owner = try z.composition.Owner.create(allocator, window, .{ .capacity = 2 });
    defer {
        owner.detach() catch {};
        owner.close() catch unreachable;
    }
    state.owner = owner;
    for (&state.nodes, 0..) |*node, index| {
        node.* = .{ .state = &state, .index = index };
        node.view = web.View.init(fault.allocator(), node, Node.event);
    }
    state.nodes_ready = true;
    for (&state.nodes) |*node| {
        node.region = try owner.reserve(.{ .bounds = if (node.index == 0) a_bounds else b_bounds });
        try node.view.attachRegion(node.region, node.options());
        try std.testing.expect(zrr_identify(window.nativeHandle().?, if (node.index == 0) "A" else "B") == 1);
    }
    state.timer = g_timeout_add(5, State.drain, &state);
    defer if (state.timer != 0) {
        _ = g_source_remove(state.timer);
    };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.err) |err| return err;
    try std.testing.expect(!watchdog.expired and state.finished and state.closed == 1 and state.detached == 2);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try std.testing.expect(zlg_region_count() == 0 and zlg_content_count() == 0 and zlg_resource_count() == 4);
}
const FreeClose = struct {
    base: std.mem.Allocator,
    window: z.Window,
    view: *web.View,
    fired: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.base.rawAlloc(len, alignment, ret);
    }
    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.base.rawResize(memory, alignment, len, ret);
    }
    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.base.rawRemap(memory, alignment, len, ret);
    }
    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (!self.fired and self.view.native != null and self.view.attachment_phase == .attaching) {
            self.fired = true;
            _ = self.window.destroy() catch unreachable;
        }
        self.base.rawFree(memory, alignment, ret);
    }
};
fn neverEvent(_: *anyopaque, _: *web.View, _: web.Event) void {
    @panic("uninitialized native callback");
}
fn allocationFailure(view_allocator: std.mem.Allocator, base: std.mem.Allocator) !void {
    const app = try z.App.init(base);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try z.composition.Owner.create(base, window, .{ .capacity = 1 });
    defer {
        owner.detach() catch {};
        owner.close() catch unreachable;
    }
    const region = try owner.reserve(.{ .bounds = a_bounds });
    var marker: u8 = 0;
    var view = web.View.init(view_allocator, &marker, neverEvent);
    view.attachRegion(region, .{ .html = "<title>allocation</title>", .storage = .ephemeral, .user_agent = "owned region metadata" }) catch |err| {
        try std.testing.expect(view.window == null and view.region == null and view.native == null and view.config == null);
        return err;
    };
    _ = try region.remove();
    try std.testing.expect(view.window == null and view.native == null and view.config == null);
}
fn closeDuringFinalScratch(base: std.mem.Allocator, custom: bool, rectangular: bool) !void {
    const app = try z.App.init(base);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = if (rectangular) try z.composition.Owner.create(base, window, .{ .capacity = 1 }) else null;
    defer {
        if (owner) |value| {
            value.detach() catch {};
            value.close() catch unreachable;
        }
    }
    const region = if (owner) |value| try value.reserve(.{ .bounds = a_bounds }) else null;
    var marker: u8 = 0;
    var view: web.View = undefined;
    var close: FreeClose = .{ .base = base, .window = window, .view = &view };
    view = web.View.init(close.allocator(), &marker, neverEvent);
    const options: web.Options = if (custom) .{
        .html = "<title>allocation</title>",
        .storage = .ephemeral,
        .custom_schemes = &.{.{ .name = "asset" }},
        .local = .{ .scheme = "asset" },
    } else .{ .html = "<title>allocation</title>", .storage = .ephemeral };
    const result: ?anyerror = blk: {
        if (region) |value| {
            view.attachRegion(value, options) catch |err| break :blk err;
        } else view.attach(window, options) catch |err| break :blk err;
        break :blk null;
    };
    try app.dispatch();
    if (result == null) return error.ClosedDuringFinalScratchAccepted;
    if (result.? != error.Closed or !close.fired) std.debug.print("final scratch custom={} result={s} fired={}\n", .{ custom, @errorName(result.?), close.fired });
    try std.testing.expect(result.? == error.Closed and close.fired);
    try std.testing.expect(view.window == null and view.region == null and view.native == null and view.config == null and view.custom_local_budget == null);
}
pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    for ([_]bool{ false, true }) |rectangular| for ([_]bool{ false, true }) |custom| try closeDuringFinalScratch(allocations.allocator(), custom, rectangular);
    try std.testing.checkAllAllocationFailures(allocations.allocator(), allocationFailure, .{allocations.allocator()});
    try run(allocations.allocator(), false);
    try run(allocations.allocator(), true);
    try std.testing.expect(zlg_resource_count() == 0);
    std.debug.print("Linux rectangular pages: two DOMs/exact geometry, allocation-free move/hide/empty, pinned remove/reuse/OOM, peer identity, pending normal/raw close resources=0\n", .{});
}
