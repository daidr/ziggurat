const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
pub const CoverageEntry = struct { view: drawing.CoverageView, used: u64, charge: usize };
pub const Entry = struct { view: drawing.ImageView, used: u64, dynamic: bool = false, charge: usize, last_from_identity: u64 = 0 };
/// Metadata only. The backend releases native objects before drop releases the
/// CPU residency lease. Eviction occurs only in explicit upload/budget methods.
pub const Cache = struct {
    entries: [32]?Entry = @splat(null),
    coverage_entries: [32]?CoverageEntry = @splat(null),
    coverage_stats: drawing.CoverageStats = .{},
    raster_peak_bytes: usize = 0,
    clock: u64 = 0,
    stats: drawing.ImageStats = .{},
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
            for (&self.coverage_entries) |*entry| if (entry.*) |*value| {
                value.used = 0;
            };
            for (&self.entries) |*entry| if (entry.*) |*value| {
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
        return self.empty() == null or bytes > self.stats.budget_bytes -| self.totalBytes();
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
    defer cache.clear();
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

test "mixed coverage and images occupy at most thirty-two native slots" {
    var leases: [32]drawing.Lease = undefined;
    var pixels: [4]u8 = @splat(255);
    const levels = [_]drawing.ImageLevel{.{ .pixels = &pixels, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
    var cache: Cache = .{};
    for (&leases, 0..) |*lease, index| {
        lease.* = drawing.Lease.init(std.Thread.getCurrentId());
        try lease.acquireResidency();
        const identity = try drawing.reserveRasterIdentity();
        if (index % 2 == 0) {
            cache.commit(index, .{ .lease = lease, .identity = identity, .levels = &levels });
        } else cache.commitCoverage(index, .{ .lease = lease, .identity = identity, .coverage = .{ .pixels = &pixels, .width = 1, .height = 1, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = 1 } }, 4);
    }
    try std.testing.expectEqual(32, cache.totalEntries());
    try std.testing.expectEqual(null, cache.empty());
    try std.testing.expect(cache.needsEviction(1));
    try std.testing.expectEqual(16, cache.stats.resident_entries);
    try std.testing.expectEqual(16, cache.coverage_stats.resident_entries);
    cache.clear();
    for (leases) |lease| try std.testing.expectEqual(0, lease.pins);
}
