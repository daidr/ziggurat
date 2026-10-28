const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_damage_clear(*anyopaque) void;
extern fn zlg_damage_read(*anyopaque, *[4]c_int) c_int;

fn clear(window: z.Window) void {
    if (builtin.os.tag == .windows) {
        std.debug.assert(c.ValidateRect(@ptrCast(window.nativeHandle()), null) != 0);
    } else zlg_damage_clear(window.nativeHandle().?);
}
fn read(window: z.Window) ?[4]c_int {
    var bounds: [4]c_int = undefined;
    if (builtin.os.tag == .windows) {
        var rect: c.RECT = undefined;
        if (c.GetUpdateRect(@ptrCast(window.nativeHandle()), &rect, c.FALSE) == 0) return null;
        bounds = .{ rect.left, rect.top, rect.right, rect.bottom };
        std.debug.assert(c.ValidateRect(@ptrCast(window.nativeHandle()), null) != 0);
    } else if (zlg_damage_read(window.nativeHandle().?, &bounds) == 0) return null;
    return bounds;
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    const window = try app.createWindow(.{ .width = 160, .height = 100 });
    try window.setClientBounds(.{ .position = .{ .x = -16000, .y = -16000 }, .width = 160, .height = 100 });
    try window.perform(.show);
    const scale: f64 = if (builtin.os.tag == .windows) @as(f64, @floatFromInt(c.GetDpiForWindow(@ptrCast(window.nativeHandle())))) / 96 else 1;
    clear(window);
    try std.testing.expect(read(window) == null);
    try window.invalidateRect(.{ .x = 2.25, .y = 3.5, .width = 10.5, .height = 7.25 });
    const expected = [_]c_int{ @intFromFloat(@floor(2.25 * scale)), @intFromFloat(@floor(3.5 * scale)), @intFromFloat(@ceil(12.75 * scale)), @intFromFloat(@ceil(10.75 * scale)) };
    try std.testing.expectEqualDeep(expected, read(window).?);
    try window.invalidateRect(.{ .x = -5, .y = -4, .width = 8.25, .height = 9.5 });
    try window.invalidateRect(.{ .x = 20, .y = 15, .width = 3, .height = 2 });
    try std.testing.expectEqualDeep([_]c_int{ 0, 0, @intFromFloat(@ceil(23 * scale)), @intFromFloat(@ceil(17 * scale)) }, read(window).?);
    try window.invalidateRect(.{ .x = 1_000_000, .y = 1_000_000, .width = 1, .height = 1 });
    try window.invalidateRect(.{ .x = 0, .y = 0, .width = 0, .height = 20 });
    try std.testing.expectError(error.InvalidGeometry, window.invalidateRect(.{ .x = 0, .y = 0, .width = -1, .height = 20 }));
    try std.testing.expect(read(window) == null);
    const scope = window.beginCallback().?;
    _ = try window.destroy();
    try std.testing.expectError(error.Closed, window.invalidateRect(.{ .x = 0, .y = 0, .width = 20, .height = 20 }));
    scope.end();
    try app.dispatch();
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
    app.deinit();
    std.debug.print("local damage: fractional DIP, clip, coalescing, empty/invalid and closing passed\n", .{});
}
