const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const process = @import("linux_webview_process.zig");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zfind_test_observer_new(*anyopaque, *anyopaque, *const fn (*anyopaque, c_int, u32) callconv(.c) void) ?*anyopaque;
extern fn zfind_test_observer_release(*anyopaque) void;
extern fn zfind_test_observers() u32;
extern fn zwk_find_counts(*u32, *u32, *u32, *usize, *usize) void;
extern fn gtk_widget_destroy(*anyopaque) void;
const source = "<!doctype html><meta charset=utf-8><body>needle needle NEEDLE café café</body>";
const Counts = struct { budgets: u32 = 0, gates: u32 = 0, commands: u32 = 0, bytes: usize = 0, peak: usize = 0 };
fn counts() Counts {
    var value: Counts = .{};
    zwk_find_counts(&value.budgets, &value.gates, &value.commands, &value.bytes, &value.peak);
    return value;
}
const Mode = enum { denied, ordered, cancel, timeout, refresh, reload, recover, close, rawclose, quit };
const RecoveryTrace = enum { pending, sdk_zero_first, process_failure_first };
const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    mode: Mode,
    failure: ?anyerror = null,
    observer: ?*anyopaque = null,
    old: ?web.PageId = null,
    budget: ?*anyopaque = null,
    loaded: u32 = 0,
    completed: u32 = 0,
    changed: u32 = 0,
    observed: u32 = 0,
    process_failures: u32 = 0,
    recovery_trace: RecoveryTrace = .pending,
    old_sdk_signals: u32 = 0,
    closed: u32 = 0,
    stage: u32 = 0,
    queued: bool = false,
    fn options(self: *State) web.Options {
        return .{ .html = source, .storage = .ephemeral, .tools = .{ .find = self.mode != .denied }, .tool_limits = .{ .max_pending = 2 }, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Linux Find {s} stage={d} loaded={d} complete={d} changed={d} SDK signals={d}: {s}\n", .{ @tagName(self.mode), self.stage, self.loaded, self.completed, self.changed, self.observed, @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.mode == .recover) std.debug.print("Linux Find recover observe event={s} active={} loading={} recovering={} generation={d}\n", .{ @tagName(std.meta.activeTag(value)), view.page_active, view.loading, view.recovering, view.page_generation });
        switch (value) {
            .failed => self.fail(error.NativeFailed),
            .process_failed => {
                if (self.mode != .recover) return self.fail(error.UnexpectedProcessFailure);
                if (self.process_failures != 0 or self.recovery_trace == .pending or self.completed != 1 or view.page_active or view.recovering or !view.failed) return self.fail(error.WrongProcessFailureOrder);
                if (self.recovery_trace == .sdk_zero_first and self.old_sdk_signals != 1) return self.fail(error.MissingOldSdkSignal);
                self.process_failures += 1;
                self.releaseObserver();
                view.recover() catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn releaseObserver(self: *State) void {
        const old = self.observer;
        self.observer = null;
        if (old) |value| zfind_test_observer_release(value);
    }
    fn observe(self: *State) !void {
        self.observer = zfind_test_observer_new(try process.ownedWidget(self.window), self, sdkSignal) orelse return error.ObserverFailed;
    }
    fn sdkSignal(ptr: *anyopaque, found: c_int, count: u32) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.observed += 1;
        if (self.mode == .recover) {
            if (self.loaded == 1) {
                self.old_sdk_signals += 1;
                if (self.old_sdk_signals != 1 or found != 0 or count != 0) return self.fail(error.WrongTerminatedSdkSignal);
            } else if (self.loaded != 2 or self.process_failures != 1 or found == 0 or count != 2) return self.fail(error.WrongRecoveredSdkSignal);
        }
        std.debug.print("Linux Find {s}: actual SDK signal found={d} count={d}\n", .{ @tagName(self.mode), found, count });
        // A single queued task runs only after the signal's entire stack exits.
        // This does not poll a counter or invent an SDK command identity.
        if ((self.mode == .cancel or self.mode == .timeout) and self.completed == 1) self.queue();
        if (self.mode == .refresh and self.loaded == 2) self.queue();
    }
    fn completion(self: *State) web.tools.Completion {
        return .{ .context = self, .complete = complete };
    }
    fn submit(self: *State, term: []const u8, sensitive: bool, timeout: ?u32) !web.ToolOperation {
        return self.view.startFind(self.view.pageId().?, .{ .term = term, .case_sensitive = sensitive, .listener = .{ .context = self, .changed = findChanged } }, .{ .timeout_ms = timeout }, self.completion());
    }
    fn ignoreScript(_: *anyopaque, _: web.ScriptResult) void {}
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.mode == .recover) std.debug.print("Linux Find recover observe page={s} active={} loading={} recovering={} generation={d}\n", .{ @tagName(std.meta.activeTag(value)), view.page_active, view.loading, view.recovering, view.page_generation });
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.LoadFailed);
        self.loaded += 1;
        if (self.loaded == 1) {
            self.old = view.pageId();
            if (counts().budgets != 0 or view.find_budget != null) return self.fail(error.DefaultAllocated);
            const unreadable: [*]const u8 = @ptrFromInt(4096);
            if (self.mode == .denied) {
                std.testing.expectError(error.ToolDenied, view.startFind(view.pageId().?, .{ .term = unreadable[0..1] }, .{}, self.completion())) catch |err| return self.fail(err);
                if (counts().bytes != 0) return self.fail(error.DeniedAllocated);
                return self.app.quit();
            }
            std.testing.expectError(error.UnsupportedCapability, view.startFind(view.pageId().?, .{ .term = unreadable[0..1], .whole_word = true }, .{}, self.completion())) catch |err| return self.fail(err);
            std.testing.expectError(error.UnsupportedCapability, view.startFind(view.pageId().?, .{ .term = unreadable[0..1], .highlight_all = false }, .{}, self.completion())) catch |err| return self.fail(err);
            if (counts().bytes != 0) return self.fail(error.UnsupportedAllocated);
            self.observe() catch |err| return self.fail(err);
            if (self.mode == .timeout) {
                _ = view.evaluateJS("(()=>{const end=Date.now()+200;while(Date.now()<end){};return 1})()", .{}, .{ .context = self, .complete = ignoreScript }) catch |err| return self.fail(err);
            }
            const operation = self.submit("needle", true, if (self.mode == .timeout) 1 else null) catch |err| return self.fail(err);
            self.budget = view.find_budget;
            std.testing.expectError(error.Full, self.submit("other", true, null)) catch |err| return self.fail(err);
            switch (self.mode) {
                .cancel => {
                    std.testing.expect(operation.cancel() catch false) catch |err| return self.fail(err);
                    std.testing.expectError(error.Full, self.submit("other", true, null)) catch |err| return self.fail(err);
                },
                .refresh => view.refresh() catch |err| self.fail(err),
                .reload => {
                    self.releaseObserver();
                    view.reload(self.options()) catch |err| self.fail(err);
                },
                .recover => {
                    // Keep an independent old controller reference through its
                    // actual failed-to-find-text, then require process_failed.
                    process.stop(self.window) catch |err| self.fail(err);
                },
                .close => {
                    _ = self.window.destroy() catch |err| return self.fail(err);
                    self.app.quit();
                },
                .rawclose => {
                    gtk_widget_destroy(self.window.nativeHandle().?);
                    self.app.quit();
                },
                .quit => self.app.quit(),
                else => {},
            }
        } else {
            if (self.loaded != 2 or (self.mode != .refresh and self.mode != .reload and self.mode != .recover)) return self.fail(error.DuplicateLoad);
            if (self.mode == .recover and (self.process_failures != 1 or self.recovery_trace == .pending or self.completed != 1)) return self.fail(error.RecoveryBeforeProcessFailure);
            if (view.find_budget != self.budget) return self.fail(error.DomainChanged);
            std.testing.expectError(error.StalePage, view.startFind(self.old.?, .{ .term = "needle" }, .{}, self.completion())) catch |err| return self.fail(err);
            if (self.mode != .refresh) self.observe() catch |err| return self.fail(err);
            if (self.mode != .refresh or self.observed != 0) self.queue();
        }
    }
    fn queue(self: *State) void {
        if (self.queued or self.failure != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn complete(ptr: *anyopaque, result: web.tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.mode == .recover) {
            std.debug.print("Linux Find recover observe completion={s} active={} loading={} recovering={} generation={d}\n", .{ @tagName(std.meta.activeTag(result)), self.view.page_active, self.view.loading, self.view.recovering, self.view.page_generation });
            if (result == .find) std.debug.print("Linux Find recover observe native snapshot={any}\n", .{result.find});
        }
        self.completed += 1;
        if (self.mode != .ordered and self.completed == 1) switch (self.mode) {
            .cancel => {
                if (result != .cancelled) return self.fail(error.ExpectedCancelled);
                return;
            },
            .timeout => {
                if (result != .timed_out) return self.fail(error.ExpectedTimeout);
                std.testing.expectError(error.FindInactive, self.view.findState(self.view.pageId().?)) catch |err| return self.fail(err);
                std.testing.expectError(error.Full, self.submit("other", true, null)) catch |err| return self.fail(err);
                return;
            },
            .refresh, .reload => {
                if (result != .page_changed) self.fail(error.ExpectedPageChanged);
                return;
            },
            .recover => {
                if (self.recovery_trace != .pending or self.process_failures != 0 or self.view.loading or self.view.recovering) return self.fail(error.WrongOldFindOrder);
                // SDK reply and process termination are independent. The first
                // trace requires actual SDK zero while the page is still live.
                // The second requires Root's exact process-revocation result
                // after page invalidation. Neither is a recovery success.
                if (result == .find) {
                    if (result.find.matches != @as(?i32, 0) or result.find.active_index != null or self.old_sdk_signals != 1 or !self.view.page_active or self.view.failed) return self.fail(error.ExpectedOldFindZeroBeforeProcessFailure);
                    self.recovery_trace = .sdk_zero_first;
                } else if (result == .unavailable) {
                    if (self.view.page_active or !self.view.failed) return self.fail(error.ExpectedProcessRevocation);
                    self.recovery_trace = .process_failure_first;
                } else return self.fail(error.ExpectedExactRecoveryTrace);
                std.debug.print("Linux Find recover actual trace={s} old SDK signals={d}\n", .{ @tagName(self.recovery_trace), self.old_sdk_signals });
                return;
            },
            .close, .rawclose, .quit => {
                if (result != .detached) self.fail(error.ExpectedDetached);
                return;
            },
            else => {},
        };
        if (result != .find) return self.fail(error.ExpectedFind);
        const expected: i32 = if (self.mode == .ordered) switch (self.stage) {
            0 => 2,
            3 => 3,
            4 => 2,
            5 => 0,
            else => return self.fail(error.UnexpectedCompletion),
        } else 2;
        if (result.find.matches != @as(?i32, expected) or result.find.active_index != null) return self.fail(error.WrongKnownState);
        self.stage += 1;
        self.queue();
    }
    fn findChanged(ptr: *anyopaque, snapshot: web.tools.FindState) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.changed += 1;
        if (self.mode != .ordered or (self.stage != 1 and self.stage != 2)) return self.fail(error.UnexpectedListener);
        if (snapshot.matches != null or snapshot.active_index != null) return self.fail(error.StepClaimedTotalOrIndex);
        self.stage += 1;
        self.queue();
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.failure != null) return;
        // Terminal counters must be checked after the actual signal stack,
        // independently of the already-withdrawn logical Book completion.
        if (counts().commands != 0) return self.fail(error.PhysicalCommandNotRetired);
        if (self.mode == .ordered) {
            const id = self.view.pageId().?;
            switch (self.stage) {
                1 => {
                    const snapshot = self.view.findState(id) catch |err| return self.fail(err);
                    if (snapshot.matches != @as(?i32, 2) or snapshot.active_index != null) return self.fail(error.WrongCachedState);
                    self.view.findNext(id) catch |err| return self.fail(err);
                    const pending = self.view.findState(id) catch |err| return self.fail(err);
                    if (pending.matches != null or pending.active_index != null) return self.fail(error.StepKeptOldTotal);
                    std.testing.expectError(error.Full, self.view.findPrevious(id)) catch |err| return self.fail(err);
                },
                2 => self.view.findPrevious(id) catch |err| self.fail(err),
                3 => {
                    _ = self.submit("needle", false, null) catch |err| self.fail(err);
                },
                4 => {
                    _ = self.submit("café", true, null) catch |err| self.fail(err);
                },
                5 => {
                    _ = self.submit("absent", true, null) catch |err| self.fail(err);
                },
                6 => {
                    self.view.stopFind() catch |err| return self.fail(err);
                    std.testing.expectError(error.FindInactive, self.view.findState(id)) catch |err| return self.fail(err);
                    self.app.quit();
                },
                else => self.fail(error.InvalidStage),
            }
        } else if (self.completed == 1) {
            _ = self.submit("needle", true, null) catch |err| self.fail(err);
        } else self.app.quit();
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        std.debug.assert(self.view.find_budget == null);
        self.releaseObserver();
    }
};
fn run(allocator: std.mem.Allocator, mode: Mode) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .mode = mode };
    state.view = web.View.init(allocator, &state, State.event);
    state.window = try app.createWindow(.{ .width = 200, .height = 100, .on_closed = .{ .context = &state, .notify = State.onClosed } });
    defer _ = state.window.destroy() catch unreachable;
    defer state.releaseObserver();
    try state.view.attach(state.window, state.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    const expected: u32 = switch (mode) {
        .denied => 0,
        .ordered => 4,
        .cancel, .timeout, .refresh, .reload, .recover => 2,
        else => 1,
    };
    try std.testing.expect(!watchdog.expired and state.closed == 1 and state.completed == expected);
    if (mode == .ordered) try std.testing.expect(state.changed == 2 and state.observed == 6);
    if (mode == .cancel or mode == .timeout) try std.testing.expect(state.observed == 2 and state.changed == 0);
    if (mode == .recover) try std.testing.expect(state.recovery_trace != .pending and state.process_failures == 1 and state.observed == state.old_sdk_signals + 1 and state.changed == 0 and state.loaded == 2);
    const native = web.resourceCounts();
    const physical = counts();
    std.debug.print("Linux Find {s}: once={d}, listener={d}, SDK={d}, remaining native={d}/{d}/{d} find={d}/{d}/{d}/{d}, peak={d}\n", .{ @tagName(mode), state.completed, state.changed, state.observed, native.states, native.handlers, native.controllers, physical.budgets, physical.gates, physical.commands, physical.bytes, physical.peak });
    try std.testing.expect(native.states == 0 and native.handlers == 0 and native.controllers == 0 and physical.budgets == 0 and physical.gates == 0 and physical.commands == 0 and physical.bytes == 0 and zfind_test_observers() == 0);
}
pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    try std.testing.expect(web.backendCapabilities().find_text and !web.backendCapabilities().browser_tools);
    const options = web.findCapabilities();
    try std.testing.expect(!options.whole_word and !options.highlight_control and !options.total_count_on_step and !options.active_index);
    var args = init.args.iterate();
    _ = args.next();
    const selected = args.next() orelse return error.ExpectedMode;
    const mode = std.meta.stringToEnum(Mode, selected) orelse return error.InvalidMode;
    if (args.next() != null) return error.TooManyArguments;
    try run(allocator, mode);
}
