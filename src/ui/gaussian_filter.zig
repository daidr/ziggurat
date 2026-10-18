//! Optional immutable live-filter kernels. No App, renderer or worker owner.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
pub const arithmetic = @import("gaussian_kernel.zig");
pub const Spec = arithmetic.Spec;
pub const Limits = struct { bytes: usize = 64 * 1024, kernels: usize = 32 };
pub const Stats = struct { owned_current: usize, owned_peak: usize, reserved_current: usize, reserved_peak: usize, kernels: usize };
pub const Options = struct { spec: Spec, cancellation: ?*const std.atomic.Value(bool) = null };
pub const View = struct {
    lease: *drawing.Lease,
    identity: u64,
    descriptor: *const arithmetic.Kernel,
    pub fn validate(self: View) !void {
        try self.lease.checkOwner();
        if (self.identity == 0) return error.InvalidGaussianResource;
        try self.descriptor.validate();
    }
};

/// All live kernels and their unpublished candidate metadata share one bounded
/// account. Bank must outlive every Kernel and borrowed View use.
pub const Bank = opaque {
    pub fn create(allocator: std.mem.Allocator, owner: std.Thread.Id, limits: Limits) !*Bank {
        if (owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (limits.kernels == 0 or limits.kernels > 64 or limits.bytes < @sizeOf(State) or limits.bytes > 16 * 1024 * 1024) return error.InvalidGaussianLimits;
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .owner = owner, .limits = limits };
        return @ptrCast(state);
    }
    pub fn prepare(self: *Bank, options: Options) !*Kernel {
        const state = cast(self);
        try state.enter();
        defer state.busy = false;
        if (state.count == state.limits.kernels) return error.GaussianKernelsFull;
        try cancelled(options.cancellation);
        // Input is a by-value Spec; derive before the first foreign allocation.
        const data = try arithmetic.Kernel.prepare(options.spec);
        try cancelled(options.cancellation);
        const bytes = @sizeOf(KernelState);
        if (bytes > state.limits.bytes - state.reserved) return error.GaussianBudgetExceeded;
        state.reserved += bytes;
        state.peak_reserved = @max(state.peak_reserved, state.reserved);
        errdefer state.reserved -= bytes;
        const result = try state.allocator.create(KernelState);
        state.owned += bytes;
        state.peak_owned = @max(state.peak_owned, state.owned);
        errdefer {
            state.allocator.destroy(result);
            state.owned -= bytes;
        }
        try cancelled(options.cancellation);
        const identity = try drawing.reserveRasterIdentity();
        try cancelled(options.cancellation);
        result.* = .{ .bank = state, .lease = drawing.Lease.init(state.owner), .identity = identity, .data = data };
        state.count += 1;
        return @ptrCast(result);
    }
    pub fn stats(self: *const Bank) !Stats {
        const state = cast(@constCast(self));
        try state.check();
        return .{ .owned_current = state.owned, .owned_peak = state.peak_owned, .reserved_current = state.reserved, .reserved_peak = state.peak_reserved, .kernels = state.count };
    }
    pub fn close(self: *Bank) !void {
        const state = cast(self);
        try state.enter();
        errdefer state.busy = false;
        if (state.count != 0) return error.Busy;
        std.debug.assert(state.owned == @sizeOf(State) and state.reserved == state.owned);
        state.closing = true;
        state.allocator.destroy(state);
    }
};

pub const Kernel = opaque {
    pub fn view(self: *const Kernel) !View {
        const state = kernelCast(@constCast(self));
        try state.check();
        return .{ .lease = &state.lease, .identity = state.identity, .descriptor = &state.data };
    }
    pub fn close(self: *Kernel) !void {
        const state = kernelCast(self);
        try state.check();
        try state.lease.ensureUnused();
        const bank = state.bank;
        try bank.enter();
        defer bank.busy = false;
        state.closing = true;
        // No state reads after destroy. Bank remains busy through foreign free.
        bank.allocator.destroy(state);
        bank.owned -= @sizeOf(KernelState);
        bank.reserved -= @sizeOf(KernelState);
        bank.count -= 1;
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    limits: Limits,
    owned: usize = @sizeOf(State),
    peak_owned: usize = @sizeOf(State),
    reserved: usize = @sizeOf(State),
    peak_reserved: usize = @sizeOf(State),
    count: usize = 0,
    busy: bool = false,
    closing: bool = false,
    fn check(self: *const State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
        if (self.busy) return error.Busy;
    }
    fn enter(self: *State) !void {
        try self.check();
        self.busy = true;
    }
};
const KernelState = struct {
    bank: *State,
    lease: drawing.Lease,
    identity: u64,
    data: arithmetic.Kernel,
    closing: bool = false,
    fn check(self: *const KernelState) !void {
        try self.lease.checkOwner();
        if (self.closing) return error.Closed;
        try self.bank.check();
    }
};
fn cast(self: *Bank) *State {
    return @ptrCast(@alignCast(self));
}
fn kernelCast(self: *Kernel) *KernelState {
    return @ptrCast(@alignCast(self));
}
fn cancelled(flag: ?*const std.atomic.Value(bool)) !void {
    if (flag) |value| if (value.load(.acquire)) return error.Cancelled;
}

test "live Gaussian bank pins immutable kernels and budgets old plus candidate" {
    const allocator = std.testing.allocator;
    const bank = try Bank.create(allocator, std.Thread.getCurrentId(), .{ .bytes = @sizeOf(State) + 2 * @sizeOf(KernelState), .kernels = 3 });
    defer bank.close() catch unreachable;
    const first = try bank.prepare(.{ .spec = .{ .sigma = 1 } });
    const second = try bank.prepare(.{ .spec = .{ .sigma = 0 } });
    const before = try bank.stats();
    try std.testing.expectError(error.GaussianBudgetExceeded, bank.prepare(.{ .spec = .{ .sigma = 2 } }));
    try std.testing.expectEqualDeep(before, try bank.stats());
    try std.testing.expectError(error.Busy, bank.close());
    const view = try first.view();
    try view.validate();
    try view.lease.acquire();
    try std.testing.expectError(error.ResourceInUse, first.close());
    try std.testing.expectEqual(@as(u32, 3), view.descriptor.radius);
    view.lease.release();
    try first.close();
    const replacement = try bank.prepare(.{ .spec = .{ .sigma = 2 } });
    try std.testing.expect((try replacement.view()).identity != view.identity);
    try replacement.close();
    try second.close();
    try std.testing.expectEqual(@as(usize, @sizeOf(State)), (try bank.stats()).owned_current);
}
test "live Gaussian candidate preparation checks count cancellation and allocation failure" {
    const bank = try Bank.create(std.testing.allocator, std.Thread.getCurrentId(), .{ .kernels = 1 });
    defer bank.close() catch unreachable;
    var flag: std.atomic.Value(bool) = .init(true);
    const initial = try bank.stats();
    try std.testing.expectError(error.Cancelled, bank.prepare(.{ .spec = .{ .sigma = 1 }, .cancellation = &flag }));
    try std.testing.expectEqualDeep(initial, try bank.stats());
    const result = try bank.prepare(.{ .spec = .{ .sigma = 0.25 } });
    defer result.close() catch unreachable;
    try std.testing.expectError(error.GaussianKernelsFull, bank.prepare(.{ .spec = .{ .sigma = 1 } }));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    const bank = try Bank.create(allocator, std.Thread.getCurrentId(), .{});
    defer bank.close() catch unreachable;
    const result = try bank.prepare(.{ .spec = .{ .sigma = 1 } });
    defer result.close() catch unreachable;
    try (try result.view()).validate();
}

test "live Gaussian allocation and final free remain exclusive under reentry" {
    const Hook = struct {
        bank: ?*Bank = null,
        kernel: ?*Kernel = null,
        flag: std.atomic.Value(bool) = .init(false),
        cancel_on_allocate: bool = false,
        calls: usize = 0,
        failure: ?anyerror = null,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn expect(self: *@This(), expected: anyerror, actual: anytype) void {
            std.testing.expectError(expected, actual) catch |err| {
                self.failure = err;
            };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const memory = std.testing.allocator.rawAlloc(len, alignment, ra);
            if (self.bank) |bank| {
                self.calls += 1;
                self.expect(error.Busy, bank.stats());
                self.expect(error.Busy, bank.close());
                if (self.cancel_on_allocate) self.flag.store(true, .release);
            }
            return memory;
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.bank) |bank| {
                self.calls += 1;
                const final_bank = bytes.ptr == @as([*]u8, @ptrCast(bank));
                self.expect(if (final_bank) error.Closed else error.Busy, bank.stats());
                self.expect(if (final_bank) error.Closed else error.Busy, bank.close());
                if (self.kernel) |kernel| {
                    self.expect(error.Closed, kernel.view());
                    self.expect(error.Closed, kernel.close());
                }
            }
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var hook: Hook = .{};
    const bank = try Bank.create(hook.allocator(), std.Thread.getCurrentId(), .{});
    hook.bank = bank;
    hook.cancel_on_allocate = true;
    try std.testing.expectError(error.Cancelled, bank.prepare(.{ .spec = .{ .sigma = 1 }, .cancellation = &hook.flag }));
    try std.testing.expectEqual(@as(usize, @sizeOf(State)), (try bank.stats()).owned_current);
    hook.cancel_on_allocate = false;
    const result = try bank.prepare(.{ .spec = .{ .sigma = 1 } });
    hook.kernel = result;
    try result.close();
    hook.kernel = null;
    try bank.close();
    try std.testing.expect(hook.calls >= 5);
    if (hook.failure) |err| return err;
}
