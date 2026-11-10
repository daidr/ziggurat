const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const ipc = @import("ziggurat_ipc");
const producer = @import("ziggurat_webview_producer");
const Bridge = producer.Bridge(struct { path: []const u8 });
const Fixture = @import("scheme_smoke.zig").Fixture;
const Watchdog = @import("watchdog.zig").Watchdog;
const html = "<!doctype html><meta charset=utf-8><script>" ++ @embedFile("producer_page") ++ "</script>";
const Work = struct {
    state: *State,
    writer: producer.bytes.Writer,
    wake: *Bridge.DeliveryTask,
    thread: ?std.Thread = null,
    full: std.atomic.Value(u32) = .init(0),
    err: ?anyerror = null,
    fn notify(self: *Work) !void {
        const task = self.wake.preparePost() catch |err| {
            if (err == error.Closed) return;
            return err;
        } orelse return;
        self.state.app.post(task) catch |err| {
            self.wake.notAccepted();
            if (err != error.Closed) return err;
        };
    }
    fn run(self: *Work) void {
        self.produce() catch |err| {
            if (err != error.Closed) self.err = err;
        };
        self.writer.deinit();
        self.notify() catch |err| {
            self.err = err;
        };
        self.wake.deinit();
        // Explicit worker completion; no bridge task calls a detached page.
        self.state.app.post(.{ .context = self, .call = ended }) catch |err| {
            if (err != error.Closed) self.err = err;
        };
    }
    fn produce(self: *Work) !void {
        for (0..4) |index| {
            const chunk: [64]u8 = @splat(@intCast(index + 1));
            while (true) {
                _ = self.writer.tryWrite(&chunk) catch |err| {
                    if (err != error.Full) return err;
                    _ = self.full.fetchAdd(1, .monotonic);
                    try self.notify();
                    try self.writer.waitWritable();
                    continue;
                };
                break;
            }
            try self.notify();
        }
        try self.writer.finish();
    }
    fn ended(context: *anyopaque) void {
        const self: *Work = @ptrCast(@alignCast(context));
        self.state.pending_workers -= 1;
        if (self.err) |err| return self.state.fail(err);
        self.state.drain() catch |err| return self.state.fail(err);
        self.state.maybePark() catch |err| return self.state.fail(err);
        self.state.maybeBind() catch |err| self.state.fail(err);
    }
};
const State = struct {
    app: *z.App,
    fixture: *Fixture,
    bridge: *Bridge = undefined,
    session: ?*web.PageSession = null,
    owner: *z.composition.Owner = undefined,
    window: z.Window = undefined,
    phase: enum { main, after_nav, quit, allocator },
    fault: ClosingAllocator = undefined,
    park_wait: bool = false,
    pause_wait: bool = false,
    loaded: bool = false,
    boot: bool = false,
    done: bool = false,
    closed: u32 = 0,
    ready: u32 = 0,
    accepted: u32 = 0,
    duplicate_acks: u32 = 0,
    budget_failures: u32 = 0,
    old_ack: ?[]u8 = null,
    parked_id: ?web.PageId = null,
    works: [12]Work = undefined,
    work_count: usize = 0,
    pending_workers: usize = 0,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("producer phase={s} failure={s} workers={d} streams={d} wakers={d}\n", .{ @tagName(self.phase), @errorName(err), self.pending_workers, self.bridge.stats().physical_streams, self.bridge.stats().wakers });
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        }
        self.app.quit();
    }
    fn event(context: *anyopaque, page: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (value) {
            .ready => {
                self.ready += 1;
                self.fixture.capture(page) catch |err| self.fail(err);
            },
            .message => |text| self.message(page, text) catch |err| self.fail(err),
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn pageEvent(context: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (value == .started) {
            self.loaded = false;
            self.boot = false;
            self.drain() catch |err| return self.fail(err);
        } else if (value == .completed) {
            if (!value.completed.success) return self.fail(error.NavigationFailed);
            self.loaded = true;
            self.maybeBind() catch |err| self.fail(err);
        }
    }
    fn closedEvent(context: *anyopaque, session: *web.PageSession) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.session = null;
        self.closed += 1;
        self.app.allocator.destroy(session);
    }
    fn maybeBind(self: *State) !void {
        if (!self.boot or !self.loaded or self.pending_workers != 0 or !self.bridge.closed) return;
        if (self.app.phase == .stopping or self.app.phase == .stopped) return;
        if (self.bridge.close() != .closed) return error.BindingStillOwned;
        var random: [16]u8 = undefined;
        zio.random.bytes(&random);
        const fresh = std.fmt.bytesToHex(random, .lower);
        const page = &self.session.?.page;
        try self.bridge.bind(page.pageId().?, try ipc.Session.init(&fresh));
        if (self.old_ack) |old| {
            try std.testing.expectError(error.StaleSession, self.bridge.receive(old));
            try std.testing.expect(!self.bridge.closed);
        }
        const hello = try std.json.Stringify.valueAlloc(self.app.allocator, .{ .kind = "hello", .session = &fresh, .stage = @tagName(self.phase) }, .{});
        defer self.app.allocator.free(hello);
        try page.postFor(page.pageId().?, hello);
    }
    fn drain(self: *State) !void {
        _ = self.bridge.drain(32) catch |err| {
            if (err == error.Closed or err == error.StalePage) return;
            return err;
        };
    }
    fn readyTask(context: *anyopaque, _: *Bridge) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.drain() catch |err| return self.fail(err);
        self.maybeResume() catch |err| self.fail(err);
    }
    /// The page pauses before reading; resume once the worker has met the
    /// full queue. A busy machine can schedule the worker after the pause
    /// message arrives, and its wake task then runs this again.
    fn maybeResume(self: *State) !void {
        if (!self.pause_wait) return;
        var blocked = false;
        for (self.works[0..self.work_count]) |*work| blocked = blocked or work.full.load(.acquire) > 0;
        if (!blocked) return;
        self.pause_wait = false;
        try std.testing.expectEqual(@as(u32, 1), self.bridge.flows[0].?.control.produced.load(.acquire));
        const page = &self.session.?.page;
        try page.postFor(page.pageId().?, "resume");
    }
    fn maybePark(self: *State) !void {
        if (!self.park_wait or self.pending_workers != 0) return;
        self.park_wait = false;
        try self.session.?.page.postFor(self.parked_id.?, "parked");
    }
    fn acceptedQuit(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.accepted += 1;
        std.testing.expect(self.app.phase == .stopping and self.session != null) catch |err| return self.fail(err);
        std.testing.expectError(error.Closed, self.bridge.drain(32)) catch |err| self.fail(err);
    }
    fn message(self: *State, page: *web.View, message_value: []const u8) !void {
        if (std.mem.startsWith(u8, message_value, "producer-failed:")) {
            std.debug.print("{s}\n", .{message_value});
            return error.PageFailed;
        }
        if (std.mem.eql(u8, message_value, "producer-boot")) {
            self.boot = true;
            return self.maybeBind();
        }
        if (std.mem.eql(u8, message_value, "paused")) {
            self.pause_wait = true;
            return self.maybeResume();
        }
        if (std.mem.eql(u8, message_value, "zero-head") or std.mem.eql(u8, message_value, "head-only")) return page.postFor(page.pageId().?, "resume");
        if (std.mem.eql(u8, message_value, "park-now")) {
            self.parked_id = page.pageId();
            try self.session.?.park();
            try std.testing.expect(self.session.?.currentRegion() == null);
            try std.testing.expect(std.meta.eql(self.parked_id, page.pageId()));
            self.park_wait = true;
            return self.maybePark();
        }
        if (std.mem.eql(u8, message_value, "park-done")) {
            const region = try self.owner.reserve(.{ .bounds = .{ .x = 8, .y = 12, .width = 240, .height = 160 } });
            try self.session.?.attachRegion(region);
            return std.testing.expect(std.meta.eql(self.parked_id, page.pageId()));
        }
        if (std.mem.eql(u8, message_value, "navigate-now")) {
            self.phase = .after_nav;
            return page.navigateLocal("/next");
        }
        if (std.mem.eql(u8, message_value, "quit-paused")) {
            try self.app.post(.{ .context = self, .call = acceptedQuit });
            self.done = true;
            self.app.quit();
            return;
        }
        if (std.mem.eql(u8, message_value, "suite-done")) {
            self.done = true;
            self.app.quit();
            return;
        }
        if (self.old_ack == null and std.mem.indexOf(u8, message_value, "\"kind\":\"ack\"") != null) self.old_ack = try self.app.allocator.dupe(u8, message_value);
        var action = try self.bridge.receive(message_value);
        switch (action) {
            .offer => |*offer| {
                defer offer.deinit() catch unreachable;
                const path = offer.params.path;
                if (std.mem.eql(u8, path, "denied")) {
                    try self.bridge.reject(offer, .denied, "private fixture denial");
                    // A native page promise must survive a local conversion
                    // budget failure: queue ownership persists until retry.
                    var hold = try self.bridge.budget.hold(self.bridge.options.max_memory_bytes - self.bridge.stats().used_bytes);
                    try std.testing.expectError(error.Full, self.bridge.drain(32));
                    self.budget_failures += 1;
                    hold.deinit();
                } else if (std.mem.eql(u8, path, "zero") or std.mem.eql(u8, path, "head") or std.mem.eql(u8, path, "allocator")) {
                    var writer = try self.bridge.accept(offer, .{ .length = if (std.mem.eql(u8, path, "head")) 100 else 0 }, .{ .head_only = std.mem.eql(u8, path, "head") });
                    try writer.finish();
                    writer.deinit();
                } else {
                    if (self.work_count == self.works.len) return error.TooManyWorkers;
                    var writer = try self.bridge.accept(offer, .{ .length = 256 }, .{});
                    errdefer writer.deinit();
                    const wake = try self.bridge.createDeliveryTask(self, readyTask);
                    errdefer wake.deinit();
                    const work = &self.works[self.work_count];
                    work.* = .{ .state = self, .writer = try writer.take(), .wake = wake };
                    work.thread = std.Thread.spawn(.{}, Work.run, .{work}) catch |err| {
                        work.writer.deinit();
                        return err;
                    };
                    self.work_count += 1;
                    self.pending_workers += 1;
                }
            },
            .control => self.duplicate_acks += 1,
            .rejected => {},
        }
        if (self.phase == .allocator and action == .offer) {
            self.fault.armed = true;
            try std.testing.expectError(error.Closed, self.bridge.drain(32));
            try std.testing.expect(self.fault.fired and self.session != null);
            self.done = true;
            self.app.quit();
            return;
        }
        try self.drain();
    }
};
const ClosingAllocator = struct {
    backing: std.mem.Allocator,
    state: *State,
    armed: bool = false,
    fired: bool = false,
    fn allocator(self: *ClosingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *ClosingAllocator = @ptrCast(@alignCast(context));
        if (self.armed) {
            self.armed = false;
            self.fired = true;
            const result = self.state.session.?.close() catch @panic("allocator close failed");
            std.debug.assert(result == .deferred and self.state.session != null);
        }
        return self.backing.rawAlloc(len, alignment, address);
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const self: *ClosingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, len, address);
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *ClosingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, len, address);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *ClosingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, address);
    }
};
fn run(allocator: std.mem.Allocator, fixture: *Fixture, phase: @FieldType(State, "phase")) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .fixture = fixture, .phase = phase };
    state.fault = .{ .backing = allocator, .state = &state };
    defer if (state.old_ack) |old| allocator.free(old);
    state.window = try app.createWindow(.{});
    state.owner = try z.composition.Owner.create(allocator, state.window, .{});
    defer state.owner.close() catch @panic("producer owner cleanup failed");
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(if (phase == .allocator) state.fault.allocator() else allocator, &state, State.event);
    try state.session.?.open(app, .{ .page = .{ .html = html, .user_data_folder = fixture.profile.?, .local = .{ .resources = &.{.{ .path = "/next", .mime = "text/html", .bytes = html }} }, .page_listener = .{ .context = &state, .event = State.pageEvent } }, .on_closed = .{ .context = &state, .notify = State.closedEvent } });
    fixture.runtime_started = true;
    try state.session.?.attachRegion(try state.owner.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 320, .height = 200 } }));
    state.bridge = try Bridge.create(allocator, app, .{ .in_flight = 1, .chunk_bytes = 64, .max_total_bytes = 256, .max_memory_bytes = 256 * 1024 });
    defer state.bridge.deinit() catch @panic("producer bridge still owned after joins");
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    for (state.works[0..state.work_count]) |*work| {
        work.thread.?.join();
        if (work.err) |err| return err;
    }
    try std.testing.expect(state.bridge.close() == .closed);
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.done and state.closed == 1 and state.session == null and state.ready == 1);
    try std.testing.expectEqual(if (phase == .quit) @as(u32, 1) else 0, state.accepted);
    if (phase == .main) try std.testing.expect(state.budget_failures == 1 and state.old_ack != null and state.duplicate_acks > 8);
    try std.testing.expect(state.bridge.stats().peak_bytes <= state.bridge.options.max_memory_bytes);
    const counts = web.resourceCounts();
    try std.testing.expect(counts.states == 0 and counts.handlers == 0 and counts.controllers == 0);
    try std.testing.expectEqualDeep(web.PageHostResourceCounts{}, web.pageHostResourceCounts());
    std.debug.print("producer native passed phase={s}: workers={d} ACKs={d} budget-failures={d} accepted={d} requested-peak={d} physical streams/tasks/COM/hosts=0\n", .{ @tagName(phase), state.work_count, state.duplicate_acks, state.budget_failures, state.accepted, state.bridge.stats().peak_bytes });
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("producer fixture leak");
    const allocator = gpa.allocator();
    var temporary = zio.tmpDir(.{});
    var fixture: Fixture = .{ .allocator = allocator, .temporary = &temporary };
    var worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    defer {
        fixture.cleanup = true;
        fixture.err = null;
        worker = std.Thread.spawn(.{}, Fixture.run, .{&fixture}) catch @panic("profile cleanup worker unavailable");
        worker.join();
        if (fixture.profile) |profile| allocator.free(profile);
        if (!fixture.closed) temporary.cleanup();
        if (fixture.err) |err| std.debug.panic("producer profile cleanup: {s}", .{@errorName(err)});
    }
    if (fixture.err) |err| return err;
    try run(allocator, &fixture, .main);
    try run(allocator, &fixture, .quit);
    try run(allocator, &fixture, .allocator);
}
