const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const document =
    \\<!doctype html><script>
    \\(async()=>{try{
    \\const check=(v,m)=>{if(!v)throw new Error(m)};
    \\let r=await fetch('/sync');check(r.status===201&&r.headers.get('X-Fixture')==='sync'&&(await r.text())==='sync-body','sync');
    \\r=await fetch('/head',{method:'HEAD'});check(r.headers.get('Content-Length')==='14'&&(await r.text())==='','head');
    \\r=await fetch('/empty');check(r.status===204&&!r.headers.has('Content-Length')&&(await r.text())==='','204');
    \\r=await fetch('/async');check(r.status===202&&(await r.text())==='worker-body','worker');
    \\r=await fetch('/cancel');check(r.status===403,'cancel');
    \\const full=new Promise(resolve=>chrome.webview.addEventListener('message',async e=>{if(e.data==='probe-full'){try{const f=await fetch('/full');check(f.status===404,'full');resolve()}catch(x){chrome.webview.postMessage('error:'+x.message)}}}));
    \\const timeout=fetch('/timeout');await full;r=await timeout;check(r.status===403,'timeout');
    \\fetch('/navigate-pending').catch(()=>{});chrome.webview.postMessage('navigate');
    \\}catch(e){chrome.webview.postMessage('error:'+e.message)}})();
    \\</script>
;
const second =
    \\<!doctype html><script>
    \\chrome.webview.addEventListener('message',e=>{if(e.data==='close')fetch('/closing').catch(()=>{})});
    \\chrome.webview.postMessage('second');
    \\</script>
;
const Kind = enum { document, worker, cancelled, timeout, full, navigation, closing };
const Case = struct {
    state: *State,
    kind: Kind,
    fn complete(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        self.state.complete(self.kind, result);
    }
};
const Work = struct {
    state: *State,
    id: web.ResourceRequestId,
    body: []const u8,
    status: u16,
    late: bool = false,
    closing: bool = false,
    gate: zio.ResetEvent = .{},
    thread: ?std.Thread = null,
    owned: ?web.resources.OwnedResponse = null,
    err: ?anyerror = null,
    fn run(self: *Work) void {
        if (self.late or self.closing) self.gate.wait();
        self.owned = web.resources.OwnedResponse.init(self.state.allocator, .{ .status = self.status, .mime = "text/html", .headers = &.{.{ .name = "X-Fixture", .value = "worker" }}, .bytes = self.body }, 1024 * 1024) catch |err| {
            self.err = err;
            return;
        };
        self.state.app.post(.{ .context = self, .call = deliver }) catch |err| {
            self.err = err;
            self.owned.?.deinit();
            self.owned = null;
        };
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *Work = @ptrCast(@alignCast(ptr));
        self.state.view.respondOwned(self.id, &self.owned.?) catch |err| {
            if (!self.late or err != error.StaleRequest) self.state.fail(err);
            if (self.owned.?.storage == null) self.state.fail(error.FailedResponseConsumed);
            self.owned.?.deinit();
            self.owned = null;
            self.state.late_seen = true;
            self.state.maybeClose();
            return;
        };
        if (self.owned.?.storage != null) self.state.fail(error.SuccessDidNotConsume);
        self.owned = null;
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    view: *web.View,
    cases: [7]Case = undefined,
    calls: [7]u32 = @splat(0),
    works: [4]Work = undefined,
    work_count: usize = 0,
    navigation_started: bool = false,
    navigate_requested: bool = false,
    navigation_id: ?web.ResourceRequestId = null,
    late_seen: bool = false,
    second_boot: bool = false,
    second_complete: bool = false,
    close_queued: bool = false,
    failed: ?anyerror = null,
    done: bool = false,
    loading_document: bool = false,
    fn fail(self: *State, err: anyerror) void {
        if (self.failed == null) {
            self.failed = err;
            std.debug.print("resource async: {s}\n", .{@errorName(err)});
        }
        self.app.quit();
    }
    fn options(self: *State, kind: Kind, timeout: u32) web.resources.DeferOptions {
        return .{ .timeout_ms = timeout, .completion = .{ .context = &self.cases[@backingInt(kind)], .complete = Case.complete } };
    }
    fn startWork(self: *State, id: web.ResourceRequestId, body: []const u8, status: u16, late: bool, closing: bool) !void {
        if (self.work_count == self.works.len) return error.TooManyWorkers;
        const work = &self.works[self.work_count];
        work.* = .{ .state = self, .id = id, .body = body, .status = status, .late = late, .closing = closing };
        self.work_count += 1;
        work.thread = try std.Thread.spawn(.{}, Work.run, .{work});
    }
    fn complete(self: *State, kind: Kind, result: web.resources.Result) void {
        self.calls[@backingInt(kind)] += 1;
        const valid = switch (kind) {
            .document, .worker => result == .responded,
            .cancelled => result == .cancelled,
            .timeout => result == .timed_out,
            .navigation => result == .page_changed,
            .closing => result == .detached,
            .full => false,
        };
        if (!valid) {
            std.debug.print("resource terminal kind={s} result={s}\n", .{ @tagName(kind), @tagName(result) });
            return self.fail(error.WrongTerminalReason);
        }
        if (kind == .closing) {
            self.done = true;
            self.works[3].gate.set();
        }
    }
    fn handle(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, request.path, "/")) {
            self.loading_document = self.view.loading;
            const id = responder.deferResponse(self.options(.document, 5000)) catch |err| return self.fail(err);
            self.startWork(id, document, 200, false, false) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/sync")) {
            responder.respond(.{ .status = 201, .mime = "text/plain", .headers = &.{.{ .name = "X-Fixture", .value = "sync" }}, .bytes = "sync-body" }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/head")) {
            if (request.method != .head) return self.fail(error.WrongMethod);
            responder.respond(.{ .bytes = "representation" }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/empty")) {
            responder.respond(.{ .status = 204 }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/async")) {
            const id = responder.deferResponse(self.options(.worker, 5000)) catch |err| return self.fail(err);
            self.startWork(id, "worker-body", 202, false, false) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/cancel")) {
            const id = responder.deferResponse(self.options(.cancelled, 5000)) catch |err| return self.fail(err);
            var bad = web.resources.OwnedResponse.init(self.allocator, .{ .bytes = "kept" }, 1024) catch |err| return self.fail(err);
            defer bad.deinit();
            bad.response.status = 99;
            self.view.respondOwned(id, &bad) catch |err| {
                if (err != error.InvalidStatus or bad.storage == null) return self.fail(error.InvalidResponseOwnership);
                if (!(id.cancel() catch |cancel_err| return self.fail(cancel_err))) return self.fail(error.CancelLost);
                return;
            };
            self.fail(error.InvalidResponseAccepted);
        } else if (std.mem.eql(u8, request.path, "/timeout")) {
            _ = responder.deferResponse(self.options(.timeout, 1000)) catch |err| return self.fail(err);
            self.app.post(.{ .context = self, .call = triggerFull }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/full")) {
            _ = responder.deferResponse(self.options(.full, 5000)) catch |err| {
                if (err != error.Full) self.fail(err);
                return;
            };
            self.fail(error.FullNotEnforced);
        } else if (std.mem.eql(u8, request.path, "/navigate-pending")) {
            const id = responder.deferResponse(self.options(.navigation, 5000)) catch |err| return self.fail(err);
            self.navigation_id = id;
            self.startWork(id, "old-page", 200, true, false) catch |err| return self.fail(err);
            self.maybeNavigate();
        } else if (std.mem.eql(u8, request.path, "/closing")) {
            const id = responder.deferResponse(self.options(.closing, 5000)) catch |err| return self.fail(err);
            self.startWork(id, "after-close", 200, false, true) catch |err| return self.fail(err);
            self.app.post(.{ .context = self, .call = quit }) catch |err| self.fail(err);
        }
    }
    fn triggerFull(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.view.post("probe-full") catch |err| self.fail(err);
    }
    fn quit(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.quit();
    }
    fn maybeNavigate(self: *State) void {
        if (self.navigate_requested and self.navigation_id != null) self.view.navigateLocal("/two") catch |err| self.fail(err);
    }
    fn maybeClose(self: *State) void {
        if (self.late_seen and self.second_boot and self.second_complete and !self.close_queued) {
            self.close_queued = true;
            self.view.post("close") catch |err| self.fail(err);
        }
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |message| {
                if (std.mem.eql(u8, message, "navigate")) {
                    self.navigate_requested = true;
                    self.maybeNavigate();
                } else if (std.mem.eql(u8, message, "second")) {
                    self.second_boot = true;
                    self.maybeClose();
                } else {
                    std.debug.print("resource page message: {s}\n", .{message});
                    self.fail(error.PageAssertionFailed);
                }
            },
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value == .started and value.started.id.generation > 1 and !self.navigation_started) {
            self.navigation_started = true;
            self.works[2].gate.set();
        }
        if (value == .completed and value.completed.id.generation > 1) {
            if (!value.completed.success) return self.fail(error.SecondLoadFailed);
            self.second_complete = true;
            self.maybeClose();
        }
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "ResourceAsyncSmoke" });
    defer allocator.free(profile);
    const app = try z.App.init(allocator);
    defer app.deinit();
    var view: web.View = undefined;
    var state: State = .{ .allocator = allocator, .app = app, .view = &view };
    for (&state.cases, 0..) |*case, i| case.* = .{ .state = &state, .kind = @fromBackingInt(@intCast(i)) };
    defer for (state.works[0..state.work_count]) |*work| {
        work.gate.set();
        if (work.thread) |thread| thread.join();
    };
    view = web.View.init(allocator, &state, State.event);
    const window = try app.createWindow(.{});
    try view.attach(window, .{ .html = "", .user_data_folder = profile, .local = .{ .dynamic_document = true, .resources = &.{.{ .path = "/two", .mime = "text/html", .bytes = second }}, .on_resource = .{ .context = &state, .handle = State.handle } }, .resource_limits = .{ .max_pending = 1 }, .page_listener = .{ .context = &state, .event = State.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    for (state.works[0..state.work_count]) |*work| {
        work.gate.set();
        if (work.thread) |thread| thread.join();
        work.thread = null;
    }
    if (watchdog.expired) std.debug.print("resource timeout calls={any} native pending={d}\n", .{ state.calls, web.deferredResourceCount() });
    try std.testing.expect(!watchdog.expired and state.failed == null and state.done and state.loading_document and state.late_seen);
    for (state.calls, 0..) |calls, i| try std.testing.expectEqual(@as(u32, if (i == @backingInt(Kind.full)) 0 else 1), calls);
    for (state.works[0..state.work_count], 0..) |work, i| {
        if (i == 3) try std.testing.expectEqual(error.Closed, work.err.?) else try std.testing.expect(work.err == null);
        try std.testing.expect(work.owned == null);
    }
    const refs = web.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), refs.states + refs.handlers + refs.controllers + web.deferredResourceCount());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("resource async smoke passed: loading document deferral, worker-owned response/headers, HEAD/204, cancel/timeout/Full, navigation stale ownership, post Closed/detach; COM/deferrals=0\n", .{});
}
