const std = @import("std");
const zio = @import("ziggurat_io");
const gaussian = @import("gaussian_filter.zig");
const gaussian_scope = @import("gaussian_scope.zig");
const gaussian_kernel = @import("gaussian_kernel.zig");
const z = @import("ziggurat");
const commands = @import("commands.zig");
const fonts = @import("ziggurat_fonts");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const drawing = @import("ziggurat_drawing_resources");
const image_cache = @import("image_cache.zig");
const cpu_gradient = @import("cpu_gradient.zig");
const layers = @import("layers.zig");
const transform_composite = @import("transform_composite.zig");
const shader_effects = commands.shader_effects;
const effect_host = @import("gpu_effect_host.zig");
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
extern fn zlc_text(*anyopaque, f32, f32, f32, f32, [*]const u8, u32, u32, f32, u16, c_int, c_int, ?[*:0]const u8) c_int;
extern fn zlc_prepared(*anyopaque, *anyopaque, f32, f32, f32, i32, i32, ?*const drawing.Rect, u32) c_int;
extern fn zlc_scale(*anyopaque) f32;
extern fn zlc_push_clip(*anyopaque, f32, f32, f32, f32) void;
extern fn zlc_pop_clip(*anyopaque) void;
extern fn zlc_end(*anyopaque, *anyopaque) void;
extern fn zlc_destroy(*anyopaque) void;
extern fn zlc_prepare_image(*anyopaque, [*]const drawing.ImageLevel, u32) c_int;
extern fn zlc_prepare_dynamic_image(*anyopaque, [*]const drawing.ImageLevel, u32) c_int;
extern fn zlc_update_image(*anyopaque, u32, [*]const drawing.ImageLevel, u32) c_int;
extern fn zlc_reserve_images(*anyopaque, u32) c_int;
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

extern fn zgl_effects_create(c_int, [*]u8, usize) ?*anyopaque;
extern fn zgl_effects_destroy(*anyopaque) void;
extern fn zgl_effects_install(*anyopaque, u32, [*:0]const u8, [*]u8, usize) c_int;
extern fn zgl_effects_run(*anyopaque, u32, [*]const u32, u32, *const effect_host.Params, [*]const u32, u32, u32, usize, [*]u32, u32, u32, usize) c_int;
extern fn zgl_effects_passes(*anyopaque) u64;

pub const GlMode = shader_effects.GlMode;
/// The mode `ZIGGURAT_GL` selects: `0`/`off`/`false`/`no` or `1`/`on`/
/// `true`/`yes`; anything else is automatic.
pub fn glModeFromEnvironment() GlMode {
    const value = zio.getenv("ZIGGURAT_GL") orelse return .automatic;
    for ([_][]const u8{ "0", "off", "false", "no" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return .off;
    for ([_][]const u8{ "1", "on", "true", "yes" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return .on;
    return .automatic;
}

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
    /// The Buffer whose backdrop, indicator and shader tables the current
    /// replay reads.
    backdrop_source: ?*const commands.Buffer = null,
    /// Element effects isolated in a Gaussian capture, innermost last.
    effect_scopes: [layers.max_depth]EffectScope = undefined,
    effect_count: usize = 0,
    /// The OpenGL executor for shader effects and the programs linked for
    /// it, once `prepareEffect` created it; `gl_unavailable` after it could
    /// not be created or failed.
    gl: ?*anyopaque = null,
    gl_unavailable: bool = false,
    gl_table: effect_host.Table = .{},
    const EffectScope = struct { slot: u8, capture: gaussian_scope.Capture };
    const Resources = struct {
        text_bytes: []const u8,
        brushes: []const commands.brushes.Stored,
        prepared: []const drawing.PreparedTextView,
        images: []const drawing.ImageView,
        coverage: []const drawing.CoverageView,
        transforms: []const layers.NativeTransform,
        filters: []const gaussian.View,
    };
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
    /// Open an element effect's Gaussian capture when one is prepared with
    /// room for it; null leaves the effect to isolation on the target.
    fn captureEffect(self: *Renderer, entry: *const commands.shader_effects.Entry) ?gaussian_scope.Capture {
        if (self.layer_plan == null or !self.layer_active or self.effect_count == self.effect_scopes.len) return null;
        const capacity = self.gaussianCapacity() orelse return null;
        const workspace = self.backdrop_source.?.shader_storage.workspace orelse return null;
        // Opening a capture with a new kernel never happens inside another
        // one: all entries of a frame share its scale.
        const kernel = workspace.carrierFor(entry.scale) catch return null;
        const bounds = entry.captureRect();
        const capture = gaussian_scope.Capture.init(bounds, kernel) catch return null;
        capture.check(capacity) catch return null;
        const descriptor = self.groupDescriptor(bounds, .{ .opacity = entry.opacity }) catch return null;
        // Fails when the layer depth or the frame's filter budget is spent.
        if (zlc_layer_begin_gaussian(self.native.?, &descriptor, &capture, kernel) != 0) return null;
        return capture;
    }
    /// Draw `body` isolated on the current target and composite it through
    /// the effect; without a workspace or room it is drawn plainly.
    fn isolateEffect(self: *Renderer, body: []const commands.Command, entry: *const commands.shader_effects.Entry, resources: Resources) anyerror!void {
        const effects = commands.shader_effects;
        const workspace = self.backdrop_source.?.shader_storage.workspace orelse return self.execute(body, resources);
        var surface: cpu_gradient.Surface = undefined;
        if (zlc_gradient_surface(self.native.?, &surface) != 0) return error.DrawEffectFailed;
        const region = effects.twoPassRegion(surface, entry, workspace) orelse return self.execute(body, resources);
        const dirty_left: u32 = @intCast(region.x0);
        const dirty_top: u32 = @intCast(region.y0);
        const dirty_width: u32 = @intCast(region.width());
        const dirty_height: u32 = @intCast(region.height());
        effects.beginIsolation(surface, region, workspace);
        errdefer {
            effects.cancelIsolation(surface, region, workspace);
            zlc_gradient_dirty(self.native.?, dirty_left, dirty_top, dirty_width, dirty_height);
        }
        zlc_gradient_dirty(self.native.?, dirty_left, dirty_top, dirty_width, dirty_height);
        try self.execute(body, resources);
        if (zlc_gradient_surface(self.native.?, &surface) != 0) return error.DrawEffectFailed;
        effects.secondIsolation(surface, region, workspace);
        zlc_gradient_dirty(self.native.?, dirty_left, dirty_top, dirty_width, dirty_height);
        try self.execute(body, resources);
        if (zlc_gradient_surface(self.native.?, &surface) != 0) return error.DrawEffectFailed;
        _ = effects.finishIsolation(surface, zlc_layer_transparent(self.native.?) != 0, region, entry, workspace);
        zlc_gradient_dirty(self.native.?, dirty_left, dirty_top, dirty_width, dirty_height);
    }
    noinline fn filterEffect(self: *Renderer, entry: *const commands.shader_effects.Entry, capture: gaussian_scope.Capture, workspace: ?*commands.shader_effects.Workspace) !void {
        var source: cpu_gradient.Surface = undefined;
        var temporary: cpu_gradient.Surface = undefined;
        var kernel: ?*const gaussian_kernel.Kernel = null;
        if (zlc_layer_gaussian_planes(self.native.?, &source, &temporary, &kernel) != 0) return error.EndGaussianFailed;
        const pixels = source.pixels[0 .. @as(usize, source.stride) * (source.height - 1) + source.width];
        const scratch = temporary.pixels[0 .. @as(usize, temporary.stride) * (temporary.height - 1) + temporary.width];
        const plane: shader_effects.Plane = .{ .pixels = pixels, .width = source.width, .height = source.height, .stride = source.stride };
        const scratch_plane: shader_effects.Plane = .{ .pixels = scratch, .width = temporary.width, .height = temporary.height, .stride = temporary.stride };
        if (self.glSlot(entry)) |slot| if (workspace) |space| {
            if (!shader_effects.startElement(space, entry, @as(u64, source.width) * source.height, capture.scale)) return;
            var params = effect_host.elementParams(entry, capture);
            params.plane = .{ source.width, source.height, 0, 0 };
            if (self.runGl(slot, space, &params, source.pixels, source.width, source.height, source.stride, source.pixels, source.width, source.height, source.stride)) return;
            shader_effects.shadeContent(entry, plane, scratch_plane, params.a[2], params.a[3], capture.scale, space);
            return;
        };
        shader_effects.applyElement(entry, plane, scratch_plane, capture, workspace);
    }
    /// Run a backdrop shader on the current plane: on OpenGL when its
    /// program is linked, else on the CPU.
    fn backdropShader(self: *Renderer, entry: *const shader_effects.Entry, surface: cpu_gradient.Surface, transparent: bool, scratch: ?[]u32, workspace: ?*shader_effects.Workspace) cpu_gradient.Dirty {
        const empty: cpu_gradient.Dirty = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const slot = self.glSlot(entry) orelse return shader_effects.applyBackdrop(surface, transparent, entry, scratch, workspace);
        const plan = shader_effects.planBackdrop(surface.width, surface.height, surface.scale, surface.origin, surface.clip, entry) orelse return empty;
        const space = workspace orelse return empty;
        if (!shader_effects.startBackdrop(space, entry, plan, if (scratch) |storage| storage.len else null, surface.scale)) return empty;
        const params = effect_host.backdropParams(entry, plan, surface.scale, surface.origin, surface.clip, transparent);
        const stride: usize = surface.stride;
        const content = surface.pixels + plan.region[1] * stride + plan.region[0];
        const out = surface.pixels + plan.out[1] * stride + plan.out[0];
        if (!self.runGl(slot, space, &params, content, @intCast(plan.region[2] - plan.region[0]), @intCast(plan.region[3] - plan.region[1]), stride, out, @intCast(plan.out[2] - plan.out[0]), @intCast(plan.out[3] - plan.out[1]), stride))
            shader_effects.shadeBackdrop(surface, transparent, entry, plan, scratch.?, space);
        return plan.dirty();
    }
    fn glSlot(self: *Renderer, entry: *const shader_effects.Entry) ?u32 {
        if (self.gl == null) return null;
        return self.gl_table.find(entry.program.identity, entry.target);
    }
    /// Run a linked program on OpenGL; false after a failure, which turns
    /// OpenGL off for this renderer.
    fn runGl(self: *Renderer, slot: u32, space: *shader_effects.Workspace, params: *const effect_host.Params, content: [*]const u32, content_width: u32, content_height: u32, content_stride: usize, out: [*]u32, out_width: u32, out_height: u32, out_stride: usize) bool {
        var words: [shader_effects.shader.gpu.max_input_words]u32 = undefined;
        const inputs = self.gl_table.entries[slot].inputs;
        for (inputs, 0..) |register, i| words[i] = space.machine.registers[register];
        if (zgl_effects_run(self.gl.?, slot, &words, @intCast(inputs.len), params, content, content_width, content_height, content_stride, out, out_width, out_height, out_stride) == 0) return true;
        self.dropGl();
        self.gl_unavailable = true;
        return false;
    }
    fn dropGl(self: *Renderer) void {
        if (self.gl) |gl| zgl_effects_destroy(gl);
        self.gl = null;
        self.gl_table.deinit();
    }
    /// Link `program` drawn as `target` for OpenGL, outside paint, creating
    /// the executor on first use. False when OpenGL is off or unavailable
    /// or rejects the program: its effects then run on the CPU.
    pub fn prepareEffect(self: *Renderer, allocator: std.mem.Allocator, program: *const shader_effects.shader.Program, target: shader_effects.Target, mode: GlMode) !bool {
        if (mode == .off or self.gl_unavailable) return false;
        const gl = self.gl orelse created: {
            var log: [256]u8 = @splat(0);
            const value = zgl_effects_create(@intFromBool(mode == .on), &log, log.len) orelse {
                self.gl_unavailable = true;
                return false;
            };
            self.gl = value;
            break :created value;
        };
        const table = &self.gl_table;
        table.beginFrame();
        if (table.find(program.identity, target) != null) return true;
        if (table.failed(program.identity, target)) return false;
        var translation = shader_effects.shader.gpu.translate(allocator, program, .glsl) catch |err| switch (err) {
            error.UnsupportedProgram => {
                table.fail(program.identity, target);
                return false;
            },
            else => |e| return e,
        };
        defer translation.deinit();
        const fragment = try effect_host.source(allocator, &translation, program.kind, target, .glsl);
        defer allocator.free(fragment);
        const inputs = try allocator.dupe(u16, translation.inputs);
        errdefer allocator.free(inputs);
        const slot = table.victim() orelse return false;
        var log: [1024]u8 = @splat(0);
        switch (zgl_effects_install(gl, slot, fragment.ptr, &log, log.len)) {
            0 => {},
            2 => {
                std.log.scoped(.ziggurat_gl).warn("shader effect program rejected: {s}", .{std.mem.sliceTo(&log, 0)});
                table.fail(program.identity, target);
                allocator.free(inputs);
                return false;
            },
            else => {
                allocator.free(inputs);
                self.dropGl();
                self.gl_unavailable = true;
                return false;
            },
        }
        table.fill(slot, program.identity, target, inputs, &.{}, allocator);
        return true;
    }
    /// Shader passes run on OpenGL.
    pub fn effectPasses(self: *const Renderer) u64 {
        return if (self.gl) |gl| zgl_effects_passes(gl) else 0;
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
        try self.reserveSlot();
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        self.images.reserveCandidate(charge);
        self.images.coverage_stats.peak_reserved_bytes = @max(self.images.coverage_stats.peak_reserved_bytes, self.images.coverage_stats.pixel_bytes + charge);
        const descriptor = view.native();
        if (zlc_prepare_coverage(native, &descriptor) != 0) return error.CoverageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.victim() orelse break, true);
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
        try self.reserveSlot();
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        self.images.stats.peak_reserved_bytes = @max(self.images.stats.peak_reserved_bytes, self.images.stats.pixel_bytes + charge);
        self.images.reserveCandidate(charge);
        if ((if (dynamic) zlc_prepare_dynamic_image(self.native.?, view.levels.ptr, @intCast(view.levels.len)) else zlc_prepare_image(self.native.?, view.levels.ptr, @intCast(view.levels.len))) != 0) return error.ImageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.victim() orelse break, true);
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
    /// Leave an empty slot for an upload: grow the table, or at its ceiling
    /// evict the oldest entry the frame being prepared does not draw.
    fn reserveSlot(self: *Renderer) !void {
        if (self.images.empty() != null) return;
        if (self.images.nextCapacity()) |capacity| {
            if (zlc_reserve_images(self.native.?, @intCast(capacity)) == 0) {
                if (self.images.grow(capacity)) return else |_| {}
            }
        } else |_| {}
        self.dropImage(self.images.victim() orelse return error.ImageSlotsFull, true);
    }
    /// Make the images and coverage a frame draws resident before it
    /// replays: upload those missing, whether never uploaded, released or
    /// evicted, without evicting the others it draws. A frame that needs more
    /// than the budget keeps them all until the next explicit upload or
    /// budget change.
    pub fn residentFrame(self: *Renderer, buffer: *const commands.Buffer) !void {
        self.images.beginFrame();
        defer self.images.endFrame();
        for (buffer.imageResources()) |view| if (self.images.find(view.identity)) |slot| self.images.touch(slot);
        for (buffer.coverageResources()) |view| if (self.images.findCoverage(view.identity)) |slot| self.images.touch(slot);
        for (buffer.imageResources()) |view| if (self.images.find(view.identity) == null) try self.uploadImage(view);
        for (buffer.coverageResources()) |view| if (self.images.findCoverage(view.identity) == null) try self.uploadCoverage(view);
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
        return self.textFont(rect, utf8, color, .{});
    }
    pub fn textFont(self: *Renderer, rect: Rect, utf8: []const u8, color: u32, font: commands.FontKey) !void {
        if (utf8.len > 64 * 1024) return error.TextTooLong;
        if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
        if (zlc_text(self.native.?, rect.x, rect.y, rect.width, rect.height, utf8.ptr, @intCast(utf8.len), color, font.size(), font.weight.value(), @intFromBool(font.italic), @intFromBool(font.monospace), if (font.family == 0) null else fonts.systemName(font.family).ptr) != 0) return error.DrawTextFailed;
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
        self.backdrop_source = buffer;
        defer self.backdrop_source = null;
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
        self.effect_count = 0;
        if (self.backdrop_source) |source| if (source.shader_storage.workspace) |workspace| {
            workspace.beginFrame();
            workspace.isolating = false;
        };
        try self.execute(list, .{ .text_bytes = text_bytes, .brushes = resources, .prepared = prepared, .images = image_resources, .coverage = coverage_resources, .transforms = transforms, .filters = filters });
        if (self.effect_count != 0) return error.UnbalancedEffects;
    }
    fn execute(self: *Renderer, list: []const commands.Command, all: Resources) anyerror!void {
        const text_bytes = all.text_bytes;
        const resources = all.brushes;
        const prepared = all.prepared;
        const image_resources = all.images;
        const coverage_resources = all.coverage;
        const transforms = all.transforms;
        const filters = all.filters;
        var depth: usize = 0;
        defer while (self.layer_plan == null and depth != 0) : (depth -= 1) {
            zlc_pop_clip(self.native.?);
        };
        var index: usize = 0;
        while (index < list.len) : (index += 1) switch (list[index]) {
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
                try self.textFont(value.bounds, text_bytes[value.offset..][0..value.len], value.color, value.font);
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
                try self.image(image_resources[value.resource], value.destination, value.options());
            },
            .begin_group => |value| {
                const r = value.bounds;
                const bounds: drawing.Rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
                const options = try commands.groupOptions(value, coverage_resources);
                if (value.filter_slot == commands.no_filter) try self.beginGroup(bounds, options) else try self.beginGaussian(bounds, options, filters[value.filter_slot]);
            },
            .end_group => try self.endGroup(),
            .effect => |slot| {
                const source = self.backdrop_source orelse return error.MissingResources;
                if (slot >= source.shader_storage.len) return error.MissingResources;
                const entry = &source.shader_storage.entries[slot];
                const effect_end = commands.effectEnd(list, index) orelse return error.UnbalancedEffects;
                if (self.captureEffect(entry)) |capture| {
                    self.effect_scopes[self.effect_count] = .{ .slot = slot, .capture = capture };
                    self.effect_count += 1;
                } else {
                    try self.isolateEffect(list[index + 1 .. effect_end], entry, all);
                    index = effect_end;
                }
            },
            .end_effect => {
                if (self.effect_count == 0) return error.UnbalancedEffects;
                self.effect_count -= 1;
                const scope = self.effect_scopes[self.effect_count];
                const source = self.backdrop_source.?;
                try self.filterEffect(&source.shader_storage.entries[scope.slot], scope.capture, source.shader_storage.workspace);
                if (zlc_layer_end_group(self.native.?) != 0) return error.EndGroupFailed;
            },
            .backdrop_shader => |slot| {
                const source = self.backdrop_source orelse return error.MissingResources;
                if (slot >= source.shader_storage.len) return error.MissingResources;
                var surface: cpu_gradient.Surface = undefined;
                if (zlc_gradient_surface(self.native.?, &surface) != 0) return error.DrawBackdropFailed;
                const scratch = if (source.backdrop_storage.workspace) |workspace| workspace.planes else null;
                const dirty = self.backdropShader(&source.shader_storage.entries[slot], surface, zlc_layer_transparent(self.native.?) != 0, scratch, source.shader_storage.workspace);
                zlc_gradient_dirty(self.native.?, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top);
            },
            .begin_transform => |slot| try self.beginTransform(transforms[slot]),
            .end_transform => try self.endTransform(),
            .backdrop => |slot| {
                const source = self.backdrop_source orelse return error.MissingResources;
                if (slot >= source.backdrop_storage.len) return error.MissingResources;
                var surface: cpu_gradient.Surface = undefined;
                if (zlc_gradient_surface(self.native.?, &surface) != 0) return error.DrawBackdropFailed;
                const dirty = commands.backdrop.apply(surface, zlc_layer_transparent(self.native.?) != 0, source.backdrop_storage.entries[slot], source.backdrop_storage.workspace);
                zlc_gradient_dirty(self.native.?, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top);
            },
            .indicator => |slot| {
                const source = self.backdrop_source orelse return error.MissingResources;
                if (slot >= source.indicator_len) return error.MissingResources;
                var surface: cpu_gradient.Surface = undefined;
                if (zlc_gradient_surface(self.native.?, &surface) != 0) return error.DrawIndicatorFailed;
                const dirty = commands.loading.draw(surface, zlc_layer_transparent(self.native.?) != 0, source.indicator_storage[slot]);
                zlc_gradient_dirty(self.native.?, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top);
            },
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
        self.dropGl();
        if (self.native) |native| zlc_destroy(native);
        self.images.deinit();
        self.* = .{};
    }
    pub fn brushStats(self: *const Renderer) BrushStats {
        var stats: BrushStats = .{};
        if (self.native) |native| zlc_brush_stats(native, &stats.creations, &stats.evictions, &stats.cached);
        return stats;
    }
};

test "Cairo text follows the command font" {
    var renderer: Renderer = .{};
    defer renderer.deinit();
    const size: z.Size = .{ .width = 160, .height = 48, .scale = 1 };
    var dummy: u8 = 0;
    try renderer.begin(.{ .native_context = &dummy, .size = size });
    const Ink = struct {
        fn measure(target: *Renderer, font: commands.Font) !usize {
            target.fill(.{ .x = 0, .y = 0, .width = 160, .height = 48 }, 0xffffff);
            var buffer: commands.Buffer = .{};
            try buffer.textFont(.{ .x = 0, .y = 0, .width = 160, .height = 48 }, "Wide", 0, font);
            try target.replayBuffer(&buffer);
            var surface: cpu_gradient.Surface = undefined;
            if (zlc_gradient_surface(target.native.?, &surface) != 0) return error.DrawGradientFailed;
            var dark: usize = 0;
            for (0..surface.height) |y| for (surface.pixels[y * surface.stride ..][0..surface.width]) |pixel| {
                if (pixel & 0xff < 0x80) dark += 1;
            };
            return dark;
        }
    };
    const body = try Ink.measure(&renderer, .body);
    const heading = try Ink.measure(&renderer, .heading1);
    const bold = try Ink.measure(&renderer, .{ .weight = .bold });
    try std.testing.expect(body > 0);
    try std.testing.expect(heading > body * 2);
    try std.testing.expect(bold > body);
    // Returning to the default font draws the same pixels as before.
    try std.testing.expectEqual(body, try Ink.measure(&renderer, .{}));
}

test "Cairo backdrop effects filter the plane drawn so far and fall back without a workspace" {
    var renderer: Renderer = .{};
    defer renderer.deinit();
    var dummy: u8 = 0;
    try renderer.begin(.{ .native_context = &dummy, .size = .{ .width = 32, .height = 16, .scale = 1 } });
    const workspace = try commands.backdrop.Workspace.create(std.testing.allocator, .{ .max_pixels = 32 * 16 });
    defer workspace.destroy();
    var buffer: commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, 0x000000);
    try buffer.fill(.{ .x = 16, .y = 0, .width = 16, .height = 16 }, 0xffffff);
    try buffer.backdropEffect(.{ .bounds = .{ .x = 8, .y = 0, .width = 16, .height = 16 }, .kind = .blur, .sigma = 2, .fallback = .rgb(0xff0000) });
    buffer.backdrop_storage.workspace = workspace;
    try renderer.replayBuffer(&buffer);
    var surface: cpu_gradient.Surface = undefined;
    if (zlc_gradient_surface(renderer.native.?, &surface) != 0) return error.DrawGradientFailed;
    const left = surface.pixels[8 * surface.stride + 15] & 255;
    try std.testing.expect(left > 40 and left < 128);
    try std.testing.expectEqual(@as(u32, 0xff000000), surface.pixels[8 * surface.stride + 7]);
    try std.testing.expectEqual(@as(u64, 1), workspace.stats.applied);
    // Without a bound workspace the pane draws its fallback fill.
    buffer.backdrop_storage.workspace = null;
    try renderer.replayBuffer(&buffer);
    if (zlc_gradient_surface(renderer.native.?, &surface) != 0) return error.DrawGradientFailed;
    try std.testing.expectEqual(@as(u32, 0xffff0000), surface.pixels[8 * surface.stride + 15]);
}

test "Cairo element effects rewrite a Gaussian capture or an isolation on the target" {
    const allocator = std.testing.allocator;
    const size: z.Size = .{ .width = 32, .height = 16, .scale = 1 };
    var renderer: Renderer = .{};
    defer renderer.deinit();
    try renderer.prepareGaussian(allocator, .{ .layers = .{ .size = size }, .source_size = .{ .width = 32, .height = 16 }, .max_radius = 2 });
    var diagnostic: commands.shader_effects.shader.Diagnostic = .{};
    // Swap red and blue, and paint the margin's empty pixels green.
    const program = try commands.shader_effects.shader.compile(allocator,
        \\vec4 color(vec2 position, vec4 pixel) {
        \\    if (pixel.a == 0.0) return vec4(0.0, 1.0, 0.0, 1.0);
        \\    return pixel.bgra;
        \\}
    , .{}, &diagnostic);
    defer program.destroy();
    const values = commands.shader_effects.shader.Values.init(program);
    const workspace = try commands.shader_effects.Workspace.create(allocator, .{});
    defer workspace.destroy();
    var buffer: commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 32, .height = 16 }, 0xffffff);
    try buffer.beginEffect(.{ .program = program, .values = values, .target = .element, .box = .{ .x = 4, .y = 4, .width = 8, .height = 8 }, .margin = 2 });
    try buffer.fill(.{ .x = 4, .y = 4, .width = 8, .height = 8 }, 0xff0000);
    try buffer.endEffect();
    buffer.shader_storage.workspace = workspace;
    var dummy: u8 = 0;
    try renderer.begin(.{ .native_context = &dummy, .size = size });
    try renderer.replayBuffer(&buffer);
    var surface: cpu_gradient.Surface = undefined;
    if (zlc_gradient_surface(renderer.native.?, &surface) != 0) return error.DrawGradientFailed;
    try std.testing.expectEqual(@as(u32, 0xff0000ff), surface.pixels[8 * surface.stride + 8]);
    // The margin (and one-pixel halo) was transparent in the capture.
    try std.testing.expectEqual(@as(u32, 0xff00ff00), surface.pixels[8 * surface.stride + 3]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), surface.pixels[8 * surface.stride + 1]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), surface.pixels[8 * surface.stride + 0]);
    try std.testing.expectEqual(@as(u64, 1), workspace.stats.applied);
    renderer.abort();
    // Without a Gaussian workspace (and without layers) the body is
    // isolated on the target: the capture has no halo.
    try renderer.releaseLayers();
    try renderer.begin(.{ .native_context = &dummy, .size = size });
    try renderer.replayBuffer(&buffer);
    if (zlc_gradient_surface(renderer.native.?, &surface) != 0) return error.DrawGradientFailed;
    try std.testing.expectEqual(@as(u32, 0xff0000ff), surface.pixels[8 * surface.stride + 8]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), surface.pixels[8 * surface.stride + 2]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), surface.pixels[8 * surface.stride + 1]);
    try std.testing.expectEqual(@as(u64, 2), workspace.stats.applied);
    // A workspace too small to isolate draws the body unchanged.
    const small = try commands.shader_effects.Workspace.create(allocator, .{ .max_pixels = 16 });
    defer small.destroy();
    buffer.shader_storage.workspace = small;
    try renderer.replayBuffer(&buffer);
    if (zlc_gradient_surface(renderer.native.?, &surface) != 0) return error.DrawGradientFailed;
    try std.testing.expectEqual(@as(u32, 0xffff0000), surface.pixels[8 * surface.stride + 8]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), surface.pixels[8 * surface.stride + 2]);
    try std.testing.expectEqual(@as(u64, 1), small.stats.skipped);
}
