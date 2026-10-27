const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @import("ziggurat_c_win32");
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
const Kind = enum { normal, large, oom, timeout, cancel, reload, after_reload, reentrant, detached, fill };
const Case = struct {
    state: *State,
    kind: Kind,
    fn complete(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        self.state.completed(self.kind, result);
    }
};
fn runSingleSlotChain(allocator: std.mem.Allocator, profile: []const u8) !void {
    const Probe = struct {
        app: *z.App,
        view: *web.View,
        calls: u32 = 0,
        done: bool = false,
        err: ?anyerror = null,
        fn fail(self: *@This(), err: anyerror) void {
            self.err = err;
            std.debug.print("single script slot chain: {s}\n", .{@errorName(err)});
            self.app.quit();
        }
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {}
        fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (value == .completed and value.completed.success) _ = view.evaluateJS("'first'", .{}, .{ .context = self, .complete = complete }) catch |err| self.fail(err);
        }
        fn complete(ptr: *anyopaque, result: web.ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (result != .json) return self.fail(error.MissingJson);
            if (self.calls == 1) {
                _ = self.view.evaluateJS("'second'", .{}, .{ .context = self, .complete = complete }) catch |err| return self.fail(err);
            } else if (self.calls == 2) {
                self.done = true;
                _ = self.view.window.?.destroy() catch |err| return self.fail(err);
                self.app.quit();
            } else self.fail(error.DuplicateCompletion);
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var view: web.View = undefined;
    var probe: Probe = .{ .app = app, .view = &view };
    view = web.View.init(allocator, &probe, Probe.event);
    const window = try app.createWindow(.{});
    try view.attach(window, .{ .html = "<title>single slot</title>", .user_data_folder = profile, .local = .{}, .scripts = .{ .max_pending = 1 }, .page_listener = .{ .context = &probe, .event = Probe.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and probe.err == null and probe.done and probe.calls == 2);
}
const State = struct {
    app: *z.App,
    view: *web.View,
    allocator_fault: *std.testing.FailingAllocator,
    profile: []const u8,
    cases: [10]Case = undefined,
    counts: [10]u32 = @splat(0),
    phase: enum { initial, large, oom, timeout, cancel, reload, after_reload, crash, await_recovery, reentrant, closing } = .initial,
    failed: ?anyerror = null,
    done: bool = false,
    native_full: bool = false,
    fn completion(self: *State, kind: Kind) web.ScriptCompletion {
        return .{ .context = &self.cases[@backingInt(kind)], .complete = Case.complete };
    }
    fn options(self: *State) web.Options {
        return .{ .html = "<title>script fixture</title>", .user_data_folder = self.profile, .local = .{}, .zoom = 1.25, .user_agent = "ZigguratScriptSmoke/Initial", .scripts = .{ .max_pending = 4, .max_result_bytes = 64 }, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        self.allocator_fault.fail_index = std.math.maxInt(usize);
        self.failed = err;
        std.debug.print("script smoke phase={s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed => self.fail(error.NativeFailure),
            .process_failed => {
                if (self.phase != .crash) return self.fail(error.NativeFailure);
                self.phase = .await_recovery;
                self.view.recover() catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .completed => |loaded| {
                if (!loaded.success) return self.fail(error.LoadFailed);
                if (self.phase == .initial) {
                    self.properties(false) catch |err| return self.fail(err);
                    view.setZoom(1.5) catch |err| return self.fail(err);
                    view.setUserAgent("ZigguratScriptSmoke/Changed") catch |err| return self.fail(err);
                    _ = view.evaluateJS("({n:42,text:'中文'})", .{}, self.completion(.normal)) catch |err| return self.fail(err);
                } else if (self.phase == .after_reload) {
                    self.properties(false) catch |err| return self.fail(err);
                    view.setZoom(1.75) catch |err| return self.fail(err);
                    view.setUserAgent("ZigguratScriptSmoke/Recovered") catch |err| return self.fail(err);
                    _ = view.evaluateJS("'after-reload'", .{}, self.completion(.after_reload)) catch |err| return self.fail(err);
                } else if (self.phase == .await_recovery) {
                    self.properties(true) catch |err| return self.fail(err);
                    self.phase = .reentrant;
                    _ = view.evaluateJS("navigator.userAgent", .{}, self.completion(.reentrant)) catch |err| return self.fail(err);
                }
            },
            else => {},
        }
    }
    fn properties(self: *State, recovered: bool) !void {
        try std.testing.expectEqual(@as(f64, if (recovered) 1.75 else 1.25), try self.view.zoom());
        const agent = try self.view.userAgent(self.app.allocator);
        defer self.app.allocator.free(agent);
        try std.testing.expectEqualStrings(if (recovered) "ZigguratScriptSmoke/Recovered" else "ZigguratScriptSmoke/Initial", agent);
        try std.testing.expectError(error.InvalidZoom, self.view.setZoom(std.math.nan(f64)));
        try std.testing.expectError(error.InvalidUserAgent, self.view.setUserAgent("must-not\r\ninject"));
        try std.testing.expect(!(try self.view.devToolsEnabled()));
        try std.testing.expectError(error.DevToolsDisabled, self.view.openDevTools());
        try self.view.setDevToolsEnabled(true);
        try std.testing.expect(try self.view.devToolsEnabled());
        try self.view.setDevToolsEnabled(false);
        // Never open a visible tool window in this automated hidden test.
    }
    fn queue(self: *State, phase: @FieldType(State, "phase")) void {
        self.phase = phase;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn completed(self: *State, kind: Kind, result: web.ScriptResult) void {
        self.counts[@backingInt(kind)] += 1;
        switch (kind) {
            .normal => {
                if (result != .json or std.mem.indexOf(u8, result.json, "42") == null or std.mem.indexOf(u8, result.json, "中文") == null) return self.fail(error.InvalidJson);
                self.queue(.large);
            },
            .large => {
                if (result != .result_too_large) return self.fail(error.LargeResultAccepted);
                self.queue(.oom);
            },
            .oom => {
                self.allocator_fault.fail_index = std.math.maxInt(usize);
                if (result != .out_of_memory) return self.fail(error.MissingAllocationFailure);
                self.queue(.timeout);
            },
            .timeout => {
                if (result != .timed_out) return self.fail(error.MissingTimeout);
                self.queue(.cancel);
            },
            .cancel => {
                if (result != .cancelled) return self.fail(error.MissingCancellation);
            },
            .reload => {
                if (result != .page_changed) return self.fail(error.ReloadDidNotCancel);
                _ = self.view.evaluateJS("'must-not-submit'", .{}, self.completion(.fill)) catch |err| {
                    if (err != error.NotReady) return self.fail(err);
                    return;
                };
                self.fail(error.RecoveryAcceptedScript);
            },
            .after_reload => {
                if (result != .json or !std.mem.eql(u8, result.json, "\"after-reload\"")) return self.fail(error.InvalidJson);
                self.queue(.crash);
            },
            .reentrant => {
                if (result != .json or !std.mem.eql(u8, result.json, "\"ZigguratScriptSmoke/Recovered\"")) return self.fail(error.InvalidJson);
                _ = self.view.evaluateJS("'pending-at-close'", .{}, self.completion(.detached)) catch |err| return self.fail(err);
                for (0..20) |_| {
                    const handle = self.view.evaluateJS("1+1", .{}, self.completion(.fill)) catch |err| {
                        if (err != error.Full) return self.fail(err);
                        self.native_full = true;
                        break;
                    };
                    if (!(handle.cancel() catch |err| return self.fail(err))) return self.fail(error.CancelLost);
                }
                if (!self.native_full) return self.fail(error.UnboundedNativeHandlers);
                self.phase = .closing;
                const result_close = self.view.window.?.destroy() catch |err| return self.fail(err);
                if (result_close != .deferred or self.view.window == null) return self.fail(error.CloseNotPinned);
                self.app.quit();
            },
            .detached => {
                if (result != .detached) return self.fail(error.CloseDidNotCancel);
                self.done = true;
            },
            .fill => if (result != .cancelled) {
                self.fail(error.CancelledHandlerReentered);
            },
        }
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (self.phase) {
            .large => {
                _ = self.view.evaluateJS("'x'.repeat(100)", .{}, self.completion(.large)) catch |err| self.fail(err);
            },
            .oom => {
                _ = self.view.evaluateJS("'allocation probe'", .{}, self.completion(.oom)) catch |err| return self.fail(err);
                self.allocator_fault.fail_index = self.allocator_fault.alloc_index;
            },
            .timeout => {
                _ = self.view.evaluateJS("{const end=Date.now()+500;while(Date.now()<end){};42}", .{ .timeout_ms = 5 }, self.completion(.timeout)) catch |err| self.fail(err);
            },
            .cancel => {
                const handle = self.view.evaluateJS("'cancelled'", .{}, self.completion(.cancel)) catch |err| return self.fail(err);
                if (!(handle.cancel() catch |err| return self.fail(err))) return self.fail(error.CancelLost);
                if (handle.cancel() catch |err| return self.fail(err)) return self.fail(error.CancelRepeated);
                self.queue(.reload);
            },
            .reload => {
                _ = self.view.evaluateJS("'old page'", .{}, self.completion(.reload)) catch |err| return self.fail(err);
                self.phase = .after_reload;
                self.view.reload(self.options()) catch |err| self.fail(err);
            },
            .crash => {
                var pid: c_uint = 0;
                if (zwv_browser_process_id(self.view.native.?, &pid) < 0 or pid == 0) return self.fail(error.BrowserPidUnavailable);
                // This process belongs to this test's controller/private profile.
                const process = c.OpenProcess(c.PROCESS_TERMINATE, c.FALSE, pid) orelse return self.fail(error.OpenProcessFailed);
                defer _ = c.CloseHandle(process);
                if (c.TerminateProcess(process, 0x7f) == 0) self.fail(error.TerminateProcessFailed);
            },
            else => self.fail(error.InvalidPhase),
        }
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "ScriptSmoke" });
    defer allocator.free(profile);
    try runSingleSlotChain(allocator, profile);
    const app = try z.App.init(allocator);
    defer app.deinit();
    var fault = std.testing.FailingAllocator.init(allocator, .{});
    var view: web.View = undefined;
    var state: State = .{ .app = app, .view = &view, .profile = profile, .allocator_fault = &fault };
    for (&state.cases, 0..) |*case, i| case.* = .{ .state = &state, .kind = @fromBackingInt(@intCast(i)) };
    view = web.View.init(fault.allocator(), &state, State.event);
    const window = try app.createWindow(.{});
    try view.attach(window, state.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and state.failed == null and state.done and state.native_full);
    for (state.counts[0..9]) |count| try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(fault.allocated_bytes, fault.freed_bytes);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    const counts = web.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.states);
    try std.testing.expectEqual(@as(u32, 0), counts.handlers);
    try std.testing.expectEqual(@as(u32, 0), counts.controllers);
    std.debug.print("script smoke passed: JSON/OOM/limits, native timer timeout, cancel/reload/reentry/close, bounded handlers, zoom/UA/devtools settings and crash recovery; COM=0\n", .{});
}
