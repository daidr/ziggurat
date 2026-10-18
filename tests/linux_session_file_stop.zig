const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zwk_file_pread_count() u64;
extern fn zlg_region_count() c_uint;

const Late = struct {
    allocator: std.mem.Allocator,
    response: web.resources.OwnedResponse,
    calls: *std.atomic.Value(u32),
    fn dispose(self: *Late) void {
        const allocator = self.allocator;
        self.response.deinit();
        allocator.destroy(self);
    }
    fn accepted(ptr: *anyopaque) void {
        const self: *Late = @ptrCast(@alignCast(ptr));
        _ = self.calls.fetchAdd(1, .release);
        self.dispose();
    }
};
/// The pump and all disk work belong to this one explicit host thread. Its
/// final delivery context is heap owned even on the unexpected accepted path.
const Worker = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    ready: z.Task,
    thread: ?std.Thread = null,
    begin: std.Thread.Semaphore = .{},
    finish: std.Thread.Semaphore = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    failure: std.atomic.Value(u16) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    post_closed: std.atomic.Value(bool) = .init(false),
    late_calls: std.atomic.Value(u32) = .init(0),
    mutex: std.Thread.Mutex = .{},
    response: ?web.OwnedFileResponse = null,

    fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, Worker.run, .{self});
    }
    fn take(self: *Worker) ?web.OwnedFileResponse {
        self.mutex.lock();
        defer self.mutex.unlock();
        var response: ?web.OwnedFileResponse = null;
        std.mem.swap(?web.OwnedFileResponse, &response, &self.response);
        return response;
    }
    fn signalStop(ptr: *anyopaque) !void {
        const self: *Worker = @ptrCast(@alignCast(ptr));
        self.finish.post();
    }
    fn join(self: *Worker) void {
        self.stopping.store(true, .release);
        self.begin.post();
        self.finish.post();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.take()) |value| {
            var response = value;
            response.deinit();
        }
    }
    fn run(self: *Worker) void {
        self.begin.wait();
        if (self.stopping.load(.acquire)) return;
        self.perform() catch |failure| {
            self.failure.store(@intFromError(failure), .release);
            self.app.post(self.ready) catch {};
        };
    }
    fn perform(self: *Worker) !void {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const file = try temporary.dir.createFile("private", .{ .read = true });
        defer file.close();
        const block: [4096]u8 = @splat('p');
        for (0..128) |_| try file.writeAll(&block);
        const position = try file.getPos();
        var prepared = try web.OwnedFileResponse.preparePumped(self.allocator, self.app.owner, file, .{}, 1024 * 1024);
        defer prepared.pump.deinit();
        // Move the response to the protected slot. Only pump stays on worker.
        self.mutex.lock();
        self.response = prepared.response;
        self.mutex.unlock();
        self.app.post(self.ready) catch |failure| {
            if (self.take()) |value| {
                var response = value;
                response.deinit();
            }
            return failure;
        };
        // Session Stop runs before signalStop; it cancels the accepted stream
        // while this worker deliberately has not called pump yet.
        self.finish.wait();
        prepared.pump.pump() catch |failure| {
            if (failure != error.Cancelled) return failure;
            self.cancelled.store(true, .release);
        };
        if (!self.cancelled.load(.acquire)) return error.PumpCompletedBeforeStop;
        try std.testing.expectEqual(position, try file.getPos());

        const late = try self.allocator.create(Late);
        const response = web.resources.OwnedResponse.init(self.allocator, .{ .bytes = "late worker response" }, 128) catch |failure| {
            self.allocator.destroy(late);
            return failure;
        };
        late.* = .{ .allocator = self.allocator, .response = response, .calls = &self.late_calls };
        self.app.post(.{ .context = late, .call = Late.accepted }) catch |failure| {
            // Failed post takes nothing. Reclaim on this same worker.
            late.response.deinit();
            self.allocator.destroy(late);
            if (failure != error.Closed) return failure;
            self.post_closed.store(true, .release);
            return;
        };
        // An unexpected success still transfers a stable context to App.
        return error.LatePostAccepted;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    worker: *Worker,
    session: ?*web.PageSession = null,
    request: ?web.ResourceRequestId = null,
    ticket: ?web.StreamTicket = null,
    accepted: bool = false,
    completions: u32 = 0,
    closed: u32 = 0,
    failure: ?anyerror = null,
    fn fail(self: *State, failure: anyerror) void {
        self.failure = self.failure orelse failure;
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed, .process_failed => self.fail(error.FileSessionFailed),
            else => {},
        }
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, request.path, "/pending") or self.request != null) return self.fail(error.UnexpectedFileRequest);
        self.request = responder.deferResponse(.{ .completion = .{ .context = self, .complete = completed } }) catch |err| return self.fail(err);
        self.worker.begin.post();
    }
    fn completed(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .responded or self.completions != 0) return self.fail(error.FileResponseNotAccepted);
        self.completions += 1;
    }
    fn ready(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const failed = self.worker.failure.load(.acquire);
        if (failed != 0) return self.fail(@errorFromInt(failed));
        if (self.worker.stopping.load(.acquire)) return;
        var response = self.worker.take() orelse return self.fail(error.MissingFileResponse);
        defer response.deinit();
        const session = self.session orelse return self.fail(error.FileSessionClosedEarly);
        self.ticket = session.page.respondFile(self.request.?, &response, .{ .ticket = true }) catch |err| return self.fail(err);
        if (response.native != null or response.metadata.storage != null or self.completions != 1) return self.fail(error.FileResponseWasNotMoved);
        self.accepted = true;
        self.app.quit();
    }
    fn closedSession(ptr: *anyopaque, session: *web.PageSession) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        self.session = null;
        self.allocator.destroy(session);
    }
};

fn stoppedFile(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var worker: Worker = .{ .allocator = allocator, .app = app, .ready = undefined };
    var state: State = .{ .allocator = allocator, .app = app, .worker = &worker };
    worker.ready = .{ .context = &state, .call = State.ready };
    try worker.start();
    defer worker.join();
    // Reverse Stop order closes Session/cancels Control before waking worker.
    var stop_node: z.StopParticipant = .{ .context = &worker, .stop = Worker.signalStop };
    _ = try app.registerStop(&stop_node);
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(allocator, &state, State.event);
    defer if (state.session) |session| {
        std.debug.assert((session.close() catch unreachable) == .closed);
        if (state.session != null) {
            state.session = null;
            allocator.destroy(session);
        }
    };
    defer if (state.ticket) |*ticket| ticket.deinit();
    try state.session.?.open(app, .{ .page = .{ .html = "<script>fetch('/pending').then(r=>r.arrayBuffer()).catch(()=>{})</script>", .storage = .ephemeral, .file_streams = .{ .max_file_bytes = 1024 * 1024 }, .custom_schemes = &.{.{ .name = "asset", .treat_as_secure = true }}, .local = .{ .scheme = "asset", .on_resource = .{ .context = &state, .handle = State.resource } } }, .on_closed = .{ .context = &state, .notify = State.closedSession } });
    const reads = zwk_file_pread_count();
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    // All UI shutdown is complete before joining our worker.
    worker.join();
    if (state.failure) |failure| return failure;
    const failure = worker.failure.load(.acquire);
    if (failure != 0) return @errorFromInt(failure);
    try std.testing.expect(!watchdog.expired and state.accepted and state.closed == 1 and state.session == null and state.completions == 1);
    try std.testing.expect(worker.cancelled.load(.acquire) and worker.post_closed.load(.acquire) and worker.late_calls.load(.acquire) == 0);
    try std.testing.expectEqual(reads, zwk_file_pread_count());
    try std.testing.expect(app.resourceStats().stop_participants == 0 and app.resourceStats().allocated_records == 0 and zlg_region_count() == 0);
}
pub fn run(allocator: std.mem.Allocator) !void {
    try stoppedFile(allocator);
    try @import("linux_session_peers.zig").drain(allocator);
    try std.testing.expectEqualDeep(web.FileResourceCounts{ .streams = 0, .controls = 0, .budgets = 0 }, web.fileResourceCounts());
    std.debug.print("Linux Session file stop: accepted unstarted pump cancelled without pread, worker post Closed retains owned response, join and late physical refs=0\n", .{});
}
