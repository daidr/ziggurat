const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const CookieStore = web.CookieStore;
const cookies = web.cookies;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_cookies_counts(*u32, *u32, *usize) void;
extern fn zwk_profile_counts(*u32, *u32, *usize) void;

/// Records whether the page's request carries the cookie the app set, and
/// answers with an HttpOnly cookie of its own.
const Server = struct {
    listener: std.Io.net.Server,
    thread: ?std.Thread = null,
    closed: bool = false,
    stopped: std.atomic.Value(bool) = .init(false),
    page_requests: std.atomic.Value(u32) = .init(0),
    page_cookie: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }
    fn stop(self: *Server) void {
        if (self.closed) return;
        if (self.thread) |thread| {
            self.stopped.store(true, .release);
            const wake = self.listener.socket.address.connect(zio.io(), .{ .mode = .stream }) catch unreachable;
            wake.close(zio.io());
            thread.join();
            self.thread = null;
        }
        self.listener.deinit(zio.io());
        self.closed = true;
    }
    /// A thread per connection: an idle preconnect must not hold the others.
    fn worker(self: *Server) void {
        while (true) {
            const connection = self.listener.accept(zio.io()) catch return;
            if (self.stopped.load(.acquire)) {
                connection.close(zio.io());
                return;
            }
            const thread = std.Thread.spawn(.{}, handle, .{ self, connection }) catch {
                connection.close(zio.io());
                continue;
            };
            thread.detach();
        }
    }
    fn handle(self: *Server, connection: std.Io.net.Stream) void {
        defer connection.close(zio.io());
        self.serve(connection) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }
    fn serve(self: *Server, stream: std.Io.net.Stream) !void {
        var request: [8192]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
            if (used == request.len) return error.RequestTooLarge;
            const n = try zio.net.receive(stream.socket.handle, request[used..]);
            if (n == 0) return;
            used += n;
        }
        var parts = std.mem.splitScalar(u8, request[0..used], ' ');
        _ = parts.next();
        const path = parts.next() orelse return error.InvalidRequest;
        if (std.mem.eql(u8, path, "/page") and self.page_requests.fetchAdd(1, .acq_rel) == 0)
            self.page_cookie.store(std.mem.indexOf(u8, request[0..used], "session=s1") != null, .release);
        const body = "<!doctype html><title>cookie store</title>";
        var bytes: [512]u8 = undefined;
        const headers = try std.fmt.bufPrint(&bytes, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nSet-Cookie: page=p1; Path=/; HttpOnly\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        try zio.net.sendAll(stream.socket.handle, headers);
        try zio.net.sendAll(stream.socket.handle, body);
    }
};

const Preparation = struct {
    allocator: std.mem.Allocator,
    main: std.Thread.Id,
    path: []const u8,
    value: ?web.profile_storage.Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Preparation) void {
        self.value = web.profile_storage.Prepared.prepare(self.allocator, self.main, self.path, .{}) catch |err| {
            self.failure = err;
            return;
        };
        self.value.?.handoff() catch |err| {
            self.failure = err;
        };
    }
    fn open(self: *Preparation) !void {
        const thread = try std.Thread.spawn(.{}, worker, .{self});
        thread.join();
        if (self.failure) |err| return err;
        try self.value.?.adopt();
    }
};

const State = struct {
    app: *z.App,
    server: *Server,
    origin: []const u8,
    profile: ?*web.Profile,
    store: ?*CookieStore = null,
    window: z.Window = undefined,
    view: web.View = undefined,
    attached: bool = false,
    grants: [1]web.OriginGrant = undefined,
    urls: [3][128]u8 = undefined,
    url_lengths: [3]usize = @splat(0),
    stage: usize = 0,
    failure: ?anyerror = null,

    fn url(self: *State, which: usize, path: []const u8) []const u8 {
        const text = std.fmt.bufPrint(&self.urls[which], "{s}{s}", .{ self.origin, path }) catch unreachable;
        self.url_lengths[which] = text.len;
        return text;
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("macOS CookieStore stage {d}: {s}\n", .{ self.stage, @errorName(err) });
        self.app.quit();
    }
    fn completion(self: *State) cookies.Completion {
        return .{ .context = self, .complete = completed };
    }
    fn names(rows: []const cookies.Cookie, buffer: []u8) []const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        for (rows, 0..) |row, i| writer.print("{s}{s}", .{ if (i == 0) "" else ",", row.name }) catch break;
        return writer.buffered();
    }
    fn byName(_: void, a: cookies.Cookie, b: cookies.Cookie) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
    fn find(rows: []const cookies.Cookie, name: []const u8) ?cookies.Cookie {
        for (rows) |row| if (std.mem.eql(u8, row.name, name)) return row;
        return null;
    }
    fn expect(self: *State, result: cookies.Result, want: []const u8) !void {
        if (result != .cookies) {
            std.debug.print("stage {d}: {s}\n", .{ self.stage, @tagName(result) });
            return error.ExpectedCookies;
        }
        std.mem.sort(cookies.Cookie, @constCast(result.cookies.rows), {}, byName);
        var buffer: [256]u8 = undefined;
        const got = names(result.cookies.rows, &buffer);
        std.debug.print("macOS CookieStore stage {d}: {s}\n", .{ self.stage, got });
        if (!std.mem.eql(u8, got, want)) return error.WrongCookies;
    }
    fn completed(ptr: *anyopaque, input: cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        self.check(result) catch |err| return self.fail(err);
        self.stage += 1;
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn check(self: *State, result: cookies.Result) !void {
        switch (self.stage) {
            0, 1, 2, 7, 9, 11, 13 => if (result != .completed) return error.MutationDidNotFinish,
            3 => {
                try self.expect(result, "session");
                const row = find(result.cookies.rows, "session").?;
                if (!row.http_only or row.expires != null or row.secure) return error.WrongSessionCookie;
            },
            4 => {
                try self.expect(result, "lasting,session");
                const row = find(result.cookies.rows, "lasting").?;
                if (row.same_site != .strict or row.expires == null or @abs(row.expires.? - 4102444800) > 1) return error.WrongLastingCookie;
            },
            5 => try self.expect(result, "lasting,secure,session"),
            6 => {
                try self.expect(result, "page,session");
                if (!find(result.cookies.rows, "page").?.http_only) return error.PageCookieNotHttpOnly;
            },
            8 => try self.expect(result, "page"),
            10 => try self.expect(result, "page,secure"),
            12 => try self.expect(result, "a,b"),
            14 => try self.expect(result, ""),
            15 => if (result != .cancelled) return error.CancelNotReported,
            else => return error.UnexpectedCompletion,
        }
    }
    fn drive(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| self.fail(err);
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.LoadFailed);
        if (self.server.page_requests.load(.acquire) != 1 or !self.server.page_cookie.load(.acquire)) return self.fail(error.PageMissedAppCookie);
        _ = self.store.?.query(.{ .url = self.url(0, "/") }, self.completion()) catch |err| self.fail(err);
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed => self.fail(error.NativePageFailed),
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
    }
    fn step(self: *State) !void {
        const store = self.store.?;
        const done = self.completion();
        switch (self.stage) {
            0 => _ = try store.set(.{ .name = "session", .value = "s1", .domain = "127.0.0.1", .path = "/", .http_only = true }, done),
            1 => _ = try store.set(.{ .name = "lasting", .value = "l1", .domain = "127.0.0.1", .path = "/sub", .expires = 4102444800, .same_site = .strict }, done),
            2 => _ = try store.set(.{ .name = "secure", .value = "x", .domain = "127.0.0.1", .path = "/", .secure = true, .same_site = .none }, done),
            // Only the root path, and Secure only over https.
            3 => _ = try store.query(.{ .url = self.url(0, "/") }, done),
            4 => _ = try store.query(.{ .url = self.url(0, "/sub/page") }, done),
            5 => _ = try store.listAll(done),
            // The page's request carries the app's cookie, and the page's
            // own HttpOnly cookie lands in the same store.
            6 => {
                self.grants = .{.{ .origin = self.origin, .ipc = true }};
                try self.view.attach(self.window, .{ .html = "", .storage = .profile, .profile = self.profile, .remote = .{ .url = self.url(1, "/page"), .origins = &self.grants, .credentials = .profile, .allow_insecure_loopback = true }, .page_listener = .{ .context = self, .event = page } });
                self.attached = true;
            },
            7 => _ = try store.deleteExact(.{ .name = "session", .value = "s1", .domain = "127.0.0.1", .path = "/" }, done),
            8 => _ = try store.query(.{ .url = self.url(0, "/") }, done),
            9 => _ = try store.deleteKey(.{ .name = "lasting", .domain = "127.0.0.1", .path = "/sub" }, done),
            10 => _ = try store.listAll(done),
            11 => _ = try store.replaceAll(&.{ .{ .name = "a", .value = "1", .domain = "127.0.0.1", .path = "/" }, .{ .name = "b", .value = "2", .domain = "127.0.0.1", .path = "/", .expires = 4102444800 } }, done),
            12 => _ = try store.listAll(done),
            13 => _ = try store.clear(.entire_profile_cookies, done),
            14 => _ = try store.listAll(done),
            15 => {
                const operation = try store.set(.{ .name = "late", .value = "1", .domain = "127.0.0.1", .path = "/" }, done);
                if (!try operation.cancel()) return error.CancelRefused;
            },
            16 => {
                _ = try self.window.destroy();
                self.app.quit();
            },
            else => return error.InvalidStage,
        }
    }
};

/// Native records drain once the engine has answered every accepted call
/// and released the profile's store.
const Drain = struct {
    app: *z.App,
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var stores: u32 = 0;
        var operations: u32 = 0;
        var bytes: usize = 0;
        zwk_cookies_counts(&stores, &operations, &bytes);
        var profiles: u32 = 0;
        var contexts: u32 = 0;
        var profile_bytes: usize = 0;
        zwk_profile_counts(&profiles, &contexts, &profile_bytes);
        const counts = web.resourceCounts();
        if (stores == 0 and operations == 0 and bytes == 0 and profiles == 0 and contexts == 0 and profile_bytes == 0 and counts.states == 0) return self.app.quit();
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    if (!web.backendCapabilities().persistent_profile) return error.SkipZigTest;
    var private = zio.tmpDir(.{});
    defer private.cleanup();
    const base = try zio.realPathAlloc(private.dir, ".", allocator);
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "profile" });
    defer allocator.free(path);
    const bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: Server = .{ .listener = try bind.listen(zio.io(), .{}) };
    try server.start();
    defer server.stop();
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://127.0.0.1:{d}", .{server.listener.socket.address.getPort()});
    var preparation: Preparation = .{ .allocator = allocator, .main = std.Thread.getCurrentId(), .path = path };
    try preparation.open();
    defer preparation.value.?.close() catch unreachable;
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var state: State = .{ .app = app, .server = &server, .origin = origin, .profile = try web.Profile.create(allocator, app, &preparation.value.?, .{}) };
        defer if (state.profile) |profile| profile.close() catch unreachable;
        state.store = try CookieStore.create(allocator, app, state.profile.?, .{ .allow_write = true, .allow_clear = true, .allow_read_all = true, .allow_replace_all = true });
        defer if (state.store) |store| {
            _ = store.close() catch unreachable;
        };
        const reader = try CookieStore.create(allocator, app, state.profile.?, .{});
        try std.testing.expectError(error.PermissionDenied, reader.set(.{ .name = "denied", .value = "no", .domain = "127.0.0.1", .path = "/" }, state.completion()));
        try std.testing.expectError(error.PermissionDenied, reader.listAll(state.completion()));
        try std.testing.expectEqual(CookieStore.CloseResult.closed, try reader.close());
        state.window = try app.createWindow(.{ .width = 320, .height = 200 });
        state.view = web.View.init(allocator, &state, State.event);
        try app.post(.{ .context = &state, .call = State.drive });
        {
            var watchdog: Watchdog = .{ .app = app };
            try watchdog.start();
            defer watchdog.stop();
            try app.run();
            watchdog.stop();
            if (watchdog.expired) state.fail(error.Timeout);
        }
        if (state.failure) |err| return err;
        try std.testing.expectEqual(@as(usize, 16), state.stage);
        _ = try state.store.?.close();
        state.store = null;
        try state.profile.?.close();
        state.profile = null;
    }
    // A stopped App takes no more tasks: a new one waits for the engine.
    const app = try z.App.init(allocator);
    defer app.deinit();
    var drain: Drain = .{ .app = app };
    try app.post(.{ .context = &drain, .call = Drain.tick });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) return error.CookieRecordsLeft;
    server.stop();
    if (server.failure) |err| return err;
    std.debug.print("macOS CookieStore: set/query by URL/list/delete/delete key/replace/clear/cancel, page and app share the profile's cookies; native records=0\n", .{});
}
