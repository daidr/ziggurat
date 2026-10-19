const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const tools = web.tools;
const Server = struct {
    listener: std.net.Server,
    thread: ?std.Thread = null,
    stopped: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    closed: bool = false,
    fn worker(self: *Server) void {
        while (true) {
            const connection = self.listener.accept() catch return;
            defer connection.stream.close();
            if (self.stopped.load(.acquire)) return;
            serve(connection.stream) catch |err| {
                self.failure = err;
                return;
            };
        }
    }
    fn serve(stream: std.net.Stream) !void {
        var request: [8192]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
            if (used == request.len) return error.RequestTooLarge;
            const n = try stream.read(request[used..]);
            if (n == 0) return;
            used += n;
        }
        const body = "<!doctype html><title>Clear fixture</title><body>profile data</body>";
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
    window: z.Window = undefined,
    view: web.View = undefined,
    url: []const u8,
    extension: []const u8,
    grants: [1]web.OriginGrant,
    phase: enum { seed, page, clear, empty, reload, cancel, done } = .seed,
    failure: ?anyerror = null,
    loads: usize = 0,
    cancelled: usize = 0,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("View clear {s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn options(self: *State) web.Options {
        return .{ .html = "", .storage = .profile, .profile = self.profile, .remote = .{ .url = self.url, .origins = &self.grants, .credentials = .profile, .allow_insecure_loopback = true }, .request_policy_extension = .{ .directory = self.extension }, .tools = .{ .clear_entire_profile = true }, .page_listener = .{ .context = self, .event = page } };
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        if (value != .completed) return;
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!value.completed.success) return self.fail(error.LoadFailed);
        self.loads += 1;
        const script = switch (self.phase) {
            .page => "localStorage.setItem('kept','yes');document.cookie='from_page=visible; Path=/; SameSite=Lax';localStorage.getItem('kept')==='yes'&&document.cookie.includes('from_page=visible')",
            .reload => "localStorage.getItem('kept')===null&&document.cookie===''",
            else => return self.fail(error.UnexpectedLoad),
        };
        _ = view.evaluateJS(script, .{}, .{ .context = self, .complete = scriptComplete }) catch |err| self.fail(err);
    }
    fn scriptComplete(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "true")) return self.fail(error.WrongPageData);
        switch (self.phase) {
            .page => self.phase = .clear,
            .reload => self.phase = .cancel,
            else => return self.fail(error.UnexpectedScript),
        }
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn toolComplete(ptr: *anyopaque, result: tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (self.phase) {
            .clear => {
                if (result != .cleared) return self.fail(error.ClearFailed);
                self.phase = .empty;
            },
            .cancel => {
                if (result != .cancelled) return self.fail(error.WrongCancelResult);
                self.cancelled += 1;
                return;
            },
            else => return self.fail(error.UnexpectedTool),
        }
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn cookieComplete(ptr: *anyopaque, input: web.cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        switch (self.phase) {
            .seed => {
                if (result != .completed) return self.fail(error.SeedFailed);
                self.phase = .page;
            },
            .empty => {
                if (result != .cookies or result.cookies.rows.len != 0) return self.fail(error.CookiesNotCleared);
                self.phase = .reload;
            },
            else => return self.fail(error.UnexpectedCookie),
        }
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn drive(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        const completion: tools.Completion = .{ .context = self, .complete = toolComplete };
        switch (self.phase) {
            .seed => _ = try self.store.set(.{ .name = "from_store", .value = "present", .domain = "127.0.0.1", .path = "/", .http_only = true }, .{ .context = self, .complete = cookieComplete }),
            .page => {
                self.view = web.View.init(self.allocator, self, event);
                try self.view.attach(self.window, self.options());
            },
            .clear => _ = try self.view.clearBrowsingData(.entire_profile, .{}, completion),
            .empty => _ = try self.store.query(.{ .url = self.url }, .{ .context = self, .complete = cookieComplete }),
            .reload => try self.view.reload(self.options()),
            .cancel => {
                const operation = try self.view.clearBrowsingData(.entire_profile, .{}, completion);
                try std.testing.expect(try operation.cancel());
                try std.testing.expect(!(try operation.cancel()));
                try std.testing.expectEqual(@as(usize, 1), self.cancelled);
                // The logically cancelled native clear may still finish later;
                // the next request is independent and completes normally.
                _ = try self.view.clearBrowsingData(.entire_profile, .{ .timeout_ms = 1 }, .{ .context = self, .complete = timeoutComplete });
            },
            else => return error.InvalidPhase,
        }
    }
    fn timeoutComplete(ptr: *anyopaque, result: tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .cleared and result != .timed_out) return self.fail(error.WrongDeadlineResult);
        self.phase = .done;
        _ = self.window.destroy() catch |err| return self.fail(err);
        self.app.quit();
    }
};
pub fn run(allocator: std.mem.Allocator, base: []const u8) !void {
    const bind = try std.net.Address.parseIp("127.0.0.1", 0);
    var server: Server = .{ .listener = try bind.listen(.{}) };
    server.thread = try std.Thread.spawn(.{}, Server.worker, .{&server});
    defer server.close();
    const path = try std.fmt.allocPrint(allocator, "{s}-view-clear", .{base});
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
    const store = try web.CookieStore.create(allocator, app, profile, .{ .allow_write = true });
    defer _ = store.close() catch unreachable;
    const origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{server.listener.listen_address.getPort()});
    defer allocator.free(origin);
    const url = try std.fmt.allocPrint(allocator, "{s}/page", .{origin});
    defer allocator.free(url);
    const extension = try std.process.getEnvVarOwned(allocator, "ZIGGURAT_REQUEST_POLICY_EXTENSION");
    defer allocator.free(extension);
    var state: State = .{ .allocator = allocator, .app = app, .profile = profile, .store = store, .url = url, .extension = extension, .grants = .{.{ .origin = origin, .ipc = true }} };
    state.window = try app.createWindow(.{ .width = 320, .height = 200 });
    try app.post(.{ .context = &state, .call = State.drive });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    server.close();
    if (server.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.phase == .done and state.loads == 2 and state.cancelled == 1);
    try std.testing.expect(app.resourceStats().allocated_records == 0);
    std.debug.print("View clear Linux: whole Profile clear removes Store and page cookies plus localStorage for later documents, cancel once, deadline/close; Store reads the same Profile\n", .{});
}
