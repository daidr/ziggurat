const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn XOpenDisplay(?[*:0]const u8) ?*anyopaque;
extern fn XCloseDisplay(*anyopaque) c_int;
extern fn XFlush(*anyopaque) c_int;
extern fn g_spawn_async(?[*:0]const u8, [*:null]const ?[*:0]const u8, ?[*:null]const ?[*:0]const u8, c_uint, ?*anyopaque, ?*anyopaque, *c_int, ?*?*anyopaque) c_int;
extern fn g_child_watch_add(c_int, *const fn (c_int, c_int, *anyopaque) callconv(.c) void, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn g_spawn_check_wait_status(c_int, ?*?*anyopaque) c_int;
extern fn g_spawn_close_pid(c_int) void;
extern fn gtk_widget_get_mapped(*anyopaque) c_int;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;

pub fn driver(args: []const []const u8) !void {
    if (args.len != 4) return error.InvalidDriverArguments;
    var points: [4]c_int = undefined;
    for (args, &points) |arg, *point| point.* = try std.fmt.parseInt(c_int, arg, 10);
    var library = try std.DynLib.open("libXtst.so.6");
    defer library.close();
    const move = library.lookup(*const fn (*anyopaque, c_int, c_int, c_int, c_ulong) callconv(.c) c_int, "XTestFakeMotionEvent") orelse return error.XTestUnavailable;
    const button = library.lookup(*const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int, "XTestFakeButtonEvent") orelse return error.XTestUnavailable;
    const display = XOpenDisplay(null) orelse return error.DisplayUnavailable;
    defer _ = XCloseDisplay(display);
    if (move(display, -1, points[0], points[1], 0) == 0 or button(display, 1, 1, 0) == 0) return error.InputInjectionFailed;
    _ = XFlush(display);
    // The driver has no App or UI loop. Give the external WM time to take the
    // actual pointer grab before moving; the parent checks observed geometry.
    zio.sleep(300 * std.time.ns_per_ms);
    if (move(display, -1, points[2], points[3], 0) == 0) return error.InputInjectionFailed;
    _ = XFlush(display);
    zio.sleep(100 * std.time.ns_per_ms);
    if (button(display, 1, 0, 0) == 0) return error.InputInjectionFailed;
    _ = XFlush(display);
}
const Job = struct {
    probe: *Probe,
    pid: c_int = 0,
    watch: c_uint = 0,
    done: bool = false,
    okay: bool = false,
    submitted: bool = false,
    fn exited(pid: c_int, status: c_int, ptr: *anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        self.pid = 0;
        self.watch = 0;
        self.done = true;
        self.okay = g_spawn_check_wait_status(status, null) != 0;
        g_spawn_close_pid(pid);
        const scope = self.probe.window.beginCallback() orelse return;
        defer scope.end();
        self.probe.enqueue();
    }
    fn start(self: *Job, allocator: std.mem.Allocator, bounds: z.ClientBounds) !void {
        const origin = bounds.position orelse return error.PositionUnavailable;
        const exe = try zio.executablePathAlloc(allocator);
        defer allocator.free(exe);
        const exe_z = try allocator.dupeSentinel(u8, exe, 0);
        defer allocator.free(exe_z);
        var storage: [4][32]u8 = undefined;
        var values: [4][:0]u8 = undefined;
        // XTest uses root physical pixels; public X11 positions are logical.
        const scale = gtk_widget_get_scale_factor(self.probe.window.nativeHandle().?);
        const coordinates = [_]i32{ (origin.x + 100) * scale, (origin.y + 100) * scale, (origin.x + 160) * scale, (origin.y + 140) * scale };
        for (coordinates, &storage, &values) |coordinate, *buffer, *value| value.* = try std.fmt.bufPrintSentinel(buffer, "{d}", .{coordinate}, 0);
        const argv = [_:null]?[*:0]const u8{ exe_z.ptr, "--x11-driver", values[0].ptr, values[1].ptr, values[2].ptr, values[3].ptr };
        if (g_spawn_async(null, &argv, null, 1 << 1, null, null, &self.pid, null) == 0) return error.DriverSpawnFailed;
        self.watch = g_child_watch_add(self.pid, exited, self);
        if (self.watch == 0) return error.ChildWatchFailed;
    }
    fn cleanup(self: *Job) void {
        if (self.watch != 0) _ = g_source_remove(self.watch);
        self.watch = 0;
        if (self.pid != 0) {
            std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
            _ = zio.posix.waitpid(self.pid, 0);
            g_spawn_close_pid(self.pid);
            self.pid = 0;
        }
    }
};
const Probe = struct {
    allocator: std.mem.Allocator,
    window: z.Window = undefined,
    jobs: [2]Job = undefined,
    stage: usize = 0,
    pending: bool = false,
    started: bool = false,
    closed: bool = false,
    before: z.ClientBounds = undefined,
    err: ?anyerror = null,
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (window.app.phase == .stopping or window.app.phase == .stopped) return;
        if (value == .pointer_down and self.started and self.stage < 2) {
            if (self.stage == 0) window.startMove() catch |err| {
                self.err = err;
                window.app.quit();
                return;
            } else window.startResize(.south_east) catch |err| {
                self.err = err;
                window.app.quit();
                return;
            };
            self.jobs[self.stage].submitted = true;
            std.testing.expectError(error.InvalidGesture, window.startMove()) catch |err| {
                self.err = err;
                window.app.quit();
            };
        }
        if (value == .window_state or value == .resize or value == .focus) self.enqueue();
    }
    fn enqueue(self: *Probe) void {
        if (self.pending or self.window.isClosed()) return;
        self.pending = true;
        self.window.app.post(.{ .context = self, .call = advance }) catch {};
    }
    fn advance(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.pending = false;
        self.step() catch |err| {
            self.err = err;
            self.window.app.quit();
        };
    }
    fn step(self: *Probe) !void {
        if (self.window.isClosed()) return;
        const state = try self.window.state();
        const bounds = try self.window.clientBounds();
        if (!self.started) {
            if (!state.focused or gtk_widget_get_mapped(self.window.nativeHandle().?) == 0 or bounds.width != 320 or bounds.height != 240) return;
            self.before = bounds;
            self.started = true;
            try self.jobs[0].start(self.allocator, bounds);
            return;
        }
        if (!self.jobs[self.stage].done) return;
        try std.testing.expect(self.jobs[self.stage].okay and self.jobs[self.stage].submitted);
        if (self.stage == 0) {
            if (std.meta.eql(self.before.position, bounds.position)) return;
            self.before = bounds;
            self.stage = 1;
            try self.jobs[1].start(self.allocator, bounds);
        } else {
            if (bounds.width <= self.before.width or bounds.height <= self.before.height) return;
            self.stage = 2;
            _ = try self.window.destroy();
        }
    }
    fn detach(_: *anyopaque) void {}
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};
pub fn run(allocator: std.mem.Allocator, require_wm: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .allocator = allocator };
    probe.jobs = .{ .{ .probe = &probe }, .{ .probe = &probe } };
    defer for (&probe.jobs) |*job| job.cleanup();
    probe.window = try app.createWindow(.{ .title = "Native move and resize", .width = 320, .height = 240, .decoration = .custom, .on_closed = .{ .context = &probe, .notify = Probe.notify } });
    try probe.window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
    if (!(try probe.window.capabilities()).native_move_resize) {
        if (require_wm) return error.WindowManagerRequired;
        return;
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try probe.window.perform(.show);
    try probe.window.perform(.focus);
    try app.run();
    if (probe.err) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.closed);
    try std.testing.expectEqual(@as(usize, 2), probe.stage);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("X11 native input passed: actual WM move and resize, one-shot gesture, observed position/size changes\n", .{});
}
