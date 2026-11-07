//! Clicks a desktop pet: a borderless window over another, whose input
//! region takes the clicks on its character and lets those elsewhere
//! through to the window behind, through the X server's input shape, as a
//! user's would be (XTest). An empty region lets every click through, null
//! none, and `setIgnorePointer(true)` wins over a region while it is set.
//! Elsewhere it checks that the region reaches the native window without
//! clicking.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;

extern fn XOpenDisplay(?[*:0]const u8) ?*anyopaque;
extern fn XCloseDisplay(*anyopaque) c_int;
extern fn XFlush(*anyopaque) c_int;
extern fn gtk_widget_get_mapped(*anyopaque) c_int;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn zlm_test_input_region_through(*anyopaque, f64, f64) c_int;
extern fn g_timeout_add(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;

const character: z.Rect = .{ .x = 20, .y = 30, .width = 60, .height = 50 };
const on_character: z.Point = .{ .x = 50, .y = 50 };
const off_character: z.Point = .{ .x = 200, .y = 150 };

const Counter = struct {
    presses: usize = 0,
    fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        if (value == .pointer_down) self.presses += 1;
    }
    fn detach(_: *anyopaque) void {}
};

const XTest = struct {
    library: std.DynLib,
    display: *anyopaque,
    move: *const fn (*anyopaque, c_int, c_int, c_int, c_ulong) callconv(.c) c_int,
    button: *const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int,
    fn open() !XTest {
        var library = try std.DynLib.open("libXtst.so.6");
        errdefer library.close();
        const move = library.lookup(*const fn (*anyopaque, c_int, c_int, c_int, c_ulong) callconv(.c) c_int, "XTestFakeMotionEvent") orelse return error.XTestUnavailable;
        const button = library.lookup(*const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int, "XTestFakeButtonEvent") orelse return error.XTestUnavailable;
        const display = XOpenDisplay(null) orelse return error.DisplayUnavailable;
        return .{ .library = library, .display = display, .move = move, .button = button };
    }
    fn close(self: *XTest) void {
        _ = XCloseDisplay(self.display);
        self.library.close();
    }
    /// Presses and releases the primary button at x, y in root pixels.
    fn click(self: *XTest, x: c_int, y: c_int) !void {
        if (self.move(self.display, -1, x, y, 0) == 0 or self.button(self.display, 1, 1, 0) == 0 or self.button(self.display, 1, 0, 0) == 0) return error.InputInjectionFailed;
        _ = XFlush(self.display);
    }
};

/// A click and the window that must take it, after setting up the front
/// window as `prepare` says.
const Step = struct {
    region: enum { keep, character, empty, all } = .keep,
    ignore: ?bool = null,
    at: z.Point,
    front_takes: bool,
};
const steps = [_]Step{
    .{ .region = .character, .at = on_character, .front_takes = true },
    .{ .at = off_character, .front_takes = false },
    .{ .region = .empty, .at = on_character, .front_takes = false },
    .{ .region = .all, .at = off_character, .front_takes = true },
    .{ .region = .character, .ignore = true, .at = on_character, .front_takes = false },
    .{ .ignore = false, .at = on_character, .front_takes = true },
    .{ .at = off_character, .front_takes = false },
};

const Probe = struct {
    app: *z.App,
    behind: z.Window,
    front: z.Window,
    behind_count: Counter = .{},
    front_count: Counter = .{},
    xtest: XTest,
    origin: z.ScreenPoint = undefined,
    step: usize = 0,
    /// Ticks to wait for the shape to reach the server before clicking.
    settle: u8 = 0,
    clicked: bool = false,
    expected: struct { behind: usize, front: usize } = .{ .behind = 0, .front = 0 },
    err: ?anyerror = null,
    done: bool = false,

    fn tick(ptr: ?*anyopaque) callconv(.c) c_int {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        if (self.done) return 0;
        self.advance() catch |err| {
            self.err = err;
            self.finish();
            return 0;
        };
        return @intFromBool(!self.done);
    }
    fn finish(self: *Probe) void {
        self.done = true;
        // A window closing frees the region it kept.
        self.front.setInputRegion(&.{character}) catch {};
        _ = self.front.destroy() catch {};
        _ = self.behind.destroy() catch {};
        self.app.quit();
    }
    fn advance(self: *Probe) !void {
        if (self.step == 0 and !self.clicked and self.settle == 0) {
            // Both windows mapped, where they were asked to be.
            if (gtk_widget_get_mapped(self.behind.nativeHandle().?) == 0 or gtk_widget_get_mapped(self.front.nativeHandle().?) == 0) return;
            const front = (try self.front.clientBounds()).position orelse return;
            const behind = (try self.behind.clientBounds()).position orelse return;
            if (!std.meta.eql(front, behind)) return;
            self.origin = front;
        }
        if (self.clicked) {
            if (self.behind_count.presses < self.expected.behind or self.front_count.presses < self.expected.front) return;
            try std.testing.expectEqual(self.expected.behind, self.behind_count.presses);
            try std.testing.expectEqual(self.expected.front, self.front_count.presses);
            self.clicked = false;
            self.step += 1;
            if (self.step == steps.len) {
                self.finish();
                return;
            }
        }
        const step = steps[self.step];
        if (self.settle == 0) {
            switch (step.region) {
                .keep => {},
                .character => try self.front.setInputRegion(&.{character}),
                .empty => try self.front.setInputRegion(&.{}),
                .all => try self.front.setInputRegion(null),
            }
            if (step.ignore) |value| try self.front.setIgnorePointer(value);
            self.settle = 1;
            return;
        }
        if (self.settle < 4) {
            self.settle += 1;
            return;
        }
        self.settle = 0;
        // XTest uses root physical pixels; window positions are logical.
        const scale = gtk_widget_get_scale_factor(self.front.nativeHandle().?);
        const x: c_int = @intFromFloat((@as(f32, @floatFromInt(self.origin.x)) + step.at.x) * @as(f32, @floatFromInt(scale)));
        const y: c_int = @intFromFloat((@as(f32, @floatFromInt(self.origin.y)) + step.at.y) * @as(f32, @floatFromInt(scale)));
        if (step.front_takes) self.expected.front += 1 else self.expected.behind += 1;
        self.clicked = true;
        try self.xtest.click(x, y);
    }
};

fn linux(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var xtest = XTest.open() catch |err| {
        std.debug.print("input region smoke skipped: {s}\n", .{@errorName(err)});
        return;
    };
    defer xtest.close();
    const behind = try app.createWindow(.{ .title = "Behind", .width = 320, .height = 240, .decoration = .borderless });
    const front = try app.createWindow(.{ .title = "Pet", .width = 320, .height = 240, .decoration = .borderless, .skip_taskbar = true });
    var probe: Probe = .{ .app = app, .behind = behind, .front = front, .xtest = xtest };
    try behind.setContent(.{ .context = &probe.behind_count, .event = Counter.event, .detach = Counter.detach });
    try front.setContent(.{ .context = &probe.front_count, .event = Counter.event, .detach = Counter.detach });
    try behind.setClientBounds(.{ .position = .{ .x = 120, .y = 120 }, .width = 320, .height = 240 });
    try front.setClientBounds(.{ .position = .{ .x = 120, .y = 120 }, .width = 320, .height = 240 });
    try behind.perform(.show);
    try front.perform(.show);
    if ((try front.capabilities()).always_on_top) try front.setAlwaysOnTop(true);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    _ = g_timeout_add(30, Probe.tick, &probe);
    try app.run();
    if (probe.err) |err| return err;
    if (watchdog.expired) {
        std.debug.print("input region smoke stalled at step {d}: behind {d} front {d}\n", .{ probe.step, probe.behind_count.presses, probe.front_count.presses });
        return error.Timeout;
    }
    try std.testing.expectEqual(steps.len, probe.step);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("input region passed: clicks on the character reach the pet, the others the window behind; empty, null and ignore-pointer regions\n", .{});
}

/// macOS and Windows: the region reaches the window without input.
fn other(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Pet", .width = 320, .height = 240, .decoration = .borderless });
    defer _ = window.destroy() catch {};
    try window.perform(.show);
    try window.setInputRegion(&.{character});
    try std.testing.expectEqualSlices(z.Rect, &.{character}, (try window.inputRegion()).?);
    if (builtin.os.tag == .macos) {
        // ignoresMouseEvents follows the pointer in and out of the region.
        const native = app.windows.get(window.key).?.native.native.?;
        const on = zlm_test_input_region_through(native, on_character.x, on_character.y);
        if (on >= 0) {
            try std.testing.expectEqual(@as(c_int, 0), on);
            try std.testing.expectEqual(@as(c_int, 1), zlm_test_input_region_through(native, off_character.x, off_character.y));
            try std.testing.expectEqual(@as(c_int, 0), zlm_test_input_region_through(native, on_character.x, on_character.y));
        } else std.debug.print("the pointer cannot be moved: following it is not checked\n", .{});
    }
    try window.setIgnorePointer(true);
    try window.setIgnorePointer(false);
    try window.setInputRegion(&.{});
    try window.setInputRegion(null);
    try std.testing.expect((try window.inputRegion()) == null);
    std.debug.print("input region passed: set, ignored, emptied and cleared on a shown window\n", .{});
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    if (builtin.os.tag == .linux) try linux(debug.allocator()) else try other(debug.allocator());
}
