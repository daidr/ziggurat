const std = @import("std");
const z = @import("root.zig");

test "window snapshots are transactional and runtime lookup excludes closing generations" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const first = try app.createWindow(.{});
    const second = try app.createWindow(.{});
    const identity = first.diagnosticId();
    var small = [_]z.Window{first};
    try std.testing.expectError(error.OutputTooSmall, app.listWindows(&small));
    try std.testing.expectEqual(first, small[0]);
    var storage: [3]z.Window = undefined;
    const snapshot = try app.listWindows(&storage);
    try std.testing.expectEqual(2, snapshot.len);
    try std.testing.expectEqual(first, app.findWindow(identity).?);
    const callback = first.beginCallback().?;
    try std.testing.expectEqual(z.CloseResult.deferred, try first.destroy());
    try std.testing.expect(app.findWindow(identity) == null);
    try std.testing.expectEqual(1, (try app.listWindows(&storage)).len);
    try std.testing.expectEqual(second, storage[0]);
    callback.end();
    try app.dispatch();
    const replacement = try app.createWindow(.{});
    try std.testing.expectEqual(identity.index, replacement.key.index);
    try std.testing.expect(replacement.key.generation != identity.generation);
    try std.testing.expect(app.findWindow(identity) == null);
    try std.testing.expect(first.isClosed());
    try std.testing.expectEqual(replacement, app.findWindow(replacement.diagnosticId()).?);
    _ = try replacement.destroy();
    _ = try second.destroy();
    try std.testing.expectEqual(0, (try app.listWindows(&storage)).len);
}

test "snapshot iteration permits explicit close and replacement without retained native pointers" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var storage: [8]z.Window = undefined;
    for (0..storage.len) |_| _ = try app.createWindow(.{});
    const snapshot = try app.listWindows(&storage);
    for (snapshot) |window| {
        const identity = window.diagnosticId();
        _ = try window.destroy();
        const replacement = try app.createWindow(.{});
        try std.testing.expect(app.findWindow(identity) == null);
        try std.testing.expectEqual(replacement, app.findWindow(replacement.diagnosticId()).?);
    }
    // All stored handles belong to the old generations, even when slots reuse.
    for (snapshot) |window| try std.testing.expect(window.isClosed());
    const active = try app.listWindows(&storage);
    try std.testing.expectEqual(8, active.len);
    for (active) |window| _ = try window.destroy();
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
}
