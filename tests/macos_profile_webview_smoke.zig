const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_profile_counts(*u32, *u32, *usize) void;

/// A loopback server that sets a lasting cookie on /seed and records whether
/// the first request of /restore and of /ephemeral carries it. Child exit
/// separates the observations, as on Linux.
const Server = struct {
    listener: std.Io.net.Server,
    thread: ?std.Thread = null,
    closed: bool = false,
    stopped: std.atomic.Value(bool) = .init(false),
    restore_requests: std.atomic.Value(u32) = .init(0),
    restore_cookie: std.atomic.Value(bool) = .init(false),
    ephemeral_requests: std.atomic.Value(u32) = .init(0),
    ephemeral_cookie: std.atomic.Value(bool) = .init(false),
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
    /// A thread per connection: an idle preconnect of the engine's must not
    /// hold the others. Every connection ends with its child process.
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
        if (!std.mem.eql(u8, parts.next() orelse return error.InvalidRequest, "GET")) return error.InvalidMethod;
        const path = parts.next() orelse return error.InvalidRequest;
        const cookie = std.mem.indexOf(u8, request[0..used], "persistent_cookie=present") != null;
        if (std.mem.eql(u8, path, "/restore")) {
            if (self.restore_requests.fetchAdd(1, .acq_rel) == 0) self.restore_cookie.store(cookie, .release);
        } else if (std.mem.eql(u8, path, "/ephemeral")) {
            if (self.ephemeral_requests.fetchAdd(1, .acq_rel) == 0) self.ephemeral_cookie.store(cookie, .release);
        }
        const body = "<!doctype html><title>Explicit profile fixture</title><body>profile</body>";
        const set_cookie = if (std.mem.eql(u8, path, "/seed")) "Set-Cookie: persistent_cookie=present; Max-Age=31536000; Path=/; SameSite=Lax\r\n" else "";
        var bytes: [768]u8 = undefined;
        const headers = try std.fmt.bufPrint(&bytes, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n", .{ set_cookie, body.len });
        try zio.net.sendAll(stream.socket.handle, headers);
        try zio.net.sendAll(stream.socket.handle, body);
    }
};

const Prepared = web.profile_storage.Prepared;
const Preparation = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    path: []const u8,
    value: ?Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Preparation) void {
        self.value = Prepared.prepare(self.allocator, self.main_thread, self.path, .{}) catch |err| {
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

const Mode = enum { seed, restore, ephemeral, lifecycle };
/// seed stores a cookie and localStorage in a fresh profile; restore finds
/// the cookie on its first request in a new process; ephemeral storage
/// never sees it; lifecycle shares one profile's store between two views
/// and closes the owner while both still hold it.
const Probe = struct {
    app: *z.App,
    owner: ?*web.Profile,
    mode: Mode,
    url: []const u8,
    grants: [1]web.OriginGrant,
    windows: [2]z.Window = undefined,
    views: [2]web.View = undefined,
    failure: ?anyerror = null,
    loads: usize = 0,
    phase: enum { initial, second, complete } = .initial,

    fn options(self: *Probe) web.Options {
        return .{
            .html = "",
            .storage = if (self.mode == .ephemeral) .ephemeral else .profile,
            .profile = self.owner,
            .remote = .{ .url = self.url, .origins = &self.grants, .credentials = if (self.mode == .ephemeral) .ephemeral else .profile, .allow_insecure_loopback = true },
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("macOS profile {s}/{s}: {s}\n", .{ @tagName(self.mode), @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed => self.fail(error.NativePageFailed),
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        if (value != .completed) return;
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (!value.completed.success) return self.fail(error.DocumentLoadFailed);
        self.loads += 1;
        const script = switch (self.mode) {
            .seed => "localStorage.setItem('persistent_value','present');localStorage.getItem('persistent_value')==='present'&&document.cookie.includes('persistent_cookie=present')",
            .restore => "document.cookie.includes('persistent_cookie=present')",
            .ephemeral => "!document.cookie.includes('persistent_cookie=present')",
            .lifecycle => if (self.phase == .initial) "localStorage.setItem('shared_value','ready');true" else "localStorage.getItem('shared_value')==='ready'",
        };
        _ = view.evaluateJS(script, .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
    }
    fn evaluated(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "true")) {
            std.debug.print("macOS profile result: {any}\n", .{result});
            return self.fail(error.WrongStorageResult);
        }
        if (self.mode != .lifecycle) return self.finish();
        switch (self.phase) {
            .initial => {
                self.phase = .second;
                self.views[1].attach(self.windows[1], self.options()) catch |err| self.fail(err);
            },
            .second => {
                const stats = self.owner.?.stats() catch |err| return self.fail(err);
                if (stats.contexts != 2 or stats.leases != 2) {
                    std.debug.print("macOS profile stats: {any}\n", .{stats});
                    return self.fail(error.WrongProfileCount);
                }
                // Both views keep the store after the owner closes.
                const owner = self.owner.?;
                self.owner = null;
                owner.close() catch |err| return self.fail(err);
                _ = self.views[0].evaluateJS("localStorage.getItem('shared_value')==='ready'", .{}, .{ .context = self, .complete = afterClose }) catch |err| self.fail(err);
            },
            .complete => self.fail(error.UnexpectedEvaluation),
        }
    }
    fn afterClose(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "true")) return self.fail(error.StoreLostAfterOwnerClose);
        self.finish();
    }
    fn finish(self: *Probe) void {
        self.phase = .complete;
        const count: usize = if (self.mode == .lifecycle) 2 else 1;
        for (self.windows[0..count]) |window| _ = window.destroy() catch |err| return self.fail(err);
        if (self.owner) |owner| {
            self.owner = null;
            owner.close() catch |err| return self.fail(err);
        }
        self.app.quit();
    }
};

/// The store, and with it the profile's native record and lock, lasts until
/// the engine has written its cookies and released its last page.
const Drain = struct {
    app: *z.App,
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var profiles: u32 = 0;
        var contexts: u32 = 0;
        var bytes: usize = 0;
        zwk_profile_counts(&profiles, &contexts, &bytes);
        const counts = web.resourceCounts();
        if (profiles == 0 and contexts == 0 and bytes == 0 and counts.states == 0 and counts.handlers == 0 and counts.controllers == 0) return self.app.quit();
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};

fn run(allocator: std.mem.Allocator, mode: Mode, prepared: *Preparation, origin: []const u8) !usize {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const owner: ?*web.Profile = if (mode == .ephemeral) null else try web.Profile.create(allocator, app, &prepared.value.?, .{ .contexts = 3 });
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ origin, switch (mode) {
        .seed => "seed",
        .restore => "restore",
        .ephemeral => "ephemeral",
        .lifecycle => "live",
    } });
    defer allocator.free(url);
    var probe: Probe = .{ .app = app, .owner = owner, .mode = mode, .url = url, .grants = .{.{ .origin = origin, .ipc = true }} };
    defer if (probe.owner) |value| value.close() catch unreachable;
    probe.windows[0] = try app.createWindow(.{ .width = 320, .height = 200 });
    probe.views[0] = web.View.init(allocator, &probe, Probe.event);
    if (mode == .lifecycle) {
        probe.windows[1] = try app.createWindow(.{ .width = 320, .height = 200 });
        probe.views[1] = web.View.init(allocator, &probe, Probe.event);
    }
    try probe.views[0].attach(probe.windows[0], probe.options());
    {
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        if (watchdog.expired) probe.fail(error.Timeout);
    }
    if (probe.failure) |err| return err;
    try std.testing.expect(probe.phase == .complete);
    return probe.loads;
}

fn child(allocator: std.mem.Allocator, mode: Mode, path: []const u8, origin: []const u8) !void {
    var prepared: Preparation = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .path = path };
    if (mode != .ephemeral) try prepared.open();
    defer if (prepared.value) |*value| value.close() catch unreachable;
    const loads = try run(allocator, mode, &prepared, origin);
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
    if (watchdog.expired) {
        var profiles: u32 = 0;
        var contexts: u32 = 0;
        var bytes: usize = 0;
        zwk_profile_counts(&profiles, &contexts, &bytes);
        std.debug.print("macOS profile {s}: records left profiles={d} contexts={d} bytes={d}\n", .{ @tagName(mode), profiles, contexts, bytes });
        return error.ProfileRecordsLeft;
    }
    std.debug.print("macOS profile child {s}: loads={d}, records released\n", .{ @tagName(mode), loads });
}

fn spawn(executable: []const u8, mode: Mode, path: []const u8, origin: []const u8) !void {
    var process = try zio.spawn(.{ .argv = &.{ executable, "--child", @tagName(mode), path, origin }, .stdin = .ignore });
    const term = try process.wait(zio.io());
    if (term != .exited or term.exited != 0) return error.ProfileChildFailed;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len == 5 and std.mem.eql(u8, args[1], "--child")) {
        const mode = std.meta.stringToEnum(Mode, args[2]) orelse return error.InvalidChildMode;
        return child(allocator, mode, args[3], args[4]);
    }
    if (args.len != 1) return error.InvalidArguments;
    if (!web.backendCapabilities().persistent_profile) return error.SkipZigTest;
    var private = zio.tmpDir(.{});
    defer private.cleanup();
    const base = try zio.realPathAlloc(private.dir, ".", allocator);
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "profile" });
    defer allocator.free(path);
    const live_path = try std.fs.path.join(allocator, &.{ base, "lifecycle" });
    defer allocator.free(live_path);
    const bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: Server = .{ .listener = try bind.listen(zio.io(), .{}) };
    try server.start();
    defer server.stop();
    const origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{server.listener.socket.address.getPort()});
    defer allocator.free(origin);
    const executable = try zio.executablePathAlloc(allocator);
    defer allocator.free(executable);
    try spawn(executable, .seed, path, origin);
    try spawn(executable, .restore, path, origin);
    std.debug.print("macOS profile restore: requests={d} cookie={}\n", .{ server.restore_requests.load(.acquire), server.restore_cookie.load(.acquire) });
    try std.testing.expect(server.restore_requests.load(.acquire) == 1 and server.restore_cookie.load(.acquire));
    try spawn(executable, .ephemeral, path, origin);
    try std.testing.expect(server.ephemeral_requests.load(.acquire) == 1 and !server.ephemeral_cookie.load(.acquire));
    try spawn(executable, .lifecycle, live_path, origin);
    server.stop();
    if (server.failure) |err| return err;
    std.debug.print("macOS profile: first-request cookie across child exit, ephemeral isolation, one store shared by two views past owner close; native records=0\n", .{});
}
