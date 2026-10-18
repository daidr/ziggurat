const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");

fn event(_: *anyopaque, _: *web.View, _: web.Event) void {}
fn candidate(allocator: std.mem.Allocator, app: *z.App) !void {
    var context: u8 = 0;
    var session = web.PageSession.init(allocator, &context, event);
    session.open(app, .{ .page = .{ .html = "candidate", .storage = .ephemeral, .user_agent = "Session prepare" }, .initial_size = .{ .width = 100_000, .height = 100_000 } }) catch |err| {
        try std.testing.expect(session.phase == .closed and session.page.config == null and session.page.native == null);
        try std.testing.expect(app.resourceStats().stop_participants == 0 and app.resourceStats().allocated_records == 0);
        try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, web.resourceCounts());
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.NativeGeometryNotApplied, err);
        return;
    };
    _ = try session.close();
    return error.ExpectedGeometryFailure;
}
pub fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    try std.testing.checkAllAllocationFailures(allocator, candidate, .{app});
    std.debug.print("Linux Session prepare: exact geometry failure and every host allocation failure roll back native/config/stop ownership, no window records\n", .{});
}
