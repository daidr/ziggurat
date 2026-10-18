const std = @import("std");

/// Owner-thread reservation ledger. Texels use one shared limit; separately
/// owned raster caches reserve both committed and unpublished candidate banks.
/// Native object internals and allocator headers are not observable here.
pub const Ledger = struct {
    pixel_limit: usize,
    total_limit: usize,
    base_metadata: usize,
    texture_bytes: usize = 0,
    workspace_bytes: usize = 0,
    surface_metadata: usize = 0,
    raster_limit: usize = 0,
    peak_pixels: usize = 0,
    peak_total: usize = 0,

    pub fn init(pixel_limit: usize, total_limit: usize, metadata: usize) !Ledger {
        const reservation = try add(pixel_limit, metadata);
        if (reservation > total_limit) return error.CapacityExceeded;
        return .{ .pixel_limit = pixel_limit, .total_limit = total_limit, .base_metadata = metadata, .peak_total = reservation };
    }
    pub fn reserveSurface(self: *Ledger, planes: usize, metadata: usize, raster: usize) !void {
        const work = try add(self.workspace_bytes, planes);
        const meta = try add(self.surface_metadata, metadata);
        const sources = try add(self.raster_limit, raster);
        const pixels = try add(self.texture_bytes, work);
        if (pixels > self.pixel_limit) return error.TextureBudgetExceeded;
        const total = try self.totalFor(meta, sources);
        if (total > self.total_limit) return error.CapacityExceeded;
        self.workspace_bytes = work;
        self.surface_metadata = meta;
        self.raster_limit = sources;
        self.peak_pixels = @max(self.peak_pixels, pixels);
        self.peak_total = @max(self.peak_total, total);
    }
    pub fn releaseSurface(self: *Ledger, planes: usize, metadata: usize, raster: usize) void {
        std.debug.assert(planes <= self.workspace_bytes and metadata <= self.surface_metadata and raster <= self.raster_limit);
        self.workspace_bytes -= planes;
        self.surface_metadata -= metadata;
        self.raster_limit -= raster;
    }
    /// Reserve before any foreign allocator or native bitmap creation. A failed
    /// candidate returns this amount while its reservation peak remains visible.
    pub fn reserveTexture(self: *Ledger, bytes: usize) !void {
        const textures = try add(self.texture_bytes, bytes);
        const pixels = try add(textures, self.workspace_bytes);
        if (pixels > self.pixel_limit) return error.TextureBudgetExceeded;
        self.texture_bytes = textures;
        self.peak_pixels = @max(self.peak_pixels, pixels);
    }
    pub fn releaseTexture(self: *Ledger, bytes: usize) void {
        std.debug.assert(bytes <= self.texture_bytes);
        self.texture_bytes -= bytes;
    }
    pub fn totalReserved(self: *const Ledger) usize {
        return self.totalFor(self.surface_metadata, self.raster_limit) catch unreachable;
    }
    fn totalFor(self: *const Ledger, metadata: usize, raster: usize) !usize {
        return add(try add(self.base_metadata, self.pixel_limit), try add(metadata, try std.math.mul(usize, raster, 2)));
    }
};
fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.CapacityExceeded;
}

test "GPU texture and workspace reservations share a transactional aggregate" {
    var ledger = try Ledger.init(100, 160, 10);
    try ledger.reserveTexture(30);
    try ledger.reserveSurface(40, 10, 10);
    try std.testing.expectEqual(@as(usize, 140), ledger.totalReserved());
    const before = ledger;
    try std.testing.expectError(error.TextureBudgetExceeded, ledger.reserveTexture(31));
    try std.testing.expect(std.meta.eql(before, ledger));
    try std.testing.expectError(error.CapacityExceeded, ledger.reserveSurface(0, 21, 0));
    try std.testing.expect(std.meta.eql(before, ledger));
    try ledger.reserveTexture(30);
    ledger.releaseTexture(30); // unpublished snapshot failed; old data unchanged
    try std.testing.expectEqual(@as(usize, 100), ledger.peak_pixels);
    ledger.releaseTexture(30); // device loss drops published textures
    try std.testing.expectEqual(@as(usize, 40), ledger.workspace_bytes);
    try std.testing.expectError(error.TextureBudgetExceeded, ledger.reserveTexture(61));
    ledger.releaseSurface(40, 10, 10);
    try std.testing.expectEqual(@as(usize, 110), ledger.totalReserved());
    try std.testing.expectEqual(@as(usize, 140), ledger.peak_total);
}

test "GPU metadata and raster candidate reservations check overflow before mutation" {
    try std.testing.expectError(error.CapacityExceeded, Ledger.init(1, 1, 1));
    var ledger = try Ledger.init(1, 100, 1);
    const before = ledger;
    try std.testing.expectError(error.Overflow, ledger.reserveSurface(0, 0, std.math.maxInt(usize)));
    try std.testing.expect(std.meta.eql(before, ledger));
    try std.testing.expectError(error.CapacityExceeded, ledger.reserveSurface(0, std.math.maxInt(usize), 0));
    try std.testing.expect(std.meta.eql(before, ledger));
}
