const std = @import("std");

/// Accounts requested framework storage, including candidates and temporary
/// reservations. Allocator bookkeeping/Runtime/browser memory is not measured.
/// No application or UI object is retained; final release may be on a worker.
pub const Budget = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: std.atomic.Value(usize),
    peak: std.atomic.Value(usize),
    refs: std.atomic.Value(usize) = .init(1),

    pub fn create(backing: std.mem.Allocator, limit: usize) !*Budget {
        if (limit < @sizeOf(Budget) or limit > 16 * 1024 * 1024) return error.InvalidBudget;
        const self = try backing.create(Budget);
        self.* = .{ .backing = backing, .limit = limit, .used = .init(@sizeOf(Budget)), .peak = .init(@sizeOf(Budget)) };
        return self;
    }
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn retain(self: *Budget) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    fn release(self: *Budget) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const backing = self.backing;
        std.debug.assert(self.used.load(.monotonic) == @sizeOf(Budget));
        backing.destroy(self);
    }
    /// One owner release. Allocations/reservations retain their own references.
    pub fn deinit(self: *Budget) void {
        self.release();
    }
    fn reserve(self: *Budget, bytes: usize) bool {
        var before = self.used.load(.monotonic);
        while (true) {
            if (bytes > self.limit - before) return false;
            const after = before + bytes;
            if (self.used.cmpxchgWeak(before, after, .acq_rel, .monotonic)) |changed| {
                before = changed;
            } else {
                var peak = self.peak.load(.monotonic);
                while (after > peak) {
                    peak = self.peak.cmpxchgWeak(peak, after, .monotonic, .monotonic) orelse break;
                }
                return true;
            }
        }
    }
    fn unreserve(self: *Budget, bytes: usize) void {
        const before = self.used.fetchSub(bytes, .release);
        std.debug.assert(before >= @sizeOf(Budget) + bytes);
    }
    /// Useful when a bounded conversion is allocated by a borrowed View's
    /// allocator: reserve its peak here before calling that foreign allocator.
    pub fn hold(self: *Budget, bytes: usize) !Reservation {
        if (!self.reserve(bytes)) return error.Full;
        self.retain();
        return .{ .budget = self, .bytes = bytes };
    }
    pub const Reservation = struct {
        budget: ?*Budget,
        bytes: usize,
        pub fn deinit(self: *Reservation) void {
            const budget = self.budget orelse return;
            self.budget = null;
            budget.unreserve(self.bytes);
            budget.release();
        }
    };
    fn allocate(context: *anyopaque, bytes: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (!self.reserve(bytes)) return null;
        self.retain();
        const result = self.backing.rawAlloc(bytes, alignment, address) orelse {
            self.unreserve(bytes);
            self.release();
            return null;
        };
        return result;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, bytes: usize, address: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(context));
        const grow = bytes -| memory.len;
        if (!self.reserve(grow)) return false;
        if (!self.backing.rawResize(memory, alignment, bytes, address)) {
            self.unreserve(grow);
            return false;
        }
        if (bytes < memory.len) self.unreserve(memory.len - bytes);
        return true;
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, bytes: usize, address: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        const grow = bytes -| memory.len;
        if (!self.reserve(grow)) return null;
        const result = self.backing.rawRemap(memory, alignment, bytes, address) orelse {
            self.unreserve(grow);
            return null;
        };
        if (bytes < memory.len) self.unreserve(memory.len - bytes);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, address);
        self.unreserve(memory.len);
        self.release();
    }
};

fn allocationFailures(allocator: std.mem.Allocator) !void {
    const budget = try Budget.create(allocator, 4096);
    errdefer budget.deinit();
    const memory = try budget.allocator().alloc(u8, 32);
    errdefer budget.allocator().free(memory);
    var hold = try budget.hold(64);
    const charged = @sizeOf(Budget) + memory.len + 64;
    try std.testing.expectEqual(charged, budget.used.load(.acquire));
    budget.deinit(); // Both independent owners keep the accounting context alive.
    budget.allocator().free(memory);
    hold.deinit();
}
test "accounting includes candidate and reserved peaks and outlives its owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
    const budget = try Budget.create(std.testing.allocator, @sizeOf(Budget) + 64);
    defer budget.deinit();
    const memory = try budget.allocator().alloc(u8, 32);
    defer budget.allocator().free(memory);
    var hold = try budget.hold(32);
    try std.testing.expectError(error.Full, budget.hold(1));
    try std.testing.expectError(error.OutOfMemory, budget.allocator().alloc(u8, 1));
    try std.testing.expectEqual(budget.limit, budget.peak.load(.acquire));
    hold.deinit();
    var replacement = try budget.hold(16);
    replacement.deinit();
    try std.testing.expectEqual(@sizeOf(Budget) + 32, budget.used.load(.acquire));
}
