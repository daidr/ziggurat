const std = @import("std");
const z = @import("ziggurat");
pub const commands = @import("commands.zig");
const command = commands;
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const drawing = @import("ziggurat_drawing_resources");
const image_cache = @import("image_cache.zig");
const layers = @import("layers.zig");
const gpu_resources = @import("gpu_resources.zig");
const transform_precision = @import("gpu_transform_precision.zig");
const interpolation = @import("gradient_interpolation_gpu.zig");
const gaussian = @import("gaussian_filter.zig");
const gaussian_scope = @import("gaussian_scope.zig");
const gaussian_precision = @import("gaussian_gpu_precision.zig");

test "gradient spread GPU preflight rejects the whole used buffer and skips inert resources" {
    var buffer: commands.Buffer = .{};
    defer buffer.reset();
    const rect: layout.Rect = .{ .x = 0, .y = 0, .width = 8, .height = 4 };
    const stops = [_]commands.brushes.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 1, .color = .rgb(0xffffff) } };
    for ([_]commands.brushes.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| {
        buffer.reset();
        try buffer.fill(rect, 0xff0000);
        try buffer.gradientRect(rect, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 4 }, .stops = &stops, .spread = .repeat, .interpolation = space } });
        const count = buffer.len;
        inline for (.{ false, true }) |prepared| try std.testing.expectError(error.UnsupportedGradientPrecision, Renderer.preflightGradientPrecisionPrepared(buffer.commands(), buffer.brushResources(), 1, prepared));
        try std.testing.expectEqual(count, buffer.len);
        // Merely retaining an unused periodic brush must not deny an
        // otherwise ordinary batch, nor must zero-size/transparent paints.
        try Renderer.preflightGradientPrecisionPrepared(buffer.commands()[0..1], buffer.brushResources(), 1, true);
        buffer.storage[1].gradient.bounds.width = 0;
        try Renderer.preflightGradientPrecisionPrepared(buffer.commands(), buffer.brushResources(), 1, true);
        buffer.storage[1].gradient.bounds.width = 8;
        for (buffer.brush_storage[0].stops[0..buffer.brush_storage[0].len]) |*stop| stop.color.a = 0;
        try Renderer.preflightGradientPrecisionPrepared(buffer.commands(), buffer.brushResources(), 1, true);
    }
}
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});

extern fn zgpu_create(c_int, *i32) ?*anyopaque;
extern fn zgpu_create_in_domain(*anyopaque, *i32) ?*anyopaque;
extern fn zgpu_create_offscreen(*anyopaque, *i32) ?*anyopaque;
extern fn zgpu_begin_offscreen(*anyopaque) i32;
extern fn zgpu_end_offscreen(*anyopaque) i32;
extern fn zgpu_commit_offscreen(*anyopaque) void;
extern fn zgpu_offscreen_metadata_size() usize;
extern fn zgpu_texture(*anyopaque, *const drawing.GpuTextureToken, *const drawing.ImagePlan) i32;
extern fn zgpu_begin(*anyopaque, ?*anyopaque, u32, u32, f32) i32;
extern fn zgpu_fill(*anyopaque, f32, f32, f32, f32, u32) void;
extern fn zgpu_shape(*anyopaque, f32, f32, f32, f32, f32, f32, u32) i32;
extern fn zgpu_gradient(*anyopaque, f32, f32, f32, f32, f32, f32, *const commands.brushes.Native) i32;
extern fn zgpu_brush_stats(*anyopaque, *u32, *u32, *u32) void;
extern fn zgpu_gradient_stats(*anyopaque, *u32, *u32, *u64, *u32) void;
extern fn zgpu_interpolation_metadata_size() usize;
extern fn zgpu_interpolation_create_candidate(*anyopaque, *anyopaque, u32, *i32) ?*anyopaque;
extern fn zgpu_interpolation_environment(*anyopaque, *?*anyopaque, *?*anyopaque) i32;
extern fn zgpu_interpolation_context_current(*anyopaque, *anyopaque) c_int;
extern fn zgpu_interpolation_take(*anyopaque) ?*anyopaque;
extern fn zgpu_interpolation_dispose(?*anyopaque) usize;
extern fn zgpu_interpolation_install(*anyopaque, *anyopaque, *anyopaque) i32;
extern fn zgpu_interpolation_ready(*anyopaque) c_int;
extern fn zgpu_interpolation_target_supported(*anyopaque) c_int;
extern fn zgpu_interpolation_stats(*anyopaque, *GradientInterpolationStats) void;
extern fn zgpu_interpolation_failure(*anyopaque, i32) i32;
extern fn zgpu_gradient_interpolated(*anyopaque, f32, f32, f32, f32, f32, f32, *const commands.brushes.Native, *const interpolation.Packet) i32;
extern fn zgpu_geometry_stats(*anyopaque, *u32, *u32, *u32) void;
extern fn zgpu_text(*anyopaque, f32, f32, f32, f32, u32, [*]const u16, u32, u32, f32, u16, c_int, c_int) void;
extern fn zgpu_prepared(*anyopaque, *anyopaque, f32, f32, ?*const drawing.Rect, u32) void;
extern fn zgpu_scale(*anyopaque) f32;
extern fn zgpu_push_clip(*anyopaque, f32, f32, f32, f32) void;
extern fn zgpu_pop_clip(*anyopaque) void;
extern fn zgpu_abort(*anyopaque) void;
extern fn zgpu_end(*anyopaque) i32;
extern fn zgpu_destroy(*anyopaque) void;
extern fn zgpu_inject_loss(*anyopaque, c_int) void;
extern fn zgpu_inject_busy(*anyopaque) void;
extern fn zgpu_resource_count() u32;
extern fn zgpu_stats(*anyopaque, *u32, *u32, *u32, *u32, *u32, *u32) void;
extern fn zgpu_test_pixel(*anyopaque, u32, u32, *u32) i32;
extern fn zgpu_test_pixels(*anyopaque, u32, u32, [*]u32) i32;
extern fn zgpu_test_text_pixels(*anyopaque, u32, u32, u32, u32, u32, *u32) i32;
extern fn zgpu_test_surface(*anyopaque) ?*anyopaque;
extern fn zgpu_test_swapchain_window(*anyopaque) ?*anyopaque;
extern fn zgpu_frame_ready(*anyopaque) ?*anyopaque;
extern fn zgpu_prepare_image(*anyopaque, [*]const drawing.ImageLevel, u32) i32;
extern fn zgpu_prepare_dynamic_image(*anyopaque, [*]const drawing.ImageLevel, u32) i32;
extern fn zgpu_update_image(*anyopaque, u32, [*]const drawing.ImageLevel, u32) i32;
extern fn zgpu_commit_image(*anyopaque, u32) void;
extern fn zgpu_release_image(*anyopaque, u32) void;
extern fn zgpu_image_fault(*anyopaque, u32) void;
extern fn zgpu_image_loss_fault(*anyopaque) void;
extern fn zgpu_image_update_loss_at(*anyopaque, u32) void;
extern fn zgpu_image(*anyopaque, u32, *const drawing.ImagePlan) i32;
extern fn zgpu_image_stats(*anyopaque, *u64, *u32, *u64) void;

pub const Driver = enum { hardware, warp };
pub const Options = struct {
    /// Used only without an explicit domain; otherwise its driver is authority.
    driver: Driver = .hardware,
    domain: ?*gpu_resources.DeviceDomain = null,
    /// Required if the caller watches this renderer's borrowed ready handle.
    /// Keep the slot stable until deinit; loss/stop clears it before CloseHandle.
    native_wait_slot: ?*?z.NativeWaitToken = null,
};
/// presents counts successful Present calls, including an occluded hidden window.
/// It does not establish that a frame appeared on a physical display.
pub const Stats = struct { device_creations: u32 = 0, target_creations: u32 = 0, resizes: u32 = 0, presents: u32 = 0, device_losses: u32 = 0, busy_presents: u32 = 0 };
pub const geometry_cache_capacity = 32;
pub const GeometryStats = struct { creations: u32 = 0, evictions: u32 = 0, cached: u32 = 0 };
pub const BrushStats = struct { creations: u32 = 0, evictions: u32 = 0, cached: u32 = 0 };
pub const GradientStats = struct { effect_creations: u32 = 0, draws: u32 = 0, constant_uploads: u64 = 0, device_restores: u32 = 0 };
pub const GradientInterpolationStats = interpolation.Stats;

/// Adapter-owned COM references plus explicitly initialized native states.
/// This does not count driver or system caches and browser/process memory.
pub fn globalResourceCount() u32 {
    return zgpu_resource_count();
}

/// Main-thread renderer. init explicitly allocates its native state once.
/// Hardware and WARP are separate choices; failure never silently changes driver.
extern fn zgpu_prepare_coverage(*anyopaque, *const drawing.NativeCoverage) i32;
extern fn zgpu_coverage(*anyopaque, u32, f32, f32, f32, u32) i32;
extern fn zgpu_coverage_stats(*anyopaque, *u64, *u32, *u64) void;
extern fn zgpu_coverage_scratch_peak(*anyopaque) usize;

extern fn zgpu_layer_create(*anyopaque, u32, u32, f32, u32, u32, u32, *i32) ?*anyopaque;
extern fn zgpu_layer_free(*anyopaque) void;
extern fn zgpu_layer_commit(*anyopaque, *anyopaque) void;
extern fn zgpu_layer_release(*anyopaque) void;
extern fn zgpu_layer_stats(*anyopaque, *layers.NativeStats) void;
extern fn zgpu_layer_begin_group(*anyopaque, *const layers.NativeGroup) i32;
extern fn zgpu_layer_end_group(*anyopaque) i32;
extern fn zgpu_layer_begin_transform(*anyopaque, *const layers.NativeTransform) i32;
extern fn zgpu_layer_end_transform(*anyopaque) i32;
extern fn zgpu_layer_pixels(*anyopaque, c_int, [*]u32, u32, u32) i32;
extern fn zgpu_discard(*anyopaque) void;
extern fn zgpu_suspend_surface(*anyopaque) c_int;
extern fn zgpu_restore_surface(*anyopaque) void;
extern fn zgpu_layer_fault(*anyopaque, u32) void;
extern fn zgpu_layer_metadata_size() usize;
extern fn zgpu_gaussian_metadata_size() usize;
extern fn zgpu_gaussian_environment(*anyopaque, *?*anyopaque, *?*anyopaque) i32;
extern fn zgpu_gaussian_create_candidate(*anyopaque, *anyopaque, *const gaussian_scope.Capacity, u32, u32, u32, u32, *i32) ?*anyopaque;
extern fn zgpu_gaussian_dispose(*anyopaque) void;
extern fn zgpu_layer_create_gaussian(*anyopaque, u32, u32, f32, u32, u32, u32, *anyopaque, *i32) ?*anyopaque;
extern fn zgpu_layer_gaussian_capacity(*anyopaque, *gaussian_scope.Capacity) c_int;
extern fn zgpu_layer_gaussian_passes(*anyopaque) u64;
extern fn zgpu_layer_gaussian_reserved(*anyopaque) usize;
extern fn zgpu_layer_candidate_gaussian_reserved(*anyopaque) usize;
extern fn zgpu_layer_release_gaussian(*anyopaque) i32;
extern fn zgpu_layer_begin_gaussian(*anyopaque, *const layers.NativeGroup, *const gaussian_scope.Capture, *const gaussian.arithmetic.Kernel) i32;

pub const Renderer = struct {
    native: ?*anyopaque = null,
    last_hresult: i32 = 0,
    active: bool = false,
    offscreen: bool = false,
    domain: ?*gpu_resources.DeviceDomain = null,
    domain_borrow: ?gpu_resources.DeviceDomain.Borrow = null,
    render_scope: ?z.AppCallbackScope = null,
    images: image_cache.Cache = .{},
    layer_plan: ?layers.Plan = null,
    layer_candidate_peak: usize = 0,
    owner: ?std.Thread.Id = null,
    interpolation_mutating: bool = false,
    /// An unpublished candidate must be destroyed or committed before its
    /// renderer is deinitialized. It is not a domain-owned device-loss cache.
    pub const LayerCandidate = struct { native: *anyopaque, plan: layers.Plan, owner: *Renderer, generation: u64 };
    /// Linear unpublished owner. Commit or destroy before deinitializing the
    /// renderer. It holds the domain metadata reservation through final free.
    pub const GradientInterpolationCandidate = struct { native: *anyopaque, context: *anyopaque, owner: *Renderer, generation: u64, metadata: usize };
    fn checkInterpolationOwner(self: *const Renderer) !void {
        if (self.native == null) return error.NotInitialized;
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    fn gradientInterpolationReadyUnchecked(self: *const Renderer) bool {
        return if (self.native) |native| zgpu_interpolation_ready(native) != 0 else false;
    }
    pub fn gradientInterpolationReady(self: *const Renderer) !bool {
        try self.checkInterpolationOwner();
        return self.gradientInterpolationReadyUnchecked();
    }
    pub fn checkGradientInterpolationPrepared(self: *Renderer) !bool {
        try self.checkInterpolationOwner();
        if (self.active or self.interpolation_mutating) return error.Busy;
        try self.checkFrame();
        self.last_hresult = 0;
        return self.gradientInterpolationReadyUnchecked();
    }
    pub fn gradientInterpolationStats(self: *const Renderer) !GradientInterpolationStats {
        try self.checkInterpolationOwner();
        var metrics: GradientInterpolationStats = .{};
        if (self.native) |native| zgpu_interpolation_stats(native, &metrics);
        return metrics;
    }
    pub fn createGradientInterpolationCandidate(self: *Renderer) !GradientInterpolationCandidate {
        return self.createGradientInterpolationCandidateWithFailureForTest(0);
    }
    pub fn createGradientInterpolationCandidateWithFailureForTest(self: *Renderer, stage: u32) !GradientInterpolationCandidate {
        try self.checkInterpolationOwner();
        const scope = try self.operation(false);
        defer scope.end();
        if (self.active or self.interpolation_mutating) return error.Busy;
        if (stage > 4) return error.InvalidFault;
        if (self.gradientInterpolationReadyUnchecked()) return error.AlreadyPrepared;
        self.interpolation_mutating = true;
        errdefer self.interpolation_mutating = false;
        const metadata = zgpu_interpolation_metadata_size();
        if (self.domain) |domain| try domain.reserveRendererMetadata(self.domain_borrow.?, metadata);
        errdefer if (self.domain) |domain| domain.releaseRendererMetadata(self.domain_borrow.?, metadata);
        var factory: ?*anyopaque = null;
        var context: ?*anyopaque = null;
        try self.result(zgpu_interpolation_environment(self.native.?, &factory, &context));
        try self.checkFrame();
        const candidate = zgpu_interpolation_create_candidate(factory.?, context.?, stage, &self.last_hresult) orelse {
            try self.result(zgpu_interpolation_failure(self.native.?, self.last_hresult));
            return error.GradientPreparationFailed;
        };
        errdefer _ = zgpu_interpolation_dispose(candidate);
        try self.checkFrame();
        if (zgpu_interpolation_context_current(self.native.?, context.?) == 0) return error.DeviceLost;
        return .{ .native = candidate, .context = context.?, .owner = self, .metadata = metadata, .generation = if (self.domain_borrow) |borrow| borrow.epoch.generation else 0 };
    }
    pub fn destroyGradientInterpolationCandidate(candidate: GradientInterpolationCandidate) void {
        const self = candidate.owner;
        const scope = self.operation(true) catch unreachable;
        defer scope.end();
        _ = zgpu_interpolation_dispose(candidate.native);
        if (self.domain) |domain| domain.releaseRendererMetadata(self.domain_borrow.?, candidate.metadata);
        self.interpolation_mutating = false;
    }
    pub fn checkGradientInterpolationCandidate(self: *Renderer, candidate: GradientInterpolationCandidate) !void {
        try self.checkInterpolationOwner();
        if (candidate.owner != self or !self.interpolation_mutating or self.active) return error.InvalidGradientCandidate;
        try self.checkFrame();
        if (self.domain_borrow) |borrow| if (candidate.generation != borrow.epoch.generation) return error.StaleGradientCandidate;
        if (zgpu_interpolation_context_current(self.native.?, candidate.context) == 0) return error.DeviceLost;
    }
    /// Retire an earlier, device-lost owner before publishing the candidate.
    /// The caller rechecks its attachment after this last foreign COM release.
    pub fn retireGradientInterpolation(self: *Renderer, candidate: GradientInterpolationCandidate) !void {
        try self.checkGradientInterpolationCandidate(candidate);
        const scope = try self.operation(false);
        defer scope.end();
        const bytes = zgpu_interpolation_dispose(zgpu_interpolation_take(self.native.?));
        if (self.domain) |domain| domain.releaseRendererMetadata(self.domain_borrow.?, bytes);
    }
    /// This final publication makes no foreign call and consumes the candidate.
    pub fn commitGradientInterpolationCandidate(self: *Renderer, candidate: GradientInterpolationCandidate) !void {
        try self.checkGradientInterpolationCandidate(candidate);
        try self.result(zgpu_interpolation_install(self.native.?, candidate.native, candidate.context));
        self.interpolation_mutating = false;
    }
    pub fn prepareGradientInterpolation(self: *Renderer) !void {
        if (try self.checkGradientInterpolationPrepared()) return;
        const candidate = try self.createGradientInterpolationCandidate();
        errdefer destroyGradientInterpolationCandidate(candidate);
        try self.retireGradientInterpolation(candidate);
        try self.commitGradientInterpolationCandidate(candidate);
    }
    pub fn releaseGradientInterpolation(self: *Renderer) !void {
        try self.checkInterpolationOwner();
        const scope = try self.operation(true);
        defer scope.end();
        if (self.active or self.interpolation_mutating) return error.Busy;
        self.interpolation_mutating = true;
        defer self.interpolation_mutating = false;
        const bytes = zgpu_interpolation_dispose(zgpu_interpolation_take(self.native.?));
        if (self.domain) |domain| domain.releaseRendererMetadata(self.domain_borrow.?, bytes);
    }
    const Operation = struct {
        domain: ?*gpu_resources.DeviceDomain = null,
        scope: ?z.AppCallbackScope = null,
        fn end(self: Operation) void {
            if (self.domain) |domain| domain.endRenderer();
            if (self.scope) |scope| scope.end();
        }
    };
    fn operation(self: *Renderer, cleanup: bool) !Operation {
        const domain = self.domain orelse return .{};
        const scope = if (cleanup) try domain.beginRendererCleanup() else domain.beginRenderer() catch |err| {
            self.last_hresult = 0;
            return err;
        };
        return .{ .domain = domain, .scope = scope };
    }
    fn checkFrame(self: *Renderer) !void {
        if (self.domain) |domain| try domain.checkRendererReady();
    }
    fn assertOwner(self: *const Renderer) void {
        if (self.domain) |domain| domain.checkRendererOwner() catch unreachable;
    }
    pub fn createLayerCandidate(self: *Renderer, _: std.mem.Allocator, options: layers.Options) !LayerCandidate {
        return self.createPlanCandidate(try layers.Plan.init(options, .gpu));
    }
    pub fn createTransformCandidate(self: *Renderer, _: std.mem.Allocator, options: layers.TransformOptions) !LayerCandidate {
        return self.createPlanCandidate(try layers.Plan.initTransforms(options, .gpu));
    }
    pub fn layerMetadataBytes() usize {
        return zgpu_layer_metadata_size();
    }
    pub fn gaussianMetadataBytes() usize {
        return zgpu_gaussian_metadata_size();
    }
    pub fn createGaussianCandidate(self: *Renderer, _: std.mem.Allocator, plan: gaussian_scope.Plan) !LayerCandidate {
        return self.createGaussianCandidateInternal(plan, 0);
    }
    pub fn createGaussianCandidateWithFailureForTest(self: *Renderer, _: std.mem.Allocator, plan: gaussian_scope.Plan, stage: u32) !LayerCandidate {
        return self.createGaussianCandidateInternal(plan, stage);
    }
    fn createGaussianCandidateInternal(self: *Renderer, plan: gaussian_scope.Plan, stage: u32) !LayerCandidate {
        const scope = try self.operation(false);
        defer scope.end();
        try self.checkFrame();
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        const metadata = gaussianMetadataBytes();
        if (self.domain) |domain| try domain.reserveRendererMetadata(self.domain_borrow.?, metadata);
        errdefer if (self.domain) |domain| domain.releaseRendererMetadata(self.domain_borrow.?, metadata);
        var device: ?*anyopaque = null;
        var context: ?*anyopaque = null;
        try self.result(zgpu_gaussian_environment(native, &device, &context));
        try self.checkFrame();
        const program = zgpu_gaussian_create_candidate(device.?, context.?, &plan.capacity, plan.layers.pool_size.width, plan.layers.pool_size.height, plan.layers.options.max_depth, stage, &self.last_hresult) orelse {
            try self.result(self.last_hresult);
            return error.GaussianPreparationFailed;
        };
        var consumed = false;
        errdefer if (!consumed) zgpu_gaussian_dispose(program);
        try self.checkFrame();
        if (zgpu_interpolation_context_current(native, context.?) == 0) return error.DeviceLost;
        const options = plan.layers.options;
        self.layer_candidate_peak = @max(self.layer_candidate_peak, self.layerStats().pixel_bytes + plan.pixel_bytes);
        consumed = true; // native construction consumes program even on failure
        const candidate = zgpu_layer_create_gaussian(native, options.size.width, options.size.height, options.size.scale, options.max_depth, plan.layers.pool_size.width, plan.layers.pool_size.height, program, &self.last_hresult) orelse {
            try self.result(self.last_hresult);
            return error.GaussianPreparationFailed;
        };
        return .{ .native = candidate, .plan = plan.layers, .owner = self, .generation = if (self.domain_borrow) |borrow| borrow.epoch.generation else 0 };
    }
    pub fn gaussianCapacity(self: *const Renderer) ?gaussian_scope.Capacity {
        var value: gaussian_scope.Capacity = undefined;
        return if (self.native != null and zgpu_layer_gaussian_capacity(self.native.?, &value) != 0) value else null;
    }
    pub fn gaussianPassesForTest(self: *const Renderer) u64 {
        return if (self.native) |native| zgpu_layer_gaussian_passes(native) else 0;
    }
    pub fn gaussianMetadataReserved(self: *const Renderer) usize {
        return if (self.native) |native| zgpu_layer_gaussian_reserved(native) else 0;
    }
    pub fn layerPlan(self: *const Renderer) ?layers.Plan {
        return self.layer_plan;
    }
    pub fn prepareGaussian(self: *Renderer, allocator: std.mem.Allocator, options: gaussian_scope.Options) !void {
        const candidate = try self.createGaussianCandidate(allocator, try gaussian_scope.Plan.init(options, .gpu, self.transformOptions()));
        errdefer destroyLayerCandidate(candidate);
        try self.commitLayerCandidate(candidate);
    }
    fn createPlanCandidate(self: *Renderer, plan: layers.Plan) !LayerCandidate {
        const scope = try self.operation(false);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        const options = plan.options;
        const native = self.native orelse return error.NotInitialized;
        self.layer_candidate_peak = @max(self.layer_candidate_peak, self.layerStats().pixel_bytes + plan.pixel_bytes);
        const candidate = zgpu_layer_create(native, options.size.width, options.size.height, options.size.scale, options.max_depth, plan.pool_size.width, plan.pool_size.height, &self.last_hresult) orelse {
            try self.result(self.last_hresult);
            return error.LayerPreparationFailed;
        };
        return .{ .native = candidate, .plan = plan, .owner = self, .generation = if (self.domain_borrow) |borrow| borrow.epoch.generation else 0 };
    }
    pub fn destroyLayerCandidate(candidate: LayerCandidate) void {
        const bytes = zgpu_layer_candidate_gaussian_reserved(candidate.native);
        zgpu_layer_free(candidate.native);
        if (bytes != 0) if (candidate.owner.domain) |domain| domain.releaseRendererMetadata(candidate.owner.domain_borrow.?, bytes);
    }
    pub fn commitLayerCandidate(self: *Renderer, candidate: LayerCandidate) !void {
        const scope = try self.operation(false);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        if (candidate.owner != self or self.native == null) return error.InvalidLayerCandidate;
        if (self.domain_borrow) |borrow| if (candidate.generation != borrow.epoch.generation) return error.StaleLayerCandidate;
        const previous = zgpu_layer_gaussian_reserved(self.native.?);
        zgpu_layer_commit(self.native.?, candidate.native);
        if (previous != 0) if (self.domain) |domain| domain.releaseRendererMetadata(self.domain_borrow.?, previous);
        self.layer_plan = candidate.plan;
    }
    pub fn prepareLayers(self: *Renderer, allocator: std.mem.Allocator, options: layers.Options) !void {
        const candidate = try self.createLayerCandidate(allocator, options);
        errdefer destroyLayerCandidate(candidate);
        try self.commitLayerCandidate(candidate);
    }
    pub fn prepareTransforms(self: *Renderer, allocator: std.mem.Allocator, options: layers.TransformOptions) !void {
        const candidate = try self.createTransformCandidate(allocator, options);
        errdefer destroyLayerCandidate(candidate);
        try self.commitLayerCandidate(candidate);
    }
    pub fn transformOptions(self: *const Renderer) ?layers.TransformOptions {
        return if (self.layer_plan) |plan| plan.transformOptions() else null;
    }
    pub fn releaseLayers(self: *Renderer) !void {
        const scope = try self.operation(true);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        if (self.native) |native| {
            const bytes = zgpu_layer_gaussian_reserved(native);
            zgpu_layer_release(native);
            if (bytes != 0) if (self.domain) |domain| domain.releaseRendererMetadata(self.domain_borrow.?, bytes);
        }
        self.layer_plan = null;
    }
    pub fn injectLayerPreparationFailureForTest(self: *Renderer, one_based_plane: u32) void {
        if (self.native) |native| zgpu_layer_fault(native, one_based_plane);
    }
    pub fn layerOptions(self: *const Renderer) ?layers.Options {
        return if (self.layer_plan) |plan| plan.options else null;
    }
    pub fn layerStats(self: *const Renderer) layers.Stats {
        const plan = self.layer_plan orelse return .{ .candidate_peak_bytes = self.layer_candidate_peak };
        var values: layers.NativeStats = .{};
        zgpu_layer_stats(self.native.?, &values);
        var metrics = layers.Stats.fromNative(plan, values);
        if (self.gaussianCapacity() != null) metrics.pixel_bytes += plan.pool_plane_bytes;
        metrics.candidate_peak_bytes = self.layer_candidate_peak;
        return metrics;
    }
    pub fn releaseGaussian(self: *Renderer) !void {
        const scope = try self.operation(true);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return;
        const bytes = zgpu_layer_gaussian_reserved(native);
        try self.result(zgpu_layer_release_gaussian(native));
        if (bytes != 0) if (self.domain) |domain| domain.releaseRendererMetadata(self.domain_borrow.?, bytes);
    }
    pub fn beginGroup(self: *Renderer, group_bounds: drawing.Rect, options: layers.Group) !void {
        const descriptor = try self.groupDescriptor(group_bounds, options);
        try self.result(zgpu_layer_begin_group(self.native.?, &descriptor));
    }
    fn groupDescriptor(self: *Renderer, group_bounds: drawing.Rect, options: layers.Group) !layers.NativeGroup {
        try self.checkFrame();
        const plan = self.layer_plan orelse return error.LayersRequired;
        if (!self.active) return error.NotDrawing;
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
    pub fn beginGaussian(self: *Renderer, group_bounds: drawing.Rect, options: layers.Group, view: gaussian.View) !void {
        try view.validate();
        if (view.descriptor.radius == 0) return self.beginGroup(group_bounds, options);
        const descriptor = try self.groupDescriptor(group_bounds, options);
        const capture = try gaussian_scope.Capture.init(group_bounds, view.descriptor);
        try self.result(zgpu_layer_begin_gaussian(self.native.?, &descriptor, &capture, view.descriptor));
    }
    pub fn endGroup(self: *Renderer) !void {
        try self.checkFrame();
        if (self.layer_plan == null) return error.LayersRequired;
        if (!self.active) return error.NotDrawing;
        try self.result(zgpu_layer_end_group(self.native.?));
    }
    pub fn beginTransform(self: *Renderer, value: layers.NativeTransform) !void {
        try self.checkFrame();
        const plan = self.layer_plan orelse return error.TransformsRequired;
        try plan.validateTransform(value);
        if (!self.active) return error.NotDrawing;
        try self.result(zgpu_layer_begin_transform(self.native.?, &value));
    }
    pub fn endTransform(self: *Renderer) !void {
        try self.checkFrame();
        if (self.layer_plan == null) return error.TransformsRequired;
        if (!self.active) return error.NotDrawing;
        try self.result(zgpu_layer_end_transform(self.native.?));
    }
    /// Preserve the accepted GPU surface if a software end cannot commit.
    pub fn suspendSurface(self: *Renderer) bool {
        self.assertOwner();
        return if (self.native) |native| zgpu_suspend_surface(native) != 0 else false;
    }
    pub fn restoreSurface(self: *Renderer) void {
        self.assertOwner();
        if (self.native) |native| zgpu_restore_surface(native);
    }
    pub fn discard(self: *Renderer) void {
        self.assertOwner();
        if (self.native) |native| zgpu_discard(native);
        self.active = false;
        self.finishScope();
    }
    /// Synchronous premultiplied BGRA readback for hidden integration checks.
    pub fn readLayerPixels(self: *Renderer, front: bool, pixels: []u32) !void {
        const scope = try self.operation(false);
        defer scope.end();
        const plan = self.layer_plan orelse return error.LayersRequired;
        if (pixels.len != @as(usize, plan.options.size.width) * plan.options.size.height) return error.InvalidGeometry;
        try self.result(zgpu_layer_pixels(self.native.?, @intFromBool(front), pixels.ptr, plan.options.size.width, plan.options.size.height));
    }
    pub fn uploadCoverage(self: *Renderer, view: drawing.CoverageView) !void {
        const scope = try self.operation(false);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        try view.validate();
        self.images.coverage_stats.upload_requests +%= 1;
        if (self.images.find(view.identity) != null) return error.RasterIdentityConflict;
        if (self.images.findCoverage(view.identity)) |slot| {
            self.images.touch(slot);
            return;
        }
        const charge = @as(usize, view.coverage.width + 2) * (view.coverage.height + 2);
        if (charge > self.images.stats.budget_bytes) return error.CoverageBudgetExceeded;
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        self.images.reserveCandidate(charge);
        self.images.coverage_stats.peak_reserved_bytes = @max(self.images.coverage_stats.peak_reserved_bytes, self.images.coverage_stats.pixel_bytes + charge);
        const descriptor = view.native();
        try self.result(zgpu_prepare_coverage(native, &descriptor));
        while (self.images.needsEviction(charge)) self.dropImage(self.images.oldest().?, true);
        const slot = self.images.empty().?;
        zgpu_commit_image(native, @intCast(slot));
        self.images.commitCoverage(slot, view, charge);
    }
    pub fn releaseCoverage(self: *Renderer, identity: u64) !bool {
        const scope = try self.operation(true);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        const slot = self.images.findCoverage(identity) orelse return false;
        try self.images.coverage_entries[slot].?.view.lease.checkOwner();
        self.dropImage(slot, false);
        return true;
    }
    pub fn coverage(self: *Renderer, view: drawing.CoverageView, origin: drawing.Point, tint: geometry.Color) !void {
        try self.checkFrame();
        if (!self.active) return error.NotDrawing;
        try view.validate();
        const native = self.native orelse return error.NoSurface;
        if (zgpu_scale(native) != view.coverage.scale) return error.CoverageDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        const slot = try self.images.lookupCoverage(view.identity);
        const x = @as(f64, origin.x) + @as(f64, @floatFromInt(view.coverage.origin_x)) / view.coverage.scale;
        const y = @as(f64, origin.y) + @as(f64, @floatFromInt(view.coverage.origin_y)) / view.coverage.scale;
        if (@abs(x) > std.math.floatMax(f32) or @abs(y) > std.math.floatMax(f32)) return error.InvalidGeometry;
        try self.result(zgpu_coverage(native, @intCast(slot), @floatCast(x), @floatCast(y), view.coverage.scale, tint.rgba()));
    }
    pub fn coverageStats(self: *const Renderer) drawing.CoverageStats {
        var values = self.images.coverage_stats;
        if (self.native) |native| {
            zgpu_coverage_stats(native, &values.restores, &values.native_objects, &values.native_creations);
            values.native_scratch_peak_bytes = zgpu_coverage_scratch_peak(native);
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
        const scope = try self.operation(false);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
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
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        self.images.stats.peak_reserved_bytes = @max(self.images.stats.peak_reserved_bytes, self.images.stats.pixel_bytes + charge);
        self.images.reserveCandidate(charge);
        try self.result(if (dynamic) zgpu_prepare_dynamic_image(native, view.levels.ptr, @intCast(view.levels.len)) else zgpu_prepare_image(native, view.levels.ptr, @intCast(view.levels.len)));
        while (self.images.needsEviction(charge)) self.dropImage(self.images.oldest().?, true);
        const slot = self.images.empty().?;
        zgpu_commit_image(native, @intCast(slot));
        self.images.commitCharged(slot, view, dynamic, charge);
    }
    pub fn updateImage(self: *Renderer, old_identity: u64, view: drawing.ImageView) !void {
        const scope = try self.operation(false);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        const slot = try self.images.updateSlot(old_identity, view);
        if (self.images.entries[slot].?.view.identity == view.identity) return;
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        try self.result(zgpu_update_image(native, @intCast(slot), view.levels.ptr, @intCast(view.levels.len)));
        self.images.replace(slot, view);
    }
    fn dropImage(self: *Renderer, slot: usize, eviction: bool) void {
        zgpu_release_image(self.native.?, @intCast(slot));
        self.images.drop(slot, eviction);
    }
    pub fn releaseImage(self: *Renderer, identity: u64) !bool {
        const scope = try self.operation(true);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        const slot = self.images.find(identity) orelse return false;
        try self.images.entries[slot].?.view.lease.checkOwner();
        self.dropImage(slot, false);
        return true;
    }
    pub fn setImageBudget(self: *Renderer, bytes: usize) !void {
        const scope = try self.operation(true);
        defer scope.end();
        if (self.active) return error.AlreadyDrawing;
        if (bytes == 0 or bytes > drawing.max_image_budget) return error.InvalidImageBudget;
        try self.images.checkOwners();
        self.images.stats.budget_bytes = bytes;
        while (self.images.totalBytes() > bytes) self.dropImage(self.images.oldest().?, true);
    }
    pub fn imageStats(self: *const Renderer) drawing.ImageStats {
        var values = self.images.stats;
        if (self.native) |native| zgpu_image_stats(native, &values.restores, &values.native_objects, &values.native_creations);
        return values;
    }
    pub fn injectImageUploadFailureForTest(self: *Renderer, one_based_mip: u32) void {
        if (self.native) |native| zgpu_image_fault(native, one_based_mip);
    }
    pub fn injectImageUploadDeviceLossForTest(self: *Renderer) void {
        if (self.native) |native| zgpu_image_loss_fault(native);
    }
    pub fn injectImageUpdateFailureForTest(self: *Renderer, one_based_mip: u32) void {
        self.injectImageUploadFailureForTest(one_based_mip);
    }
    pub fn injectImageUpdateDeviceLossForTest(self: *Renderer) void {
        self.injectImageUploadDeviceLossForTest();
    }
    pub fn injectImageUpdateDeviceLossAtMipForTest(self: *Renderer, one_based_mip: u32) void {
        if (self.native) |value| zgpu_image_update_loss_at(value, one_based_mip);
    }
    pub fn image(self: *Renderer, view: drawing.ImageView, destination: layout.Rect, options: drawing.ImageOptions) !void {
        try self.checkFrame();
        if (!self.active) return error.NotDrawing;
        const plan = try drawing.planImage(view, .{ .x = destination.x, .y = destination.y, .width = destination.width, .height = destination.height }, options, zgpu_scale(self.native.?));
        if (plan.destination.width == 0 or plan.destination.height == 0 or plan.opacity == 0) return;
        const slot = try self.images.lookup(view.identity);
        try self.result(zgpu_image(self.native.?, @intCast(slot), &plan));
    }

    pub fn init(self: *Renderer, options: Options) !void {
        if (self.native != null) return error.AlreadyInitialized;
        if (options.domain) |domain| {
            const borrow = try domain.acquireRenderer(options.native_wait_slot);
            errdefer domain.releaseRenderer(borrow.slot);
            const scope = try domain.beginRenderer();
            defer {
                domain.endRenderer();
                scope.end();
            }
            const native = zgpu_create_in_domain(borrow.native, &self.last_hresult) orelse return error.GraphicsInitializationFailed;
            errdefer zgpu_destroy(native);
            try domain.checkRendererReady();
            self.native = native;
            self.domain = domain;
            self.domain_borrow = borrow;
        } else self.native = zgpu_create(if (options.driver == .warp) 1 else 0, &self.last_hresult) orelse return error.GraphicsInitializationFailed;
        self.owner = std.Thread.getCurrentId();
    }

    /// Internal surface integration: success consumes the pre-reserved borrow;
    /// failure leaves it with the caller. There is no HWND or swapchain here.
    pub fn initOffscreen(self: *Renderer, domain: *gpu_resources.DeviceDomain, borrow: gpu_resources.DeviceDomain.Borrow) !void {
        try domain.validateRendererBorrow(borrow);
        if (self.native != null) return error.AlreadyInitialized;
        const native = zgpu_create_offscreen(borrow.native, &self.last_hresult) orelse return error.GraphicsInitializationFailed;
        errdefer zgpu_destroy(native);
        try domain.checkRendererReady();
        self.native = native;
        self.domain = domain;
        self.domain_borrow = borrow;
        self.offscreen = true;
        self.owner = std.Thread.getCurrentId();
    }
    pub fn offscreenMetadataSize() usize {
        return zgpu_offscreen_metadata_size();
    }
    pub fn beginOffscreen(self: *Renderer) !void {
        const domain = self.domain orelse return error.DomainRequired;
        const scope = try domain.beginRenderer();
        errdefer {
            domain.endRenderer();
            scope.end();
        }
        if (!self.offscreen) return error.SurfaceModeMismatch;
        if (self.active) return error.AlreadyDrawing;
        if (self.interpolation_mutating) return error.Busy;
        if (self.layer_plan == null) return error.LayersRequired;
        self.last_hresult = 0;
        errdefer zgpu_discard(self.native.?);
        try self.result(zgpu_begin_offscreen(self.native.?));
        try domain.checkRendererReady();
        self.render_scope = scope;
        self.active = true;
    }
    pub fn endOffscreen(self: *Renderer) !void {
        if (self.domain) |domain| try domain.checkRendererOwner();
        if (!self.offscreen) return error.SurfaceModeMismatch;
        if (!self.active) return error.NotDrawing;
        defer self.finishScope();
        self.active = false;
        errdefer zgpu_discard(self.native.?);
        try self.checkFrame();
        try self.result(zgpu_end_offscreen(self.native.?));
        try self.checkFrame();
        zgpu_commit_offscreen(self.native.?);
    }

    pub fn begin(self: *Renderer, paint: z.Paint) !void {
        const scope = if (self.domain) |domain| try domain.beginRenderer() else null;
        errdefer if (scope) |value| {
            self.domain.?.endRenderer();
            value.end();
        };
        if (self.active) return error.AlreadyDrawing;
        if (self.offscreen) return error.SurfaceModeMismatch;
        if (self.interpolation_mutating) return error.Busy;
        self.last_hresult = 0;
        const native = self.native orelse return error.NotInitialized;
        _ = try geometry.validateSurface(paint.size.width, paint.size.height, paint.size.scale);
        if (self.layer_plan) |plan| if (!plan.matches(paint.size)) return error.LayersRequired;
        const hwnd = paint.native_window orelse c.WindowFromDC(paint.native_context);
        try self.result(zgpu_begin(native, hwnd, paint.size.width, paint.size.height, 96.0 * paint.size.scale));
        self.render_scope = scope;
        self.active = true;
    }

    pub fn replay(self: *Renderer, ops: []const command.Command, text: []const u8) !void {
        try self.replayWithResources(ops, text, &.{});
    }
    pub fn replayBuffer(self: *Renderer, buffer: *const commands.Buffer) !void {
        try self.replayWithGaussianResources(buffer.commands(), buffer.textBytes(), buffer.brushResources(), buffer.preparedTextResources(), buffer.imageResources(), buffer.coverageResources(), buffer.textureResources(), buffer.transformResources(), buffer.filterResources());
    }
    pub fn replayWithResources(self: *Renderer, ops: []const command.Command, text: []const u8, resources: []const commands.brushes.Stored) !void {
        try self.replayWithTextResources(ops, text, resources, &.{});
    }
    pub fn preparedText(self: *Renderer, view: drawing.PreparedTextView, origin: drawing.Point, tint: geometry.Color) !void {
        try self.checkFrame();
        if (!self.active) return error.NotDrawing;
        try view.validate();
        if (view.platform != .windows) return error.PreparedPlatformMismatch;
        if (zgpu_scale(self.native.?) != view.coverage.scale) return error.PreparedDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        zgpu_prepared(self.native.?, view.native_layout, origin.x, origin.y, if (view.clip) |*r| r else null, tint.rgba());
    }
    pub fn replayWithTextResources(self: *Renderer, ops: []const command.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView) !void {
        try self.replayWithImageResources(ops, text, resources, prepared, &.{});
    }
    pub fn replayWithImageResources(self: *Renderer, ops: []const command.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView) !void {
        try self.replayWithRasterResources(ops, text, resources, prepared, image_resources, &.{});
    }
    pub fn replayWithRasterResources(self: *Renderer, ops: []const command.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView) !void {
        try self.replayWithTextureResources(ops, text, resources, prepared, image_resources, coverage_resources, &.{});
    }
    pub fn replayWithTextureResources(self: *Renderer, ops: []const command.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView) !void {
        return self.replayWithScopeResources(ops, text, resources, prepared, image_resources, coverage_resources, textures, &.{});
    }
    pub fn replayWithScopeResources(self: *Renderer, ops: []const command.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView, transforms: []const layers.NativeTransform) !void {
        return self.replayWithGaussianResources(ops, text, resources, prepared, image_resources, coverage_resources, textures, transforms, &.{});
    }
    pub fn replayWithGaussianResources(self: *Renderer, ops: []const command.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView, transforms: []const layers.NativeTransform, filters: []const gaussian.View) !void {
        try self.checkFrame();
        if (!self.active) return error.NotDrawing;
        self.preflightTextures(ops, textures) catch |err| {
            self.last_hresult = 0;
            self.discard();
            return err;
        };
        errdefer if (self.layer_plan != null) self.discard() else self.abort();
        try self.replayNative(ops, text, resources, prepared, image_resources, coverage_resources, textures, transforms, filters);
    }
    fn preflightTextures(self: *Renderer, ops: []const command.Command, textures: []const drawing.TextureView) !void {
        // Validate every device-bound command before the first native draw.
        // Backdrop effects and loading indicators draw on the software plane.
        if (commands.softwareOnly(ops)) return error.SoftwareOnlyCommands;
        // Software fallback cannot consume these resources or repair a domain.
        for (ops) |op| if (op == .texture) {
            const value = op.texture;
            if (value.resource >= textures.len) return error.MissingResources;
            const view = textures[value.resource];
            try view.validate();
            const borrow = self.domain_borrow orelse return error.TextureDomainRequired;
            if (view.domain != borrow.epoch) return error.TextureDomainMismatch;
            _ = try drawing.planTexture(view, .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, .{ .alignment = value.alignment, .fit = value.fit, .sampling = value.sampling, .opacity = value.opacity }, zgpu_scale(self.native.?));
        };
    }
    /// Pure backend policy, shared by direct replay and offscreen's pre-begin
    /// gate. No native target or work-plane clear is needed to reject a frame.
    pub fn preflightGradientPrecision(ops: []const command.Command, resources: []const commands.brushes.Stored, scale: f32) !void {
        return preflightGradientPrecisionPrepared(ops, resources, scale, false);
    }
    pub fn preflightGradientPrecisionPrepared(ops: []const command.Command, resources: []const commands.brushes.Stored, scale: f32, prepared: bool) !void {
        if (resources.len > commands.brushes.max_brushes) return error.BrushesFull;
        var needs_gradient_precision = false;
        var needs_interpolation = false;
        for (resources) |*resource| {
            try resource.validate();
            needs_interpolation = needs_interpolation or resource.interpolation != .srgb;
            needs_gradient_precision = needs_gradient_precision or resource.spread != .pad or resource.kind == .conic or needs_interpolation;
        }
        if (needs_gradient_precision) for (ops) |op| {
            if (op != .gradient) continue;
            const value = op.gradient;
            if (value.brush >= resources.len) return error.MissingResources;
            const brush = &resources[value.brush];
            if (brush.isTransparent()) continue;
            const planned = try geometry.plan(.{ .bounds = value.bounds, .radius = value.radius, .stroke_width = value.stroke_width, .color = geometry.Color.rgb(0) });
            if (planned.bounds.width == 0 or planned.bounds.height == 0) continue;
            // Periodic sampling is a valid software input. Neither analytic
            // shader receives a lossy, silently pad-only native descriptor.
            if (brush.spread != .pad) return error.UnsupportedGradientPrecision;
            // Both programs reject outside their own source-plane envelope
            // before any command in the complete buffer can draw.
            if (brush.interpolation != .srgb) {
                if (!prepared or !interpolation.supports(brush, planned, scale)) return error.UnsupportedGradientPrecision;
            } else if (!brush.conicGpuSupported(planned.bounds, scale)) return error.UnsupportedGradientPrecision;
        };
    }
    noinline fn replayInterpolation(self: *Renderer, brush: *const commands.brushes.Stored, planned: geometry.Plan) !void {
        const native_brush = brush.native();
        const packet = interpolation.Packet.prepare(brush);
        try self.result(zgpu_gradient_interpolated(self.native.?, planned.bounds.x, planned.bounds.y, planned.bounds.width, planned.bounds.height, planned.radius, planned.stroke_width, &native_brush, &packet));
    }
    pub fn preflightGaussianPrecision(ops: []const command.Command, filters: []const gaussian.View) !void {
        if (filters.len == 0) return;
        for (ops) |op| if (op == .begin_group and op.begin_group.filter_slot != commands.no_filter) {
            const group = op.begin_group;
            if (group.filter_slot >= filters.len) return error.MissingResources;
            const bounds = group.bounds;
            const capture = try gaussian_scope.Capture.init(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height }, filters[group.filter_slot].descriptor);
            if (!gaussian_precision.supports(capture)) return error.UnsupportedGaussianPrecision;
        };
    }
    fn replayNative(self: *Renderer, ops: []const command.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView, transforms: []const layers.NativeTransform, filters: []const gaussian.View) !void {
        const native = self.native.?;
        preflightGradientPrecisionPrepared(ops, resources, zgpu_scale(native), self.gradientInterpolationReadyUnchecked() and zgpu_interpolation_target_supported(native) != 0) catch |err| {
            self.last_hresult = 0;
            return err;
        };
        const layer_plan: ?layers.Plan = self.layer_plan;
        _ = try commands.preflightGaussianScopes(ops, if (layer_plan) |p| p.options.max_depth else 0, if (layer_plan) |p| p.options.size.scale else 1, coverage_resources, if (layer_plan) |p| p.options.legacy_text == .grayscale else true, layer_plan, transforms, filters, if (filters.len != 0) self.gaussianCapacity() else null);
        try preflightGaussianPrecision(ops, filters);
        transform_precision.preflight(ops, transforms, zgpu_scale(native)) catch |err| {
            self.last_hresult = 0;
            return err;
        };
        var depth: usize = 0;
        var utf16: [64 * 1024]u16 = undefined;
        for (ops) |op| switch (op) {
            .fill => |fill| {
                if (!layout.validRect(fill.bounds)) return error.InvalidGeometry;
                const r = fill.bounds;
                zgpu_fill(native, r.x, r.y, r.width, r.height, fill.color);
            },
            .shape => |value| {
                const p = try geometry.plan(value);
                try self.result(zgpu_shape(native, p.bounds.x, p.bounds.y, p.bounds.width, p.bounds.height, p.radius, p.stroke_width, p.color.rgba()));
            },
            .gradient => |value| {
                if (value.brush >= resources.len) return error.MissingResources;
                const p = try geometry.plan(.{ .bounds = value.bounds, .radius = value.radius, .stroke_width = value.stroke_width, .color = geometry.Color.rgb(0) });
                if (resources[value.brush].isTransparent()) continue;
                if (resources[value.brush].interpolation == .srgb) {
                    const brush = resources[value.brush].native();
                    try self.result(zgpu_gradient(native, p.bounds.x, p.bounds.y, p.bounds.width, p.bounds.height, p.radius, p.stroke_width, &brush));
                } else {
                    if (p.bounds.width == 0 or p.bounds.height == 0) continue;
                    try self.replayInterpolation(&resources[value.brush], p);
                }
            },
            .text => |value| {
                if (!layout.validRect(value.bounds)) return error.InvalidGeometry;
                const start: usize = value.offset;
                if (start > text.len or value.len > text.len - start) return error.InvalidTextRange;
                const bytes = text[start..][0..value.len];
                if (bytes.len > utf16.len) return error.TextTooLong;
                const count = try std.unicode.utf8ToUtf16Le(&utf16, bytes);
                const r = value.bounds;
                const font = value.font;
                zgpu_text(native, r.x, r.y, r.width, r.height, value.color, &utf16, @intCast(count), if (font.isDefault()) 0 else @bitCast(font), font.size(), font.weight.value(), @intFromBool(font.italic), @intFromBool(font.monospace));
            },
            .prepared_text => |value| {
                if (value.resource >= prepared.len) return error.MissingResources;
                try self.preparedText(prepared[value.resource], value.origin, value.color);
            },
            .coverage => |value| {
                if (value.resource >= coverage_resources.len) return error.MissingResources;
                try self.coverage(coverage_resources[value.resource], value.origin, value.color);
            },
            .image => |value| {
                if (value.resource >= image_resources.len) return error.MissingResources;
                try self.image(image_resources[value.resource], value.destination, .{ .alignment = value.alignment, .fit = value.fit, .sampling = value.sampling, .opacity = value.opacity });
            },
            .texture => |value| {
                const view = textures[value.resource];
                const plan = try drawing.planTexture(view, .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, .{ .alignment = value.alignment, .fit = value.fit, .sampling = value.sampling, .opacity = value.opacity }, zgpu_scale(native));
                if (plan.destination.width != 0 and plan.destination.height != 0 and plan.opacity != 0) try self.result(zgpu_texture(native, view.token, &plan));
            },
            .begin_group => |value| {
                const r = value.bounds;
                const group_bounds: drawing.Rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
                const options = try commands.groupOptions(value, coverage_resources);
                if (value.filter_slot == commands.no_filter) try self.beginGroup(group_bounds, options) else try self.beginGaussian(group_bounds, options, filters[value.filter_slot]);
            },
            .end_group => try self.endGroup(),
            .begin_transform => |slot| try self.beginTransform(transforms[slot]),
            .end_transform => try self.endTransform(),
            .backdrop, .indicator => unreachable, // Whole batch rejected before drawing.
            .push_clip => |r| {
                if (!layout.validRect(r)) return error.InvalidGeometry;
                if (depth == 32) return error.ClipStackFull;
                depth += 1;
                zgpu_push_clip(native, r.x, r.y, r.width, r.height);
            },
            .pop_clip => {
                if (depth == 0) return error.ClipStackEmpty;
                depth -= 1;
                zgpu_pop_clip(native);
            },
        };
        if (depth != 0) return error.UnbalancedClips;
    }

    pub fn end(self: *Renderer) !void {
        if (self.domain) |domain| try domain.checkRendererOwner();
        if (self.offscreen) return error.SurfaceModeMismatch;
        if (!self.active) return error.NotDrawing;
        defer self.finishScope();
        self.active = false;
        try self.checkFrame();
        try self.result(zgpu_end(self.native.?));
    }
    pub fn abort(self: *Renderer) void {
        self.assertOwner();
        defer self.finishScope();
        if (self.native) |native| zgpu_abort(native);
        self.active = false;
    }
    pub fn deinit(self: *Renderer) void {
        _ = self.deinitInternal(true);
    }
    /// Internal owning-surface teardown. The caller releases this borrow only
    /// after its final foreign free callback has returned.
    pub fn deinitRetainingBorrow(self: *Renderer) ?gpu_resources.DeviceDomain.Borrow {
        return self.deinitInternal(false);
    }
    fn deinitInternal(self: *Renderer, release_borrow: bool) ?gpu_resources.DeviceDomain.Borrow {
        std.debug.assert(!self.interpolation_mutating);
        const operation_scope = self.operation(true) catch unreachable;
        defer operation_scope.end();
        const native = self.native;
        const domain = self.domain;
        const borrow = self.domain_borrow;
        const scope = self.render_scope;
        self.native = null;
        self.domain = null;
        self.domain_borrow = null;
        self.render_scope = null;
        if (domain) |value| value.clearRendererWait(borrow.?.slot);
        if (native) |value| zgpu_destroy(value);
        if (release_borrow) if (domain) |value| value.releaseRenderer(borrow.?.slot);
        self.images.clear();
        self.images = .{};
        self.native = null;
        self.layer_plan = null;
        self.layer_candidate_peak = 0;
        self.active = false;
        self.offscreen = false;
        self.owner = null;
        if (scope) |value| {
            domain.?.endRenderer();
            value.end();
        }
        return if (release_borrow) null else borrow;
    }
    fn finishScope(self: *Renderer) void {
        const scope = self.render_scope orelse return;
        self.render_scope = null;
        self.domain.?.endRenderer();
        scope.end();
    }
    pub fn stats(self: *const Renderer) Stats {
        var values: Stats = .{};
        if (self.native) |native| zgpu_stats(native, &values.device_creations, &values.target_creations, &values.resizes, &values.presents, &values.device_losses, &values.busy_presents);
        return values;
    }
    pub fn geometryStats(self: *const Renderer) GeometryStats {
        var values: GeometryStats = .{};
        if (self.native) |native| zgpu_geometry_stats(native, &values.creations, &values.evictions, &values.cached);
        return values;
    }
    pub fn brushStats(self: *const Renderer) BrushStats {
        var values: BrushStats = .{};
        if (self.native) |native| zgpu_brush_stats(native, &values.creations, &values.evictions, &values.cached);
        return values;
    }
    pub fn gradientStats(self: *const Renderer) GradientStats {
        var values: GradientStats = .{};
        if (self.native) |native| zgpu_gradient_stats(native, &values.effect_creations, &values.draws, &values.constant_uploads, &values.device_restores);
        return values;
    }
    fn result(self: *Renderer, hr: i32) !void {
        self.last_hresult = hr;
        if (hr >= 0) return;
        switch (@as(u32, @bitCast(hr))) {
            0x887a0005, 0x887a0006, 0x887a0007, 0x887a0020, 0x8899000c => return error.DeviceLost,
            0x887a000a => return error.PresentationBusy,
            0x88995001 => return error.UnsupportedGradientPrecision,
            0x88995002 => return error.UnsupportedGaussianPrecision,
            else => return error.GraphicsFailed,
        }
    }

    /// Fault injection exercises the same cleanup path as a removed device.
    pub fn injectDeviceLoss(self: *Renderer) void {
        if (self.native) |native| zgpu_inject_loss(native, 0);
    }
    pub fn injectDeviceLossOnResize(self: *Renderer) void {
        if (self.native) |native| zgpu_inject_loss(native, 1);
    }
    /// The next completed draw declines presentation without changing its surface.
    pub fn injectPresentationBusy(self: *Renderer) void {
        if (self.native) |native| zgpu_inject_busy(native);
    }
    /// Synchronous GPU readback for integration tests. Never call in normal UI drawing.
    pub fn readPixelForTest(self: *Renderer, x: u32, y: u32) !u32 {
        try self.checkFrame();
        if (!self.active) return error.NotDrawing;
        var rgb: u32 = undefined;
        try self.result(zgpu_test_pixel(self.native.?, x, y, &rgb));
        return rgb;
    }
    /// Explicit full-target readback; allocates native staging resources only
    /// for this diagnostic call. Output is opaque encoded RGB.
    pub fn readPixelsForTest(self: *Renderer, width: u32, height: u32, pixels: []u32) !void {
        try self.checkFrame();
        if (!self.active) return error.NotDrawing;
        if (pixels.len != @as(usize, width) * height) return error.InvalidReadbackLength;
        try self.result(zgpu_test_pixels(self.native.?, width, height, pixels.ptr));
    }
    /// Counts pixels changed by text in a caller-selected test region.
    pub fn textPixelsForTest(self: *Renderer, x: u32, y: u32, width: u32, height: u32, background: u32) !u32 {
        try self.checkFrame();
        if (!self.active) return error.NotDrawing;
        var count: u32 = undefined;
        try self.result(zgpu_test_text_pixels(self.native.?, x, y, width, height, background, &count));
        return count;
    }
    pub fn surfaceForTest(self: *const Renderer) ?*anyopaque {
        return if (self.native) |native| zgpu_test_surface(native) else null;
    }
    pub fn swapchainWindowForTest(self: *const Renderer) ?*anyopaque {
        return if (self.native) |native| zgpu_test_swapchain_window(native) else null;
    }
    /// Borrowed until device loss, a different HWND, or deinit. Unwatch first.
    pub fn frameReadyHandle(self: *const Renderer) ?*anyopaque {
        return if (self.native) |native| zgpu_frame_ready(native) else null;
    }
};
