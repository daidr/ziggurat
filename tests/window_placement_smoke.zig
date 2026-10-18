const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const p = @import("ziggurat_window_placement");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_widget_get_mapped(*anyopaque) c_int;
extern fn gtk_widget_get_window(*anyopaque) *anyopaque;
const GdkRect = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
extern fn gdk_window_get_frame_extents(*anyopaque, *GdkRect) void;
const Stage = enum { initial, recover, maximize, fullscreen, io, reopen, final, done };
const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    topology: p.Topology = undefined,
    restorer: p.Restorer = undefined,
    tracker: p.Tracker,
    normal: p.State = undefined,
    saved: p.State = undefined,
    stage: Stage = .initial,
    driving: bool = false,
    event_pending: bool = false,
    posted: bool = false,
    closed: usize = 0,
    failure: ?anyerror = null,
    directory: std.fs.Dir,
    encoded: [p.codec.max_bytes]u8 = undefined,
    encoded_length: usize = 0,
    loaded: [p.codec.max_bytes]u8 = undefined,
    loaded_length: usize = 0,
    worker_error: ?anyerror = null,
    worker: ?std.Thread = null,
    watchdog: Watchdog = .{},
    fn content(self: *Probe) z.Content {
        return .{ .context = self, .event = event, .detach = detach };
    }
    fn detach(_: *anyopaque) void {}
    fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .resize, .window_position, .window_state => {
                if (self.driving) self.event_pending = true else if (!self.posted) {
                    self.posted = true;
                    self.app.post(.{ .context = self, .call = scheduled }) catch |err| self.fail(err);
                }
            },
            else => {},
        }
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        if (self.stage == .io and self.failure == null) self.reopen() catch |err| self.fail(err) else if (self.stage == .done) self.app.quit();
    }
    fn fail(self: *Probe, err: anyerror) void {
        self.failure = self.failure orelse err;
        self.app.quit();
    }
    fn scheduled(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.posted = false;
        self.drive();
    }
    fn start(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.window.perform(.show) catch |err| return self.fail(err);
        self.drive();
    }
    fn drive(self: *Probe) void {
        if (self.driving) {
            self.event_pending = true;
            return;
        }
        self.driving = true;
        self.event_pending = false;
        self.step() catch |err| self.fail(err);
        self.driving = false;
        if (self.event_pending and !self.posted and self.failure == null and self.stage != .done) {
            self.posted = true;
            self.app.post(.{ .context = self, .call = scheduled }) catch |err| self.fail(err);
        }
    }
    fn step(self: *Probe) !void {
        if (self.stage == .io or self.stage == .done) return;
        const state = try self.window.state();
        switch (self.stage) {
            .initial => {
                if (!state.visible) return;
                if (builtin.os.tag == .linux and gtk_widget_get_mapped(self.window.nativeHandle().?) == 0) return;
                self.topology = try p.refresh(self.window);
                // A newly mapped toolkit window can report client bounds that
                // trail the window manager's configure; wait for the next event.
                self.tracker.confirmNormal(self.window, &self.topology) catch |err| {
                    if (err == error.GeometryPending) return;
                    return err;
                };
                var offscreen = try self.tracker.snapshot();
                offscreen.display = try p.Key.init("disconnected-display");
                offscreen.normal.position = .{ .x = 1000000, .y = -1000000 };
                offscreen.normal.width = 800;
                offscreen.normal.height = 500;
                self.restorer = try p.Restorer.init(self.window, offscreen, self.topology, .{});
                self.stage = .recover;
                self.event_pending = true;
            },
            .recover, .reopen, .final => {
                const progress = try self.restorer.advance();
                if (progress == .needs_show) {
                    try self.window.perform(.show);
                    self.event_pending = true;
                    return;
                }
                if (progress != .complete) return;
                if (self.stage == .recover) {
                    try frameContained(self.window, self.topology.monitors[self.restorer.display_index].work);
                    try self.tracker.confirmNormal(self.window, &self.topology);
                    self.normal = try self.tracker.snapshot();
                    self.stage = .maximize;
                    try self.window.perform(.maximize);
                    self.event_pending = true;
                } else if (self.stage == .reopen) {
                    const current = try self.window.state();
                    try std.testing.expect(current.fullscreen);
                    var restored_normal = self.saved;
                    restored_normal.fullscreen = false;
                    restored_normal.maximized = false;
                    self.restorer = try p.Restorer.init(self.window, restored_normal, self.topology, .{});
                    self.stage = .final;
                    self.event_pending = true;
                } else {
                    const actual = try self.window.clientBounds();
                    try std.testing.expectEqual(self.normal.normal.width, actual.width);
                    try std.testing.expectEqual(self.normal.normal.height, actual.height);
                    try std.testing.expectEqual(self.normal.normal.position.x, actual.position.?.x);
                    try std.testing.expectEqual(self.normal.normal.position.y, actual.position.?.y);
                    try frameContained(self.window, self.topology.monitors[self.restorer.display_index].work);
                    try std.testing.expectEqual(p.Observation.normal_pending, try self.tracker.observe(self.window, &self.topology));
                    try std.testing.expectEqualDeep(self.normal.normal, (try self.tracker.snapshot()).normal);
                    try self.tracker.confirmNormal(self.window, &self.topology);
                    self.stage = .done;
                    _ = try self.window.destroy();
                }
            },
            .maximize => {
                if (!state.maximized) return;
                var missing = p.Tracker.init();
                try std.testing.expectError(error.NormalBoundsRequired, missing.observe(self.window, &self.topology));
                try std.testing.expectEqual(p.Observation.special, try self.tracker.observe(self.window, &self.topology));
                const saved = try self.tracker.snapshot();
                try std.testing.expectEqualDeep(self.normal.normal, saved.normal);
                try std.testing.expect(saved.maximized);
                self.stage = .fullscreen;
                try self.window.setFullscreen(true);
                self.event_pending = true;
            },
            .fullscreen => {
                if (!state.fullscreen) return;
                _ = try self.tracker.observe(self.window, &self.topology);
                self.saved = try self.tracker.snapshot();
                try std.testing.expectEqualDeep(self.normal.normal, self.saved.normal);
                try std.testing.expect(self.saved.maximized and self.saved.fullscreen);
                var entries: [1]p.Entry = undefined;
                var store = try p.Store.init(&entries);
                try store.put(try p.Key.init("main"), self.saved);
                self.encoded_length = (try p.codec.encode(&store, &self.encoded)).len;
                self.stage = .io;
                self.worker = try std.Thread.spawn(.{}, storeWorker, .{self});
            },
            .io, .done => unreachable,
        }
    }
    fn storeWorker(self: *Probe) void {
        self.storeInner() catch |err| {
            self.worker_error = err;
        };
        self.app.post(.{ .context = self, .call = loadedState }) catch |err| {
            self.worker_error = err;
            self.watchdog.expired.store(true, .release);
        };
    }
    fn storeInner(self: *Probe) !void {
        try std.testing.expectError(error.WrongThread, p.refresh(self.window));
        try std.testing.expectError(error.WrongThread, self.tracker.snapshot());
        try std.testing.expectError(error.WrongThread, self.tracker.observe(self.window, &self.topology));
        try std.testing.expectError(error.WrongThread, self.restorer.advance());
        try std.testing.expectError(error.WrongThread, self.restorer.cancel());
        const files: p.Files = .{ .ui_thread = self.app.owner };
        var buffer: [256]u8 = undefined;
        try files.save(self.directory, "placement.bin", self.encoded[0..self.encoded_length], &buffer);
        self.loaded_length = (try files.read(self.directory, "placement.bin", &self.loaded)).len;
    }
    fn loadedState(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.loadedInner() catch |err| self.fail(err);
    }
    fn loadedInner(self: *Probe) !void {
        if (self.worker_error) |err| return err;
        var entries: [1]p.Entry = undefined;
        var store = try p.Store.init(&entries);
        try p.codec.decode(&store, self.loaded[0..self.loaded_length]);
        self.saved = store.get(try p.Key.init("main")).?;
        try std.testing.expectEqualDeep(self.normal.normal, self.saved.normal);
        _ = try self.window.destroy();
    }
    fn reopen(self: *Probe) !void {
        self.window = try self.app.createWindow(.{ .width = 200, .height = 160, .on_closed = .{ .context = self, .notify = onClosed } });
        try self.window.setContent(self.content());
        self.topology = try p.refresh(self.window);
        self.restorer = try p.Restorer.init(self.window, self.saved, self.topology, .{});
        self.stage = .reopen;
        self.drive();
    }
};
const Watchdog = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    done: bool = false,
    app: *z.App = undefined,
    expired: std.atomic.Value(bool) = .init(false),
    fn run(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // A settled window manager change does not always produce another
        // geometry event, so re-drive the probe periodically until it finishes.
        var waited: u64 = 0;
        while (!self.done) self.condition.timedWait(&self.mutex, nudge_interval) catch {
            waited += nudge_interval;
            if (waited >= 15 * std.time.ns_per_s) {
                self.expired.store(true, .release);
                self.app.post(.{ .context = self, .call = timeout }) catch {};
                return;
            }
            self.app.post(.{ .context = self, .call = nudge }) catch {};
        };
    }
    const nudge_interval = 250 * std.time.ns_per_ms;
    fn nudge(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const probe: *Probe = @fieldParentPtr("watchdog", self);
        if (probe.failure == null and !probe.posted) probe.drive();
    }
    fn timeout(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.app.quit();
    }
    fn finish(self: *@This()) void {
        self.mutex.lock();
        self.done = true;
        self.condition.signal();
        self.mutex.unlock();
    }
};
fn frameContained(window: z.Window, work: p.Rect) !void {
    var x: i64 = undefined;
    var y: i64 = undefined;
    var right: i64 = undefined;
    var bottom: i64 = undefined;
    if (builtin.os.tag == .windows) {
        var rect: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(window.nativeHandle(), &rect) != 0);
        x = rect.left;
        y = rect.top;
        right = rect.right;
        bottom = rect.bottom;
    } else {
        var rect: GdkRect = undefined;
        gdk_window_get_frame_extents(gtk_widget_get_window(window.nativeHandle().?), &rect);
        x = rect.x;
        y = rect.y;
        right = @as(i64, rect.x) + rect.width;
        bottom = @as(i64, rect.y) + rect.height;
    }
    try std.testing.expect(x >= work.x and y >= work.y and right <= work.right() and bottom <= work.bottom());
}
fn run(allocator: std.mem.Allocator, require_wm: bool) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app, .directory = temporary.dir, .tracker = p.Tracker.init() };
    probe.window = try app.createWindow(.{ .width = 320, .height = 240, .on_closed = .{ .context = &probe, .notify = Probe.onClosed } });
    try probe.window.setContent(probe.content());
    const capabilities = try probe.window.capabilities();
    if (!capabilities.client_position or !capabilities.fullscreen) {
        if (!capabilities.client_position) try std.testing.expectError(error.UnsupportedCapability, p.refresh(probe.window));
        if (require_wm) return error.RequiredWindowManagerUnavailable;
        _ = try probe.window.destroy();
        try app.dispatch();
        return;
    }
    probe.watchdog.app = app;
    const watchdog = try std.Thread.spawn(.{}, Watchdog.run, .{&probe.watchdog});
    defer {
        probe.watchdog.finish();
        watchdog.join();
    }
    try app.post(.{ .context = &probe, .call = Probe.start });
    try app.run();
    if (probe.worker) |worker| worker.join();
    if (probe.failure) |err| {
        std.debug.print("placement stage {s}: {}\n", .{ @tagName(probe.stage), err });
        return err;
    }
    if (probe.watchdog.expired.load(.acquire)) {
        std.debug.print("placement stage {s}, restorer phase {s}: timed out\n", .{ @tagName(probe.stage), @tagName(probe.restorer.phase) });
        return error.WindowPlacementTimeout;
    }
    try std.testing.expectEqual(Stage.done, probe.stage);
    try std.testing.expectEqual(@as(usize, 2), probe.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("window placement: workarea/offscreen restore, normal/max/full tracker, worker atomic store, reopened WM-observed placement, records=0\n", .{});
}
fn isolatedWindows() !void {
    var name: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.Placement.{d}", .{c.GetCurrentProcessId()});
    var wide: [64:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null);
    if (desktop == null) return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const exe_length = c.GetModuleFileNameW(null, &executable, executable.len);
    if (exe_length == 0 or exe_length + 32 >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    command[0] = '"';
    @memcpy(command[1..][0..exe_length], executable[0..exe_length]);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
    @memcpy(command[exe_length + 1 ..][0..suffix.len], suffix);
    command[exe_length + 1 + suffix.len] = 0;
    var startup = std.mem.zeroes(c.STARTUPINFOW);
    startup.cb = @sizeOf(c.STARTUPINFOW);
    startup.lpDesktop = &wide;
    startup.dwFlags = c.STARTF_USESTDHANDLES;
    startup.hStdInput = c.GetStdHandle(c.STD_INPUT_HANDLE);
    startup.hStdOutput = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    startup.hStdError = c.GetStdHandle(c.STD_ERROR_HANDLE);
    var process: c.PROCESS_INFORMATION = undefined;
    if (c.CreateProcessW(&executable, &command, null, null, c.TRUE, c.CREATE_NO_WINDOW, null, null, &startup, &process) == 0) return error.CreateTestProcessFailed;
    defer _ = c.CloseHandle(process.hThread);
    defer _ = c.CloseHandle(process.hProcess);
    if (c.WaitForSingleObject(process.hProcess, 45000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &code) == 0 or code != 0) return error.TestProcessFailed;
}
pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    const allocator = allocations.allocator();
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    var require_wm = false;
    var desktop_child = false;
    for (arguments[1..]) |argument| if (std.mem.eql(u8, argument, "--require-wm")) {
        require_wm = true;
    } else if (std.mem.eql(u8, argument, "--desktop-child")) {
        desktop_child = true;
    } else return error.InvalidArgument;
    if (builtin.os.tag == .windows and !desktop_child) return isolatedWindows();
    try run(allocator, require_wm);
    try @import("window_placement_reentry.zig").run(allocator, false);
    try @import("window_placement_reentry.zig").run(allocator, true);
}
