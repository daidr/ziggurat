const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const Server = struct {
    listener: std.net.Server,
    thread: ?std.Thread = null,
    stopped: std.atomic.Value(bool) = .init(false),
    first: std.atomic.Value(bool) = .init(false),
    second: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    closed: bool = false,
    fn worker(self: *Server) void {
        while (true) {
            const connection = self.listener.accept() catch return;
            defer connection.stream.close();
            if (self.stopped.load(.acquire)) return;
            self.serve(connection.stream) catch |err| {
                self.failure = err;
                return;
            };
        }
    }
    fn serve(self: *Server, stream: std.net.Stream) !void {
        var request: [8192]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
            if (used == request.len) return error.RequestTooLarge;
            const n = try stream.read(request[used..]);
            if (n == 0) return;
            used += n;
        }
        var parts = std.mem.splitScalar(u8, request[0..used], ' ');
        _ = parts.next();
        const route = parts.next() orelse return error.InvalidRequest;
        const from_store = std.mem.indexOf(u8, request[0..used], "from_store=present") != null;
        const from_page = std.mem.indexOf(u8, request[0..used], "from_page=visible") != null;
        if (std.mem.eql(u8, route, "/first")) self.first.store(from_store and !from_page, .release);
        if (std.mem.eql(u8, route, "/second")) self.second.store(from_store and from_page, .release);
        const body = "<!doctype html><title>Cookie owner fixture</title><body>shared profile</body>";
        var buffer: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        try stream.writeAll(header);
        try stream.writeAll(body);
    }
    fn close(self: *Server) void {
        if (self.closed) return;
        self.closed = true;
        self.stopped.store(true, .release);
        if (self.thread) |thread| {
            const connection = std.net.tcpConnectToAddress(self.listener.listen_address) catch unreachable;
            connection.close();
            thread.join();
            self.thread = null;
        }
        self.listener.deinit();
    }
};
const Preparation = struct {
    allocator: std.mem.Allocator,
    main: std.Thread.Id,
    path: []const u8,
    prepared: ?web.profile_storage.Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Preparation) void {
        self.prepared = web.profile_storage.Prepared.prepare(self.allocator, self.main, self.path, .{}) catch |err| {
            self.failure = err;
            return;
        };
        self.prepared.?.handoff() catch |err| {
            self.failure = err;
        };
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    profile: *web.Profile,
    store: *web.CookieStore,
    windows: [2]z.Window = undefined,
    views: [2]web.View = undefined,
    origin: []const u8,
    urls: [2][]const u8,
    extension: []const u8,
    grants: [1]web.OriginGrant,
    phase: enum { seed, first, page_cookie, second, clear, empty, proof, done } = .seed,
    failure: ?anyerror = null,
    proofs: usize = 0,
    loads: usize = 0,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Cookie HTTP {s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn completion(self: *State) web.cookies.Completion {
        return .{ .context = self, .complete = cookieComplete };
    }
    fn event(ptr: *anyopaque, _: *web.View, event_value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (event_value) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn attach(self: *State, index: usize) !void {
        self.views[index] = web.View.init(self.allocator, self, event);
        try self.views[index].attach(self.windows[index], .{ .html = "", .storage = .profile, .profile = self.profile, .remote = .{ .url = self.urls[index], .origins = &self.grants, .credentials = .profile, .allow_insecure_loopback = true }, .request_policy_extension = .{ .directory = self.extension }, .page_listener = .{ .context = self, .event = page } });
    }
    fn page(ptr: *anyopaque, view: *web.View, event_value: web.PageEvent) void {
        if (event_value != .completed) return;
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!event_value.completed.success) return self.fail(error.LoadFailed);
        self.loads += 1;
        const script = if (self.phase == .first) "localStorage.setItem('store-keeps-local','yes');document.cookie='from_page=visible; Path=/; SameSite=Lax';!document.cookie.includes('from_store=')&&document.cookie.includes('from_page=visible')" else "localStorage.getItem('store-keeps-local')==='yes'&&document.cookie.includes('from_page=visible')&&!document.cookie.includes('from_store=')";
        _ = view.evaluateJS(script, .{}, .{ .context = self, .complete = scriptComplete }) catch |err| self.fail(err);
    }
    fn scriptComplete(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "true")) return self.fail(error.WrongDOMCookieState);
        switch (self.phase) {
            .first => {
                self.phase = .page_cookie;
                _ = self.store.query(.{ .url = self.urls[1], .name = "from_page" }, self.completion()) catch |err| self.fail(err);
            },
            .second => {
                self.phase = .clear;
                _ = self.store.clear(.entire_profile_cookies, self.completion()) catch |err| self.fail(err);
            },
            .proof => {
                self.proofs += 1;
                if (self.proofs == 2) {
                    self.phase = .done;
                    self.app.quit();
                }
            },
            else => self.fail(error.UnexpectedScriptCompletion),
        }
    }
    fn cookieComplete(ptr: *anyopaque, input: web.cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        switch (self.phase) {
            .seed => {
                if (result != .completed) return self.fail(error.SeedFailed);
                self.phase = .first;
            },
            .page_cookie => {
                if (result != .cookies or result.cookies.rows.len != 1 or !std.mem.eql(u8, result.cookies.rows[0].value, "visible") or result.cookies.rows[0].http_only) return self.fail(error.PageWriteNotShared);
                self.phase = .second;
            },
            .clear => {
                if (result != .completed) return self.fail(error.ClearFailed);
                self.phase = .empty;
            },
            .empty => {
                if (result != .cookies or result.cookies.rows.len != 0) return self.fail(error.CookiesNotCleared);
                self.phase = .proof;
            },
            else => return self.fail(error.UnexpectedCookieCompletion),
        }
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn drive(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        switch (self.phase) {
            .seed => _ = try self.store.set(.{ .name = "from_store", .value = "present", .domain = "127.0.0.1", .path = "/", .http_only = true }, self.completion()),
            .first => try self.attach(0),
            .second => try self.attach(1),
            .empty => _ = try self.store.query(.{ .url = self.urls[1] }, self.completion()),
            .proof => for (&self.views) |*view| {
                _ = try view.evaluateJS("localStorage.getItem('store-keeps-local')==='yes'&&document.cookie===''", .{}, .{ .context = self, .complete = scriptComplete });
            },
            else => return error.InvalidPhase,
        }
    }
};
pub fn run(allocator: std.mem.Allocator, base: []const u8) !void {
    const bind = try std.net.Address.parseIp("127.0.0.1", 0);
    var server: Server = .{ .listener = try bind.listen(.{}) };
    server.thread = try std.Thread.spawn(.{}, Server.worker, .{&server});
    defer server.close();
    const path = try std.fmt.allocPrint(allocator, "{s}-http", .{base});
    defer allocator.free(path);
    var preparation: Preparation = .{ .allocator = allocator, .main = std.Thread.getCurrentId(), .path = path };
    const worker = try std.Thread.spawn(.{}, Preparation.worker, .{&preparation});
    worker.join();
    if (preparation.failure) |err| return err;
    try preparation.prepared.?.adopt();
    defer preparation.prepared.?.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const profile = try web.Profile.create(allocator, app, &preparation.prepared.?, .{});
    defer profile.close() catch unreachable;
    const store = try web.CookieStore.create(allocator, app, profile, .{ .allow_write = true, .allow_clear = true });
    defer _ = store.close() catch unreachable;
    const origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{server.listener.listen_address.getPort()});
    defer allocator.free(origin);
    const first = try std.fmt.allocPrint(allocator, "{s}/first", .{origin});
    defer allocator.free(first);
    const second = try std.fmt.allocPrint(allocator, "{s}/second", .{origin});
    defer allocator.free(second);
    const extension = try std.process.getEnvVarOwned(allocator, "ZIGGURAT_REQUEST_POLICY_EXTENSION");
    defer allocator.free(extension);
    var state: State = .{ .allocator = allocator, .app = app, .profile = profile, .store = store, .origin = origin, .urls = .{ first, second }, .extension = extension, .grants = .{.{ .origin = origin, .ipc = true }} };
    for (&state.windows) |*window| window.* = try app.createWindow(.{ .width = 320, .height = 200 });
    try app.post(.{ .context = &state, .call = State.drive });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    server.close();
    if (server.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.phase == .done and state.loads == 2 and state.proofs == 2);
    try std.testing.expect(server.first.load(.acquire) and server.second.load(.acquire));
    try std.testing.expect(app.resourceStats().allocated_records == 0);
    std.debug.print("CookieStore HTTP: cold HttpOnly on first request, browser write queried by Store, two independent Views share Profile, cookie-only clear preserves localStorage\n", .{});
}
