const std = @import("std");
const z = @import("root.zig");

const Seen = struct {
    events: [8]z.Event = undefined,
    count: usize = 0,
    fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
        const self: *Seen = @ptrCast(@alignCast(ptr));
        if (self.count < self.events.len) self.events[self.count] = value;
        self.count += 1;
    }
    fn detach(_: *anyopaque) void {}
};
fn record(window: z.Window) *z.WindowRecord {
    return window.app.windows.get(window.key).?;
}

test "zoomed content sees its own DIPs and frames at the zoomed scale" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 200, .height = 100 });
    var seen: Seen = .{};
    try window.setContent(.{ .context = &seen, .event = Seen.event, .detach = Seen.detach });
    try std.testing.expectEqual(@as(f32, 1), window.zoom());
    try std.testing.expectError(error.InvalidValue, window.setZoom(0));
    try std.testing.expectError(error.InvalidValue, window.setZoom(std.math.nan(f32)));
    try std.testing.expectError(error.InvalidValue, window.setZoom(9));

    try window.setZoom(2);
    try std.testing.expectEqual(@as(f32, 2), window.zoom());
    try std.testing.expectEqual(@as(f32, 2), (try window.contentSize()).scale);

    seen.count = 0;
    const item = record(window);
    item.emit(.{ .resize = .{ .width = 200, .height = 100, .scale = 1 } });
    try std.testing.expectEqual(@as(f32, 2), seen.events[0].resize.scale);
    seen.count = 0;
    item.emit(.{ .pointer_move = .{ .x = 40, .y = 20 } });
    item.emit(.{ .wheel = .{ .position = .{ .x = 10, .y = 8 }, .delta = .{ .x = 0, .y = 48 } } });
    item.emit(.{ .pointer_down = .{ .position = .{ .x = 6, .y = 4 } } });
    try std.testing.expectEqual(z.Point{ .x = 20, .y = 10 }, seen.events[0].pointer_move);
    try std.testing.expectEqual(z.Point{ .x = 5, .y = 4 }, seen.events[1].wheel.position);
    try std.testing.expectEqual(z.Point{ .x = 0, .y = 24 }, seen.events[1].wheel.delta);
    try std.testing.expectEqual(z.Point{ .x = 3, .y = 2 }, seen.events[2].pointer_down.position);

    // Unzoomed, events pass as they are.
    try window.setZoom(1);
    seen.count = 0;
    item.emit(.{ .pointer_move = .{ .x = 40, .y = 20 } });
    try std.testing.expectEqual(z.Point{ .x = 40, .y = 20 }, seen.events[0].pointer_move);
    try std.testing.expectEqual(z.Rect{ .x = 2, .y = 4, .width = 6, .height = 8 }, z.zoomRect(.{ .x = 1, .y = 2, .width = 3, .height = 4 }, 2));
}
