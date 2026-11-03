//! The macOS offscreen surface (src/ui/gpu_offscreen.zig's `Surface`): a
//! Metal renderer of the domain draws each frame into a transparent work
//! target, which becomes the front once the frame has drawn whole; a frame
//! that fails leaves the front as it was. `snapshot` copies the front into
//! a new immutable texture of the domain, which frames of any of its
//! renderers draw, this surface's own included.
//!
//! The surface reserves the plan of the other GPU surfaces in the domain's
//! budget, so that limits read the same on every platform. Metal itself
//! holds two targets (front and work) and the frame's captures (groups,
//! transforms, Gaussian filters), which it makes per frame.
const std = @import("std");
const z = @import("ziggurat");
const drawing = @import("ziggurat_drawing_resources");
const commands = @import("commands.zig");
const batch = @import("render_batch.zig");
const layers = @import("layers.zig");
const gaussian_scope = @import("gaussian_scope.zig");
const resources = @import("gpu_resources.zig");
const offscreen = @import("gpu_offscreen.zig");
const interpolation = @import("gradient_interpolation_gpu.zig");
const metal = @import("metal.zig");
const Renderer = metal.Renderer;
const Options = offscreen.Options;
const Stats = offscreen.Stats;

/// The renderer's own bookkeeping, held by the domain's budget beside the
/// surface's state: instances, batches, clips and captures of a frame.
const native_metadata = 64 * 1024;

pub const Surface = opaque {
    pub fn create(domain: *resources.DeviceDomain, allocator: std.mem.Allocator, options: Options) !*Surface {
        return createInternal(false, domain, allocator, options, {}, 0);
    }
    /// Metal filters Gaussian groups in each frame's captures; the plan
    /// bounds them as it bounds the other GPU surfaces'.
    pub fn createGaussian(domain: *resources.DeviceDomain, allocator: std.mem.Allocator, options: Options, filter: gaussian_scope.FilterOptions) !*Surface {
        return createInternal(true, domain, allocator, options, filter, 0);
    }
    pub fn createWithFailureForTest(domain: *resources.DeviceDomain, allocator: std.mem.Allocator, options: Options, plane: u32) !*Surface {
        return createInternal(false, domain, allocator, options, {}, plane);
    }
    pub fn createGaussianWithFailureForTest(domain: *resources.DeviceDomain, allocator: std.mem.Allocator, options: Options, filter: gaussian_scope.FilterOptions, plane: u32) !*Surface {
        return createInternal(true, domain, allocator, options, filter, plane);
    }
    fn createInternal(comptime filtered: bool, domain: *resources.DeviceDomain, allocator: std.mem.Allocator, options: Options, filter_options: if (filtered) gaussian_scope.FilterOptions else void, fault: u32) !*Surface {
        if (!offscreen.available) return error.GpuNotEnabled;
        try domain.checkRendererReady();
        if (options.resident_bytes > drawing.max_image_budget or options.render_work == 0 or options.render_work > 1024 * 1024 * 1024) return error.InvalidOffscreenLimits;
        if (options.transform_source != null and options.render_work > 512 * 1024 * 1024) return error.InvalidOffscreenLimits;
        if (options.size.width > 16384 or options.size.height > 16384 or @as(u64, options.size.width) * options.size.height > 16 * 1024 * 1024) return error.InvalidGeometry;
        const layer_options: layers.Options = .{ .size = options.size, .max_depth = options.max_depth, .legacy_text = options.legacy_text, .bytes = layers.max_bytes, .total_bytes = layers.max_bytes };
        const filter: ?gaussian_scope.Plan = if (filtered) try filterPlan(options, filter_options) else null;
        var plan = if (filter) |value| value.layers else if (options.transform_source) |source| try layers.Plan.initTransforms(.{ .layers = layer_options, .source_size = source, .render_work = @min(options.render_work, 512 * 1024 * 1024) }, .gpu) else try layers.Plan.init(layer_options, .gpu);
        if (filter) |value| plan.pixel_bytes = value.pixel_bytes;
        const borrow = try domain.acquireRenderer(null);
        const scope = domain.beginRenderer() catch |err| {
            domain.releaseRenderer(borrow.slot);
            return err;
        };
        var committed = false;
        defer {
            if (!committed) domain.releaseRenderer(borrow.slot);
            domain.endRenderer();
            scope.end();
        }
        const metadata = @sizeOf(State) + native_metadata + @as(usize, if (options.transform_source != null) @sizeOf(commands.TransformStorage) else 0) + @as(usize, if (filter != null) @sizeOf(commands.FilterStorage) else 0);
        try domain.reserveSurface(borrow, plan.pixel_bytes, metadata, options.resident_bytes);
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .domain = domain, .options = options, .filter_options = if (filtered) filter_options else null, .plan = plan, .metadata = metadata };
        var initialized = false;
        errdefer {
            if (initialized) _ = state.renderer.deinitRetainingBorrow();
            state.closing = true;
            if (state.transform_storage) |storage| allocator.destroy(storage);
            if (state.filter_storage) |storage| allocator.destroy(storage);
            allocator.destroy(state);
        }
        if (options.transform_source != null) {
            state.transform_storage = try allocator.create(commands.TransformStorage);
            state.transform_storage.?.* = .{ .scale = options.size.scale };
        }
        if (filter != null) {
            state.filter_storage = try allocator.create(commands.FilterStorage);
            state.filter_storage.?.* = .{};
        }
        try domain.checkRendererReady();
        try state.renderer.initOffscreen(domain, borrow);
        initialized = true;
        // The renderer's preparation failing, as the other surfaces' plane
        // preparation can.
        if (fault != 0) return error.GraphicsFailed;
        try domain.checkRendererReady();
        // Empty residency permits texture-only scenes; uploads against it fail.
        state.renderer.images.stats.budget_bytes = options.resident_bytes;
        committed = true;
        return @ptrCast(state);
    }
    pub fn render(self: *Surface, source: *const commands.Buffer) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(true);
        defer scope.end();
        const epoch = state.renderer.domain_borrow.?.epoch;
        const filter = if (state.filter_options) |value| try filterPlan(state.options, value) else null;
        const work = batch.preflight(source, .{ .size = state.options.size, .max_depth = state.options.max_depth, .legacy_text = state.options.legacy_text, .render_work = state.options.render_work, .texture_domain = epoch, .output_copy = false, .transform_plan = state.plan, .gaussian_capacity = if (filter) |value| value.capacity else null }) catch |err| {
            state.aborted +|= 1;
            return err;
        };
        defer state.captured.reset();
        if (source.transformResources().len != 0) try state.captured.bindTransformStorage(state.transform_storage orelse return error.TransformsRequired);
        if (source.filterResources().len != 0) try state.captured.bindFilterStorage(state.filter_storage orelse return error.GaussianNotPrepared);
        try batch.capture(&state.captured, source);
        // Every raster input must already be resident: replay never uploads.
        for (state.captured.imageResources()) |view| if (state.renderer.images.find(view.identity) == null) return error.ImageNotUploaded;
        for (state.captured.coverageResources()) |view| if (state.renderer.images.findCoverage(view.identity) == null) return error.CoverageNotUploaded;
        try state.renderer.beginOffscreen(state.options.size, true);
        state.renderer.replayBuffer(&state.captured) catch |err| {
            state.renderer.abort();
            state.aborted +|= 1;
            return err;
        };
        state.renderer.endOffscreen(null, 0) catch |err| {
            state.aborted +|= 1;
            return err;
        };
        state.renderer.commitOffscreen();
        state.generation = epoch.generation;
        state.has_frame = true;
        state.renders +|= 1;
        state.committed +|= 1;
        state.last_render_work = work;
    }
    /// Metal mixes gradient stops in every space in its shaders: there is
    /// nothing to prepare.
    pub fn prepareGradientInterpolation(self: *Surface) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(true);
        defer scope.end();
    }
    pub fn releaseGradientInterpolation(self: *Surface) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(false);
        defer scope.end();
    }
    pub fn gradientInterpolationStats(self: *Surface) !interpolation.Stats {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(false);
        defer scope.end();
        return .{ .ready = @intFromBool(state.renderer.domain_borrow.?.epoch.status == 1) };
    }
    pub fn snapshot(self: *Surface) !*resources.Texture {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(true);
        defer scope.end();
        if (!state.has_frame) return error.NoFrame;
        const borrow = state.renderer.domain_borrow.?;
        if (state.generation != borrow.epoch.generation) return error.StaleSurfaceGeneration;
        const fault = state.snapshot_fault;
        state.snapshot_fault = 0;
        const texture = try state.domain.snapshotRenderer(borrow, state.renderer.native.?, state.options.size.width, state.options.size.height, fault);
        state.snapshots +|= 1;
        return texture;
    }
    pub fn uploadImage(self: *Surface, view: drawing.ImageView) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(true);
        defer scope.end();
        try state.renderer.uploadImage(view);
        try state.domain.checkRendererReady();
    }
    pub fn uploadCoverage(self: *Surface, view: drawing.CoverageView) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(true);
        defer scope.end();
        try state.renderer.uploadCoverage(view);
        try state.domain.checkRendererReady();
    }
    pub fn releaseImage(self: *Surface, identity: u64) !bool {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(false);
        defer scope.end();
        return state.renderer.releaseImage(identity);
    }
    pub fn releaseCoverage(self: *Surface, identity: u64) !bool {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(false);
        defer scope.end();
        return state.renderer.releaseCoverage(identity);
    }
    pub fn stats(self: *const Surface) !Stats {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(@constCast(self));
        const scope = try state.enter(false);
        defer scope.end();
        const epoch = state.renderer.domain_borrow.?.epoch;
        const objects = state.renderer.offscreenObjects();
        const plan = state.plan;
        const native: layers.Stats = .{ .prepared = true, .pixel_bytes = plan.pixel_bytes, .plane_bytes = plan.plane_bytes, .planes = plan.planes, .max_depth = plan.options.max_depth, .native_objects = objects, .metadata_bytes = native_metadata, .native_creations = state.renderer.stats().offscreen_targets, .committed_frames = state.committed, .aborted_frames = state.aborted };
        return .{ .size = state.options.size, .generation = state.generation, .has_frame = state.has_frame and epoch.status == 1 and epoch.generation == state.generation, .workspace_reserved = plan.pixel_bytes, .workspace_actual = if (objects == 0) 0 else plan.pixel_bytes, .metadata_reserved = state.metadata, .raster_limit = state.options.resident_bytes, .raster_current = state.renderer.rasterStats().pixel_bytes, .raster_candidate_bound = state.options.resident_bytes * 2, .raster = state.renderer.rasterStats(), .renders = state.renders, .snapshots = state.snapshots, .last_render_work = state.last_render_work, .layers = native };
    }
    pub fn close(self: *Surface) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        try state.check(false);
        const domain = state.domain;
        const scope = try domain.beginRendererCleanup();
        defer {
            domain.endRenderer();
            if (scope) |value| value.end();
        }
        state.closing = true;
        state.busy = true;
        state.captured.reset();
        const borrow = state.renderer.deinitRetainingBorrow().?;
        if (state.transform_storage) |storage| {
            state.transform_storage = null;
            state.allocator.destroy(storage);
        }
        if (state.filter_storage) |storage| {
            state.filter_storage = null;
            state.allocator.destroy(storage);
        }
        state.allocator.destroy(state);
        domain.releaseRenderer(borrow.slot);
    }
    /// The next frame fails as one on a removed device does, and the domain
    /// loses its device.
    pub fn injectDeviceLossForTest(self: *Surface) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(true);
        defer scope.end();
        state.renderer.injectDeviceLoss();
    }
    pub fn injectSnapshotFailureForTest(self: *Surface, stage: u32) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(true);
        defer scope.end();
        if (stage > 3) return error.InvalidFault;
        state.snapshot_fault = stage;
    }
    /// Test-only synchronous readback of the front: 0xAARRGGBB,
    /// premultiplied.
    pub fn readFrontForTest(self: *Surface, pixels: []u32) !void {
        if (!offscreen.available) return error.GpuNotEnabled;
        const state = cast(self);
        const scope = try state.enter(true);
        defer scope.end();
        if (!state.has_frame or state.generation != state.renderer.domain_borrow.?.epoch.generation) return error.NoFrame;
        try state.renderer.readFront(pixels, state.options.size.width, state.options.size.height);
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    domain: *resources.DeviceDomain,
    options: Options,
    plan: layers.Plan,
    metadata: usize,
    renderer: Renderer = .{},
    captured: commands.Buffer = .{},
    transform_storage: ?*commands.TransformStorage = null,
    filter_storage: ?*commands.FilterStorage = null,
    filter_options: ?gaussian_scope.FilterOptions = null,
    busy: bool = false,
    closing: bool = false,
    has_frame: bool = false,
    generation: u64 = 0,
    renders: u64 = 0,
    snapshots: u64 = 0,
    committed: u64 = 0,
    aborted: u64 = 0,
    last_render_work: u64 = 0,
    snapshot_fault: u32 = 0,
    fn check(self: *State, ready: bool) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
        if (self.busy) return error.Busy;
        if (ready) try self.domain.checkRendererReady();
    }
    fn enter(self: *State, ready: bool) !Operation {
        try self.check(ready);
        const scope = if (ready) try self.domain.beginRenderer() else try self.domain.beginRendererCleanup();
        self.busy = true;
        return .{ .state = self, .domain = self.domain, .scope = scope };
    }
};
fn filterPlan(options: Options, filter: gaussian_scope.FilterOptions) !gaussian_scope.Plan {
    const layer_options: layers.Options = .{ .size = options.size, .max_depth = options.max_depth, .legacy_text = options.legacy_text, .bytes = layers.max_bytes, .total_bytes = layers.max_bytes };
    const transforms: ?layers.TransformOptions = if (options.transform_source) |source| .{ .layers = layer_options, .source_size = source, .render_work = @min(options.render_work, 512 * 1024 * 1024) } else null;
    return try gaussian_scope.Plan.init(gaussian_scope.withLayers(filter, layer_options, @min(options.render_work, 512 * 1024 * 1024)), .gpu, transforms);
}
const Operation = struct {
    state: *State,
    domain: *resources.DeviceDomain,
    scope: ?z.AppCallbackScope,
    fn end(self: Operation) void {
        self.state.busy = false;
        self.domain.endRenderer();
        if (self.scope) |scope| scope.end();
    }
};
fn cast(surface: *Surface) *State {
    return @ptrCast(@alignCast(surface));
}
