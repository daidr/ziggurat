const std = @import("std");

/// Accounts explicit adapter allocations and conservative native construction
/// reservations. Underlying allocator metadata and native SDK caches are not
/// byte-counted. No allocation is made by this accounting layer.
pub const Budget = struct {
    source: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    external: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    pub fn total(self: *const Budget) usize {
        return self.live + self.external;
    }
    fn permits(self: *Budget, old: usize, new: usize) bool {
        if (new > self.limit -| (self.total() - old)) {
            self.denied = true;
            return false;
        }
        return true;
    }
    fn record(self: *Budget) void {
        self.peak = @max(self.peak, self.total());
    }
    pub fn reserve(self: *Budget, bytes: usize) !void {
        if (!self.permits(0, bytes)) return error.CapacityExceeded;
        self.external += bytes;
        self.record();
    }
    pub fn release(self: *Budget, bytes: usize) void {
        std.debug.assert(bytes <= self.external);
        self.external -= bytes;
    }
    pub fn normalize(self: *Budget, err: anyerror) anyerror {
        if (err == error.OutOfMemory and self.denied) return error.CapacityExceeded;
        return err;
    }
    fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.denied = false;
        if (!self.permits(0, size)) return null;
        const result = self.source.rawAlloc(size, alignment, ret) orelse return null;
        self.live += size;
        self.record();
        return result;
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.denied = false;
        if (!self.permits(bytes.len, size) or !self.source.rawResize(bytes, alignment, size, ret)) return false;
        self.live = self.live - bytes.len + size;
        self.record();
        return true;
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.denied = false;
        if (!self.permits(bytes.len, size)) return null;
        const result = self.source.rawRemap(bytes, alignment, size, ret) orelse return null;
        self.live = self.live - bytes.len + size;
        self.record();
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.source.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};
