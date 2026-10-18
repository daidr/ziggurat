const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
extern fn zwk_session_park(*anyopaque, u64) c_int;
extern fn zwk_session_size(*anyopaque, *u32, *u32) c_int;
extern fn zlg_region_count() c_uint;
fn event(_: *anyopaque, _: *web.View, _: web.Event) void {}
fn observed(session: *web.PageSession) !web.PageSession.PixelSize {
    var actual: web.PageSession.PixelSize = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zwk_session_size(session.page.native.?, &actual.width, &actual.height));
    return actual;
}
fn extent(start: f32, length: f32, scale: f32) u32 {
    const physical_first = @round(@as(f64, start) * scale);
    const physical_last = @round((@as(f64, start) + length) * scale);
    return @intFromFloat((@ceil(physical_last / scale) - @floor(physical_first / scale)) * scale);
}
pub fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 400, .height = 280 });
    const scale = (try window.contentSize()).scale;
    var context: u8 = 0;
    var invalid = web.PageSession.init(allocator, &context, event);
    try std.testing.expectError(error.InvalidViewport, invalid.open(app, .{ .page = .{ .html = "invalid", .storage = .ephemeral }, .initial_size = .{ .width = 0, .height = 1 } }));
    try std.testing.expect(invalid.phase == .closed and app.resourceStats().stop_participants == 0);
    if (scale > 1) {
        var unrepresentable = web.PageSession.init(allocator, &context, event);
        try std.testing.expectError(error.NativeGeometryNotApplied, unrepresentable.open(app, .{ .page = .{ .html = "not rounded", .storage = .ephemeral }, .initial_size = .{ .width = @as(u32, @intFromFloat(scale)) + 1, .height = 20 } }));
        try std.testing.expect(unrepresentable.phase == .closed and unrepresentable.page.native == null and app.resourceStats().stop_participants == 0);
    }
    const owner = try z.composition.Owner.create(allocator, window, .{ .capacity = 2 });
    defer {
        owner.detach() catch {};
        owner.close() catch unreachable;
    }
    var session = web.PageSession.init(allocator, &context, event);
    try session.open(app, .{ .page = .{ .html = "geometry", .storage = .ephemeral } });
    defer _ = session.close() catch unreachable;
    const native = session.page.native;
    const too_large: z.composition.Viewport = .{ .bounds = .{ .x = 1, .y = 2, .width = 100_000, .height = 20 } };
    const rejected = try owner.reserve(too_large);
    try std.testing.expectError(error.InvalidNativeArgument, session.attachRegion(rejected));
    try std.testing.expect(session.currentRegion() == null and session.page.native == native and session.page.window == null and zlg_region_count() == 0);
    try std.testing.expectEqualDeep(too_large, (try rejected.snapshot()).viewport);
    try std.testing.expect(try rejected.remove());

    const viewport: z.composition.Viewport = .{ .bounds = .{ .x = -3.25, .y = 7.5, .width = 20.5, .height = 14.75 } };
    const region = try owner.reserve(viewport);
    try session.attachRegion(region);
    const expected: web.PageSession.PixelSize = .{ .width = extent(viewport.bounds.x, viewport.bounds.width, scale), .height = extent(viewport.bounds.y, viewport.bounds.height, scale) };
    try std.testing.expectEqualDeep(expected, try observed(&session));
    try std.testing.expectEqualDeep(expected, session.last_size);
    const hosts = zlg_region_count();
    try std.testing.expect(hosts != 0);
    // The private physical adapter must reject an old attachment even when the
    // public Session/Region still owns a current mount. No newer state changes.
    try std.testing.expectEqual(@as(c_int, 4), zwk_session_park(native.?, session.attachment_epoch - 1));
    try std.testing.expectEqualDeep(expected, try observed(&session));
    try std.testing.expectEqual(hosts, zlg_region_count());
    try std.testing.expectError(error.InvalidNativeArgument, region.update(too_large));
    try std.testing.expectEqualDeep(viewport, (try region.snapshot()).viewport);
    try std.testing.expectEqualDeep(expected, try observed(&session));
    try std.testing.expectEqualDeep(expected, session.last_size);

    try session.park();
    try std.testing.expectError(error.Closed, region.snapshot());
    try std.testing.expectEqual(@as(c_uint, 0), zlg_region_count());
    try std.testing.expectEqualDeep(expected, try observed(&session));
    const replacement = try owner.reserve(viewport);
    const epoch = session.attachment_epoch;
    session.attachment_epoch = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, session.attachRegion(replacement));
    try std.testing.expect(session.region == null and session.page.native == native);
    session.attachment_epoch = epoch;
    try session.attachRegion(replacement);
    try std.testing.expectEqual(epoch + 1, session.attachment_epoch);
    try std.testing.expectEqualDeep(expected, try observed(&session));
    try std.testing.expectEqual(web.PageSession.CloseResult.closed, try session.close());
    try std.testing.expect(zlg_region_count() == 0 and app.resourceStats().stop_participants == 0);
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, web.resourceCounts());
    std.debug.print("Linux Session geometry: invalid/exact-size preparation, negative/fractional edges, rejected attach/update preserve ownership, stale epoch and nonwrapping rehost, resources=0\n", .{});
}
