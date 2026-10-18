const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const ledger = web.policy_store;
const Fixture = @import("scheme_smoke.zig").Fixture;
const Watchdog = @import("watchdog.zig").Watchdog;
const scope: ledger.Scope = .{ .namespace = [_]u8{0x71} ** 16, .policy_epoch = 4 };
const local_origin = "https://app.ziggurat.invalid";
const permission_key: ledger.Key = .{ .origin = local_origin, .subject = .{ .permission = .notifications } };
const Phase = enum { permission, permission_revoked, download, download_limited, download_revoked, final_save };
const payload = [_]u8{0x62} ** (64 * 1024);
const Server = struct {
    listener: std.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    gate: std.Thread.ResetEvent = .{},
    fn run(self: *Server) void {
        while (true) {
            const connection = self.listener.accept() catch return;
            defer connection.stream.close();
            if (self.stopping.load(.acquire)) return;
            self.serve(connection.stream) catch {};
        }
    }
    fn serve(self: *Server, stream: std.net.Stream) !void {
        var request: [8192]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
            if (used == request.len) return error.RequestTooLarge;
            const count = try std.posix.recv(stream.handle, request[used..], 0);
            if (count == 0) return;
            used += count;
        }
        const limited = std.mem.startsWith(u8, request[0..used], "GET /attachment?limited ");
        const attachment = limited or std.mem.startsWith(u8, request[0..used], "GET /attachment ");
        const body: []const u8 = if (attachment) &payload else "<title>private persisted download</title>";
        var storage: [512]u8 = undefined;
        const headers = try std.fmt.bufPrint(&storage, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\n{s}Content-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ if (attachment) "application/octet-stream" else "text/html", if (attachment) "Content-Disposition: attachment; filename=private.bin\r\n" else "", body.len });
        try stream.writeAll(headers);
        if (limited) {
            try stream.writeAll(body[0 .. 32 * 1024]);
            self.gate.wait();
            if (!self.stopping.load(.acquire)) try stream.writeAll(body[32 * 1024 ..]);
        } else try stream.writeAll(body);
    }
    fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        self.gate.set();
        const wake = std.net.tcpConnectToAddress(self.listener.listen_address) catch unreachable;
        wake.close();
        self.thread.?.join();
        self.listener.deinit();
    }
};
const Preparation = struct {
    allocator: std.mem.Allocator,
    temporary: *std.testing.TmpDir,
    directory: ?[]u8 = null,
    policy_path: ?[]u8 = null,
    err: ?anyerror = null,
    fn run(self: *Preparation) void {
        self.work() catch |err| {
            self.err = err;
        };
    }
    fn work(self: *Preparation) !void {
        self.directory = try self.temporary.dir.realpathAlloc(self.allocator, ".");
        errdefer {
            self.allocator.free(self.directory.?);
            self.directory = null;
        }
        self.policy_path = try std.fs.path.join(self.allocator, &.{ self.directory.?, "policy.bin" });
    }
};
const Persist = struct {
    state: *State,
    snapshot: ?ledger.Snapshot,
    candidate: ?*ledger.Store = null,
    thread: ?std.Thread = null,
    err: ?anyerror = null,
    fn run(self: *Persist) void {
        self.work() catch |err| {
            self.err = err;
            if (self.candidate) |candidate| {
                candidate.close() catch unreachable;
                self.candidate = null;
            }
            if (self.snapshot) |*snapshot| snapshot.deinit();
            self.snapshot = null;
            self.state.app.post(.{ .context = self, .call = fail }) catch {};
        };
    }
    fn work(self: *Persist) !void {
        try self.snapshot.?.save(self.state.main_thread, self.state.preparation.policy_path.?, .{});
        self.candidate = try ledger.load(self.state.app.allocator, self.state.main_thread, scope, self.state.preparation.policy_path.?, .{}, null);
        try self.state.app.post(.{ .context = self, .call = install });
    }
    fn fail(ptr: *anyopaque) void {
        const self: *Persist = @ptrCast(@alignCast(ptr));
        self.state.fail(self.err.?);
    }
    fn install(ptr: *anyopaque) void {
        const self: *Persist = @ptrCast(@alignCast(ptr));
        const candidate = self.candidate.?;
        candidate.adopt() catch |err| return self.state.fail(err);
        self.candidate = null;
        var installed = false;
        defer if (!installed) candidate.close() catch unreachable;
        if (self.state.last_lease) |lease| {
            const valid = candidate.validateLease(&lease, 101) catch |err| return self.state.fail(err);
            if (valid) return self.state.fail(error.RevivedOldStoreLease);
        }
        self.state.store.close() catch |err| return self.state.fail(err);
        self.state.store = candidate;
        installed = true;
        self.snapshot.?.deinit();
        self.snapshot = null;
        self.state.installs += 1;
        self.state.installed = true;
        if (self.state.phase == .final_save) {
            if ((candidate.lookup(permission_key, 101) catch |err| return self.state.fail(err)) != null or (candidate.lookup(.{ .origin = self.state.origin, .subject = .download }, 101) catch |err| return self.state.fail(err)) != null) return self.state.fail(error.RevocationDidNotPersist);
            self.state.done = true;
            self.state.app.quit();
            return;
        }
        self.state.startWhenReady();
    }
};
const DecisionWork = struct {
    state: *State,
    id: web.PermissionId,
    lease: ledger.DecisionLease,
    thread: ?std.Thread = null,
    err: ?anyerror = null,
    fn run(self: *DecisionWork) void {
        self.state.app.post(.{ .context = self, .call = decide }) catch |err| {
            self.err = err;
        };
    }
    fn decide(ptr: *anyopaque) void {
        const self: *DecisionWork = @ptrCast(@alignCast(ptr));
        const valid = self.state.store.validateLease(&self.lease, 101) catch |err| return self.state.fail(err);
        if (valid != (self.state.phase == .permission)) return self.state.fail(error.WrongPermissionLeaseValidity);
        self.state.view.decidePermission(self.id, if (valid and self.lease.action.decision() == .allow) .allow_ephemeral else .deny_ephemeral) catch |err| self.state.fail(err);
    }
};
const DownloadWork = struct {
    state: *State,
    id: web.DownloadId,
    lease: ledger.DecisionLease,
    revoked: bool,
    limited: bool = false,
    cancelled_by_rule: bool = false,
    owned: ?web.DownloadDestination = null,
    thread: ?std.Thread = null,
    err: ?anyerror = null,
    fn run(self: *DownloadWork) void {
        self.work() catch |err| {
            self.err = err;
            if (self.owned) |*owned| owned.deinit();
            self.owned = null;
            self.state.app.post(.{ .context = self, .call = fail }) catch {};
        };
    }
    fn work(self: *DownloadWork) !void {
        if (self.lease.action != .download or self.lease.action.download.constraints.folder_key != 7) return error.UnknownFolderKey;
        // Only this fixture resolves key 7 to its own private directory.
        const path = try std.fs.path.join(self.state.app.allocator, &.{ self.state.preparation.directory.?, if (self.revoked) "revoked.bin" else if (self.limited) "limited.bin" else "accepted.bin" });
        defer self.state.app.allocator.free(path);
        self.owned = try web.DownloadDestination.prepare(self.state.app.allocator, self.state.main_thread, path, .{});
        try self.state.app.post(.{ .context = self, .call = resolve });
    }
    fn fail(ptr: *anyopaque) void {
        const self: *DownloadWork = @ptrCast(@alignCast(ptr));
        self.state.fail(self.err.?);
    }
    fn resolve(ptr: *anyopaque) void {
        const self: *DownloadWork = @ptrCast(@alignCast(ptr));
        const valid = self.state.store.validateLease(&self.lease, 101) catch |err| return self.state.fail(err);
        if (valid == self.revoked) return self.state.fail(error.WrongDownloadLeaseValidity);
        if (!valid) {
            _ = self.id.cancel() catch |err| return self.state.fail(err);
            if (self.owned.?.path == null) return self.state.fail(error.InvalidLeaseConsumedTarget);
            self.owned.?.deinit();
            return;
        }
        self.state.view.resolveDownload(self.id, &self.owned.?, .{ .context = self, .changed = progress }) catch |err| return self.state.fail(err);
        if (self.owned.?.path != null) self.state.fail(error.AcceptedTargetNotConsumed);
    }
    fn progress(ptr: *anyopaque, snapshot: web.downloads.Snapshot) void {
        const self: *DownloadWork = @ptrCast(@alignCast(ptr));
        const limit = self.lease.action.download.constraints.max_received_bytes;
        if (snapshot.received_bytes > limit and !self.cancelled_by_rule) {
            self.cancelled_by_rule = true;
            self.state.limited_progress += 1;
            self.state.limited_observed = snapshot.received_bytes;
            const cancelled = self.id.cancel() catch |err| return self.state.fail(err);
            if (!cancelled) return self.state.fail(error.LimitDidNotCancelActiveDownload);
            self.state.server.gate.set();
        }
    }
};
const State = struct {
    app: *z.App,
    view: *web.View,
    fixture: *Fixture,
    preparation: *Preparation,
    server: *Server,
    main_thread: std.Thread.Id,
    store: *ledger.Store,
    origin: []const u8,
    start_url: []const u8,
    attachment_url: []const u8,
    remote_grants: [1]web.OriginGrant = undefined,
    download_origins: [1][]const u8 = undefined,
    phase: Phase = .permission,
    loaded: bool = false,
    installed: bool = false,
    started: bool = false,
    queued: bool = false,
    done: bool = false,
    permission_message: bool = false,
    permission_terminal: bool = false,
    saves: [6]Persist = undefined,
    save_count: usize = 0,
    decisions: [2]DecisionWork = undefined,
    decision_count: usize = 0,
    downloads: [3]DownloadWork = undefined,
    download_count: usize = 0,
    installs: usize = 0,
    permission_count: usize = 0,
    download_terminals: usize = 0,
    limited_progress: usize = 0,
    limited_observed: u64 = 0,
    last_lease: ?ledger.DecisionLease = null,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("policy store phase={s} failure={s} hr=0x{x:0>8}\n", .{ @tagName(self.phase), @errorName(err), @as(u32, @bitCast(self.view.last_hresult)) });
        }
        self.server.gate.set();
        self.app.quit();
    }
    fn options(self: *State) web.Options {
        self.remote_grants[0] = .{ .origin = self.origin };
        self.download_origins[0] = self.origin;
        const permission = self.phase == .permission or self.phase == .permission_revoked;
        return .{ .html = if (permission) "<title>private permission policy</title>" else "", .user_data_folder = self.fixture.profile.?, .local = if (permission) .{} else null, .remote = if (permission) null else .{ .url = self.start_url, .origins = &self.remote_grants, .credentials = .profile, .allow_insecure_loopback = true }, .permissions = if (permission) .{ .grants = &.{.{ .origin = local_origin, .kinds = .{ .notifications = true } }}, .handler = .{ .context = self, .handle = permissionOffer }, .require_user_gesture = false } else null, .downloads = if (permission) null else .{ .origins = &self.download_origins, .handler = .{ .context = self, .handle = downloadOffer }, .lifetime = .view, .limits = .{ .max_known_bytes = payload.len, .max_received_bytes = payload.len } }, .page_listener = .{ .context = self, .event = page } };
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.fixture.capture(view) catch |err| return self.fail(err);
                self.persist();
            },
            .failed, .process_failed => self.fail(error.NativeFailure),
            .message => |message| {
                const expected = if (self.phase == .permission) "granted" else "denied";
                if (!std.mem.eql(u8, message, expected)) return self.fail(error.WrongPermissionJsDecision);
                self.permission_message = true;
                self.nextWhenReady();
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value == .completed and value.completed.success) {
            self.loaded = true;
            self.startWhenReady();
        }
    }
    fn persist(self: *State) void {
        if (self.save_count == self.saves.len) return self.fail(error.TooManyPolicySaves);
        const save = &self.saves[self.save_count];
        self.save_count += 1;
        save.* = .{ .state = self, .snapshot = self.store.snapshot(self.app.allocator) catch |err| return self.fail(err) };
        save.thread = std.Thread.spawn(.{}, Persist.run, .{save}) catch |err| return self.fail(err);
    }
    fn startWhenReady(self: *State) void {
        if (!self.loaded or !self.installed or self.started or self.done or self.failure != null) return;
        self.started = true;
        if (self.phase == .permission or self.phase == .permission_revoked) {
            _ = self.view.evaluateJS("Notification.requestPermission().then(x=>chrome.webview.postMessage(x))", .{}, .{ .context = self, .complete = scriptComplete }) catch |err| self.fail(err);
        } else {
            var storage: [256]u8 = undefined;
            const url = if (self.phase == .download_limited) std.fmt.bufPrint(&storage, "{s}?limited", .{self.attachment_url}) catch unreachable else self.attachment_url;
            self.view.navigateRemote(url) catch |err| self.fail(err);
        }
    }
    fn scriptComplete(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .json and result != .page_changed and result != .detached) self.fail(error.ScriptFailed);
    }
    fn permissionOffer(ptr: *anyopaque, offer: web.PermissionOffer, responder: *web.PermissionResponder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (offer.kind != .notifications or !std.mem.eql(u8, offer.origin, local_origin)) return self.fail(error.WrongPermissionOffer);
        const lease = (self.store.lookup(.{ .origin = offer.origin, .subject = .{ .permission = offer.kind } }, 101) catch |err| return self.fail(err)) orelse return self.fail(error.MissingSavedPermission);
        self.last_lease = lease;
        const id = responder.deferDecision(.{ .completion = .{ .context = self, .complete = permissionComplete } }) catch |err| return self.fail(err);
        if (self.phase == .permission_revoked) {
            _ = self.store.revoke(permission_key) catch |err| return self.fail(err);
        }
        const work = &self.decisions[self.decision_count];
        self.decision_count += 1;
        work.* = .{ .state = self, .id = id, .lease = lease };
        work.thread = std.Thread.spawn(.{}, DecisionWork.run, .{work}) catch |err| return self.fail(err);
    }
    fn permissionComplete(ptr: *anyopaque, result: web.permissions.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const expected: web.permissions.Decision = if (self.phase == .permission) .allow_ephemeral else .deny_ephemeral;
        if (result != .decided or result.decided != expected) return self.fail(error.WrongPermissionTerminal);
        self.permission_count += 1;
        self.permission_terminal = true;
        self.nextWhenReady();
    }
    fn downloadOffer(ptr: *anyopaque, offer: web.DownloadOffer, responder: *web.DownloadResponder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (offer.total_bytes != payload.len) return self.fail(error.WrongDownloadOffer);
        const lease = (self.store.lookup(.{ .origin = self.origin, .subject = .download }, 101) catch |err| return self.fail(err)) orelse return self.fail(error.MissingSavedDownload);
        const constraints = lease.action.download.constraints.intersect(.{ .max_known_bytes = payload.len, .max_received_bytes = payload.len });
        if (offer.total_bytes.? > constraints.max_known_bytes or lease.action.decision() != .allow) return self.fail(error.DownloadPolicyNotNarrowed);
        self.last_lease = lease;
        const id = responder.deferDecision(.{ .completion = .{ .context = self, .complete = downloadComplete } }) catch |err| return self.fail(err);
        const revoked = self.phase == .download_revoked;
        if (revoked) {
            _ = self.store.revoke(.{ .origin = self.origin, .subject = .download }) catch |err| return self.fail(err);
        }
        const work = &self.downloads[self.download_count];
        self.download_count += 1;
        work.* = .{ .state = self, .id = id, .lease = lease, .revoked = revoked, .limited = self.phase == .download_limited };
        work.thread = std.Thread.spawn(.{}, DownloadWork.run, .{work}) catch |err| return self.fail(err);
    }
    fn downloadComplete(ptr: *anyopaque, result: web.downloads.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.phase == .download) {
            if (result != .completed or result.completed.snapshot.received_bytes != payload.len or result.completed.snapshot.received_bytes > payload.len) return self.fail(error.WrongDownloadTerminal);
        } else if (result != .cancelled) return self.fail(error.RevokedDownloadCommitted);
        self.download_terminals += 1;
        self.nextWhenReady();
    }
    fn nextWhenReady(self: *State) void {
        if (self.queued or self.done or self.failure != null) return;
        if ((self.phase == .permission or self.phase == .permission_revoked) and (!self.permission_message or !self.permission_terminal)) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.phase = @enumFromInt(@intFromEnum(self.phase) + 1);
        self.loaded = false;
        self.installed = false;
        self.started = false;
        self.permission_message = false;
        self.permission_terminal = false;
        if (self.phase == .download_limited or self.phase == .download_revoked) self.store.put(.{ .origin = self.origin, .issued_at = 100, .expires_at = 1000, .action = .{ .download = .{ .decision = .allow, .constraints = .{ .max_known_bytes = payload.len, .max_received_bytes = if (self.phase == .download_limited) 1 else payload.len, .folder_key = 7 } } } }) catch |err| return self.fail(err);
        if (self.phase == .final_save) self.persist() else self.view.reload(self.options()) catch |err| self.fail(err);
    }
    fn finishWorkers(self: *State) !void {
        var failure: ?anyerror = null;
        for (self.saves[0..self.save_count]) |*save| {
            if (save.thread) |thread| thread.join();
            save.thread = null;
            if (save.err) |err| {
                if (failure == null) failure = err;
            }
        }
        for (self.decisions[0..self.decision_count]) |*work| {
            if (work.thread) |thread| thread.join();
            work.thread = null;
            if (work.err) |err| {
                if (failure == null) failure = err;
            }
        }
        for (self.downloads[0..self.download_count]) |*work| {
            if (work.thread) |thread| thread.join();
            work.thread = null;
            if (work.err) |err| {
                if (failure == null) failure = err;
            }
        }
        if (failure) |err| return err;
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
    var preparation: Preparation = .{ .allocator = gpa.allocator(), .temporary = &temporary };
    worker = try std.Thread.spawn(.{}, Preparation.run, .{&preparation});
    worker.join();
    if (preparation.err) |err| return err;
    defer {
        if (preparation.directory) |directory| gpa.allocator().free(directory);
        if (preparation.policy_path) |path| gpa.allocator().free(path);
    }
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server: Server = .{ .listener = try address.listen(.{}) };
    try server.start();
    defer server.stop();
    var origin_storage: [128]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_storage, "http://127.0.0.1:{d}", .{server.listener.listen_address.getPort()});
    var start_storage: [160]u8 = undefined;
    const start = try std.fmt.bufPrint(&start_storage, "{s}/start", .{origin});
    var attachment_storage: [160]u8 = undefined;
    const attachment = try std.fmt.bufPrint(&attachment_storage, "{s}/attachment", .{origin});
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    var view: web.View = undefined;
    const store = try ledger.Store.init(gpa.allocator(), std.Thread.getCurrentId(), scope, .{});
    var state: State = .{ .app = app, .view = &view, .fixture = &fixture, .preparation = &preparation, .server = &server, .main_thread = std.Thread.getCurrentId(), .store = store, .origin = origin, .start_url = start, .attachment_url = attachment };
    defer {
        state.finishWorkers() catch {};
        for (state.saves[0..state.save_count]) |*save| {
            if (save.snapshot) |*snapshot| snapshot.deinit();
        }
        for (state.downloads[0..state.download_count]) |*work| {
            if (work.owned) |*owned| owned.deinit();
        }
        state.store.close() catch unreachable;
    }
    try store.put(.{ .origin = local_origin, .issued_at = 100, .expires_at = 1000, .action = .{ .permission = .{ .kind = .notifications, .decision = .allow } } });
    try store.put(.{ .origin = origin, .issued_at = 100, .expires_at = 1000, .action = .{ .download = .{ .decision = .allow, .constraints = .{ .max_known_bytes = payload.len, .max_received_bytes = payload.len, .folder_key = 7 } } } });
    view = web.View.init(gpa.allocator(), &state, State.event);
    const window = try app.createWindow(.{});
    try view.attach(window, state.options());
    fixture.runtime_started = true;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    server.gate.set();
    watchdog.stop();
    try state.finishWorkers();
    std.debug.print("policy store installs={d} permission={d} download={d} limited_progress={d} observed={d} rule_limit=1 view_limit={d} refs={any}\n", .{ state.installs, state.permission_count, state.download_terminals, state.limited_progress, state.limited_observed, payload.len, web.actionResourceCounts() });
    try std.testing.expect(!watchdog.expired and state.failure == null and state.done and state.installs == 6 and state.permission_count == 2 and state.download_terminals == 3 and state.limited_progress == 1);
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
            const bytes = try self.temporary.dir.readFileAlloc(self.allocator, "accepted.bin", payload.len + 1);
            defer self.allocator.free(bytes);
            try std.testing.expectEqualSlices(u8, &payload, bytes);
            try std.testing.expectError(error.FileNotFound, self.temporary.dir.openFile("revoked.bin", .{}));
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
    std.debug.print("policy store smoke passed: worker save/load/post/adopt, persistent permission/download decisions, exact capability gates, revoked leases denied before native commit, narrower progress cancellation, 64KiB bytes and final revoked file; COM=0\n", .{});
}
