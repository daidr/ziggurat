const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const FileWorker = @import("linux_session_worker.zig").FileWorker;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn zlg_region_count() c_uint;
extern fn zlg_resource_count() c_uint;

const html =
    \\<!doctype html><style>html,body{margin:0}</style><script>
    \\window.marker=0;
    \\chrome.webview.addEventListener('message',e=>chrome.webview.postMessage(e.data));
    \\fetch('/hold').then(r=>r.text()).then(text=>chrome.webview.postMessage('resource:'+text));
    \\fetch('/file').then(r=>r.arrayBuffer()).then(b=>{const v=new Uint8Array(b);chrome.webview.postMessage(v.length===524325&&v[0]===119&&v[v.length-1]===119?'file-kept':'file-bad')});
    \\</script>
;
const Dimensions = struct { width: u32, height: u32, marker: u32 };
const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    session: ?*web.PageSession = null,
    a: z.Window = undefined,
    b: z.Window = undefined,
    owner_a: *z.composition.Owner = undefined,
    owner_b: ?*z.composition.Owner = null,
    original: ?web.PageId = null,
    region: ?z.composition.Region = null,
    stage: enum { initial, mounted_a, hidden_a, parked, mounted_b, evacuated, remounted } = .initial,
    queued: bool = false,
    echo_pending: bool = false,
    evaluations: u32 = 0,
    ready: u32 = 0,
    loads: u32 = 0,
    closed: u32 = 0,
    done: bool = false,
    initial_started: bool = false,
    final_script: bool = false,
    moved_script: bool = false,
    resource_message: bool = false,
    resource_completed: u32 = 0,
    request: ?web.ResourceRequestId = null,
    file_request: ?web.ResourceRequestId = null,
    file_worker: *FileWorker = undefined,
    file_prepared: bool = false,
    file_delivered: bool = false,
    file_message: bool = false,
    file_ticket: ?web.StreamTicket = null,
    err: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("Linux Session {s}: {s}\n", .{ @tagName(self.stage), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => self.ready += 1,
            .message => |message| {
                if (std.mem.eql(u8, message, "file-kept")) {
                    if (self.file_message) return self.fail(error.DuplicateFile);
                    self.file_message = true;
                    self.finish();
                    return;
                }
                if (std.mem.eql(u8, message, "resource:kept")) {
                    if (self.resource_message) return self.fail(error.DuplicateResource);
                    self.resource_message = true;
                    self.finish();
                    return;
                }
                if (!self.echo_pending or !std.mem.eql(u8, message, "session-echo")) return self.fail(error.UnexpectedMessage);
                self.echo_pending = false;
                _ = view.evaluateJS("({width:innerWidth,height:innerHeight,marker:++window.marker})", .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
            },
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.LoadFailed);
        self.loads += 1;
        if (self.loads != 1) return self.fail(error.DocumentReloaded);
        self.original = view.pageId() orelse return self.fail(error.NoPage);
        self.begin();
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const file = std.mem.eql(u8, request.path, "/file");
        if (!file and !std.mem.eql(u8, request.path, "/hold")) return self.fail(error.UnexpectedResource);
        if (responder.window != null or (if (file) self.file_request != null else self.request != null)) return self.fail(error.ParkedResourceHasWindow);
        const id = responder.deferResponse(.{ .timeout_ms = 10_000, .completion = .{ .context = self, .complete = resourceDone } }) catch |err| return self.fail(err);
        if (file) self.file_request = id else self.request = id;
        self.begin();
    }
    fn resourceDone(ptr: *anyopaque, value: web.resources.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .responded) return self.fail(error.ResourceDidNotSurviveRehost);
        self.resource_completed += 1;
    }
    fn begin(self: *State) void {
        if (self.initial_started or self.original == null or self.request == null or self.file_request == null) return;
        self.initial_started = true;
        self.echo();
    }
    fn finish(self: *State) void {
        if (self.done or !self.final_script or !self.moved_script or !self.resource_message or !self.file_message) return;
        const result = self.session.?.close() catch |err| return self.fail(err);
        if (result != .deferred or self.session == null or self.session.?.page.native == null) return self.fail(error.ClosedInsideCallback);
        self.done = true;
        self.app.quit();
    }
    fn echo(self: *State) void {
        const view = &self.session.?.page;
        if (!std.meta.eql(view.pageId(), self.original)) return self.fail(error.PageIdChanged);
        self.echo_pending = true;
        view.postFor(self.original.?, "session-echo") catch |err| self.fail(err);
    }
    fn fileReady(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.file_worker.err()) |failure| return self.fail(failure);
        self.file_prepared = true;
        self.deliverFile() catch |err| self.fail(err);
    }
    fn moved(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, "true") or self.moved_script) return self.fail(error.PendingScriptChanged);
        switch (self.stage) {
            .initial, .mounted_a, .hidden_a => return self.fail(error.CallbackBeforePark),
            else => {},
        }
        self.moved_script = true;
        self.finish();
    }
    fn deliverFile(self: *State) !void {
        if (!self.file_prepared or self.file_delivered or self.stage != .remounted) return;
        var owned = self.file_worker.take() orelse return error.FileHandoffMissing;
        defer owned.deinit();
        self.file_ticket = try self.session.?.page.respondFile(self.file_request.?, &owned, .{ .ticket = true });
        self.file_delivered = true;
    }
    fn sessionClosed(ptr: *anyopaque, session: *web.PageSession) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        self.session = null;
        self.allocator.destroy(session);
    }
    fn windowClosed(ptr: *anyopaque, value: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!std.meta.eql(value, self.b)) return;
        const owner = self.owner_b orelse return;
        self.owner_b = null;
        owner.close() catch |err| return self.fail(err);
        if (self.stage == .evacuated) self.queue();
    }
    fn evaluated(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .json) return self.fail(error.ScriptFailed);
        const parsed = std.json.parseFromSlice(Dimensions, self.allocator, value.json, .{}) catch |err| return self.fail(err);
        defer parsed.deinit();
        self.evaluations += 1;
        const expected: Dimensions = switch (self.stage) {
            .initial => .{ .width = 620 / self.scale(), .height = 310 / self.scale(), .marker = 1 },
            .mounted_a => .{ .width = 200, .height = 100, .marker = self.evaluations },
            .hidden_a, .parked => .{ .width = 220, .height = 120, .marker = self.evaluations },
            .mounted_b => .{ .width = 300, .height = 180, .marker = 5 },
            .remounted => .{ .width = 250, .height = 140, .marker = 6 },
            .evacuated => return self.fail(error.UnexpectedScript),
        };
        if (!std.meta.eql(parsed.value, expected)) {
            std.debug.print("Linux Session DOM actual={any} expected={any}\n", .{ parsed.value, expected });
            return self.fail(error.IncorrectViewportOrDOM);
        }
        if (self.stage == .mounted_b) {
            var owned = web.resources.OwnedResponse.init(self.allocator, .{ .bytes = "kept" }, 1024) catch |err| return self.fail(err);
            defer owned.deinit();
            self.session.?.page.respondOwned(self.request.?, &owned) catch |err| return self.fail(err);
            self.stage = .evacuated;
            gtk_widget_destroy(self.b.nativeHandle().?);
            if (self.session.?.currentRegion() != null or self.session.?.page.native == null) return self.fail(error.EarlyEvacuationFailed);
            if (self.owner_b == null) self.queue();
        } else if (self.stage == .remounted) {
            self.final_script = true;
            self.finish();
        } else self.queue();
    }
    fn scale(self: *State) u32 {
        return @intFromFloat((self.a.contentSize() catch unreachable).scale);
    }
    fn queue(self: *State) void {
        if (self.queued or self.err != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        const session = self.session orelse return error.SessionEnded;
        switch (self.stage) {
            .initial => {
                self.region = try self.owner_a.reserve(.{ .bounds = .{ .x = 10, .y = 20, .width = 200, .height = 100 } });
                try session.attachRegion(self.region.?);
                self.stage = .mounted_a;
            },
            .mounted_a => {
                try self.region.?.update(.{ .bounds = .{ .x = 10, .y = 20, .width = 220, .height = 120 }, .visible = false });
                self.stage = .hidden_a;
            },
            .hidden_a => {
                _ = try session.page.evaluateJS("window.marker >= 3", .{ .timeout_ms = 10_000 }, .{ .context = self, .complete = moved });
                var tokens: [16]u64 = undefined;
                try std.testing.expectEqual(@as(usize, 1), session.page.eval_book.tokens(&tokens, null).len);
                try session.park();
                try std.testing.expectEqual(@as(usize, 1), session.page.eval_book.tokens(&tokens, null).len);
                try std.testing.expect(session.currentRegion() == null and session.page.window == null);
                try std.testing.expectError(error.Closed, self.region.?.snapshot());
                self.stage = .parked;
                self.file_worker.begin();
            },
            .parked => {
                self.region = try self.owner_b.?.reserve(.{ .bounds = .{ .x = 30, .y = 40, .width = 300, .height = 180 } });
                try session.attachRegion(self.region.?);
                self.stage = .mounted_b;
            },
            .evacuated => {
                try std.testing.expect(self.owner_b == null and self.b.isClosed());
                self.region = try self.owner_a.reserve(.{ .bounds = .{ .x = 60, .y = 50, .width = 250, .height = 140 } });
                try session.attachRegion(self.region.?);
                self.stage = .remounted;
                try self.deliverFile();
            },
            else => return error.UnexpectedStage,
        }
        self.echo();
    }
};

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .allocator = allocator };
    state.a = try app.createWindow(.{ .width = 640, .height = 480 });
    state.b = try app.createWindow(.{ .width = 640, .height = 480, .on_closed = .{ .context = &state, .notify = State.windowClosed } });
    state.owner_a = try z.composition.Owner.create(allocator, state.a, .{ .capacity = 2 });
    defer {
        state.owner_a.detach() catch {};
        state.owner_a.close() catch unreachable;
    }
    state.owner_b = try z.composition.Owner.create(allocator, state.b, .{ .capacity = 2 });
    defer if (state.owner_b) |owner| {
        state.owner_b = null;
        owner.detach() catch {};
        owner.close() catch unreachable;
    };
    state.session = try allocator.create(web.PageSession);
    state.session.?.* = web.PageSession.init(allocator, &state, State.event);
    errdefer if (state.session) |session| {
        const closed = session.close() catch unreachable;
        std.debug.assert(closed == .closed);
        if (state.session != null) allocator.destroy(session);
    };
    var worker: FileWorker = .{ .allocator = allocator, .app = app, .ready = .{ .context = &state, .call = State.fileReady } };
    state.file_worker = &worker;
    try worker.start();
    defer worker.stop();
    state.session.?.open(app, .{ .page = .{ .html = html, .storage = .ephemeral, .file_streams = .{ .max_file_bytes = 1024 * 1024 }, .custom_schemes = &.{.{ .name = "asset", .treat_as_secure = true }}, .local = .{ .scheme = "asset", .scheme_ipc = true, .on_resource = .{ .context = &state, .handle = State.resource } }, .page_listener = .{ .context = &state, .event = State.page } }, .initial_size = .{ .width = 620, .height = 310 }, .on_closed = .{ .context = &state, .notify = State.sessionClosed } }) catch |err| {
        std.debug.print("Linux Session open: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(state.session.?.page.window == null and app.resourceStats().allocated_records == 2);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    worker.stop();
    if (state.file_ticket) |*ticket| ticket.deinit();
    state.file_ticket = null;
    try std.testing.expect(!watchdog.expired);
    if (state.err) |err| return err;
    if (worker.err()) |err| return err;
    try std.testing.expect(state.done and state.closed == 1 and state.ready == 1 and state.loads == 1 and state.evaluations == 6 and state.resource_completed == 2 and state.resource_message and state.file_message);
    try std.testing.expect(state.session == null and zlg_region_count() == 0 and app.resourceStats().stop_participants == 0);
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, web.resourceCounts());
    try std.testing.expect(web.deferredResourceCount() == 0);
    try std.testing.expectEqualDeep(web.custom_local.ResourceCounts{ .budgets = 0, .streams = 0, .body_bytes = 0 }, web.customLocalResourceCounts());
    try std.testing.expectEqualDeep(web.FileResourceCounts{ .streams = 0, .controls = 0, .budgets = 0 }, web.fileResourceCounts());
}
pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    try run(allocations.allocator());
    try @import("linux_session_prepare.zig").run(allocations.allocator());
    try @import("linux_session_geometry.zig").run(allocations.allocator());
    try @import("linux_session_recovery.zig").run(allocations.allocator());
    try @import("linux_session_peers.zig").run(allocations.allocator());
    try @import("linux_session_file_stop.zig").run(allocations.allocator());
    try @import("linux_session_lifetime.zig").run(allocations.allocator());
    try @import("linux_session_stop.zig").run(allocations.allocator());
    const extension = try zio.getEnvVarOwned(allocations.allocator(), "ZIGGURAT_REQUEST_POLICY_EXTENSION");
    defer allocations.allocator().free(extension);
    try @import("linux_session_remote.zig").run(allocations.allocator(), extension);
    try std.testing.expect(zlg_resource_count() == 0);
    std.debug.print("Linux PageSession: no parking window, exact DOM viewport, six IPC/JS cycles, two hosts/hide/park/raw close/rehost, same DOM/PageId, callback close/free, resources=0\n", .{});
}
