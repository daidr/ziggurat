const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zcap_test_check_png([*]const u8, usize, u32, u32) c_int;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn zwk_capture_counts(*u32, *u32, *usize, *usize) void;
const source =
    \\<!doctype html><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#204060}div{position:absolute;left:50%;top:0;width:50%;height:100%;background:#e08020}</style><div></div>
;
const Counts = struct { budgets: u32 = 0, operations: u32 = 0, bytes: usize = 0, peak: usize = 0 };
fn counts() Counts {
    var out: Counts = .{};
    zwk_capture_counts(&out.budgets, &out.operations, &out.bytes, &out.peak);
    return out;
}
fn checkPng(window: z.Window, bytes: []const u8) !void {
    // A hidden GtkWindow client allocation remains 1x1. WebKit has the
    // explicitly configured 96x64 GTK logical viewport at the real scale.
    const scale: u32 = @intCast(gtk_widget_get_scale_factor(window.nativeHandle().?));
    const code = zcap_test_check_png(bytes.ptr, bytes.len, 96 * scale, 64 * scale);
    if (code != 0) {
        std.debug.print("Capture PNG oracle={d} expected={d}x{d} scale={d} bytes={d}\n", .{ code, 96 * scale, 64 * scale, scale, bytes.len });
        return error.WrongPNG;
    }
}
const Mode = enum { denied, success, cancel, timeout, limit, refresh, reload, recover, close, quit };
const State = struct {
    app: *z.App,
    window: z.Window,
    mode: Mode,
    view: web.View = undefined,
    failure: ?anyerror = null,
    completed: usize = 0,
    loaded: usize = 0,
    detached: usize = 0,
    timer: c_uint = 0,
    old: ?web.PageId = null,
    budget: ?*anyopaque = null,
    fn options(self: *State) web.Options {
        return .{ .html = source, .storage = .ephemeral, .tools = .{ .capture = self.mode != .denied }, .tool_limits = .{ .max_pending = 1, .max_capture_bytes = if (self.mode == .limit) 8 else 4096 }, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Linux capturePreview {s}: {s}\n", .{ @tagName(self.mode), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, input: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (input) {
            .process_failed => {
                if (self.mode != .recover) return self.fail(error.NativePageFailed);
                view.recover() catch |err| self.fail(err);
            },
            .failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn submit(self: *State, timeout: ?u32) !web.ToolOperation {
        return self.view.capturePreview(self.view.pageId().?, .{ .timeout_ms = timeout }, .{ .context = self, .complete = capture });
    }
    fn ignoreScript(_: *anyopaque, _: web.ScriptResult) void {}
    fn page(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (input != .completed) return;
        if (!input.completed.success) return self.fail(error.LoadFailed);
        self.loaded += 1;
        if (self.loaded == 1) {
            self.old = view.pageId();
            self.budget = view.capture_budget;
            if (self.mode == .denied) {
                std.testing.expect(self.budget == null and counts().budgets == 0 and counts().operations == 0) catch |err| return self.fail(err);
                std.testing.expectError(error.ToolDenied, self.submit(null)) catch |err| return self.fail(err);
                std.testing.expectError(error.ToolDenied, view.startFind(view.pageId().?, .{ .term = "x" }, .{}, .{ .context = self, .complete = capture })) catch |err| return self.fail(err);
                if (counts().bytes != 0) return self.fail(error.DefaultCaptureAllocated);
                return self.app.quit();
            }
            if (self.mode == .timeout or self.mode == .refresh or self.mode == .reload or self.mode == .recover) {
                _ = view.evaluateJS("(()=>{const end=Date.now()+120;while(Date.now()<end){};return 7})()", .{}, .{ .context = self, .complete = ignoreScript }) catch |err| return self.fail(err);
            }
            const operation = self.submit(if (self.mode == .timeout) 1 else null) catch |err| return self.fail(err);
            switch (self.mode) {
                .cancel => {
                    std.testing.expect(operation.cancel() catch false) catch |err| return self.fail(err);
                    std.testing.expectError(error.Full, self.submit(null)) catch |err| return self.fail(err);
                    self.timer = g_timeout_add(1, afterPhysical, self);
                },
                .refresh => view.refresh() catch |err| self.fail(err),
                .reload => view.reload(self.options()) catch |err| self.fail(err),
                .recover => @import("linux_webview_process.zig").stop(self.window) catch |err| self.fail(err),
                .close => {
                    _ = self.window.destroy() catch |err| return self.fail(err);
                    self.app.quit();
                },
                .quit => self.app.quit(),
                else => {},
            }
        } else {
            if (self.loaded != 2 or (self.mode != .refresh and self.mode != .reload and self.mode != .recover)) return self.fail(error.DuplicateLoad);
            if (view.capture_budget != self.budget) return self.fail(error.RecoveryResetPhysicalBudget);
            std.testing.expectError(error.StalePage, view.capturePreview(self.old.?, .{}, .{ .context = self, .complete = capture })) catch |err| return self.fail(err);
            _ = self.submit(null) catch |err| self.fail(err);
        }
    }
    fn afterPhysical(ptr: *anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (counts().operations != 0) return 1;
        self.timer = 0;
        _ = self.submit(null) catch |err| self.fail(err);
        return 0;
    }
    fn capture(ptr: *anyopaque, result: web.tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.completed += 1;
        if (self.completed == 1) switch (self.mode) {
            .cancel => {
                if (result != .cancelled) self.fail(error.MissingCancelled);
                return;
            },
            .timeout => {
                if (result != .timed_out) return self.fail(error.MissingTimeout);
                std.testing.expectError(error.Full, self.submit(null)) catch |err| return self.fail(err);
                return self.app.quit();
            },
            .limit => {
                if (result != .limit_exceeded) return self.fail(error.MissingPngLimit);
                return self.app.quit();
            },
            .refresh, .reload => {
                if (result != .page_changed) self.fail(error.MissingPageChanged);
                return;
            },
            .recover => {
                if (result != .unavailable and result != .native_failure) self.fail(error.MissingProcessRevocation);
                return;
            },
            .close, .quit => {
                if (result != .detached) self.fail(error.MissingDetached);
                return;
            },
            else => {},
        };
        if (result != .png) return self.fail(error.MissingPNG);
        checkPng(self.window, result.png) catch |err| return self.fail(err);
        if (self.mode == .success and self.completed == 1) {
            // The Book slot is free, but GTask still physically owns this Op.
            std.testing.expectError(error.Full, self.submit(null)) catch |err| return self.fail(err);
            self.timer = g_timeout_add(1, afterPhysical, self);
            return;
        }
        self.app.quit();
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.detached += 1;
        std.debug.assert(self.view.capture_budget == null);
    }
};
fn run(allocator: std.mem.Allocator, mode: Mode) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .window = undefined, .mode = mode };
    state.view = web.View.init(allocator, &state, State.event);
    state.window = try app.createWindow(.{ .width = 96, .height = 64, .on_closed = .{ .context = &state, .notify = State.closed } });
    defer _ = state.window.destroy() catch unreachable;
    defer if (state.timer != 0) {
        _ = g_source_remove(state.timer);
    };
    // Only explicit hidden test windows; no browser, images or file output.
    try state.view.attach(state.window, state.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    const expected: usize = switch (mode) {
        .denied => 0,
        .success, .cancel, .refresh, .reload, .recover => 2,
        else => 1,
    };
    try std.testing.expect(!watchdog.expired and state.completed == expected and state.detached == 1);
    std.debug.print("Linux capturePreview {s}: {d} exactly-once completions\n", .{ @tagName(mode), state.completed });
}
const Drain = struct {
    app: *z.App,
    timer: c_uint = 0,
    fn tick(ptr: *anyopaque) callconv(.c) c_int {
        const self: *Drain = @ptrCast(@alignCast(ptr));
        const native = web.resourceCounts();
        const capture = counts();
        if (native.states != 0 or native.handlers != 0 or native.controllers != 0 or capture.budgets != 0 or capture.operations != 0 or capture.bytes != 0) return 1;
        self.timer = 0;
        self.app.quit();
        return 0;
    }
};
fn drain(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const keepalive = try app.createWindow(.{});
    defer _ = keepalive.destroy() catch unreachable;
    var state: Drain = .{ .app = app };
    state.timer = g_timeout_add(1, Drain.tick, &state);
    defer if (state.timer != 0) {
        _ = g_source_remove(state.timer);
    };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and state.timer == 0);
}
fn attachFailure(view_allocator: std.mem.Allocator, core_allocator: std.mem.Allocator) !void {
    const app = try z.App.init(core_allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var marker: u8 = 0;
    var view = web.View.init(view_allocator, &marker, struct {
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {
            @panic("late callback after capture construction rollback");
        }
    }.event);
    view.attach(window, .{ .html = source, .storage = .ephemeral, .tools = .{ .capture = true }, .user_agent = "owned capture metadata" }) catch |err| {
        try std.testing.expect(view.window == null and view.native == null and view.capture_budget == null);
        return err;
    };
    _ = try window.destroy();
    try std.testing.expect(view.window == null and view.native == null and view.capture_budget == null);
}
fn freedOwner(allocator: std.mem.Allocator, after_png: bool) !void {
    const Owner = struct {
        allocator: std.mem.Allocator,
        app: *z.App,
        window: z.Window,
        view: web.View = undefined,
        after_png: bool,
        calls: *usize,
        closes: *usize,
        failure: *?anyerror,
        fn event(_: *anyopaque, _: *web.View, value: web.Event) void {
            std.debug.assert(value != .failed and value != .process_failed);
        }
        fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
            if (value != .completed) return;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = view.capturePreview(view.pageId().?, .{}, .{ .context = self, .complete = complete }) catch unreachable;
            if (!self.after_png) {
                const app = self.app;
                _ = self.window.destroy() catch unreachable;
                app.quit();
            }
        }
        fn complete(ptr: *anyopaque, value: web.tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            if (self.after_png) {
                if (value == .png) checkPng(self.window, value.png) catch |err| {
                    self.failure.* = err;
                } else self.failure.* = error.MissingSelfFreePNG;
                const app = self.app;
                _ = self.window.destroy() catch unreachable;
                app.quit();
            } else if (value != .detached) self.failure.* = error.MissingSelfFreeDetach;
        }
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.closes.* += 1;
            self.allocator.destroy(self);
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var calls: usize = 0;
    var closes: usize = 0;
    var failure: ?anyerror = null;
    const owner = try allocator.create(Owner);
    owner.* = .{ .allocator = allocator, .app = app, .window = undefined, .after_png = after_png, .calls = &calls, .closes = &closes, .failure = &failure };
    owner.view = web.View.init(allocator, owner, Owner.event);
    owner.window = try app.createWindow(.{ .width = 96, .height = 64, .on_closed = .{ .context = owner, .notify = Owner.closed } });
    try owner.view.attach(owner.window, .{ .html = source, .storage = .ephemeral, .tools = .{ .capture = true }, .page_listener = .{ .context = owner, .event = Owner.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (failure) |err| return err;
    try std.testing.expect(!watchdog.expired and calls == 1 and closes == 1);
    std.debug.print("Linux capturePreview immediate owner free after_png={}: exactly once\n", .{after_png});
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    try std.testing.expect(web.backendCapabilities().capture_preview and !web.backendCapabilities().browser_tools);
    try std.testing.checkAllAllocationFailures(allocator, attachFailure, .{allocator});
    try drain(allocator);
    inline for (std.meta.tags(Mode)) |mode| {
        try run(allocator, mode);
        try drain(allocator);
    }
    try freedOwner(allocator, false);
    try drain(allocator);
    try freedOwner(allocator, true);
    try drain(allocator);
    std.debug.print("Linux capturePreview: default cold/OOM, PNG dimensions/pixels, physical quota/cancel/deadline/navigation/reload/recover/close/Stop, native refs/PNG bytes=0; no visual QA\n", .{});
}
