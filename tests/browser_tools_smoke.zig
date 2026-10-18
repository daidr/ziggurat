const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const Server = @import("remote_page_smoke.zig").Server;
const w = @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
const Kind = enum { small, cookies, deleted, find, capture, pdf, clear, empty, cancel, detached, rejected };
const Case = struct {
    state: *State,
    kind: Kind,
    fn complete(ptr: *anyopaque, result: web.tools.Result) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        self.state.complete(self.kind, result);
    }
};
const State = struct {
    app: *z.App,
    view: *web.View,
    profile: []const u8,
    fixture: *PdfFile,
    url: []const u8,
    other_url: []const u8,
    pdf_path: []const u8,
    origins: [2]web.OriginGrant,
    cases: [11]Case = undefined,
    calls: [11]u32 = @splat(0),
    phase: enum { denied, small, large, cookie_visibility, cookie_deleted, find_start, find_next, find_previous, capture, pdf, clear, storage, closing } = .denied,
    failed: ?anyerror = null,
    done: bool = false,
    queued: bool = false,
    png_bytes: usize = 0,
    script_detached: u32 = 0,
    cookie_clock: ?std.time.Timer = null,
    cookie_timer: ?*anyopaque = null,
    cookie_watch: ?z.NativeWaitToken = null,
    cookie_checks: u32 = 0,
    cookie_set_checks: u32 = 0,
    cookie_delete_checks: u32 = 0,
    const cookie_deadline_ns = 5 * std.time.ns_per_s;
    fn closeCookieTimer(self: *State) void {
        if (self.cookie_watch) |watch| _ = self.app.unwatchNative(watch);
        self.cookie_watch = null;
        if (self.cookie_timer) |timer| {
            _ = w.CancelWaitableTimer(timer);
            _ = w.CloseHandle(timer);
        }
        self.cookie_timer = null;
    }
    fn pauseCookieTimer(self: *State) void {
        if (self.cookie_watch) |watch| _ = self.app.unwatchNative(watch);
        self.cookie_watch = null;
        if (self.cookie_timer) |timer| _ = w.CancelWaitableTimer(timer);
    }
    fn cookieDeadlineError(self: *State) anyerror {
        return if (self.phase == .large) error.CookieSetDeadlineExceeded else error.CookieDeleteDeadlineExceeded;
    }
    fn cookieRead(self: *State) void {
        const elapsed = self.cookie_clock.?.read();
        if (elapsed >= cookie_deadline_ns or self.cookie_checks >= 128) return self.fail(self.cookieDeadlineError());
        const remaining_ms = (cookie_deadline_ns - elapsed + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        const setting = self.phase == .large;
        _ = self.view.getCookies(if (setting) self.other_url else self.url, .{ .timeout_ms = @intCast(remaining_ms) }, self.completion(if (setting) .cookies else .deleted)) catch |err| self.fail(err);
    }
    fn cookieTimerReady(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.cookie_watch = null;
        if (self.failed == null and (self.phase == .large or self.phase == .cookie_deleted)) self.cookieRead();
    }
    fn observeCookieAgain(self: *State) void {
        const elapsed = self.cookie_clock.?.read();
        if (elapsed >= cookie_deadline_ns or self.cookie_checks >= 128) return self.fail(self.cookieDeadlineError());
        if (self.cookie_timer == null) self.cookie_timer = w.CreateWaitableTimerW(null, w.TRUE, null) orelse return self.fail(error.CookieTimerCreateFailed);
        var due: w.LARGE_INTEGER = undefined;
        due.QuadPart = -@as(i64, @intCast((@min(50 * std.time.ns_per_ms, cookie_deadline_ns - elapsed) + 99) / 100));
        if (w.SetWaitableTimer(self.cookie_timer.?, &due, 0, null, null, w.FALSE) == 0) return self.fail(error.CookieTimerArmFailed);
        self.cookie_watch = self.app.watchNative(self.cookie_timer.?, .{ .context = self, .call = cookieTimerReady }) catch |err| return self.fail(err);
    }
    fn completion(self: *State, kind: Kind) web.tools.Completion {
        return .{ .context = &self.cases[@intFromEnum(kind)], .complete = Case.complete };
    }
    fn options(self: *State) web.Options {
        const enabled = self.phase != .denied;
        return .{ .html = "", .user_data_folder = self.profile, .remote = .{ .url = self.url, .origins = &self.origins, .credentials = .profile, .allow_insecure_loopback = true }, .tools = .{ .cookies = enabled, .clear_entire_profile = enabled, .find = enabled, .capture = enabled, .pdf = enabled }, .tool_limits = .{ .max_pending = 2, .max_capture_bytes = if (self.phase == .small) 32 else 4 * 1024 * 1024 }, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        self.failed = err;
        std.debug.print("browser tools phase={s}: {s} (cookie checks={d})\n", .{ @tagName(self.phase), @errorName(err), self.cookie_checks });
        self.closeCookieTimer();
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => self.fixture.captureBrowser(view) catch |err| self.fail(err),
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value == .completed) {
            if (!value.completed.success) return self.fail(error.LoadFailed);
            self.queue();
        }
    }
    fn queue(self: *State) void {
        if (self.queued or self.failed != null or self.done) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn findChanged(ptr: *anyopaque, snapshot: web.tools.FindState) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (snapshot.matches != @as(?i32, 2)) return;
        if ((self.phase == .find_start and snapshot.active_index == @as(?i32, 1)) or (self.phase == .find_next and snapshot.active_index == @as(?i32, 2)) or (self.phase == .find_previous and snapshot.active_index == @as(?i32, 1))) self.queue();
    }
    fn complete(self: *State, kind: Kind, result: web.tools.Result) void {
        if (result == .native_failure) std.debug.print("browser tool native failure kind={s} HRESULT=0x{x:0>8}\n", .{ @tagName(kind), @as(u32, @bitCast(result.native_failure)) });
        if (kind != .deleted and kind != .cookies) self.calls[@intFromEnum(kind)] += 1;
        switch (kind) {
            .small => {
                if (result != .limit_exceeded) return self.fail(error.UnboundedCapture);
                self.phase = .large;
                self.view.reload(self.options()) catch |err| self.fail(err);
            },
            .cookies => {
                self.cookie_checks += 1;
                if (result != .cookies) return self.fail(if (result == .timed_out) error.CookieSetReadTimedOut else error.MissingCookies);
                var found = false;
                for (result.cookies) |cookie| if (std.mem.eql(u8, cookie.name, "private_cookie")) {
                    found = std.mem.eql(u8, cookie.value, "secret") and cookie.http_only and cookie.session and !cookie.secure and cookie.same_site == .lax and std.mem.eql(u8, cookie.domain, "127.0.0.1") and std.mem.eql(u8, cookie.path, "/");
                };
                if (!found) return self.observeCookieAgain();
                self.cookie_set_checks = self.cookie_checks;
                self.calls[@intFromEnum(kind)] += 1;
                self.pauseCookieTimer();
                // The explicitly authorized second port sees the same cookie.
                // Origin authorization does not turn cookies into port isolation.
                self.phase = .cookie_visibility;
                _ = self.view.evaluateJS("document.cookie.includes('private_cookie')", .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
            },
            .deleted => {
                self.cookie_checks += 1;
                if (result != .cookies) return self.fail(if (result == .timed_out) error.CookieDeleteReadTimedOut else error.MissingCookies);
                for (result.cookies) |cookie| if (std.mem.eql(u8, cookie.name, "private_cookie")) {
                    if (self.cookie_clock.?.read() >= cookie_deadline_ns or self.cookie_checks >= 128) std.debug.print("cookie remained: {s} domain={s} path={s} secure={} http_only={}\n", .{ cookie.name, cookie.domain, cookie.path, cookie.secure, cookie.http_only });
                    // Mutation acceptance has no completion callback. Observe it
                    // only in this bounded test driver, without blocking the UI.
                    return self.observeCookieAgain();
                };
                self.calls[@intFromEnum(kind)] += 1;
                self.cookie_delete_checks = self.cookie_checks;
                self.closeCookieTimer();
                self.phase = .find_start;
                _ = self.view.startFind(self.view.pageId().?, .{ .term = "needle", .case_sensitive = true, .whole_word = true, .listener = .{ .context = self, .changed = findChanged } }, .{}, self.completion(.find)) catch |err| self.fail(err);
            },
            .find => {
                if (result != .find) return self.fail(error.FindFailed);
                self.findChangedFromResult(result.find);
            },
            .capture => {
                if (result != .png or result.png.len < 24 or !std.mem.eql(u8, result.png[0..8], "\x89PNG\r\n\x1a\n") or std.mem.readInt(u32, result.png[16..20], .big) == 0 or std.mem.readInt(u32, result.png[20..24], .big) == 0) return self.fail(error.InvalidPng);
                self.png_bytes = result.png.len;
                self.phase = .pdf;
                self.queue();
            },
            .pdf => {
                if (result != .pdf_path or !std.mem.eql(u8, result.pdf_path, self.pdf_path)) return self.fail(error.PdfFailed);
                self.phase = .clear;
                self.queue();
            },
            .clear => {
                if (result != .cleared) {
                    std.debug.print("profile clear terminal result={any}\n", .{result});
                    return self.fail(error.ClearFailed);
                }
                self.phase = .storage;
                _ = self.view.evaluateJS("localStorage.getItem('fixture')", .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
            },
            .empty => {
                if (result != .cookies or result.cookies.len != 0) return self.fail(error.ClearCookiesFailed);
                const cancelled = self.view.getCookies(self.url, .{}, self.completion(.cancel)) catch |err| return self.fail(err);
                if (!(cancelled.cancel() catch |err| return self.fail(err))) return self.fail(error.CancelLost);
                _ = self.view.getCookies(self.url, .{ .timeout_ms = 5000 }, self.completion(.detached)) catch |err| return self.fail(err);
                _ = self.view.evaluateJS("'not-delivered-after-quit'", .{ .timeout_ms = 5000 }, .{ .context = self, .complete = scriptDetached }) catch |err| return self.fail(err);
                _ = self.view.capturePreview(self.view.pageId().?, .{}, self.completion(.rejected)) catch |err| {
                    if (err != error.Full) return self.fail(err);
                    self.phase = .closing;
                    self.app.quit();
                    return;
                };
                self.fail(error.UnboundedNativeTools);
            },
            .cancel => if (result != .cancelled) {
                self.fail(error.CancelDidNotTerminate);
            },
            .detached => {
                if (result != .detached) {
                    std.debug.print("quit tool terminal result={any}\n", .{result});
                    return self.fail(error.DetachDidNotTerminate);
                }
                self.done = true;
            },
            .rejected => self.fail(error.RejectedContextWasTaken),
        }
    }
    fn findChangedFromResult(self: *State, snapshot: web.tools.FindState) void {
        findChanged(self, snapshot);
    }
    fn scriptDetached(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .detached) {
            std.debug.print("quit script terminal result={any}\n", .{result});
            return self.fail(error.ScriptQuitDidNotDetach);
        }
        self.script_detached += 1;
    }
    fn evaluated(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.QueryFailed);
        if (self.phase == .cookie_visibility) {
            if (!std.mem.eql(u8, result.json, "false")) return self.fail(error.HttpOnlyExposed);
            self.cookie_clock = std.time.Timer.start() catch |err| return self.fail(err);
            self.cookie_checks = 0;
            self.view.deleteCookie(self.url, .{ .name = "private_cookie", .path = "/", .accept_cookie_scope = true }) catch |err| return self.fail(err);
            self.phase = .cookie_deleted;
            self.cookieRead();
        } else if (self.phase == .storage) {
            if (!std.mem.eql(u8, result.json, "null")) return self.fail(error.StorageNotCleared);
            _ = self.view.getCookies(self.url, .{}, self.completion(.empty)) catch |err| self.fail(err);
        } else self.fail(error.UnexpectedQuery);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        const page_id = self.view.pageId() orelse return self.fail(error.NoPage);
        switch (self.phase) {
            .denied => {
                _ = self.view.capturePreview(page_id, .{}, self.completion(.rejected)) catch |err| {
                    if (err != error.ToolDenied) return self.fail(err);
                    self.phase = .small;
                    self.view.reload(self.options()) catch |reload_err| self.fail(reload_err);
                    return;
                };
                self.fail(error.DefaultToolsAllowed);
            },
            .small => {
                _ = self.view.capturePreview(page_id, .{ .timeout_ms = 5000 }, self.completion(.small)) catch |err| self.fail(err);
            },
            .large => {
                self.cookie_clock = std.time.Timer.start() catch |err| return self.fail(err);
                self.cookie_checks = 0;
                self.view.setCookie(self.url, .{ .name = "private_cookie", .value = "secret", .secure = false, .http_only = true, .accept_cookie_scope = true }) catch |err| return self.fail(err);
                _ = self.view.getCookies("https://unknown.example/", .{}, self.completion(.rejected)) catch |err| {
                    if (err != error.OriginDenied) return self.fail(err);
                    self.cookieRead();
                    return;
                };
                self.fail(error.UnknownCookieOriginAllowed);
            },
            .find_start => {
                const snapshot = self.view.findState(page_id) catch |err| return self.fail(err);
                if (snapshot.matches != @as(?i32, 2) or snapshot.active_index != @as(?i32, 1)) return self.fail(error.WrongFindState);
                self.phase = .find_next;
                self.view.findNext(page_id) catch |err| self.fail(err);
            },
            .find_next => {
                self.phase = .find_previous;
                self.view.findPrevious(page_id) catch |err| self.fail(err);
            },
            .find_previous => {
                self.view.stopFind() catch |err| return self.fail(err);
                self.phase = .capture;
                _ = self.view.capturePreview(page_id, .{ .timeout_ms = 5000 }, self.completion(.capture)) catch |err| self.fail(err);
            },
            .pdf => {
                _ = self.view.printToPdf(page_id, .{ .path = self.pdf_path, .accept_overwrite = true, .first_page = 1, .last_page = 1 }, .{ .timeout_ms = 5000 }, self.completion(.pdf)) catch |err| self.fail(err);
            },
            .clear => {
                _ = self.view.clearBrowsingData(.entire_profile, .{ .timeout_ms = 5000 }, self.completion(.clear)) catch |err| self.fail(err);
            },
            else => self.fail(error.InvalidPhase),
        }
    }
};

const PdfFile = struct {
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    private: *std.testing.TmpDir,
    path: ?[]u8 = null,
    profile: ?[]u8 = null,
    mode: enum { prepare, verify, cleanup } = .prepare,
    bytes: usize = 0,
    err: ?anyerror = null,
    processes: [8]?*anyopaque = @splat(null),
    process_count: usize = 0,
    runtime_started: bool = false,
    waited: bool = false,
    runtime_safe: bool = false,
    private_closed: bool = false,
    fn captureBrowser(self: *PdfFile, view: *web.View) !void {
        if (self.process_count == self.processes.len) return error.TooManyBrowserEpochs;
        var pid: c_uint = 0;
        if (zwv_browser_process_id(view.native.?, &pid) < 0 or pid == 0) return error.BrowserPidUnavailable;
        self.processes[self.process_count] = w.OpenProcess(w.SYNCHRONIZE, w.FALSE, pid) orelse return error.BrowserWaitHandleUnavailable;
        self.process_count += 1;
    }
    fn waitForBrowsers(self: *PdfFile) !void {
        if (self.waited) return if (self.runtime_safe) {} else error.BrowserShutdownUnconfirmed;
        self.waited = true;
        defer for (&self.processes) |*process| if (process.*) |handle| {
            _ = w.CloseHandle(handle);
            process.* = null;
        };
        if (self.runtime_started and self.process_count == 0) return error.BrowserShutdownUnconfirmed;
        const deadline = w.GetTickCount64() + 10_000;
        for (self.processes[0..self.process_count]) |process| {
            const now = w.GetTickCount64();
            const remaining: u32 = @intCast(if (deadline > now) deadline - now else 0);
            const result = w.WaitForSingleObject(process.?, remaining);
            if (result != w.WAIT_OBJECT_0) {
                std.debug.print("private browser shutdown wait result=0x{x} last_error={d}\n", .{ result, if (result == w.WAIT_FAILED) w.GetLastError() else 0 });
                return error.BrowserShutdownUnconfirmed;
            }
        }
        self.runtime_safe = true;
    }
    fn run(self: *PdfFile) void {
        self.work() catch |err| {
            self.err = err;
        };
    }
    fn work(self: *PdfFile) !void {
        if (self.mode == .prepare) {
            try self.directory.makeDir("profile");
            self.profile = try self.directory.realpathAlloc(self.allocator, "profile");
            const file = try self.directory.createFile("私有输出.pdf", .{});
            defer file.close();
            try file.writeAll("reserved private output");
            self.path = try self.directory.realpathAlloc(self.allocator, "私有输出.pdf");
        } else if (self.mode == .verify) {
            try self.waitForBrowsers();
            const bytes = try self.directory.readFileAlloc(self.allocator, "私有输出.pdf", 16 * 1024 * 1024);
            defer self.allocator.free(bytes);
            try std.testing.expect(std.mem.startsWith(u8, bytes, "%PDF-") and std.mem.indexOf(u8, bytes, "/Type /Page") != null and std.mem.indexOf(u8, bytes, "%%EOF") != null);
            self.bytes = bytes.len;
        } else {
            self.waitForBrowsers() catch |err| {
                self.directory.close();
                self.private.parent_dir.close();
                self.private_closed = true;
                std.debug.print("private profile retained because shutdown is unconfirmed: {?s}\n", .{self.profile});
                return err;
            };
            self.directory.close();
            self.private_closed = true;
            defer self.private.parent_dir.close();
            try self.private.parent_dir.deleteTree(&self.private.sub_path);
        }
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var private = std.testing.tmpDir(.{});
    var pdf: PdfFile = .{ .allocator = allocator, .directory = private.dir, .private = &private };
    defer {
        if (!pdf.private_closed) {
            pdf.mode = .cleanup;
            pdf.err = null;
            const cleanup_worker = std.Thread.spawn(.{}, PdfFile.run, .{&pdf}) catch @panic("unable to start fixture cleanup worker");
            cleanup_worker.join();
            if (pdf.err) |err| std.debug.print("fixture cleanup failed: {s}\n", .{@errorName(err)});
        }
        if (pdf.path) |path| allocator.free(path);
        if (pdf.profile) |profile| allocator.free(profile);
    }
    var worker = try std.Thread.spawn(.{}, PdfFile.run, .{&pdf});
    worker.join();
    if (pdf.err) |err| return err;
    const bind = try std.net.Address.parseIp4("127.0.0.1", 0);
    var allowed: Server = .{ .listener = try bind.listen(.{}), .start_html = "<body>needle needle other NEEDLE<script>localStorage.setItem('fixture','private');document.cookie='visible=1;path=/;SameSite=Lax'</script></body>" };
    defer allowed.stop();
    var other: Server = .{ .listener = try bind.listen(.{}) };
    defer other.stop();
    try allowed.start();
    try other.start();
    const origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{allowed.listener.listen_address.getPort()});
    defer allocator.free(origin);
    const other_origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{other.listener.listen_address.getPort()});
    defer allocator.free(other_origin);
    const url = try std.fmt.allocPrint(allocator, "{s}/start", .{origin});
    defer allocator.free(url);
    const other_url = try std.fmt.allocPrint(allocator, "{s}/start", .{other_origin});
    defer allocator.free(other_url);
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var view: web.View = undefined;
        var state: State = .{ .app = app, .view = &view, .profile = pdf.profile.?, .fixture = &pdf, .url = url, .other_url = other_url, .pdf_path = pdf.path.?, .origins = .{ .{ .origin = origin }, .{ .origin = other_origin } } };
        defer state.closeCookieTimer();
        for (&state.cases, 0..) |*case, i| case.* = .{ .state = &state, .kind = @enumFromInt(i) };
        view = web.View.init(allocator, &state, State.event);
        const window = try app.createWindow(.{});
        try view.attach(window, state.options());
        pdf.runtime_started = true;
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        if (watchdog.expired) std.debug.print("tools timeout phase={s} calls={any} toolrefs={any} COM={any}\n", .{ @tagName(state.phase), state.calls, web.toolResourceCounts(), web.resourceCounts() });
        const refs = web.resourceCounts();
        const tool_refs = web.toolResourceCounts();
        std.debug.print("browser tool refs COM={any} tools={any} png={d} cookie_set_checks={d} cookie_delete_checks={d}\n", .{ refs, tool_refs, state.png_bytes, state.cookie_set_checks, state.cookie_delete_checks });
        try std.testing.expect(!watchdog.expired and state.failed == null and state.done);
        for (state.calls[0..10]) |count| try std.testing.expectEqual(@as(u32, 1), count);
        try std.testing.expectEqual(@as(u32, 0), state.calls[10]);
        try std.testing.expectEqual(@as(u32, 1), state.script_detached);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        try std.testing.expect(state.cookie_watch == null and state.cookie_timer == null);
        try std.testing.expectEqual(@as(u32, 0), refs.states + refs.handlers + refs.controllers + tool_refs.streams + tool_refs.pending);
    }
    pdf.mode = .verify;
    worker = try std.Thread.spawn(.{}, PdfFile.run, .{&pdf});
    worker.join();
    if (pdf.err) |err| return err;
    try std.testing.expectEqual(@as(u32, 0), other.requests.load(.acquire));
    pdf.mode = .cleanup;
    worker = try std.Thread.spawn(.{}, PdfFile.run, .{&pdf});
    worker.join();
    if (pdf.err) |err| return err;
    std.debug.print("browser tools smoke passed: cookie scope/HttpOnly/delete/profile clear, hidden find, bounded PNG, async private PDF={d}, cancel/close/native capacity; COM/streams=0\n", .{pdf.bytes});
}
