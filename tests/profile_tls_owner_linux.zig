const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile");
const certificate = @embedFile("fixtures/profile-https/server-cert.pem");
extern fn test_profile_init_gtk() c_int;
extern fn test_profile_retain_context(*anyopaque) *anyopaque;
extern fn test_profile_drop_native(*anyopaque) void;
extern fn zwk_profile_test_fail_after(c_int) void;

const Fixture = struct {
    allocator: std.mem.Allocator,
    main: std.Thread.Id,
    path: []const u8,
    prepared: ?profile.storage.Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Fixture) void {
        self.prepared = profile.storage.Prepared.prepare(self.allocator, self.main, self.path, .{}) catch |err| {
            self.failure = err;
            return;
        };
        self.prepared.?.handoff() catch |err| {
            self.failure = err;
        };
    }
    fn open(self: *Fixture) !void {
        if (builtin.os.tag != .linux) return error.SkipZigTest;
        if (test_profile_init_gtk() == 0) return error.NativeGtkInitializationFailed;
        const worker_thread = try std.Thread.spawn(.{}, worker, .{self});
        worker_thread.join();
        if (self.failure) |err| return err;
        try self.prepared.?.adopt();
    }
};
fn pathFor(suffix: []const u8) ![]u8 {
    const base = std.posix.getenv("ZIGGURAT_PROFILE_TEST_ROOT") orelse return error.MissingProfileTestRoot;
    return std.fmt.allocPrint(std.testing.allocator, "{s}/tls-owner-{d}-{s}", .{ base, std.time.nanoTimestamp(), suffix });
}

test "native TLS parser preserves real GLib failure and failed candidate preserves claim" {
    const path = try pathFor("parser");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = .{ .allocator = std.testing.allocator, .main = std.Thread.getCurrentId(), .path = path };
    try fixture.open();
    defer fixture.prepared.?.close() catch unreachable;
    var failure: ?profile.Failure = null;
    try std.testing.expectError(error.InvalidTlsCertificate, profile.Profile.createWithOptionsAndFailure(std.testing.allocator, fixture.main, &fixture.prepared.?, .{ .loopback_https = .{ .certificate_pem = "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n" } }, &failure));
    try std.testing.expect(failure != null and failure.? == .glib and failure.?.glib.domain != 0);
    try std.testing.expectEqual(profile.NativeCounts{}, profile.nativeCounts());
    const owner = try profile.Profile.createWithOptions(std.testing.allocator, fixture.main, &fixture.prepared.?, .{ .loopback_https = .{ .certificate_pem = certificate } });
    const stats = try owner.stats();
    try std.testing.expectEqual(@sizeOf(profile.tls_policy.Captured), stats.peak_bytes - stats.owned_bytes);
    try owner.close();
    try std.testing.expectEqual(profile.NativeCounts{}, profile.nativeCounts());
}

const InputGate = struct {
    bytes: []u8,
    prepared: *profile.storage.Prepared,
    hit: bool = false,
    fn allocator(self: *InputGate) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *InputGate = @ptrCast(@alignCast(ptr));
        if (!self.hit) {
            self.hit = true;
            @memset(self.bytes, 0);
            std.testing.expectError(error.ProfileStorageLeasesAlive, self.prepared.close()) catch unreachable;
        }
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
};
test "first caller allocation cannot invalidate captured PEM or the prepared claim" {
    const path = try pathFor("capture");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = .{ .allocator = std.testing.allocator, .main = std.Thread.getCurrentId(), .path = path };
    try fixture.open();
    defer fixture.prepared.?.close() catch unreachable;
    var bytes = certificate.*;
    var gate: InputGate = .{ .bytes = &bytes, .prepared = &fixture.prepared.? };
    const owner = try profile.Profile.createWithOptions(gate.allocator(), fixture.main, &fixture.prepared.?, .{ .loopback_https = .{ .certificate_pem = &bytes } });
    try std.testing.expect(gate.hit);
    try owner.close();
    try std.testing.expectEqual(profile.NativeCounts{}, profile.nativeCounts());
}

test "TLS candidate native OOM retains claim and late Context refs retain only native storage" {
    const path = try pathFor("oom");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = .{ .allocator = std.testing.allocator, .main = std.Thread.getCurrentId(), .path = path };
    try fixture.open();
    defer fixture.prepared.?.close() catch unreachable;
    zwk_profile_test_fail_after(0);
    defer zwk_profile_test_fail_after(-1);
    try std.testing.expectError(error.OutOfMemory, profile.Profile.createWithOptions(std.testing.allocator, fixture.main, &fixture.prepared.?, .{ .loopback_https = .{ .certificate_pem = certificate } }));
    try std.testing.expectEqual(profile.NativeCounts{}, profile.nativeCounts());
    zwk_profile_test_fail_after(-1);
    const owner = try profile.Profile.createWithOptions(std.testing.allocator, fixture.main, &fixture.prepared.?, .{ .loopback_https = .{ .certificate_pem = certificate } });
    var context = try owner.borrowContext();
    const late = test_profile_retain_context(try context.webContext());
    try context.close();
    try owner.close();
    try std.testing.expectEqual(@as(u32, 1), profile.nativeCounts().contexts);
    test_profile_drop_native(late);
    try std.testing.expectEqual(profile.NativeCounts{}, profile.nativeCounts());
}

test "capture reservation is checked before caller allocation and a rejected limit leaves claim reusable" {
    const path = try pathFor("budget");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = .{ .allocator = std.testing.allocator, .main = std.Thread.getCurrentId(), .path = path };
    try fixture.open();
    defer fixture.prepared.?.close() catch unreachable;
    try std.testing.expectError(error.CapacityExceeded, profile.Profile.createWithOptions(std.testing.failing_allocator, fixture.main, &fixture.prepared.?, .{ .limits = .{ .bytes = @sizeOf(profile.tls_policy.Captured) }, .loopback_https = .{ .certificate_pem = certificate } }));
    const owner = try profile.Profile.createWithOptions(std.testing.allocator, fixture.main, &fixture.prepared.?, .{ .loopback_https = .{ .certificate_pem = certificate } });
    try owner.close();
    try std.testing.expectEqual(profile.NativeCounts{}, profile.nativeCounts());
}
