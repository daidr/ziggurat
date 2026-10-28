const std = @import("std");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @import("ziggurat_c_gtk");
extern fn zlg_resource_count() u32;

// Real registered GTK signals enter the ordinary C adapter and Core. The event
// facts are deterministic test data; this is not physical device provenance.
const Probe = struct {
    app: *z.App = undefined,
    window: z.Window = undefined,
    other: z.Window = undefined,
    enabled: bool,
    failure: ?anyerror = null,
    phase: z.PointerPhase = .down,
    tick: u32 = 0,
    count: u8 = 1,
    predecessor: u64 = 0,
    eligible: bool = true,
    down: ?z.PointerButtonInput = null,
    sample: ?z.PointerClickTiming = null,
    downs: usize = 0,
    ups: usize = 0,
    detach_count: usize = 0,
    masks: usize = 0,

    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.receive(window, value) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }
    fn receive(self: *Probe, window: z.Window, value: z.Event) !void {
        const input = switch (value) {
            .pointer_down => |input| blk: {
                try std.testing.expectEqual(z.PointerPhase.down, self.phase);
                self.downs += 1;
                self.down = input;
                break :blk input;
            },
            .pointer_up => |input| blk: {
                try std.testing.expectEqual(z.PointerPhase.up, self.phase);
                self.ups += 1;
                break :blk input;
            },
            else => return,
        };
        try std.testing.expectEqual(z.Point{ .x = 20, .y = 20 }, input.position);
        try std.testing.expectEqual(z.PointerButton.primary, input.button);
        if (!self.enabled) {
            try std.testing.expectEqual(@as(u64, 0), input.press.sequence);
            try std.testing.expectError(error.UnsupportedCapability, window.pointerPressSnapshot(input.press, self.phase));
            return;
        }
        const snapshot = try window.pointerPressSnapshot(input.press, self.phase);
        try std.testing.expect(input.press.sequence != 0);
        try std.testing.expectEqual(self.count, input.press.window_count);
        try std.testing.expectEqual(self.eligible, snapshot.continuation_eligible);
        try std.testing.expectEqual(z.PointerButton.primary, snapshot.button);
        const timing = snapshot.timing orelse return error.ExpectedOriginalTiming;
        try std.testing.expectEqual(@as(f64, 20), timing.position.x);
        try std.testing.expectEqual(@as(f64, 20), timing.position.y);
        try std.testing.expect(timing.position.domain != 0 and timing.policy.valid());
        if (self.phase == .down) {
            try std.testing.expectEqual(self.tick, timing.tick_ms);
            try std.testing.expectEqual(self.predecessor, snapshot.previous_completed_sequence);
            self.sample = timing;
        } else {
            try std.testing.expectEqualDeep(self.sample.?, timing);
            try std.testing.expectEqual(self.down.?.press.sequence, input.press.sequence);
            try std.testing.expectEqual(@as(u64, 0), snapshot.previous_completed_sequence);
        }
        try std.testing.expectError(error.StalePointerInput, self.other.pointerPressSnapshot(input.press, self.phase));
        try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, if (self.phase == .down) .up else .down));
        // Ordinary forwarding preserves the native ingress, while a genuinely
        // independent native callback masks it and restores it on return.
        const ordinary = window.beginCallback() orelse return error.ExpectedCallbackScope;
        try std.testing.expectEqualDeep(snapshot, try window.pointerPressSnapshot(input.press, self.phase));
        ordinary.end();
        const native = self.app.beginNativeCallback();
        try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, self.phase));
        native.end();
        try std.testing.expectEqualDeep(snapshot, try window.pointerPressSnapshot(input.press, self.phase));
        self.masks += 1;
    }
    fn detach(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.detach_count += 1;
    }
    fn area(self: *Probe) !*c.GtkWidget {
        const window: *c.GtkWidget = @ptrCast(@alignCast(self.window.nativeHandle() orelse return error.MissingWindow));
        return c.gtk_bin_get_child(@ptrCast(window)) orelse error.MissingArea;
    }
    fn button(self: *Probe, phase: z.PointerPhase, button_number: u32) !void {
        const area_widget = try self.area();
        var native_event = std.mem.zeroes(c.GdkEventButton);
        native_event.type = if (phase == .down) c.GDK_BUTTON_PRESS else c.GDK_BUTTON_RELEASE;
        native_event.window = c.gtk_widget_get_window(area_widget) orelse return error.MissingNativeWindow;
        native_event.send_event = 1;
        native_event.button = button_number;
        native_event.time = self.tick;
        native_event.x = 20;
        native_event.y = 20;
        native_event.x_root = 20;
        native_event.y_root = 20;
        self.phase = phase;
        var handled: c_int = 0;
        c.g_signal_emit_by_name(area_widget, if (phase == .down) "button-press-event" else "button-release-event", &native_event, &handled);
        if (self.failure) |err| return err;
        if (self.enabled and self.down != null) try std.testing.expectError(error.StalePointerInput, self.window.pointerPressSnapshot(self.down.?.press, phase));
    }
    fn motion(self: *Probe, x: f64) !void {
        const area_widget = try self.area();
        var native_event = std.mem.zeroes(c.GdkEventMotion);
        native_event.type = c.GDK_MOTION_NOTIFY;
        native_event.window = c.gtk_widget_get_window(area_widget) orelse return error.MissingNativeWindow;
        native_event.send_event = 1;
        native_event.time = self.tick;
        native_event.x = x;
        native_event.y = 20;
        native_event.state = c.GDK_BUTTON1_MASK;
        var handled: c_int = 0;
        c.g_signal_emit_by_name(area_widget, "motion-notify-event", &native_event, &handled);
        if (self.failure) |err| return err;
    }
    fn run(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.exercise() catch |err| {
            std.debug.print("GTK raw Core enabled={} failed: {s}\n", .{ self.enabled, @errorName(err) });
            if (self.failure == null) self.failure = err;
        };
        self.app.quit();
    }
    fn exercise(self: *Probe) !void {
        c.gtk_widget_grab_focus(try self.area());
        for ([_]u8{ 1, 2, 3, 1 }, 0..) |expected, i| {
            self.count = if (self.enabled) expected else 1;
            self.tick = @intCast(i); // Timestamp zero is captured and valid.
            try self.button(.down, 1);
            try self.button(.up, 1);
            if (self.enabled) self.predecessor = self.down.?.press.sequence;
        }
        if (self.enabled) {
            const before = self.downs;
            // An unknown down is observed by the real adapter, consumes no
            // public sequence and must erase the preceding completion fact.
            self.tick += 1;
            try self.button(.down, 32);
            try std.testing.expectEqual(before, self.downs);
            self.predecessor = 0;
            self.count = 1;
            self.tick += 1;
            try self.button(.down, 1);
            // Moving outside the native threshold and back is sticky, while
            // the current ordinary release remains paired and delivered once.
            try self.motion(1_000_000);
            try self.motion(20);
            self.eligible = false;
            try self.button(.up, 1);
            self.eligible = true;
            self.predecessor = 0;
            self.tick += 1;
            try self.button(.down, 1);
            try self.button(.up, 1);
        }
    }
};

fn scenario(allocator: std.mem.Allocator, enabled: bool) !void {
    var probe: Probe = .{ .enabled = enabled };
    {
        const app = try z.App.initWithOptions(allocator, .{ .icon_policy = .disabled });
        defer app.deinit();
        probe.app = app;
        probe.window = try app.createWindow(.{ .title = "GTK raw ingress", .width = 180, .height = 100, .native_pointer_clicks = enabled });
        probe.other = try app.createWindow(.{ .title = "Other raw owner", .native_pointer_clicks = true });
        try probe.window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
        try app.post(.{ .context = &probe, .call = Probe.run });
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        try std.testing.expect(!watchdog.expired);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    if (probe.failure) |err| return err;
    const expected: usize = if (enabled) 6 else 4;
    try std.testing.expectEqual(expected, probe.downs);
    try std.testing.expectEqual(expected, probe.ups);
    try std.testing.expectEqual(if (enabled) expected * 2 else 0, probe.masks);
    try std.testing.expectEqual(@as(usize, 1), probe.detach_count);
    try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("GTK raw Core enabled={} down={d} up={d} native_masks={d} detach={d} resources=0; original logical sample, zero tick, 1/2/3/1, predecessor/unknown break, sticky motion, exact phase/Window, forwarding/restoration\n", .{ enabled, probe.downs, probe.ups, probe.masks, probe.detach_count });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try scenario(gpa.allocator(), false);
    try scenario(gpa.allocator(), true);
}
