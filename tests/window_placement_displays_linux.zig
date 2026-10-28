const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const p = @import("ziggurat_window_placement");
const desktop = @import("ziggurat_system").desktop;
extern fn gtk_widget_get_mapped(*anyopaque) c_int;
extern fn gtk_widget_get_window(*anyopaque) *anyopaque;
extern fn gdk_display_get_default() ?*anyopaque;
extern fn gdk_x11_display_get_xdisplay(*anyopaque) *anyopaque;
const GdkRect = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
extern fn gdk_window_get_frame_extents(*anyopaque, *GdkRect) void;
extern fn zwpt_shrink_output(*anyopaque) c_int;
extern fn zwpt_restore_output(*anyopaque) c_int;

/// A real monitor change on an isolated Xvfb server: the only CRTC shrinks
/// under a window placed on its far side. The desktop monitors notification
/// drives refresh, displacement and a Restorer from the Tracker snapshot.
const Stage = enum { initial, place, shrink, relocate, done };
const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    topology: p.Topology = undefined,
    restorer: p.Restorer = undefined,
    tracker: p.Tracker,
    watch: desktop.Watch = undefined,
    stage: Stage = .initial,
    original: p.Rect = undefined,
    shrunk: bool = false,
    changes: usize = 0,
    displaced: p.Displacement = .contained,
    driving: bool = false,
    event_pending: bool = false,
    posted: bool = false,
    failure: ?anyerror = null,
    expired: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    fn content(self: *Probe) z.Content {
        return .{ .context = self, .event = event, .detach = detach };
    }
    fn detach(_: *anyopaque) void {}
    fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .resize, .window_position, .window_state => self.schedule(),
            else => {},
        }
    }
    fn monitorsChanged(ptr: *anyopaque, change: desktop.Change) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (change.monitors) self.changes += 1;
        self.drive();
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.app.quit();
    }
    fn fail(self: *Probe, err: anyerror) void {
        self.failure = self.failure orelse err;
        self.app.quit();
    }
    fn schedule(self: *Probe) void {
        if (self.driving) {
            self.event_pending = true;
        } else if (!self.posted) {
            self.posted = true;
            self.app.post(.{ .context = self, .call = scheduled }) catch |err| self.fail(err);
        }
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
        if (self.failure != null or self.stage == .done) return;
        self.driving = true;
        self.event_pending = false;
        self.step() catch |err| self.fail(err);
        self.driving = false;
        if (self.event_pending and self.failure == null and self.stage != .done) self.schedule();
    }
    fn step(self: *Probe) !void {
        switch (self.stage) {
            .initial => {
                if (!(try self.window.state()).visible) return;
                if (gtk_widget_get_mapped(self.window.nativeHandle().?) == 0) return;
                self.topology = try p.refresh(self.window);
                try std.testing.expectEqual(@as(u8, 1), self.topology.count);
                self.tracker.confirmNormal(self.window, &self.topology) catch |err| {
                    if (err == error.GeometryPending) return;
                    return err;
                };
                // Place the window in the bottom-right quarter, which the
                // shrunk output no longer covers.
                const work = self.topology.monitors[0].work;
                var target = try self.tracker.snapshot();
                target.normal.position = .{ .x = work.x + @as(i32, @intCast(work.width * 3 / 4)), .y = work.y + @as(i32, @intCast(work.height * 3 / 4)) };
                self.original = self.topology.monitors[0].bounds;
                self.restorer = try p.Restorer.init(self.window, target, self.topology, .{});
                self.stage = .place;
                self.event_pending = true;
            },
            .place, .relocate => {
                const progress = try self.restorer.advance();
                if (progress == .needs_show) {
                    try self.window.perform(.show);
                    self.event_pending = true;
                    return;
                }
                if (progress != .complete) return;
                try frameContained(self.window, self.topology.monitors[self.restorer.display_index].work);
                try self.tracker.confirmNormal(self.window, &self.topology);
                try std.testing.expectEqual(p.Displacement.contained, try p.displacement(self.window, &self.topology));
                if (self.stage == .place) {
                    try self.watch.start(self.app, .{ .monitors = true });
                    const status = zwpt_shrink_output(xdisplay());
                    if (status != 0) return error.RandrChangeFailed;
                    self.shrunk = true;
                    self.stage = .shrink;
                } else {
                    self.watch.stop();
                    self.stage = .done;
                    _ = try self.window.destroy();
                }
            },
            .shrink => {
                // Only the monitors notification moves this stage forward.
                if (self.changes == 0) return;
                self.topology = try p.refresh(self.window);
                const bounds = self.topology.monitors[0].bounds;
                if (bounds.width != self.original.width / 2 or bounds.height != self.original.height / 2) return;
                self.displaced = try p.displacement(self.window, &self.topology);
                // The window manager may already have pulled the frame back.
                if (self.displaced == .contained) return;
                self.restorer = try p.Restorer.init(self.window, try self.tracker.snapshot(), self.topology, .{});
                self.stage = .relocate;
                self.event_pending = true;
            },
            .done => {},
        }
    }
};
fn xdisplay() *anyopaque {
    return gdk_x11_display_get_xdisplay(gdk_display_get_default().?);
}
fn frameContained(window: z.Window, work: p.Rect) !void {
    var rect: GdkRect = undefined;
    gdk_window_get_frame_extents(gtk_widget_get_window(window.nativeHandle().?), &rect);
    try std.testing.expect(rect.x >= work.x and rect.y >= work.y and @as(i64, rect.x) + rect.width <= work.right() and @as(i64, rect.y) + rect.height <= work.bottom());
}
/// Window managers do not always send another geometry event once a change
/// settles, so re-drive the probe until it finishes or the deadline passes.
fn watchdog(probe: *Probe) void {
    var waited: u64 = 0;
    const interval = 250 * std.time.ns_per_ms;
    while (!probe.done.load(.acquire)) {
        zio.sleep(interval);
        waited += interval;
        if (waited >= 20 * std.time.ns_per_s) {
            probe.expired.store(true, .release);
            probe.app.post(.{ .context = probe, .call = timeout }) catch {};
            return;
        }
        probe.app.post(.{ .context = probe, .call = nudge }) catch {};
    }
}
fn nudge(ptr: *anyopaque) void {
    const probe: *Probe = @ptrCast(@alignCast(ptr));
    if (!probe.posted) probe.drive();
}
fn timeout(ptr: *anyopaque) void {
    const probe: *Probe = @ptrCast(@alignCast(ptr));
    probe.app.quit();
}
pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    const allocator = allocations.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app, .tracker = p.Tracker.init() };
    probe.watch = desktop.Watch.init(&probe, Probe.monitorsChanged);
    probe.window = try app.createWindow(.{ .width = 320, .height = 240, .on_closed = .{ .context = &probe, .notify = Probe.onClosed } });
    try probe.window.setContent(probe.content());
    if (!(try probe.window.capabilities()).client_position) return error.RequiredWindowManagerUnavailable;
    const thread = try std.Thread.spawn(.{}, watchdog, .{&probe});
    defer {
        probe.done.store(true, .release);
        thread.join();
    }
    try app.post(.{ .context = &probe, .call = Probe.start });
    try app.run();
    if (probe.shrunk) {
        if (gdk_display_get_default()) |_| _ = zwpt_restore_output(xdisplay());
    }
    if (probe.failure) |err| {
        std.debug.print("display change stage {s}: {}\n", .{ @tagName(probe.stage), err });
        return err;
    }
    if (probe.expired.load(.acquire)) {
        std.debug.print("display change stage {s}, changes {d}, displacement {s}, restorer phase {s}: timed out\n", .{ @tagName(probe.stage), probe.changes, @tagName(probe.displaced), @tagName(probe.restorer.phase) });
        return error.DisplayChangeTimeout;
    }
    try std.testing.expectEqual(Stage.done, probe.stage);
    try std.testing.expect(probe.changes > 0);
    try std.testing.expectEqual(@as(usize, 0), desktop.resourceCount());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("window placement displays: output shrink notified ({d} monitor changes), frame {s}, relocated into the new workarea, records=0\n", .{ probe.changes, @tagName(probe.displaced) });
}
