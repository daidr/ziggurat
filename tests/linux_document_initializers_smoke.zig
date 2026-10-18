const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const certificate = @embedFile("fixtures/profile-https/server-cert.pem");
const material = certificate.* ++ @embedFile("fixtures/profile-https/server-key.pem").* ++ "\x00";
extern fn zinit_https_new([*:0]const u8) ?*anyopaque;
extern fn zinit_https_free(*anyopaque) void;
extern fn zinit_https_origin(*anyopaque, c_uint) [*:0]const u8;
extern fn zinit_https_requests(*anyopaque, c_uint) c_uint;
extern fn g_main_context_iteration(?*anyopaque, c_int) c_int;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
extern fn zwk_profile_counts(*u32, *u32, *usize) void;
const a = [_][]const u8{
    "window.__zigInitializer=['甲😀'];var bodyLocal=1;return;window.__zigInitializer.push('unreachable');",
    "window.__zigInitializer.push('A2:'+typeof bodyLocal,'bridge:'+typeof chrome.webview.postMessage);",
};
const b0 = "window.__zigInitializer=['B1'];var bodyLocal=1;return;window.__zigInitializer.push('unreachable');";
const b = [_][]const u8{ b0, "window.__zigInitializer.push('B2:'+typeof bodyLocal,'bridge:'+typeof chrome.webview.postMessage);" };
const throwing = [_][]const u8{ "window.__zigInitializer=['T1'];throw Error('fixture-initializer-throw');", "window.__zigInitializer.push('unreachable');" };
const opaque_html = "<!doctype html><body><script>const trace=Array.isArray(window.__zigInitializer)?window.__zigInitializer.slice():[];const child=document.createElement('iframe');child.onload=()=>chrome.webview.postMessage(JSON.stringify({trace,origin:location.origin,path:location.pathname,frame:typeof child.contentWindow.__zigInitializer==='undefined'}));document.body.appendChild(child)</script>";
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
const Mode = enum { exercise, close_completion, stop_completion, close_ready, stop_ready };
const Phase = enum { a, b, peer, back, throwing, empty, reset, crashing, recovered, opaque_doc, final_remote };
const Payload = struct { trace: []const []const u8, origin: []const u8, path: []const u8, frame: bool };
const State = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    profile: *web.Profile,
    window: z.Window,
    view: web.View = undefined,
    mode: Mode,
    phase: Phase = .a,
    fixture: *anyopaque,
    origins: [2][]const u8,
    urls: [2][]const u8,
    extension: []const u8,
    grants: [2]web.OriginGrant,
    entries: [2]web.DocumentInitializer = undefined,
    input_origins: [1][]const u8 = undefined,
    mutable_body: [b0.len]u8 = b0.*,
    fail_after: ?usize = null,
    failure: ?anyerror = null,
    domain: ?*anyopaque = null,
    old_page: ?web.PageId = null,
    held_widget: ?*anyopaque = null,
    ready: usize = 0,
    messages: usize = 0,
    completed: usize = 0,
    installed: usize = 0,
    oom: usize = 0,
    recoveries: usize = 0,
    loaded: bool = false,
    messaged: bool = false,
    queued: bool = false,
    checking_current: bool = false,
    nested: bool = false,
    fn faultAllocator(self: *State) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn allocate(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.fail_after) |remaining| {
            if (remaining == 0) return null;
            self.fail_after = remaining - 1;
        }
        return self.allocator.rawAlloc(len, alignment, address);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.allocator.rawFree(bytes, alignment, address);
    }
    fn source(self: *State, bodies: [2][]const u8) []const web.DocumentInitializer {
        self.input_origins[0] = self.origins[0];
        for (&self.entries, bodies) |*entry, body| entry.* = .{ .body = body, .origins = &self.input_origins };
        return &self.entries;
    }
    fn options(self: *State, bodies: [2][]const u8) web.Options {
        const is_opaque = self.phase == .opaque_doc;
        return .{ .html = if (is_opaque) opaque_html else "", .storage = .profile, .profile = self.profile, .remote = if (is_opaque) null else .{ .url = self.urls[0], .origins = &self.grants, .credentials = .profile, .allow_insecure_loopback = true, .allow_script_navigation = true }, .request_policy_extension = if (is_opaque) null else .{ .directory = self.extension }, .document_initializers = self.source(bodies), .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("initializer {s}/{s}: {s}\n", .{ @tagName(self.mode), @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.ready += 1;
                if (self.domain) |domain| {
                    if (view.initializer_domain != domain) return self.fail(error.BudgetDomainChanged);
                } else self.domain = view.initializer_domain orelse return self.fail(error.MissingInitializerDomain);
                if (self.phase == .recovered and self.held_widget != null) {
                    const native = web.initializerNativeCounts();
                    // A retained SDK widget need not keep C state past GTK
                    // destroy/dispose. Only extant framework owners are charged.
                    std.debug.print("initializer retained SDK widget: budgets={d} owners={d} operations={d}\n", .{ native.budgets, native.owners, native.handlers });
                    if (native.budgets != 1 or native.owners < 1 or native.owners > 2 or native.handlers != 0) return self.fail(error.InvalidRecoveryOwners);
                }
                if (self.mode == .close_ready) {
                    _ = self.window.destroy() catch |err| return self.fail(err);
                    self.app.quit();
                } else if (self.mode == .stop_ready) self.app.quit();
            },
            .message => |bytes| self.message(bytes) catch |err| self.fail(err),
            .failed => {
                std.debug.print("initializer native: {any}\n", .{view.nativeFailure()});
                self.fail(error.NativeFailed);
            },
            .process_failed => {
                if (self.phase != .crashing) return self.fail(error.UnexpectedProcessFailure);
                self.recoveries += 1;
                self.phase = .recovered;
                view.recover() catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .started => {
                self.loaded = false;
                self.messaged = false;
            },
            .completed => |result| {
                if (!result.success) return self.fail(error.DocumentLoadFailed);
                self.completed += 1;
                self.loaded = true;
                self.queue();
            },
            else => {},
        }
    }
    fn message(self: *State, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Payload, self.allocator, bytes, .{});
        defer parsed.deinit();
        const value = parsed.value;
        const expected: []const []const u8 = switch (self.phase) {
            .a => &.{ "甲😀", "A2:undefined", "bridge:function" },
            .b, .back, .reset, .recovered, .final_remote => &.{ "B1", "B2:undefined", "bridge:function" },
            .throwing => &.{"T1"},
            .peer, .empty, .opaque_doc => &.{},
            else => return error.UnexpectedMessage,
        };
        errdefer std.debug.print("initializer payload={s}\n", .{bytes});
        try std.testing.expect(!self.messaged and value.frame and value.trace.len == expected.len);
        for (value.trace, expected) |actual, wanted| try std.testing.expectEqualStrings(wanted, actual);
        try std.testing.expectEqualStrings(if (self.phase == .opaque_doc) "null" else self.origins[@intFromBool(self.phase == .peer)], value.origin);
        if (self.phase != .opaque_doc) try std.testing.expectEqualStrings("/oracle", value.path);
        self.messages += 1;
        self.messaged = true;
        self.queue();
    }
    fn queue(self: *State) void {
        if (!self.loaded or !self.messaged or self.queued) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.advanceInner() catch |err| self.fail(err);
    }
    fn completion(ptr: *anyopaque, result: web.InitializerResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .installed or result.installed != self.installed + 1) return self.fail(error.InvalidReplacementResult);
        self.installed += 1;
        if (self.nested) {
            self.nested = false;
            self.replace(b) catch |err| return self.fail(err);
        }
        if (self.mode == .close_completion) {
            _ = self.window.destroy() catch |err| return self.fail(err);
            self.app.quit();
        } else if (self.mode == .stop_completion) self.app.quit();
    }
    fn replace(self: *State, bodies: [2][]const u8) !void {
        const expected = self.installed + 1 + @intFromBool(self.nested);
        const replacement = try self.view.replaceDocumentInitializers(self.source(bodies), .{ .context = self, .complete = completion });
        if (self.failure) |err| return err;
        try std.testing.expect(self.installed == expected);
        if (self.mode == .exercise) try std.testing.expect(!(try replacement.cancel()));
    }
    fn current(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!self.checking_current or result != .json or !std.mem.eql(u8, result.json, "true")) return self.fail(error.CurrentDocumentChanged);
        self.checking_current = false;
        self.phase = .b;
        self.view.refresh() catch |err| self.fail(err);
    }
    fn advanceInner(self: *State) !void {
        if (self.mode != .exercise) {
            try self.replace(b);
            return;
        }
        switch (self.phase) {
            .a => {
                // Stable explicit allocator rejects each preparation allocation
                // before one accepted replacement. Failure owns no completion.
                // Exercise controller OOM, then leave a controller by failing
                // its candidate. The loop now has a stable allocation shape.
                for (0..2) |index| {
                    self.fail_after = index;
                    const rejected = self.view.replaceDocumentInitializers(self.source(b), .{ .context = self, .complete = completion });
                    self.fail_after = null;
                    try std.testing.expectError(error.OutOfMemory, rejected);
                    self.oom += 1;
                    try std.testing.expect(self.installed == 0 and web.initializerNativeCounts().handlers == 0);
                }
                var accepted = false;
                for (0..64) |index| {
                    self.fail_after = index;
                    const attempt = self.view.replaceDocumentInitializers(self.source(.{ &self.mutable_body, b[1] }), .{ .context = self, .complete = completion });
                    self.fail_after = null;
                    if (attempt) |replacement| {
                        try std.testing.expect(self.installed == 1 and !(try replacement.cancel()));
                        accepted = true;
                        break;
                    } else |err| {
                        if (err != error.OutOfMemory) return err;
                        self.oom += 1;
                        try std.testing.expect(self.installed == 0 and web.initializerNativeCounts().handlers == 0);
                    }
                }
                try std.testing.expect(accepted and self.oom > 0);
                @memset(&self.mutable_body, '?');
                self.entries[0].body = "throw Error('caller changed')";
                self.input_origins[0] = "https://changed.invalid";
                self.checking_current = true;
                _ = try self.view.evaluateJS("globalThis.__zigInitializer.join('|')==='甲😀|A2:undefined|bridge:function'", .{}, .{ .context = self, .complete = current });
            },
            .b => {
                self.phase = .peer;
                try self.view.navigateRemote(self.urls[1]);
            },
            .peer => {
                self.phase = .back;
                try self.view.navigateRemote(self.urls[0]);
            },
            .back => {
                try self.replace(throwing);
                self.phase = .throwing;
                try self.view.refresh();
            },
            .throwing => {
                const replacement = try self.view.replaceDocumentInitializers(&.{}, .{ .context = self, .complete = completion });
                try std.testing.expect(!(try replacement.cancel()) and self.installed == 3);
                self.phase = .empty;
                try self.view.refresh();
            },
            .empty => {
                self.nested = true;
                try self.replace(b);
                self.phase = .reset;
                try self.view.refresh();
            },
            .reset => {
                self.old_page = self.view.pageId();
                self.held_widget = g_object_ref(try @import("linux_webview_process.zig").ownedWidget(self.window));
                self.phase = .crashing;
                try @import("linux_webview_process.zig").stop(self.window);
            },
            .recovered => {
                try std.testing.expect(self.recoveries == 1 and !std.meta.eql(self.old_page, self.view.pageId()));
                try std.testing.expectError(error.StalePage, self.view.postFor(self.old_page.?, "old initializer document"));
                const widget = self.held_widget.?;
                self.held_widget = null;
                g_object_unref(widget);
                self.phase = .opaque_doc;
                try self.view.reload(self.options(b));
            },
            .opaque_doc => {
                self.phase = .final_remote;
                try self.view.reload(self.options(b));
            },
            .final_remote => self.app.quit(),
            else => return error.UnexpectedAdvance,
        }
    }
};
fn run(allocator: std.mem.Allocator, base: []const u8, extension: []const u8, mode: Mode) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const fixture = zinit_https_new(material) orelse return error.TlsFixtureFailed;
    defer zinit_https_free(fixture);
    const path = try std.fmt.allocPrint(allocator, "{s}/initializer-{d}-{s}", .{ base, std.time.nanoTimestamp(), @tagName(mode) });
    defer allocator.free(path);
    var preparation: Preparation = .{ .allocator = allocator, .main = app.owner, .path = path };
    try preparation.open();
    defer preparation.value.?.close() catch unreachable;
    const profile = try web.Profile.createWithOptions(allocator, app, &preparation.value.?, .{ .loopback_https = .{ .certificate_pem = certificate } });
    defer profile.close() catch unreachable;
    const origins = [2][]const u8{ std.mem.span(zinit_https_origin(fixture, 0)), std.mem.span(zinit_https_origin(fixture, 1)) };
    const urls = [2][]const u8{ try std.fmt.allocPrint(allocator, "{s}/oracle", .{origins[0]}), try std.fmt.allocPrint(allocator, "{s}/oracle", .{origins[1]}) };
    defer for (urls) |url| allocator.free(url);
    var state: State = .{ .app = app, .allocator = allocator, .profile = profile, .window = try app.createWindow(.{ .width = 160, .height = 100 }), .mode = mode, .fixture = fixture, .origins = origins, .urls = urls, .extension = extension, .grants = .{ .{ .origin = origins[0], .ipc = true }, .{ .origin = origins[1], .ipc = true } } };
    defer _ = state.window.destroy() catch unreachable;
    defer if (state.held_widget) |widget| g_object_unref(widget);
    state.view = web.View.init(state.faultAllocator(), &state, State.event);
    try state.view.attach(state.window, state.options(a));
    state.entries[0].body = "throw Error('changed-before-first-load')";
    state.input_origins[0] = "https://changed.invalid";
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired);
    const first = zinit_https_requests(fixture, 0);
    const peer = zinit_https_requests(fixture, 1);
    if (mode == .exercise) {
        try std.testing.expect(state.messages == 10 and state.completed == 10 and state.installed == 5 and state.ready == 4 and state.recoveries == 1);
        try std.testing.expect(first == 8 and peer == 1);
    } else if (mode == .close_ready or mode == .stop_ready) try std.testing.expect(state.messages == 0 and state.installed == 0 and first == 0 and peer == 0 and state.ready == 1) else try std.testing.expect(state.messages == 1 and state.installed == 1 and first == 1 and peer == 0);
    std.debug.print("Linux initializer {s}: ready={d} documents={d} messages={d} installed={d} OOM={d} requests={d}/{d}\n", .{ @tagName(mode), state.ready, state.completed, state.messages, state.installed, state.oom, first, peer });
}
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
        const view = web.resourceCounts();
        const initializer = web.initializerNativeCounts();
        if (profiles == 0 and contexts == 0 and bytes == 0 and view.states == 0 and view.controllers == 0 and view.handlers == 0 and std.meta.eql(initializer, web.InitializerNativeCounts{})) return;
        _ = g_main_context_iteration(null, 1);
    }
    return error.NativeResponsibilitiesRemain;
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const base = std.posix.getenv("ZIGGURAT_PROFILE_TEST_ROOT") orelse return error.MissingProfileTestRoot;
    const extension = std.posix.getenv("ZIGGURAT_REQUEST_POLICY_EXTENSION") orelse return error.MissingRequestPolicyExtension;
    const filter = std.posix.getenv("ZIGGURAT_INITIALIZER_MODE");
    var selected: usize = 0;
    inline for (std.meta.tags(Mode)) |mode| {
        if (filter == null or std.mem.eql(u8, filter.?, @tagName(mode))) {
            selected += 1;
            try run(allocator, base, extension, mode);
            try drain();
        }
    }
    if (selected == 0) return error.InvalidMode;
    std.debug.print("Linux initializer TLS: exact compiler UTF8, future-document replacement, top/origin/bootstrap/recovery/close/Stop and physical refs=0\n", .{});
}
