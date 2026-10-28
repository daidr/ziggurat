const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Fixture = @import("scheme_smoke.zig").Fixture;
const Watchdog = @import("watchdog.zig").Watchdog;
const Phase = enum { default_deny, completed, timeout, navigation, cancelled, limit, paused, closing };
const payload = [_]u8{0x6d} ** (256 * 1024);
const Server = struct {
    listener: std.net.Server,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    gate: std.Thread.ResetEvent = .{},
    downloads: std.atomic.Value(u32) = .init(0),
    // A transfer still being written must not hold up the next page, so each
    // connection gets its own thread.
    connections: [64]?std.Thread = @splat(null),
    connection_count: usize = 0,
    fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    fn stop(self: *Server) void {
        self.stop_requested.store(true, .release);
        self.gate.set();
        const wake = std.net.tcpConnectToAddress(self.listener.listen_address) catch unreachable;
        wake.close();
        self.thread.?.join();
        for (self.connections[0..self.connection_count]) |connection| connection.?.join();
        self.listener.deinit();
    }
    fn run(self: *Server) void {
        while (true) {
            const connection = self.listener.accept() catch return;
            if (self.stop_requested.load(.acquire)) {
                connection.stream.close();
                return;
            }
            if (self.connection_count < self.connections.len) {
                if (std.Thread.spawn(.{}, serveConnection, .{ self, connection.stream })) |thread| {
                    self.connections[self.connection_count] = thread;
                    self.connection_count += 1;
                    continue;
                } else |_| {}
            }
            serveConnection(self, connection.stream);
        }
    }
    fn serveConnection(self: *Server, stream: std.net.Stream) void {
        defer stream.close();
        self.serve(stream) catch {};
    }
    fn serve(self: *Server, stream: std.net.Stream) !void {
        var request: [8192]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
            if (used == request.len) return error.RequestTooLarge;
            const n = try std.posix.recv(stream.handle, request[used..], 0);
            if (n == 0) return;
            used += n;
        }
        var words = std.mem.splitScalar(u8, request[0..used], ' ');
        _ = words.next();
        const path = words.next() orelse return error.InvalidRequest;
        var storage: [512]u8 = undefined;
        if (std.mem.startsWith(u8, path, "/download")) {
            _ = self.downloads.fetchAdd(1, .monotonic);
            const head = try std.fmt.bufPrint(&storage, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=private.bin\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{payload.len});
            try stream.writeAll(head);
            try stream.writeAll(payload[0..4096]);
            if (std.mem.indexOf(u8, path, "pause") != null) self.gate.wait();
            if (self.stop_requested.load(.acquire)) return;
            try stream.writeAll(payload[4096..]);
        } else {
            const body = "<title>private download fixture</title><script>chrome.webview.postMessage('boot')</script>";
            const head = try std.fmt.bufPrint(&storage, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{body.len});
            try stream.writeAll(head);
            try stream.writeAll(body);
        }
    }
};
const Work = struct {
    state: *State,
    id: web.DownloadId,
    path: [2048]u8 = undefined,
    owned: ?web.DownloadDestination = null,
    thread: ?std.Thread = null,
    err: ?anyerror = null,
    fn run(self: *Work) void {
        self.work() catch |err| {
            self.err = err;
            self.state.app.post(.{ .context = self, .call = fail }) catch {};
        };
    }
    fn work(self: *Work) !void {
        const path = try std.fmt.bufPrint(&self.path, "{s}{c}{s}.bin", .{ self.state.directory, std.fs.path.sep, @tagName(self.state.phase) });
        self.owned = try web.DownloadDestination.prepare(self.state.app.allocator, self.state.main_thread, path, .{});
        errdefer self.owned.?.deinit();
        try self.state.app.post(.{ .context = self, .call = deliver });
    }
    fn fail(ptr: *anyopaque) void {
        const self: *Work = @ptrCast(@alignCast(ptr));
        self.state.fail(self.err.?);
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *Work = @ptrCast(@alignCast(ptr));
        if (self.state.phase == .navigation) {
            self.state.ready_destination = self;
            self.state.view.navigateRemote(self.state.next_url) catch |err| self.state.fail(err);
            return;
        }
        self.resolve();
    }
    fn resolve(self: *Work) void {
        self.state.active_work = self;
        self.state.view.resolveDownload(self.id, &self.owned.?, .{ .context = self.state, .changed = State.progress }) catch |err| return self.state.fail(err);
        if (self.owned.?.path != null or self.owned.?.wide != null) return self.state.fail(error.TargetNotConsumed);
        if (self.state.phase == .paused) {
            self.id.pause() catch |err| return self.state.fail(err);
        }
    }
    fn resumeTransfer(ptr: *anyopaque) void {
        const self: *Work = @ptrCast(@alignCast(ptr));
        self.id.resumeTransfer() catch |err| return self.state.fail(err);
        self.state.server.gate.set();
    }
};
const State = struct {
    app: *z.App,
    view: *web.View,
    fixture: *Fixture,
    server: *Server,
    directory: []const u8,
    main_thread: std.Thread.Id,
    origin: []const u8,
    start_url: []const u8,
    next_url: []const u8,
    grants: [1]web.OriginGrant = undefined,
    download_origins: [1][]const u8 = undefined,
    phase: Phase = .default_deny,
    works: [8]Work = undefined,
    work_count: usize = 0,
    ready_destination: ?*Work = null,
    active_work: ?*Work = null,
    resume_queued: bool = false,
    offers: usize = 0,
    completions: usize = 0,
    pauses: usize = 0,
    navigation_seen: bool = false,
    queued: bool = false,
    started: bool = false,
    done: bool = false,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("download phase={s} error={s} hr=0x{x:0>8}\n", .{ @tagName(self.phase), @errorName(err), @as(u32, @bitCast(self.view.last_hresult)) });
        }
        self.server.gate.set();
        self.app.quit();
    }
    fn options(self: *State) web.Options {
        self.grants[0] = .{ .origin = self.origin, .ipc = true };
        self.download_origins[0] = self.origin;
        return .{ .html = "", .user_data_folder = self.fixture.profile.?, .remote = .{ .url = self.start_url, .origins = &self.grants, .credentials = .profile, .allow_insecure_loopback = true }, .policy = .{ .download = .notify }, .downloads = if (self.phase == .default_deny) null else .{ .origins = &self.download_origins, .handler = .{ .context = self, .handle = offer }, .lifetime = .view, .limits = .{ .max_active = 1, .max_received_bytes = if (self.phase == .limit) 1 else payload.len } }, .page_listener = .{ .context = self, .event = page } };
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => self.fixture.capture(view) catch |err| self.fail(err),
            .failed, .process_failed => self.fail(error.NativeFailure),
            .policy_request => |request| if (request.kind == .download) {
                if (self.phase != .default_deny) return self.fail(error.UnexpectedDownloadDenial);
                self.next();
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .completed or !value.completed.success) return;
        if (self.ready_destination) |work| {
            self.ready_destination = null;
            self.navigation_seen = true;
            work.resolve();
            return;
        }
        if (self.started or self.done) return;
        self.started = true;
        var url_storage: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_storage, "{s}/download{s}", .{ self.origin, if (self.phase == .paused) "?pause" else "" }) catch unreachable;
        self.view.navigateRemote(url) catch |err| self.fail(err);
    }
    fn offer(ptr: *anyopaque, request: web.DownloadOffer, responder: *web.DownloadResponder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        std.debug.print("download offer uri={s} mime={s} name={s} bytes={?d}\n", .{ request.uri, request.mime, request.suggested_name, request.total_bytes });
        if (request.total_bytes != payload.len or !std.mem.startsWith(u8, request.uri, self.origin) or !std.mem.startsWith(u8, request.suggested_name, "private") or !std.mem.endsWith(u8, request.suggested_name, ".bin")) return self.fail(error.WrongOffer);
        self.offers += 1;
        const id = responder.deferDecision(.{ .timeout_ms = if (self.phase == .timeout) 20 else 5000, .completion = .{ .context = self, .complete = completed } }) catch |err| return self.fail(err);
        if (self.phase == .timeout) return;
        if (self.phase == .cancelled) {
            _ = id.cancel() catch |err| return self.fail(err);
            return;
        }
        if (self.phase == .closing) {
            self.done = true;
            self.app.quit();
            return;
        }
        const work = &self.works[self.work_count];
        self.work_count += 1;
        work.* = .{ .state = self, .id = id };
        work.thread = std.Thread.spawn(.{}, Work.run, .{work}) catch |err| return self.fail(err);
    }
    fn progress(ptr: *anyopaque, snapshot: web.downloads.Snapshot) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (snapshot.paused) {
            self.pauses += 1;
            if (self.phase == .paused and !self.resume_queued) {
                self.resume_queued = true;
                const work = self.active_work.?;
                const current = work.id.snapshot() catch |err| return self.fail(err);
                if (!current.paused or current.total_bytes != payload.len) return self.fail(error.WrongPauseSnapshot);
                self.app.post(.{ .context = work, .call = Work.resumeTransfer }) catch |err| self.fail(err);
            }
        }
    }
    fn completed(ptr: *anyopaque, result: web.downloads.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        std.debug.print("download terminal phase={s} result={s}\n", .{ @tagName(self.phase), @tagName(result) });
        const valid = switch (self.phase) {
            .completed, .navigation, .paused => result == .completed and result.completed.snapshot.received_bytes == payload.len,
            .timeout => result == .timed_out,
            .cancelled => result == .cancelled,
            .limit => result == .limit_exceeded,
            .closing => result == .detached,
            else => false,
        };
        if (!valid) {
            std.debug.print("download unexpected terminal={any}\n", .{result});
            return self.fail(error.WrongTerminal);
        }
        self.completions += 1;
        if (!self.done) self.next();
    }
    fn next(self: *State) void {
        if (self.queued or self.done or self.failure != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.phase = @enumFromInt(@intFromEnum(self.phase) + 1);
        self.started = false;
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
            const cleanup = std.Thread.spawn(.{}, Fixture.run, .{&fixture}) catch @panic("cleanup worker");
            cleanup.join();
        }
        if (fixture.profile) |profile| gpa.allocator().free(profile);
    }
    var worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    if (fixture.err) |err| return err;
    // Preparation and final byte validation run on an explicit worker.
    const Prepare = struct {
        temporary: *std.testing.TmpDir,
        allocator: std.mem.Allocator,
        directory: ?[]u8 = null,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.directory = self.temporary.dir.realpathAlloc(self.allocator, ".") catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var prepare: Prepare = .{ .temporary = &temporary, .allocator = gpa.allocator() };
    worker = try std.Thread.spawn(.{}, Prepare.run, .{&prepare});
    worker.join();
    if (prepare.err) |err| return err;
    defer gpa.allocator().free(prepare.directory.?);
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server: Server = .{ .listener = try address.listen(.{}) };
    try server.start();
    defer server.stop();
    var base_storage: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_storage, "http://127.0.0.1:{d}", .{server.listener.listen_address.getPort()});
    var start_storage: [160]u8 = undefined;
    const start_url = try std.fmt.bufPrint(&start_storage, "{s}/start", .{base});
    var next_storage: [160]u8 = undefined;
    const next_url = try std.fmt.bufPrint(&next_storage, "{s}/next", .{base});
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    var view: web.View = undefined;
    var state: State = .{ .app = app, .view = &view, .fixture = &fixture, .server = &server, .directory = prepare.directory.?, .main_thread = std.Thread.getCurrentId(), .origin = base, .start_url = start_url, .next_url = next_url };
    defer for (state.works[0..state.work_count]) |*work| {
        if (work.thread) |thread| thread.join();
        if (work.owned) |*owned| owned.deinit();
    };
    view = web.View.init(gpa.allocator(), &state, State.event);
    const window = try app.createWindow(.{});
    try view.attach(window, state.options());
    fixture.runtime_started = true;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    std.debug.print("download offers={d} completions={d} paused={d} native={any}\n", .{ state.offers, state.completions, state.pauses, web.actionResourceCounts() });
    try std.testing.expect(!watchdog.expired and state.failure == null and state.done and state.offers == 7 and state.completions == 7 and state.navigation_seen and state.pauses > 0);
    const counts = web.actionResourceCounts();
    try std.testing.expect(counts.budgets + counts.permissions + counts.downloads == 0);
    const refs = web.resourceCounts();
    try std.testing.expect(refs.states + refs.handlers + refs.controllers == 0);
    try std.testing.expect(app.resourceStats().allocated_records == 0);
    const Validate = struct {
        temporary: *std.testing.TmpDir,
        allocator: std.mem.Allocator,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.work() catch |err| {
                self.err = err;
            };
        }
        fn work(self: *@This()) !void {
            for ([_][]const u8{ "completed.bin", "navigation.bin", "paused.bin" }) |name| {
                const bytes = try self.temporary.dir.readFileAlloc(self.allocator, name, payload.len + 1);
                defer self.allocator.free(bytes);
                if (!std.mem.eql(u8, bytes, &payload)) return error.DownloadBytesMismatch;
            }
        }
    };
    var validate: Validate = .{ .temporary = &temporary, .allocator = gpa.allocator() };
    worker = try std.Thread.spawn(.{}, Validate.run, .{&validate});
    worker.join();
    if (validate.err) |err| return err;
    fixture.cleanup = true;
    worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    if (fixture.err) |err| return err;
    std.debug.print("download smoke passed: private transfers/default denial/worker targets/navigation/timeout/cancel/limit/pause/quit; resources=0\n", .{});
}
