const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const desktop = system.desktop;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_settings_get_default() ?*anyopaque;
extern fn g_object_set(object: *anyopaque, first: [*:0]const u8, ...) void;
extern fn g_object_get(object: *anyopaque, first: [*:0]const u8, ...) void;

const Counter = struct {
    calls: usize = 0,
    seen: desktop.Change = .{},
    last: desktop.Change = .{},
    stop_inside: ?*desktop.Watch = null,
    after_stop: ?*Probe = null,
    fn changed(ptr: *anyopaque, change: desktop.Change) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.last = change;
        self.seen = desktop.Change.fromBits(self.seen.bits() | change.bits());
        if (self.stop_inside) |watch| {
            watch.stop();
            watch.stop();
            // Synchronous notification after stop must never reach this context.
            if (self.after_stop) |probe| probe.burst(watch) catch |err| probe.fail(err);
        }
    }
};

const Probe = struct {
    app: *z.App,
    failure: ?anyerror = null,
    baseline: usize = 0,
    gui_baseline: u32 = 0,
    preferences_counter: Counter = .{},
    preferences_watch: desktop.Watch = undefined,
    network_counter: Counter = .{},
    network_watch: desktop.Watch = undefined,
    stopping_counter: Counter = .{},
    stopping_watch: desktop.Watch = undefined,
    shutdown_counter: Counter = .{},
    shutdown_watch: desktop.Watch = undefined,
    stage: usize = 0,
    confirmed: bool = false,
    original_dark: c_int = 0,
    original_animations: c_int = 1,
    toggles: c_int = 0,
    watchdog: Watchdog = undefined,

    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) {
            std.debug.print("desktop smoke failed at stage {d}: {s}\n", .{ self.stage, @errorName(err) });
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        }
        self.failure = self.failure orelse err;
        self.app.quit();
    }
    fn later(self: *Probe, call: *const fn (*anyopaque) void) !void {
        try self.app.post(.{ .context = self, .call = call });
    }
    fn begin(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.snapshots() catch |err| return self.fail(err);
        self.rounds() catch |err| return self.fail(err);
        self.firstBurst() catch |err| return self.fail(err);
    }

    fn snapshots(self: *Probe) !void {
        var list: [desktop.max_monitors]desktop.Monitor = undefined;
        const count = try desktop.monitors(self.app, &list);
        try std.testing.expect(count >= 1);
        var primary: usize = 0;
        for (list[0..count]) |monitor| {
            try std.testing.expect(monitor.bounds.width > 0 and monitor.bounds.height > 0);
            try std.testing.expect(monitor.work_area.width > 0 and monitor.work_area.width <= monitor.bounds.width);
            try std.testing.expect(monitor.scale >= 1);
            if (monitor.primary) primary += 1;
            std.debug.print("monitor {d},{d} {d}x{d} work {d}x{d} scale {d} primary {} refresh {?d}\n", .{ monitor.bounds.x, monitor.bounds.y, monitor.bounds.width, monitor.bounds.height, monitor.work_area.width, monitor.work_area.height, monitor.scale, monitor.primary, monitor.refresh_hz });
        }
        try std.testing.expect(primary <= 1);
        var small: [0]desktop.Monitor = .{};
        try std.testing.expectError(error.CapacityExceeded, desktop.monitors(self.app, &small));
        var sentinel: [1]desktop.Monitor = .{.{ .bounds = .{ .x = 7, .y = 7, .width = 7, .height = 7 }, .work_area = .{ .x = 7, .y = 7, .width = 7, .height = 7 }, .scale = 7, .primary = false, .refresh_hz = 7 }};
        if (count > 1) {
            try std.testing.expectError(error.CapacityExceeded, desktop.monitors(self.app, &sentinel));
            try std.testing.expectEqual(@as(i32, 7), sentinel[0].bounds.x);
        }
        const preferences = try desktop.preferences(self.app);
        try std.testing.expect(preferences.text_scale > 0 and preferences.text_scale <= 5);
        if (builtin.os.tag == .linux) try std.testing.expect(preferences.accent == null and preferences.reduce_transparency == null);
        const power = try desktop.power(self.app);
        if (power.battery_percent) |percent| try std.testing.expect(percent <= 100);
        const network = try desktop.network(self.app);
        std.debug.print("preferences {any}\npower {any}\nnetwork {any}\n", .{ preferences, power, network });
    }

    fn rounds(self: *Probe) !void {
        self.stage = 1;
        var counter: Counter = .{};
        var watch = desktop.Watch.init(&counter, Counter.changed);
        try std.testing.expectError(error.EmptySelection, watch.start(self.app, .{}));
        watch.stop();
        // Warm up process-wide classes, registered messages and GIO singletons.
        try watch.start(self.app, .{ .monitors = true, .preferences = true, .power = true, .network = true });
        watch.stop();
        self.baseline = desktop.resourceCount();
        self.gui_baseline = guiObjects();
        const stops = self.app.resourceStats().stop_participants;
        for (0..12) |_| {
            try watch.start(self.app, .{ .monitors = true, .preferences = true, .power = true, .network = true });
            try std.testing.expect(watch.running());
            try std.testing.expectError(error.AlreadyStarted, watch.start(self.app, .{ .power = true }));
            try std.testing.expectEqual(self.baseline + 1, desktop.resourceCount());
            try std.testing.expectEqual(stops + 1, self.app.resourceStats().stop_participants);
            watch.stop();
            watch.stop();
            try std.testing.expect(!watch.running());
        }
        try std.testing.expectEqual(self.baseline, desktop.resourceCount());
        try std.testing.expectEqual(stops, self.app.resourceStats().stop_participants);
        // Each round creates and destroys its own top-level window. Windows may
        // add a USER object it owns lazily (for example after a broadcast from
        // another process), so assert no object per round rather than exact.
        try std.testing.expect(guiObjects() < self.gui_baseline + 12);
        try std.testing.expectEqual(@as(usize, 0), counter.calls);
    }

    /// One synchronous native burst: several preference notifications plus,
    /// on Windows, a display change and a filtered power broadcast.
    fn burst(self: *Probe, watch: *desktop.Watch) !void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = @ptrCast(desktop.notificationWindowForTesting(watch) orelse return);
            const area = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet");
            for (0..3) |_| _ = c.SendMessageW(hwnd, c.WM_SETTINGCHANGE, 0, @bitCast(@intFromPtr(area)));
            _ = c.SendMessageW(hwnd, c.WM_THEMECHANGED, 0, 0);
            _ = c.SendMessageW(hwnd, c.WM_SYSCOLORCHANGE, 0, 0);
            _ = c.SendMessageW(hwnd, c.WM_DISPLAYCHANGE, 32, 0);
            _ = c.SendMessageW(hwnd, c.WM_POWERBROADCAST, c.PBT_APMPOWERSTATUSCHANGE, 0);
        } else {
            const settings = gtk_settings_get_default() orelse return error.NoSettings;
            for (0..3) |_| {
                self.toggles += 1;
                g_object_set(settings, "gtk-application-prefer-dark-theme", @as(c_int, @intFromBool(@rem(self.toggles, 2) == 1)), @as(?*anyopaque, null));
            }
            g_object_set(settings, "gtk-enable-animations", @as(c_int, 0), @as(?*anyopaque, null));
            g_object_set(settings, "gtk-enable-animations", @as(c_int, 1), @as(?*anyopaque, null));
        }
    }
    fn expectedBurst() desktop.Change {
        return if (builtin.os.tag == .windows) .{ .preferences = true, .monitors = true } else .{ .preferences = true };
    }

    fn firstBurst(self: *Probe) !void {
        self.stage = 2;
        self.preferences_watch = desktop.Watch.init(&self.preferences_counter, Counter.changed);
        try self.preferences_watch.start(self.app, .{ .preferences = true, .monitors = true });
        self.network_watch = desktop.Watch.init(&self.network_counter, Counter.changed);
        try self.network_watch.start(self.app, .{ .network = true });
        try self.burst(&self.preferences_watch);
        try std.testing.expectEqual(@as(usize, 0), self.preferences_counter.calls);
        try self.later(afterFirst);
    }
    fn afterFirst(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.checkFirst() catch |err| self.fail(err);
    }
    fn checkFirst(self: *Probe) !void {
        self.stage = 3;
        // The coalesced idle/posted flush runs before this posted check only if
        // it was already due; wait one more turn when it has not arrived yet.
        if (self.preferences_counter.calls == 0) return self.later(afterFirst);
        // Give a second, uncoalesced delivery one more turn to show up.
        if (!self.confirmed) {
            self.confirmed = true;
            return self.later(afterFirst);
        }
        self.confirmed = false;
        try std.testing.expectEqual(@as(usize, 1), self.preferences_counter.calls);
        try std.testing.expectEqual(expectedBurst(), self.preferences_counter.last);
        try std.testing.expect(!self.network_counter.seen.preferences and !self.network_counter.seen.monitors);
        // Second burst, a fresh native burst after delivery.
        try self.burst(&self.preferences_watch);
        try self.later(afterSecond);
    }
    fn afterSecond(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.checkSecond() catch |err| self.fail(err);
    }
    fn checkSecond(self: *Probe) !void {
        self.stage = 4;
        if (self.preferences_counter.calls == 1) return self.later(afterSecond);
        if (!self.confirmed) {
            self.confirmed = true;
            return self.later(afterSecond);
        }
        try std.testing.expectEqual(@as(usize, 2), self.preferences_counter.calls);
        self.preferences_watch.stop();
        // Stop inside the callback, then a further burst from inside it.
        self.stopping_watch = desktop.Watch.init(&self.stopping_counter, Counter.changed);
        self.stopping_counter.stop_inside = &self.stopping_watch;
        self.stopping_counter.after_stop = self;
        try self.stopping_watch.start(self.app, .{ .preferences = true, .monitors = true });
        try self.burst(&self.stopping_watch);
        try self.later(afterStopInside);
    }
    fn afterStopInside(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.checkStopInside() catch |err| self.fail(err);
    }
    fn checkStopInside(self: *Probe) !void {
        self.stage = 5;
        if (self.stopping_counter.calls == 0) return self.later(afterStopInside);
        try std.testing.expect(!self.stopping_watch.running());
        // Another burst against nothing; give any stale delivery two turns.
        try self.burst(&self.stopping_watch);
        self.stage = 6;
        try self.later(settle);
    }
    fn settle(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.later(finalStage) catch |err| self.fail(err);
    }
    fn finalStage(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.checkFinal() catch |err| self.fail(err);
    }
    fn checkFinal(self: *Probe) !void {
        self.stage = 7;
        try std.testing.expectEqual(@as(usize, 1), self.stopping_counter.calls);
        try std.testing.expectEqual(@as(usize, 2), self.preferences_counter.calls);
        // Leave two watches running into App shutdown, with a burst pending.
        self.shutdown_watch = desktop.Watch.init(&self.shutdown_counter, Counter.changed);
        try self.shutdown_watch.start(self.app, .{ .preferences = true, .monitors = true, .power = true });
        try std.testing.expectEqual(self.baseline + 2, desktop.resourceCount());
        try self.burst(&self.shutdown_watch);
        self.stage = 8;
        self.app.quit();
    }
};

fn guiObjects() u32 {
    if (builtin.os.tag != .windows) return 0;
    return c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS);
}

const Watchdog = struct {
    app: *z.App,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    done: bool = false,
    expired: bool = false,
    fn run(self: *Watchdog) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var timer = std.time.Timer.start() catch unreachable;
        const deadline = 20 * std.time.ns_per_s;
        while (!self.done) {
            const elapsed = timer.read();
            if (elapsed >= deadline) break;
            self.condition.timedWait(&self.mutex, deadline - elapsed) catch {};
        }
        if (!self.done) self.app.post(.{ .context = self, .call = timeout }) catch {};
    }
    fn finish(self: *Watchdog) void {
        self.mutex.lock();
        self.done = true;
        self.condition.signal();
        self.mutex.unlock();
    }
    fn timeout(ptr: *anyopaque) void {
        const self: *Watchdog = @ptrCast(@alignCast(ptr));
        self.expired = true;
        self.app.quit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    // A hidden window keeps the App running; it is never shown.
    _ = try app.createWindow(.{ .title = "desktop smoke" });
    var probe: Probe = .{ .app = app };
    probe.watchdog = .{ .app = app };
    if (builtin.os.tag == .linux) {
        const settings = gtk_settings_get_default() orelse return error.NoSettings;
        g_object_get(settings, "gtk-application-prefer-dark-theme", &probe.original_dark, "gtk-enable-animations", &probe.original_animations, @as(?*anyopaque, null));
    }
    const watchdog = try std.Thread.spawn(.{}, Watchdog.run, .{&probe.watchdog});
    try app.post(.{ .context = &probe, .call = Probe.begin });
    const result = app.run();
    probe.watchdog.finish();
    watchdog.join();
    try result;
    if (probe.watchdog.expired) return error.Timeout;
    if (probe.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 8), probe.stage);
    // App shutdown stopped both running watches; their pending burst never ran.
    try std.testing.expect(!probe.shutdown_watch.running() and !probe.network_watch.running());
    try std.testing.expectEqual(@as(usize, 0), probe.shutdown_counter.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.stopping_counter.calls);
    probe.shutdown_watch.stop();
    probe.network_watch.stop();
    try std.testing.expectEqual(probe.baseline, desktop.resourceCount());
    try std.testing.expectEqual(@as(usize, 0), desktop.resourceCount());
    // App.run destroyed the hidden window; allow the same lazy system objects.
    try std.testing.expect(guiObjects() < probe.gui_baseline + 12);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
    if (builtin.os.tag == .linux) {
        const settings = gtk_settings_get_default() orelse return error.NoSettings;
        g_object_set(settings, "gtk-application-prefer-dark-theme", probe.original_dark, "gtk-enable-animations", probe.original_animations, @as(?*anyopaque, null));
    }
    std.debug.print("desktop smoke passed\n", .{});
}
