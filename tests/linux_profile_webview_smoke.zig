const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

extern fn webkit_web_view_get_context(*anyopaque) *anyopaque;
extern fn webkit_web_context_get_website_data_manager(*anyopaque) *anyopaque;
extern fn zwk_profile_counts(*u32, *u32, *usize) void;

// The parent owns this explicit test worker and has no App or native loop.
// Child exit, rather than a delay or a directory unlock, separates the two
// persistence observations. This is not an engine fsync guarantee.
const Server = struct {
    listener: std.net.Server,
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
            const wake = std.net.tcpConnectToAddress(self.listener.listen_address) catch unreachable;
            wake.close();
            thread.join();
            self.thread = null;
        }
        self.listener.deinit();
        self.closed = true;
    }
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
        try stream.writeAll(headers);
        try stream.writeAll(body);
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
        // Setup precedes App creation: there is no UI operation to block.
        thread.join();
        if (self.failure) |err| return err;
        try self.value.?.adopt();
    }
};

const Mode = enum { seed, restore, ephemeral, lifecycle, session, rejected, ownership, allocations, recover };
const Probe = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    owner: ?*web.Profile,
    mode: Mode,
    origin: []const u8,
    url: []const u8,
    extension: []const u8,
    grants: [1]web.OriginGrant,
    windows: [2]z.Window = undefined,
    views: [2]web.View = undefined,
    session: web.PageSession = undefined,
    failure: ?anyerror = null,
    loads: usize = 0,
    evaluations: usize = 0,
    accepted_tasks: usize = 0,
    accepted_total: usize = 0,
    cancelled: usize = 0,
    releases: usize = 0,
    session_closed: usize = 0,
    old_page: ?web.PageId = null,
    gate: ?*@import("linux_profile_lifetime.zig").Reentry = null,
    phase: enum { initial, second, full, restart, replacement, complete } = .initial,

    fn options(self: *Probe) web.Options {
        return .{
            .html = "",
            .storage = if (self.mode == .ephemeral) .ephemeral else .profile,
            .profile = self.owner,
            .remote = .{ .url = self.url, .origins = &self.grants, .credentials = if (self.mode == .ephemeral) .ephemeral else .profile, .allow_insecure_loopback = true },
            .request_policy_extension = .{ .directory = self.extension },
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Profile {s}/{s}: {s}\n", .{ @tagName(self.mode), @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed => self.fail(error.NativePageFailed),
            .process_failed => {
                if (self.mode != .recover or self.phase != .restart) return self.fail(error.UnexpectedProcessFailure);
                view.recover() catch |err| return self.fail(err);
                const owner = self.owner orelse return self.fail(error.MissingRecoveryOwner);
                self.owner = null;
                owner.close() catch |err| return self.fail(err);
                self.phase = .replacement;
            },
            .resources_released => self.releases += 1,
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
            .restore => "localStorage.getItem('persistent_value')==='present'&&document.cookie.includes('persistent_cookie=present')",
            .ephemeral => "typeof localStorage==='undefined'&&!document.cookie.includes('persistent_cookie=present')",
            .lifecycle => if (self.phase == .initial) "localStorage.setItem('shared_value','ready');true" else "localStorage.getItem('shared_value')==='ready'",
            .session, .recover => "6*7===42",
            .rejected => "6*7===42",
            .ownership, .allocations => unreachable,
        };
        _ = view.evaluateJS(script, .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
    }
    fn evaluated(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "true")) {
            std.debug.print("Profile result: {any}\n", .{result});
            return self.fail(error.WrongStorageResult);
        }
        self.evaluations += 1;
        if (self.mode == .recover and self.phase == .initial) {
            self.old_page = self.views[0].pageId();
            self.phase = .restart;
            @import("linux_webview_process.zig").stop(self.windows[0]) catch |err| self.fail(err);
            return;
        }
        if (self.mode == .recover) {
            if (self.phase != .replacement or self.owner != null or std.meta.eql(self.old_page, self.views[0].pageId())) return self.fail(error.RecoveryLostAcceptedContext);
            std.testing.expectError(error.StalePage, self.views[0].postFor(self.old_page.?, "old recovery page")) catch |err| return self.fail(err);
        }
        if (self.mode == .rejected and self.phase == .initial) {
            self.old_page = self.views[0].pageId();
            const native = self.views[0].native;
            const gate = self.gate.?;
            gate.owner_slot = &self.owner;
            gate.action = .close_on_alloc;
            self.views[0].allocator = gate.allocator();
            std.testing.expectError(error.Closed, self.views[0].reload(self.options())) catch |err| return self.fail(err);
            if (gate.callback_error) |err| return self.fail(err);
            if (!gate.acted or self.owner != null or self.views[0].native != native or !self.views[0].ready or !std.meta.eql(self.old_page, self.views[0].pageId())) return self.fail(error.RejectedRestartChangedOldPage);
            self.phase = .replacement;
            _ = self.views[0].evaluateJS("6*7===42", .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
            return;
        }
        if (self.mode != .lifecycle) {
            self.phase = .complete;
            self.app.quit();
            return;
        }
        switch (self.phase) {
            .initial => {
                self.phase = .second;
                self.views[1].attach(self.windows[1], self.options()) catch |err| self.fail(err);
            },
            .second => self.checkFull(),
            .replacement => {
                if (self.owner != null or self.cancelled != 1 or self.releases != 1) return self.fail(error.AcceptedRestartWasRevoked);
                self.phase = .complete;
                self.app.quit();
            },
            else => self.fail(error.UnexpectedEvaluation),
        }
    }
    fn checkFull(self: *Probe) void {
        const a = @import("linux_webview_process.zig").ownedWidget(self.windows[0]) catch |err| return self.fail(err);
        const b = @import("linux_webview_process.zig").ownedWidget(self.windows[1]) catch |err| return self.fail(err);
        const ca = webkit_web_view_get_context(a);
        const cb = webkit_web_view_get_context(b);
        if (ca == cb or webkit_web_context_get_website_data_manager(ca) != webkit_web_context_get_website_data_manager(cb)) return self.fail(error.ContextsNotIndependent);
        const stats = self.owner.?.stats() catch |err| return self.fail(err);
        if (stats.contexts != 2 or stats.leases != 2) return self.fail(error.WrongPhysicalProfileCount);
        self.old_page = self.views[0].pageId();
        self.phase = .full;
        while (true) {
            self.app.post(.{ .context = self, .call = accepted }) catch |err| {
                if (err != error.Full) return self.fail(err);
                break;
            };
            self.accepted_total += 1;
        }
        std.testing.expectError(error.Full, self.views[0].reload(self.options())) catch |err| return self.fail(err);
        if (!std.meta.eql(self.old_page, self.views[0].pageId()) or !self.views[0].ready or self.views[0].recovering) return self.fail(error.FullChangedOldDocument);
        const after = self.owner.?.stats() catch |err| return self.fail(err);
        if (after.contexts != 2 or after.leases != 2) return self.fail(error.FailedCandidateLeaked);
    }
    fn accepted(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.accepted_tasks += 1;
        if (self.accepted_tasks != self.accepted_total) return;
        self.phase = .restart;
        _ = self.views[0].evaluateJS("new Promise(()=>{})", .{}, .{ .context = self, .complete = onCancelled }) catch |err| return self.fail(err);
        self.views[0].reload(self.options()) catch |err| return self.fail(err);
        if (self.owner != null or self.cancelled != 1 or self.views[0].pending_config == null) return self.fail(error.ProfileClosedBeforeAcceptedCommit);
        self.phase = .replacement;
    }
    fn onCancelled(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .page_changed or self.phase != .restart) return self.fail(error.WrongRestartCancellation);
        self.cancelled += 1;
        const owner = self.owner orelse return self.fail(error.DuplicateOwnerClose);
        self.owner = null;
        owner.close() catch |err| self.fail(err);
    }
    fn sessionClosed(ptr: *anyopaque, _: *web.PageSession) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.session_closed += 1;
    }
};

fn nativeEmpty() !void {
    var profiles: u32 = 0;
    var contexts: u32 = 0;
    var bytes: usize = 0;
    zwk_profile_counts(&profiles, &contexts, &bytes);
    const resources = web.resourceCounts();
    try std.testing.expect(profiles == 0 and contexts == 0 and bytes == 0);
    try std.testing.expect(resources.states == 0 and resources.handlers == 0 and resources.controllers == 0);
}

fn child(allocator: std.mem.Allocator, mode: Mode, path: []const u8, origin: []const u8, extension: []const u8) !void {
    if (mode == .ownership) return @import("linux_profile_lifetime.zig").run(allocator, path);
    if (mode == .allocations) return @import("linux_profile_lifetime.zig").allocations(allocator, path, origin, extension);
    var prepared: Preparation = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .path = path };
    if (mode != .ephemeral) try prepared.open();
    defer if (prepared.value) |*value| value.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var owner: ?*web.Profile = if (mode == .ephemeral) null else try web.Profile.create(allocator, app, &prepared.value.?, .{ .contexts = 3 });
    const route = switch (mode) {
        .seed => "seed",
        .restore => "restore",
        .ephemeral => "ephemeral",
        .lifecycle => "live",
        .session => "session",
        .rejected => "rejected",
        .recover => "recover",
        .ownership, .allocations => unreachable,
    };
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ origin, route });
    defer allocator.free(url);
    var probe: Probe = .{ .allocator = allocator, .app = app, .owner = owner, .mode = mode, .origin = origin, .url = url, .extension = extension, .grants = .{.{ .origin = origin, .ipc = true }} };
    var gate: @import("linux_profile_lifetime.zig").Reentry = .{ .backing = allocator, .app = app };
    probe.gate = &gate;
    defer if (probe.owner) |value| value.close() catch unreachable;
    probe.windows[0] = try app.createWindow(.{ .width = 320, .height = 200 });
    probe.views[0] = web.View.init(allocator, &probe, Probe.event);
    if (mode == .session) {
        probe.session = web.PageSession.init(allocator, &probe, Probe.event);
        try probe.session.open(app, .{ .page = probe.options(), .on_closed = .{ .context = &probe, .notify = Probe.sessionClosed } });
        try owner.?.close();
        owner = null;
        probe.owner = null;
    } else {
        if (mode == .lifecycle) {
            probe.windows[1] = try app.createWindow(.{ .width = 320, .height = 200 });
            probe.views[1] = web.View.init(allocator, &probe, Probe.event);
        }
        try probe.views[0].attach(probe.windows[0], probe.options());
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.phase == .complete and app.resourceStats().allocated_records == 0);
    if (mode == .lifecycle) try std.testing.expect(probe.loads == 3 and probe.evaluations == 3 and probe.accepted_tasks == probe.accepted_total);
    if (mode == .session) try std.testing.expect(probe.session.phase == .closed and probe.session_closed == 1);
    if (mode == .recover) try std.testing.expect(probe.loads == 2 and probe.evaluations == 2 and probe.releases == 0);
    if (probe.owner) |value| {
        probe.owner = null;
        try value.close();
    }
    std.debug.print("Profile child {s}: loads={d}, shutdown completed\n", .{ @tagName(mode), probe.loads });
}

fn spawn(allocator: std.mem.Allocator, executable: []const u8, mode: Mode, path: []const u8, origin: []const u8, extension: []const u8) !void {
    var process = std.process.Child.init(&.{ executable, "--child", @tagName(mode), path, origin, extension }, allocator);
    process.stdin_behavior = .Ignore;
    try process.spawn();
    const term = try process.wait();
    if (term != .Exited or term.Exited != 0) return error.ProfileChildFailed;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len == 6 and std.mem.eql(u8, args[1], "--child")) {
        const mode = std.meta.stringToEnum(Mode, args[2]) orelse return error.InvalidChildMode;
        try child(allocator, mode, args[3], args[4], args[5]);
        try @import("linux_session_peers.zig").drain(allocator);
        try nativeEmpty();
        return;
    }
    if (args.len != 1) return error.InvalidArguments;
    const extension = try std.process.getEnvVarOwned(allocator, "ZIGGURAT_REQUEST_POLICY_EXTENSION");
    defer allocator.free(extension);
    const base = try std.process.getEnvVarOwned(allocator, "ZIGGURAT_PROFILE_TEST_ROOT");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/public-{d}", .{ base, std.time.nanoTimestamp() });
    defer allocator.free(path);
    const live_path = try std.fmt.allocPrint(allocator, "{s}-lifecycle", .{path});
    defer allocator.free(live_path);
    const session_path = try std.fmt.allocPrint(allocator, "{s}-session", .{path});
    defer allocator.free(session_path);
    const ownership_path = try std.fmt.allocPrint(allocator, "{s}-ownership", .{path});
    defer allocator.free(ownership_path);
    const rejected_path = try std.fmt.allocPrint(allocator, "{s}-rejected", .{path});
    defer allocator.free(rejected_path);
    const allocations_path = try std.fmt.allocPrint(allocator, "{s}-allocations", .{path});
    defer allocator.free(allocations_path);
    const recovery_path = try std.fmt.allocPrint(allocator, "{s}-recovery", .{path});
    defer allocator.free(recovery_path);
    const bind = try std.net.Address.parseIp("127.0.0.1", 0);
    var server: Server = .{ .listener = try bind.listen(.{}) };
    try server.start();
    defer server.stop();
    const origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{server.listener.listen_address.getPort()});
    defer allocator.free(origin);
    const executable = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    try spawn(allocator, executable, .ownership, ownership_path, origin, extension);
    try spawn(allocator, executable, .allocations, allocations_path, origin, extension);
    try spawn(allocator, executable, .seed, path, origin, extension);
    try spawn(allocator, executable, .restore, path, origin, extension);
    try std.testing.expect(server.restore_requests.load(.acquire) == 1 and server.restore_cookie.load(.acquire));
    try spawn(allocator, executable, .ephemeral, path, origin, extension);
    try std.testing.expect(server.ephemeral_requests.load(.acquire) == 1 and !server.ephemeral_cookie.load(.acquire));
    try spawn(allocator, executable, .lifecycle, live_path, origin, extension);
    try spawn(allocator, executable, .session, session_path, origin, extension);
    try spawn(allocator, executable, .rejected, rejected_path, origin, extension);
    try spawn(allocator, executable, .recover, recovery_path, origin, extension);
    server.stop();
    if (server.failure) |err| return err;
    std.debug.print("Profile public: first-request cookie and localStorage across child exit, ephemeral isolation, shared manager/distinct contexts, Full rollback, accepted reload survives owner close, parked Session and stop; native refs=0\n", .{});
}
