const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = @import("ziggurat_c_win32");

const Probe = struct {
    window: z.Window = undefined,
    content: ui.Context = undefined,
    cancel: bool = false,
    close_while_drawing: bool = false,
    raw_close_while_drawing: bool = false,
    requests: usize = 0,
    notifications: usize = 0,
    fn request(ptr: *anyopaque, _: z.Window, reason: z.CloseReason) z.CloseDecision {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        std.debug.assert(reason == .user);
        self.requests += 1;
        return if (self.cancel) .cancel else .allow;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        const before = self.notifications;
        if (self.close_while_drawing) {
            std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
            std.debug.assert(self.content.hasSurface());
        }
        if (self.raw_close_while_drawing) {
            std.debug.assert(c.DestroyWindow(self.hwnd()) != 0);
            std.debug.assert(self.content.hasSurface());
        }
        std.debug.assert(before == self.notifications);
        // This must remain usable even after a close request during paint.
        frame.label(.{ .x = 8, .y = 8, .width = 200, .height = 32 }, "Lifecycle / 生命周期", 0x182430);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn closed(ptr: *anyopaque, window: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        std.debug.assert(window.isClosed() and window.nativeHandle() == null);
        std.debug.assert(self.content.window == null and !self.content.hasSurface());
        self.notifications += 1;
    }
    fn attach(self: *Probe, app: *z.App) !void {
        self.window = try app.createWindow(.{ .width = 320, .height = 200, .min_width = 180, .min_height = 100, .on_close = .{ .context = self, .request = request }, .on_closed = .{ .context = self, .notify = closed } });
        self.content = ui.Context.init(self, draw, action);
        try self.content.attach(self.window);
    }
    fn hwnd(self: *Probe) c.HWND {
        return @ptrCast(self.window.nativeHandle());
    }
    fn paint(self: *Probe) void {
        _ = c.SendMessageW(self.hwnd(), c.WM_PAINT, 0, 0);
    }
};

fn checkLifecycle(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    try probe.attach(app);
    try probe.window.setTitle("工具窗口 / 🧱");
    var title: [64]u16 = undefined;
    const title_len = c.GetWindowTextW(probe.hwnd(), &title, title.len);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("工具窗口 / 🧱"), title[0..@intCast(title_len)]);
    try probe.window.perform(.disable);
    try std.testing.expect(!(try probe.window.state()).enabled);
    try probe.window.perform(.enable);
    try std.testing.expect((try probe.window.state()).enabled);
    try std.testing.expect(!(try probe.window.state()).visible);
    try probe.window.resize(360, 240);
    var client: c.RECT = undefined;
    try std.testing.expect(c.GetClientRect(probe.hwnd(), &client) != 0);
    const current_dpi = c.GetDpiForWindow(probe.hwnd());
    try std.testing.expectEqual(c.MulDiv(360, @intCast(current_dpi), 96), client.right);
    try std.testing.expectEqual(c.MulDiv(240, @intCast(current_dpi), 96), client.bottom);
    try std.testing.expectError(error.InvalidSize, probe.window.resize(1, 1));
    var limits = std.mem.zeroes(c.MINMAXINFO);
    _ = c.SendMessageW(probe.hwnd(), c.WM_GETMINMAXINFO, 0, @bitCast(@intFromPtr(&limits)));
    const dpi = c.GetDpiForWindow(probe.hwnd());
    try std.testing.expect(limits.ptMinTrackSize.x >= c.MulDiv(180, @intCast(dpi), 96));
    try std.testing.expect(limits.ptMinTrackSize.y >= c.MulDiv(100, @intCast(dpi), 96));
    probe.paint();
    probe.cancel = true;
    _ = c.SendMessageW(probe.hwnd(), c.WM_CLOSE, 0, 0);
    try std.testing.expect(!probe.window.isClosed());
    try std.testing.expectEqual(1, probe.requests);
    probe.cancel = false;
    _ = c.SendMessageW(probe.hwnd(), c.WM_CLOSE, 0, 0);
    try std.testing.expect(probe.window.isClosed());
    try std.testing.expect(probe.content.window != null);
    try app.dispatch();
    try std.testing.expect(probe.content.window == null);

    try probe.attach(app);
    probe.close_while_drawing = true;
    probe.paint();
    try std.testing.expect(probe.window.isClosed());
    try std.testing.expect(probe.content.hasSurface());
    try app.dispatch();
    try std.testing.expect(!probe.content.hasSurface());
    probe.close_while_drawing = false;

    try probe.attach(app);
    probe.raw_close_while_drawing = true;
    probe.paint();
    try std.testing.expect(probe.window.isClosed());
    try std.testing.expect(probe.content.hasSurface());
    try app.dispatch();
    try std.testing.expect(!probe.content.hasSurface());
    probe.raw_close_while_drawing = false;

    // External native destruction must invalidate and release the same record.
    try probe.attach(app);
    const native_window = probe.hwnd();
    try std.testing.expect(c.DestroyWindow(native_window) != 0);
    try std.testing.expect(probe.window.isClosed());
    try std.testing.expect(probe.content.window == null);
    const stale = probe.window;

    // Warm up system font caches before comparing process GUI object counts.
    for (0..16) |_| {
        try probe.attach(app);
        probe.paint();
        _ = try probe.window.destroy();
    }
    _ = c.GdiFlush();
    const base_gdi = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
    const base_user = c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS);
    for (0..1000) |_| {
        try probe.attach(app);
        probe.paint();
        _ = try stale.destroy();
        try std.testing.expect(!probe.window.isClosed());
        _ = try probe.window.destroy();
        try std.testing.expectEqual(0, app.resourceStats().allocated_records);
    }
    _ = c.GdiFlush();
    const end_gdi = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
    const end_user = c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS);
    try std.testing.expectEqual(base_gdi, end_gdi);
    try std.testing.expectEqual(base_user, end_user);
    try std.testing.expectEqual(1, app.resourceStats().registry_slots);
    try std.testing.expectEqual(0, app.resourceStats().pending_destroys);
    std.debug.print("lifecycle smoke passed: 1000 painted windows; records=0 slots=1 GDI {d}->{d}, USER {d}->{d}\n", .{ base_gdi, end_gdi, base_user, end_user });
}

fn checkNativeQuitReentrancy(allocator: std.mem.Allocator) !void {
    const Mutation = struct {
        next: z.Window,
        vetoes: usize = 0,
        fn remove(ptr: *anyopaque, window: z.Window, _: z.CloseReason) z.CloseDecision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(c.DestroyWindow(@ptrCast(window.nativeHandle())) != 0);
            std.debug.assert(c.DestroyWindow(@ptrCast(self.next.nativeHandle())) != 0);
            return .allow;
        }
        fn veto(ptr: *anyopaque, _: z.Window, _: z.CloseReason) z.CloseDecision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.vetoes += 1;
            return .cancel;
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var mutation: Mutation = .{ .next = undefined };
    const survivor = try app.createWindow(.{ .on_close = .{ .context = &mutation, .request = Mutation.veto } });
    mutation.next = try app.createWindow(.{});
    const first = try app.createWindow(.{ .on_close = .{ .context = &mutation, .request = Mutation.remove } });
    try std.testing.expectEqual(z.App.QuitResult.cancelled, app.requestQuit());
    try std.testing.expectEqual(1, mutation.vetoes);
    try std.testing.expect(first.isClosed() and mutation.next.isClosed() and !survivor.isClosed());
    try std.testing.expectEqual(1, app.resourceStats().allocated_records);
}

const Fairness = struct {
    app: *z.App,
    stop: std.atomic.Value(bool) = .init(false),
    ticks: usize = 0,
    ticks_at_stop: usize = 0,
    tasks: usize = 0,
    fn task(ptr: *anyopaque) void {
        const self: *Fairness = @ptrCast(@alignCast(ptr));
        self.tasks += 1;
        if (self.stop.load(.acquire)) {
            self.ticks_at_stop = self.ticks;
            self.app.quit();
        } else self.app.post(.{ .context = self, .call = task }) catch unreachable;
    }
    fn finish(self: *Fairness) void {
        zio.sleep(300 * std.time.ns_per_ms);
        self.stop.store(true, .release);
    }
    fn timer(_: c.HWND, _: c.UINT, _: c.UINT_PTR, _: c.DWORD) callconv(.winapi) void {
        active_fairness.?.ticks += 1;
    }
};
var active_fairness: ?*Fairness = null;

fn checkFairness(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var state: Fairness = .{ .app = app };
    active_fairness = &state;
    defer active_fairness = null;
    const timer_id = c.SetTimer(null, 0, 10, @ptrCast(&Fairness.timer));
    if (timer_id == 0) return error.CreateTimerFailed;
    defer _ = c.KillTimer(null, timer_id);
    const worker = try std.Thread.spawn(.{}, Fairness.finish, .{&state});
    defer worker.join();
    try app.post(.{ .context = &state, .call = Fairness.task });
    try app.run();
    try std.testing.expect(state.ticks_at_stop > 0);
    std.debug.print("fairness smoke passed: timer dispatched during continuous tasks ({d} ticks)\n", .{state.ticks_at_stop});
}

fn checkMessageQuota(allocator: std.mem.Allocator) !void {
    const State = struct {
        app: *z.App,
        calls: usize = 0,
        during_run: bool = false,
        fn task(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            self.during_run = self.app.phase == .running;
            self.app.quit();
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var state: State = .{ .app = app };
    var count: usize = 0;
    while (count < 20000 and c.PostMessageW(@ptrCast(app.native.dispatcher), c.WM_NULL, 0, 0) != 0) : (count += 1) {}
    const quota_hit = count < 20000;
    if (quota_hit) try std.testing.expectEqual(@as(u32, 1816), c.GetLastError());
    try app.post(.{ .context = &state, .call = State.task });
    try app.run();
    try std.testing.expectEqual(1, state.calls);
    try std.testing.expect(state.during_run);
    std.debug.print("quota smoke passed: messages={d}, quota_hit={}, accepted task executed once\n", .{ count, quota_hit });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const AllocationScenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const app = try z.App.init(allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            _ = try window.destroy();
        }
    };
    // Includes real UTF-16 title allocation and native initialization rollback.
    try std.testing.checkAllAllocationFailures(gpa.allocator(), AllocationScenario.run, .{});
    try checkLifecycle(gpa.allocator());
    try checkNativeQuitReentrancy(gpa.allocator());
    try checkFairness(gpa.allocator());
    try checkMessageQuota(gpa.allocator());
}
