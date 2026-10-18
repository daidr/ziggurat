const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Fixture = @import("scheme_smoke.zig").Fixture;
const Watchdog = @import("watchdog.zig").Watchdog;
const Phase = enum { default_deny, allowed, denied, gesture, timeout, navigate, closing };
const origin = "https://app.ziggurat.invalid";
const next_document = "<script>chrome.webview.postMessage('navigated')</script>";
const Case = struct {
    state: *State,
    phase: Phase,
    id: web.PermissionId = undefined,
    thread: ?std.Thread = null,
    err: ?anyerror = null,
    fn complete(ptr: *anyopaque, result: web.permissions.Result) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        const expected = switch (self.phase) {
            .allowed => result == .decided and result.decided == .allow_ephemeral,
            .denied => result == .decided and result.decided == .deny_ephemeral,
            .timeout => result == .timed_out,
            .navigate => result == .page_changed,
            .closing => result == .detached,
            else => false,
        };
        if (!expected) {
            std.debug.print("permission phase={s} unexpected result={any}\n", .{ @tagName(self.phase), result });
            return self.state.fail(error.WrongPermissionTerminal);
        }
        self.state.terminals[@intFromEnum(self.phase)] += 1;
        self.state.advanceWhenReady();
    }
    fn worker(self: *Case) void {
        self.state.app.post(.{ .context = self, .call = deliver }) catch |err| {
            self.err = err;
        };
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        self.state.view.decidePermission(self.id, if (self.phase == .allowed) .allow_ephemeral else .deny_ephemeral) catch |err| self.state.fail(err);
    }
};
const State = struct {
    app: *z.App,
    view: *web.View,
    fixture: *Fixture,
    phase: Phase = .default_deny,
    html: [4096]u8 = undefined,
    cases: [32]Case = undefined,
    case_count: usize = 0,
    offers: [7]usize = @splat(0),
    terminals: [7]usize = @splat(0),
    loaded: bool = false,
    script_done: bool = false,
    next_started: bool = false,
    queued: bool = false,
    resource_pending: bool = false,
    resource_detached: usize = 0,
    script_detached: usize = 0,
    tool_detached: usize = 0,
    done: bool = false,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("permission smoke phase={s} error={s} hr=0x{x:0>8}\n", .{ @tagName(self.phase), @errorName(err), @as(u32, @bitCast(self.view.last_hresult)) });
        }
        self.app.quit();
    }
    fn options(self: *State) web.Options {
        const rounds: u8 = if (self.phase == .navigate or self.phase == .closing) 1 else 2;
        const text = std.fmt.bufPrint(&self.html,
            \\<script>{s}
            \\(async()=>{{try{{const results=[];for(let i=0;i<{d};i++)results.push(await Notification.requestPermission());
            \\chrome.webview.postMessage('result:'+results.join('/')+':state='+Notification.permission)
            \\}}catch(e){{chrome.webview.postMessage('error:'+e.message)}}}})();</script>
        , .{ if (self.phase == .closing) "fetch('/hold').catch(()=>{});" else "", rounds }) catch unreachable;
        return .{ .html = text, .user_data_folder = self.fixture.profile.?, .local = .{ .resources = &.{.{ .path = "/next", .mime = "text/html", .bytes = next_document }}, .on_resource = .{ .context = self, .handle = resource } }, .permissions = if (self.phase == .default_deny) null else .{ .grants = &.{.{ .origin = origin, .kinds = .{ .notifications = true } }}, .handler = .{ .context = self, .handle = offer }, .require_user_gesture = self.phase == .gesture, .limits = .{ .max_pending = 2 } }, .tools = .{ .cookies = true }, .page_listener = .{ .context = self, .event = page } };
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.fixture.capture(view) catch |err| return self.fail(err);
                if (self.phase == .default_deny and web.actionResourceCounts().budgets != 0) self.fail(error.DefaultAllocatedActionBudget);
            },
            .failed, .process_failed => self.fail(error.NativeFailure),
            .message => |text| {
                if (std.mem.startsWith(u8, text, "error:")) {
                    std.debug.print("permission document: {s}\n", .{text});
                    return self.fail(error.DocumentError);
                }
                if (std.mem.eql(u8, text, "navigated")) {
                    self.script_done = true;
                } else if (std.mem.startsWith(u8, text, "result:")) {
                    std.debug.print("permission native result phase={s}: {s}\n", .{ @tagName(self.phase), text });
                    const expected = if (self.phase == .allowed) "result:granted/granted:" else "result:denied/denied:";
                    if (!std.mem.startsWith(u8, text, expected)) return self.fail(error.WrongNativePermissionDecision);
                    self.script_done = true;
                } else return self.fail(error.UnexpectedMessage);
                self.advanceWhenReady();
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value == .started and self.phase == .navigate) {
            if (value.started.uri) |uri| if (std.mem.endsWith(u8, uri, "/next")) {
                self.next_started = true;
            };
        } else if (value == .completed) {
            if (!value.completed.success) return self.fail(error.LoadFailed);
            if (self.phase != .navigate or self.next_started) self.loaded = true;
            self.advanceWhenReady();
        }
    }
    fn offer(ptr: *anyopaque, request: web.PermissionOffer, responder: *web.PermissionResponder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (request.kind != .notifications or !std.mem.eql(u8, request.origin, origin) or request.page.view != self.view) return self.fail(error.WrongPermissionOffer);
        if (self.phase == .default_deny or self.phase == .gesture) return self.fail(error.UnrequestedPermissionHandler);
        if (self.case_count == self.cases.len) return self.fail(error.TooManyPermissionRequests);
        const case = &self.cases[self.case_count];
        self.case_count += 1;
        case.* = .{ .state = self, .phase = self.phase };
        case.id = responder.deferDecision(.{ .timeout_ms = if (self.phase == .timeout) 20 else 5000, .completion = .{ .context = case, .complete = Case.complete } }) catch |err| return self.fail(err);
        self.offers[@intFromEnum(self.phase)] += 1;
        if (self.phase == .allowed or self.phase == .denied) {
            case.thread = std.Thread.spawn(.{}, Case.worker, .{case}) catch |err| return self.fail(err);
        } else if (self.phase == .navigate) {
            self.app.post(.{ .context = self, .call = navigate }) catch |err| return self.fail(err);
        }
        self.advanceWhenReady();
    }
    fn navigate(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.loaded = false;
        self.view.navigateLocal("/next") catch |err| self.fail(err);
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, request.path, "/hold")) return;
        if (self.phase != .closing) return self.fail(error.UnexpectedResource);
        _ = responder.deferResponse(.{ .timeout_ms = 5000, .completion = .{ .context = self, .complete = resourceComplete } }) catch |err| return self.fail(err);
        self.resource_pending = true;
        self.advanceWhenReady();
    }
    fn resourceComplete(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .detached) return self.fail(error.ResourceDidNotDetach);
        self.resource_detached += 1;
    }
    fn scriptComplete(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .detached) return self.fail(error.ScriptDidNotDetach);
        self.script_detached += 1;
    }
    fn toolComplete(ptr: *anyopaque, result: web.tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .detached) return self.fail(error.ToolDidNotDetach);
        self.tool_detached += 1;
    }
    fn advanceWhenReady(self: *State) void {
        if (self.done or self.queued or self.failure != null or !self.loaded) return;
        const index = @intFromEnum(self.phase);
        if (self.phase == .closing) {
            if (!self.resource_pending or self.offers[index] != 1) return;
        } else if (!self.script_done or self.terminals[index] != self.offers[index]) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.phase == .closing) {
            _ = self.view.evaluateJS("'closing'", .{ .timeout_ms = 5000 }, .{ .context = self, .complete = scriptComplete }) catch |err| return self.fail(err);
            _ = self.view.getCookies(origin, .{ .timeout_ms = 5000 }, .{ .context = self, .complete = toolComplete }) catch |err| return self.fail(err);
            self.done = true;
            self.app.quit();
            return;
        }
        if (self.phase == .navigate) {
            const old = self.cases[self.case_count - 1].id;
            std.testing.expectError(error.StalePermission, self.view.decidePermission(old, .allow_ephemeral)) catch |err| return self.fail(err);
        }
        self.phase = @enumFromInt(@intFromEnum(self.phase) + 1);
        self.loaded = false;
        self.script_done = false;
        self.next_started = false;
        self.view.reload(self.options()) catch |err| self.fail(err);
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var temporary = std.testing.tmpDir(.{});
    var fixture: Fixture = .{ .allocator = gpa.allocator(), .temporary = &temporary };
    defer {
        if (!fixture.closed) {
            fixture.cleanup = true;
            const cleanup = std.Thread.spawn(.{}, Fixture.run, .{&fixture}) catch @panic("cleanup worker unavailable");
            cleanup.join();
            if (fixture.err) |err| std.debug.print("permission profile cleanup: {s}\n", .{@errorName(err)});
        }
        if (fixture.profile) |profile| gpa.allocator().free(profile);
    }
    var worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    if (fixture.err) |err| return err;
    {
        const app = try z.App.init(gpa.allocator());
        defer app.deinit();
        var view: web.View = undefined;
        var state: State = .{ .app = app, .view = &view, .fixture = &fixture };
        defer for (state.cases[0..state.case_count]) |*case| if (case.thread) |thread| thread.join();
        view = web.View.init(gpa.allocator(), &state, State.event);
        const window = try app.createWindow(.{});
        fixture.runtime_started = true;
        try view.attach(window, state.options());
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        for (state.cases[0..state.case_count]) |*case| {
            if (case.thread) |thread| thread.join();
            case.thread = null;
            if (case.err) |err| return err;
        }
        const counts = web.actionResourceCounts();
        std.debug.print("permission offers={any} completions={any} native={any}\n", .{ state.offers, state.terminals, counts });
        try std.testing.expect(!watchdog.expired and state.failure == null and state.done);
        try std.testing.expect(state.offers[0] == 0 and state.offers[3] == 0 and state.offers[1] >= 1 and state.offers[2] >= 1 and state.offers[4] >= 1 and state.offers[5] == 1 and state.offers[6] == 1);
        try std.testing.expectEqualSlices(usize, &state.offers, &state.terminals);
        try std.testing.expect(state.resource_detached == 1 and state.script_detached == 1 and state.tool_detached == 1);
        try std.testing.expectEqual(@as(u32, 0), counts.budgets + counts.permissions + counts.downloads);
        const refs = web.resourceCounts();
        try std.testing.expectEqual(@as(u32, 0), refs.states + refs.handlers + refs.controllers);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    fixture.cleanup = true;
    worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    if (fixture.err) |err| return err;
    std.debug.print("permission smoke passed: default deny/no native budget, explicit ephemeral allow/deny, observed repeat/session behavior, gesture gate, async timeout, stale navigation and four-book quit; COM=0\n", .{});
}
