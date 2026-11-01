//! WKWebView downloads from a granted origin: the app takes the offer, a
//! worker prepares the file and the transfer completes; a decision times out;
//! the page navigates while a decision waits; the app cancels; a received
//! limit stops one; one is still waiting when the app quits. WKDownload has
//! no pause.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_download_count() u32;
const Phase = enum { completed, timeout, navigation, cancelled, limit, closing };
const payload = @as([256 * 1024]u8, @splat(0x6d));
const Server = struct {
    listener: std.Io.net.Server,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    gate: zio.ResetEvent = .{},
    downloads: std.atomic.Value(u32) = .init(0),
    fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    fn stop(self: *Server) void {
        self.stop_requested.store(true, .release);
        self.gate.set();
        const wake = self.listener.socket.address.connect(zio.io(), .{ .mode = .stream }) catch unreachable;
        wake.close(zio.io());
        self.thread.?.join();
        self.listener.deinit(zio.io());
    }
    fn run(self: *Server) void {
        while (true) {
            const connection = self.listener.accept(zio.io()) catch return;
            defer connection.close(zio.io());
            if (self.stop_requested.load(.acquire)) return;
            self.serve(connection) catch {};
        }
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
        var words = std.mem.splitScalar(u8, request[0..used], ' ');
        _ = words.next();
        const path = words.next() orelse return error.InvalidRequest;
        var storage: [512]u8 = undefined;
        if (std.mem.startsWith(u8, path, "/download")) {
            _ = self.downloads.fetchAdd(1, .monotonic);
            const head = try std.fmt.bufPrint(&storage, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=private.bin\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{payload.len});
            try zio.net.sendAll(stream.socket.handle, head);
            try zio.net.sendAll(stream.socket.handle, payload[0..4096]);
            // The first bytes are seen, and over a limit of one, before the rest.
            zio.sleep(200 * std.time.ns_per_ms);
            if (self.stop_requested.load(.acquire)) return;
            try zio.net.sendAll(stream.socket.handle, payload[4096..]);
        } else {
            const body = "<title>private download fixture</title><p>download fixture</p>";
            const head = try std.fmt.bufPrint(&storage, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{body.len});
            try zio.net.sendAll(stream.socket.handle, head);
            try zio.net.sendAll(stream.socket.handle, body);
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
        self.state.view.resolveDownload(self.id, &self.owned.?, .{ .context = self.state, .changed = State.progress }) catch |err| return self.state.fail(err);
        if (self.owned.?.path != null or self.owned.?.wide != null) return self.state.fail(error.TargetNotConsumed);
        if (self.state.phase == .completed) {
            self.id.pause() catch |err| if (err != error.UnsupportedCapability) return self.state.fail(err);
            const current = self.id.snapshot() catch |err| return self.state.fail(err);
            if (current.paused or (current.total_bytes != null and current.total_bytes != payload.len)) return self.state.fail(error.WrongSnapshot);
        }
    }
};
const State = struct {
    app: *z.App,
    view: *web.View,
    directory: []const u8,
    main_thread: std.Thread.Id,
    origin: []const u8,
    start_url: []const u8,
    next_url: []const u8,
    grants: [1]web.OriginGrant = undefined,
    download_origins: [1][]const u8 = undefined,
    phase: Phase = .completed,
    works: [8]Work = undefined,
    work_count: usize = 0,
    ready_destination: ?*Work = null,
    offers: usize = 0,
    completions: usize = 0,
    progress_events: usize = 0,
    navigation_seen: bool = false,
    queued: bool = false,
    started: bool = false,
    done: bool = false,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("macOS download phase={s} error={s}\n", .{ @tagName(self.phase), @errorName(err) });
        }
        self.app.quit();
    }
    fn options(self: *State) web.Options {
        self.grants[0] = .{ .origin = self.origin };
        self.download_origins[0] = self.origin;
        return .{ .html = "", .storage = .ephemeral, .remote = .{ .url = self.start_url, .origins = &self.grants, .credentials = .ephemeral, .allow_insecure_loopback = true }, .downloads = .{ .origins = &self.download_origins, .handler = .{ .context = self, .handle = offer }, .lifetime = .view, .limits = .{ .max_active = 1, .max_received_bytes = if (self.phase == .limit) 1 else payload.len } }, .page_listener = .{ .context = self, .event = page } };
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed, .process_failed => self.fail(error.NativeFailure),
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
        const url = std.fmt.bufPrint(&url_storage, "{s}/download", .{self.origin}) catch unreachable;
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
        if (snapshot.paused) return self.fail(error.UnexpectedPause);
        self.progress_events += 1;
    }
    fn completed(ptr: *anyopaque, result: web.downloads.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        std.debug.print("download terminal phase={s} result={s}\n", .{ @tagName(self.phase), @tagName(result) });
        const valid = switch (self.phase) {
            .completed, .navigation => result == .completed and result.completed.snapshot.received_bytes == payload.len,
            .timeout => result == .timed_out,
            .cancelled => result == .cancelled,
            .limit => result == .limit_exceeded,
            .closing => result == .detached,
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
        self.phase = @fromBackingInt(@intCast(@backingInt(self.phase) + 1));
        self.started = false;
        self.view.reload(self.options()) catch |err| self.fail(err);
    }
};

/// The pages' records and the downloads they took end with the closed view.
const Drain = struct {
    app: *z.App,
    rounds: usize = 0,
    fn clean() bool {
        const counts = web.resourceCounts();
        return counts.states == 0 and counts.handlers == 0 and counts.controllers == 0 and zwk_download_count() == 0;
    }
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.rounds += 1;
        if (clean() or self.rounds == 3000) return self.app.quit();
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var temporary = zio.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try zio.realPathAlloc(temporary.dir, ".", allocator);
    defer allocator.free(directory);
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server: Server = .{ .listener = try address.listen(zio.io(), .{}) };
    try server.start();
    defer server.stop();
    var base_storage: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_storage, "http://127.0.0.1:{d}", .{server.listener.socket.address.getPort()});
    var start_storage: [160]u8 = undefined;
    const start_url = try std.fmt.bufPrint(&start_storage, "{s}/start", .{base});
    var next_storage: [160]u8 = undefined;
    const next_url = try std.fmt.bufPrint(&next_storage, "{s}/next", .{base});
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var view: web.View = undefined;
        var state: State = .{ .app = app, .view = &view, .directory = directory, .main_thread = std.Thread.getCurrentId(), .origin = base, .start_url = start_url, .next_url = next_url };
        defer for (state.works[0..state.work_count]) |*work| {
            if (work.thread) |thread| thread.join();
            if (work.owned) |*owned| owned.deinit();
        };
        view = web.View.init(allocator, &state, State.event);
        const window = try app.createWindow(.{});
        try view.attach(window, state.options());
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        _ = window.destroy() catch {};
        std.debug.print("download offers={d} completions={d} progress={d}\n", .{ state.offers, state.completions, state.progress_events });
        if (state.failure) |err| return err;
        try std.testing.expect(!watchdog.expired and state.done and state.navigation_seen and state.offers == 6 and state.progress_events > 0);
        // The decision still waiting at quit ends detached with the view.
        try std.testing.expect(state.completions == 5 or state.completions == 6);
    }
    {
        // A stopped App takes no posts, so a fresh one turns the run loop.
        const app = try z.App.init(allocator);
        defer app.deinit();
        var drain: Drain = .{ .app = app };
        try app.post(.{ .context = &drain, .call = Drain.tick });
        try app.run();
        if (!Drain.clean()) return error.DownloadRecordsRemain;
    }
    for ([_][]const u8{ "completed.bin", "navigation.bin" }) |name| {
        const bytes = try temporary.dir.readFileAlloc(zio.io(), name, allocator, .limited(payload.len + 1));
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, &payload)) return error.DownloadBytesMismatch;
    }
    std.debug.print("macOS downloads: granted offer to a worker's file, timeout, navigation while deciding, cancel, received limit, quit; no pause; records=0\n", .{});
}
