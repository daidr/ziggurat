const std = @import("std");
const profile = @import("profile");
extern fn test_cookies_init_gtk() c_int;
extern fn test_cookies_native(*anyopaque) c_int;
const Fixture = struct {
    path: []const u8,
    main: std.Thread.Id,
    prepared: ?profile.storage.Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Fixture) void {
        self.prepared = profile.storage.Prepared.prepare(std.testing.allocator, self.main, self.path, .{}) catch |err| {
            self.failure = err;
            return;
        };
        self.prepared.?.handoff() catch |err| {
            self.failure = err;
        };
    }
};
test "native cookie owner malloc failures and synchronous completion keep physical pins" {
    const base = std.posix.getenv("ZIGGURAT_PROFILE_TEST_ROOT") orelse return error.MissingProfileTestRoot;
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/native-cookies-{d}", .{ base, std.time.nanoTimestamp() });
    defer std.testing.allocator.free(path);
    var fixture: Fixture = .{ .path = path, .main = std.Thread.getCurrentId() };
    const worker = try std.Thread.spawn(.{}, Fixture.worker, .{&fixture});
    worker.join();
    if (fixture.failure) |err| return err;
    try fixture.prepared.?.adopt();
    defer fixture.prepared.?.close() catch unreachable;
    try std.testing.expect(test_cookies_init_gtk() != 0);
    const owner = try profile.Profile.create(std.testing.allocator, fixture.main, &fixture.prepared.?, .{});
    errdefer owner.close() catch unreachable;
    try std.testing.expectEqual(@as(c_int, 0), test_cookies_native(owner.native.?));
    try std.testing.expectEqual(@as(u32, 0), (try owner.stats()).contexts);
    try std.testing.expectEqual(@as(u32, 0), (try owner.stats()).leases);
    try owner.close();
    try std.testing.expectEqual(@as(u32, 0), profile.nativeCounts().profiles);
}
