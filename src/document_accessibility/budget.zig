const std = @import("std");
const n = @import("native.zig");

/// Temporary host storage shares an atomic ceiling with MTA-created ranges.
/// The Account contains no pointer to this owner or to its source allocator.
pub const Budget = struct {
    source: std.mem.Allocator,
    account: *n.Account,
    denied: ?anyerror = null,
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    pub fn normalize(self: *const Budget, err: anyerror) anyerror {
        return if (err == error.OutOfMemory) self.denied orelse err else err;
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.denied = null;
        n.check(n.zda_account_reserve_host(self.account, len)) catch |err| {
            self.denied = err;
            return null;
        };
        const result = self.source.rawAlloc(len, alignment, ret) orelse {
            n.zda_account_release_host(self.account, len);
            return null;
        };
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        const account = self.account;
        const source = self.source;
        source.rawFree(bytes, alignment, ret);
        n.zda_account_release_host(account, bytes.len);
    }
};
