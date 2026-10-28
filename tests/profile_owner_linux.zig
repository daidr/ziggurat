const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const profile = @import("profile");
const storage = profile.storage;

const Fixture = struct {
    prepared: ?storage.Prepared = null,
    main: std.Thread.Id,
    path: [:0]const u8,
    err: ?anyerror = null,

    fn prepare(self: *Fixture) void {
        self.prepared = storage.Prepared.prepare(std.testing.allocator, self.main, self.path, .{}) catch |err| {
            self.err = err;
            return;
        };
        self.prepared.?.handoff() catch |err| {
            self.err = err;
        };
    }
    fn open(self: *Fixture, path: [:0]const u8) !void {
        self.* = .{ .main = std.Thread.getCurrentId(), .path = path };
        const worker = try std.Thread.spawn(.{}, prepare, .{self});
        worker.join();
        if (self.err) |err| return err;
        try self.prepared.?.adopt();
    }
};
fn rootPath(allocator: std.mem.Allocator, suffix: []const u8) ![:0]u8 {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const base = zio.getenv("ZIGGURAT_PROFILE_TEST_ROOT") orelse return error.MissingProfileTestRoot;
    // A newly named child preserves every previous run's diagnostic files.
    const run = try std.fmt.allocPrint(allocator, "{s}/owner-{d}-{s}", .{ base, zio.nanoTimestamp(), suffix });
    defer allocator.free(run);
    return allocator.dupeSentinel(u8, run, 0);
}
fn initGtk() !void {
    if (test_profile_init_gtk() == 0) return error.NativeGtkInitializationFailed;
}
extern fn test_profile_init_gtk() c_int;
extern fn test_profile_native(c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8) c_int;
extern fn test_profile_retain_context(*anyopaque) *anyopaque;
extern fn test_profile_drop_native(*anyopaque) void;
extern fn test_profile_lock_busy([*:0]const u8) c_int;

test "native shared manager and independent contexts preserve physical capacity through late refs" {
    const path = try rootPath(std.testing.allocator, "native");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = undefined;
    try fixture.open(path);
    defer fixture.prepared.?.close() catch unreachable;
    {
        const lease = try fixture.prepared.?.acquire();
        defer lease.release() catch unreachable;
        const paths = try lease.paths();
        try std.testing.expectEqual(@as(c_int, 0), test_profile_native(try lease.borrowLockDescriptor(), paths.data, paths.cache, paths.cookies));
    }
    try fixture.prepared.?.close();
    try std.testing.expectEqual(@as(c_int, 0), test_profile_lock_busy(path));
}

test "Profile release leaves native-only lock lease until actual context finalization" {
    const path = try rootPath(std.testing.allocator, "late");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = undefined;
    try fixture.open(path);
    try initGtk();
    const owner = try profile.Profile.create(std.testing.allocator, fixture.main, &fixture.prepared.?, .{});
    var context = try owner.borrowContext();
    const native = test_profile_retain_context(try context.webContext());
    try owner.close();
    try std.testing.expectError(error.ProfileStorageAlreadyClaimed, profile.Profile.create(std.testing.allocator, fixture.main, &fixture.prepared.?, .{}));
    try fixture.prepared.?.close();
    try context.close();
    try context.close();
    try std.testing.expectError(error.Closed, context.webContext());
    try std.testing.expectEqual(@as(c_int, 1), test_profile_lock_busy(path));
    try std.testing.expectEqual(@as(u32, 1), profile.nativeCounts().profiles);
    var blocked: Fixture = undefined;
    try std.testing.expectError(error.ProfileStorageInUse, blocked.open(path));
    test_profile_drop_native(native);
    try std.testing.expectEqual(@as(u32, 0), profile.nativeCounts().profiles);
    try std.testing.expectEqual(@as(usize, 0), profile.nativeCounts().bytes);
    try std.testing.expectEqual(@as(c_int, 0), test_profile_lock_busy(path));
    try blocked.open(path);
    try blocked.prepared.?.close();
}

const ReentryAllocator = struct {
    backing: std.mem.Allocator,
    prepared: ?*storage.Prepared = null,
    owner: ?*profile.Profile = null,
    in_callback: bool = false,
    blocked: bool = false,
    withdrawn: bool = false,
    allocations: usize = 0,
    frees: usize = 0,
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn allocator(self: *ReentryAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *ReentryAllocator = @ptrCast(@alignCast(ptr));
        if (self.prepared) |prepared| {
            if (prepared.close()) self.blocked = false else |err| self.blocked = err == error.ProfileStorageLeasesAlive;
        }
        self.allocations += 1;
        return self.backing.rawAlloc(len, alignment, address);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const self: *ReentryAllocator = @ptrCast(@alignCast(ptr));
        return self.backing.rawResize(bytes, alignment, len, address);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *ReentryAllocator = @ptrCast(@alignCast(ptr));
        return self.backing.rawRemap(bytes, alignment, len, address);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *ReentryAllocator = @ptrCast(@alignCast(ptr));
        if (self.owner) |owner| if (!self.in_callback) {
            self.in_callback = true;
            self.withdrawn = owner.native == null;
            if (owner.close()) self.blocked = false else |err| self.blocked = err == error.Busy;
            self.in_callback = false;
        };
        self.frees += 1;
        self.backing.rawFree(bytes, alignment, address);
    }
};
test "Profile pins preparation before caller allocation and withdraws before final caller free" {
    const path = try rootPath(std.testing.allocator, "reentry");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = undefined;
    try fixture.open(path);
    defer fixture.prepared.?.close() catch unreachable;
    try initGtk();
    var reentry: ReentryAllocator = .{ .backing = std.testing.allocator, .prepared = &fixture.prepared.? };
    const owner = try profile.Profile.create(reentry.allocator(), fixture.main, &fixture.prepared.?, .{});
    try std.testing.expect(reentry.blocked);
    reentry.prepared = null;
    reentry.owner = owner;
    try owner.close();
    reentry.owner = null;
    try std.testing.expect(reentry.blocked and reentry.withdrawn);
    try std.testing.expectEqual(@as(usize, 1), reentry.allocations);
    try std.testing.expectEqual(@as(usize, 1), reentry.frees);
    try std.testing.expectEqual(@as(u32, 0), profile.nativeCounts().profiles);
}

test "Profile capacity allocation failure and seal are explicit and preserve preparation" {
    const path = try rootPath(std.testing.allocator, "failures");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = undefined;
    try fixture.open(path);
    defer fixture.prepared.?.close() catch unreachable;
    try initGtk();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, profile.Profile.create(failing.allocator(), fixture.main, &fixture.prepared.?, .{}));
    try std.testing.expectEqual(@as(usize, 0), (try fixture.prepared.?.stats()).active_leases);
    const owner = try profile.Profile.create(std.testing.allocator, fixture.main, &fixture.prepared.?, .{ .contexts = 1 });
    const metadata_bytes = (try owner.stats()).owned_bytes;
    var context = try owner.borrowContext();
    try std.testing.expectError(error.Full, owner.borrowContext());
    try owner.seal();
    try std.testing.expect(!(try owner.stats()).accepting);
    try std.testing.expectError(error.Closed, context.webContext());
    try std.testing.expectError(error.Closed, owner.borrowContext());
    try owner.close();
    try context.close();
    try std.testing.expectEqual(@as(u32, 0), profile.nativeCounts().profiles);
    try std.testing.expectError(error.ProfileStorageAlreadyClaimed, profile.Profile.create(std.testing.allocator, fixture.main, &fixture.prepared.?, .{}));
    try fixture.prepared.?.close();
    try fixture.open(path);
    const bounded = try profile.Profile.create(std.testing.allocator, fixture.main, &fixture.prepared.?, .{ .bytes = metadata_bytes });
    try std.testing.expectError(error.CapacityExceeded, bounded.borrowContext());
    try bounded.close();
    try std.testing.expectEqual(@as(u32, 0), profile.nativeCounts().profiles);
}

test "Profile and Context reject foreign owner threads before native access" {
    const path = try rootPath(std.testing.allocator, "threads");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = undefined;
    try fixture.open(path);
    defer fixture.prepared.?.close() catch unreachable;
    try initGtk();
    const owner = try profile.Profile.create(std.testing.allocator, fixture.main, &fixture.prepared.?, .{});
    defer owner.close() catch unreachable;
    var context = try owner.borrowContext();
    defer context.close() catch unreachable;
    const Foreign = struct {
        fn run(value: *profile.Profile, ctx: *profile.Context) void {
            std.testing.expectError(error.WrongThread, value.stats()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.borrowContext()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.seal()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.close()) catch unreachable;
            std.testing.expectError(error.WrongThread, ctx.webContext()) catch unreachable;
            std.testing.expectError(error.WrongThread, ctx.close()) catch unreachable;
        }
    };
    const worker = try std.Thread.spawn(.{}, Foreign.run, .{ owner, &context });
    worker.join();
    try std.testing.expect((try owner.stats()).accepting);
    _ = try context.webContext();
}

test "only admitted Contexts survive seal and C-only config refs retain the final lock" {
    const path = try rootPath(std.testing.allocator, "admit");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = undefined;
    try fixture.open(path);
    try initGtk();
    const owner = try profile.Profile.create(std.testing.allocator, fixture.main, &fixture.prepared.?, .{ .contexts = 2, .leases = 2 });
    var one = try owner.retainConfig();
    var two = try owner.retainConfig();
    try std.testing.expectError(error.Full, owner.retainConfig());
    var ordinary = try one.context();
    var admitted = try two.context();
    try admitted.admit();
    try std.testing.expectError(error.InvalidProfile, admitted.admit());
    try std.testing.expectError(error.Full, one.context());
    try owner.seal();
    try std.testing.expectError(error.Closed, one.check());
    try std.testing.expectError(error.Closed, one.context());
    try std.testing.expectError(error.Closed, ordinary.admit());
    try std.testing.expectError(error.Closed, ordinary.webContext());
    _ = try admitted.webContext();
    try owner.close();
    _ = try admitted.webContext();
    try fixture.prepared.?.close();
    try ordinary.close();
    try admitted.close();
    try std.testing.expectEqual(@as(u32, 1), profile.nativeCounts().profiles);
    try std.testing.expectEqual(@as(u32, 0), profile.nativeCounts().contexts);
    try std.testing.expectEqual(@as(c_int, 1), test_profile_lock_busy(path));
    try one.release();
    try one.release();
    try std.testing.expectEqual(@as(u32, 1), profile.nativeCounts().profiles);
    try two.release();
    try std.testing.expectEqual(@as(u32, 0), profile.nativeCounts().profiles);
    try std.testing.expectEqual(@as(c_int, 0), test_profile_lock_busy(path));
}

test "native construction consumes its epoch even when the enclosing owner is not published" {
    const path = try rootPath(std.testing.allocator, "unpublished");
    defer std.testing.allocator.free(path);
    var fixture: Fixture = undefined;
    try fixture.open(path);
    try initGtk();
    var construction = try profile.Construction.begin(&fixture.prepared.?, .{}, @sizeOf(profile.Profile));
    var unpublished: profile.Profile = .{ .allocator = std.testing.allocator, .owner = fixture.main, .native = try construction.createNative(null) };
    var context = try unpublished.borrowContext();
    const retained = test_profile_retain_context(try context.webContext());
    // An outer validation error now unwinds native storage and then attempts
    // abort. It must not reopen the same OFD for a second manager.
    try unpublished.releaseNative();
    try context.close();
    construction.abort();
    try std.testing.expectError(error.ProfileStorageAlreadyClaimed, fixture.prepared.?.claimNativeOwner());
    try fixture.prepared.?.close();
    var blocked: Fixture = undefined;
    try std.testing.expectError(error.ProfileStorageInUse, blocked.open(path));
    test_profile_drop_native(retained);
    try blocked.open(path);
    try blocked.prepared.?.close();
    try std.testing.expectEqual(@as(u32, 0), profile.nativeCounts().profiles);
}

test {
    _ = profile;
}
