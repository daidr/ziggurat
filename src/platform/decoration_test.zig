const std = @import("std");
const z = @import("../root.zig");

const HitProbe = struct {
    calls: usize = 0,
    action: enum { caption, recurse, maximize, close } = .caption,
    closed: bool = false,
    fn query(ptr: *anyopaque, window: z.Window, point: z.Point) z.WindowHit {
        const self: *HitProbe = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        switch (self.action) {
            .caption => return if (point.y < 32) .caption else .client,
            .recurse => std.debug.assert((window.hitTest(point) catch unreachable) == .client),
            .maximize => window.perform(.maximize) catch unreachable,
            .close => {
                std.debug.assert((window.destroy() catch unreachable) == .deferred);
                std.debug.assert(!self.closed);
            },
        }
        return .south;
    }
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *HitProbe = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};
test "custom hit regions reserve DIP edges, suppress invalid states, bound reentry and pin close" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(failing.allocator());
    defer app.deinit();
    var probe: HitProbe = .{};
    const handler: z.HitTestHandler = .{ .context = &probe, .query = HitProbe.query };
    try std.testing.expectError(error.InvalidWindowDecoration, app.createWindow(.{ .hit_test = handler }));
    try std.testing.expectError(error.InvalidGeometry, app.createWindow(.{ .resize_border = std.math.nan(f32) }));
    const window = try app.createWindow(.{ .width = 200, .height = 100, .decoration = .custom, .hit_test = handler, .on_closed = .{ .context = &probe, .notify = HitProbe.notify } });
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqual(z.WindowHit.north_west, try window.hitTest(.{ .x = 2, .y = 2 }));
    try std.testing.expectEqual(z.WindowHit.south_east, try window.hitTest(.{ .x = 199, .y = 99 }));
    try std.testing.expectEqual(z.WindowHit.caption, try window.hitTest(.{ .x = 60, .y = 20 }));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try window.perform(.disable);
    try std.testing.expectEqual(z.WindowHit.client, try window.hitTest(.{ .x = 2, .y = 2 }));
    try window.perform(.enable);
    probe.action = .recurse;
    try std.testing.expectEqual(z.WindowHit.south, try window.hitTest(.{ .x = 60, .y = 60 }));
    probe.action = .maximize;
    try std.testing.expectEqual(z.WindowHit.client, try window.hitTest(.{ .x = 60, .y = 60 }));
    try window.perform(.restore);
    probe.action = .close;
    try std.testing.expectEqual(z.WindowHit.client, try window.hitTest(.{ .x = 60, .y = 60 }));
    try std.testing.expect(!probe.closed);
    try app.dispatch();
    try std.testing.expect(probe.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
test "native gesture ownership, capability, failure and modal policy are checked before side effects" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const owner = try app.createWindow(.{ .decoration = .borderless });
    try std.testing.expectError(error.InvalidWindowState, owner.startMove());
    try owner.perform(.show);
    try std.testing.expectError(error.InvalidGesture, owner.startMove());
    const record = app.windows.get(owner.key).?;
    record.native.gesture_active = true;
    app.native.fail_update = true;
    try std.testing.expectError(error.WindowUpdateFailed, owner.startMove());
    try std.testing.expect(!record.native.gesture_used);
    try owner.startResize(.east);
    try std.testing.expectEqual(z.ResizeEdge.east, record.native.last_resize.?);
    try std.testing.expectError(error.InvalidGesture, owner.startMove());
    const count = record.native.interactions;
    record.native.gesture_used = false;
    record.native.caps.native_move_resize = false;
    try std.testing.expectError(error.UnsupportedCapability, owner.startMove());
    record.native.caps.native_move_resize = true;
    const modal = try app.createWindow(.{ .owner = owner, .modal = true });
    try modal.perform(.show);
    try std.testing.expectError(error.ModalBlocked, owner.startResize(.south));
    try std.testing.expectEqual(count, record.native.interactions);
    _ = try modal.destroy();
    try owner.perform(.disable);
    try std.testing.expectError(error.Disabled, owner.startMove());
    try std.testing.expect(!(try owner.capabilities()).transparent and !(try owner.capabilities()).backdrop_material);
    _ = try owner.destroy();
}
test "backdrop material is capability gated, update guarded and failure reported without state" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const record = app.windows.get(window.key).?;
    try std.testing.expectError(error.UnsupportedCapability, window.setBackdrop(.mica));
    try std.testing.expectEqual(z.WindowBackdrop.system, record.native.backdrop);
    record.native.caps.backdrop_material = true;
    try window.setBackdrop(.acrylic);
    try std.testing.expectEqual(z.WindowBackdrop.acrylic, record.native.backdrop);
    app.native.fail_update = true;
    try std.testing.expectError(error.WindowUpdateFailed, window.setBackdrop(.none));
    try std.testing.expectEqual(z.WindowBackdrop.acrylic, record.native.backdrop);
    try std.testing.expectEqual(@as(u32, 5), app.last_native_error);
    record.window_update_busy = true;
    try std.testing.expectError(error.Busy, window.setBackdrop(.system));
    record.window_update_busy = false;
    try window.setBackdrop(.system);
    _ = try window.destroy();
    try std.testing.expectError(error.Closed, window.setBackdrop(.mica));
}
