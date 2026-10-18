const std = @import("std");
const gaussian = @import("gaussian_filter.zig");
const gaussian_scope = @import("gaussian_scope.zig");
const gaussian_kernel = @import("gaussian_kernel.zig");
const z = @import("ziggurat");
const commands = @import("commands.zig");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const drawing = @import("ziggurat_drawing_resources");
const image_cache = @import("image_cache.zig");
const cpu_gradient = @import("cpu_gradient.zig");
const layers = @import("layers.zig");
const transform_composite = @import("transform_composite.zig");
const Rect = layout.Rect;
comptime {
    if (@sizeOf(usize) == 8 and (@sizeOf(cpu_gradient.Surface) != 72 or @offsetOf(cpu_gradient.Surface, "clip") != 24 or @offsetOf(cpu_gradient.Surface, "origin") != 56)) @compileError("software plane ABI mismatch");
}
extern fn zlc_create() ?*anyopaque;
extern fn zlc_has_surface(*anyopaque) c_int;
extern fn zlc_begin(*anyopaque, u32, u32, f32) c_int;
extern fn zlc_fill(*anyopaque, f32, f32, f32, f32, u32) void;
extern fn zlc_shape(*anyopaque, f32, f32, f32, f32, f32, f32, u32) c_int;
extern fn zlc_gradient_surface(*anyopaque, *cpu_gradient.Surface) c_int;
extern fn zlc_gradient_dirty(*anyopaque, u32, u32, u32, u32) void;
extern fn zlc_brush_stats(*anyopaque, *u32, *u32, *u32) void;
pub const BrushStats = struct { creations: u32 = 0, evictions: u32 = 0, cached: u32 = 0 };
extern fn zlc_text(*anyopaque, f32, f32, f32, f32, [*]const u8, u32, u32) c_int;
extern fn zlc_prepared(*anyopaque, *anyopaque, f32, f32, f32, i32, i32, ?*const drawing.Rect, u32) c_int;
extern fn zlc_scale(*anyopaque) f32;
extern fn zlc_push_clip(*anyopaque, f32, f32, f32, f32) void;
extern fn zlc_pop_clip(*anyopaque) void;
extern fn zlc_end(*anyopaque, *anyopaque) void;
extern fn zlc_destroy(*anyopaque) void;
extern fn zlc_prepare_image(*anyopaque, [*]const drawing.ImageLevel, u32) c_int;
extern fn zlc_prepare_dynamic_image(*anyopaque, [*]const drawing.ImageLevel, u32) c_int;
extern fn zlc_update_image(*anyopaque, u32, [*]const drawing.ImageLevel, u32) c_int;
extern fn zlc_commit_image(*anyopaque, u32) void;
extern fn zlc_image_fault(*anyopaque, u32) void;
extern fn zlc_release_image(*anyopaque, u32) void;
extern fn zlc_image(*anyopaque, u32, *const drawing.ImagePlan) c_int;
extern fn zlc_image_objects(*anyopaque) u32;
extern fn zlc_image_creations(*anyopaque) u64;
extern fn zlc_layer_create(u32, u32, f32, u32, u32, u32, u32) ?*anyopaque;
extern fn zlc_layer_copy_front(*anyopaque, *anyopaque) c_int;
extern fn zlc_layer_free(*anyopaque) void;
extern fn zlc_layer_commit(*anyopaque, *anyopaque) void;
extern fn zlc_layer_release(*anyopaque) c_int;
extern fn zlc_layer_abort(*anyopaque) void;
extern fn zlc_surface_bytes(*anyopaque) usize;
extern fn zlc_layer_stats(*anyopaque, *layers.NativeStats) void;
extern fn zlc_layer_transparent(*anyopaque) c_int;
extern fn zlc_layer_begin_group(*anyopaque, *const layers.NativeGroup) c_int;
extern fn zlc_layer_end_group(*anyopaque) c_int;
extern fn zlc_layer_begin_transform(*anyopaque, *const layers.NativeTransform) c_int;
extern fn zlc_layer_transform_planes(*anyopaque, *cpu_gradient.Surface, *cpu_gradient.Surface, *layers.NativeTransform) c_int;
extern fn zlc_layer_finish_transform(*anyopaque, u64, u32, u32, u32, u32) c_int;
extern fn zlc_gaussian_metadata_bytes() usize;
extern fn zlc_layer_release_gaussian(*anyopaque) c_int;
extern fn zlc_layer_prepare_gaussian(*anyopaque, *const gaussian_scope.Capacity) c_int;
extern fn zlc_layer_gaussian_capacity(*anyopaque, *gaussian_scope.Capacity) c_int;
extern fn zlc_layer_gaussian_active(*anyopaque) c_int;
extern fn zlc_layer_begin_gaussian(*anyopaque, *const layers.NativeGroup, *const gaussian_scope.Capture, *const gaussian_kernel.Kernel) c_int;
extern fn zlc_layer_gaussian_planes(*anyopaque, *cpu_gradient.Surface, *cpu_gradient.Surface, *?*const gaussian_kernel.Kernel) c_int;
extern fn zlc_end_checked(*anyopaque, *anyopaque) c_int;
extern fn zlc_layer_metadata_bytes() usize;
extern fn zlc_offscreen_prepare(*anyopaque) c_int;
extern fn zlc_offscreen_begin(*anyopaque) c_int;
extern fn zlc_offscreen_end(*anyopaque, [*]u8, usize) c_int;

extern fn zlc_prepare_coverage(*anyopaque, *const drawing.NativeCoverage) c_int;
extern fn zlc_coverage(*anyopaque, u32, f32, f32, f32, i32, i32, u32) c_int;
extern fn zlc_coverage_objects(*anyopaque) u32;
extern fn zlc_coverage_creations(*anyopaque) u64;

pub const Renderer = struct {
    native: ?*anyopaque = null,
    images: image_cache.Cache = .{},
    layer_plan: ?layers.Plan = null,
    layer_active: bool = false,
    layer_fault: u32 = 0,
    layer_candidate_peak: usize = 0,
    pub const LayerCandidate = struct { native: *anyopaque, plan: layers.Plan };
    pub fn layerMetadataBytes() usize {
        return zlc_layer_metadata_bytes();
    }
    pub fn prepareOffscreen(self: *Renderer) !void {
        if (self.native == null or zlc_offscreen_prepare(self.native.?) != 0) return error.OffscreenPreparationFailed;
    }
    pub fn beginOffscreen(self: *Renderer) !void {
        if (self.layer_plan == null) return error.LayersRequired;
        if (self.layer_active) return error.AlreadyDrawing;
        if (self.native == null or zlc_offscreen_begin(self.native.?) != 0) return error.OffscreenBeginFailed;
        self.layer_active = true;
    }
    pub fn endOffscreen(self: *Renderer, pixels: []u8) !void {
        const native = self.native orelse return error.NoSurface;
        const result = zlc_offscreen_end(native, pixels.ptr, pixels.len);
        if (result == 4) return error.SurfaceModeMismatch;
        if (result != 0) return error.OffscreenExportFailed;
        self.layer_active = false;
    }
    pub fn createLayerCandidate(self: *Renderer, _: std.mem.Allocator, options: layers.Options) !LayerCandidate {
        return self.createPlanCandidate(try layers.Plan.init(options, .cairo));
    }
    pub fn createTransformCandidate(self: *Renderer, _: std.mem.Allocator, options: layers.TransformOptions) !LayerCandidate {
        return self.createPlanCandidate(try layers.Plan.initTransforms(options, .cairo));
    }
    pub fn createGaussianCandidate(self: *Renderer, _: std.mem.Allocator, plan: gaussian_scope.Plan) !LayerCandidate {
        const candidate = try self.createPlanCandidate(plan.layers);
        errdefer zlc_layer_free(candidate.native);
        if (zlc_layer_prepare_gaussian(candidate.native, &plan.capacity) != 0) return error.GaussianPreparationFailed;
        self.layer_candidate_peak = @max(self.layer_candidate_peak, self.layerSurfaceBytes() + plan.pixel_bytes);
        return candidate;
    }
    pub fn prepareGaussian(self: *Renderer, allocator: std.mem.Allocator, options: gaussian_scope.Options) !void {
        self.commitLayerCandidate(try self.createGaussianCandidate(allocator, try gaussian_scope.Plan.init(options, .cairo, self.transformOptions())));
    }
    pub fn gaussianCapacity(self: *const Renderer) ?gaussian_scope.Capacity {
        var value: gaussian_scope.Capacity = undefined;
        return if (self.native != null and zlc_layer_gaussian_capacity(self.native.?, &value) != 0) value else null;
    }
    pub fn gaussianMetadataBytes() usize {
        return zlc_gaussian_metadata_bytes();
    }
    pub fn releaseGaussian(self: *Renderer) !void {
        if (self.layer_active) return error.AlreadyDrawing;
        if (self.native) |native| if (zlc_layer_release_gaussian(native) != 0) return error.GaussianReleaseFailed;
    }
    fn createPlanCandidate(self: *Renderer, plan: layers.Plan) !LayerCandidate {
        if (self.layer_active) return error.AlreadyDrawing;
        const options = plan.options;
        if (self.native == null) self.native = zlc_create() orelse return error.OutOfMemory;
        self.layer_candidate_peak = @max(self.layer_candidate_peak, self.layerSurfaceBytes() + plan.pixel_bytes);
        const fault = self.layer_fault;
        self.layer_fault = 0;
        const candidate = zlc_layer_create(options.size.width, options.size.height, options.size.scale, options.max_depth, fault, plan.pool_size.width, plan.pool_size.height) orelse return error.LayerPreparationFailed;
        errdefer zlc_layer_free(candidate);
        if (zlc_layer_copy_front(self.native.?, candidate) != 0) return error.LayerPreparationFailed;
        return .{ .native = candidate, .plan = plan };
    }
    pub fn destroyLayerCandidate(candidate: LayerCandidate) void {
        zlc_layer_free(candidate.native);
    }
    pub fn commitLayerCandidate(self: *Renderer, candidate: LayerCandidate) void {
        zlc_layer_commit(self.native.?, candidate.native);
        self.layer_plan = candidate.plan;
        self.layer_active = false;
    }
    pub fn prepareLayers(self: *Renderer, allocator: std.mem.Allocator, options: layers.Options) !void {
        self.commitLayerCandidate(try self.createLayerCandidate(allocator, options));
    }
    pub fn prepareTransforms(self: *Renderer, allocator: std.mem.Allocator, options: layers.TransformOptions) !void {
        self.commitLayerCandidate(try self.createTransformCandidate(allocator, options));
    }
    pub fn transformOptions(self: *const Renderer) ?layers.TransformOptions {
        return if (self.layer_plan) |plan| plan.transformOptions() else null;
    }
    pub fn releaseLayers(self: *Renderer) !void {
        if (self.layer_active) return error.AlreadyDrawing;
        if (self.native) |native| {
            const result = zlc_layer_release(native);
            if (result == 2) return error.OffscreenSurface;
            if (result != 0) return error.LayerReleaseFailed;
        }
        self.layer_plan = null;
    }
    pub fn injectLayerPreparationFailureForTest(self: *Renderer, one_based_plane: u32) void {
        self.layer_fault = one_based_plane;
    }
    pub fn layerSurfaceBytes(self: *const Renderer) usize {
        return if (self.layer_plan) |plan| plan.pixel_bytes + (if (self.gaussianCapacity() != null) plan.pool_plane_bytes else @as(usize, 0)) else if (self.native) |native| zlc_surface_bytes(native) else 0;
    }
    pub fn layerOptions(self: *const Renderer) ?layers.Options {
        return if (self.layer_plan) |plan| plan.options else null;
    }
    pub fn layerPlan(self: *const Renderer) ?layers.Plan {
        return self.layer_plan;
    }
    pub fn layerStats(self: *const Renderer) layers.Stats {
        const plan = self.layer_plan orelse return .{ .candidate_peak_bytes = self.layer_candidate_peak };
        var values: layers.NativeStats = .{};
        zlc_layer_stats(self.native.?, &values);
        var result = layers.Stats.fromNative(plan, values);
        if (self.gaussianCapacity() != null) result.pixel_bytes += plan.pool_plane_bytes;
        result.candidate_peak_bytes = self.layer_candidate_peak;
        return result;
    }
    pub fn abort(self: *Renderer) void {
        if (self.native) |native| zlc_layer_abort(native);
        self.layer_active = false;
    }
    pub fn beginGroup(self: *Renderer, group_bounds: drawing.Rect, options: layers.Group) !void {
        const descriptor = try self.groupDescriptor(group_bounds, options);
        if (zlc_layer_begin_group(self.native.?, &descriptor) != 0) return error.BeginGroupFailed;
    }
    fn groupDescriptor(self: *Renderer, group_bounds: drawing.Rect, options: layers.Group) !layers.NativeGroup {
        const plan = self.layer_plan orelse return error.LayersRequired;
        if (!self.layer_active) return error.NotDrawing;
        try layers.validateGroup(group_bounds, options, plan.options.size.scale);
        var descriptor: layers.NativeGroup = .{ .x = group_bounds.x, .y = group_bounds.y, .width = group_bounds.width, .height = group_bounds.height, .opacity = options.opacity };
        if (options.mask) |view| {
            descriptor.mask_slot = @intCast(try self.images.lookupCoverage(view.identity));
            descriptor.mask_x = options.mask_origin.x;
            descriptor.mask_y = options.mask_origin.y;
            descriptor.mask_left = view.coverage.origin_x;
            descriptor.mask_top = view.coverage.origin_y;
            descriptor.mask_scale = view.coverage.scale;
        }
        return descriptor;
    }
    pub fn endGroup(self: *Renderer) !void {
        if (self.layer_plan == null) return error.LayersRequired;
        if (zlc_layer_gaussian_active(self.native.?) != 0) try self.filterGaussian();
        if (zlc_layer_end_group(self.native.?) != 0) return error.EndGroupFailed;
    }
    pub fn beginGaussian(self: *Renderer, bounds: drawing.Rect, options: layers.Group, view: gaussian.View) !void {
        try view.validate();
        if (view.descriptor.radius == 0) return self.beginGroup(bounds, options);
        const capture = try gaussian_scope.Capture.init(bounds, view.descriptor);
        const descriptor = try self.groupDescriptor(bounds, options);
        if (zlc_layer_begin_gaussian(self.native.?, &descriptor, &capture, view.descriptor) != 0) return error.BeginGaussianFailed;
    }
    noinline fn filterGaussian(self: *Renderer) !void {
        var source: cpu_gradient.Surface = undefined;
        var temporary: cpu_gradient.Surface = undefined;
        var kernel: ?*const gaussian_kernel.Kernel = null;
        if (zlc_layer_gaussian_planes(self.native.?, &source, &temporary, &kernel) != 0 or kernel == null) return error.EndGaussianFailed;
        var visits: u64 = 0;
        const pixels = source.pixels[0 .. @as(usize, source.stride) * (source.height - 1) + source.width];
        const scratch = temporary.pixels[0 .. @as(usize, temporary.stride) * (temporary.height - 1) + temporary.width];
        try gaussian_kernel.apply(kernel.?, .{ .pixels = pixels, .width = source.width, .height = source.height, .stride = source.stride }, .{ .pixels = scratch, .width = temporary.width, .height = temporary.height, .stride = temporary.stride }, .{ .pixels = pixels, .width = source.width, .height = source.height, .stride = source.stride }, std.math.maxInt(u64), null, &visits);
    }
    pub fn beginTransform(self: *Renderer, value: layers.NativeTransform) !void {
        const plan = self.layer_plan orelse return error.TransformsRequired;
        try plan.validateTransform(value);
        if (!self.layer_active) return error.NotDrawing;
        if (zlc_layer_begin_transform(self.native.?, &value) != 0) return error.BeginTransformFailed;
    }
    pub fn endTransform(self: *Renderer) !void {
        if (self.layer_plan == null) return error.TransformsRequired;
        var source: cpu_gradient.Surface = undefined;
        var destination: cpu_gradient.Surface = undefined;
        var value: layers.NativeTransform = undefined;
        if (zlc_layer_transform_planes(self.native.?, &source, &destination, &value) != 0) return error.EndTransformFailed;
        // No allocator, callback, native call or retained borrow is permitted
        // between acquiring these owned planes and finishing the pure sample.
        const result = try transform_composite.drawWithBounds(.{ .pixels = source.pixels, .width = source.width, .height = source.height, .stride = source.stride }, .{ .pixels = destination.pixels, .width = destination.width, .height = destination.height, .stride = destination.stride }, value.matrix(), destination.scale, destination.origin, destination.clip);
        const bounds = result.bounds;
        if (zlc_layer_finish_transform(self.native.?, result.visits, bounds[0], bounds[1], bounds[2] - bounds[0], bounds[3] - bounds[1]) != 0) return error.EndTransformFailed;
    }
    pub fn uploadCoverage(self: *Renderer, view: drawing.CoverageView) !void {
        try view.validate();
        self.images.coverage_stats.upload_requests +%= 1;
        if (self.images.find(view.identity) != null) return error.RasterIdentityConflict;
        if (self.images.findCoverage(view.identity)) |slot| {
            self.images.touch(slot);
            return;
        }
        const charge = @max(view.coverage.stride, (view.coverage.width + 3) & ~@as(u32, 3)) * @as(usize, view.coverage.height);
        if (charge > self.images.stats.budget_bytes) return error.CoverageBudgetExceeded;
        if (self.native == null) self.native = zlc_create() orelse return error.OutOfMemory;
        const native = self.native.?;
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        self.images.reserveCandidate(charge);
        self.images.coverage_stats.peak_reserved_bytes = @max(self.images.coverage_stats.peak_reserved_bytes, self.images.coverage_stats.pixel_bytes + charge);
        const descriptor = view.native();
        if (zlc_prepare_coverage(native, &descriptor) != 0) return error.CoverageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.oldest().?, true);
        const slot = self.images.empty().?;
        zlc_commit_image(native, @intCast(slot));
        self.images.commitCoverage(slot, view, charge);
    }
    pub fn releaseCoverage(self: *Renderer, identity: u64) !bool {
        const slot = self.images.findCoverage(identity) orelse return false;
        try self.images.coverage_entries[slot].?.view.lease.checkOwner();
        self.dropImage(slot, false);
        return true;
    }
    pub fn coverage(self: *Renderer, view: drawing.CoverageView, origin: drawing.Point, tint: geometry.Color) !void {
        try view.validate();
        const native = self.native orelse return error.NoSurface;
        if (zlc_scale(native) != view.coverage.scale) return error.CoverageDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        const slot = try self.images.lookupCoverage(view.identity);
        if (zlc_coverage(native, @intCast(slot), origin.x, origin.y, view.coverage.scale, view.coverage.origin_x, view.coverage.origin_y, tint.rgba()) != 0) return error.DrawCoverageFailed;
    }
    pub fn coverageStats(self: *const Renderer) drawing.CoverageStats {
        var values = self.images.coverage_stats;
        if (self.native) |native| {
            values.native_objects = zlc_coverage_objects(native);
            values.native_creations = zlc_coverage_creations(native);
        }
        return values;
    }
    /// Images and coverage share the same bounded residency budget.
    pub fn setRasterBudget(self: *Renderer, bytes: usize) !void {
        try self.setImageBudget(bytes);
    }
    pub fn rasterStats(self: *const Renderer) drawing.RasterStats {
        return .{ .images = self.imageStats(), .coverage = self.coverageStats(), .resident_entries = self.images.totalEntries(), .pixel_bytes = self.images.totalBytes(), .budget_bytes = self.images.stats.budget_bytes, .peak_reserved_bytes = self.images.raster_peak_bytes };
    }
    pub fn uploadImage(self: *Renderer, view: drawing.ImageView) !void {
        try self.uploadImageMode(view, false);
    }
    pub fn uploadDynamicImage(self: *Renderer, view: drawing.ImageView) !void {
        try self.uploadImageMode(view, true);
    }
    fn uploadImageMode(self: *Renderer, view: drawing.ImageView, dynamic: bool) !void {
        try view.validate();
        self.images.stats.upload_requests +%= 1;
        if (self.images.findCoverage(view.identity) != null) return error.RasterIdentityConflict;
        if (self.images.find(view.identity)) |slot| {
            if (dynamic and !self.images.entries[slot].?.dynamic) return error.ImageNotDynamic;
            self.images.touch(slot);
            return;
        }
        const charge = view.pixelBytes() * @as(usize, if (dynamic) 2 else 1);
        if (charge > self.images.stats.budget_bytes) return error.ImageBudgetExceeded;
        if (self.native == null) self.native = zlc_create() orelse return error.OutOfMemory;
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        self.images.stats.peak_reserved_bytes = @max(self.images.stats.peak_reserved_bytes, self.images.stats.pixel_bytes + charge);
        self.images.reserveCandidate(charge);
        if ((if (dynamic) zlc_prepare_dynamic_image(self.native.?, view.levels.ptr, @intCast(view.levels.len)) else zlc_prepare_image(self.native.?, view.levels.ptr, @intCast(view.levels.len))) != 0) return error.ImageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.oldest().?, true);
        const slot = self.images.empty().?;
        zlc_commit_image(self.native.?, @intCast(slot));
        self.images.commitCharged(slot, view, dynamic, charge);
    }
    pub fn updateImage(self: *Renderer, old_identity: u64, view: drawing.ImageView) !void {
        const slot = try self.images.updateSlot(old_identity, view);
        if (self.images.entries[slot].?.view.identity == view.identity) return;
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        if (zlc_update_image(self.native.?, @intCast(slot), view.levels.ptr, @intCast(view.levels.len)) != 0) return error.ImageUpdateFailed;
        self.images.replace(slot, view);
    }
    pub fn injectImageUploadFailureForTest(self: *Renderer, one_based_mip: u32) void {
        if (self.native) |native| zlc_image_fault(native, one_based_mip);
    }
    pub fn injectImageUpdateFailureForTest(self: *Renderer, one_based_mip: u32) void {
        self.injectImageUploadFailureForTest(one_based_mip);
    }
    fn dropImage(self: *Renderer, slot: usize, eviction: bool) void {
        zlc_release_image(self.native.?, @intCast(slot));
        self.images.drop(slot, eviction);
    }
    pub fn releaseImage(self: *Renderer, identity: u64) !bool {
        const slot = self.images.find(identity) orelse return false;
        try self.images.entries[slot].?.view.lease.checkOwner();
        self.dropImage(slot, false);
        return true;
    }
    pub fn setImageBudget(self: *Renderer, bytes: usize) !void {
        if (bytes == 0 or bytes > drawing.max_image_budget) return error.InvalidImageBudget;
        try self.images.checkOwners();
        self.images.stats.budget_bytes = bytes;
        while (self.images.totalBytes() > bytes) self.dropImage(self.images.oldest().?, true);
    }
    pub fn imageStats(self: *const Renderer) drawing.ImageStats {
        var stats = self.images.stats;
        if (self.native) |native| {
            stats.native_objects = zlc_image_objects(native);
            stats.native_creations = zlc_image_creations(native);
        }
        return stats;
    }
    pub fn image(self: *Renderer, view: drawing.ImageView, destination: Rect, options: drawing.ImageOptions) !void {
        const native = self.native orelse return error.NoSurface;
        const plan = try drawing.planImage(view, .{ .x = destination.x, .y = destination.y, .width = destination.width, .height = destination.height }, options, zlc_scale(native));
        if (plan.destination.width == 0 or plan.destination.height == 0 or plan.opacity == 0) return;
        const slot = try self.images.lookup(view.identity);
        if (zlc_image(native, @intCast(slot), &plan) != 0) return error.DrawImageFailed;
    }
    pub fn hasSurface(self: *const Renderer) bool {
        return if (self.native) |native| zlc_has_surface(native) != 0 else false;
    }
    pub fn begin(self: *Renderer, paint: z.Paint) !void {
        _ = try geometry.validateSurface(paint.size.width, paint.size.height, paint.size.scale);
        if (self.native == null) self.native = zlc_create() orelse return error.OutOfMemory;
        if (self.layer_plan) |plan| if (!plan.matches(paint.size)) return error.LayersRequired;
        const result = zlc_begin(self.native.?, paint.size.width, paint.size.height, paint.size.scale);
        if (result == 4) return error.SurfaceModeMismatch;
        if (result != 0) return error.CreateSurfaceFailed;
        if (self.layer_plan != null) self.layer_active = true;
    }
    pub fn end(self: *Renderer, paint: z.Paint) void {
        self.endChecked(paint) catch {};
    }
    pub fn endChecked(self: *Renderer, paint: z.Paint) !void {
        const result = zlc_end_checked(self.native.?, paint.native_context);
        if (result == 4) return error.SurfaceModeMismatch;
        self.layer_active = false;
        if (result != 0) return error.PresentSurfaceFailed;
    }
    pub fn fill(self: *Renderer, rect: Rect, color: u32) void {
        zlc_fill(self.native.?, rect.x, rect.y, rect.width, rect.height, color);
    }
    pub fn text(self: *Renderer, rect: Rect, utf8: []const u8, color: u32) !void {
        if (utf8.len > 64 * 1024) return error.TextTooLong;
        if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
        if (zlc_text(self.native.?, rect.x, rect.y, rect.width, rect.height, utf8.ptr, @intCast(utf8.len), color) != 0) return error.DrawTextFailed;
    }
    pub fn preparedText(self: *Renderer, view: drawing.PreparedTextView, origin: drawing.Point, tint: geometry.Color) !void {
        try view.validate();
        if (view.platform != .linux) return error.PreparedPlatformMismatch;
        const native = self.native orelse return error.NoSurface;
        if (zlc_scale(native) != view.coverage.scale) return error.PreparedDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        if (zlc_prepared(native, view.native_coverage.?, origin.x, origin.y, view.coverage.scale, view.coverage.origin_x, view.coverage.origin_y, if (view.clip) |*r| r else null, tint.rgba()) != 0) return error.DrawPreparedTextFailed;
    }
    pub fn replay(self: *Renderer, list: []const commands.Command, text_bytes: []const u8) !void {
        try self.replayWithResources(list, text_bytes, &.{});
    }
    pub fn replayBuffer(self: *Renderer, buffer: *const commands.Buffer) !void {
        try self.replayWithGaussianResources(buffer.commands(), buffer.textBytes(), buffer.brushResources(), buffer.preparedTextResources(), buffer.imageResources(), buffer.coverageResources(), buffer.transformResources(), buffer.filterResources());
    }
    pub fn replayWithResources(self: *Renderer, list: []const commands.Command, text_bytes: []const u8, resources: []const commands.brushes.Stored) !void {
        try self.replayWithTextResources(list, text_bytes, resources, &.{});
    }
    pub fn replayWithTextResources(self: *Renderer, list: []const commands.Command, text_bytes: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView) !void {
        try self.replayWithImageResources(list, text_bytes, resources, prepared, &.{});
    }
    pub fn replayWithImageResources(self: *Renderer, list: []const commands.Command, text_bytes: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView) !void {
        try self.replayWithRasterResources(list, text_bytes, resources, prepared, image_resources, &.{});
    }
    pub fn replayWithRasterResources(self: *Renderer, list: []const commands.Command, text_bytes: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView) !void {
        return self.replayWithScopeResources(list, text_bytes, resources, prepared, image_resources, coverage_resources, &.{});
    }
    pub fn replayWithScopeResources(self: *Renderer, list: []const commands.Command, text_bytes: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, transforms: []const layers.NativeTransform) !void {
        return self.replayWithGaussianResources(list, text_bytes, resources, prepared, image_resources, coverage_resources, transforms, &.{});
    }
    pub fn replayWithGaussianResources(self: *Renderer, list: []const commands.Command, text_bytes: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, transforms: []const layers.NativeTransform, filters: []const gaussian.View) !void {
        errdefer self.abort();
        try commands.rejectTextures(list);
        if (resources.len > commands.brushes.max_brushes) return error.BrushesFull;
        for (resources) |*resource| try resource.validate();
        const layer_plan: ?layers.Plan = self.layer_plan;
        _ = try commands.preflightGaussianScopes(list, if (layer_plan) |p| p.options.max_depth else 0, if (layer_plan) |p| p.options.size.scale else 1, coverage_resources, if (layer_plan) |p| p.options.legacy_text == .grayscale else true, layer_plan, transforms, filters, if (filters.len != 0) self.gaussianCapacity() else null);
        var depth: usize = 0;
        defer while (self.layer_plan == null and depth != 0) : (depth -= 1) {
            zlc_pop_clip(self.native.?);
        };
        for (list) |op| switch (op) {
            .fill => |fill_command| {
                if (!layout.validRect(fill_command.bounds)) return error.InvalidGeometry;
                self.fill(fill_command.bounds, fill_command.color);
            },
            .shape => |value| {
                const p = try geometry.plan(value);
                if (zlc_shape(self.native.?, p.bounds.x, p.bounds.y, p.bounds.width, p.bounds.height, p.radius, p.stroke_width, p.color.rgba()) != 0) return error.DrawShapeFailed;
            },
            .gradient => |value| {
                if (value.brush >= resources.len) return error.MissingResources;
                const p = try geometry.plan(.{ .bounds = value.bounds, .radius = value.radius, .stroke_width = value.stroke_width, .color = geometry.Color.rgb(0) });
                if (resources[value.brush].isTransparent()) continue;
                var surface: cpu_gradient.Surface = undefined;
                if (zlc_gradient_surface(self.native.?, &surface) != 0) return error.DrawGradientFailed;
                const dirty = if (zlc_layer_transparent(self.native.?) != 0) cpu_gradient.drawTransparent(surface, p, &resources[value.brush]) else cpu_gradient.draw(surface, p, &resources[value.brush]);
                zlc_gradient_dirty(self.native.?, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top);
            },
            .text => |value| {
                if (!layout.validRect(value.bounds)) return error.InvalidGeometry;
                if (value.offset > text_bytes.len or value.len > text_bytes.len - value.offset) return error.InvalidTextRange;
                try self.text(value.bounds, text_bytes[value.offset..][0..value.len], value.color);
            },
            .prepared_text => |value| {
                if (value.resource >= prepared.len) return error.MissingResources;
                try self.preparedText(prepared[value.resource], value.origin, value.color);
            },
            .coverage => |value| {
                if (value.resource >= coverage_resources.len) return error.MissingResources;
                try self.coverage(coverage_resources[value.resource], value.origin, value.color);
            },
            .texture => unreachable, // Whole batch rejected before drawing.
            .image => |value| {
                if (value.resource >= image_resources.len) return error.MissingResources;
                try self.image(image_resources[value.resource], value.destination, .{ .alignment = value.alignment, .fit = value.fit, .sampling = value.sampling, .opacity = value.opacity });
            },
            .begin_group => |value| {
                const r = value.bounds;
                const bounds: drawing.Rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
                const options = try commands.groupOptions(value, coverage_resources);
                if (value.filter_slot == commands.no_filter) try self.beginGroup(bounds, options) else try self.beginGaussian(bounds, options, filters[value.filter_slot]);
            },
            .end_group => try self.endGroup(),
            .begin_transform => |slot| try self.beginTransform(transforms[slot]),
            .end_transform => try self.endTransform(),
            .push_clip => |rect| {
                if (depth == 32) return error.ClipStackFull;
                if (!layout.validRect(rect)) return error.InvalidGeometry;
                zlc_push_clip(self.native.?, rect.x, rect.y, rect.width, rect.height);
                depth += 1;
            },
            .pop_clip => {
                if (depth == 0) return error.ClipStackEmpty;
                zlc_pop_clip(self.native.?);
                depth -= 1;
            },
        };
        if (depth != 0) return error.UnbalancedClips;
    }
    pub fn deinit(self: *Renderer) void {
        if (self.native) |native| zlc_destroy(native);
        self.images.clear();
        self.* = .{};
    }
    pub fn brushStats(self: *const Renderer) BrushStats {
        var stats: BrushStats = .{};
        if (self.native) |native| zlc_brush_stats(native, &stats.creations, &stats.evictions, &stats.cached);
        return stats;
    }
};
