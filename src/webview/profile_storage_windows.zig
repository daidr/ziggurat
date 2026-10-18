const std = @import("std");
const builtin = @import("builtin");
pub const max_path_bytes = 4096;
pub const max_leases = 64;
pub const max_owned_bytes = 1024 * 1024;
pub const process_capacity = 63;
pub const Limits = struct {
    leases: u16 = 16,
    bytes: usize = 32 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.leases == 0 or self.leases > max_leases or self.bytes == 0 or self.bytes > max_owned_bytes) return error.InvalidProfileStorageLimits;
    }
};
/// Borrowed canonical paths until Prepared.close. Windows owns one UDF; cache
/// and cookie paths inside it belong to the Runtime and are not exposed here.
pub const Paths = struct { root: [:0]const u8, data: [:0]const u8 };
pub const Stats = struct { owned_bytes: usize, active_leases: usize, lease_capacity: usize, native_handles: usize };
pub const RetirementStats = extern struct { bytes: usize, processes: u32, admissions: u32, accepting: u32, running: u32 };
pub const NativeCounts = extern struct { domains: u32 = 0, processes: u32 = 0, bytes: usize = 0 };
const NativePaths = extern struct { root: [*:0]const u8, data: [*:0]const u8, data_w: [*:0]const u16 };
const Slot = struct { generation: u64 = 0 };
const Phase = enum { prepared, in_transit, adopted, closed };

/// Linear explicit-worker process-exit responsibility, independent of App and
/// COM. Timeout preserves this token, process HANDLEs and the storage lock.
/// No wait runs on main; no callback or implicit worker is installed.
pub const RetirementDriver = struct {
    native: ?*anyopaque,
    worker: std.Thread.Id,
    pub fn run(self: *RetirementDriver, timeout_ms: u32, system_error: ?*?u32) !void {
        if (system_error) |value| value.* = null;
        try self.check();
        var code: u32 = 0;
        const result = zwpw_lifetime_run(self.native.?, timeout_ms, &code);
        if (system_error) |value| if (code != 0) {
            value.* = code;
        };
        try nativeError(result);
    }
    pub fn stats(self: *RetirementDriver) !RetirementStats {
        try self.check();
        var result: RetirementStats = undefined;
        try nativeError(zwpw_lifetime_stats(self.native.?, &result));
        return result;
    }
    /// Never abandons an active epoch. Seal/close first, then run until its
    /// admitted browser processes exit and release this linear token.
    pub fn deinit(self: *RetirementDriver) !void {
        try self.check();
        const value = try self.stats();
        if (value.accepting != 0 or value.running != 0 or value.processes != 0 or value.admissions != 0) return error.ProcessExitPending;
        try self.run(0, null);
        const native = self.native.?;
        self.native = null;
        zwpw_lifetime_unref(native);
    }
    fn check(self: *RetirementDriver) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != self.worker) return error.WrongThread;
        if (self.native == null) return error.Closed;
    }
};

pub const Lease = struct {
    storage: *Prepared,
    index: u16,
    generation: u64,
    pub fn paths(self: Lease) !Paths {
        const native = try self.checked();
        var result: NativePaths = undefined;
        zwpw_storage_paths(native, &result);
        return .{ .root = std.mem.span(result.root), .data = std.mem.span(result.data) };
    }
    pub fn release(self: Lease) !void {
        _ = try self.checked();
        self.storage.slots[self.index].generation += 1;
        self.storage.active -= 1;
    }
    fn checked(self: Lease) !*anyopaque {
        try self.storage.local();
        if (!self.storage.matches(self)) return error.StaleProfileStorageLease;
        return self.storage.native.?;
    }
};
pub const NativeClaim = struct {
    lease: Lease,
    pub fn paths(self: NativeClaim) !Paths {
        return self.lease.paths();
    }
    pub fn dataWide(self: NativeClaim) ![*:0]const u16 {
        var result: NativePaths = undefined;
        zwpw_storage_paths(try self.lease.checked(), &result);
        return result.data_w;
    }
    pub fn borrowDomain(self: NativeClaim) !*anyopaque {
        return zwpw_storage_domain(try self.lease.checked());
    }
    pub fn commit(self: NativeClaim) !void {
        const prepared = try self.validate();
        prepared.committed = true;
        prepared.slots[self.lease.index].generation += 1;
        prepared.active -= 1;
    }
    pub fn abort(self: NativeClaim) !void {
        const prepared = try self.validate();
        prepared.claimed = false;
        prepared.slots[self.lease.index].generation += 1;
        prepared.active -= 1;
    }
    fn validate(self: NativeClaim) !*Prepared {
        _ = try self.lease.checked();
        const prepared = self.lease.storage;
        if (!prepared.claimed or prepared.committed) return error.StaleProfileStorageLease;
        return prepared;
    }
};

/// Worker-prepared private UDF and cooperative lock. No disk work on adopt or
/// main close, no deletion and no implicit process-exit waiting. Stable address
/// while leases exist; App.post is the exclusive linear handoff barrier.
/// Native filesystem/security scratch and OS handles are separate from the
/// metadata cap; canonical path buffers and the fixed domain are included.
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    worker: std.Thread.Id,
    main: std.Thread.Id,
    owner: std.Thread.Id,
    native: ?*anyopaque,
    slots: []Slot,
    phase: Phase = .prepared,
    busy: bool = false,
    active: usize = 0,
    claimed: bool = false,
    committed: bool = false,
    driver_issued: bool = false,
    pub fn prepare(allocator: std.mem.Allocator, main: std.Thread.Id, absolute_root: []const u8, limits: Limits) !Prepared {
        return prepareWithFailure(allocator, main, absolute_root, limits, null);
    }
    pub fn prepareWithFailure(allocator: std.mem.Allocator, main: std.Thread.Id, absolute_root: []const u8, limits: Limits, system_error: ?*?u32) !Prepared {
        if (system_error) |value| value.* = null;
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        const worker = std.Thread.getCurrentId();
        if (worker == main) return error.UiThreadForbidden;
        _ = try requiredBytes(absolute_root, limits);
        const zig_bytes = @sizeOf(Prepared) + @as(usize, limits.leases) * @sizeOf(Slot);
        var native: ?*anyopaque = null;
        var code: u32 = 0;
        const result = zwpw_storage_create(@intCast(main), absolute_root.ptr, absolute_root.len, limits.bytes - zig_bytes, &native, &code);
        if (system_error) |value| if (code != 0) {
            value.* = code;
        };
        try nativeError(result);
        errdefer {
            nativeError(zwpw_lifetime_abandon(zwpw_storage_domain(native.?))) catch unreachable;
            zwpw_storage_unref(native.?);
        }
        const slots = try allocator.alloc(Slot, limits.leases);
        @memset(slots, .{});
        return .{ .allocator = allocator, .worker = worker, .main = main, .owner = worker, .native = native, .slots = slots };
    }
    /// Conservative reservation even if a short path's canonical spelling
    /// expands. stats reports actual retained metadata after preparation.
    pub fn requiredBytes(absolute_root: []const u8, limits: Limits) !usize {
        try limits.validate();
        try validatePath(absolute_root);
        const size = @sizeOf(Prepared) + @as(usize, limits.leases) * @sizeOf(Slot) + zwpw_storage_bound();
        if (size > limits.bytes) return error.CapacityExceeded;
        return size;
    }
    /// Take once on the preparing worker, before claim. The host runs/releases
    /// this independent token on every successful or failed handoff path.
    pub fn takeRetirementDriver(self: *Prepared) !RetirementDriver {
        try self.local();
        if (std.Thread.getCurrentId() != self.worker) return error.WrongThread;
        if (self.phase != .prepared or self.driver_issued or self.claimed) return error.InvalidProfileStoragePhase;
        const native = zwpw_storage_domain(self.native.?);
        zwpw_lifetime_ref(native);
        self.driver_issued = true;
        return .{ .native = native, .worker = self.worker };
    }
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
    pub fn adopt(self: *Prepared) !void {
        if (self.busy) return error.Busy;
        if (std.Thread.getCurrentId() != self.main) return error.WrongThread;
        if (self.phase != .in_transit) return error.InvalidProfileStoragePhase;
        self.owner = self.main;
        self.phase = .adopted;
    }
    pub fn paths(self: *Prepared) !Paths {
        try self.local();
        var result: NativePaths = undefined;
        zwpw_storage_paths(self.native.?, &result);
        return .{ .root = std.mem.span(result.root), .data = std.mem.span(result.data) };
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
        if (self.claimed) return error.ProfileStorageAlreadyClaimed;
        if (!self.driver_issued) return error.RetirementDriverRequired;
        const lease = try self.acquire();
        self.claimed = true;
        return .{ .lease = lease };
    }
    pub fn stats(self: *Prepared) !Stats {
        try self.local();
        return .{ .owned_bytes = @sizeOf(Prepared) + self.slots.len * @sizeOf(Slot) + zwpw_storage_size(self.native.?), .active_leases = self.active, .lease_capacity = self.slots.len, .native_handles = 5 };
    }
    pub fn close(self: *Prepared) !void {
        if (self.busy) return error.Busy;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.phase == .closed) return;
        try self.local();
        if (self.active != 0) return error.ProfileStorageLeasesAlive;
        self.busy = true;
        defer self.busy = false;
        const native = self.native.?;
        if (!self.committed) {
            const domain = zwpw_storage_domain(native);
            try nativeError(if (self.owner == self.main) zwpw_lifetime_seal(domain) else zwpw_lifetime_abandon(domain));
        }
        const allocator = self.allocator;
        const slots = self.slots;
        self.phase = .closed;
        self.native = null;
        self.slots = &.{};
        zwpw_storage_unref(native);
        allocator.free(slots);
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
};
fn validatePath(path: []const u8) !void {
    if (path.len < 4 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\') return error.AbsoluteProfilePathRequired;
    if (path.len >= max_path_bytes - 32) return error.ProfilePathTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    var parts = std.mem.splitScalar(u8, path[3..], '\\');
    while (parts.next()) |part| {
        if (part.len == 0 or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.NonCanonicalProfilePath;
        for (part) |ch| if (ch < 32 or std.mem.indexOfScalar(u8, "/:\"<>|?*", ch) != null) return error.NonCanonicalProfilePath;
    }
}
pub fn nativeCounts() NativeCounts {
    var result: NativeCounts = .{};
    if (builtin.os.tag == .windows) zwpw_lifetime_counts(&result);
    return result;
}
fn nativeError(result: c_int) !void {
    return switch (result) {
        0 => {},
        1 => error.Closed,
        2 => error.Full,
        3 => error.OutOfMemory,
        4 => error.InvalidProfileStorage,
        5 => error.WrongThread,
        6 => error.ProfileSystemFailure,
        7 => error.CapacityExceeded,
        8 => error.ProcessExitPending,
        9 => error.ProfileStorageInUse,
        else => error.ProfileSystemFailure,
    };
}
extern fn zwpw_storage_create(u32, [*]const u8, usize, usize, *?*anyopaque, *u32) c_int;
extern fn zwpw_storage_paths(*anyopaque, *NativePaths) void;
extern fn zwpw_storage_domain(*anyopaque) *anyopaque;
extern fn zwpw_storage_size(*anyopaque) usize;
extern fn zwpw_storage_bound() usize;
extern fn zwpw_storage_unref(*anyopaque) void;
extern fn zwpw_lifetime_ref(*anyopaque) void;
extern fn zwpw_lifetime_unref(*anyopaque) void;
extern fn zwpw_lifetime_abandon(*anyopaque) c_int;
extern fn zwpw_lifetime_seal(*anyopaque) c_int;
extern fn zwpw_lifetime_run(*anyopaque, u32, *u32) c_int;
extern fn zwpw_lifetime_stats(*anyopaque, *RetirementStats) c_int;
extern fn zwpw_lifetime_counts(*NativeCounts) void;
test "Windows storage rejects noncanonical paths before native preparation" {
    for ([_][]const u8{ "relative", "/private", "\\\\server\\root", "\\\\?\\C:\\root" }) |path| try std.testing.expectError(error.AbsoluteProfilePathRequired, validatePath(path));
    for ([_][]const u8{ "C:\\root\\", "C:\\root\\..\\x", "C:\\root/child", "C:\\root:stream", "C:\\root ", "C:\\root\\\\x" }) |path| try std.testing.expectError(error.NonCanonicalProfilePath, validatePath(path));
    try validatePath("C:\\private\\配置");
    try std.testing.expectError(error.UiThreadForbidden, Prepared.prepare(std.testing.failing_allocator, std.Thread.getCurrentId(), "invalid", .{ .bytes = 0 }));
}
