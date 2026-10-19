const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const p = @import("ziggurat_window_placement");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_widget_destroy(*anyopaque) void;
const Flags = struct { freed: bool = false, in_advance: bool = false, closed_inside_callback: bool = false, busy_checked: bool = false, failure: ?anyerror = null };
const Host = struct {
    allocator: std.mem.Allocator,
    window: z.Window = undefined,
    restorer: p.Restorer = undefined,
    flags: *Flags,
    raw: bool,
    armed: bool = false,
    shown: bool = false,
    geometry_pending: bool = false,
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (self.geometry_pending and (value == .resize or value == .window_position or value == .window_state)) {
            self.geometry_pending = false;
            window.app.post(.{ .context = self, .call = start }) catch |err| {
                self.flags.failure = err;
                window.app.quit();
            };
            return;
        }
        if (value != .resize or !self.armed) return;
        self.armed = false;
        const flags = self.flags;
        if (flags.in_advance) {
            std.testing.expectError(error.Busy, self.restorer.advance()) catch |err| {
                flags.failure = err;
            };
            flags.busy_checked = true;
        }
        if (self.raw) {
            if (builtin.os.tag == .windows) std.debug.assert(c.DestroyWindow(window.nativeHandle()) != 0) else gtk_widget_destroy(window.nativeHandle().?);
        } else _ = window.destroy() catch |err| {
            flags.failure = err;
            return;
        };
        flags.closed_inside_callback = flags.freed;
    }
    fn detach(_: *anyopaque) void {}
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        const flags = self.flags;
        allocator.destroy(self);
        flags.freed = true;
    }
    fn start(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.prepare() catch |err| {
            // The toolkit's client bounds can trail the window manager's
            // configure after mapping; retry on the next geometry event.
            if (err == error.GeometryPending) {
                self.geometry_pending = true;
                return;
            }
            self.flags.failure = err;
            self.window.app.quit();
            return;
        };
        const flags = self.flags;
        flags.in_advance = true;
        _ = self.restorer.advance() catch |err| {
            if (err != error.Closed) flags.failure = err;
        };
        // The final Window scope may already have released Host; only external
        // test state is accessed from this point.
        flags.in_advance = false;
    }
    fn prepare(self: *Host) !void {
        if (!self.shown) try self.window.perform(.show);
        self.shown = true;
        const topology = try p.refresh(self.window);
        var tracker = p.Tracker.init();
        try tracker.confirmNormal(self.window, &topology);
        var saved = try tracker.snapshot();
        saved.normal.width += 31;
        self.restorer = try p.Restorer.init(self.window, saved, topology, .{});
        self.armed = true;
    }
};
pub fn run(allocator: std.mem.Allocator, raw: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var flags: Flags = .{};
    const host = try allocator.create(Host);
    var attached = false;
    errdefer if (!attached) allocator.destroy(host);
    host.* = .{ .allocator = allocator, .flags = &flags, .raw = raw };
    host.window = try app.createWindow(.{ .width = 240, .height = 180, .on_closed = .{ .context = host, .notify = Host.closed } });
    attached = true;
    try host.window.setContent(.{ .context = host, .event = Host.event, .detach = Host.detach });
    try app.post(.{ .context = host, .call = Host.start });
    try app.run();
    if (flags.failure) |err| return err;
    try std.testing.expect(flags.freed and !flags.closed_inside_callback);
    if (builtin.os.tag == .windows) try std.testing.expect(flags.busy_checked);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
