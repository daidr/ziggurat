const std = @import("std");
const z = @import("root.zig");

test "local invalidation validates before changing damage and respects handle generation" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const scope = window.beginCallback().?;
    const bounds: z.Rect = .{ .x = -2.25, .y = 10.5, .width = 20, .height = 7.25 };
    try window.invalidateRect(bounds);
    try std.testing.expectEqualDeep(bounds, scope.record.native.damage.?);
    const invalid = [_]z.Rect{
        .{ .x = std.math.nan(f32), .y = 0, .width = 1, .height = 1 },
        .{ .x = 0, .y = 0, .width = std.math.inf(f32), .height = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = -1 },
        .{ .x = 1_000_001, .y = 0, .width = 1, .height = 1 },
    };
    for (invalid) |item| try std.testing.expectError(error.InvalidGeometry, window.invalidateRect(item));
    try window.invalidateRect(.{ .x = 0, .y = 0, .width = 0, .height = 10 });
    try std.testing.expectEqualDeep(bounds, scope.record.native.damage.?);
    _ = try window.destroy();
    try std.testing.expectError(error.Closed, window.invalidateRect(bounds));
    scope.end();
    try app.dispatch();
    const replacement = try app.createWindow(.{});
    try std.testing.expectError(error.Closed, window.invalidateRect(bounds));
    const new_scope = replacement.beginCallback().?;
    try std.testing.expect(new_scope.record.native.damage == null);
    new_scope.end();
    _ = try replacement.destroy();
}

test "local invalidation rejects a worker before geometry or native access" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const Worker = struct {
        fn run(value: z.Window) void {
            std.testing.expectError(error.WrongThread, value.invalidateRect(.{
                .x = std.math.nan(f32),
                .y = 0,
                .width = 1,
                .height = 1,
            })) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{window});
    thread.join();
    _ = try window.destroy();
}

test "failed damage reports no undocumented stale native code and pins diagnostic close" {
    const State = struct {
        window: z.Window = undefined,
        calls: usize = 0,
        fn report(ptr: *anyopaque, diagnostic: z.diagnostics.Diagnostic) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.testing.expectEqual(error.InvalidateFailed, diagnostic.err.?) catch unreachable;
            std.testing.expect(diagnostic.code == null) catch unreachable;
            std.testing.expectEqual(self.window.diagnosticId(), diagnostic.window.?) catch unreachable;
            self.calls += 1;
            std.testing.expectEqual(z.CloseResult.deferred, self.window.destroy() catch unreachable) catch unreachable;
        }
    };
    var state: State = .{};
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.report } });
    defer app.deinit();
    state.window = try app.createWindow(.{});
    app.captureNativeFailure(.win32, 123);
    const scope = state.window.beginCallback().?;
    scope.record.native.fail_damage = true;
    scope.end();
    try std.testing.expectError(error.InvalidateFailed, state.window.invalidateRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
