const std = @import("std");
const builtin = @import("builtin");
pub const source = @import("document_initializers.zig");
pub const transaction = @import("initializer_transaction.zig");

extern fn zwv_initializer_budget_create(usize, *i32) ?*anyopaque;
extern fn zwv_initializer_budget_limit(*anyopaque) usize;
extern fn zwv_initializer_budget_retain(*anyopaque) callconv(.c) void;
extern fn zwv_initializer_budget_unref(*anyopaque) callconv(.c) void;
extern fn zwv_initializer_budget_reserve(*anyopaque, usize) callconv(.c) bool;
extern fn zwv_initializer_budget_release(*anyopaque, usize) callconv(.c) void;
extern fn zwk_initializer_budget_create(usize, *i32) ?*anyopaque;
extern fn zwk_initializer_budget_limit(*anyopaque) usize;
extern fn zwk_initializer_budget_retain(*anyopaque) callconv(.c) void;
extern fn zwk_initializer_budget_unref(*anyopaque) callconv(.c) void;
extern fn zwk_initializer_budget_reserve(*anyopaque, usize) callconv(.c) bool;
extern fn zwk_initializer_budget_release(*anyopaque, usize) callconv(.c) void;
const supported = builtin.os.tag == .windows or builtin.os.tag == .linux;
const budget_create = if (builtin.os.tag == .linux) zwk_initializer_budget_create else zwv_initializer_budget_create;
const budget_limit = if (builtin.os.tag == .linux) zwk_initializer_budget_limit else zwv_initializer_budget_limit;
const budget_retain = if (builtin.os.tag == .linux) zwk_initializer_budget_retain else zwv_initializer_budget_retain;
const budget_unref = if (builtin.os.tag == .linux) zwk_initializer_budget_unref else zwv_initializer_budget_unref;
const budget_reserve = if (builtin.os.tag == .linux) zwk_initializer_budget_reserve else zwv_initializer_budget_reserve;
const budget_release = if (builtin.os.tag == .linux) zwk_initializer_budget_release else zwv_initializer_budget_release;

pub const NativeInput = extern struct {
    budget: *anyopaque,
    source: ?[*:0]const u16,
    units: u32,
};
comptime {
    if (@sizeOf(usize) == 8 and @sizeOf(NativeInput) != 24) @compileError("Native initializer descriptor ABI mismatch");
}
fn accounting(domain: *anyopaque) source.Accounting {
    if (comptime !supported) unreachable;
    return .{ .context = domain, .retain_fn = budget_retain, .unref_fn = budget_unref, .reserve_fn = budget_reserve, .release_fn = budget_release };
}
fn pinDomain(limits: source.Limits, shared: ?*anyopaque) !*anyopaque {
    if (comptime !supported) return error.UnsupportedCapability;
    try limits.validate();
    if (shared) |domain| {
        if (budget_limit(domain) != limits.bytes) return error.InitializerBudgetChange;
        budget_retain(domain);
        return domain;
    }
    var status: i32 = 0;
    return budget_create(limits.bytes, &status) orelse {
        if (if (builtin.os.tag == .linux) status == 12 else @as(u32, @bitCast(status)) == 0x80070718) return error.InitializerBudgetExceeded;
        return error.OutOfMemory;
    };
}
pub fn validateSharedLimits(limits: source.Limits, domain: *anyopaque) !void {
    if (comptime !supported) unreachable;
    try limits.validate();
    if (budget_limit(domain) != limits.bytes) return error.InitializerBudgetChange;
}
pub fn retainDomain(domain: *anyopaque) void {
    if (comptime !supported) unreachable;
    budget_retain(domain);
}
pub fn releaseDomain(domain: *anyopaque) void {
    if (comptime !supported) unreachable;
    budget_unref(domain);
}

/// Linear, immutable source owner. Its record and its Owned each independently
/// pin the C domain. That domain outlives allocator.free reentry closing a View.
pub const Config = struct {
    allocator: std.mem.Allocator,
    domain: *anyopaque,
    owned: source.Owned,

    pub fn create(allocator: std.mem.Allocator, entries: []const source.Initializer, limits: source.Limits, shared: ?*anyopaque) !?*Config {
        if (entries.len == 0) return null;
        if (!supported) return error.UnsupportedCapability;
        const domain = try pinDomain(limits, shared);
        errdefer budget_unref(domain);
        const account = accounting(domain);
        try account.reserve(@sizeOf(Config));
        errdefer account.release(@sizeOf(Config));
        // Capture/own the complete input before the record allocator can
        // replace caller descriptors. Byte borrows stay stable until return.
        var owned = try source.Owned.initAccounted(allocator, account, entries);
        errdefer owned.deinit();
        const self = try allocator.create(Config);
        self.* = .{ .allocator = allocator, .domain = domain, .owned = owned };
        return self;
    }
    pub fn input(self: *const Config) NativeInput {
        if (comptime !supported) unreachable;
        const encoded = self.owned.encoded.?;
        return .{ .budget = self.domain, .source = encoded.ptr, .units = @intCast(encoded.len) };
    }
    pub fn destroy(self: *Config) void {
        // Unsupported adapters cannot create these owners. Keep the native
        // ABI behind that invariant even when ordinary View teardown is
        // instantiated by a Debug build; this is never a leaking no-op.
        if (comptime !supported) unreachable;
        const allocator = self.allocator;
        const domain = self.domain;
        var owned = self.owned.take();
        owned.deinit();
        allocator.destroy(self);
        budget_release(domain, @sizeOf(Config));
        budget_unref(domain);
    }
};

/// Allocated only for a replacement transaction, never for an ordinary View.
/// Candidate source stays owned through physical retirement even after cancel.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    domain: *anyopaque,
    book: transaction.Book = .{},
    candidate: ?*Config = null,
    refs: usize = 1,

    pub fn create(allocator: std.mem.Allocator, limits: source.Limits, shared: ?*anyopaque, revision: u64) !*Controller {
        if (comptime !supported) return error.UnsupportedCapability;
        const domain = try pinDomain(limits, shared);
        errdefer budget_unref(domain);
        const account = accounting(domain);
        try account.reserve(@sizeOf(Controller));
        errdefer account.release(@sizeOf(Controller));
        const self = try allocator.create(Controller);
        self.* = .{ .allocator = allocator, .domain = domain, .book = .{ .revision = revision } };
        return self;
    }
    pub fn input(self: *const Controller) NativeInput {
        if (comptime !supported) unreachable;
        return if (self.candidate) |candidate| candidate.input() else .{ .budget = self.domain, .source = null, .units = 0 };
    }
    pub fn retain(self: *Controller) void {
        if (comptime !supported) unreachable;
        std.debug.assert(self.refs != 0);
        self.refs += 1;
    }
    pub fn release(self: *Controller) void {
        if (comptime !supported) unreachable;
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs == 0) self.destroy();
    }
    fn destroy(self: *Controller) void {
        if (comptime !supported) unreachable;
        const candidate = self.candidate;
        self.candidate = null;
        const allocator = self.allocator;
        const domain = self.domain;
        if (candidate) |value| value.destroy();
        allocator.destroy(self);
        budget_release(domain, @sizeOf(Controller));
        budget_unref(domain);
    }
};
