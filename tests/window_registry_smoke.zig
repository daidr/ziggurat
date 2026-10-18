const std = @import("std");
const z = @import("ziggurat");

pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    const app = try z.App.init(allocations.allocator());
    defer app.deinit();
    var windows: [3]z.Window = undefined;
    for (0..100) |_| {
        for (&windows) |*window| window.* = try app.createWindow(.{});
        const identity = windows[0].diagnosticId();
        var snapshot: [3]z.Window = undefined;
        try std.testing.expectEqual(3, (try app.listWindows(&snapshot)).len);
        for (snapshot) |window| try std.testing.expectEqual(window, app.findWindow(window.diagnosticId()).?);
        const pin = windows[0].beginCallback().?;
        _ = try windows[0].destroy();
        try std.testing.expect(app.findWindow(identity) == null);
        try std.testing.expectEqual(2, (try app.listWindows(&snapshot)).len);
        pin.end();
        try app.dispatch();
        windows[0] = try app.createWindow(.{});
        try std.testing.expect(app.findWindow(identity) == null);
        try std.testing.expectEqual(windows[0], app.findWindow(windows[0].diagnosticId()).?);
        for (windows) |window| _ = try window.destroy();
        try app.dispatch();
        try std.testing.expectEqual(0, (try app.listWindows(&snapshot)).len);
        try std.testing.expectEqual(0, app.resourceStats().allocated_records);
        try std.testing.expectEqual(3, app.resourceStats().registry_slots);
    }
    std.debug.print("window registry: 400 native windows, bounded open snapshots, closing/stale lookup rejected, records=0 slots=3\n", .{});
}
