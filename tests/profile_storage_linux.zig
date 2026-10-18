const std = @import("std");
const builtin = @import("builtin");
const storage = @import("profile_storage");

const Worker = struct {
    allocator: std.mem.Allocator,
    main: std.Thread.Id,
    path: []const u8,
    limits: storage.Limits = .{},
    value: ?storage.Prepared = null,
    failure: ?anyerror = null,
    reclaim: bool = false,

    fn run(self: *@This()) void {
        self.value = storage.Prepared.prepare(self.allocator, self.main, self.path, self.limits) catch |err| {
            self.failure = err;
            return;
        };
        const prepared = &self.value.?;
        std.testing.expectError(error.WrongThread, prepared.adopt()) catch unreachable;
        prepared.handoff() catch unreachable;
        if (self.reclaim) {
            std.testing.expectError(error.ProfileStorageInTransit, prepared.paths()) catch unreachable;
            prepared.reclaim() catch unreachable;
            prepared.close() catch unreachable;
        }
    }
};

fn prepare(allocator: std.mem.Allocator, path: []const u8, limits: storage.Limits) !storage.Prepared {
    var worker: Worker = .{ .allocator = allocator, .main = std.Thread.getCurrentId(), .path = path, .limits = limits };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    var value = worker.value.?;
    try std.testing.expectError(error.WrongThread, value.paths());
    try value.adopt();
    return value;
}

/// File tests are opt-in and retain their directories for diagnosis. Point this
/// at a pre-existing private Linux filesystem directory, not a mounted host FS.
fn newPath(case: []const u8) ![]u8 {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const root = std.process.getEnvVarOwned(std.testing.allocator, "ZIGGURAT_PROFILE_TEST_ROOT") catch |err| return if (err == error.EnvironmentVariableNotFound) error.MissingProfileTestRoot else err;
    defer std.testing.allocator.free(root);
    if (!std.fs.path.isAbsolute(root)) return error.AbsoluteTestRootRequired;
    const result = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}-{x}", .{ root, case, std.crypto.random.int(u64) });
    std.debug.print("profile-storage evidence: {s}\n", .{result});
    return result;
}

fn descriptorCount() !usize {
    var directory = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer directory.close();
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next()) |_| count += 1;
    return count;
}

fn makeRoot(path: []const u8) !void {
    try std.posix.mkdir(path, 0o700);
}

test "private profile directories share one nonblocking lock and retain existing data" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const path = try newPath("shared-配置");
    defer std.testing.allocator.free(path);
    const before = try descriptorCount();
    {
        var prepared = try prepare(std.testing.allocator, path, .{});
        defer prepared.close() catch unreachable;
        const paths = try prepared.paths();
        try std.testing.expectEqual(@as(usize, 5), (try prepared.stats()).native_handles);
        try std.testing.expectEqual(before + 5, try descriptorCount());
        for (prepared.fds) |fd| try std.testing.expect((try std.posix.fcntl(fd, std.posix.F.GETFD, 0)) & std.posix.FD_CLOEXEC != 0);
        try std.testing.expectError(error.ProfileStorageInUse, prepare(std.testing.allocator, path, .{}));
        try std.testing.expectEqual(before + 5, try descriptorCount());
        const lease = try prepared.acquire();
        try std.testing.expectError(error.ProfileStorageLeasesAlive, prepared.close());
        try lease.release();
        const marker = try std.fmt.allocPrint(std.testing.allocator, "{s}/preserved", .{paths.data});
        defer std.testing.allocator.free(marker);
        const file = try std.fs.createFileAbsolute(marker, .{ .mode = 0o600, .exclusive = true });
        try file.writeAll("keep existing data");
        file.close();
    }
    try std.testing.expectEqual(before, try descriptorCount());
    var reopened = try prepare(std.testing.allocator, path, .{});
    defer reopened.close() catch unreachable;
    const marker = try std.fmt.allocPrint(std.testing.allocator, "{s}/preserved", .{(try reopened.paths()).data});
    defer std.testing.allocator.free(marker);
    const file = try std.fs.openFileAbsolute(marker, .{});
    defer file.close();
    var bytes: [32]u8 = undefined;
    const length = try file.readAll(&bytes);
    try std.testing.expectEqualStrings("keep existing data", bytes[0..length]);
}

test "profile root ancestors and fixed children cannot redirect through symlinks" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const target = try newPath("symlink-target");
    defer std.testing.allocator.free(target);
    var original = try prepare(std.testing.allocator, target, .{});
    try original.close();
    const alias = try newPath("symlink-root");
    defer std.testing.allocator.free(alias);
    try std.posix.symlink(target, alias);
    const before = try descriptorCount();
    if (prepare(std.testing.allocator, alias, .{})) |value| {
        var unexpected = value;
        try unexpected.close();
        return error.SymlinkRootAccepted;
    } else |err| try std.testing.expect(err == error.NotDir or err == error.SymLinkLoop);
    const through = try std.fmt.allocPrint(std.testing.allocator, "{s}/child", .{alias});
    defer std.testing.allocator.free(through);
    if (prepare(std.testing.allocator, through, .{})) |value| {
        var unexpected = value;
        try unexpected.close();
        return error.SymlinkAncestorAccepted;
    } else |err| try std.testing.expect(err == error.NotDir or err == error.SymLinkLoop);
    for ([_][]const u8{ "data", "cache", "cookies.sqlite", ".ziggurat-profile.lock" }) |name| {
        const path = try newPath(name);
        defer std.testing.allocator.free(path);
        try makeRoot(path);
        const child = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ path, name });
        defer std.testing.allocator.free(child);
        try std.posix.symlink(target, child);
        if (prepare(std.testing.allocator, path, .{})) |value| {
            var unexpected = value;
            try unexpected.close();
            return error.SymlinkChildAccepted;
        } else |err| try std.testing.expect(err == error.NotDir or err == error.SymLinkLoop);
    }
    try std.testing.expectEqual(before, try descriptorCount());
}

test "profile preparation rejects insecure modes hardlinks and missing ancestors" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const path = try newPath("permissions");
    defer std.testing.allocator.free(path);
    try makeRoot(path);
    var directory = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer directory.close();
    try std.posix.fchmod(directory.fd, 0o755);
    try std.testing.expectError(error.InsecureProfileStoragePermissions, prepare(std.testing.allocator, path, .{}));
    try std.posix.fchmod(directory.fd, 0o700);
    var prepared = try prepare(std.testing.allocator, path, .{});
    const data_path = try std.testing.allocator.dupe(u8, (try prepared.paths()).data);
    defer std.testing.allocator.free(data_path);
    try prepared.close();
    var data = try std.fs.openDirAbsolute(data_path, .{ .iterate = true });
    defer data.close();
    try std.posix.fchmod(data.fd, 0o500);
    try std.testing.expectError(error.InsecureProfileStoragePermissions, prepare(std.testing.allocator, path, .{}));
    try std.posix.fchmod(data.fd, 0o700);
    const external = try std.fmt.allocPrint(std.testing.allocator, "{s}/duplicate-cookie", .{path});
    defer std.testing.allocator.free(external);
    const cookies = try std.fmt.allocPrint(std.testing.allocator, "{s}/cookies.sqlite", .{path});
    defer std.testing.allocator.free(cookies);
    try std.posix.link(cookies, external);
    try std.testing.expectError(error.LinkedProfileStorageFile, prepare(std.testing.allocator, path, .{}));
    const missing = try newPath("missing");
    defer std.testing.allocator.free(missing);
    const nested = try std.fmt.allocPrint(std.testing.allocator, "{s}/parent/profile", .{missing});
    defer std.testing.allocator.free(nested);
    try std.testing.expectError(error.FileNotFound, prepare(std.testing.allocator, nested, .{}));
}

test "all profile metadata allocations fail before filesystem mutation and return handles" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const path = try newPath("allocation");
    defer std.testing.allocator.free(path);
    const before = try descriptorCount();
    var offset: usize = 0;
    while (true) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = offset });
        if (prepare(failing.allocator(), path, .{})) |value| {
            var prepared = value;
            try prepared.close();
            try std.testing.expect(!failing.has_induced_failure);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectError(error.FileNotFound, std.fs.openDirAbsolute(path, .{}));
        }
        try std.testing.expectEqual(before, try descriptorCount());
        if (offset >= 8) return error.AllocationSweepLimit;
    }
    try std.testing.expectEqual(@as(usize, 2), offset);
    try std.testing.expectEqual(before, try descriptorCount());
}

test "a failed post can reclaim on worker and main adoption performs no allocation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const path = try newPath("handoff");
    defer std.testing.allocator.free(path);
    const before = try descriptorCount();
    var worker: Worker = .{ .allocator = std.testing.allocator, .main = std.Thread.getCurrentId(), .path = path, .reclaim = true };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    try std.testing.expectEqual(before, try descriptorCount());
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var transfer: Worker = .{ .allocator = failing.allocator(), .main = std.Thread.getCurrentId(), .path = path };
    const next = try std.Thread.spawn(.{}, Worker.run, .{&transfer});
    next.join();
    if (transfer.failure) |err| return err;
    const value = &transfer.value.?;
    failing.fail_index = failing.alloc_index;
    try value.adopt();
    const lease = try value.acquire();
    _ = try lease.paths();
    try lease.release();
    try value.close();
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(before, try descriptorCount());
}

test "adopted profile rejects foreign threads and duplicated lock ownership survives close" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const path = try newPath("physical-lock");
    defer std.testing.allocator.free(path);
    const before = try descriptorCount();
    var prepared = try prepare(std.testing.allocator, path, .{});
    const Check = struct {
        fn run(value: *storage.Prepared) void {
            std.testing.expectError(error.WrongThread, value.paths()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.acquire()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.close()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.handoff()) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Check.run, .{&prepared});
    thread.join();
    // A later native owner can retain this open-file-description without a
    // callback to Prepared. close must not issue LOCK_UN on the shared lock.
    const duplicate = try std.posix.dup(prepared.fds[1]);
    _ = try std.posix.fcntl(duplicate, std.posix.F.SETFD, std.posix.FD_CLOEXEC);
    try prepared.close();
    try std.testing.expectError(error.ProfileStorageInUse, prepare(std.testing.allocator, path, .{}));
    try std.testing.expectEqual(before + 1, try descriptorCount());
    std.posix.close(duplicate);
    var reopened = try prepare(std.testing.allocator, path, .{});
    try reopened.close();
    try std.testing.expectEqual(before, try descriptorCount());
}

test {
    _ = storage;
}
