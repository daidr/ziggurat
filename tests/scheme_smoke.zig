const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const w = @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
const document =
    \\<!doctype html><script>
    \\chrome.webview.addEventListener('message',e=>{if(e.data==='host')chrome.webview.postMessage('pong')});
    \\chrome.webview.postMessage('boot');
    \\(async()=>{const check=(v,m)=>{if(!v)throw Error(m)};try{
    \\check(location.protocol==='asset:'&&location.hostname==='fixture'&&isSecureContext===expectSecure,'registered-origin');
    \\let r=await fetch('/static');check(r.status===200&&(await r.text())==='static-data','static');
    \\r=await fetch('/async');check(r.status===202&&(await r.text())==='worker-data','async');
    \\let posted=false;try{r=await fetch('/post',{method:'POST',headers:{'Content-Type':'text/plain','X-Probe':'allowed'},body:'private'});posted=r.status===201&&(await r.text())==='accepted'}catch(e){}check(posted===expectPost,'POST/CORS-origin');
    \\for(const options of [{method:'PUT'},{headers:{Unusual:'not-granted'}}]){r=await fetch('/never',options);check(r.status===403,'method/header-deny')}
    \\r=await fetch('asset://fixture:123/port-alias');check(r.status===200&&(await r.text())==='same-origin-alias','port-normalization');
    \\r=await fetch('asset://user@fixture/user-alias');check(r.status===200&&(await r.text())==='same-origin-alias','userinfo-normalization');
    \\for(const url of ['asset://other/never','unused://fixture/never']){
    \\let denied=false;try{r=await fetch(url);denied=r.status===403}catch(e){denied=true}check(denied,'authority-deny:'+url)}
    \\await fetch('/done');
    \\}catch(e){fetch('/fail?'+encodeURIComponent(e.message)).catch(()=>{})}})();
    \\</script>
;
const registrations = [_]web.SchemeRegistration{
    .{ .name = "unused" },
    .{ .name = "asset", .treat_as_secure = true, .request_origins = &.{"asset://fixture"} },
};
pub const Fixture = struct {
    allocator: std.mem.Allocator,
    temporary: *std.testing.TmpDir,
    profile: ?[]u8 = null,
    handles: [16]?*anyopaque = @splat(null),
    count: usize = 0,
    cleanup: bool = false,
    runtime_started: bool = false,
    closed: bool = false,
    err: ?anyerror = null,
    pub fn run(self: *Fixture) void {
        self.work() catch |err| {
            self.err = err;
        };
    }
    fn work(self: *Fixture) !void {
        if (!self.cleanup) {
            try self.temporary.dir.makeDir("profile");
            self.profile = try self.temporary.dir.realpathAlloc(self.allocator, "profile");
            return;
        }
        defer {
            for (self.handles[0..self.count]) |handle| if (handle) |value| {
                _ = w.CloseHandle(value);
            };
            self.temporary.dir.close();
            self.temporary.parent_dir.close();
            self.closed = true;
        }
        if (self.runtime_started and self.count == 0) {
            std.debug.print("scheme private profile retained: {?s}\n", .{self.profile});
            return error.BrowserShutdownUnconfirmed;
        }
        for (self.handles[0..self.count]) |handle| if (w.WaitForSingleObject(handle.?, 10_000) != w.WAIT_OBJECT_0) return error.BrowserShutdownUnconfirmed;
        try self.temporary.parent_dir.deleteTree(&self.temporary.sub_path);
    }
    pub fn capture(self: *Fixture, view: *web.View) !void {
        var pid: c_uint = 0;
        if (zwv_browser_process_id(view.native.?, &pid) < 0 or pid == 0) return error.NoBrowserPid;
        const handle = w.OpenProcess(w.SYNCHRONIZE, w.FALSE, pid) orelse return error.OpenBrowserFailed;
        if (self.count == self.handles.len) {
            _ = w.CloseHandle(handle);
            return error.TooManyBrowserEpochs;
        }
        self.handles[self.count] = handle;
        self.count += 1;
    }
};
const Work = struct {
    state: *State,
    id: web.ResourceRequestId,
    thread: ?std.Thread = null,
    owned: ?web.resources.OwnedResponse = null,
    err: ?anyerror = null,
    fn run(self: *Work) void {
        self.owned = web.resources.OwnedResponse.init(self.state.app.allocator, .{ .status = 202, .bytes = "worker-data" }, 1024) catch |err| {
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
            self.owned.?.deinit();
            return self.state.fail(err);
        };
        if (self.owned.?.storage != null) self.state.fail(error.ResponseNotConsumed);
        self.owned = null;
    }
};
const State = struct {
    app: *z.App,
    view: *web.View,
    fixture: *Fixture,
    html: []const u8,
    registry: [2]web.SchemeRegistration = registrations,
    allow_post: bool,
    incompatible: web.View = undefined,
    phase: enum { denied, trusted, crashing, recovering } = .denied,
    done: bool = false,
    loaded: bool = false,
    suite: bool = false,
    pong: bool = false,
    queued: bool = false,
    incompatible_seen: bool = false,
    failure: ?anyerror = null,
    works: [3]Work = undefined,
    work_count: usize = 0,
    terminals: u32 = 0,
    loads: u32 = 0,
    messages: u32 = 0,
    fn options(self: *State) web.Options {
        return .{ .html = self.html, .user_data_folder = self.fixture.profile.?, .custom_schemes = &self.registry, .tools = .{ .cookies = true }, .local = .{ .scheme = "asset", .host = "fixture", .scheme_ipc = self.phase != .denied, .methods = .{ .post = true }, .request_headers = &.{ .{ .name = "Content-Type", .exact_value = "text/plain" }, .{ .name = "X-Probe", .exact_value = "allowed" } }, .resources = &.{.{ .path = "/static", .mime = "text/plain", .bytes = "static-data" }}, .on_resource = .{ .context = self, .handle = resource } }, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("scheme smoke phase={s} error={s} hr=0x{x:0>8} loads={d} suite={} pong={}\n", .{ @tagName(self.phase), @errorName(err), @as(u32, @bitCast(self.view.last_hresult)), self.loads, self.suite, self.pong });
        }
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => self.fixture.capture(view) catch |err| self.fail(err),
            .failed => |hr| {
                std.debug.print("scheme native failure=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
                self.fail(error.NativeFailure);
            },
            .process_failed => {
                if (self.phase != .crashing) return self.fail(error.UnexpectedProcessFailure);
                self.phase = .recovering;
                self.view.recover() catch |err| self.fail(err);
            },
            .message => |message| {
                if (self.phase == .denied) return self.fail(error.DefaultSchemeIpcAccepted);
                self.messages += 1;
                if (std.mem.eql(u8, message, "boot")) {
                    self.view.post("host") catch |err| self.fail(err);
                } else if (std.mem.eql(u8, message, "pong")) {
                    self.pong = true;
                    self.advanceWhenReady();
                } else self.fail(error.UnexpectedMessage);
            },
            else => {},
        }
    }
    fn noCookie(_: *anyopaque, _: web.tools.Result) void {
        @panic("denied Cookie operation took completion ownership");
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value == .completed) {
            if (!value.completed.success) return self.fail(error.LoadFailed);
            self.loaded = true;
            self.loads += 1;
            if (self.phase == .denied) {
                std.testing.expectError(error.IpcOriginDenied, view.post("denied")) catch |err| return self.fail(err);
                var changed = self.options();
                changed.user_data_folder = "C:\\AnotherSchemeProfile";
                changed.custom_schemes = &.{.{ .name = "different" }};
                changed.local = null;
                std.testing.expectError(error.SchemeEnvironmentChange, view.reload(changed)) catch |err| return self.fail(err);
            }
            std.testing.expectError(error.OriginDenied, view.getCookies("asset://fixture/", .{}, .{ .context = self, .complete = noCookie })) catch |err| return self.fail(err);
            self.advanceWhenReady();
        }
    }
    fn terminal(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .responded) return self.fail(error.WrongResourceTerminal);
        self.terminals += 1;
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, request.path, "/async")) {
            if (self.work_count == self.works.len) return self.fail(error.TooManyWorkers);
            const id = responder.deferResponse(.{ .timeout_ms = 5000, .completion = .{ .context = self, .complete = terminal } }) catch |err| return self.fail(err);
            const work = &self.works[self.work_count];
            self.work_count += 1;
            work.* = .{ .state = self, .id = id };
            work.thread = std.Thread.spawn(.{}, Work.run, .{work}) catch |err| return self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/post")) {
            if (!self.allow_post) return self.fail(error.RuntimeCorsOriginDeniedReachedHandler);
            if (request.method != .post) return self.fail(error.WrongMethod);
            responder.respond(.{ .status = 201, .bytes = "accepted" }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/port-alias") or std.mem.eql(u8, request.path, "/user-alias")) {
            const expected = if (std.mem.eql(u8, request.path, "/port-alias")) "asset://fixture/port-alias" else "asset://fixture/user-alias";
            if (!std.mem.eql(u8, request.uri, expected)) return self.fail(error.UnexpectedAuthorityNormalization);
            responder.respond(.{ .bytes = "same-origin-alias" }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/done")) {
            responder.respond(.{}) catch |err| return self.fail(err);
            self.suite = true;
            self.advanceWhenReady();
        } else if (std.mem.eql(u8, request.path, "/fail")) {
            std.debug.print("scheme document failure URI={s}\n", .{request.uri});
            self.fail(error.DocumentAssertion);
        } else {
            std.debug.print("unexpected scheme resource uri={s} method={s} headers={any}\n", .{ request.uri, @tagName(request.method), request.headers });
            self.fail(error.DeniedResourceReachedHandler);
        }
    }
    fn incompatibleEvent(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed => |hr| {
                std.debug.print("scheme same-profile mismatch HRESULT=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
                if (hr >= 0) return self.fail(error.InvalidMismatchStatus);
                self.incompatible_seen = true;
                _ = view.window.?.destroy() catch |err| return self.fail(err);
                self.advanceWhenReady();
            },
            .ready => self.fail(error.IncompatibleEnvironmentAccepted),
            else => {},
        }
    }
    fn advanceWhenReady(self: *State) void {
        if (!self.loaded or !self.suite or self.queued or self.failure != null) return;
        if (self.phase != .denied and (!self.pong or !self.incompatible_seen)) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.loaded = false;
        self.suite = false;
        self.pong = false;
        switch (self.phase) {
            .denied => {
                self.phase = .trusted;
                self.view.reload(self.options()) catch |err| return self.fail(err);
                self.incompatible = web.View.init(self.app.allocator, self, incompatibleEvent);
                const window = self.app.createWindow(.{}) catch |err| return self.fail(err);
                self.incompatible.attach(window, .{ .html = "", .user_data_folder = self.fixture.profile.?, .custom_schemes = &.{.{ .name = "incompatible" }} }) catch |err| return self.fail(err);
            },
            .trusted => {
                self.phase = .crashing;
                var pid: c_uint = 0;
                if (zwv_browser_process_id(self.view.native.?, &pid) < 0 or pid == 0) return self.fail(error.NoBrowserPid);
                // Only the browser belonging to this fixture's private profile.
                const process = w.OpenProcess(w.PROCESS_TERMINATE, w.FALSE, pid) orelse return self.fail(error.OpenBrowserFailed);
                defer _ = w.CloseHandle(process);
                if (w.TerminateProcess(process, 0x7f) == 0) self.fail(error.TerminateBrowserFailed);
            },
            .recovering => {
                self.done = true;
                self.app.quit();
            },
            else => self.fail(error.InvalidPhase),
        }
    }
};
fn runCycle(secure_and_post: bool) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var temporary = std.testing.tmpDir(.{});
    var fixture: Fixture = .{ .allocator = gpa.allocator(), .temporary = &temporary };
    defer {
        if (!fixture.closed) {
            fixture.cleanup = true;
            const cleanup = std.Thread.spawn(.{}, Fixture.run, .{&fixture}) catch @panic("cleanup worker unavailable");
            cleanup.join();
            if (fixture.err) |err| std.debug.print("scheme fixture cleanup={s}\n", .{@errorName(err)});
        }
        if (fixture.profile) |profile| gpa.allocator().free(profile);
    }
    var worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    if (fixture.err) |err| return err;
    const html = try std.fmt.allocPrint(gpa.allocator(), "<script>const expectSecure={s},expectPost={s};</script>{s}", .{ if (secure_and_post) "true" else "false", if (secure_and_post) "true" else "false", document });
    defer gpa.allocator().free(html);
    {
        const app = try z.App.init(gpa.allocator());
        defer app.deinit();
        var view: web.View = undefined;
        var state: State = .{ .app = app, .view = &view, .fixture = &fixture, .html = html, .allow_post = secure_and_post };
        state.registry[1].treat_as_secure = secure_and_post;
        if (!secure_and_post) state.registry[1].request_origins = &.{};
        defer for (state.works[0..state.work_count]) |*work| if (work.thread) |thread| thread.join();
        view = web.View.init(gpa.allocator(), &state, State.event);
        const window = try app.createWindow(.{});
        fixture.runtime_started = true;
        view.attach(window, state.options()) catch |err| {
            std.debug.print("scheme attach HRESULT=0x{x:0>8}\n", .{@as(u32, @bitCast(view.last_hresult))});
            return err;
        };
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        for (state.works[0..state.work_count]) |*work| {
            if (work.thread) |thread| thread.join();
            work.thread = null;
            if (work.err) |err| return err;
        }
        const counts = web.resourceCounts();
        std.debug.print("scheme smoke secure/post={} loads={d} completions={d} messages={d} refs={any}\n", .{ secure_and_post, state.loads, state.terminals, state.messages, counts });
        try std.testing.expect(!watchdog.expired and state.failure == null and state.done and state.incompatible_seen);
        try std.testing.expectEqual(@as(u32, 3), state.loads);
        try std.testing.expectEqual(@as(u32, 3), state.terminals);
        try std.testing.expectEqual(@as(u32, 4), state.messages);
        try std.testing.expectEqual(@as(u32, 0), counts.states + counts.handlers + counts.controllers);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    fixture.cleanup = true;
    worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    if (fixture.err) |err| return err;
}
pub fn main() !void {
    try runCycle(true);
    try runCycle(false);
    std.debug.print("registered scheme smoke passed: true scheme origin/secure context opt-in, resources and worker deferral, POST/CORS-origin/header gates, IPC opt-in, Cookie deny, immutable reload, same-profile mismatch and crash recovery; COM=0\n", .{});
}
