const std = @import("std");
const z = @import("root.zig");

test "caller recorder survives App allocation failure and validation has no stale code" {
    var recorder: z.diagnostics.Recorder(4) = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, z.App.initWithOptions(failing.allocator(), .{ .diagnostics_sink = recorder.sink() }));
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .diagnostics_sink = recorder.sink() });
    defer app.deinit();
    app.last_native_error = 123;
    app.native_failure = .{ .domain = .win32, .code = 456 };
    try std.testing.expectError(error.InvalidSize, app.createWindow(.{ .width = 0 }));
    var entries: [4]z.diagnostics.Diagnostic = undefined;
    const snapshot = recorder.snapshot(&entries);
    try std.testing.expectEqual(2, snapshot.count);
    try std.testing.expectEqual(error.OutOfMemory, entries[0].err.?);
    try std.testing.expectEqual(z.diagnostics.Operation.app_init, entries[0].operation);
    try std.testing.expectEqual(error.InvalidSize, entries[1].err.?);
    try std.testing.expect(entries[0].code == null and entries[1].code == null);
}

test "diagnostic callback destruction is deferred and recursive reporting is bounded" {
    const State = struct {
        window: ?z.Window = null,
        calls: usize = 0,
        result: ?z.CloseResult = null,
        fn emit(ptr: *anyopaque, _: z.diagnostics.Diagnostic) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            const window = self.window.?;
            window.report(.{ .domain = .core, .operation = .paint });
            self.result = window.destroy() catch unreachable;
        }
    };
    var state: State = .{};
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.emit } });
    defer app.deinit();
    const window = try app.createWindow(.{});
    state.window = window;
    window.report(.{ .domain = .renderer, .operation = .paint, .err = error.DrawFailed });
    try std.testing.expectEqual(1, state.calls);
    try std.testing.expectEqual(z.CloseResult.deferred, state.result.?);
    try std.testing.expectEqual(1, app.resourceStats().allocated_records);
    try app.dispatch();
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
}

test "backend code retains namespace and generation when destroy rolls back" {
    var recorder: z.diagnostics.Recorder(2) = .{};
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .diagnostics_sink = recorder.sink() });
    defer app.deinit();
    const window = try app.createWindow(.{});
    app.native.fail_destroy = true;
    try std.testing.expectError(error.DestroyWindowFailed, window.destroy());
    var entries: [2]z.diagnostics.Diagnostic = undefined;
    const snapshot = recorder.snapshot(&entries);
    try std.testing.expectEqual(1, snapshot.count);
    try std.testing.expectEqualDeep(window.diagnosticId(), entries[0].window.?);
    try std.testing.expect(entries[0].code == null);
    try std.testing.expect(!window.isClosed());
    _ = try window.destroy();
}
