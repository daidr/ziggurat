const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const process = @import("linux_webview_process.zig");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zfind_test_observer_new(*anyopaque, *anyopaque, *const fn (*anyopaque, c_int, u32) callconv(.c) void) ?*anyopaque;
extern fn zfind_test_observer_release(*anyopaque) void;
extern fn zwk_find_counts(*u32, *u32, *u32, *usize, *usize) void;

// Observation only: retain the original failure when an unexpected old Find
// terminal arrives, but keep the original watchdog until process_failed is seen.
const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    observer: ?*anyopaque = null,
    failure: ?anyerror = null,
    completions: u32 = 0,
    processes: u32 = 0,
    signals: u32 = 0,
    closed: u32 = 0,
    fn trace(self: *State, where: []const u8, tag: []const u8) void {
        std.debug.print("Find recover observation {s}={s} active={} loading={} recovering={} generation={d} completed={d} process_failed={d}\n", .{ where, tag, self.view.page_active, self.view.loading, self.view.recovering, self.view.page_generation, self.completions, self.processes });
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.trace("event", @tagName(std.meta.activeTag(value)));
        switch (value) {
            .process_failed => {
                self.processes += 1;
                std.debug.print("Find recover observation actual process kind={d}\n", .{value.process_failed.native_kind});
                self.app.quit();
            },
            .failed => {
                self.failure = self.failure orelse error.NativeFailed;
                self.app.quit();
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.trace("page", @tagName(std.meta.activeTag(value)));
        if (value != .completed) return;
        if (!value.completed.success) {
            self.failure = self.failure orelse error.LoadFailed;
            return self.app.quit();
        }
        const widget = process.ownedWidget(self.window) catch @panic("own widget missing");
        self.observer = zfind_test_observer_new(widget, self, observed) orelse @panic("observer failed");
        _ = view.startFind(view.pageId().?, .{ .term = "needle", .case_sensitive = true }, .{}, .{ .context = self, .complete = complete }) catch @panic("Find submission failed");
        process.stop(self.window) catch @panic("owned process termination failed");
    }
    fn complete(ptr: *anyopaque, value: web.tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.completions += 1;
        self.trace("completion", @tagName(std.meta.activeTag(value)));
        if (value == .find) std.debug.print("Find recover observation actual snapshot={any}\n", .{value.find});
        if (value != .unavailable and value != .native_failure) {
            self.failure = self.failure orelse error.ExpectedProcessRevocation;
            std.debug.print("Find recover observation original failure retained; awaiting actual process event\n", .{});
        }
    }
    fn observed(ptr: *anyopaque, found: c_int, count: u32) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.signals += 1;
        self.trace("SDK", if (found != 0) "found-text" else "failed-to-find-text");
        std.debug.print("Find recover observation actual SDK count={d}; independent controller ref held\n", .{count});
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        const observer = self.observer;
        self.observer = null;
        if (observer) |value| zfind_test_observer_release(value);
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    var state: State = .{ .app = app };
    state.view = web.View.init(gpa.allocator(), &state, State.event);
    state.window = try app.createWindow(.{ .width = 200, .height = 100, .on_closed = .{ .context = &state, .notify = State.onClosed } });
    defer _ = state.window.destroy() catch unreachable;
    try state.view.attach(state.window, .{ .html = "<!doctype html><body>needle needle</body>", .storage = .ephemeral, .tools = .{ .find = true }, .tool_limits = .{ .max_pending = 2 }, .page_listener = .{ .context = &state, .event = State.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    var budgets: u32 = 0;
    var gates: u32 = 0;
    var commands: u32 = 0;
    var bytes: usize = 0;
    var peak: usize = 0;
    zwk_find_counts(&budgets, &gates, &commands, &bytes, &peak);
    const native = web.resourceCounts();
    std.debug.print("Find recover observation final completions={d} processes={d} signals={d} closed={d} watchdog={} native={d}/{d}/{d} find={d}/{d}/{d}/{d}\n", .{ state.completions, state.processes, state.signals, state.closed, watchdog.expired, native.states, native.handlers, native.controllers, budgets, gates, commands, bytes });
    try std.testing.expect(!watchdog.expired and state.completions == 1 and state.processes == 1 and state.closed == 1 and native.states == 0 and native.handlers == 0 and native.controllers == 0 and budgets == 0 and gates == 0 and commands == 0 and bytes == 0);
    if (state.failure) |err| return err;
}
