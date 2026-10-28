const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const geometry = @import("geometry.zig");
const drawing = @import("ziggurat_drawing_resources");
const layout = @import("layout.zig");
const affine = @import("affine.zig");
pub const max_depth = 4;
pub const max_bytes = 256 * 1024 * 1024;
pub const Backend = enum { gdi, cairo, gpu };
pub const LegacyText = enum { grayscale, disabled };
pub const Options = struct {
    size: z.Size,
    max_depth: u8 = 2,
    /// Workspace front/work/groups and optional text scratch, per backend.
    /// Excludes the native swapchain and opaque system object metadata.
    bytes: usize = 64 * 1024 * 1024,
    /// Context checks the software+GPU aggregate before either allocates.
    total_bytes: usize = 64 * 1024 * 1024,
    legacy_text: LegacyText = .grayscale,
};
/// Explicit raster-scope capacity. Source extents are local DIP; the pool
/// includes a transparent physical texel on each side of every source.
pub const TransformOptions = struct { layers: Options, source_size: layout.Size, render_work: u64 = 128 * 1024 * 1024 };
pub const NativeTransform = extern struct {
    xx: f64 = 1,
    yx: f64 = 0,
    xy: f64 = 0,
    yy: f64 = 1,
    x0: f64 = 0,
    y0: f64 = 0,
    source_width: f32,
    source_height: f32,
    pixel_width: u32,
    pixel_height: u32,
    pub fn init(to_parent: affine.Affine, source_size: layout.Size, scale: f32) !NativeTransform {
        const canonical = try to_parent.narrowed();
        const pixels = try sourcePixels(source_size, scale);
        _ = try canonical.mapBounds(.{ .width = source_size.width, .height = source_size.height });
        // The guard is part of the sampled raster quad. Validate it before
        // any child draw, including when a tiny scale makes one texel huge.
        _ = try canonical.mapBounds(.{ .x = -1 / @as(f64, scale), .y = -1 / @as(f64, scale), .width = @as(f64, @floatFromInt(pixels[0] + 2)) / scale, .height = @as(f64, @floatFromInt(pixels[1] + 2)) / scale });
        return .{ .xx = canonical.xx, .yx = canonical.yx, .xy = canonical.xy, .yy = canonical.yy, .x0 = canonical.x0, .y0 = canonical.y0, .source_width = source_size.width, .source_height = source_size.height, .pixel_width = pixels[0], .pixel_height = pixels[1] };
    }
    pub fn matrix(self: NativeTransform) affine.Affine {
        return .{ .xx = self.xx, .yx = self.yx, .xy = self.xy, .yy = self.yy, .x0 = self.x0, .y0 = self.y0 };
    }
    pub fn validate(self: NativeTransform, scale: f32) !void {
        const expected = try init(self.matrix(), .{ .width = self.source_width, .height = self.source_height }, scale);
        inline for (zio.fields(NativeTransform)) |field| if (@field(self, field.name) != @field(expected, field.name)) return error.InvalidTransform;
    }
};
fn sourcePixels(size: layout.Size, scale: f32) ![2]u32 {
    if (!std.math.isFinite(size.width) or !std.math.isFinite(size.height) or size.width <= 0 or size.height <= 0 or !std.math.isFinite(scale) or scale <= 0 or 1 / @as(f64, scale) > affine.max_component) return error.InvalidTransformSource;
    const width = @ceil(@as(f64, size.width) * scale);
    const height = @ceil(@as(f64, size.height) * scale);
    if (width < 1 or height < 1 or width > 32766 or height > 32766) return error.InvalidTransformSource;
    return .{ @intFromFloat(width), @intFromFloat(height) };
}
pub const Group = struct { opacity: u8 = 255, mask: ?drawing.CoverageView = null, mask_origin: drawing.Point = .{} };
pub const NativeGroup = extern struct { x: f32, y: f32, width: f32, height: f32, mask_x: f32 = 0, mask_y: f32 = 0, opacity: u32 = 255, mask_slot: u32 = std.math.maxInt(u32), mask_left: i32 = 0, mask_top: i32 = 0, mask_scale: f32 = 1 };
pub const NativeStats = extern struct { native_objects: u32 = 0, native_restores: u32 = 0, native_creations: u64 = 0, groups: u64 = 0, clear_pixels: u64 = 0, composite_pixels: u64 = 0, committed_frames: u64 = 0, aborted_frames: u64 = 0, metadata_bytes: usize = 0 };
pub fn validateGroup(bounds: drawing.Rect, group: Group, scale: f32) !void {
    if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or bounds.width < 0 or bounds.height < 0 or !std.math.isFinite(bounds.x + bounds.width) or !std.math.isFinite(bounds.y + bounds.height) or !std.math.isFinite(group.mask_origin.x) or !std.math.isFinite(group.mask_origin.y)) return error.InvalidGeometry;
    if (group.mask) |view| {
        try view.validate();
        if (view.coverage.scale != scale) return error.CoverageDpiMismatch;
    }
}
pub const Plan = struct {
    options: Options,
    plane_bytes: usize,
    pixel_bytes: usize,
    planes: u8,
    pool_size: z.Size,
    pool_plane_bytes: usize,
    transform_source: ?layout.Size = null,
    transform_work: u64 = 128 * 1024 * 1024,
    pub fn init(options: Options, backend: Backend) !Plan {
        return initInner(options, backend, null);
    }
    pub fn initTransforms(options: TransformOptions, backend: Backend) !Plan {
        if (options.render_work == 0 or options.render_work > 512 * 1024 * 1024) return error.InvalidRenderLimits;
        var result = try initInner(options.layers, backend, options.source_size);
        result.transform_work = options.render_work;
        return result;
    }
    fn initInner(options: Options, backend: Backend, source: ?layout.Size) !Plan {
        const plane = try geometry.validateSurface(options.size.width, options.size.height, options.size.scale);
        if (options.max_depth == 0 or options.max_depth > max_depth or options.bytes == 0 or options.bytes > max_bytes or options.total_bytes == 0 or options.total_bytes > max_bytes) return error.InvalidLayerLimits;
        const planes: u8 = options.max_depth + 2 + @as(u8, @intFromBool(backend == .gdi and options.legacy_text == .grayscale));
        var pool_size = options.size;
        if (source) |size| {
            const pixels = try sourcePixels(size, options.size.scale);
            pool_size.width = @max(pool_size.width, pixels[0] + 2);
            pool_size.height = @max(pool_size.height, pixels[1] + 2);
        }
        const pool_plane = try geometry.validateSurface(pool_size.width, pool_size.height, pool_size.scale);
        const bytes = std.math.add(usize, plane * 2, std.math.mul(usize, pool_plane, planes - 2) catch return error.LayerBudgetExceeded) catch return error.LayerBudgetExceeded;
        if (bytes > options.bytes) return error.LayerBudgetExceeded;
        return .{ .options = options, .plane_bytes = plane, .pixel_bytes = bytes, .planes = planes, .pool_size = pool_size, .pool_plane_bytes = pool_plane, .transform_source = source };
    }
    pub fn checkContext(options: Options, software: Backend, gpu: bool) !usize {
        const first = try init(options, software);
        const second = if (gpu) (try init(options, .gpu)).pixel_bytes else 0;
        const total = first.pixel_bytes + second;
        if (total > options.total_bytes) return error.LayerAggregateBudgetExceeded;
        return total;
    }
    pub fn matches(self: Plan, size: z.Size) bool {
        return size.width == self.options.size.width and size.height == self.options.size.height and size.scale == self.options.size.scale;
    }
    pub fn checkTransformContext(options: TransformOptions, software: Backend, gpu: bool) !usize {
        const first = try initTransforms(options, software);
        const second = if (gpu) (try initTransforms(options, .gpu)).pixel_bytes else 0;
        const total = first.pixel_bytes + second;
        if (total > options.layers.total_bytes) return error.LayerAggregateBudgetExceeded;
        return total;
    }
    pub fn validateTransform(self: Plan, value: NativeTransform) !void {
        const source = self.transform_source orelse return error.TransformsRequired;
        try value.validate(self.options.size.scale);
        if (value.source_width > source.width or value.source_height > source.height) return error.TransformSourceExceeded;
    }
    pub fn transformOptions(self: Plan) ?TransformOptions {
        return if (self.transform_source) |source| .{ .layers = self.options, .source_size = source, .render_work = self.transform_work } else null;
    }
};
pub const Stats = struct {
    prepared: bool = false,
    pixel_bytes: usize = 0,
    plane_bytes: usize = 0,
    planes: u8 = 0,
    max_depth: u8 = 0,
    native_objects: u32 = 0,
    metadata_bytes: usize = 0,
    native_creations: u64 = 0,
    native_restores: u64 = 0,
    candidate_peak_bytes: usize = 0,
    groups: u64 = 0,
    clear_pixels: u64 = 0,
    composite_pixels: u64 = 0,
    committed_frames: u64 = 0,
    aborted_frames: u64 = 0,
    pub fn fromNative(plan: Plan, native: NativeStats) Stats {
        return .{ .prepared = true, .pixel_bytes = plan.pixel_bytes, .plane_bytes = plan.plane_bytes, .planes = plan.planes, .max_depth = plan.options.max_depth, .native_objects = native.native_objects, .metadata_bytes = native.metadata_bytes, .native_restores = native.native_restores, .native_creations = native.native_creations, .groups = native.groups, .clear_pixels = native.clear_pixels, .composite_pixels = native.composite_pixels, .committed_frames = native.committed_frames, .aborted_frames = native.aborted_frames };
    }
};

test "layer budgets check per backend and aggregate before allocation" {
    const options: Options = .{ .size = .{ .width = 1280, .height = 720, .scale = 1 } };
    const gdi = try Plan.init(options, .gdi);
    const gpu = try Plan.init(options, .gpu);
    try std.testing.expectEqual(@as(usize, 1280 * 720 * 4 * 5), gdi.pixel_bytes);
    try std.testing.expectEqual(gdi.pixel_bytes + gpu.pixel_bytes, try Plan.checkContext(options, .gdi, true));
    var large = options;
    large.size.width *= 2;
    large.size.height *= 2;
    large.size.scale = 2;
    large.bytes = 128 * 1024 * 1024;
    _ = try Plan.init(large, .gdi);
    try std.testing.expectError(error.LayerAggregateBudgetExceeded, Plan.checkContext(large, .gdi, true));
    large.total_bytes = 160 * 1024 * 1024;
    _ = try Plan.checkContext(large, .gdi, true);
    var invalid = options;
    invalid.max_depth = 0;
    try std.testing.expectError(error.InvalidLayerLimits, Plan.init(invalid, .cairo));
    invalid = options;
    invalid.bytes = 1;
    try std.testing.expectError(error.LayerBudgetExceeded, Plan.init(invalid, .gdi));
}

test "transform plans reserve guarded shared pools independently of window fronts" {
    const options: TransformOptions = .{ .layers = .{ .size = .{ .width = 8, .height = 6, .scale = 1.5 }, .max_depth = 2 }, .source_size = .{ .width = 10, .height = 20 } };
    const plan = try Plan.initTransforms(options, .gdi);
    try std.testing.expectEqual(@as(u32, 17), plan.pool_size.width);
    try std.testing.expectEqual(@as(u32, 32), plan.pool_size.height);
    try std.testing.expectEqual(@as(usize, 8 * 6 * 4 * 2 + 17 * 32 * 4 * 3), plan.pixel_bytes);
    const gpu = try Plan.initTransforms(options, .gpu);
    try std.testing.expectEqual(plan.pixel_bytes + gpu.pixel_bytes, try Plan.checkTransformContext(options, .gdi, true));
    const transform = try NativeTransform.init(.{ .xy = 0.25, .x0 = -2 }, options.source_size, 1.5);
    try plan.validateTransform(transform);
    var invalid = transform;
    invalid.pixel_width += 1;
    try std.testing.expectError(error.InvalidTransform, plan.validateTransform(invalid));
    invalid = try NativeTransform.init(.{}, .{ .width = 11, .height = 20 }, 1.5);
    try std.testing.expectError(error.TransformSourceExceeded, plan.validateTransform(invalid));
    try std.testing.expectError(error.TransformsRequired, (try Plan.init(options.layers, .gdi)).validateTransform(transform));
    var limited = options;
    limited.layers.bytes = plan.pixel_bytes - 1;
    try std.testing.expectError(error.LayerBudgetExceeded, Plan.initTransforms(limited, .gdi));
    limited = options;
    limited.layers.total_bytes = plan.pixel_bytes + gpu.pixel_bytes - 1;
    try std.testing.expectError(error.LayerAggregateBudgetExceeded, Plan.checkTransformContext(limited, .gdi, true));
    limited = options;
    limited.source_size.width = std.math.inf(f32);
    try std.testing.expectError(error.InvalidTransformSource, Plan.initTransforms(limited, .gdi));
}

comptime {
    if (@sizeOf(NativeTransform) != 64 or @alignOf(NativeTransform) != 8) @compileError("transform ABI mismatch");
    if (@sizeOf(NativeGroup) != 44) @compileError("layer group ABI mismatch");
    if (@sizeOf(usize) == 8 and @sizeOf(NativeStats) != 64) @compileError("layer stats ABI mismatch");
}
