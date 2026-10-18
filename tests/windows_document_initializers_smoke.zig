const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const w = @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});
const Record = extern struct { origin: u32, method: i32, authorization: i32, path: [128]u16 };
extern fn zwv_test_initializer_probe_install(*anyopaque, [*]const [*:0]const u16, u32, c_int, *?*anyopaque) i32;
extern fn zwv_test_credential_probe_counts(*anyopaque, *u32, *u32, *u32, *u32, *u32) void;
extern fn zwv_test_credential_probe_record(*anyopaque, u32, *Record) c_int;
extern fn zwv_test_credential_probe_release(*anyopaque) void;
extern fn zwv_test_credential_live_probes() u32;
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
extern fn zwv_test_initializer_observe_retirement(*anyopaque, u64, *anyopaque) i32;
extern fn zwv_test_initializer_observer_clear() void;
extern fn zwv_test_initializer_observer_count() u32;
extern fn zwv_test_initializer_hold(*anyopaque, u64, *anyopaque) i32;
extern fn zwv_test_initializer_held_success() bool;
extern fn zwv_test_initializer_resume() void;
extern fn zwv_test_initializer_hold_clear() void;
const Mode = enum { exercise, close_pending, stop_pending, wrong_certificate };
const Phase = enum { a, installing_b, b, peer, opaque_doc, throwing, held_add, attempted, cancel_retiring, after_cancel, crashing, recovered, empty, installing_reset, reset, closing };
const Payload = struct { path: []const u8, origin: []const u8, trace: []const []const u8, frame: bool, csp: bool };
const bodies_a = [_][]const u8{ "window.__zigInitializer=['甲😀'];var bodyLocal=1;return;window.__zigInitializer.push('unreachable');", "window.__zigInitializer.push('A2:'+typeof bodyLocal);" };
const bodies_b = [_][]const u8{ "window.__zigInitializer=['B1'];var bodyLocal=1;return;window.__zigInitializer.push('unreachable');", "window.__zigInitializer.push('B2:'+typeof bodyLocal);" };
const bodies_throw = [_][]const u8{ "window.__zigInitializer=['T1'];throw Error('expected-initializer-throw');", "window.__zigInitializer.push('unreachable');" };
const opaque_html =
    \\<!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-fixture'; frame-src 'self'; base-uri 'none'; object-src 'none'"><body><script nonce="fixture">
    \\(()=>{try{const trace=Array.isArray(window.__zigInitializer)?window.__zigInitializer.slice():[];
    \\let csp=false;try{new Function('return 1')();}catch(_){csp=true;}
    \\const child=document.createElement('iframe');child.addEventListener('load',()=>{try{
    \\const frame=child.contentWindow.location.href==='about:blank'&&typeof child.contentWindow.__zigInitializer==='undefined';
    \\chrome.webview.postMessage(JSON.stringify({path:location.pathname,origin:location.origin,trace,frame,csp}));
    \\}catch(_){chrome.webview.postMessage('fixture-failed');}},{once:true});document.body.appendChild(child);
    \\}catch(_){chrome.webview.postMessage('fixture-failed');}})();</script>
;
const State = struct {
    app: *z.App = undefined,
    view: *web.View,
    window: z.Window = undefined,
    allocator: std.mem.Allocator,
    mode: Mode,
    origins: [4][]const u8,
    wide: [4][*:0]const u16,
    urls: [7][]const u8,
    profile: []const u8,
    grants: [3]web.OriginGrant,
    entries: [2]web.DocumentInitializer = undefined,
    phase: Phase = .a,
    failure: ?anyerror = null,
    done: bool = false,
    queued: bool = false,
    loaded: bool = false,
    messaged: bool = false,
    messages: u32 = 0,
    installed: u32 = 0,
    cancelled: u32 = 0,
    detached: u32 = 0,
    recoveries: u32 = 0,
    gate_denials: u32 = 0,
    attempt_done: bool = false,
    domain: ?*anyopaque = null,
    replacement: ?web.InitializerReplacement = null,
    event_handle: *anyopaque,
    event_watch: ?z.NativeWaitToken = null,
    probes: [8]?*anyopaque = @splat(null),
    browsers: [8]?*anyopaque = @splat(null),
    epochs: usize = 0,
    cleanup_failure: ?anyerror = null,

    fn source(self: *State, bodies: [2][]const u8) []const web.DocumentInitializer {
        for (&self.entries, bodies) |*entry, body| entry.* = .{ .body = body, .origins = self.origins[0..1] };
        return &self.entries;
    }
    fn options(self: *State) web.Options {
        const is_opaque = self.phase == .opaque_doc;
        // pending-leak is otherwise allowed: its denial must come from the
        // initializer gate, rather than the ordinary script-navigation policy.
        return .{ .html = if (is_opaque) opaque_html else "", .user_data_folder = self.profile, .remote = if (is_opaque) null else .{ .url = self.urls[if (self.mode == .wrong_certificate) 6 else if (self.phase == .throwing) 2 else if (self.phase == .empty) 3 else 0], .origins = &self.grants, .credentials = .profile, .allow_insecure_loopback = true, .allow_script_navigation = true }, .document_initializers = if (self.phase == .empty) &.{} else self.source(if (self.phase == .throwing) bodies_throw else if (is_opaque) bodies_b else bodies_a), .policy = .{ .navigation = .notify }, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("initializer mode={s} phase={s} error={s}\n", .{ @tagName(self.mode), @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                if (self.epochs == self.probes.len) return self.fail(error.TooManyEpochs);
                if (self.domain) |domain| {
                    if (view.initializer_domain != domain) return self.fail(error.BudgetDomainChanged);
                } else self.domain = view.initializer_domain orelse return self.fail(error.MissingBudgetDomain);
                const index = self.epochs;
                if (self.phase != .opaque_doc and zwv_test_initializer_probe_install(view.native.?, &self.wide, 4, 1, &self.probes[index]) < 0) return self.fail(error.ProbeInstallFailed);
                var pid: c_uint = 0;
                if (zwv_browser_process_id(view.native.?, &pid) < 0 or pid == 0) return self.fail(error.BrowserPidUnavailable);
                self.browsers[index] = w.OpenProcess(w.SYNCHRONIZE | w.PROCESS_TERMINATE, w.FALSE, pid) orelse return self.fail(error.BrowserHandleUnavailable);
                self.epochs += 1;
            },
            .message => |message| self.handleMessage(message) catch |err| self.fail(err),
            .policy_request => |request| {
                if (self.phase != .attempted or request.kind != .navigation or !std.mem.eql(u8, request.uri, self.urls[5])) return self.fail(error.UnexpectedNavigationDenial);
                self.gate_denials += 1;
                if (self.attempt_done) self.queue();
            },
            .process_failed => {
                if (self.phase != .crashing) return self.fail(error.UnexpectedProcessFailure);
                self.phase = .recovered;
                self.recoveries += 1;
                view.recover() catch |err| self.fail(err);
            },
            .failed => |hr| {
                std.debug.print("initializer native HRESULT=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
                self.fail(error.NativeFailure);
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
            .completed => |completed| {
                if (!completed.success) {
                    if (self.mode == .wrong_certificate) {
                        self.done = true;
                        self.app.quit();
                    } else if (self.phase != .crashing) self.fail(error.DocumentLoadFailed);
                    return;
                }
                self.loaded = true;
                if (self.messaged) self.queue();
            },
            else => {},
        }
    }
    fn handleMessage(self: *State, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Payload, self.allocator, bytes, .{});
        defer parsed.deinit();
        const value = parsed.value;
        const expected: []const []const u8 = switch (self.phase) {
            .a => &.{ "甲😀", "A2:undefined" },
            .b, .reset => &.{ "B1", "B2:undefined" },
            .throwing, .after_cancel, .recovered => &.{"T1"},
            .peer, .opaque_doc, .empty => &.{},
            else => return error.UnexpectedMessage,
        };
        if (expected.len != value.trace.len or !value.frame or !value.csp) return error.InitializerBodyOrControlMismatch;
        for (expected, value.trace) |left, right| if (!std.mem.eql(u8, left, right)) return error.InitializerTraceMismatch;
        const origin = if (self.phase == .opaque_doc) "null" else self.origins[@intFromBool(self.phase == .peer)];
        if (!std.mem.eql(u8, value.origin, origin)) return error.UnexpectedDocumentOrigin;
        const path = switch (self.phase) {
            .a, .b => "/a/start",
            .peer => "/peer/start",
            .throwing, .after_cancel, .recovered => "/throw/start",
            .empty => "/empty/start",
            .reset => "/guard-reset/start",
            else => null,
        };
        if (path) |expected_path| if (!std.mem.eql(u8, expected_path, value.path)) return error.UnexpectedDocumentPath;
        self.messages += 1;
        self.messaged = true;
        std.debug.print("initializer_document phase={s} trace={d} frame=excluded csp=blocked\n", .{ @tagName(self.phase), value.trace.len });
        if (self.loaded) self.queue();
    }
    fn queue(self: *State) void {
        if (self.queued or self.failure != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.failure != null) return;
        self.next() catch |err| self.fail(err);
    }
    fn next(self: *State) !void {
        switch (self.phase) {
            .a => {
                if (self.mode != .exercise) {
                    self.phase = .closing;
                    _ = try self.view.replaceDocumentInitializers(self.source(bodies_b), .{ .context = self, .complete = completion });
                    self.done = true;
                    if (self.mode == .close_pending) _ = try self.window.destroy();
                    self.app.quit();
                    return;
                }
                self.phase = .installing_b;
                var body = "window.__zigInitializer=['B1'];var bodyLocal=1;return;".*;
                var origins = [_][]const u8{self.origins[0]};
                const entries = [_]web.DocumentInitializer{ .{ .body = &body, .origins = &origins }, .{ .body = bodies_b[1], .origins = &origins } };
                _ = try self.view.replaceDocumentInitializers(&entries, .{ .context = self, .complete = completion });
                @memset(&body, '?');
                origins[0] = "http://changed.test";
                try std.testing.expectError(error.Busy, self.view.refresh());
                try std.testing.expectError(error.Busy, self.view.reload(self.options()));
            },
            .b => {
                self.phase = .peer;
                try self.view.navigateRemote(self.urls[1]);
            },
            .peer => {
                self.phase = .opaque_doc;
                try self.view.reload(self.options());
            },
            .opaque_doc => {
                self.phase = .throwing;
                try self.view.reload(self.options());
            },
            .throwing => {
                self.phase = .held_add;
                self.event_watch = try self.app.watchNative(self.event_handle, .{ .context = self, .call = physicalEvent });
                const replacement = try self.view.replaceDocumentInitializers(&.{.{ .body = "window.__zigInitializer=['C1'];", .origins = self.origins[0..1] }}, .{ .context = self, .complete = completion });
                self.replacement = replacement;
                if (zwv_test_initializer_observe_retirement(self.view.native.?, replacement.token, self.event_handle) < 0 or zwv_test_initializer_hold(self.view.native.?, replacement.token, self.event_handle) < 0) return error.NativeHoldInstallFailed;
            },
            .attempted => {
                if (self.gate_denials != 1) return error.MissingNativeNavigationDenial;
                self.phase = .cancel_retiring;
                if (!try self.replacement.?.cancel()) return error.PendingCancellationFailed;
                self.event_watch = try self.app.watchNative(self.event_handle, .{ .context = self, .call = physicalEvent });
                zwv_test_initializer_resume();
            },
            .after_cancel => {
                self.phase = .crashing;
                if (w.TerminateProcess(self.browsers[self.epochs - 1].?, 1) == 0) return error.OwnBrowserTerminationFailed;
            },
            .recovered => {
                self.phase = .empty;
                try self.view.reload(self.options());
            },
            .empty => {
                if (self.view.initializer_domain != self.domain or web.initializerNativeCounts().budgets != 1) return error.EmptyReloadLostBudgetDomain;
                self.phase = .installing_reset;
                _ = try self.view.replaceDocumentInitializers(self.source(bodies_b), .{ .context = self, .complete = completion });
            },
            .reset => {
                self.done = true;
                self.app.quit();
            },
            else => return error.InvalidPhase,
        }
    }
    fn completion(ptr: *anyopaque, result: web.InitializerResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (result) {
            .installed => |revision| {
                self.installed += 1;
                if (self.phase == .installing_b and revision == 1) {
                    self.phase = .b;
                    // Reenter reload with the just-published owned config.
                    // The original caller's body/descriptors were overwritten
                    // after acceptance, so this also tests future replay.
                    self.view.reload(self.view.config.?.options) catch |err| self.fail(err);
                } else if (self.phase == .installing_reset and revision == 2) {
                    self.phase = .reset;
                    self.view.navigateRemote(self.urls[4]) catch |err| self.fail(err);
                } else self.fail(error.UnexpectedInstallCompletion);
            },
            .cancelled => {
                self.cancelled += 1;
                if (self.phase != .cancel_retiring) return self.fail(error.UnexpectedCancellation);
                std.testing.expectError(error.Busy, self.view.refresh()) catch return self.fail(error.CancelReturnedNativeSlotEarly);
                std.testing.expectError(error.Busy, self.view.replaceDocumentInitializers(&.{}, .{ .context = self, .complete = completion })) catch return self.fail(error.CancelAllowedSecondTransaction);
            },
            .detached => {
                self.detached += 1;
                if (self.phase != .closing) self.fail(error.UnexpectedDetachCompletion);
            },
            .native_failure => |hr| {
                std.debug.print("initializer transaction HRESULT=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
                self.fail(error.NativeTransactionFailed);
            },
        }
    }
    fn physicalEvent(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.event_watch) |watch| _ = self.app.unwatchNative(watch);
        self.event_watch = null;
        if (w.ResetEvent(self.event_handle) == 0) return self.fail(error.EventResetFailed);
        if (self.phase == .held_add) {
            if (!zwv_test_initializer_held_success()) return self.fail(error.HeldSdkAddDidNotInstall);
            self.phase = .attempted;
            const script = std.fmt.allocPrint(self.allocator, "location.href='{s}';'attempted';", .{self.urls[5]}) catch |err| return self.fail(err);
            defer self.allocator.free(script);
            _ = self.view.evaluateJS(script, .{}, .{ .context = self, .complete = attempted }) catch |err| self.fail(err);
        } else if (self.phase == .cancel_retiring) {
            self.phase = .after_cancel;
            self.view.refresh() catch |err| self.fail(err);
        } else self.fail(error.UnexpectedPhysicalEvent);
    }
    fn attempted(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "\"attempted\"")) return self.fail(error.PageNavigationAttemptDidNotExecute);
        self.attempt_done = true;
        if (self.gate_denials == 1) self.queue();
    }
    fn waitBrowsers(self: *State) void {
        const deadline = w.GetTickCount64() + 10_000;
        for (&self.browsers) |*browser| if (browser.*) |handle| {
            const now = w.GetTickCount64();
            if (w.WaitForSingleObject(handle, @intCast(if (deadline > now) deadline - now else 0)) != w.WAIT_OBJECT_0) self.cleanup_failure = error.BrowserShutdownUnconfirmed;
            _ = w.CloseHandle(handle);
            browser.* = null;
        };
    }
    fn releaseReferences(self: *State) void {
        for (&self.browsers) |*browser| if (browser.*) |handle| {
            _ = w.CloseHandle(handle);
            browser.* = null;
        };
        for (&self.probes) |*probe| if (probe.*) |native| {
            zwv_test_credential_probe_release(native);
            probe.* = null;
        };
    }
    fn inspect(self: *State) !void {
        defer self.releaseReferences();
        var allowed: u32 = 0;
        var denied: u32 = 0;
        for (self.probes) |probe| if (probe) |native| {
            var count: u32 = 0;
            var yes: u32 = 0;
            var no: u32 = 0;
            var refs: u32 = 0;
            var overflow: u32 = 0;
            zwv_test_credential_probe_counts(native, &count, &yes, &no, &refs, &overflow);
            if (refs != 1 or overflow != 0) return error.NativeProbeReferenceLeak;
            allowed += yes;
            denied += no;
            for (0..count) |index| {
                var record: Record = undefined;
                if (zwv_test_credential_probe_record(native, @intCast(index), &record) == 0) return error.MissingRequestRecord;
                const path = try std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.sliceTo(&record.path, 0));
                defer self.allocator.free(path);
                std.debug.print("request_oracle origin={d} path={s} method={d} auth={d}\n", .{ record.origin, path, record.method, record.authorization });
            }
        };
        if (self.mode == .wrong_certificate) {
            if (allowed != 0 or denied == 0) return error.CertificatePinNotEnforced;
        } else if (allowed == 0) return error.NoControlledTls;
        const counts = web.initializerNativeCounts();
        const resources = web.resourceCounts();
        if (!std.meta.eql(counts, web.InitializerNativeCounts{}) or resources.states + resources.handlers + resources.controllers != 0 or zwv_test_initializer_observer_count() != 0) return error.NativeInitializerLeak;
        std.debug.print("initializer_summary epochs={d} messages={d} installed={d} cancelled={d} detached={d} recoveries={d} native_gate_denials={d} native_refs=0 budget_bytes=0\n", .{ self.epochs, self.messages, self.installed, self.cancelled, self.detached, self.recoveries, self.gate_denials });
    }
};
fn run(state: *State) !void {
    const app = try z.App.init(state.allocator);
    defer app.deinit();
    state.app = app;
    defer {
        if (state.event_watch) |watch| _ = app.unwatchNative(watch);
        state.event_watch = null;
    }
    state.view.* = web.View.init(state.allocator, state, State.event);
    state.window = try app.createWindow(.{});
    try state.view.attach(state.window, state.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) return error.WatchdogExpired;
    if (state.failure) |err| return err;
    if (!state.done or app.resourceStats().allocated_records != 0) return error.NoTerminalResult;
    if (state.mode == .exercise) {
        if (state.messages != 9 or state.installed != 2 or state.cancelled != 1 or state.detached != 0 or state.recoveries != 1 or state.gate_denials != 1) return error.MissingExerciseStage;
    } else if (state.mode != .wrong_certificate and (state.messages != 1 or state.installed != 0 or state.detached != 1)) return error.MissingDetachStage;
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 7) return error.ExpectedModeOriginsAndProfile;
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.InvalidMode;
    var origins: [4][]const u8 = undefined;
    var wide: [4][:0]u16 = undefined;
    var wide_count: usize = 0;
    defer for (wide[0..wide_count]) |text| allocator.free(text);
    for (&origins, &wide, args[2..6]) |*origin, *text, arg| {
        origin.* = arg;
        text.* = try std.unicode.utf8ToUtf16LeAllocZ(allocator, arg);
        wide_count += 1;
    }
    var urls: [7][]u8 = undefined;
    var url_count: usize = 0;
    defer for (urls[0..url_count]) |text| allocator.free(text);
    for (&urls, [_][]const u8{ "/a/start", "/peer/start", "/throw/start", "/empty/start", "/guard-reset/start", "/pending-leak", "/wrong/start" }, 0..) |*url, path, index| {
        url.* = try std.fmt.allocPrint(allocator, "{s}{s}", .{ origins[if (index == 1) 1 else if (index == 6) 3 else 0], path });
        url_count += 1;
    }
    const event_handle = w.CreateEventW(null, w.TRUE, w.FALSE, null) orelse return error.EventCreateFailed;
    defer _ = w.CloseHandle(event_handle);
    var view: web.View = undefined;
    var state: State = .{ .view = &view, .allocator = allocator, .mode = mode, .origins = origins, .wide = .{ wide[0].ptr, wide[1].ptr, wide[2].ptr, wide[3].ptr }, .urls = .{ urls[0], urls[1], urls[2], urls[3], urls[4], urls[5], urls[6] }, .profile = args[6], .grants = .{ .{ .origin = origins[0], .ipc = true }, .{ .origin = origins[1], .ipc = true }, .{ .origin = origins[3], .ipc = true } }, .event_handle = event_handle };
    var runtime_error: ?anyerror = null;
    run(&state) catch |err| {
        runtime_error = err;
    };
    zwv_test_initializer_observer_clear();
    zwv_test_initializer_hold_clear();
    const cleanup = std.Thread.spawn(.{}, State.waitBrowsers, .{&state}) catch |err| {
        state.releaseReferences();
        return err;
    };
    cleanup.join();
    var inspection_error: ?anyerror = null;
    state.inspect() catch |err| {
        inspection_error = err;
    };
    if (zwv_test_credential_live_probes() != 0) return error.ProbeLeak;
    if (state.cleanup_failure) |err| return err;
    if (runtime_error) |err| return err;
    if (inspection_error) |err| return err;
    std.debug.print("initializer_probe_shutdown=confirmed mode={s}\n", .{@tagName(mode)});
}
