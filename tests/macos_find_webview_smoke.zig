const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_find_counts(*u32, *u32, *u32, *usize, *usize) void;

const source = "<!doctype html><meta charset=utf-8><body>needle needle NEEDLE café café</body>";
const Counts = struct { budgets: u32 = 0, gates: u32 = 0, commands: u32 = 0, bytes: usize = 0, peak: usize = 0 };
fn counts() Counts {
    var value: Counts = .{};
    zwk_find_counts(&value.budgets, &value.gates, &value.commands, &value.bytes, &value.peak);
    return value;
}

/// Text find in order, as the Linux smoke runs it: a case-sensitive start
/// knows its total, a step knows none, then a case-insensitive start, a
/// non-ASCII term, a term with no match, and stop.
const State = struct {
    app: *z.App,
    window: z.Window,
    view: web.View = undefined,
    denied: bool,
    failure: ?anyerror = null,
    loaded: u32 = 0,
    stage: u32 = 0,
    changed: u32 = 0,
    queued: bool = false,
    fn options(self: *State) web.Options {
        return .{ .html = source, .storage = .ephemeral, .tools = .{ .find = !self.denied }, .tool_limits = .{ .max_pending = 2 }, .page_listener = .{ .context = self, .event = page } };
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("macOS find denied={} stage={d} changed={d}: {s}\n", .{ self.denied, self.stage, self.changed, @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed => self.fail(error.NativeFailed),
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
    }
    fn completion(self: *State) web.tools.Completion {
        return .{ .context = self, .complete = complete };
    }
    fn submit(self: *State, term: []const u8, sensitive: bool) !web.ToolOperation {
        return self.view.startFind(self.view.pageId().?, .{ .term = term, .case_sensitive = sensitive, .listener = .{ .context = self, .changed = findChanged } }, .{}, self.completion());
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.LoadFailed);
        self.loaded += 1;
        if (self.loaded != 1) return self.fail(error.DuplicateLoad);
        if (counts().budgets != 0) return self.fail(error.DefaultAllocated);
        if (self.denied) {
            std.testing.expectError(error.ToolDenied, view.startFind(view.pageId().?, .{ .term = "needle" }, .{}, self.completion())) catch |err| return self.fail(err);
            if (counts().bytes != 0) return self.fail(error.DeniedAllocated);
            _ = self.window.destroy() catch |err| return self.fail(err);
            return self.app.quit();
        }
        std.testing.expectError(error.UnsupportedCapability, view.startFind(view.pageId().?, .{ .term = "needle", .whole_word = true }, .{}, self.completion())) catch |err| return self.fail(err);
        std.testing.expectError(error.UnsupportedCapability, view.startFind(view.pageId().?, .{ .term = "needle", .highlight_all = false }, .{}, self.completion())) catch |err| return self.fail(err);
        _ = self.submit("needle", true) catch |err| return self.fail(err);
        std.testing.expectError(error.Full, self.submit("other", true)) catch |err| return self.fail(err);
    }
    fn queue(self: *State) void {
        if (self.queued or self.failure != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn complete(ptr: *anyopaque, result: web.tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .find) return self.fail(error.ExpectedFind);
        const expected: i32 = switch (self.stage) {
            0 => 2,
            3 => 3,
            4 => 2,
            5 => 0,
            else => return self.fail(error.UnexpectedCompletion),
        };
        std.debug.print("macOS find stage {d}: {any}\n", .{ self.stage, result.find });
        if (result.find.matches != @as(?i32, expected) or result.find.active_index != null) return self.fail(error.WrongKnownState);
        self.stage += 1;
        self.queue();
    }
    fn findChanged(ptr: *anyopaque, snapshot: web.tools.FindState) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.changed += 1;
        if (self.stage != 1 and self.stage != 2) return self.fail(error.UnexpectedListener);
        if (snapshot.matches != null or snapshot.active_index != null) return self.fail(error.StepClaimedTotalOrIndex);
        self.stage += 1;
        self.queue();
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.failure != null) return;
        if (counts().commands != 0) return self.fail(error.CommandNotRetired);
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
            3 => _ = self.submit("needle", false) catch |err| self.fail(err),
            4 => _ = self.submit("café", true) catch |err| self.fail(err),
            5 => _ = self.submit("absent", true) catch |err| self.fail(err),
            6 => {
                self.view.stopFind() catch |err| return self.fail(err);
                std.testing.expectError(error.FindInactive, self.view.findState(id)) catch |err| return self.fail(err);
                _ = self.window.destroy() catch |err| return self.fail(err);
                self.app.quit();
            },
            else => self.fail(error.InvalidStage),
        }
    }
};

fn run(allocator: std.mem.Allocator, denied: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .window = try app.createWindow(.{ .width = 320, .height = 240 }), .denied = denied };
    state.view = web.View.init(allocator, &state, State.event);
    try state.view.attach(state.window, state.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) state.fail(error.Timeout);
    if (state.failure) |err| return err;
    if (!denied and state.stage != 6) return error.Incomplete;
}

/// Engine completions of closed pages still arrive after close.
const Drain = struct {
    app: *z.App,
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const value = web.resourceCounts();
        if (value.states == 0 and value.handlers == 0 and value.controllers == 0) return self.app.quit();
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (!web.backendCapabilities().find_text) return error.SkipZigTest;
    try run(allocator.allocator(), true);
    try run(allocator.allocator(), false);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var drain: Drain = .{ .app = app };
    try app.post(.{ .context = &drain, .call = Drain.tick });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired);
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, web.resourceCounts());
    const left = counts();
    if (left.budgets != 0 or left.gates != 0 or left.commands != 0 or left.bytes != 0) {
        std.debug.print("macOS find records left: {any}\n", .{left});
        return error.FindRecordsLeft;
    }
    std.debug.print("macOS find: denied, known totals, steps without totals, case, non-ASCII, no match, stop; find records=0 (peak {d} bytes)\n", .{left.peak});
}
