const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

// Private test server only. No framework HTTP server or worker is introduced.
pub const Server = struct {
    listener: std.Io.net.Server,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    requests: std.atomic.Value(u32) = .init(0),
    frames: std.atomic.Value(u32) = .init(0),
    writes: std.atomic.Value(u32) = .init(0),
    start_html: []const u8 = "",
    // A connection the browser opens ahead and leaves idle must not hold up
    // the next page, so each connection gets its own thread.
    connections: [64]?std.Thread = @splat(null),
    connection_count: usize = 0,
    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn stop(self: *Server) void {
        if (self.thread) |thread| {
            self.stop_requested.store(true, .release);
            const wake = self.listener.socket.address.connect(zio.io(), .{ .mode = .stream }) catch unreachable;
            wake.close(zio.io());
            thread.join();
            self.thread = null;
        }
        for (self.connections[0..self.connection_count]) |connection| connection.?.join();
        self.connection_count = 0;
        self.listener.deinit(zio.io());
    }
    fn run(self: *Server) void {
        while (true) {
            const connection = self.listener.accept(zio.io()) catch return;
            if (self.stop_requested.load(.acquire)) {
                connection.close(zio.io());
                return;
            }
            if (self.connection_count < self.connections.len) {
                if (std.Thread.spawn(.{}, serveConnection, .{ self, connection })) |thread| {
                    self.connections[self.connection_count] = thread;
                    self.connection_count += 1;
                    continue;
                } else |_| {}
            }
            serveConnection(self, connection);
        }
    }
    fn serveConnection(self: *Server, stream: std.Io.net.Stream) void {
        defer stream.close(zio.io());
        self.serve(stream) catch |err| {
            std.debug.print("private server: {s}\n", .{@errorName(err)});
        };
    }
    fn serve(self: *Server, stream: std.Io.net.Stream) !void {
        var buffer: [8192]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n") == null) {
            if (used == buffer.len) return error.RequestTooLarge;
            const n = try zio.net.receive(stream.socket.handle, buffer[used..]);
            if (n == 0) return;
            used += n;
        }
        _ = self.requests.fetchAdd(1, .monotonic);
        var parts = std.mem.splitScalar(u8, buffer[0..used], ' ');
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;
        if (!std.mem.eql(u8, method, "GET")) _ = self.writes.fetchAdd(1, .monotonic);
        if (std.mem.eql(u8, path, "/frame")) _ = self.frames.fetchAdd(1, .monotonic);
        const trusted_html =
            \\<title>trusted</title><script>
            \\chrome.webview.addEventListener('message',e=>{if(e.data==='ping')chrome.webview.postMessage('pong-trusted')});
            \\chrome.webview.postMessage('boot-trusted');
            \\</script>
        ;
        const body = if (std.mem.eql(u8, path, "/start")) self.start_html else if (std.mem.eql(u8, path, "/trusted")) trusted_html else "asset-ok";
        var headers: [512]u8 = undefined;
        const head = if (std.mem.eql(u8, path, "/redirect"))
            try std.fmt.bufPrint(&headers, "HTTP/1.1 302 Found\r\nLocation: /trusted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{})
        else
            try std.fmt.bufPrint(&headers, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        try zio.net.sendAll(stream.socket.handle, head);
        if (!std.mem.eql(u8, path, "/redirect")) try zio.net.sendAll(stream.socket.handle, body);
    }
};

const State = struct {
    app: *z.App,
    view: *web.View,
    profile: []const u8,
    base: []const u8,
    start_url: []const u8,
    redirect_url: []const u8,
    unlisted_url: []const u8,
    grants: [1]web.OriginGrant,
    phase: enum { untrusted, redirect_denied, trusted, snapshot } = .untrusted,
    failed: ?anyerror = null,
    done: bool = false,
    title_ready: bool = false,
    complete: bool = false,
    script_denied: bool = false,
    redirect_denied: bool = false,
    queued: bool = false,
    boot: bool = false,
    pong: bool = false,
    released: bool = false,
    old: ?web.PageId = null,
    current: ?web.PageId = null,
    generation: u64 = 0,
    fn options(self: *State, trusted: bool) web.Options {
        self.grants[0].ipc = trusted;
        return .{
            .html = "",
            .user_data_folder = self.profile,
            .remote = .{ .url = if (trusted) self.redirect_url else self.start_url, .origins = &self.grants, .credentials = .profile, .allow_insecure_loopback = true, .allow_redirects = trusted },
            .policy = .{ .navigation = .notify, .frame_navigation = .notify },
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn fail(self: *State, err: anyerror) void {
        self.failed = err;
        std.debug.print("remote page smoke phase={s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |message| {
                if (self.phase != .trusted and self.phase != .snapshot) return self.fail(error.UntrustedIpcReceived);
                if (std.mem.eql(u8, message, "boot-trusted")) self.boot = true else if (std.mem.eql(u8, message, "pong-trusted")) self.pong = true else if (std.mem.eql(u8, message, "snapshot-ok")) {
                    self.done = true;
                    const result = view.window.?.destroy() catch |err| return self.fail(err);
                    if (result != .deferred) return self.fail(error.CloseNotPinned);
                    self.app.quit();
                } else return self.fail(error.UnexpectedMessage);
            },
            .resources_released => self.released = true,
            .policy_request => |request| {
                if (request.kind == .navigation) {
                    if (std.mem.endsWith(u8, request.uri, "/script")) self.script_denied = true;
                    if (std.mem.endsWith(u8, request.uri, "/trusted")) self.redirect_denied = true;
                }
            },
            .failed => return self.fail(error.NativeFailure),
            .process_failed => return self.fail(error.ProcessFailure),
            else => {},
        }
        self.check();
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .started => |started| {
                if (!started.redirected) {
                    if (started.id.generation <= self.generation) return self.fail(error.GenerationReused);
                    self.generation = started.id.generation;
                    self.current = started.id;
                    self.complete = false;
                    if (self.old) |old| {
                        view.postFor(old, "must-not-send") catch |err| {
                            if (err != error.StalePage) return self.fail(err);
                            return;
                        };
                        return self.fail(error.OldPageAccepted);
                    }
                }
            },
            .completed => |completed| {
                self.complete = true;
                if (!completed.success and self.phase != .redirect_denied) {
                    std.debug.print("remote load native status={d}\n", .{completed.native_status});
                    return self.fail(error.UnexpectedLoadFailure);
                }
                if (!completed.success and view.pageId() != null) return self.fail(error.FailedPageStillActive);
            },
            .title_changed => |title| if (title.title) |text| {
                if (std.mem.eql(u8, text, "ready-start")) self.title_ready = true;
            },
            else => {},
        }
        self.check();
    }
    fn check(self: *State) void {
        if (self.failed != null or self.done or self.queued) return;
        const ready = switch (self.phase) {
            .untrusted => self.complete and self.title_ready and self.script_denied,
            .redirect_denied => self.complete and self.redirect_denied,
            .trusted => self.complete and self.boot,
            .snapshot => false,
        };
        if (ready) {
            self.queued = true;
            self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
        }
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        switch (self.phase) {
            .untrusted => {
                self.view.post("secret") catch |err| {
                    if (err != error.IpcOriginDenied) return self.fail(err);
                    self.view.navigateRemote(self.unlisted_url) catch |denied| {
                        if (denied != error.OriginDenied) return self.fail(denied);
                        self.view.navigateRemote("file:///C:/must-not-open.html") catch |file_denied| {
                            if (file_denied != error.OriginDenied) return self.fail(file_denied);
                            self.old = self.current;
                            self.phase = .redirect_denied;
                            self.complete = false;
                            self.view.navigateRemote(self.redirect_url) catch |nav_err| self.fail(nav_err);
                            return;
                        };
                        return self.fail(error.FileSchemeAccepted);
                    };
                    return self.fail(error.UnlistedOriginAccepted);
                };
                return self.fail(error.UntrustedPostAccepted);
            },
            .redirect_denied => {
                self.phase = .trusted;
                self.complete = false;
                self.view.reload(self.options(true)) catch |err| self.fail(err);
            },
            .trusted => {
                if (!self.released) return self.fail(error.OldConfigNotReleased);
                if (!self.pong) {
                    self.view.postFor(self.current.?, "ping") catch |err| self.fail(err);
                } else {
                    self.done = true;
                    _ = self.view.window.?.destroy() catch |err| return self.fail(err);
                    self.app.quit();
                }
            },
            else => self.fail(error.InvalidPhase),
        }
    }
};

fn verifyReleased(app: *z.App) !void {
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    const counts = web.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.states);
    try std.testing.expectEqual(@as(u32, 0), counts.handlers);
    try std.testing.expectEqual(@as(u32, 0), counts.controllers);
}
fn runSnapshot(allocator: std.mem.Allocator, directory: std.Io.Dir, profile: []const u8) !void {
    const document = try directory.createFile(zio.io(), "页面.html", .{ .read = true });
    defer document.close(zio.io());
    try document.writeStreamingAll(zio.io(), "<title>private file snapshot</title><script>fetch('/asset.txt').then(r=>r.text()).then(t=>{if(t==='private-file-bytes')chrome.webview.postMessage('snapshot-ok')})</script>");
    const asset = try directory.createFile(zio.io(), "资源.txt", .{ .read = true });
    defer asset.close(zio.io());
    try asset.writeStreamingAll(zio.io(), "private-file-bytes");
    const Probe = struct {
        allocator: std.mem.Allocator,
        main: std.Thread.Id,
        document: std.Io.File,
        asset: std.Io.File,
        snapshot: ?web.snapshots.FileSnapshot = null,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            const resources = [_]web.snapshots.FileResource{.{ .path = "/asset.txt", .mime = "text/plain", .file = self.asset }};
            self.snapshot = web.snapshots.FileSnapshot.init(self.allocator, self.main, self.document, &resources, .{}) catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var probe: Probe = .{ .allocator = allocator, .main = std.Thread.getCurrentId(), .document = document, .asset = asset };
    const worker = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    worker.join();
    if (probe.err) |err| return err;
    var snapshot = probe.snapshot.?;
    defer snapshot.deinit();
    // A later write cannot alter the immutable bytes served by the View.
    try asset.writePositionalAll(zio.io(), "changed-after-snapshot", 0);
    const app = try z.App.init(allocator);
    defer app.deinit();
    var view: web.View = undefined;
    var state: State = .{ .app = app, .view = &view, .profile = profile, .base = "", .start_url = "", .redirect_url = "", .unlisted_url = "", .grants = .{.{ .origin = "" }}, .phase = .snapshot };
    view = web.View.init(allocator, &state, State.event);
    const window = try app.createWindow(.{});
    try view.attach(window, .{ .html = snapshot.html, .user_data_folder = profile, .local = .{ .resources = snapshot.resources }, .page_listener = .{ .context = &state, .event = State.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and state.failed == null and state.done);
    try verifyReleased(app);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var private = zio.tmpDir(.{});
    defer private.cleanup();
    const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "RemotePageSmoke" });
    defer allocator.free(profile);
    const bind = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var allowed: Server = .{ .listener = try bind.listen(zio.io(), .{}) };
    defer allowed.stop();
    var forbidden: Server = .{ .listener = try bind.listen(zio.io(), .{}) };
    defer forbidden.stop();
    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{allowed.listener.socket.address.getPort()});
    defer allocator.free(base);
    const unlisted = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/leak", .{forbidden.listener.socket.address.getPort()});
    defer allocator.free(unlisted);
    allowed.start_html = try std.fmt.allocPrint(allocator,
        \\<title>starting</title><iframe src="/frame"></iframe><script>
        \\chrome.webview.postMessage('must-not-reach-host');
        \\Promise.all([fetch('/asset').then(r=>r.text()).then(t=>{{if(t!=='asset-ok')throw Error(t)}}),
        \\fetch('{s}').catch(()=>null), fetch('/write',{{method:'POST',body:'private'}}).catch(()=>null)])
        \\.then(()=>{{document.title='ready-start';location.href='/script'}});
        \\</script>
    , .{unlisted});
    defer allocator.free(allowed.start_html);
    try allowed.start();
    try forbidden.start();
    const start_url = try std.fmt.allocPrint(allocator, "{s}/start", .{base});
    defer allocator.free(start_url);
    const redirect_url = try std.fmt.allocPrint(allocator, "{s}/redirect", .{base});
    defer allocator.free(redirect_url);
    {
        var view: web.View = undefined;
        const app = try z.App.init(allocator);
        defer app.deinit();
        var state: State = .{ .app = app, .view = &view, .profile = profile, .base = base, .start_url = start_url, .redirect_url = redirect_url, .unlisted_url = unlisted, .grants = .{.{ .origin = base }} };
        view = web.View.init(allocator, &state, State.event);
        const window = try app.createWindow(.{});
        try view.attach(window, state.options(false));
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        if (state.failed != null) std.debug.print("remote requests allowed={d} forbidden={d}\n", .{ allowed.requests.load(.acquire), forbidden.requests.load(.acquire) });
        if (watchdog.expired) std.debug.print("remote timeout phase={s} complete={} title={} deny-script={} deny-redirect={} boot={} pong={}\n", .{ @tagName(state.phase), state.complete, state.title_ready, state.script_denied, state.redirect_denied, state.boot, state.pong });
        try std.testing.expect(!watchdog.expired and state.failed == null and state.done);
        std.debug.print("remote probes forbidden={d} frames={d} writes={d} counts={any}\n", .{ forbidden.requests.load(.acquire), allowed.frames.load(.acquire), allowed.writes.load(.acquire), web.resourceCounts() });
        try std.testing.expectEqual(@as(u32, 0), forbidden.requests.load(.acquire));
        try std.testing.expectEqual(@as(u32, 0), allowed.frames.load(.acquire));
        try std.testing.expectEqual(@as(u32, 0), allowed.writes.load(.acquire));
        try verifyReleased(app);
    }
    try runSnapshot(allocator, private.dir, profile);
    std.debug.print("remote page smoke passed: private loopback, exact ports, HTTP request/method/frame denial, default IPC denial, redirect opt-in, config generations, trusted IPC and worker file snapshots; COM=0\n", .{});
}
