const std = @import("std");
const image = @import("image.zig");
const pre = @import("prepare.zig");
const v = @import("ziggurat_vector");
const scene = @import("scene.zig");

// Lazily created, preparation-local storage. Ordinary scenes do not allocate
// image metadata, pixel buffers or per-brush payloads.
pub const Resources = struct {
    work: *pre.Work,
    entries: ?*image.Snapshot = null,
    paints: ?*image.Paint = null,
    requests: usize = 0,
    instances: usize = 0,
    pixels: usize = 0,
    bytes: usize = 0,
    used: u64 = 0,
    denied: bool = false,
    /// Pixel-mode patterns use the common lane compositor. This ledger is
    /// shared for the preparation, rather than refreshing work per paint.
    pattern_work: ?*scene.Work = null,
    pub fn create(work: *pre.Work) !*Resources {
        if (!work.allocator_budgeted) try work.reserve(@sizeOf(Resources));
        errdefer if (!work.allocator_budgeted) {
            work.live -= @sizeOf(Resources);
        };
        const self = try work.allocator.create(Resources);
        self.* = .{ .work = work };
        return self;
    }
    pub fn close(self: *Resources) void {
        const a = self.allocator();
        if (self.pattern_work) |ledger| {
            self.pattern_work = null;
            a.destroy(ledger);
        }
        var cursor = self.paints;
        self.paints = null;
        while (cursor) |item| {
            cursor = item.next;
            a.destroy(item);
        }
        var entry = self.entries;
        self.entries = null;
        while (entry) |item| {
            entry = item.next;
            const lease = item.lease;
            a.free(item.pixels);
            a.destroy(item);
            // The last allocator callback still observes the resource pinned.
            lease.release();
        }
        const work = self.work;
        work.allocator.destroy(self);
        if (!work.allocator_budgeted) work.live -= @sizeOf(Resources);
    }
    pub fn charge(self: *Resources, count: u64) !void {
        if (count > self.work.options.image_provider.?.limits.work -| self.used) return error.ImageWorkExceeded;
        self.used += count;
        try self.work.check();
    }
    pub fn patternLedger(self: *Resources) !*scene.Work {
        if (self.pattern_work) |ledger| return ledger;
        const ledger = self.allocator().create(scene.Work) catch |err| return if (err == error.OutOfMemory and self.denied) error.CapacityExceeded else err;
        const limits = self.work.options.limits;
        ledger.* = .{ .op_limit = limits.scene_work, .pixel_limit = limits.pixel_work, .color = .{ .limit = limits.color_work }, .geometry = .{ .scan_limit = limits.raster.scan_tests, .sort_limit = limits.sort_work, .sample_limit = limits.sample_work } };
        self.pattern_work = ledger;
        return ledger;
    }
    pub fn get(self: *Resources, key: []const u8) !*const image.Snapshot {
        return self.getInner(key) catch |err| return if (err == error.OutOfMemory and self.denied) error.CapacityExceeded else err;
    }
    fn getInner(self: *Resources, key: []const u8) !*const image.Snapshot {
        var entry = self.entries;
        while (entry) |item| {
            try self.charge(1 + @min(item.key.len, key.len));
            if (std.mem.eql(u8, item.key, key)) return item;
            entry = item.next;
        }
        const provider = self.work.options.image_provider.?;
        if (self.requests == provider.limits.requests) return error.ImageRequestsFull;
        self.requests += 1;
        try self.charge(key.len + 1);
        const view = try provider.resolve_fn(provider.context, key);
        // Capture descriptors and pin before calling any foreign allocator.
        try view.lease.acquire();
        var transferred = false;
        defer if (!transferred) view.lease.release();
        try view.validate();
        const base = view.levels[0];
        const pixels = @as(usize, base.width) * base.height;
        const bytes = pixels * 4;
        const borrowed = view.pixelBytes();
        if (pixels > provider.limits.pixels -| self.pixels or borrowed > provider.limits.bytes -| self.bytes or bytes > provider.limits.bytes -| self.bytes -| borrowed) return error.ImageCapacityExceeded;
        self.pixels += pixels;
        self.bytes += borrowed + bytes;
        try self.charge(pixels);
        const a = self.allocator();
        const result = try a.create(image.Snapshot);
        errdefer a.destroy(result);
        const copy = try a.alloc(u8, bytes);
        errdefer a.free(copy);
        for (0..base.height) |y| {
            try self.work.check();
            const row = base.pixels[y * base.stride ..][0 .. @as(usize, base.width) * 4];
            for (0..base.width) |x| {
                if (x % 256 == 0) try self.work.check();
                const source = row[x * 4 ..][0..4];
                if (source[0] > source[3] or source[1] > source[3] or source[2] > source[3]) return error.InvalidImagePremultiplication;
                @memcpy(copy[(y * base.width + x) * 4 ..][0..4], source);
            }
        }
        try self.work.check();
        result.* = .{ .next = self.entries, .key = key, .lease = view.lease, .pixels = copy, .width = base.width, .height = base.height };
        self.entries = result;
        transferred = true;
        return result;
    }
    pub fn paint(self: *Resources, snapshot: *const image.Snapshot, inverse: v.Transform) !*const image.Paint {
        if (self.instances == self.work.options.image_provider.?.limits.instances) return error.ImageInstancesFull;
        self.instances += 1;
        try self.charge(1);
        const result = self.allocator().create(image.Paint) catch |err| return if (err == error.OutOfMemory and self.denied) error.CapacityExceeded else err;
        result.* = .{ .next = self.paints, .image = snapshot, .inverse = inverse };
        self.paints = result;
        return result;
    }
    fn allocator(self: *Resources) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Resources = @ptrCast(@alignCast(context));
        if (!self.work.allocator_budgeted) self.work.reserve(length) catch {
            self.denied = true;
            return null;
        };
        return self.work.allocator.rawAlloc(length, alignment, ret) orelse {
            if (!self.work.allocator_budgeted) self.work.live -= length;
            return null;
        };
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Resources = @ptrCast(@alignCast(context));
        self.work.allocator.rawFree(bytes, alignment, ret);
        if (!self.work.allocator_budgeted) self.work.live -= bytes.len;
    }
};
