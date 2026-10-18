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
extern fn zwv_test_credential_probe_install(*anyopaque, [*]const [*:0]const u16, u32, c_int, *?*anyopaque) i32;
extern fn zwv_test_credential_probe_counts(*anyopaque, *u32, *u32, *u32, *u32, *u32) void;
extern fn zwv_test_credential_probe_record(*anyopaque, u32, *Record) c_int;
extern fn zwv_test_credential_probe_release(*anyopaque) void;
extern fn zwv_test_credential_live_probes() u32;
extern fn zwv_test_credential_final_reference() c_int;
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
const Mode = enum { exercise, redirect_denied, close_ready, wrong_certificate };

const State = struct {
    app: *z.App,
    view: *web.View,
    mode: Mode,
    origins: [4][]const u8,
    wide_origins: [4][*:0]const u16,
    profiles: [2][]const u8,
    urls: [4][]const u8,
    grants: [3]web.OriginGrant,
    credentials: [1]web.RequestCredential,
    probes: [8]?*anyopaque = @splat(null),
    browsers: [8]?*anyopaque = @splat(null),
    native_count: usize = 0,
    phase: enum { a, b, crashing, recovered, none, separate } = .a,
    failure: ?anyerror = null,
    done: bool = false,
    queued: bool = false,
    messages: u32 = 0,
    recoveries: u32 = 0,
    cleanup_failure: ?anyerror = null,

    fn options(self: *State) web.Options {
        const decorated = self.phase != .none and self.phase != .separate;
        return .{ .html = "", .user_data_folder = self.profiles[@intFromBool(self.phase == .separate)], .remote = .{
            .url = if (self.mode == .wrong_certificate) self.urls[3] else switch (self.phase) {
                .a => self.urls[0],
                .b, .crashing, .recovered => self.urls[1],
                .none, .separate => self.urls[2],
            },
            .origins = &self.grants,
            .credentials = .profile,
            .allow_insecure_loopback = true,
            .allow_redirects = self.mode != .redirect_denied,
            .request_credentials = if (decorated) &self.credentials else &.{},
        }, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("credential smoke mode={s} phase={s} error={s}\n", .{ @tagName(self.mode), @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                if (self.native_count == self.probes.len) return self.fail(error.TooManyNativeEpochs);
                const index = self.native_count;
                if (zwv_test_credential_probe_install(view.native.?, &self.wide_origins, 4, 1, &self.probes[index]) < 0) return self.fail(error.ProbeInstallFailed);
                self.native_count += 1;
                var pid: c_uint = 0;
                if (zwv_browser_process_id(view.native.?, &pid) < 0 or pid == 0) return self.fail(error.BrowserPidUnavailable);
                self.browsers[index] = w.OpenProcess(w.SYNCHRONIZE | w.PROCESS_TERMINATE, w.FALSE, pid) orelse return self.fail(error.BrowserHandleUnavailable);
                if (self.mode == .close_ready) {
                    self.done = true;
                    self.app.quit();
                }
            },
            .message => |message| {
                const expected = switch (self.phase) {
                    .a => "ready-a",
                    .b, .recovered => "ready-b",
                    .none, .separate => "ready-n",
                    .crashing => return self.fail(error.MessageDuringCrash),
                };
                if (self.mode != .exercise or !std.mem.eql(u8, expected, message)) return self.fail(error.UnexpectedMessage);
                self.messages += 1;
                self.queue();
            },
            .process_failed => {
                if (self.mode != .exercise or self.phase != .crashing) return self.fail(error.UnexpectedProcessFailure);
                self.phase = .recovered;
                self.recoveries += 1;
                view.recover() catch |err| self.fail(err);
            },
            .failed => |hr| {
                std.debug.print("credential native failure HRESULT=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
                self.fail(error.NativeFailure);
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value == .completed and !value.completed.success) {
            if (self.mode == .redirect_denied or self.mode == .wrong_certificate) {
                self.done = true;
                self.app.quit();
            } else if (self.phase != .crashing) self.fail(error.DocumentLoadFailed);
        }
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
        switch (self.phase) {
            .a => {
                self.phase = .b;
                self.credentials[0] = .{ .origin = self.origins[0], .bearer = @splat(0x6b) };
                self.view.reload(self.options()) catch |err| return self.fail(err);
                // Both pending reload and later recover own the accepted input.
                self.credentials[0] = .{ .origin = self.origins[1], .bearer = @splat(0xee) };
            },
            .b => {
                self.phase = .crashing;
                if (w.TerminateProcess(self.browsers[self.native_count - 1].?, 1) == 0) self.fail(error.OwnBrowserTerminationFailed);
            },
            .recovered => {
                self.phase = .none;
                self.view.reload(self.options()) catch |err| self.fail(err);
            },
            .none => {
                self.phase = .separate;
                self.view.reload(self.options()) catch |err| self.fail(err);
            },
            .separate => {
                self.done = true;
                self.app.quit();
            },
            .crashing => self.fail(error.InvalidPhase),
        }
    }
    // Called on an explicit test worker only after App.run and App.deinit.
    fn waitBrowsers(self: *State) void {
        const deadline = w.GetTickCount64() + 10_000;
        for (&self.browsers) |*browser| if (browser.*) |handle| {
            const now = w.GetTickCount64();
            const remaining: u32 = @intCast(if (deadline > now) deadline - now else 0);
            if (w.WaitForSingleObject(handle, remaining) != w.WAIT_OBJECT_0) self.cleanup_failure = error.BrowserShutdownUnconfirmed;
            _ = w.CloseHandle(handle);
            browser.* = null;
        };
    }
    fn releaseCallerReferences(self: *State) void {
        for (&self.browsers) |*browser| if (browser.*) |handle| {
            browser.* = null;
            _ = w.CloseHandle(handle);
        };
        for (&self.probes) |*probe| if (probe.*) |native| {
            probe.* = null;
            zwv_test_credential_probe_release(native);
        };
    }
    fn inspectAndRelease(self: *State, allocator: std.mem.Allocator) !void {
        // On any diagnostic allocation failure, withdraw every caller reference.
        defer for (&self.probes) |*probe| if (probe.*) |native| {
            probe.* = null;
            zwv_test_credential_probe_release(native);
        };
        var certificates_allowed: u32 = 0;
        var certificates_denied: u32 = 0;
        var bad_reference = false;
        for (&self.probes) |*probe| if (probe.*) |native| {
            var count: u32 = 0;
            var allowed: u32 = 0;
            var denied: u32 = 0;
            var references: u32 = 0;
            var overflow: u32 = 0;
            zwv_test_credential_probe_counts(native, &count, &allowed, &denied, &references, &overflow);
            certificates_allowed += allowed;
            certificates_denied += denied;
            bad_reference = bad_reference or references != 1 or overflow != 0;
            for (0..count) |index| {
                var record: Record = undefined;
                if (zwv_test_credential_probe_record(native, @intCast(index), &record) == 0) return error.RecordDisappeared;
                const path = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(&record.path, 0));
                defer allocator.free(path);
                std.debug.print("request_oracle origin={d} path={s} method={d} auth={d}\n", .{ record.origin, path, record.method, record.authorization });
            }
            zwv_test_credential_probe_release(native);
            probe.* = null;
        };
        std.debug.print("credential probes={d} certificates_allowed={d} certificates_denied={d} messages={d} recoveries={d}\n", .{ self.native_count, certificates_allowed, certificates_denied, self.messages, self.recoveries });
        if (bad_reference or zwv_test_credential_live_probes() != 0) return error.NativeProbeReferenceLeak;
        if (self.mode == .wrong_certificate) {
            if (certificates_denied == 0 or certificates_allowed != 0) return error.CertificatePinNotEnforced;
        } else if (self.mode != .close_ready and certificates_allowed == 0) return error.TlsFixtureNotExercised;
    }
};

fn runRuntime(state: *State, allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    state.app = app;
    state.view.* = web.View.init(allocator, state, State.event);
    const window = try app.createWindow(.{});
    try state.view.attach(window, state.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) return error.WatchdogExpired;
    if (state.failure) |err| return err;
    if (!state.done) return error.NoTerminalResult;
    if (state.mode == .exercise and (state.messages != 5 or state.recoveries != 1)) return error.MissingLifecycleStage;
    const counts = web.resourceCounts();
    if (counts.states + counts.handlers + counts.controllers != 0 or app.resourceStats().allocated_records != 0) return error.NativeResourceLeak;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 8) return error.ExpectedModeOriginsAndPrivateProfiles;
    if (!web.backendCapabilities().request_credentials) return error.RequestCredentialCapabilityUnavailable;
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.InvalidMode;
    if (zwv_test_credential_final_reference() == 0) return error.FinalNativeCredentialReferenceFailed;
    var origins: [4][]const u8 = undefined;
    var wide: [4][:0]u16 = undefined;
    var wide_count: usize = 0;
    defer for (wide[0..wide_count]) |text| allocator.free(text);
    for (&origins, &wide, args[2..6]) |*origin, *text, arg| {
        origin.* = arg;
        text.* = try std.unicode.utf8ToUtf16LeAllocZ(allocator, arg);
        wide_count += 1;
    }
    var urls: [4][]u8 = undefined;
    var url_count: usize = 0;
    defer for (urls[0..url_count]) |url| allocator.free(url);
    for (&urls, [_][]const u8{ "/a/top", "/b/top", "/n/top", "/wrong/start" }, 0..) |*url, path, index| {
        url.* = try std.fmt.allocPrint(allocator, "{s}{s}", .{ origins[if (index == 3) 3 else 0], path });
        url_count += 1;
    }
    var view: web.View = undefined;
    var state: State = .{ .app = undefined, .view = &view, .mode = mode, .origins = origins, .wide_origins = .{ wide[0].ptr, wide[1].ptr, wide[2].ptr, wide[3].ptr }, .profiles = .{ args[6], args[7] }, .urls = .{ urls[0], urls[1], urls[2], urls[3] }, .grants = .{ .{ .origin = origins[0], .ipc = true }, .{ .origin = origins[1] }, .{ .origin = origins[3], .ipc = true } }, .credentials = .{.{ .origin = origins[if (mode == .wrong_certificate) 3 else 0], .bearer = @splat(0x5a) }} };
    var runtime_error: ?anyerror = null;
    runRuntime(&state, allocator) catch |err| {
        runtime_error = err;
    };
    const cleanup = std.Thread.spawn(.{}, State.waitBrowsers, .{&state}) catch |err| {
        // App has already detached. Release only our handles/references, without
        // waiting or claiming that the browser's private directory is reusable.
        state.releaseCallerReferences();
        return err;
    };
    cleanup.join();
    const inspection_error: ?anyerror = blk: {
        state.inspectAndRelease(allocator) catch |err| break :blk err;
        break :blk null;
    };
    if (state.cleanup_failure) |err| return err;
    if (runtime_error) |err| return err;
    if (inspection_error) |err| return err;
    std.debug.print("credential_probe_shutdown=confirmed mode={s}\n", .{@tagName(mode)});
}
