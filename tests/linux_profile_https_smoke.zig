const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const certificate = @embedFile("fixtures/profile-https/server-cert.pem");
const server_material = certificate.* ++ @embedFile("fixtures/profile-https/server-key.pem").* ++ "\x00";
const other_material = @embedFile("fixtures/profile-https/other-cert.pem").* ++ @embedFile("fixtures/profile-https/other-key.pem").* ++ "\x00";
extern fn ztest_https_new([*:0]const u8) ?*anyopaque;
extern fn ztest_https_free(*anyopaque) void;
extern fn ztest_https_origin(*anyopaque) [*:0]const u8;
extern fn ztest_https_counts(*anyopaque, *c_uint, *c_uint, *c_uint, *c_uint, *c_uint) void;
extern fn ztest_https_connections(*anyopaque) c_uint;
extern fn ztest_https_direct(*anyopaque) void;
extern fn ztest_https_is_certificate_error(u32, i32) c_int;
extern fn ztest_https_peer_origin(*anyopaque) [*:0]const u8;
extern fn ztest_https_enable_peer(*anyopaque) void;
extern fn ztest_https_peer_cookie(*anyopaque) c_int;
extern fn ztest_https_stop_server(*anyopaque) void;
extern fn ztest_https_credentials(*anyopaque, c_uint) void;
extern fn ztest_https_credential_counts(*anyopaque, c_uint) c_int;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
extern fn webkit_web_view_terminate_web_process(*anyopaque) void;
extern fn g_main_context_iteration(?*anyopaque, c_int) c_int;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn zwk_profile_counts(*u32, *u32, *usize) void;

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
        const worker_thread = try std.Thread.spawn(.{}, worker, .{self});
        worker_thread.join();
        if (self.failure) |err| return err;
        try self.value.?.adopt();
    }
};

const ConstructorGate = struct {
    backing: std.mem.Allocator,
    app: *z.App,
    prepared: *web.profile_storage.Prepared,
    input: []u8,
    quit: bool,
    hit: bool = false,
    frees: usize = 0,
    target: ?*web.Profile = null,
    withdrawn: bool = false,
    fn allocator(self: *ConstructorGate) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ConstructorGate = @ptrCast(@alignCast(ptr));
        if (!self.hit) {
            self.hit = true;
            @memset(self.input, 0);
            std.testing.expectError(error.ProfileStorageLeasesAlive, self.prepared.close()) catch unreachable;
            if (self.quit) self.app.quit();
        }
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ConstructorGate = @ptrCast(@alignCast(ptr));
        self.frees += 1;
        if (self.target) |target| {
            self.target = null;
            self.withdrawn = target.base.native == null;
            std.testing.expectError(error.Busy, target.close()) catch unreachable;
        }
        self.backing.rawFree(bytes, alignment, ra);
    }
};
fn constructorChecks(allocator: std.mem.Allocator, base: []const u8) !void {
    for ([_]bool{ false, true }) |quit| {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const path = try std.fmt.allocPrint(allocator, "{s}/https-construct-{d}-{}", .{ base, zio.nanoTimestamp(), quit });
        defer allocator.free(path);
        var preparation: Preparation = .{ .allocator = allocator, .main = app.owner, .path = path };
        try preparation.open();
        defer preparation.value.?.close() catch unreachable;
        try std.testing.expectError(error.OutOfMemory, web.Profile.createWithOptions(std.testing.failing_allocator, app, &preparation.value.?, .{ .loopback_https = .{ .certificate_pem = certificate } }));
        try std.testing.expect((try preparation.value.?.stats()).active_leases == 0 and app.resourceStats().stop_participants == 0);
        var input = certificate.*;
        var gate: ConstructorGate = .{ .backing = allocator, .app = app, .prepared = &preparation.value.?, .input = &input, .quit = quit };
        const options: web.Profile.CreateOptions = .{ .loopback_https = .{ .certificate_pem = &input } };
        if (quit) {
            try std.testing.expectError(error.Closed, web.Profile.createWithOptions(gate.allocator(), app, &preparation.value.?, options));
            try std.testing.expect(app.resourceStats().stop_participants == 0 and (try preparation.value.?.stats()).active_leases == 0);
            try app.finishShutdown();
            try std.testing.expect(app.phase == .stopped);
        } else {
            const profile = try web.Profile.createWithOptions(gate.allocator(), app, &preparation.value.?, options);
            gate.target = profile;
            try profile.close();
            try std.testing.expect(gate.withdrawn and gate.target == null);
        }
        try std.testing.expect(gate.hit and gate.frees == 1);
        var profiles: u32 = 0;
        var contexts: u32 = 0;
        var bytes: usize = 0;
        zwk_profile_counts(&profiles, &contexts, &bytes);
        try std.testing.expect(profiles == 0 and contexts == 0 and bytes == 0);
    }
    std.debug.print("HTTPS constructor: caller OOM, owned capture/claim before callback, quit rollback, withdrawn final free, refs=0\n", .{});
}
const Counts = struct {
    requests: c_uint = 0,
    forbidden: c_uint = 0,
    proxy: c_uint = 0,
    cookie: c_uint = 0,
    heads: c_uint = 0,
    fn get(fixture: *anyopaque) Counts {
        var self: Counts = .{};
        ztest_https_counts(fixture, &self.requests, &self.forbidden, &self.proxy, &self.cookie, &self.heads);
        return self;
    }
};
const Mode = enum { trusted, default_proxy, default_direct, wrong_certificate, wrong_host, server_stopped, missing_policy, close_ready, accepted_reload, ipc_denied, storage_ports, park_rehost, recover_parked, stop_pending, request_credentials, request_credentials_missing_policy, request_credentials_close_ready };
fn hasCredentials(mode: Mode) bool {
    return mode == .request_credentials or mode == .request_credentials_missing_policy or mode == .request_credentials_close_ready;
}
fn missingPolicy(mode: Mode) bool {
    return mode == .missing_policy or mode == .request_credentials_missing_policy;
}
fn closeReady(mode: Mode) bool {
    return mode == .close_ready or mode == .request_credentials_close_ready;
}
fn isSession(mode: Mode) bool {
    return mode == .park_rehost or mode == .recover_parked or mode == .stop_pending;
}
const State = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    profile: *web.Profile,
    alternate_profile: ?*web.Profile = null,
    store: ?*web.CookieStore = null,
    window: z.Window,
    view: web.View = undefined,
    session: web.PageSession = undefined,
    owner: ?*z.composition.Owner = null,
    fixture: *anyopaque,
    origin: []const u8,
    url: []const u8,
    extension: []const u8,
    grant: [2]web.OriginGrant,
    credential: [1]web.RequestCredential = undefined,
    credential_enabled: bool = true,
    mode: Mode,
    ready: usize = 0,
    messages: usize = 0,
    completed: usize = 0,
    rejected: bool = false,
    old_page: ?web.PageId = null,
    scripts_detached: usize = 0,
    posts: usize = 0,
    recoveries: usize = 0,
    cookie_queries: usize = 0,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("HTTPS {s}: {s}\n", .{ @tagName(self.mode), @errorName(err) });
        self.app.quit();
    }
    fn options(self: *State) web.Options {
        return .{ .html = "", .storage = .profile, .profile = self.profile, .remote = .{ .url = self.url, .origins = self.grant[0..if (self.mode == .storage_ports or hasCredentials(self.mode)) 2 else 1], .credentials = .profile, .request_credentials = if (hasCredentials(self.mode) and self.credential_enabled) &self.credential else &.{}, .allow_insecure_loopback = true, .allow_redirects = self.mode == .request_credentials }, .request_policy_extension = .{ .directory = self.extension, .handshake_timeout_ms = if (missingPolicy(self.mode)) 300 else 5000 }, .page_listener = .{ .context = self, .event = page } };
    }
    fn attach(self: *State) !void {
        if (isSession(self.mode)) {
            try self.session.open(self.app, .{ .page = self.options() });
            try self.mount();
        } else {
            try self.view.attach(self.window, self.options());
            if (hasCredentials(self.mode)) self.scrambleCredential();
        }
    }
    fn scrambleCredential(self: *State) void {
        self.credential[0] = .{ .origin = self.grant[1].origin, .bearer = @splat(0xee) };
    }
    fn mount(self: *State) !void {
        try self.session.attachRegion(try self.owner.?.reserve(.{ .bounds = .{ .x = 8, .y = 8, .width = 240, .height = 160 } }));
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.ready += 1;
                if (self.ready == 1 and Counts.get(self.fixture).requests != 0) return self.fail(error.RequestBeforeReady);
                if (closeReady(self.mode)) self.app.quit();
            },
            .failed => {
                if (!missingPolicy(self.mode)) {
                    std.debug.print("HTTPS native failure: {any}\n", .{view.nativeFailure()});
                    return self.fail(error.UnexpectedNativeFailure);
                }
                if (view.nativeFailure() == null or view.nativeFailure().? != .glib) return self.fail(error.MissingNativeFailure);
                self.rejected = true;
                self.app.quit();
            },
            .process_failed => {
                if (self.mode == .request_credentials and self.messages == 2 and self.recoveries == 0) {
                    self.recoveries += 1;
                    view.recover() catch |err| self.fail(err);
                    return;
                }
                if (self.mode != .recover_parked or self.messages != 1 or self.recoveries != 0) return self.fail(error.ProcessFailed);
                self.recoveries += 1;
                view.recover() catch |err| return self.fail(err);
                self.profile.seal() catch |err| return self.fail(err);
            },
            .message => |message| {
                if (self.mode == .request_credentials) {
                    self.credentialMessage(view, message) catch |err| self.fail(err);
                    return;
                }
                if (self.mode == .ipc_denied) return self.fail(error.UntrustedIpcAccepted);
                if (self.mode == .storage_ports) {
                    self.storage(view, message) catch |err| self.fail(err);
                    return;
                }
                self.prove(message) catch |err| return self.fail(err);
                self.messages += 1;
                if (self.mode == .accepted_reload and self.messages == 1) {
                    view.reload(self.options()) catch |err| return self.fail(err);
                    self.profile.seal() catch |err| return self.fail(err);
                } else if (isSession(self.mode) and self.messages == 1) {
                    self.old_page = view.pageId();
                    if (self.mode == .recover_parked) {
                        const widget = @import("linux_webview_process.zig").ownedWidget(self.window) catch |err| return self.fail(err);
                        _ = g_object_ref(widget);
                        defer g_object_unref(widget);
                        self.session.park() catch |err| return self.fail(err);
                        webkit_web_view_terminate_web_process(widget);
                    } else if (self.mode == .park_rehost) {
                        _ = view.evaluateJS("globalThis.preserved=41;true", .{}, .{ .context = self, .complete = saved }) catch |err| self.fail(err);
                    } else {
                        self.session.park() catch |err| return self.fail(err);
                        self.app.post(.{ .context = self, .call = stop }) catch |err| self.fail(err);
                    }
                } else if (self.mode == .recover_parked) {
                    if (self.session.currentRegion() != null or std.meta.eql(self.old_page, view.pageId())) return self.fail(error.RecoveryIdentityLost);
                    std.testing.expectError(error.StalePage, view.postFor(self.old_page.?, "old TLS document")) catch |err| return self.fail(err);
                    self.app.quit();
                } else self.app.quit();
            },
            else => {},
        }
    }
    fn credentialMessage(self: *State, view: *web.View, message: []const u8) !void {
        const Value = struct { secure: bool, origin: []const u8, hidden: bool, credential: bool };
        const parsed = std.json.parseFromSlice(Value, self.allocator, message, .{}) catch |err| {
            std.debug.print("credential page: {s}\n", .{message});
            return err;
        };
        defer parsed.deinit();
        try std.testing.expect(parsed.value.secure and parsed.value.hidden and parsed.value.credential);
        try std.testing.expectEqualStrings(self.origin, parsed.value.origin);
        self.messages += 1;
        if (ztest_https_credential_counts(self.fixture, @intCast(self.messages)) == 0) return error.CredentialRequestMismatch;
        switch (self.messages) {
            1 => {
                ztest_https_credentials(self.fixture, 0x6b);
                self.credential[0] = .{ .origin = self.origin, .bearer = @splat(0x6b) };
                try view.reload(self.options());
                self.scrambleCredential();
            },
            2 => {
                const widget = try @import("linux_webview_process.zig").ownedWidget(self.window);
                _ = g_object_ref(widget);
                defer g_object_unref(widget);
                webkit_web_view_terminate_web_process(widget);
            },
            3 => {
                ztest_https_credentials(self.fixture, 0);
                self.credential_enabled = false;
                try view.reload(self.options());
            },
            4 => {
                self.profile = self.alternate_profile.?;
                try view.reload(self.options());
            },
            5 => self.app.quit(),
            else => return error.DuplicateCredentialDocument,
        }
    }
    fn storage(self: *State, view: *web.View, message: []const u8) !void {
        const Value = struct { site: []const u8, before: []const u8, origin: []const u8, secure: bool, hidden: bool };
        const parsed = try std.json.parseFromSlice(Value, self.allocator, message, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.secure and parsed.value.hidden);
        const peer = std.mem.span(ztest_https_peer_origin(self.fixture));
        const is_peer = self.messages == 1;
        try std.testing.expectEqualStrings(if (is_peer) "b" else "a", parsed.value.site);
        try std.testing.expectEqualStrings(if (is_peer) peer else self.origin, parsed.value.origin);
        try std.testing.expectEqualStrings(if (self.messages == 2) "a" else "absent", parsed.value.before);
        self.messages += 1;
        if (self.messages == 3) {
            try std.testing.expect(ztest_https_peer_cookie(self.fixture) != 0);
            self.app.quit();
        } else {
            const url = try std.fmt.allocPrint(self.allocator, "{s}/storage", .{if (self.messages == 1) peer else self.origin});
            defer self.allocator.free(url);
            try view.navigateRemote(url);
        }
    }
    fn saved(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "true")) return self.fail(error.SaveFailed);
        self.session.park() catch |err| return self.fail(err);
        self.mount() catch |err| return self.fail(err);
        if (!std.meta.eql(self.old_page, self.session.page.pageId())) return self.fail(error.ParkChangedPage);
        _ = self.session.page.evaluateJS("preserved===41&&isSecureContext", .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
    }
    fn stop(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        _ = self.session.page.evaluateJS("42", .{ .timeout_ms = 10_000 }, .{ .context = self, .complete = detached }) catch |err| return self.fail(err);
        self.app.post(.{ .context = self, .call = accepted }) catch |err| return self.fail(err);
        self.app.quit();
    }
    fn detached(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .detached) return self.fail(error.StopDidNotDetachScript);
        self.scripts_detached += 1;
    }
    fn accepted(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.app.phase != .stopping) return self.fail(error.PostNotDrainedWhileStopping);
        self.posts += 1;
    }
    fn prove(self: *State, message: []const u8) !void {
        const Value = struct { secure: bool, origin: []const u8, denied: usize, hidden: bool };
        const parsed = try std.json.parseFromSlice(Value, self.allocator, message, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.secure and parsed.value.hidden and parsed.value.denied == 3);
        try std.testing.expectEqualStrings(self.origin, parsed.value.origin);
        const counts = Counts.get(self.fixture);
        try std.testing.expect(counts.forbidden == 0 and counts.proxy == 0 and counts.cookie == 1 and counts.heads >= 1);
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        if (value != .completed) return;
        const self: *State = @ptrCast(@alignCast(ptr));
        self.completed += 1;
        const should_fail = self.mode == .default_proxy or self.mode == .default_direct or self.mode == .wrong_certificate or self.mode == .wrong_host or self.mode == .server_stopped;
        if (should_fail) {
            if (value.completed.success or value.completed.native_status == 0) return self.fail(error.BadCertificateAccepted);
            if (view.nativeFailure() == null or view.nativeFailure().? != .glib) return self.fail(error.MissingTlsFailure);
            if (self.mode != .default_proxy and self.mode != .server_stopped) {
                const failure = view.nativeFailure().?.glib;
                if (ztest_https_is_certificate_error(failure.domain, failure.code) == 0) return self.fail(error.ExpectedCertificateError);
            }
            self.rejected = true;
            self.app.quit();
        } else if (!value.completed.success) return self.fail(error.HttpsLoadFailed) else if (self.mode == .ipc_denied) {
            _ = view.evaluateJS("isSecureContext&&location.protocol==='https:'", .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
        }
    }
    fn evaluated(ptr: *anyopaque, value: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .json or !std.mem.eql(u8, value.json, "true")) return self.fail(error.InvalidSecureContext);
        self.app.quit();
    }
    fn seeded(ptr: *anyopaque, input: web.cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var value = input;
        defer if (value == .cookies) value.cookies.deinit();
        if (value != .completed) return self.fail(error.CookieSeedFailed);
        _ = self.store.?.query(.{ .url = self.url, .name = "tls_seed" }, .{ .context = self, .complete = queried }) catch |err| self.fail(err);
    }
    fn queried(ptr: *anyopaque, input: web.cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var value = input;
        defer if (value == .cookies) value.cookies.deinit();
        if (value != .cookies or value.cookies.rows.len != 1) return self.fail(error.CookieQueryFailed);
        const cookie = value.cookies.rows[0];
        if (!cookie.secure or !cookie.http_only or !std.mem.eql(u8, cookie.value, "present")) return self.fail(error.CookieAttributesLost);
        self.cookie_queries += 1;
        if (self.mode == .storage_ports and self.cookie_queries == 1) {
            const peer = std.mem.span(ztest_https_peer_origin(self.fixture));
            const url = std.fmt.allocPrint(self.allocator, "{s}/storage", .{peer}) catch |err| return self.fail(err);
            defer self.allocator.free(url);
            _ = self.store.?.query(.{ .url = url, .name = "tls_seed" }, .{ .context = self, .complete = queried }) catch |err| self.fail(err);
            return;
        }
        self.attach() catch |err| self.fail(err);
    }
};

fn run(allocator: std.mem.Allocator, base: []const u8, extension: []const u8, mode: Mode) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const fixture = ztest_https_new(if (mode == .wrong_certificate) other_material else server_material) orelse return error.TlsFixtureFailed;
    defer ztest_https_free(fixture);
    if (mode == .storage_ports) ztest_https_enable_peer(fixture);
    if (hasCredentials(mode)) ztest_https_credentials(fixture, 0x5a);
    // No Context or client has existed yet: there is no reusable connection.
    if (mode == .server_stopped) ztest_https_stop_server(fixture);
    const path = try std.fmt.allocPrint(allocator, "{s}/https-{d}-{s}", .{ base, zio.nanoTimestamp(), @tagName(mode) });
    defer allocator.free(path);
    var preparation: Preparation = .{ .allocator = allocator, .main = app.owner, .path = path };
    try preparation.open();
    defer preparation.value.?.close() catch unreachable;
    const profile = if (mode == .default_proxy or mode == .default_direct) try web.Profile.create(allocator, app, &preparation.value.?, .{}) else try web.Profile.createWithOptions(allocator, app, &preparation.value.?, .{ .loopback_https = .{ .certificate_pem = certificate } });
    defer profile.close() catch unreachable;
    const alternate_path = try std.fmt.allocPrint(allocator, "{s}-alternate", .{path});
    defer allocator.free(alternate_path);
    var alternate_preparation: Preparation = .{ .allocator = allocator, .main = app.owner, .path = alternate_path };
    defer if (alternate_preparation.value) |*value| value.close() catch unreachable;
    const alternate_profile = if (mode == .request_credentials) blk: {
        try alternate_preparation.open();
        break :blk try web.Profile.createWithOptions(allocator, app, &alternate_preparation.value.?, .{ .loopback_https = .{ .certificate_pem = certificate } });
    } else null;
    defer if (alternate_profile) |value| value.close() catch unreachable;
    if (mode == .default_direct) {
        var lease = try profile.retainForApp(app);
        defer lease.release() catch unreachable;
        var context = try lease.context();
        defer context.close() catch unreachable;
        ztest_https_direct(try context.webContext());
    }
    const native_origin = std.mem.span(ztest_https_origin(fixture));
    const origin = if (mode == .wrong_host) try std.fmt.allocPrint(allocator, "https://localhost{s}", .{native_origin["https://127.0.0.1".len..]}) else try allocator.dupe(u8, native_origin);
    defer allocator.free(origin);
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ origin, if (mode == .storage_ports) "storage" else if (mode == .request_credentials) "credentials" else "start" });
    defer allocator.free(url);
    const directory = if (missingPolicy(mode)) try std.fmt.allocPrint(allocator, "{s}/absent", .{extension}) else try allocator.dupe(u8, extension);
    defer allocator.free(directory);
    var state: State = .{ .allocator = allocator, .app = app, .profile = profile, .window = try app.createWindow(.{ .width = 320, .height = 200 }), .fixture = fixture, .origin = origin, .url = url, .extension = directory, .grant = .{ .{ .origin = origin, .ipc = mode != .ipc_denied }, .{ .origin = std.mem.span(ztest_https_peer_origin(fixture)), .ipc = true } }, .mode = mode };
    state.view = web.View.init(allocator, &state, State.event);
    state.alternate_profile = alternate_profile;
    if (hasCredentials(mode)) state.credential[0] = .{ .origin = origin, .bearer = @splat(0x5a) };
    state.session = web.PageSession.init(allocator, &state, State.event);
    if (isSession(mode)) state.owner = try z.composition.Owner.create(allocator, state.window, .{ .capacity = 1 });
    defer if (state.owner) |owner| {
        owner.detach() catch {};
        owner.close() catch unreachable;
    };
    defer if (isSession(mode)) {
        _ = state.session.close() catch unreachable;
    };
    const needs_cookie = mode == .trusted or mode == .accepted_reload or mode == .storage_ports or mode == .request_credentials or isSession(mode);
    const store = if (needs_cookie) try web.CookieStore.create(allocator, app, profile, .{ .allow_write = true }) else null;
    defer if (store) |value| {
        _ = value.close() catch unreachable;
    };
    state.store = store;
    if (store) |value| {
        _ = try value.set(.{ .name = "tls_seed", .value = "present", .domain = "127.0.0.1", .path = "/", .secure = true, .http_only = true }, .{ .context = &state, .complete = State.seeded });
    } else try state.attach();
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and app.resourceStats().allocated_records == 0);
    const counts = Counts.get(fixture);
    if (mode == .default_proxy or mode == .default_direct or mode == .wrong_certificate or mode == .wrong_host or missingPolicy(mode) or mode == .server_stopped) {
        try std.testing.expect(state.rejected and counts.requests == 0 and state.messages == 0);
        if (mode == .default_proxy) try std.testing.expect(counts.proxy > 0) else if (missingPolicy(mode) or mode == .server_stopped) try std.testing.expect(counts.proxy == 0 and ztest_https_connections(fixture) == 0) else try std.testing.expect(counts.proxy == 0 and ztest_https_connections(fixture) > 0);
    } else if (closeReady(mode)) {
        try std.testing.expect(state.ready == 1 and counts.requests == 0 and state.messages == 0);
    } else if (mode == .ipc_denied) {
        try std.testing.expect(state.messages == 0 and state.completed == 1);
    } else if (mode == .storage_ports) {
        try std.testing.expect(state.messages == 3 and counts.requests == 3 and counts.forbidden == 0 and counts.proxy == 0);
    } else try std.testing.expectEqual(@as(usize, if (mode == .request_credentials) 5 else if (mode == .accepted_reload or mode == .recover_parked) 2 else 1), state.messages);
    if (isSession(mode)) try std.testing.expect(state.session.phase == .closed and state.session.currentRegion() == null);
    if (mode == .stop_pending) try std.testing.expect(state.scripts_detached == 1 and state.posts == 1 and !(try profile.stats()).accepting);
    if (mode == .recover_parked) try std.testing.expect(state.recoveries == 1);
    std.debug.print("HTTPS {s}: ready={d} loads={d} messages={d} requests={d} blocked={d} proxy={d} accepted={d}\n", .{ @tagName(mode), state.ready, state.completed, state.messages, counts.requests, counts.forbidden, counts.proxy, ztest_https_connections(fixture) });
}

/// Explicit test-only final drain of cancelled C-only responsibilities.
fn drain() !void {
    var expired = false;
    const source = g_timeout_add(3000, struct {
        fn timeout(ptr: *anyopaque) callconv(.c) c_int {
            const value: *bool = @ptrCast(@alignCast(ptr));
            value.* = true;
            return 0;
        }
    }.timeout, &expired);
    defer if (!expired) {
        _ = g_source_remove(source);
    };
    while (!expired) {
        var profiles: u32 = 0;
        var contexts: u32 = 0;
        var bytes: usize = 0;
        zwk_profile_counts(&profiles, &contexts, &bytes);
        const cookies = web.cookieStoreNativeCounts();
        const view = web.resourceCounts();
        if (profiles == 0 and contexts == 0 and bytes == 0 and cookies.stores == 0 and cookies.operations == 0 and cookies.bytes == 0 and view.states == 0 and view.controllers == 0 and view.handlers == 0) return;
        _ = g_main_context_iteration(null, 1);
    }
    return error.NativeResponsibilitiesRemain;
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const base = zio.getenv("ZIGGURAT_PROFILE_TEST_ROOT") orelse return error.MissingProfileTestRoot;
    const extension = zio.getenv("ZIGGURAT_REQUEST_POLICY_EXTENSION") orelse return error.MissingRequestPolicyExtension;
    const filter = zio.getenv("ZIGGURAT_HTTPS_MODE");
    if (filter == null) try constructorChecks(allocator, base);
    var selected: usize = 0;
    inline for (std.meta.tags(Mode)) |mode| {
        if (filter == null or std.mem.eql(u8, filter.?, @tagName(mode))) {
            selected += 1;
            try run(allocator, base, extension, mode);
            try drain();
        }
    }
    if (selected == 0) return error.InvalidHttpsMode;
    std.debug.print("HTTPS loopback: actual TLS, direct default/certificate/host rejection, proxy bypass, first-request/cross-port Cookie, isolated localStorage, Session park/recovery/Stop, refs=0\n", .{});
}
