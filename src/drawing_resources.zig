const std = @import("std");

pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Rect = extern struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Platform = enum { windows, linux };
var next_raster_identity: std.atomic.Value(u64) = .init(1);

/// All independently prepared raster resources share this process-wide space.
/// Reservation is thread-safe and does not allocate; exhausted IDs never wrap.
pub fn reserveRasterIdentity() error{RasterIdentityExhausted}!u64 {
    var next = next_raster_identity.load(.monotonic);
    while (true) {
        if (next == std.math.maxInt(u64)) return error.RasterIdentityExhausted;
        if (next_raster_identity.cmpxchgWeak(next, next + 1, .monotonic, .monotonic)) |actual| next = actual else return next;
    }
}

/// Stable, owner-thread lease. A frame pins only until all of its replays end.
/// The owning resource must outlive every acquire/release and unpinned view use.
pub const Lease = struct {
    owner: std.Thread.Id,
    pins: usize = 0,
    residency_pins: usize = 0,
    pub fn init(owner: std.Thread.Id) Lease {
        return .{ .owner = owner };
    }
    pub fn checkOwner(self: *const Lease) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    pub fn acquire(self: *Lease) !void {
        try self.checkOwner();
        if (self.pins == std.math.maxInt(usize)) return error.ResourcePinsFull;
        self.pins += 1;
    }
    pub fn release(self: *Lease) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId() and self.pins > self.residency_pins);
        self.pins -= 1;
    }
    pub fn acquireResidency(self: *Lease) !void {
        try self.acquire();
        self.residency_pins += 1;
    }
    pub fn releaseResidency(self: *Lease) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId() and self.residency_pins != 0 and self.pins >= self.residency_pins);
        self.residency_pins -= 1;
        self.pins -= 1;
    }
    pub fn ensureNoBorrow(self: *const Lease) !void {
        try self.checkOwner();
        if (self.pins != self.residency_pins) return error.ResourceInUse;
    }
    pub fn ensureUnused(self: *const Lease) !void {
        try self.checkOwner();
        if (self.pins != 0) return error.ResourceInUse;
    }
};

/// Immutable 8-bit glyph coverage. Origin is relative to layout origin in
/// physical pixels at scale. No color, shaping or ownership is stored here.
pub const Coverage = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    origin_x: i32,
    origin_y: i32,
    scale: f32,
};
pub const max_coverage_bytes = 16 * 1024 * 1024;
/// Immutable A8 residency. Budget is shared with images through RasterStats.
pub const CoverageStats = struct {
    upload_requests: u64 = 0,
    uploads: u64 = 0,
    restores: u64 = 0,
    draws: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    resident_entries: u32 = 0,
    pixel_bytes: usize = 0,
    peak_reserved_bytes: usize = 0,
    native_objects: u32 = 0,
    native_creations: u64 = 0,
    native_scratch_peak_bytes: usize = 0,
};
pub const RasterStats = struct { images: ImageStats, coverage: CoverageStats, resident_entries: u32, pixel_bytes: usize, budget_bytes: usize, peak_reserved_bytes: usize };
pub const NativeCoverage = extern struct { pixels: [*]const u8, byte_len: usize, width: u32, height: u32, stride: u32, origin_x: i32, origin_y: i32, scale: f32 };

/// Immutable platform-independent A8 raster, owned by an explicit producer.
/// Frame borrowing and renderer residency are separate pins on the same lease.
pub const CoverageView = struct {
    lease: *Lease,
    identity: u64,
    coverage: Coverage,
    pub fn validate(self: CoverageView) !void {
        try self.lease.checkOwner();
        const c = self.coverage;
        if (self.identity == 0 or !std.math.isFinite(c.scale) or c.scale < 0.0625 or c.scale > 16 or c.width == 0 or c.height == 0 or c.width > 16384 or c.height > 16384 or c.stride < c.width) return error.InvalidCoverageResource;
        const bytes = @as(u64, c.stride) * c.height;
        if (bytes > max_coverage_bytes or bytes > c.pixels.len or @as(i64, c.origin_x) + c.width > std.math.maxInt(i32) or @as(i64, c.origin_y) + c.height > std.math.maxInt(i32)) return error.InvalidCoverageResource;
    }
    pub fn pixelBytes(self: CoverageView) usize {
        return @as(usize, self.coverage.stride) * self.coverage.height;
    }
    pub fn native(self: CoverageView) NativeCoverage {
        const c = self.coverage;
        return .{ .pixels = c.pixels.ptr, .byte_len = self.pixelBytes(), .width = c.width, .height = c.height, .stride = c.stride, .origin_x = c.origin_x, .origin_y = c.origin_y, .scale = c.scale };
    }
};

test "raster identities and platform-independent coverage have bounded ownership" {
    const first = try reserveRasterIdentity();
    const second = try reserveRasterIdentity();
    try std.testing.expect(first != 0 and second > first);
    var lease = Lease.init(std.Thread.getCurrentId());
    const pixels = [_]u8{ 0, 64, 128, 255 };
    var view: CoverageView = .{ .lease = &lease, .identity = first, .coverage = .{ .pixels = &pixels, .width = 2, .height = 2, .stride = 2, .origin_x = -1, .origin_y = 0, .scale = 1.5 } };
    try view.validate();
    try std.testing.expectEqual(4, view.pixelBytes());
    try std.testing.expectEqual(if (@sizeOf(usize) == 8) @as(usize, 40) else @as(usize, 32), @sizeOf(NativeCoverage));
    view.coverage.stride = 3;
    try std.testing.expectError(error.InvalidCoverageResource, view.validate());
    view.coverage.stride = 2;
    view.coverage.origin_x = std.math.maxInt(i32);
    try std.testing.expectError(error.InvalidCoverageResource, view.validate());
    view.coverage.origin_x = 0;
    view.identity = 0;
    try std.testing.expectError(error.InvalidCoverageResource, view.validate());
}

/// Created only by the optional text-layout module. All native tokens and
/// slices are borrowed from Prepared; pin before recording into a frame.
pub const PreparedTextView = struct {
    lease: *Lease,
    platform: Platform,
    native_layout: *anyopaque,
    native_coverage: ?*anyopaque,
    coverage: Coverage,
    clip: ?Rect = null,
    pub fn validate(self: PreparedTextView) !void {
        try self.lease.checkOwner();
        const c = self.coverage;
        if (!std.math.isFinite(c.scale) or c.scale < 0.0625 or c.scale > 16 or c.width == 0 or c.height == 0 or c.width > 32768 or c.height > 32768 or c.stride < c.width or @as(u64, c.stride) * c.height > c.pixels.len) return error.InvalidPreparedText;
        if (self.clip) |r| if (!std.math.isFinite(r.x) or !std.math.isFinite(r.y) or !std.math.isFinite(r.width) or !std.math.isFinite(r.height) or r.width <= 0 or r.height <= 0) return error.InvalidPreparedText;
        if (self.platform == .linux and self.native_coverage == null) return error.InvalidPreparedText;
    }
};

test "resource leases reject early release of owning resources" {
    var lease = Lease.init(std.Thread.getCurrentId());
    try lease.ensureUnused();
    try lease.acquire();
    try std.testing.expectError(error.ResourceInUse, lease.ensureUnused());
    lease.release();
    try lease.ensureUnused();
}

pub const max_image_levels = 15;
pub const max_image_bytes = 96 * 1024 * 1024;
pub const default_image_budget = 64 * 1024 * 1024;
pub const max_image_budget = 256 * 1024 * 1024;
/// Top-down premultiplied BGRA8. Descriptors and pixels stay stable while pinned.
pub const ImageLevel = extern struct { pixels: [*]const u8, byte_len: usize, width: u32, height: u32, stride: u32 };
pub const ImageView = struct {
    lease: *Lease,
    identity: u64,
    levels: []const ImageLevel,
    pub fn validate(self: ImageView) !void {
        try self.lease.checkOwner();
        if (self.identity == 0 or self.levels.len == 0 or self.levels.len > max_image_levels) return error.InvalidImageResource;
        var bytes: u64 = 0;
        var width = self.levels[0].width;
        var height = self.levels[0].height;
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.InvalidImageResource;
        for (self.levels, 0..) |level, index| {
            if (level.width != width or level.height != height or level.stride < @as(u64, width) * 4 or @as(u64, level.stride) * height > level.byte_len) return error.InvalidImageResource;
            if (level.byte_len > max_image_bytes - bytes) return error.InvalidImageResource;
            bytes += level.byte_len;
            if (index + 1 < self.levels.len and width == 1 and height == 1) return error.InvalidImageResource;
            width = @max(1, width / 2);
            height = @max(1, height / 2);
        }
        if (bytes > max_image_bytes or (self.levels.len > 1 and (self.levels[self.levels.len - 1].width != 1 or self.levels[self.levels.len - 1].height != 1))) return error.InvalidImageResource;
    }
    pub fn pixelBytes(self: ImageView) usize {
        var bytes: usize = 0;
        for (self.levels) |level| bytes += level.byte_len;
        return bytes;
    }
};

/// Stable domain/token headers are owned by the explicit GPU resource module.
/// These descriptors contain no CPU pixels and cannot be used as ImageView.
pub const GpuDomainEpoch = extern struct {
    identity: u64,
    generation: u64 = 1,
    status: u32 = 0, // 0 constructing, 1 ready, 2 lost, 3 stopped, 4 exhausted
    reserved: u32 = 0,
};
pub const GpuTextureToken = extern struct {
    identity: u64 = 0,
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    levels: u32 = 0,
    reserved: u32 = 0,
};
/// Immutable, device-bound texture. Its owning Texture and DeviceDomain must
/// outlive the view and all frame pins. Loss invalidates a generation; no readback
/// or implicit CPU fallback is represented by this type.
pub const TextureView = struct {
    lease: *Lease,
    domain: *const GpuDomainEpoch,
    token: *const GpuTextureToken,
    identity: u64,
    generation: u64,
    width: u32,
    height: u32,
    levels: u32,
    pub fn validate(self: TextureView) !void {
        try self.lease.checkOwner();
        if (self.identity == 0 or self.token.identity != self.identity) return error.Closed;
        switch (self.domain.status) {
            1 => {},
            2 => return error.TextureDeviceLost,
            4 => return error.GenerationExhausted,
            else => return error.Closed,
        }
        if (self.generation != self.domain.generation or self.token.generation != self.generation) return error.StaleTextureGeneration;
        if (self.domain.identity == 0 or self.generation == 0 or self.width == 0 or self.height == 0 or self.width > 16384 or self.height > 16384 or @as(u64, self.width) * self.height > 16 * 1024 * 1024 or self.levels == 0 or self.levels > max_image_levels or self.token.width != self.width or self.token.height != self.height or self.token.levels != self.levels) return error.InvalidTextureResource;
        if (self.levels != 1 and self.levels != 32 - @clz(@max(self.width, self.height))) return error.InvalidTextureResource;
    }
};
pub const ImageFit = enum(u8) { stretch, contain, cover };
pub const ImageSampling = enum(u8) { nearest, linear, mip_linear };
pub const ImageOptions = struct {
    alignment: Point = .{ .x = 0.5, .y = 0.5 },
    fit: ImageFit = .stretch,
    sampling: ImageSampling = .linear,
    opacity: u8 = 255,
    pub fn validate(self: ImageOptions) !void {
        if (!std.math.isFinite(self.alignment.x) or !std.math.isFinite(self.alignment.y) or self.alignment.x < 0 or self.alignment.y < 0 or self.alignment.x > 1 or self.alignment.y > 1) return error.InvalidImageOptions;
    }
};
/// Native ABI: destination DIPs, source pixels in the selected mip level.
pub const ImagePlan = extern struct { destination: Rect, source: Rect, level: u32, sampling: u32, opacity: f32 };
pub fn planImage(view: ImageView, destination: Rect, options: ImageOptions, scale: f32) !ImagePlan {
    try view.validate();
    return planRaster(view.levels[0].width, view.levels[0].height, view.levels.len, destination, options, scale);
}
pub fn planTexture(view: TextureView, destination: Rect, options: ImageOptions, scale: f32) !ImagePlan {
    try view.validate();
    return planRaster(view.width, view.height, view.levels, destination, options, scale);
}
fn planRaster(width_pixels: u32, height_pixels: u32, level_count: usize, destination: Rect, options: ImageOptions, scale: f32) !ImagePlan {
    try options.validate();
    if (!std.math.isFinite(scale) or scale <= 0 or !std.math.isFinite(destination.x) or !std.math.isFinite(destination.y) or !std.math.isFinite(destination.width) or !std.math.isFinite(destination.height) or destination.width < 0 or destination.height < 0) return error.InvalidGeometry;
    if (@abs(@as(f64, destination.x) + destination.width) > std.math.floatMax(f32) or @abs(@as(f64, destination.y) + destination.height) > std.math.floatMax(f32)) return error.InvalidGeometry;
    const base = .{ .width = width_pixels, .height = height_pixels };
    if (options.sampling == .mip_linear and level_count == 1 and (base.width != 1 or base.height != 1)) return error.MipmapsUnavailable;
    var plan: ImagePlan = .{ .destination = destination, .source = .{ .width = @floatFromInt(base.width), .height = @floatFromInt(base.height) }, .level = 0, .sampling = if (options.sampling == .nearest) 0 else 1, .opacity = @as(f32, @floatFromInt(options.opacity)) / 255 };
    if (destination.width == 0 or destination.height == 0) return plan;
    const ratio_x = @as(f64, destination.width) / @as(f64, @floatFromInt(base.width));
    const ratio_y = @as(f64, destination.height) / @as(f64, @floatFromInt(base.height));
    switch (options.fit) {
        .stretch => {},
        .contain => {
            const ratio = @min(ratio_x, ratio_y);
            const width = @as(f64, @floatFromInt(base.width)) * ratio;
            const height = @as(f64, @floatFromInt(base.height)) * ratio;
            const x = @as(f64, destination.x) + (@as(f64, destination.width) - width) * options.alignment.x;
            const y = @as(f64, destination.y) + (@as(f64, destination.height) - height) * options.alignment.y;
            if (@abs(x) > std.math.floatMax(f32) or @abs(y) > std.math.floatMax(f32)) return error.InvalidGeometry;
            plan.destination = .{ .x = @floatCast(x), .y = @floatCast(y), .width = @floatCast(width), .height = @floatCast(height) };
        },
        .cover => {
            const ratio = @max(ratio_x, ratio_y);
            const width = @as(f64, destination.width) / ratio;
            const height = @as(f64, destination.height) / ratio;
            plan.source = .{ .x = @floatCast((@as(f64, @floatFromInt(base.width)) - width) * options.alignment.x), .y = @floatCast((@as(f64, @floatFromInt(base.height)) - height) * options.alignment.y), .width = @floatCast(width), .height = @floatCast(height) };
        },
    }
    if (options.sampling == .mip_linear) {
        const minification = @max(@as(f64, plan.source.width) / (@as(f64, plan.destination.width) * scale), @as(f64, plan.source.height) / (@as(f64, plan.destination.height) * scale));
        if (minification > 1) plan.level = @intFromFloat(@min(@as(f64, @floatFromInt(level_count - 1)), @floor(@log2(minification) + 0.5)));
    }
    const mip = .{ .width = @max(1, base.width >> @as(u5, @intCast(plan.level))), .height = @max(1, base.height >> @as(u5, @intCast(plan.level))) };
    const sx = @as(f32, @floatFromInt(mip.width)) / @as(f32, @floatFromInt(base.width));
    const sy = @as(f32, @floatFromInt(mip.height)) / @as(f32, @floatFromInt(base.height));
    plan.source.x *= sx;
    plan.source.width *= sx;
    plan.source.y *= sy;
    plan.source.height *= sy;
    return plan;
}
pub const ImageStats = struct {
    upload_requests: u64 = 0,
    uploads: u64 = 0,
    restores: u64 = 0,
    evictions: u64 = 0,
    draws: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    resident_entries: u32 = 0,
    pixel_bytes: usize = 0,
    budget_bytes: usize = default_image_budget,
    native_objects: u32 = 0,
    peak_reserved_bytes: usize = 0,
    update_requests: u64 = 0,
    updates: u64 = 0,
    update_bytes: u64 = 0,
    dynamic_entries: u32 = 0,
    native_creations: u64 = 0,
};

test "residency counts distinguish frames from independent renderer ownership" {
    var lease = Lease.init(std.Thread.getCurrentId());
    try lease.acquireResidency();
    try lease.acquireResidency();
    try lease.ensureNoBorrow();
    try lease.acquire();
    try std.testing.expectError(error.ResourceInUse, lease.ensureNoBorrow());
    lease.release();
    try lease.ensureNoBorrow();
    lease.releaseResidency();
    try std.testing.expectError(error.ResourceInUse, lease.ensureUnused());
    lease.releaseResidency();
    try lease.ensureUnused();
}

test "typed texture geometry matches CPU image plans without exposing pixels" {
    var lease = Lease.init(std.Thread.getCurrentId());
    var epoch: GpuDomainEpoch = .{ .identity = 90, .status = 1 };
    var token: GpuTextureToken = .{ .identity = 91, .generation = 1, .width = 4, .height = 2, .levels = 3 };
    const texture: TextureView = .{ .lease = &lease, .domain = &epoch, .token = &token, .identity = 91, .generation = 1, .width = 4, .height = 2, .levels = 3 };
    const pixels: [44]u8 = @splat(0);
    const levels = [_]ImageLevel{
        .{ .pixels = &pixels, .width = 4, .height = 2, .stride = 16, .byte_len = 32 },
        .{ .pixels = pixels[32..].ptr, .width = 2, .height = 1, .stride = 8, .byte_len = 8 },
        .{ .pixels = pixels[40..].ptr, .width = 1, .height = 1, .stride = 4, .byte_len = 4 },
    };
    const image: ImageView = .{ .lease = &lease, .identity = 92, .levels = &levels };
    for ([_]ImageFit{ .stretch, .contain, .cover }) |fit| for ([_]ImageSampling{ .nearest, .linear, .mip_linear }) |sampling| for ([_]f32{ 1, 1.5, 2 }) |scale| for ([_]f32{ 0, 0.25, 1 }) |align_value| {
        for ([_]Rect{ .{ .x = -2.5, .y = 0.25, .width = 0, .height = 3 }, .{ .x = 1, .y = -2, .width = 1, .height = 2 }, .{ .x = 0, .y = 0, .width = 17, .height = 19 } }) |rect| {
            const options: ImageOptions = .{ .fit = fit, .sampling = sampling, .alignment = .{ .x = align_value, .y = 1 - align_value }, .opacity = 123 };
            try std.testing.expect(std.meta.eql(try planImage(image, rect, options, scale), try planTexture(texture, rect, options, scale)));
        }
    };
    epoch.status = 2;
    try std.testing.expectError(error.TextureDeviceLost, texture.validate());
    epoch.status = 1;
    epoch.generation = 2;
    try std.testing.expectError(error.StaleTextureGeneration, texture.validate());
    epoch.generation = 1;
    token.identity = 0;
    try std.testing.expectError(error.Closed, texture.validate());
    token.identity = 91;
    var invalid = texture;
    invalid.levels = 2;
    token.levels = 2;
    try std.testing.expectError(error.InvalidTextureResource, invalid.validate());
    invalid.generation = 0;
    epoch.generation = 0;
    token.generation = 0;
    try std.testing.expectError(error.InvalidTextureResource, invalid.validate());
}
