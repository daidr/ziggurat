const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
pub const CoverageEntry = struct { view: drawing.CoverageView, used: u64, charge: usize };
pub const Entry = struct { view: drawing.ImageView, used: u64, dynamic: bool = false, charge: usize, last_from_identity: u64 = 0 };
/// Slots a cache starts with and the most it grows to. The byte budget, not
/// the slot count, bounds residency; past the ceiling the oldest entry makes
/// room as before.
pub const initial_slots = 32;
pub const max_slots = 64 * 1024;
/// Metadata only. The backend releases native objects before drop releases the
/// CPU residency lease. Eviction occurs only in explicit upload/budget methods
/// and when a frame makes the images it draws resident.
pub const Cache = struct {
    entries: []?Entry = &.{},
    coverage_entries: []?CoverageEntry = &.{},
    coverage_stats: drawing.CoverageStats = .{},
    raster_peak_bytes: usize = 0,
    clock: u64 = 0,
    /// Entries used at or after this clock value belong to the frame being
    /// prepared and are not evicted for it.
    protect_from: u64 = std.math.maxInt(u64),
    stats: drawing.ImageStats = .{},
    /// The slot count to grow to next, or `error.ImageSlotsFull` at the ceiling.
    pub fn nextCapacity(self: *const Cache) !usize {
        if (self.entries.len >= max_slots) return error.ImageSlotsFull;
        return if (self.entries.len == 0) initial_slots else @min(max_slots, self.entries.len * 2);
    }
    /// Grow both tables to `capacity` empty-tailed slots. Call after the
    /// backend's native table has grown to at least as many.
    pub fn grow(self: *Cache, capacity: usize) !void {
        std.debug.assert(capacity > self.entries.len);
        const old = self.entries.len;
        const entries = try std.heap.page_allocator.alloc(?Entry, capacity);
        errdefer std.heap.page_allocator.free(entries);
        const coverage = try std.heap.page_allocator.alloc(?CoverageEntry, capacity);
        @memcpy(entries[0..old], self.entries);
        @memset(entries[old..], null);
        @memcpy(coverage[0..old], self.coverage_entries);
        @memset(coverage[old..], null);
        self.free();
        self.entries = entries;
        self.coverage_entries = coverage;
    }
    fn free(self: *Cache) void {
        if (self.entries.len != 0) std.heap.page_allocator.free(self.entries);
        if (self.coverage_entries.len != 0) std.heap.page_allocator.free(self.coverage_entries);
        self.entries = &.{};
        self.coverage_entries = &.{};
    }
    /// Drop every entry and free the tables.
    pub fn deinit(self: *Cache) void {
        self.clear();
        self.free();
        self.* = .{};
    }
    /// Start making a frame's rasters resident: entries touched from now on
    /// are kept until `endFrame`.
    pub fn beginFrame(self: *Cache) void {
        self.protect_from = self.clock +| 1;
    }
    pub fn endFrame(self: *Cache) void {
        self.protect_from = std.math.maxInt(u64);
    }
    pub fn find(self: *const Cache, identity: u64) ?usize {
        for (self.entries, 0..) |entry, i| if (entry) |value| if (value.view.identity == identity) return i;
        return null;
    }
    pub fn findCoverage(self: *const Cache, identity: u64) ?usize {
        for (self.coverage_entries, 0..) |entry, i| if (entry) |value| if (value.view.identity == identity) return i;
        return null;
    }
    pub fn totalBytes(self: *const Cache) usize {
        return self.stats.pixel_bytes + self.coverage_stats.pixel_bytes;
    }
    pub fn totalEntries(self: *const Cache) u32 {
        return self.stats.resident_entries + self.coverage_stats.resident_entries;
    }
    pub fn checkOwners(self: *const Cache) !void {
        for (self.entries) |entry| if (entry) |value| try value.view.lease.checkOwner();
        for (self.coverage_entries) |entry| if (entry) |value| try value.view.lease.checkOwner();
    }
    pub fn reserveCandidate(self: *Cache, charge: usize) void {
        self.raster_peak_bytes = @max(self.raster_peak_bytes, self.totalBytes() + charge);
    }
    pub fn touch(self: *Cache, index: usize) void {
        if (self.clock == std.math.maxInt(u64)) {
            self.clock = 0;
            if (self.protect_from != std.math.maxInt(u64)) self.protect_from = 0;
            for (self.coverage_entries) |*entry| if (entry.*) |*value| {
                value.used = 0;
            };
            for (self.entries) |*entry| if (entry.*) |*value| {
                value.used = 0;
            };
        }
        self.clock += 1;
        if (self.entries[index] != null) self.entries[index].?.used = self.clock else self.coverage_entries[index].?.used = self.clock;
    }
    pub fn empty(self: *const Cache) ?usize {
        for (self.entries, 0..) |entry, i| if (entry == null and self.coverage_entries[i] == null) return i;
        return null;
    }
    pub fn oldest(self: *const Cache) ?usize {
        var index: ?usize = null;
        var oldest_use: u64 = std.math.maxInt(u64);
        for (self.entries, 0..) |entry, i| if (entry) |value| {
            if (index == null or value.used < oldest_use) {
                index = i;
                oldest_use = value.used;
            }
        };
        for (self.coverage_entries, 0..) |entry, i| if (entry) |value| {
            if (index == null or value.used < oldest_use) {
                index = i;
                oldest_use = value.used;
            }
        };
        return index;
    }
    pub fn needsEviction(self: *const Cache, bytes: usize) bool {
        return bytes > self.stats.budget_bytes -| self.totalBytes();
    }
    /// The oldest entry an upload may evict: any entry outside a frame, else
    /// one the frame being prepared has not touched. Null when every entry
    /// belongs to that frame, which then goes over budget until the next
    /// explicit upload or budget change.
    pub fn victim(self: *const Cache) ?usize {
        const index = self.oldest() orelse return null;
        const used = if (self.entries[index]) |value| value.used else self.coverage_entries[index].?.used;
        return if (used < self.protect_from) index else null;
    }
    pub fn commit(self: *Cache, index: usize, view: drawing.ImageView) void {
        self.commitCharged(index, view, false, view.pixelBytes());
    }
    pub fn commitCharged(self: *Cache, index: usize, view: drawing.ImageView, dynamic: bool, charge: usize) void {
        std.debug.assert(self.entries[index] == null and self.coverage_entries[index] == null);
        self.entries[index] = .{ .view = view, .used = 0, .dynamic = dynamic, .charge = charge };
        self.stats.resident_entries += 1;
        self.stats.dynamic_entries += @intFromBool(dynamic);
        self.stats.pixel_bytes += charge;
        self.stats.uploads +%= 1;
        self.touch(index);
    }
    pub fn commitCoverage(self: *Cache, index: usize, view: drawing.CoverageView, charge: usize) void {
        std.debug.assert(self.entries[index] == null and self.coverage_entries[index] == null);
        self.coverage_entries[index] = .{ .view = view, .used = 0, .charge = charge };
        self.coverage_stats.resident_entries += 1;
        self.coverage_stats.pixel_bytes += charge;
        self.coverage_stats.uploads +%= 1;
        self.touch(index);
    }
    pub fn drop(self: *Cache, index: usize, eviction: bool) void {
        if (self.coverage_entries[index]) |entry| {
            entry.view.lease.releaseResidency();
            self.coverage_stats.pixel_bytes -= entry.charge;
            self.coverage_stats.resident_entries -= 1;
            if (eviction) self.coverage_stats.evictions +%= 1;
            self.coverage_entries[index] = null;
            return;
        }
        const entry = self.entries[index].?;
        entry.view.lease.releaseResidency();
        self.stats.pixel_bytes -= entry.charge;
        self.stats.resident_entries -= 1;
        self.stats.dynamic_entries -= @intFromBool(entry.dynamic);
        if (eviction) self.stats.evictions +%= 1;
        self.entries[index] = null;
    }
    /// Returns a validated dynamic entry without changing its LRU position.
    /// Source views remain immutable; only this renderer's registration moves.
    pub fn updateSlot(self: *Cache, identity: u64, view: drawing.ImageView) !usize {
        self.stats.update_requests +%= 1;
        try view.validate();
        if (self.findCoverage(view.identity) != null) return error.RasterIdentityConflict;
        if (identity == 0) return error.ImageNotUploaded;
        const index = self.find(identity) orelse {
            // One exact transition can be retried after another backend fails.
            // No old lease is retained: its resource may already be closed.
            const target = self.find(view.identity) orelse return error.ImageNotUploaded;
            const entry = self.entries[target].?;
            if (!entry.dynamic or entry.last_from_identity != identity or entry.view.lease != view.lease or entry.view.levels.ptr != view.levels.ptr or entry.view.levels.len != view.levels.len) return error.ImageNotUploaded;
            return target;
        };
        const old = self.entries[index].?;
        if (!old.dynamic) return error.ImageNotDynamic;
        try old.view.lease.ensureNoBorrow();
        if (self.find(view.identity)) |other| if (other != index) return error.ImageAlreadyUploaded;
        if (old.view.levels.len != view.levels.len) return error.ImageShapeMismatch;
        for (old.view.levels, view.levels) |a, b| if (a.width != b.width or a.height != b.height or a.stride != b.stride or a.byte_len != b.byte_len) return error.ImageShapeMismatch;
        return index;
    }
    /// Native commit and the new residency acquire have already succeeded.
    pub fn replace(self: *Cache, index: usize, view: drawing.ImageView) void {
        const old = self.entries[index].?.view;
        self.entries[index].?.view = view;
        self.entries[index].?.last_from_identity = old.identity;
        old.lease.releaseResidency();
        self.stats.updates +%= 1;
        self.stats.update_bytes +%= view.pixelBytes();
        self.touch(index);
    }
    pub fn clear(self: *Cache) void {
        for (0..self.entries.len) |i| if (self.entries[i] != null or self.coverage_entries[i] != null) self.drop(i, false);
    }
    pub fn lookupCoverage(self: *Cache, identity: u64) !usize {
        self.coverage_stats.draws +%= 1;
        const index = self.findCoverage(identity) orelse {
            self.coverage_stats.misses +%= 1;
            return error.CoverageNotUploaded;
        };
        self.coverage_stats.hits +%= 1;
        self.touch(index);
        return index;
    }
    pub fn lookup(self: *Cache, identity: u64) !usize {
        self.stats.draws +%= 1;
        const index = self.find(identity) orelse {
            self.stats.misses +%= 1;
            return error.ImageNotUploaded;
        };
        self.stats.hits +%= 1;
        self.touch(index);
        return index;
    }
};

test "coverage shares the bounded image slots budget and LRU without changing dynamic transitions" {
    var image_lease = drawing.Lease.init(std.Thread.getCurrentId());
    var mask_lease = drawing.Lease.init(std.Thread.getCurrentId());
    var replacement_lease = drawing.Lease.init(std.Thread.getCurrentId());
    var rgba: [16]u8 = @splat(255);
    var alpha: [8]u8 = @splat(255);
    const levels = [_]drawing.ImageLevel{.{ .pixels = &rgba, .byte_len = rgba.len, .width = 2, .height = 2, .stride = 8 }};
    const image: drawing.ImageView = .{ .lease = &image_lease, .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
    const mask: drawing.CoverageView = .{ .lease = &mask_lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &alpha, .width = 2, .height = 2, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = 1 } };
    const replacement: drawing.ImageView = .{ .lease = &replacement_lease, .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
    var cache: Cache = .{};
    defer cache.deinit();
    try cache.grow(try cache.nextCapacity());
    cache.stats.budget_bytes = 64;
    try image.lease.acquireResidency();
    cache.commitCharged(0, image, true, 32);
    try mask.lease.acquireResidency();
    cache.commitCoverage(1, mask, mask.pixelBytes());
    try std.testing.expectEqual(2, cache.totalEntries());
    try std.testing.expectEqual(40, cache.totalBytes());
    try std.testing.expect(cache.needsEviction(32));
    cache.touch(0);
    try std.testing.expectEqual(@as(?usize, 1), cache.oldest());
    cache.drop(1, true);
    try std.testing.expectEqual(0, mask_lease.pins);
    try std.testing.expectEqual(1, cache.coverage_stats.evictions);
    try image.lease.acquire();
    try std.testing.expectError(error.ResourceInUse, cache.updateSlot(image.identity, replacement));
    image.lease.release();
    const slot = try cache.updateSlot(image.identity, replacement);
    try replacement.lease.acquireResidency();
    cache.replace(slot, replacement);
    try std.testing.expectEqual(slot, try cache.updateSlot(image.identity, replacement));
    try std.testing.expectError(error.ImageNotUploaded, cache.updateSlot(0xffffffffffff, replacement));
    try std.testing.expectEqual(0, image_lease.pins);
    try std.testing.expectEqual(1, replacement_lease.residency_pins);
    try std.testing.expectEqual(1, cache.stats.updates);
}

test "mixed coverage and images share slots that grow past thirty-two" {
    var leases: [33]drawing.Lease = undefined;
    var pixels: [4]u8 = @splat(255);
    const levels = [_]drawing.ImageLevel{.{ .pixels = &pixels, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
    var cache: Cache = .{};
    defer cache.deinit();
    try std.testing.expectEqual(null, cache.empty());
    try cache.grow(try cache.nextCapacity());
    for (&leases, 0..) |*lease, index| {
        lease.* = drawing.Lease.init(std.Thread.getCurrentId());
        try lease.acquireResidency();
        const identity = try drawing.reserveRasterIdentity();
        const slot = cache.empty() orelse slot: {
            try std.testing.expectEqual(32, index);
            try cache.grow(try cache.nextCapacity());
            break :slot cache.empty().?;
        };
        if (index % 2 == 0) {
            cache.commit(slot, .{ .lease = lease, .identity = identity, .levels = &levels });
        } else cache.commitCoverage(slot, .{ .lease = lease, .identity = identity, .coverage = .{ .pixels = &pixels, .width = 1, .height = 1, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = 1 } }, 4);
    }
    try std.testing.expectEqual(64, cache.entries.len);
    try std.testing.expectEqual(33, cache.totalEntries());
    try std.testing.expect(!cache.needsEviction(1));
    try std.testing.expectEqual(17, cache.stats.resident_entries);
    try std.testing.expectEqual(16, cache.coverage_stats.resident_entries);
    cache.clear();
    for (leases) |lease| try std.testing.expectEqual(0, lease.pins);
}

test "a frame keeps the entries it touched and goes over budget instead of evicting them" {
    var leases: [3]drawing.Lease = undefined;
    var pixels: [16]u8 = @splat(255);
    const levels = [_]drawing.ImageLevel{.{ .pixels = &pixels, .byte_len = 16, .width = 2, .height = 2, .stride = 8 }};
    var cache: Cache = .{};
    defer cache.deinit();
    try cache.grow(try cache.nextCapacity());
    cache.stats.budget_bytes = 32;
    var views: [3]drawing.ImageView = undefined;
    for (&leases, &views) |*lease, *view| {
        lease.* = drawing.Lease.init(std.Thread.getCurrentId());
        view.* = .{ .lease = lease, .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
    }
    for (views[0..2]) |view| {
        try view.lease.acquireResidency();
        cache.commit(cache.empty().?, view);
    }
    try std.testing.expectEqual(@as(?usize, 0), cache.victim());
    cache.beginFrame();
    cache.touch(cache.find(views[1].identity).?);
    try std.testing.expectEqual(@as(?usize, 0), cache.victim());
    cache.touch(cache.find(views[0].identity).?);
    try std.testing.expect(cache.needsEviction(16));
    try std.testing.expectEqual(null, cache.victim());
    try views[2].lease.acquireResidency();
    cache.commit(cache.empty().?, views[2]);
    try std.testing.expectEqual(48, cache.totalBytes());
    cache.endFrame();
    try std.testing.expectEqual(@as(?usize, 1), cache.victim());
}
