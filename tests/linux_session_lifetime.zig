const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zlg_region_count() c_uint;
const scratch_html = "<title>Final native Session scratch</title>";

const FreeGate = struct {
    child: std.mem.Allocator,
    app: *z.App,
    session: ?*web.PageSession = null,
    action: enum { close, quit },
    scratch: ?[*]u8 = null,
    fired: bool = false,
    native_witness: bool = false,
    notifications: u32 = 0,
    fn allocator(self: *FreeGate) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FreeGate = @ptrCast(@alignCast(ptr));
        const memory = self.child.rawAlloc(len, alignment, ra) orelse return null;
        if (len == scratch_html.len + 1) if (self.session) |session| {
            if (session.phase == .opening and session.page.config != null and session.page.native == null) {
                std.debug.assert(self.scratch == null);
                self.scratch = memory;
            }
        };
        return memory;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FreeGate = @ptrCast(@alignCast(ptr));
        // Allocator.free poisons contents before rawFree; identify the exact
        // allocation captured after owned configuration, rather than its data.
        if (!self.fired and self.scratch == bytes.ptr and bytes.len == scratch_html.len + 1) {
            self.scratch = null;
            if (self.session) |session| if (session.phase == .opening and session.page.native != null) {
                // startWebKit frees this HTML scratch last. The native object
                // is published, while generic open still pins Session/App.
                self.fired = true;
                self.native_witness = true;
                switch (self.action) {
                    .close => std.debug.assert((session.close() catch unreachable) == .deferred),
                    .quit => self.app.quit(),
                }
            };
        }
        self.child.rawFree(bytes, alignment, ra);
    }
    fn event(_: *anyopaque, _: *web.View, _: web.Event) void {}
    fn closed(ptr: *anyopaque, _: *web.PageSession) void {
        const self: *FreeGate = @ptrCast(@alignCast(ptr));
        self.notifications += 1;
    }
};

fn finalScratch(allocator: std.mem.Allocator, action: @FieldType(FreeGate, "action")) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var gate: FreeGate = .{ .child = allocator, .app = app, .action = action };
    var session = web.PageSession.init(gate.allocator(), &gate, FreeGate.event);
    gate.session = &session;
    defer _ = session.close() catch unreachable;
    try std.testing.expectError(error.Closed, session.open(app, .{ .page = .{ .html = scratch_html, .user_agent = "Final scratch witness agent", .storage = .ephemeral }, .on_closed = .{ .context = &gate, .notify = FreeGate.closed } }));
    try std.testing.expect(gate.fired and gate.native_witness and gate.notifications == 0);
    try std.testing.expect(session.phase == .closed and session.page.native == null and session.page.config == null);
    try std.testing.expect(app.resourceStats().stop_participants == 0 and app.resourceStats().allocated_records == 0);
    if (action == .quit) try app.finishShutdown();
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, web.resourceCounts());
}

const Queued = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window,
    session: ?*web.PageSession = null,
    loads: u32 = 0,
    notifications: u32 = 0,
    after_calls: u32 = 0,
    resources_released: u32 = 0,
    failure: ?anyerror = null,
    fn fail(self: *Queued, failure: anyerror) void {
        self.failure = self.failure orelse failure;
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *Queued = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed, .process_failed => self.fail(error.QueuedSessionFailed),
            .resources_released => self.resources_released += 1,
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *Queued = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        self.loads += 1;
        if (!value.completed.success or self.loads != 1) return self.fail(error.QueuedDocumentReloaded);
        view.reload(.{ .html = "<title>Unissued queued replacement</title>", .storage = .ephemeral }) catch |err| return self.fail(err);
        if (!view.recovering or view.pending_config == null) return self.fail(error.RecoveryTaskNotAccepted);
        // Native recoveryDispatch was posted first and owns only its C anchor.
        // Session closes/frees when this callback pin ends, before that task.
        const session = self.session orelse return self.fail(error.QueuedSessionMissing);
        const disposition = session.close() catch |err| return self.fail(err);
        if (disposition != .deferred) return self.fail(error.ClosedDuringActiveCallback);
        self.app.post(.{ .context = self, .call = after }) catch |err| self.fail(err);
    }
    fn closed(ptr: *anyopaque, session: *web.PageSession) void {
        const self: *Queued = @ptrCast(@alignCast(ptr));
        self.notifications += 1;
        self.session = null;
        self.allocator.destroy(session);
    }
    fn after(ptr: *anyopaque) void {
        const self: *Queued = @ptrCast(@alignCast(ptr));
        self.after_calls += 1;
        if (self.session != null or self.notifications != 1 or self.resources_released != 0) return self.fail(error.QueuedCallbackOutlivedSession);
        _ = self.window.destroy() catch |err| return self.fail(err);
        self.app.quit();
    }
};

fn queuedClose(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Queued = .{ .allocator = allocator, .app = app, .window = try app.createWindow(.{}) };
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(allocator, &state, Queued.event);
    defer if (state.session) |session| {
        std.debug.assert((session.close() catch unreachable) == .closed);
        if (state.session != null) {
            state.session = null;
            allocator.destroy(session);
        }
    };
    try state.session.?.open(app, .{ .page = .{ .html = "<title>Original queued Session</title>", .storage = .ephemeral, .page_listener = .{ .context = &state, .event = Queued.page } }, .on_closed = .{ .context = &state, .notify = Queued.closed } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |failure| return failure;
    try std.testing.expect(!watchdog.expired and state.loads == 1 and state.notifications == 1 and state.after_calls == 1 and state.resources_released == 0 and state.session == null);
    try std.testing.expect(app.resourceStats().allocated_records == 0 and app.resourceStats().stop_participants == 0 and zlg_region_count() == 0);
}
pub fn run(allocator: std.mem.Allocator) !void {
    try finalScratch(allocator, .close);
    try finalScratch(allocator, .quit);
    try queuedClose(allocator);
    try @import("linux_session_peers.zig").drain(allocator);
    std.debug.print("Linux Session lifetime: native-created last scratch free close/quit rejects open, queued native recovery after Session self-free is silent; resources=0\n", .{});
}
