const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

/// Includes the trailing NUL needed by native absolute-path consumers.
pub const max_path_bytes = 4096;
pub const max_leases = 64;
pub const max_owned_bytes = 1024 * 1024;
const lock_name = ".ziggurat-profile.lock";
const cookie_name = "cookies.sqlite";

pub const Limits = struct {
    leases: u16 = 16,
    bytes: usize = 32 * 1024,

    pub fn validate(self: Limits) !void {
        if (self.leases == 0 or self.leases > max_leases or self.bytes == 0 or self.bytes > max_owned_bytes) return error.InvalidProfileStorageLimits;
    }
};

/// These paths are borrowed until close. Preparation fixes one private root;
/// data and cache never fall back to an engine or environment default.
pub const Paths = struct {
    root: [:0]const u8,
    data: [:0]const u8,
    cache: [:0]const u8,
    cookies: [:0]const u8,
};
pub const Stats = struct { owned_bytes: usize, active_leases: usize, lease_capacity: usize, native_handles: usize };
const Phase = enum { prepared, in_transit, adopted, closed };
const Slot = struct { generation: u64 = 0 };

/// A bounded logical owner-thread borrow. Release it before Prepared.close.
/// This capacity does not limit native engine callbacks or prove quiescence.
/// Do not copy; an already released copy is rejected while Prepared lives.
/// After Prepared.close its old leases, including release, are invalid to use.
pub const Lease = struct {
    storage: *Prepared,
    index: u16,
    generation: u64,

    pub fn paths(self: Lease) !Paths {
        try self.storage.local();
        if (!self.storage.matches(self)) return error.StaleProfileStorageLease;
        return self.storage.pathsUnchecked();
    }
    /// Borrow only for an immediate native duplication while this lease is
    /// alive. Never close, unlock, transfer or retain this descriptor. Native
    /// owners duplicate atomically with close-on-exec and close their own copy.
    pub fn borrowLockDescriptor(self: Lease) !c_int {
        try self.storage.local();
        if (!self.storage.matches(self)) return error.StaleProfileStorageLease;
        return self.storage.fds[1];
    }
    pub fn release(self: Lease) !void {
        try self.storage.local();
        if (!self.storage.matches(self)) return error.StaleProfileStorageLease;
        self.storage.slots[self.index].generation += 1;
        self.storage.active -= 1;
    }
};

/// Linear permission for exactly one native profile construction attempt.
/// Abort is allowed only before publication. Commit consumes this Prepared
/// for native construction permanently: late native references cannot safely
/// call back into the caller-owned Prepared to make it reusable.
pub const NativeClaim = struct {
    lease: Lease,

    pub fn paths(self: NativeClaim) !Paths {
        return self.lease.paths();
    }
    pub fn borrowLockDescriptor(self: NativeClaim) !c_int {
        return self.lease.borrowLockDescriptor();
    }
    pub fn commit(self: NativeClaim) !void {
        const prepared = try self.validate();
        // Validation finishes before either field changes; no foreign calls.
        prepared.slots[self.lease.index].generation += 1;
        prepared.active -= 1;
    }
    pub fn abort(self: NativeClaim) !void {
        const prepared = try self.validate();
        prepared.native_claimed = false;
        prepared.slots[self.lease.index].generation += 1;
        prepared.active -= 1;
    }
    fn validate(self: NativeClaim) !*Prepared {
        const prepared = self.lease.storage;
        try prepared.local();
        if (!prepared.matches(self.lease) or !prepared.native_claimed) return error.StaleProfileStorageLease;
        return prepared;
    }
};

/// Linear directory/lock owner. It never starts a worker or deletes data.
/// prepare performs blocking filesystem operations on the explicit worker.
/// The caller keeps this value at a stable address while any Lease exists.
/// All methods require exclusive access; App.post supplies the handoff barrier.
/// The supplied allocator outlives this value and permits worker allocation and
/// release on whichever thread successfully owns the value at close.
///
/// Only the final root and fixed children may be created. Ancestors must exist.
/// Every path component is opened with O_NOFOLLOW; the root, child directories,
/// cookie and lock files must belong to euid and have no group/other access.
/// The host keeps these paths private and does not rename/replace them while
/// borrowed. This is cooperative application ownership, not a filesystem sandbox.
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    worker: std.Thread.Id,
    main: std.Thread.Id,
    owner: std.Thread.Id,
    phase: Phase = .prepared,
    busy: bool = false,
    storage: ?[]u8,
    ends: [4]usize,
    slots: []Slot,
    active: usize = 0,
    native_claimed: bool = false,
    fds: [5]c_int,

    pub fn prepare(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, absolute_root: []const u8, limits: Limits) !Prepared {
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        const worker = std.Thread.getCurrentId();
        if (worker == process_main_thread_id) return error.UiThreadForbidden;
        try limits.validate();
        const size = try requiredBytes(absolute_root, limits);
        const path_bytes = size - @sizeOf(Prepared) - @as(usize, limits.leases) * @sizeOf(Slot);
        const storage = try allocator.alloc(u8, path_bytes);
        errdefer allocator.free(storage);
        const slots = try allocator.alloc(Slot, limits.leases);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const ends = writePaths(storage, absolute_root);
        var fds: [5]c_int = @splat(-1);
        errdefer closeHandles(fds);
        fds[0] = try privateRoot(absolute_root);
        fds[1] = try privateFile(fds[0], lock_name);
        zio.posix.flock(fds[1], std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| return if (err == error.WouldBlock) error.ProfileStorageInUse else err;
        fds[2] = try privateDirectory(fds[0], "data");
        fds[3] = try privateDirectory(fds[0], "cache");
        fds[4] = try privateFile(fds[0], cookie_name);
        return .{ .allocator = allocator, .worker = worker, .main = process_main_thread_id, .owner = worker, .storage = storage, .ends = ends, .slots = slots, .fds = fds };
    }

    /// Allocation-free validation and exact metadata charge, including this
    /// caller-owned value, four NUL-terminated paths and all lease slots.
    pub fn requiredBytes(absolute_root: []const u8, limits: Limits) !usize {
        try limits.validate();
        try validatePath(absolute_root);
        if (absolute_root.len + 1 + cookie_name.len >= max_path_bytes) return error.ProfilePathTooLong;
        const path_storage = absolute_root.len * 4 + "/data".len + "/cache".len + 1 + cookie_name.len + 4;
        const size = @sizeOf(Prepared) + @as(usize, limits.leases) * @sizeOf(Slot) + path_storage;
        if (size > limits.bytes) return error.CapacityExceeded;
        return size;
    }

    /// Call before posting this stable storage to the main thread. A failed
    /// post does not transfer responsibility: reclaim on the worker, then close
    /// or retry. Never reclaim a successful/accepted post.
    pub fn handoff(self: *Prepared) !void {
        try self.local();
        if (self.phase != .prepared) return error.InvalidProfileStoragePhase;
        if (self.active != 0) return error.ProfileStorageLeasesAlive;
        self.phase = .in_transit;
    }
    pub fn reclaim(self: *Prepared) !void {
        if (self.busy) return error.Busy;
        if (std.Thread.getCurrentId() != self.worker) return error.WrongThread;
        if (self.phase != .in_transit) return error.InvalidProfileStoragePhase;
        self.phase = .prepared;
    }
    /// Pure state publication. No disk access, allocation or native callback.
    pub fn adopt(self: *Prepared) !void {
        if (self.busy) return error.Busy;
        if (std.Thread.getCurrentId() != self.main) return error.WrongThread;
        if (self.phase != .in_transit) return error.InvalidProfileStoragePhase;
        self.owner = self.main;
        self.phase = .adopted;
    }
    pub fn paths(self: *Prepared) !Paths {
        try self.local();
        return self.pathsUnchecked();
    }
    pub fn acquire(self: *Prepared) !Lease {
        try self.local();
        for (self.slots, 0..) |*slot, index| {
            if (slot.generation & 1 != 0 or slot.generation > std.math.maxInt(u64) - 2) continue;
            slot.generation += 1;
            self.active += 1;
            return .{ .storage = self, .index = @intCast(index), .generation = slot.generation };
        }
        return error.Full;
    }
    pub fn claimNativeOwner(self: *Prepared) !NativeClaim {
        try self.local();
        if (self.native_claimed) return error.ProfileStorageAlreadyClaimed;
        const lease = try self.acquire();
        self.native_claimed = true;
        return .{ .lease = lease };
    }
    pub fn stats(self: *Prepared) !Stats {
        try self.local();
        return .{ .owned_bytes = @sizeOf(Prepared) + self.storage.?.len + self.slots.len * @sizeOf(Slot), .active_leases = self.active, .lease_capacity = self.slots.len, .native_handles = 5 };
    }

    /// Releases this owner's handles and metadata, never existing data. It is
    /// not an engine flush, process-exit barrier, fsync or directory-removal grant.
    /// The caller-owned value remains valid for repeated close on its owner.
    pub fn close(self: *Prepared) !void {
        if (self.busy) return error.Busy;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.phase == .closed) return;
        try self.local();
        if (self.active != 0) return error.ProfileStorageLeasesAlive;
        self.busy = true;
        defer self.busy = false;
        const storage = self.storage.?;
        const slots = self.slots;
        const fds = self.fds;
        self.phase = .closed;
        self.storage = null;
        self.slots = &.{};
        self.fds = @splat(-1);
        closeHandles(fds);
        self.allocator.free(slots);
        self.allocator.free(storage);
    }

    fn local(self: *Prepared) !void {
        if (self.busy) return error.Busy;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.phase == .closed) return error.Closed;
        if (self.phase == .in_transit) return error.ProfileStorageInTransit;
    }
    fn matches(self: *Prepared, lease: Lease) bool {
        return lease.index < self.slots.len and lease.generation & 1 != 0 and self.slots[lease.index].generation == lease.generation;
    }
    fn pathsUnchecked(self: *Prepared) Paths {
        const storage = self.storage.?;
        return .{ .root = storage[0..self.ends[0] :0], .data = storage[self.ends[0] + 1 .. self.ends[1] :0], .cache = storage[self.ends[1] + 1 .. self.ends[2] :0], .cookies = storage[self.ends[2] + 1 .. self.ends[3] :0] };
    }
};

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/') return error.AbsoluteProfilePathRequired;
    if (path.len > max_path_bytes) return error.ProfilePathTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.NonCanonicalProfilePath;
}
fn writePaths(output: []u8, root: []const u8) [4]usize {
    var offset: usize = 0;
    var ends: [4]usize = undefined;
    for ([_][]const u8{ "", "/data", "/cache", "/" ++ cookie_name }, 0..) |suffix, index| {
        @memcpy(output[offset..][0..root.len], root);
        offset += root.len;
        @memcpy(output[offset..][0..suffix.len], suffix);
        offset += suffix.len;
        ends[index] = offset;
        output[offset] = 0;
        offset += 1;
    }
    std.debug.assert(offset == output.len);
    return ends;
}
fn closeHandles(fds: [5]c_int) void {
    if (builtin.os.tag != .linux) return;
    var at = fds.len;
    while (at != 0) {
        at -= 1;
        if (fds[at] >= 0) zio.posix.close(fds[at]);
    }
}
fn privateRoot(path: []const u8) !std.posix.fd_t {
    var parent = try zio.posix.open("/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    defer zio.posix.close(parent);
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (parts.peek() == null) return privateDirectory(parent, part);
        const next = try zio.posix.openat(parent, part, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        zio.posix.close(parent);
        parent = next;
    }
    unreachable;
}
fn privateDirectory(parent: std.posix.fd_t, name: []const u8) !std.posix.fd_t {
    zio.posix.mkdirat(parent, name, 0o700) catch |err| if (err != error.PathAlreadyExists) return err;
    const fd = try zio.posix.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    errdefer zio.posix.close(fd);
    try validatePrivate(fd, true);
    return fd;
}
fn privateFile(parent: std.posix.fd_t, name: []const u8) !std.posix.fd_t {
    const fd = try zio.posix.openat(parent, name, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0o600);
    errdefer zio.posix.close(fd);
    try validatePrivate(fd, false);
    return fd;
}
fn validatePrivate(fd: std.posix.fd_t, directory: bool) !void {
    const info = try zio.posix.fstat(fd);
    if (if (directory) !std.posix.S.ISDIR(info.mode) else !std.posix.S.ISREG(info.mode)) return error.InvalidProfileStorageType;
    if (info.uid != zio.posix.geteuid()) return error.ForeignProfileStorageOwner;
    const expected: std.posix.mode_t = if (directory) 0o700 else 0o600;
    if (info.mode & 0o7777 != expected) return error.InsecureProfileStoragePermissions;
    if (!directory and info.nlink != 1) return error.LinkedProfileStorageFile;
}

fn testingValue(allocator: std.mem.Allocator, count: u16) !Prepared {
    const root = "/private-fixture";
    const size = try Prepared.requiredBytes(root, .{ .leases = count });
    const storage = try allocator.alloc(u8, size - @sizeOf(Prepared) - @as(usize, count) * @sizeOf(Slot));
    errdefer allocator.free(storage);
    const slots = try allocator.alloc(Slot, count);
    @memset(slots, .{});
    return .{ .allocator = allocator, .worker = std.Thread.getCurrentId(), .main = std.Thread.getCurrentId(), .owner = std.Thread.getCurrentId(), .storage = storage, .ends = writePaths(storage, root), .slots = slots, .fds = @splat(-1) };
}

test "profile paths and exact metadata budget are validated without allocation" {
    const needed = try Prepared.requiredBytes("/private/配置", .{});
    try std.testing.expectEqual(needed, try Prepared.requiredBytes("/private/配置", .{ .bytes = needed }));
    try std.testing.expectError(error.CapacityExceeded, Prepared.requiredBytes("/private/配置", .{ .bytes = needed - 1 }));
    for ([_][]const u8{ "/", "/private/", "/private//x", "/private/./x", "/private/../x" }) |path| try std.testing.expectError(error.NonCanonicalProfilePath, Prepared.requiredBytes(path, .{}));
    try std.testing.expectError(error.AbsoluteProfilePathRequired, Prepared.requiredBytes("relative", .{}));
    try std.testing.expectError(error.EmbeddedNul, Prepared.requiredBytes("/private\x00x", .{}));
    try std.testing.expectError(error.InvalidUtf8, Prepared.requiredBytes("/private\xff", .{}));
    try std.testing.expectError(error.ProfilePathTooLong, Prepared.requiredBytes("/" ++ &@as([max_path_bytes]u8, @splat('x')), .{}));
    _ = try Prepared.requiredBytes("/" ++ &@as([max_path_bytes - cookie_name.len - 3]u8, @splat('x')), .{});
    try std.testing.expectError(error.ProfilePathTooLong, Prepared.requiredBytes("/" ++ &@as([max_path_bytes - cookie_name.len - 2]u8, @splat('x')), .{}));
    try std.testing.expectError(error.InvalidProfileStorageLimits, Prepared.requiredBytes("/private", .{ .leases = 0 }));
    try std.testing.expectError(error.InvalidProfileStorageLimits, Prepared.requiredBytes("/private", .{ .leases = max_leases + 1 }));
}

test "profile logical leases are bounded and stale generations cannot release a replacement" {
    var value = try testingValue(std.testing.allocator, 1);
    defer value.close() catch unreachable;
    const lease = try value.acquire();
    try std.testing.expectEqualStrings("/private-fixture/cache", (try lease.paths()).cache);
    try std.testing.expectError(error.Full, value.acquire());
    try std.testing.expectError(error.ProfileStorageLeasesAlive, value.handoff());
    try std.testing.expectError(error.ProfileStorageLeasesAlive, value.close());
    try lease.release();
    const replacement = try value.acquire();
    try std.testing.expectError(error.StaleProfileStorageLease, lease.release());
    try std.testing.expectError(error.StaleProfileStorageLease, lease.paths());
    try std.testing.expectError(error.StaleProfileStorageLease, lease.borrowLockDescriptor());
    try std.testing.expectEqual(@as(usize, 1), (try value.stats()).active_leases);
    try replacement.release();
    value.slots[0].generation = std.math.maxInt(u64) - 1;
    try std.testing.expectError(error.Full, value.acquire());
}

test "a native claim rolls back failure but successful construction permanently consumes its epoch" {
    var value = try testingValue(std.testing.allocator, 1);
    defer value.close() catch unreachable;
    const occupied = try value.acquire();
    try std.testing.expectError(error.Full, value.claimNativeOwner());
    try std.testing.expect(!value.native_claimed);
    try occupied.release();
    const first = try value.claimNativeOwner();
    const Foreign = struct {
        fn run(claim: NativeClaim) void {
            std.testing.expectError(error.WrongThread, claim.abort()) catch unreachable;
            std.testing.expectError(error.WrongThread, claim.commit()) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Foreign.run, .{first});
    thread.join();
    try std.testing.expectEqual(@as(usize, 1), value.active);
    try std.testing.expect(value.native_claimed);
    try std.testing.expectError(error.ProfileStorageAlreadyClaimed, value.claimNativeOwner());
    try std.testing.expectError(error.ProfileStorageLeasesAlive, value.close());
    try first.abort();
    try std.testing.expectEqual(@as(usize, 0), value.active);
    const second = try value.claimNativeOwner();
    try std.testing.expectError(error.StaleProfileStorageLease, first.abort());
    try std.testing.expectError(error.StaleProfileStorageLease, first.commit());
    try second.commit();
    try std.testing.expectEqual(@as(usize, 0), value.active);
    try std.testing.expectError(error.StaleProfileStorageLease, second.abort());
    try std.testing.expectError(error.StaleProfileStorageLease, second.commit());
    try std.testing.expectError(error.ProfileStorageAlreadyClaimed, value.claimNativeOwner());
    const ordinary = try value.acquire();
    try ordinary.release();
    try std.testing.expectError(error.ProfileStorageAlreadyClaimed, value.claimNativeOwner());
}

test "profile handoff failure can reclaim while adoption consumes the transfer state" {
    var value = try testingValue(std.testing.allocator, 2);
    defer value.close() catch unreachable;
    try value.handoff();
    try std.testing.expectError(error.ProfileStorageInTransit, value.paths());
    try std.testing.expectError(error.ProfileStorageInTransit, value.close());
    try value.reclaim();
    try std.testing.expectEqualStrings("/private-fixture/cookies.sqlite", (try value.paths()).cookies);
    try value.handoff();
    try value.adopt();
    try std.testing.expectError(error.InvalidProfileStoragePhase, value.reclaim());
    try std.testing.expectError(error.InvalidProfileStoragePhase, value.adopt());
    try std.testing.expectError(error.InvalidProfileStoragePhase, value.handoff());
}

test "profile close withdraws owned storage and rejects reentry through the final foreign free" {
    const Reentrant = struct {
        target: ?*Prepared = null,
        calls: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const value = self.target.?;
            self.calls += 1;
            std.testing.expect(value.storage == null and value.slots.len == 0 and value.phase == .closed) catch unreachable;
            std.testing.expectError(error.Busy, value.close()) catch unreachable;
            std.testing.expectError(error.Busy, value.handoff()) catch unreachable;
            std.testing.expectError(error.Busy, value.adopt()) catch unreachable;
            std.testing.expectError(error.Busy, value.paths()) catch unreachable;
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var allocator: Reentrant = .{};
    var value = try testingValue(allocator.allocator(), 2);
    allocator.target = &value;
    try value.close();
    try std.testing.expectEqual(@as(usize, 2), allocator.calls);
    try value.close();
    try std.testing.expectError(error.Closed, value.paths());
}

test "profile preparation has an explicit platform and worker boundary" {
    const expected = if (builtin.os.tag == .linux) error.UiThreadForbidden else error.UnsupportedCapability;
    try std.testing.expectError(expected, Prepared.prepare(std.testing.failing_allocator, std.Thread.getCurrentId(), "/private", .{}));
}
