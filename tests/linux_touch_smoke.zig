//! Touchscreen fingers on a GTK window: a tap clicks where it landed, a held
//! finger right-clicks and moving fingers scroll the content along with
//! them. Touches are given to the window as GDK delivers them.
const std = @import("std");
const z = @import("ziggurat");

extern fn zlg_test_touch(*anyopaque, c_int, u64, f64, f64, u32, c_int) void;
extern fn zlg_window_pointer_operation(*anyopaque) u64;

const Recorded = union(enum) { down: z.PointerButtonInput, up: z.PointerButtonInput, wheel: struct { position: z.Point, delta: z.Point } };

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    events: [32]Recorded = undefined,
    count: usize = 0,
    failure: ?anyerror = null,
    started: bool = false,

    fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        // Touches reach a window that shows: start once it paints.
        if (value == .paint and !self.started) {
            self.started = true;
            self.app.post(.{ .context = self, .call = run }) catch |err| {
                self.failure = err;
            };
        }
        const recorded: Recorded = switch (value) {
            .pointer_down => |input| .{ .down = input },
            .pointer_up => |input| .{ .up = input },
            .wheel => |wheel| .{ .wheel = .{ .position = wheel.position, .delta = wheel.delta } },
            else => return,
        };
        if (self.count < self.events.len) self.events[self.count] = recorded;
        self.count += 1;
    }
    fn detach(_: *anyopaque) void {}
    fn native(self: *State) *anyopaque {
        return self.app.windows.get(self.window.key).?.native.native.?;
    }
    fn run(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.check() catch |err| {
            self.failure = err;
        };
        _ = self.window.destroy() catch {};
    }
    fn check(self: *State) !void {
        const area = self.native();
        // A tap: a primary press and release where the finger landed.
        zlg_test_touch(area, 0, 1, 40, 30, 1000, 1);
        zlg_test_touch(area, 1, 1, 42, 31, 1020, 1);
        zlg_test_touch(area, 2, 1, 42, 31, 1080, 1);
        try std.testing.expectEqual(2, self.count);
        try std.testing.expect(self.events[0] == .down and self.events[0].down.button == .primary);
        try std.testing.expectEqual(z.Point{ .x = 40, .y = 30 }, self.events[0].down.position);
        try std.testing.expect(self.events[1] == .up and self.events[1].up.button == .primary);
        // Held still, a finger right-clicks: a secondary press and release
        // through the mouse's path, which, as a right mouse button's, give
        // content no primary click.
        self.count = 0;
        const before = zlg_window_pointer_operation(area);
        zlg_test_touch(area, 0, 2, 60, 60, 2000, 1);
        zlg_test_touch(area, 2, 2, 60, 60, 2600, 1);
        try std.testing.expectEqual(before + 2, zlg_window_pointer_operation(area));
        for (self.events[0..self.count]) |recorded| switch (recorded) {
            .down => |input| try std.testing.expectEqual(z.PointerButton.secondary, input.button),
            .up => |input| try std.testing.expectEqual(z.PointerButton.secondary, input.button),
            .wheel => return error.TestUnexpectedResult,
        };
        // A moving finger scrolls the content under it along with it and
        // clicks nothing.
        self.count = 0;
        zlg_test_touch(area, 0, 3, 100, 100, 3000, 1);
        zlg_test_touch(area, 1, 3, 100, 130, 3050, 1);
        zlg_test_touch(area, 2, 3, 100, 130, 3100, 1);
        try std.testing.expectEqual(1, self.count);
        try std.testing.expect(self.events[0] == .wheel);
        try std.testing.expectEqual(z.Point{ .x = 100, .y = 100 }, self.events[0].wheel.position);
        try std.testing.expectEqual(z.Point{ .x = 0, .y = -30 }, self.events[0].wheel.delta);
        // A canceled touch does nothing.
        self.count = 0;
        zlg_test_touch(area, 0, 4, 10, 10, 4000, 1);
        zlg_test_touch(area, 3, 4, 10, 10, 4010, 1);
        try std.testing.expectEqual(0, self.count);
    }
};

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const app = try z.App.init(debug.allocator());
    defer app.deinit();
    var state: State = .{ .app = app };
    state.window = try app.createWindow(.{ .title = "Touch", .width = 240, .height = 180 });
    try state.window.setContent(.{ .context = &state, .event = State.event, .detach = State.detach });
    try state.window.perform(.show);
    try app.run();
    if (state.failure) |err| return err;
    std.debug.print("linux touch passed: tap, press and hold, finger scroll, cancel\n", .{});
}
