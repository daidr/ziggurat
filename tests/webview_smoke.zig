const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const html =
    \\<!doctype html><meta charset="utf-8"><script>
    \\chrome.webview.addEventListener('message', e => { if(e.data === 'ping') chrome.webview.postMessage('pong'); });
    \\chrome.webview.postMessage('boot');
    \\</script>
;

const State = struct {
    close_when_ready: bool = false,
    complete: bool = false,
    failed: bool = false,
    premature_callbacks: usize = 0,
    close_result: ?z.CloseResult = null,
    attached_after_close: bool = false,

    fn close(self: *State, view: *web.View) void {
        self.close_result = view.window.?.destroy() catch {
            self.failed = true;
            view.window.?.app.quit();
            return;
        };
        self.attached_after_close = view.window != null and view.native != null and view.ready;
        view.post("after-close") catch |err| {
            if (err != error.Closed) self.failed = true;
            return;
        };
        self.failed = true;
    }
    fn early(ptr: *anyopaque, _: *web.View, _: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.premature_callbacks += 1;
    }
    fn event(ptr: *anyopaque, view: *web.View, ev: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .resources_released => {},
            .policy_request, .process_failed => {
                self.failed = true;
                self.close(view);
            },
            .ready => if (self.close_when_ready) {
                self.complete = true;
                self.close(view);
            },
            .failed => |hr| {
                std.debug.print("WebView2 failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
                self.failed = true;
                self.close(view);
            },
            .message => |text| {
                if (std.mem.eql(u8, text, "boot")) {
                    view.post("ping") catch {
                        self.failed = true;
                        self.close(view);
                    };
                } else if (std.mem.eql(u8, text, "pong")) {
                    self.complete = true;
                    self.close(view);
                }
            },
        }
    }
};

fn expectResourcesReleased(stage: []const u8, cycle: usize) !void {
    const counts = web.resourceCounts();
    if (counts.states != 0 or counts.handlers != 0 or counts.controllers != 0) {
        std.debug.print("WebView resources after {s} cycle {d}: states={d}, handlers={d}, controllers={d}\n", .{ stage, cycle, counts.states, counts.handlers, counts.controllers });
    }
    try std.testing.expectEqual(@as(u32, 0), counts.states);
    try std.testing.expectEqual(@as(u32, 0), counts.handlers);
    try std.testing.expectEqual(@as(u32, 0), counts.controllers);
}

fn runAbandonedOnlyCycle(allocator: std.mem.Allocator, profile: []const u8, cycle: usize) !void {
    var state: State = .{};
    var view = web.View.init(allocator, &state, State.early);
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        try view.attach(window, .{ .html = html, .user_data_folder = profile });
        const pending = web.resourceCounts();
        try std.testing.expectEqual(@as(u32, 1), pending.states);
        try std.testing.expect(pending.handlers > 0);
        try std.testing.expectEqual(@as(u32, 0), pending.controllers);
        try std.testing.expectEqual(z.CloseResult.closed, try window.destroy());
        app.quit();
        try std.testing.expectEqual(0, app.resourceStats().allocated_records);
        try std.testing.expectEqual(0, app.resourceStats().pending_destroys);
        try std.testing.expectEqual(1, app.resourceStats().registry_slots);
        try std.testing.expect(view.window == null and view.native == null and !view.ready);
    }
    // No run(), replacement window, or manual message pump assists cleanup.
    try expectResourcesReleased("abandoned-only", cycle);
    try std.testing.expectEqual(0, state.premature_callbacks);
}

fn runCycle(allocator: std.mem.Allocator, profile: []const u8, cycle: usize) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .close_when_ready = cycle % 2 == 0 };
    var early = web.View.init(allocator, &state, State.early);
    var view = web.View.init(allocator, &state, State.event);

    // Reusing the View while its old native callbacks are pending must be safe.
    var stale: ?z.Window = null;
    for (0..8) |_| {
        const abandoned = try app.createWindow(.{});
        try early.attach(abandoned, .{ .html = html, .user_data_folder = profile });
        if (stale) |closed| {
            try std.testing.expectEqual(z.CloseResult.closed, try closed.destroy());
            try std.testing.expect(!abandoned.isClosed());
        }
        try std.testing.expectEqual(z.CloseResult.closed, try abandoned.destroy());
        try std.testing.expect(abandoned.isClosed());
        try std.testing.expect(early.window == null and early.native == null and !early.ready);
        try std.testing.expectEqual(0, app.resourceStats().allocated_records);
        try std.testing.expectEqual(1, app.resourceStats().registry_slots);
        stale = abandoned;
    }

    const window = try app.createWindow(.{});
    try view.attach(window, .{ .html = html, .user_data_folder = profile });
    try std.testing.expect(stale.?.isClosed());
    try std.testing.expectEqual(z.CloseResult.closed, try stale.?.destroy());
    try std.testing.expect(!window.isClosed());

    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired);
    try std.testing.expect(!state.failed);
    try std.testing.expect(state.complete);
    try std.testing.expectEqual(0, state.premature_callbacks);
    try std.testing.expectEqual(z.CloseResult.deferred, state.close_result.?);
    try std.testing.expect(state.attached_after_close);
    try std.testing.expect(window.isClosed());
    try std.testing.expect(view.window == null and view.native == null and !view.ready);
    const stats = app.resourceStats();
    try std.testing.expectEqual(0, stats.live_windows);
    try std.testing.expectEqual(0, stats.allocated_records);
    try std.testing.expectEqual(0, stats.pending_destroys);
    try std.testing.expectEqual(1, stats.registry_slots);
    try expectResourcesReleased("callback close", cycle);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "Smoke" });
    defer allocator.free(profile);
    try expectResourcesReleased("initial", 0);
    for (0..3) |cycle| try runAbandonedOnlyCycle(allocator, profile, cycle + 1);
    for (0..12) |cycle| try runCycle(allocator, profile, cycle + 1);
    try expectResourcesReleased("final", 12);
    std.debug.print("webview smoke passed: 15 Apps, 99 pending closes, ready/message callback closes; records=0 slots=1 COM=0\n", .{});
}
