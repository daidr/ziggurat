const std = @import("std");
/// Requested bytes only. Native layouts belong to the two host Adapters and
/// keep their separate, explicit budgets. No backing allocation is hidden.
pub const Budget = struct {
    source: std.mem.Allocator,
    limit: usize,
    live: usize,
    peak: usize,
    denied: bool = false,
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    pub fn normalize(self: *Budget, err: anyerror) anyerror {
        return if (err == error.OutOfMemory and self.denied) error.CapacityExceeded else err;
    }
    fn permit(self: *Budget, previous: usize, next: usize) bool {
        if (next > self.limit -| (self.live - previous)) {
            self.denied = true;
            return false;
        }
        return true;
    }
    fn record(self: *Budget, previous: usize, next: usize) void {
        self.live = self.live - previous + next;
        self.peak = @max(self.peak, self.live);
    }
    fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.denied = false;
        if (!self.permit(0, size)) return null;
        const result = self.source.rawAlloc(size, alignment, ret) orelse return null;
        self.record(0, size);
        return result;
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.denied = false;
        if (!self.permit(bytes.len, size) or !self.source.rawResize(bytes, alignment, size, ret)) return false;
        self.record(bytes.len, size);
        return true;
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.denied = false;
        if (!self.permit(bytes.len, size)) return null;
        const result = self.source.rawRemap(bytes, alignment, size, ret) orelse return null;
        self.record(bytes.len, size);
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.source.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};
