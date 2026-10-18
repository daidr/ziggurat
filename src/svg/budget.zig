const std = @import("std");

// Stable, preparation-local allocator state. This counts requested live bytes,
// including old+new capacity during ArrayList growth and geometry scratch.
// It deliberately does not pretend to measure an allocator's private headers.
pub const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize,
    peak: usize,
    denied: bool = false,

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    pub fn remaining(self: *const Budget) usize {
        return self.limit - self.live;
    }
    // Only ownership transfer to the identical child allocator may bypass free.
    pub fn transfer(self: *Budget, bytes: usize) void {
        std.debug.assert(bytes <= self.live);
        self.live -= bytes;
    }
    pub fn failure(self: *const Budget, err: anyerror) anyerror {
        return if (err == error.OutOfMemory and self.denied) error.CapacityExceeded else err;
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.denied = length > self.remaining();
        if (self.denied) return null;
        const result = self.child.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        std.debug.assert(memory.len <= self.live);
        self.child.rawFree(memory, alignment, ret);
        self.live -= memory.len;
    }
};
