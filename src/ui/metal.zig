//! The macOS GPU renderer: replays a frame's commands with Metal into a
//! CAMetalLayer of the window's view (src/ui/metal.m).
//!
//! It draws fills, rounded shapes and strokes, gradients (linear, radial
//! and conic, padded, repeated or reflected, mixed in sRGB, linear sRGB or
//! Oklab), text, prepared text, coverage masks, images, clips, groups (at
//! an opacity, through a mask, or filtered with a Gaussian kernel), raster
//! transforms, shader effects (element effects over a capture of their
//! content and backdrop shaders over a copy of the target, with programs
//! translated to MSL and compiled outside paint by `prepareEffect`), inside
//! raster transforms too, backdrop effects (blur, glass and scroll edges,
//! filtered from a copy of the target as the software planes filter it) and
//! loading indicators (their scenes evaluated per pixel). Groups and
//! transforms capture their content in textures of the frame, as the
//! software planes do; their limits (depth, transform sources, Gaussian
//! capacity) are the software renderer's plan, which `Context` checks each
//! frame against. A frame that uses anything else (a shader program not
//! prepared, GPU textures without a device domain) draws on the software
//! plane instead, as
//! `prepareEffects` tells; so does a frame drawing an image or mask not yet
//! uploaded (`holdsFrame`), which `residentFrame` uploads for the next.
//!
//! The window's frame is kept between frames: `replayDamage` draws again
//! only the device pixels that changed (src/ui/damage.zig).
//!
//! A renderer made in a device domain (`Options.domain`,
//! src/ui/gpu_resources.zig) draws with the domain's device, and draws the
//! domain's GPU textures (`Frame.texture`); a frame drawing a texture of
//! another domain fails whole, before it draws anything. When the domain
//! loses its device, the renderer's objects go with it; after
//! `DeviceDomain.recreate` the next frame or upload takes the new device,
//! and images and masks are uploaded again as frames draw them.
const std = @import("std");
const zio = @import("ziggurat_io");
const fonts = @import("ziggurat_fonts");
const z = @import("ziggurat");
pub const commands = @import("commands.zig");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const drawing = @import("ziggurat_drawing_resources");
const image_cache = @import("image_cache.zig");
const layers = @import("layers.zig");
const gpu_resources = @import("gpu_resources.zig");
const gaussian_scope = @import("gaussian_scope.zig");
const effect_host = @import("gpu_effect_host.zig");
const shader_effects = commands.shader_effects;
const gaussian = @import("gaussian_filter.zig");
const damage = @import("damage.zig");
const backdrop = commands.backdrop;
const loading = commands.loading;

extern fn zmtl_create(*c_int) ?*anyopaque;
extern fn zmtl_create_in_domain(*anyopaque, *c_int) ?*anyopaque;
extern fn zmtl_rebuild(*anyopaque) c_int;
extern fn zmtl_offscreen_prepare(*anyopaque, u32, u32) c_int;
extern fn zmtl_texture(*anyopaque, *const drawing.GpuTextureToken, *const drawing.ImagePlan) c_int;
extern fn zmtl_inject_loss(*anyopaque) void;
extern fn zmtl_offscreen_commit(*anyopaque) void;
extern fn zmtl_offscreen_objects(*anyopaque) u32;
extern fn zmtl_read_front(*anyopaque, [*]u32, u32, u32) c_int;
extern fn zmtl_destroy(?*anyopaque) void;
extern fn zmtl_live_objects() u32;
extern fn zmtl_begin(*anyopaque, ?*anyopaque, u32, u32, f32, c_int) c_int;
extern fn zmtl_begin_offscreen(*anyopaque, u32, u32, f32, c_int) c_int;
extern fn zmtl_scale(*anyopaque) f32;
extern fn zmtl_fill(*anyopaque, f32, f32, f32, f32, u32) void;
extern fn zmtl_shape(*anyopaque, f32, f32, f32, f32, f32, f32, u32) c_int;
extern fn zmtl_gradient(*anyopaque, f32, f32, f32, f32, f32, f32, *const commands.brushes.Native, u32, u32) c_int;
extern fn zmtl_begin_group(*anyopaque, *const layers.NativeGroup) c_int;
extern fn zmtl_begin_gaussian(*anyopaque, *const layers.NativeGroup, i32, i32, u32, u32, u32, *const [gaussian.arithmetic.capacity]u32) c_int;
extern fn zmtl_end_group(*anyopaque) c_int;
extern fn zmtl_begin_transform(*anyopaque, u32, u32, f32, f32) c_int;
extern fn zmtl_end_transform(*anyopaque, *const [6]f64, *const [4]f32) c_int;
extern fn zmtl_plane(*anyopaque, *u64) c_int;
extern fn zmtl_set_partial(*anyopaque, c_int) void;
extern fn zmtl_clear_box(*anyopaque, i32, i32, i32, i32) void;
extern fn zmtl_push_device_clip(*anyopaque, i32, i32, i32, i32) void;
extern fn zmtl_forget_plane(*anyopaque) void;
extern fn zmtl_push_clip(*anyopaque, f32, f32, f32, f32) void;
extern fn zmtl_pop_clip(*anyopaque) void;
extern fn zmtl_text(*anyopaque, f32, f32, f32, f32, [*]const u8, u32, u32, f32, u16, c_int, c_int, ?[*:0]const u8) c_int;
extern fn zmtl_prepared(*anyopaque, *anyopaque, *const drawing.NativeCoverage, f32, f32, ?*const drawing.Rect, u32) c_int;
extern fn zmtl_forget_prepared(*anyopaque) void;
extern fn zmtl_reserve_images(*anyopaque, u32) c_int;
extern fn zmtl_prepare_image(*anyopaque, [*]const drawing.ImageLevel, u32) c_int;
extern fn zmtl_prepare_coverage(*anyopaque, *const drawing.NativeCoverage) c_int;
extern fn zmtl_commit_image(*anyopaque, u32) void;
extern fn zmtl_release_image(*anyopaque, u32) void;
extern fn zmtl_update_image(*anyopaque, u32, [*]const drawing.ImageLevel, u32) c_int;
extern fn zmtl_coverage(*anyopaque, u32, f32, f32, u32) c_int;
extern fn zmtl_image(*anyopaque, u32, *const drawing.ImagePlan) c_int;
extern fn zmtl_end(*anyopaque) c_int;
extern fn zmtl_end_offscreen(*anyopaque, ?[*]u8, usize) c_int;
extern fn zmtl_abort(*anyopaque) void;
extern fn zmtl_suspend(*anyopaque) c_int;
extern fn zmtl_restore(*anyopaque) void;
extern fn zmtl_stats(*anyopaque, *NativeStats) void;
extern fn zmtl_effect_install(*anyopaque, u32, [*]const u8, usize) c_int;
extern fn zmtl_effect_installed(*anyopaque, u32) c_int;
extern fn zmtl_effect_passes(*anyopaque) u64;
extern fn zmtl_effect_geometry(*anyopaque, *EffectGeometry) c_int;
extern fn zmtl_begin_effect(*anyopaque, i32, i32, u32, u32, u32) c_int;
extern fn zmtl_end_effect(*anyopaque, ?*const EffectPass, u32) c_int;
extern fn zmtl_backdrop_shader(*anyopaque, *const EffectPass, *const [4]u32, *const [4]u32) c_int;
extern fn zmtl_backdrop(*anyopaque, *const Glass, u32, [*]const GlassLevel, [*]const f32, u32) c_int;
extern fn zmtl_indicator(*anyopaque, [*]const f32, u32, f32, f32, f32, *const [4]i32, u32, f32) c_int;
extern fn zmtl_test_display([*:0]const u8) void;
extern fn zmtl_test_capture(*anyopaque, c_int) void;
extern fn zmtl_test_pixel(*anyopaque, u32, u32) u32;
extern fn zmtl_test_pixels(*anyopaque, [*]u32, u32, u32) c_int;
extern fn zmtl_test_layer_shown(*anyopaque) c_int;
extern fn zmtl_test_layer_under_subviews(*anyopaque) c_int;
extern fn zmtl_test_layer_flipped(*anyopaque) c_int;
extern fn zmtl_test_atlas_levels(*anyopaque) u32;

const NativeStats = extern struct { device_creations: u32, layer_creations: u32, resizes: u32, presents: u32, transaction_presents: u32, busy_presents: u32, atlas_pages: u32, glyphs: u32, frames: u64, instances: u64, batches: u64, effect_passes: u64, layers: u64, filter_passes: u64, partial_frames: u64, cached_pipelines: u64, backdrops: u64, indicators: u64, offscreen_targets: u64, device_losses: u64 };
/// A backdrop effect's plan for src/ui/metal.m (ZmGlass).
const Glass = extern struct { box: [4]f32, clip: [4]f32, tone: [4]f32, tint: [4]f32, line: [4]f32, line2: [4]f32, misc: [4]f32, misc2: [4]f32, background: [4]f32, fill: [4]f32, region: [4]u32, out: [4]u32 };
const GlassLevel = extern struct { radius: u32, lo: f32, hi: f32, weights: u32 };
const kernel_len = 2 * backdrop.max_radius_pixels + 1;
const EffectPass = extern struct { words: [*]const u32, word_count: u32, slot: u32, params: effect_host.Params };
const EffectGeometry = extern struct { clip: [4]f64, scale: f32, origin: [2]f32, width: u32, height: u32, transparent: u32 };
/// Captures (groups, transforms and element effects) nested in one another
/// at most, as src/ui/metal.m holds them.
const max_capture_depth = 8;
/// Largest texture side a capture may have.
const max_texture = 16384;

pub const Driver = enum { hardware, warp };
pub const Options = struct {
    /// Metal always uses the system's default device.
    driver: Driver = .hardware,
    /// Draw with this domain's device, and its textures.
    domain: ?*gpu_resources.DeviceDomain = null,
    /// Revoked by the domain when it loses its device; Metal frames never
    /// wait on a handle, so nothing is put in it.
    native_wait_slot: ?*?z.NativeWaitToken = null,
};
/// presents counts drawables presented, transaction_presents those presented
/// with the Core Animation transaction (frames that changed the layer and
/// those of a live resize), busy_presents frames for which no drawable came.
/// layers counts groups and transforms composited, filter_passes Gaussian
/// filter passes, partial_frames frames that drew only their damage and
/// cached_pipelines pipelines made from the disk cache's compiled code,
/// backdrops backdrop effects and indicators loading indicators drawn,
/// offscreen_targets offscreen targets made and device_losses the devices
/// this renderer lost with its domain.
pub const Stats = struct { device_creations: u32 = 0, layer_creations: u32 = 0, resizes: u32 = 0, presents: u32 = 0, transaction_presents: u32 = 0, busy_presents: u32 = 0, atlas_pages: u32 = 0, glyphs: u32 = 0, frames: u64 = 0, instances: u64 = 0, batches: u64 = 0, effect_passes: u64 = 0, layers: u64 = 0, filter_passes: u64 = 0, partial_frames: u64 = 0, cached_pipelines: u64 = 0, backdrops: u64 = 0, indicators: u64 = 0, offscreen_targets: u64 = 0, device_losses: u64 = 0 };

/// Renderers and device domains alive.
pub fn liveObjects() u32 {
    return zmtl_live_objects();
}
/// As d3d11.globalResourceCount: the native objects alive, renderers and
/// device domains.
pub fn globalResourceCount() u32 {
    return zmtl_live_objects();
}

pub const Renderer = struct {
    native: ?*anyopaque = null,
    /// Kept for the shared failure report; Metal has no HRESULT.
    last_hresult: i32 = 0,
    active: bool = false,
    offscreen: bool = false,
    /// The device domain this renderer draws with, its attachment, the
    /// domain generation whose device it holds, and the domain operation a
    /// frame keeps open from begin to its end.
    domain: ?*gpu_resources.DeviceDomain = null,
    domain_borrow: ?gpu_resources.DeviceDomain.Borrow = null,
    device_generation: u64 = 0,
    render_scope: ?z.AppCallbackScope = null,
    interpolation_mutating: bool = false,
    images: image_cache.Cache = .{},
    /// The view is being drawn into a capture: its software frame must not
    /// hide the layer the window shows.
    capturing: bool = false,
    /// Installed shader programs, the slot each of this frame's entries
    /// runs in, and the frame whose effects replay draws.
    effect_table: effect_host.Table = .{},
    effect_slots: [shader_effects.max_entries]u32 = undefined,
    effect_buffer: ?*const commands.Buffer = null,

    pub fn init(self: *Renderer, options: Options) !void {
        if (self.native != null) return error.AlreadyInitialized;
        var failure: c_int = 0;
        if (options.domain) |domain| {
            const borrow = try domain.acquireRenderer(options.native_wait_slot);
            errdefer domain.releaseRenderer(borrow.slot);
            const scope = try domain.beginRenderer();
            defer {
                domain.endRenderer();
                scope.end();
            }
            const native = zmtl_create_in_domain(borrow.native, &failure) orelse {
                self.last_hresult = failure;
                return error.GraphicsInitializationFailed;
            };
            errdefer zmtl_destroy(native);
            try domain.checkRendererReady();
            self.native = native;
            self.domain = domain;
            self.domain_borrow = borrow;
            self.device_generation = borrow.epoch.generation;
            return;
        }
        self.native = zmtl_create(&failure) orelse return error.GraphicsInitializationFailed;
        self.last_hresult = failure;
    }
    /// For an offscreen surface (src/ui/gpu_offscreen_metal.zig): success
    /// takes the surface's attachment; failure leaves it with the caller.
    pub fn initOffscreen(self: *Renderer, domain: *gpu_resources.DeviceDomain, borrow: gpu_resources.DeviceDomain.Borrow) !void {
        try domain.validateRendererBorrow(borrow);
        if (self.native != null) return error.AlreadyInitialized;
        var failure: c_int = 0;
        const native = zmtl_create_in_domain(borrow.native, &failure) orelse {
            self.last_hresult = failure;
            return error.GraphicsInitializationFailed;
        };
        errdefer zmtl_destroy(native);
        try domain.checkRendererReady();
        self.native = native;
        self.domain = domain;
        self.domain_borrow = borrow;
        self.device_generation = borrow.epoch.generation;
    }
    pub fn deinit(self: *Renderer) void {
        _ = self.deinitInternal(true);
    }
    /// An offscreen surface's teardown: the surface releases the attachment
    /// once its own memory is freed.
    pub fn deinitRetainingBorrow(self: *Renderer) ?gpu_resources.DeviceDomain.Borrow {
        return self.deinitInternal(false);
    }
    fn deinitInternal(self: *Renderer, release_borrow: bool) ?gpu_resources.DeviceDomain.Borrow {
        const domain = self.domain;
        const borrow = self.domain_borrow;
        const cleanup = if (domain) |value| value.beginRendererCleanup() catch unreachable else null;
        if (self.render_scope) |scope| {
            self.render_scope = null;
            domain.?.endRenderer();
            scope.end();
        }
        if (domain) |value| value.clearRendererWait(borrow.?.slot);
        if (self.native) |native| zmtl_destroy(native);
        self.images.deinit();
        self.effect_table.deinit();
        self.* = .{};
        if (domain) |value| {
            if (release_borrow) value.releaseRenderer(borrow.?.slot);
            value.endRenderer();
        }
        if (cleanup) |scope| scope.end();
        return if (release_borrow) null else borrow;
    }
    /// Opens the domain operation a frame or an upload runs in, and takes
    /// the domain's device again when it lost the one this renderer had:
    /// what was uploaded with that one is gone, and uploads again.
    fn enterDomain(self: *Renderer) !?z.AppCallbackScope {
        const domain = self.domain orelse return null;
        const scope = try domain.beginRenderer();
        errdefer {
            domain.endRenderer();
            scope.end();
        }
        try self.syncDevice();
        return scope;
    }
    fn leaveDomain(self: *Renderer, scope: ?z.AppCallbackScope) void {
        if (scope) |value| {
            self.domain.?.endRenderer();
            value.end();
        }
    }
    fn syncDevice(self: *Renderer) !void {
        const borrow = self.domain_borrow orelse return;
        if (borrow.epoch.generation == self.device_generation) return;
        self.images.clear();
        switch (zmtl_rebuild(self.native.?)) {
            0 => {},
            2 => return error.DomainDeviceLost,
            else => return error.GraphicsFailed,
        }
        self.device_generation = borrow.epoch.generation;
    }
    fn finishScope(self: *Renderer) void {
        const scope = self.render_scope orelse return;
        self.render_scope = null;
        self.leaveDomain(scope);
    }

    pub fn begin(self: *Renderer, paint: z.Paint) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        _ = try geometry.validateSurface(paint.size.width, paint.size.height, paint.size.scale);
        const scope = try self.enterDomain();
        errdefer self.leaveDomain(scope);
        self.capturing = false;
        switch (zmtl_begin(native, paint.native_window, paint.size.width, paint.size.height, paint.size.scale, @intFromBool(paint.transparent))) {
            0 => {},
            1 => return error.NoSurface,
            4 => {
                self.capturing = true;
                return error.NotDrawingToScreen;
            },
            else => return error.GraphicsFailed,
        }
        self.render_scope = scope;
        self.active = true;
        self.offscreen = false;
    }
    /// A frame drawn into an owned texture rather than the window, read
    /// back by `endOffscreen`; for checks that compare it with software.
    pub fn beginOffscreen(self: *Renderer, size: z.Size, transparent: bool) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        _ = try geometry.validateSurface(size.width, size.height, size.scale);
        const scope = try self.enterDomain();
        errdefer self.leaveDomain(scope);
        if (zmtl_begin_offscreen(native, size.width, size.height, size.scale, @intFromBool(transparent)) != 0) return error.GraphicsFailed;
        self.render_scope = scope;
        self.active = true;
        self.offscreen = true;
    }
    /// Premultiplied BGRA rows of `stride` bytes.
    pub fn endOffscreen(self: *Renderer, pixels: ?[]u8, stride: usize) !void {
        if (!self.active or !self.offscreen) return error.NotDrawing;
        defer self.finishScope();
        self.active = false;
        switch (zmtl_end_offscreen(self.native.?, if (pixels) |value| value.ptr else null, stride)) {
            0 => {},
            3 => return error.DeviceLost,
            else => return error.GraphicsFailed,
        }
    }
    /// Makes an offscreen surface's targets for `size` now rather than
    /// at its first frames.
    pub fn prepareOffscreen(self: *Renderer, size: z.Size) !void {
        if (zmtl_offscreen_prepare(self.native orelse return error.NotInitialized, size.width, size.height) != 0) return error.GraphicsFailed;
    }
    /// An offscreen surface's frame drawn: it becomes the front.
    pub fn commitOffscreen(self: *Renderer) void {
        zmtl_offscreen_commit(self.native.?);
    }
    /// The offscreen targets held: the front and the work target.
    pub fn offscreenObjects(self: *const Renderer) u32 {
        return if (self.native) |native| zmtl_offscreen_objects(native) else 0;
    }
    /// The committed front's 0xAARRGGBB pixels, premultiplied; for tests.
    pub fn readFront(self: *Renderer, pixels: []u32, width: u32, height: u32) !void {
        if (pixels.len != @as(usize, width) * height) return error.InvalidGeometry;
        if (zmtl_read_front(self.native.?, pixels.ptr, width, height) != 0) return error.NoFrame;
    }
    /// The next offscreen frame fails as one on a removed device does.
    pub fn injectDeviceLoss(self: *Renderer) void {
        if (self.native) |native| zmtl_inject_loss(native);
    }
    pub fn end(self: *Renderer) !void {
        if (!self.active) return error.NotDrawing;
        if (self.offscreen) return error.SurfaceModeMismatch;
        defer self.finishScope();
        self.active = false;
        switch (zmtl_end(self.native.?)) {
            0 => {},
            3 => return error.PresentationBusy,
            else => return error.GraphicsFailed,
        }
    }
    pub fn abort(self: *Renderer) void {
        if (self.native) |native| zmtl_abort(native);
        self.active = false;
        self.finishScope();
    }
    pub fn discard(self: *Renderer) void {
        self.abort();
    }
    /// The software renderer draws the next frame: hide the layer over the
    /// view's own drawing. True when it was shown.
    pub fn suspendSurface(self: *Renderer) bool {
        const native = self.native orelse return false;
        if (self.capturing) return false;
        return zmtl_suspend(native) != 0;
    }
    pub fn restoreSurface(self: *Renderer) void {
        if (self.native) |native| zmtl_restore(native);
    }
    /// Frames never wait on a handle: one without a drawable draws in
    /// software.
    pub fn frameReadyHandle(_: *const Renderer) ?*anyopaque {
        return null;
    }

    /// Whether the GPU draws `buffer`; see the module's documentation. Each
    /// shader program it uses must have been prepared with `prepareEffect`;
    /// shader effects also need the frame's shader workspace and the
    /// frame's scale. Gaussian groups need kernels at the frame's scale;
    /// every capture must fit a texture.
    pub fn prepareEffects(self: *Renderer, buffer: *const commands.Buffer) bool {
        const native = self.native orelse return false;
        if (!self.active) return false;
        const scale = zmtl_scale(native);
        // A domain's renderer draws its textures; the frame fails at replay
        // when one is another domain's.
        if (self.domain_borrow == null) for (buffer.commands()) |op| switch (op) {
            .texture => return false,
            else => {},
        };
        for (buffer.preparedTextResources()) |view| if (view.native_coverage == null) return false;
        const entries = buffer.shaderEntries();
        const filters = buffer.filterResources();
        const transforms = buffer.transformResources();
        const workspace = buffer.shader_storage.workspace;
        const Scope = enum { group, transform, effect };
        var scopes: [max_capture_depth]Scope = undefined;
        var depth: usize = 0;
        var uses = false;
        // Masked clips draw as groups masked by their coverage: the clip
        // depth of each, a bit for each depth.
        var clip_depth: usize = 0;
        var masked: u64 = 0;
        for (buffer.commands()) |op| switch (op) {
            .push_clip => clip_depth += 1,
            .push_mask_clip => {
                if (depth == scopes.len or clip_depth >= 64) return false;
                masked |= @as(u64, 1) << @intCast(clip_depth);
                clip_depth += 1;
                scopes[depth] = .group;
                depth += 1;
            },
            .pop_clip => {
                if (clip_depth == 0) return false;
                clip_depth -= 1;
                if (masked & (@as(u64, 1) << @intCast(clip_depth)) != 0) {
                    masked &= ~(@as(u64, 1) << @intCast(clip_depth));
                    if (depth == 0) return false;
                    depth -= 1;
                }
            },
            .begin_group => |value| {
                if (depth == scopes.len) return false;
                if (value.filter_slot != commands.no_filter) {
                    if (value.filter_slot >= filters.len) return false;
                    const kernel = filters[value.filter_slot].descriptor;
                    if (kernel.radius != 0) {
                        if (kernel.scale != scale) return false;
                        const r = value.bounds;
                        const capture = gaussian_scope.Capture.init(.{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }, kernel) catch return false;
                        if (capture.pixelWidth() > max_texture or capture.pixelHeight() > max_texture) return false;
                    }
                }
                scopes[depth] = .group;
                depth += 1;
            },
            .begin_transform => |slot| {
                if (depth == scopes.len or slot >= transforms.len) return false;
                const t = transforms[slot];
                if (t.pixel_width + 2 > max_texture or t.pixel_height + 2 > max_texture) return false;
                scopes[depth] = .transform;
                depth += 1;
            },
            .effect => |slot| {
                uses = true;
                if (depth == scopes.len) return false;
                const shaders = workspace orelse return false;
                if (slot >= entries.len) return false;
                const entry = &entries[slot];
                if (entry.scale != scale) return false;
                const kernel = shaders.carrierFor(entry.scale) catch return false;
                const capture = gaussian_scope.Capture.init(entry.captureRect(), kernel) catch return false;
                if (capture.pixelWidth() > max_texture or capture.pixelHeight() > max_texture) return false;
                scopes[depth] = .effect;
                depth += 1;
            },
            .end_group, .end_transform, .end_effect => {
                if (depth == 0) return false;
                depth -= 1;
            },
            .backdrop_shader => |slot| {
                uses = true;
                if (workspace == null or slot >= entries.len) return false;
            },
            else => {},
        };
        if (depth != 0) return false;
        if (!uses) return true;
        if (entries.len > self.effect_slots.len) return false;
        self.effect_table.beginFrame();
        for (entries, 0..) |*entry, i| {
            const slot = self.effect_table.find(entry.program.identity, entry.target) orelse return false;
            if (zmtl_effect_installed(native, slot) == 0) return false;
            self.effect_slots[i] = slot;
        }
        return true;
    }
    /// Translate `program` drawn as `target` to MSL and compile it, outside
    /// a frame. False when the compiler rejects it: frames using it draw in
    /// software. Metal keeps compiled shaders in its own cache across runs;
    /// the renderer keeps them while it lives.
    pub fn prepareEffect(self: *Renderer, allocator: std.mem.Allocator, program: *const shader_effects.shader.Program, target: shader_effects.Target) !bool {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        const table = &self.effect_table;
        table.beginFrame();
        if (table.find(program.identity, target)) |slot| {
            if (zmtl_effect_installed(native, slot) != 0) return true;
            const code = table.entries[slot].code;
            return zmtl_effect_install(native, slot, code.ptr, code.len) == 0;
        }
        if (table.failed(program.identity, target)) return false;
        var translation = shader_effects.shader.gpu.translate(allocator, program, .msl) catch |err| switch (err) {
            error.UnsupportedProgram => {
                table.fail(program.identity, target);
                return false;
            },
            else => |e| return e,
        };
        defer translation.deinit();
        const source = try effect_host.source(allocator, &translation, program.kind, target, .msl);
        defer allocator.free(source);
        const slot = table.victim() orelse return false;
        switch (zmtl_effect_install(native, slot, source.ptr, source.len)) {
            0 => {},
            // The compiler rejects the program: remember it.
            2 => {
                table.fail(program.identity, target);
                return false;
            },
            else => return false,
        }
        const code = try allocator.dupe(u8, source);
        errdefer allocator.free(code);
        const inputs = try allocator.dupe(u16, translation.inputs);
        table.fill(slot, program.identity, target, inputs, code, allocator);
        return true;
    }
    const OpenEffect = struct { slot: u8, capture: gaussian_scope.Capture };
    fn effectSource(self: *const Renderer, slot: u8) !struct { *const shader_effects.Entry, *shader_effects.Workspace } {
        const buffer = self.effect_buffer orelse return error.SoftwareOnlyCommands;
        if (slot >= buffer.shader_storage.len) return error.MissingResources;
        return .{ &buffer.shader_storage.entries[slot], buffer.shader_storage.workspace orelse return error.ShaderEffectsNotPrepared };
    }
    /// Open an element effect's capture, as the carrier kernel bounds it.
    fn beginEffect(self: *Renderer, slot: u8) !OpenEffect {
        const entry, const workspace = try self.effectSource(slot);
        const kernel = try workspace.carrierFor(entry.scale);
        const capture = try gaussian_scope.Capture.init(entry.captureRect(), kernel);
        switch (zmtl_begin_effect(self.native.?, capture.left, capture.top, capture.width, capture.height, capture.radius)) {
            0 => {},
            1 => return error.LayerDepthExceeded,
            else => return error.GraphicsFailed,
        }
        return .{ .slot = slot, .capture = capture };
    }
    /// Run the effect over its capture, or over budget or with a faulting
    /// prologue composite the content as drawn.
    fn endEffect(self: *Renderer, open: OpenEffect, words: []u32) !void {
        const entry, const workspace = try self.effectSource(open.slot);
        const capture = open.capture;
        const status = if (!shader_effects.startElement(workspace, entry, @as(u64, capture.pixelWidth()) * capture.pixelHeight(), capture.scale))
            zmtl_end_effect(self.native.?, null, entry.opacity)
        else status: {
            const pass = self.effectPass(open.slot, words, effect_host.elementParams(entry, capture), workspace);
            break :status zmtl_end_effect(self.native.?, &pass, entry.opacity);
        };
        if (status != 0) return error.GraphicsFailed;
    }
    fn backdropShader(self: *Renderer, slot: u8, words: []u32) !void {
        const entry, const workspace = try self.effectSource(slot);
        var target: EffectGeometry = undefined;
        if (zmtl_effect_geometry(self.native.?, &target) != 0) return error.NotDrawing;
        const origin = [2]f64{ target.origin[0], target.origin[1] };
        const plan = shader_effects.planBackdrop(target.width, target.height, target.scale, origin, target.clip, entry) orelse return;
        const room: ?usize = if (self.effect_buffer.?.backdrop_storage.workspace) |space| space.planes.len else null;
        if (!shader_effects.startBackdrop(workspace, entry, plan, room, target.scale)) return;
        const pass = self.effectPass(slot, words, effect_host.backdropParams(entry, plan, target.scale, origin, target.clip, target.transparent != 0), workspace);
        const region = [4]u32{ @intCast(plan.region[0]), @intCast(plan.region[1]), @intCast(plan.region[2]), @intCast(plan.region[3]) };
        const out = [4]u32{ @intCast(plan.out[0]), @intCast(plan.out[1]), @intCast(plan.out[2]), @intCast(plan.out[3]) };
        if (zmtl_backdrop_shader(self.native.?, &pass, &region, &out) != 0) return error.GraphicsFailed;
    }
    /// Filters the target beneath a backdrop effect as the software planes
    /// do (src/ui/backdrop.zig), counting it in the workspace's statistics.
    fn backdropEffect(self: *Renderer, entry: backdrop.Entry, workspace: ?*backdrop.Workspace) !void {
        var target: EffectGeometry = undefined;
        if (zmtl_effect_geometry(self.native.?, &target) != 0) return error.NotDrawing;
        const p = backdrop.plan(.{ .width = target.width, .height = target.height, .scale = target.scale, .origin = .{ target.origin[0], target.origin[1] }, .clip = target.clip }, entry, workspace);
        if (p.mode == .empty) return;
        const shading = p.shading;
        const f = struct {
            fn v(value: f64) f32 {
                return @floatCast(value);
            }
        }.v;
        const region = if (p.mode == .fill) p.out else p.sample;
        var glass: Glass = .{
            .box = .{ f(p.box.x0), f(p.box.y0), f(p.box.x1), f(p.box.y1) },
            .clip = .{ f(p.clip[0]), f(p.clip[1]), f(p.clip[2]), f(p.clip[3]) },
            .tone = .{ f(shading.tone.low), f(shading.tone.high), f(shading.tone.curve), f(shading.tone.saturation) },
            .tint = .{ f(shading.tint[0]), f(shading.tint[1]), f(shading.tint[2]), f(shading.tint[3]) },
            .line = @splat(0),
            .line2 = @splat(0),
            .misc = .{ f(p.box.radius), f(shading.refraction), f(shading.bezel), f(shading.noise) },
            .misc2 = .{ f(shading.rim), if (p.mode == .fill) 3 else @floatFromInt(@backingInt(shading.kind)), @floatFromInt(target.transparent), if (shading.progressive != null) 1 else 0 },
            .background = .{ f(shading.background[0]), f(shading.background[1]), f(shading.background[2]), 0 },
            .fill = .{ @as(f32, @floatFromInt(p.fill.r)) / 255, @as(f32, @floatFromInt(p.fill.g)) / 255, @as(f32, @floatFromInt(p.fill.b)) / 255, @as(f32, @floatFromInt(p.fill.a)) / 255 },
            .region = .{ @intCast(region.x0), @intCast(region.y0), @intCast(region.x1), @intCast(region.y1) },
            .out = .{ @intCast(p.out.x0), @intCast(p.out.y0), @intCast(p.out.x1), @intCast(p.out.y1) },
        };
        var levels: [16]GlassLevel = undefined;
        var weights: [16 * kernel_len]f32 = undefined;
        var count: usize = 0;
        if (p.mode == .filter) {
            var kernel: [kernel_len]f64 = undefined;
            if (shading.progressive) |line| {
                glass.line = .{ f(line.x), f(line.y), f(line.dx), f(line.dy) };
                glass.line2 = .{ f(line.length), f(line.from), f(line.to), 0 };
                var planned: [16]backdrop.Level = undefined;
                for (planned[0..backdrop.blurLevels(&planned, line.least, line.most)]) |level| {
                    const radius = backdrop.gaussianWeights(level.blur, &kernel);
                    for (0..2 * radius + 1) |i| weights[count * kernel_len + i] = f(kernel[i]);
                    levels[count] = .{ .radius = @intCast(radius), .lo = f(level.lo), .hi = f(level.hi), .weights = @intCast(count * kernel_len) };
                    count += 1;
                }
            } else {
                const radius = backdrop.gaussianWeights(shading.sigma, &kernel);
                if (radius != 0) {
                    for (0..2 * radius + 1) |i| weights[i] = f(kernel[i]);
                    levels[0] = .{ .radius = @intCast(radius), .lo = 0, .hi = 0, .weights = 0 };
                    count = 1;
                }
            }
        }
        if (zmtl_backdrop(self.native.?, &glass, @intCast(count), &levels, &weights, weights.len) != 0) return error.GraphicsFailed;
    }
    /// Draws a loading indicator, its scene evaluated per pixel as the
    /// software planes rasterize it (src/ui/loading.zig).
    fn indicator(self: *Renderer, entry: loading.Entry) !void {
        var target: EffectGeometry = undefined;
        if (zmtl_effect_geometry(self.native.?, &target) != 0) return error.NotDrawing;
        var elements: [loading.max_elements * loading.element_floats]f32 = undefined;
        const scene = loading.encode(entry, &elements);
        const origin = [2]f64{ target.origin[0], target.origin[1] };
        const placed = loading.place(.{ .width = target.width, .height = target.height, .scale = target.scale, .origin = origin, .clip = target.clip }, entry, scene.width) orelse return;
        if (scene.count == 0) return;
        // The instances' coordinates are the target's less its origin.
        const box = [4]i32{
            @intFromFloat(@as(f64, @floatFromInt(placed.x0)) - origin[0]),
            @intFromFloat(@as(f64, @floatFromInt(placed.y0)) - origin[1]),
            @intFromFloat(@as(f64, @floatFromInt(placed.x1)) - origin[0]),
            @intFromFloat(@as(f64, @floatFromInt(placed.y1)) - origin[1]),
        };
        const rgb = (@as(u32, entry.color.r) << 16) | (@as(u32, entry.color.g) << 8) | entry.color.b;
        if (zmtl_indicator(self.native.?, &elements, @intCast(scene.count), @floatCast(placed.ox - origin[0]), @floatCast(placed.oy - origin[1]), @floatCast(placed.k), &box, rgb, @as(f32, @floatFromInt(entry.color.a)) / 255) != 0) return error.GraphicsFailed;
    }
    fn effectPass(self: *Renderer, slot: u8, words: []u32, params: effect_host.Params, workspace: *shader_effects.Workspace) EffectPass {
        const installed = self.effect_slots[slot];
        const inputs = self.effect_table.entries[installed].inputs;
        for (inputs, 0..) |register, i| words[i] = workspace.machine.registers[register];
        return .{ .words = words.ptr, .word_count = @intCast(inputs.len), .slot = installed, .params = params };
    }
    /// Shader passes run on the GPU since the renderer was created.
    pub fn effectPasses(self: *const Renderer) u64 {
        return if (self.native) |native| zmtl_effect_passes(native) else 0;
    }

    pub fn replayBuffer(self: *Renderer, buffer: *const commands.Buffer) !void {
        self.effect_buffer = if (self.prepareEffects(buffer)) buffer else null;
        defer self.effect_buffer = null;
        try self.replayAll(buffer.commands(), buffer.textBytes(), buffer.brushResources(), buffer.preparedTextResources(), buffer.imageResources(), buffer.coverageResources(), buffer.textureResources(), buffer.transformResources(), buffer.filterResources());
    }
    /// Whether the window's frame kept from the last one may be drawn over,
    /// and which frame it holds; for the damage tracker. Valid between
    /// `begin` and the end of the frame.
    pub fn planeKept(self: *const Renderer) bool {
        var generation: u64 = 0;
        return if (self.native) |native| self.active and !self.offscreen and zmtl_plane(native, &generation) != 0 else false;
    }
    pub fn planeGeneration(self: *const Renderer) u64 {
        var generation: u64 = 0;
        if (self.native) |native| _ = zmtl_plane(native, &generation);
        // Apart from the software plane's generations.
        return generation | (1 << 63);
    }
    /// The kept frame no longer holds the last frame the tracker saw drawn.
    pub fn forgetPlane(self: *Renderer) void {
        if (self.native) |native| zmtl_forget_plane(native);
    }
    /// Draws `buffer` again only inside `region`, over the frame kept from
    /// the last one, as the software renderer's `replayDamage` does; a
    /// transparent frame's damage is cleared first. A whole region draws
    /// the frame as `replayBuffer` does.
    pub fn replayDamage(self: *Renderer, buffer: *const commands.Buffer, region: *const damage.Damage, transparent: bool) !void {
        if (!self.active) return error.NotDrawing;
        const native = self.native.?;
        if (region.full) return self.replayBuffer(buffer);
        zmtl_set_partial(native, 1);
        for (region.slice()) |box| {
            zmtl_push_device_clip(native, box.x0, box.y0, box.x1, box.y1);
            defer zmtl_pop_clip(native);
            if (transparent) zmtl_clear_box(native, box.x0, box.y0, box.x1, box.y1);
            try self.replayBuffer(buffer);
        }
    }
    pub fn replay(self: *Renderer, ops: []const commands.Command, text: []const u8) !void {
        try self.replayWithResources(ops, text, &.{}, &.{}, &.{}, &.{});
    }
    pub fn replayWithResources(self: *Renderer, ops: []const commands.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView) !void {
        try self.replayAll(ops, text, resources, prepared, image_resources, coverage_resources, &.{}, &.{}, &.{});
    }
    fn groupDescriptor(self: *Renderer, bounds: drawing.Rect, options: layers.Group) !layers.NativeGroup {
        try layers.validateGroup(bounds, options, zmtl_scale(self.native.?));
        var descriptor: layers.NativeGroup = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height, .opacity = options.opacity };
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
    fn beginGroup(self: *Renderer, value: commands.GroupCommand, coverage_resources: []const drawing.CoverageView, filters: []const gaussian.View) !void {
        const native = self.native.?;
        const r = value.bounds;
        const bounds: drawing.Rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
        const descriptor = try self.groupDescriptor(bounds, try commands.groupOptions(value, coverage_resources));
        const kernel: ?*const gaussian.arithmetic.Kernel = if (value.filter_slot == commands.no_filter) null else kernel: {
            if (value.filter_slot >= filters.len) return error.MissingResources;
            const view = filters[value.filter_slot];
            try view.validate();
            break :kernel if (view.descriptor.radius == 0) null else view.descriptor;
        };
        const status = if (kernel) |filter| status: {
            if (filter.scale != zmtl_scale(native)) return error.GaussianDpiMismatch;
            const capture = try gaussian_scope.Capture.init(bounds, filter);
            break :status zmtl_begin_gaussian(native, &descriptor, capture.left, capture.top, capture.width, capture.height, capture.radius, &filter.weights);
        } else zmtl_begin_group(native, &descriptor);
        switch (status) {
            0 => {},
            1 => return error.LayerDepthExceeded,
            else => return error.GraphicsFailed,
        }
    }
    fn beginTransform(self: *Renderer, value: layers.NativeTransform) !void {
        try value.validate(zmtl_scale(self.native.?));
        switch (zmtl_begin_transform(self.native.?, value.pixel_width, value.pixel_height, value.source_width, value.source_height)) {
            0 => {},
            1 => return error.LayerDepthExceeded,
            else => return error.GraphicsFailed,
        }
    }
    /// Samples the transform's source back into its parent over the device
    /// pixels its guarded source covers there, as the software renderer's
    /// transform composite does.
    fn endTransform(self: *Renderer, value: layers.NativeTransform) !void {
        const native = self.native.?;
        const scale: f64 = zmtl_scale(native);
        const to_parent = value.matrix();
        const inverse = try to_parent.inverse();
        const padded = try to_parent.mapBounds(.{ .x = -1 / scale, .y = -1 / scale, .width = @as(f64, @floatFromInt(value.pixel_width + 2)) / scale, .height = @as(f64, @floatFromInt(value.pixel_height + 2)) / scale });
        const bounds = [4]f32{ @floatCast(@floor(padded.x * scale)), @floatCast(@floor(padded.y * scale)), @floatCast(@ceil((padded.x + padded.width) * scale)), @floatCast(@ceil((padded.y + padded.height) * scale)) };
        const matrix = [6]f64{ inverse.xx, inverse.yx, inverse.xy, inverse.yy, inverse.x0, inverse.y0 };
        if (zmtl_end_transform(native, &matrix, &bounds) != 0) return error.GraphicsFailed;
    }
    /// Every texture a frame draws is checked before anything draws: one of
    /// another domain, or lost, fails the whole frame.
    fn preflightTextures(self: *Renderer, ops: []const commands.Command, textures: []const drawing.TextureView) !void {
        for (ops) |op| if (op == .texture) {
            const value = op.texture;
            if (value.resource >= textures.len) return error.MissingResources;
            const view = textures[value.resource];
            try view.validate();
            const borrow = self.domain_borrow orelse return error.TextureDomainRequired;
            if (view.domain != borrow.epoch) return error.TextureDomainMismatch;
            _ = try drawing.planTexture(view, .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, value.options(), zmtl_scale(self.native.?));
        };
    }
    /// The masked clips open while a list replays: each drawing inside is
    /// masked by itself, as the software planes do (`mask_mix`). Drawings
    /// that do not overlap gather into one run drawn in a group masked by
    /// each clip of their layer; a group, transform or effect is one
    /// drawing of the layer it composites onto.
    const MaskRuns = struct {
        const Scope = struct { clip: commands.MaskClip, level: usize };
        scopes: [32]Scope = undefined,
        len: usize = 0,
        /// Groups open for the run now; 0 while none is.
        groups: usize = 0,
        boxes: [32]damage.Box = undefined,
        box_len: usize = 0,
        whole: bool = false,
        /// The mask groups opened beneath each open layer, by its level.
        spans: [max_capture_depth + 2]usize = @splat(0),

        fn masked(self: *const MaskRuns, level: usize) bool {
            for (self.scopes[0..self.len]) |scope| if (scope.level == level) return true;
            return false;
        }
        fn openGroups(self: *MaskRuns, r: *Renderer, level: usize, coverage_resources: []const drawing.CoverageView, filters: []const gaussian.View) !usize {
            var count: usize = 0;
            for (self.scopes[0..self.len]) |scope| if (scope.level == level) {
                try r.beginGroup(.{ .bounds = scope.clip.bounds, .mask_origin = scope.clip.origin, .mask_resource = scope.clip.mask }, coverage_resources, filters);
                count += 1;
            };
            return count;
        }
        fn closeGroups(native: *anyopaque, count: usize) !void {
            for (0..count) |_| if (zmtl_end_group(native) != 0) return error.GraphicsFailed;
        }
        fn flush(self: *MaskRuns, r: *Renderer) !void {
            const count = self.groups;
            self.groups = 0;
            self.box_len = 0;
            self.whole = false;
            try closeGroups(r.native.?, count);
        }
        fn draw(self: *MaskRuns, r: *Renderer, level: usize, box: ?damage.Box, coverage_resources: []const drawing.CoverageView, filters: []const gaussian.View) !void {
            if (!self.masked(level)) return;
            if (self.groups != 0) {
                var overlap = self.whole or box == null or self.box_len == self.boxes.len;
                if (!overlap) for (self.boxes[0..self.box_len]) |kept| if (kept.intersects(box.?)) {
                    overlap = true;
                    break;
                };
                if (overlap) try self.flush(r);
            }
            if (self.groups == 0) self.groups = try self.openGroups(r, level, coverage_resources, filters);
            if (box) |b| {
                self.boxes[self.box_len] = b;
                self.box_len += 1;
            } else self.whole = true;
        }
        fn beginSpan(self: *MaskRuns, r: *Renderer, level: usize, coverage_resources: []const drawing.CoverageView, filters: []const gaussian.View) !void {
            try self.flush(r);
            if (level + 1 >= self.spans.len) return error.LayerDepthExceeded;
            self.spans[level + 1] = if (self.masked(level)) try self.openGroups(r, level, coverage_resources, filters) else 0;
        }
        /// After the layer at `level` + 1 ended.
        fn endSpan(self: *MaskRuns, r: *Renderer, level: usize) !void {
            if (level + 1 >= self.spans.len) return;
            const count = self.spans[level + 1];
            self.spans[level + 1] = 0;
            try closeGroups(r.native.?, count);
        }
    };
    fn replayAll(self: *Renderer, ops: []const commands.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView, transforms: []const layers.NativeTransform, filters: []const gaussian.View) !void {
        if (!self.active) return error.NotDrawing;
        const native = self.native.?;
        try self.preflightTextures(ops, textures);
        if (resources.len > commands.brushes.max_brushes) return error.BrushesFull;
        for (resources) |*resource| try resource.validate();
        var depth: usize = 0;
        defer while (depth != 0) : (depth -= 1) zmtl_pop_clip(native);
        // The clips open that are masked, a bit for each depth.
        var masked: u32 = 0;
        var runs: MaskRuns = .{};
        const box_sources: damage.Sources = .{ .prepared = prepared, .coverage = coverage_resources, .indicators = if (self.effect_buffer) |buffer| buffer.indicator_storage[0..buffer.indicator_len] else &.{} };
        const box_scale = zmtl_scale(native);
        var effect_stack: [max_capture_depth]OpenEffect = undefined;
        var effect_depth: usize = 0;
        var transform_stack: [max_capture_depth]layers.NativeTransform = undefined;
        var transform_depth: usize = 0;
        var group_depth: usize = 0;
        var words: [shader_effects.shader.gpu.max_input_words]u32 = undefined;
        for (ops) |op| {
            const level = group_depth + transform_depth + effect_depth;
            if (runs.len != 0) switch (op) {
                .fill, .shape, .gradient, .text, .prepared_text, .coverage, .image, .indicator, .texture => try runs.draw(self, level, damage.commandBox(op, box_sources, box_scale), coverage_resources, filters),
                .backdrop, .backdrop_shader => {
                    try runs.flush(self);
                    try runs.draw(self, level, null, coverage_resources, filters);
                },
                .push_clip, .push_mask_clip, .pop_clip, .end_group, .end_transform, .end_effect => try runs.flush(self),
                .begin_group, .begin_transform, .effect => try runs.beginSpan(self, level, coverage_resources, filters),
            };
            try self.replayOne(op, text, resources, prepared, image_resources, coverage_resources, textures, transforms, filters, &runs, &depth, &masked, &effect_stack, &effect_depth, &transform_stack, &transform_depth, &group_depth, &words);
        }
        try runs.flush(self);
        if (depth != 0) return error.UnbalancedClips;
        if (effect_depth != 0) return error.UnbalancedEffects;
        if (group_depth != 0) return error.UnbalancedGroups;
        if (transform_depth != 0) return error.UnbalancedTransforms;
    }
    fn replayOne(self: *Renderer, op: commands.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView, transforms: []const layers.NativeTransform, filters: []const gaussian.View, runs: *MaskRuns, depth_ptr: *usize, masked_ptr: *u32, effect_stack: *[max_capture_depth]OpenEffect, effect_depth_ptr: *usize, transform_stack: *[max_capture_depth]layers.NativeTransform, transform_depth_ptr: *usize, group_depth_ptr: *usize, words: *[shader_effects.shader.gpu.max_input_words]u32) !void {
        const native = self.native.?;
        var depth = depth_ptr.*;
        var masked = masked_ptr.*;
        var effect_depth = effect_depth_ptr.*;
        var transform_depth = transform_depth_ptr.*;
        var group_depth = group_depth_ptr.*;
        defer {
            depth_ptr.* = depth;
            masked_ptr.* = masked;
            effect_depth_ptr.* = effect_depth;
            transform_depth_ptr.* = transform_depth;
            group_depth_ptr.* = group_depth;
        }
        switch (op) {
            .fill => |fill| {
                if (!layout.validRect(fill.bounds)) return error.InvalidGeometry;
                const r = fill.bounds;
                zmtl_fill(native, r.x, r.y, r.width, r.height, fill.color);
            },
            .shape => |value| {
                const p = try geometry.plan(value);
                if (zmtl_shape(native, p.bounds.x, p.bounds.y, p.bounds.width, p.bounds.height, p.radius, p.stroke_width, p.color.rgba()) != 0) return error.DrawShapeFailed;
            },
            .gradient => |value| {
                if (value.brush >= resources.len) return error.MissingResources;
                const p = try geometry.plan(.{ .bounds = value.bounds, .radius = value.radius, .stroke_width = value.stroke_width, .color = geometry.Color.rgb(0) });
                const brush = &resources[value.brush];
                if (brush.isTransparent()) return;
                const descriptor = brush.native();
                const spread: u32 = switch (brush.spread) {
                    .pad => 0,
                    .repeat => 1,
                    .reflect => 2,
                };
                const space: u32 = switch (brush.interpolation) {
                    .srgb => 0,
                    .srgb_linear => 1,
                    .oklab => 2,
                };
                if (zmtl_gradient(native, p.bounds.x, p.bounds.y, p.bounds.width, p.bounds.height, p.radius, p.stroke_width, &descriptor, spread, space) != 0) return error.DrawGradientFailed;
            },
            .text => |value| {
                if (!layout.validRect(value.bounds)) return error.InvalidGeometry;
                if (value.offset > text.len or value.len > text.len - value.offset) return error.InvalidTextRange;
                const bytes = text[value.offset..][0..value.len];
                if (bytes.len > 64 * 1024) return error.TextTooLong;
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
                const r = value.bounds;
                const font = value.font;
                if (zmtl_text(native, r.x, r.y, r.width, r.height, bytes.ptr, @intCast(bytes.len), value.color, font.size(), font.weight.value(), @intFromBool(font.italic), @intFromBool(font.monospace), if (font.family == 0) null else fonts.systemName(font.family).ptr) != 0) return error.DrawTextFailed;
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
                try self.image(image_resources[value.resource], value.destination, value.options());
            },
            .push_clip => |r| {
                if (!layout.validRect(r)) return error.InvalidGeometry;
                if (depth == 32) return error.ClipStackFull;
                depth += 1;
                zmtl_push_clip(native, r.x, r.y, r.width, r.height);
            },
            .push_mask_clip => |value| {
                const r = value.bounds;
                if (!layout.validRect(r)) return error.InvalidGeometry;
                if (depth == 32) return error.ClipStackFull;
                if (value.mask >= coverage_resources.len) return error.MissingResources;
                if (runs.len == runs.scopes.len) return error.ClipStackFull;
                zmtl_push_clip(native, r.x, r.y, r.width, r.height);
                masked |= @as(u32, 1) << @intCast(depth);
                depth += 1;
                runs.scopes[runs.len] = .{ .clip = value, .level = group_depth + transform_depth + effect_depth };
                runs.len += 1;
            },
            .pop_clip => {
                if (depth == 0) return error.ClipStackEmpty;
                depth -= 1;
                if (masked & (@as(u32, 1) << @intCast(depth)) != 0) {
                    masked &= ~(@as(u32, 1) << @intCast(depth));
                    if (runs.len == 0) return error.ClipStackEmpty;
                    runs.len -= 1;
                }
                zmtl_pop_clip(native);
            },
            .effect => |slot| {
                if (self.effect_buffer == null) return error.SoftwareOnlyCommands;
                if (effect_depth == effect_stack.len) return error.LayerDepthExceeded;
                effect_stack[effect_depth] = try self.beginEffect(slot);
                effect_depth += 1;
            },
            .end_effect => {
                if (effect_depth == 0) return error.UnbalancedEffects;
                effect_depth -= 1;
                try self.endEffect(effect_stack[effect_depth], words);
                try runs.endSpan(self, group_depth + transform_depth + effect_depth);
            },
            .backdrop_shader => |slot| {
                if (self.effect_buffer == null) return error.SoftwareOnlyCommands;
                try self.backdropShader(slot, words);
            },
            .backdrop => |slot| {
                const buffer = self.effect_buffer orelse return error.SoftwareOnlyCommands;
                if (slot >= buffer.backdrop_storage.len) return error.MissingResources;
                try self.backdropEffect(buffer.backdrop_storage.entries[slot], buffer.backdrop_storage.workspace);
            },
            .indicator => |slot| {
                const buffer = self.effect_buffer orelse return error.SoftwareOnlyCommands;
                if (slot >= buffer.indicator_len) return error.MissingResources;
                try self.indicator(buffer.indicator_storage[slot]);
            },
            .begin_group => |value| {
                try self.beginGroup(value, coverage_resources, filters);
                group_depth += 1;
            },
            .end_group => {
                if (group_depth == 0) return error.GroupStackEmpty;
                group_depth -= 1;
                if (zmtl_end_group(native) != 0) return error.GraphicsFailed;
                try runs.endSpan(self, group_depth + transform_depth + effect_depth);
            },
            .begin_transform => |slot| {
                if (slot >= transforms.len) return error.MissingResources;
                if (transform_depth == transform_stack.len) return error.LayerDepthExceeded;
                try self.beginTransform(transforms[slot]);
                transform_stack[transform_depth] = transforms[slot];
                transform_depth += 1;
            },
            .end_transform => {
                if (transform_depth == 0) return error.TransformStackEmpty;
                transform_depth -= 1;
                try self.endTransform(transform_stack[transform_depth]);
                try runs.endSpan(self, group_depth + transform_depth + effect_depth);
            },
            .texture => |value| {
                const view = textures[value.resource];
                const plan = try drawing.planTexture(view, .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, value.options(), zmtl_scale(native));
                if (plan.destination.width == 0 or plan.destination.height == 0 or plan.opacity == 0) return;
                if (zmtl_texture(native, view.token, &plan) != 0) return error.DrawTextureFailed;
            },
        }
    }
    pub fn preparedText(self: *Renderer, view: drawing.PreparedTextView, origin: drawing.Point, tint: geometry.Color) !void {
        if (!self.active) return error.NotDrawing;
        try view.validate();
        // macOS prepares text for the software renderer's ABI.
        if (view.platform != .linux) return error.PreparedPlatformMismatch;
        const key = view.native_coverage orelse return error.PreparedPlatformMismatch;
        if (zmtl_scale(self.native.?) != view.coverage.scale) return error.PreparedDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        const c = view.coverage;
        const descriptor: drawing.NativeCoverage = .{ .pixels = c.pixels.ptr, .byte_len = @as(usize, c.stride) * c.height, .width = c.width, .height = c.height, .stride = c.stride, .origin_x = c.origin_x, .origin_y = c.origin_y, .scale = c.scale };
        if (zmtl_prepared(self.native.?, key, &descriptor, origin.x, origin.y, if (view.clip) |*r| r else null, tint.rgba()) != 0) return error.DrawPreparedTextFailed;
    }

    pub fn uploadCoverage(self: *Renderer, view: drawing.CoverageView) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        // A domain's device must be there, and the renderer's its own.
        const scope = try self.enterDomain();
        defer self.leaveDomain(scope);
        try view.validate();
        self.images.coverage_stats.upload_requests +%= 1;
        if (self.images.find(view.identity) != null) return error.RasterIdentityConflict;
        if (self.images.findCoverage(view.identity)) |slot| {
            self.images.touch(slot);
            return;
        }
        const charge = @as(usize, view.coverage.width + 2) * (view.coverage.height + 2);
        if (charge > self.images.stats.budget_bytes) return error.CoverageBudgetExceeded;
        try self.reserveSlot();
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        self.images.reserveCandidate(charge);
        self.images.coverage_stats.peak_reserved_bytes = @max(self.images.coverage_stats.peak_reserved_bytes, self.images.coverage_stats.pixel_bytes + charge);
        const descriptor = view.native();
        if (zmtl_prepare_coverage(native, &descriptor) != 0) return error.CoverageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.victim() orelse break, true);
        const slot = self.images.empty().?;
        zmtl_commit_image(native, @intCast(slot));
        self.images.commitCoverage(slot, view, charge);
    }
    pub fn releaseCoverage(self: *Renderer, identity: u64) !bool {
        if (self.active) return error.AlreadyDrawing;
        const slot = self.images.findCoverage(identity) orelse return false;
        try self.images.coverage_entries[slot].?.view.lease.checkOwner();
        self.dropImage(slot, false);
        return true;
    }
    pub fn coverage(self: *Renderer, view: drawing.CoverageView, origin: drawing.Point, tint: geometry.Color) !void {
        if (!self.active) return error.NotDrawing;
        try view.validate();
        const native = self.native orelse return error.NoSurface;
        if (zmtl_scale(native) != view.coverage.scale) return error.CoverageDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        const slot = try self.images.lookupCoverage(view.identity);
        const x = @as(f64, origin.x) + @as(f64, @floatFromInt(view.coverage.origin_x)) / view.coverage.scale;
        const y = @as(f64, origin.y) + @as(f64, @floatFromInt(view.coverage.origin_y)) / view.coverage.scale;
        if (@abs(x) > std.math.floatMax(f32) or @abs(y) > std.math.floatMax(f32)) return error.InvalidGeometry;
        if (zmtl_coverage(native, @intCast(slot), @floatCast(x), @floatCast(y), tint.rgba()) != 0) return error.DrawCoverageFailed;
    }
    pub fn coverageStats(self: *const Renderer) drawing.CoverageStats {
        return self.images.coverage_stats;
    }
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
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        // A domain's device must be there, and the renderer's its own.
        const scope = try self.enterDomain();
        defer self.leaveDomain(scope);
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
        try self.reserveSlot();
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        self.images.stats.peak_reserved_bytes = @max(self.images.stats.peak_reserved_bytes, self.images.stats.pixel_bytes + charge);
        self.images.reserveCandidate(charge);
        if (zmtl_prepare_image(native, view.levels.ptr, @intCast(view.levels.len)) != 0) return error.ImageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.victim() orelse break, true);
        const slot = self.images.empty().?;
        zmtl_commit_image(native, @intCast(slot));
        self.images.commitCharged(slot, view, dynamic, charge);
    }
    pub fn updateImage(self: *Renderer, old_identity: u64, view: drawing.ImageView) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        // A domain's device must be there, and the renderer's its own.
        const scope = try self.enterDomain();
        defer self.leaveDomain(scope);
        const slot = try self.images.updateSlot(old_identity, view);
        if (self.images.entries[slot].?.view.identity == view.identity) return;
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        if (zmtl_update_image(native, @intCast(slot), view.levels.ptr, @intCast(view.levels.len)) != 0) return error.ImageUpdateFailed;
        self.images.replace(slot, view);
    }
    fn dropImage(self: *Renderer, slot: usize, eviction: bool) void {
        zmtl_release_image(self.native.?, @intCast(slot));
        self.images.drop(slot, eviction);
    }
    fn reserveSlot(self: *Renderer) !void {
        if (self.images.empty() != null) return;
        if (self.images.nextCapacity()) |capacity| {
            if (zmtl_reserve_images(self.native.?, @intCast(capacity)) == 0) {
                if (self.images.grow(capacity)) return else |_| {}
            }
        } else |_| {}
        self.dropImage(self.images.victim() orelse return error.ImageSlotsFull, true);
    }
    /// Whether every image and coverage mask a frame draws is uploaded; a
    /// frame missing one draws in software and `residentFrame` uploads them.
    pub fn holdsFrame(self: *const Renderer, buffer: *const commands.Buffer) bool {
        // What was uploaded with a lost device is gone.
        if (self.domain_borrow) |borrow| if (borrow.epoch.generation != self.device_generation) return false;
        for (buffer.imageResources()) |view| if (self.images.find(view.identity) == null) return false;
        for (buffer.coverageResources()) |view| if (self.images.findCoverage(view.identity) == null) return false;
        return true;
    }
    pub fn residentFrame(self: *Renderer, buffer: *const commands.Buffer) !void {
        const scope = try self.enterDomain();
        defer self.leaveDomain(scope);
        self.images.beginFrame();
        defer self.images.endFrame();
        for (buffer.imageResources()) |view| if (self.images.find(view.identity)) |slot| self.images.touch(slot);
        for (buffer.coverageResources()) |view| if (self.images.findCoverage(view.identity)) |slot| self.images.touch(slot);
        for (buffer.imageResources()) |view| if (self.images.find(view.identity) == null) try self.uploadImage(view);
        for (buffer.coverageResources()) |view| if (self.images.findCoverage(view.identity) == null) try self.uploadCoverage(view);
    }
    pub fn releaseImage(self: *Renderer, identity: u64) !bool {
        if (self.active) return error.AlreadyDrawing;
        const slot = self.images.find(identity) orelse return false;
        try self.images.entries[slot].?.view.lease.checkOwner();
        self.dropImage(slot, false);
        return true;
    }
    pub fn setImageBudget(self: *Renderer, bytes: usize) !void {
        if (self.active) return error.AlreadyDrawing;
        if (bytes == 0 or bytes > drawing.max_image_budget) return error.InvalidImageBudget;
        try self.images.checkOwners();
        self.images.stats.budget_bytes = bytes;
        while (self.images.totalBytes() > bytes) self.dropImage(self.images.oldest().?, true);
    }
    pub fn imageStats(self: *const Renderer) drawing.ImageStats {
        return self.images.stats;
    }
    pub fn image(self: *Renderer, view: drawing.ImageView, destination: layout.Rect, options: drawing.ImageOptions) !void {
        if (!self.active) return error.NotDrawing;
        const plan = try drawing.planImage(view, .{ .x = destination.x, .y = destination.y, .width = destination.width, .height = destination.height }, options, zmtl_scale(self.native.?));
        if (plan.destination.width == 0 or plan.destination.height == 0 or plan.opacity == 0) return;
        const slot = try self.images.lookup(view.identity);
        if (zmtl_image(self.native.?, @intCast(slot), &plan) != 0) return error.DrawImageFailed;
    }

    /// Groups and transforms capture into textures of their frame: Metal
    /// prepares no layer planes of its own.
    pub fn layerStats(_: *const Renderer) layers.Stats {
        return .{};
    }
    pub fn stats(self: *const Renderer) Stats {
        const native = self.native orelse return .{};
        var values: NativeStats = undefined;
        zmtl_stats(native, &values);
        var result: Stats = undefined;
        inline for (zio.fields(Stats)) |field| @field(result, field.name) = @field(values, field.name);
        return result;
    }

    /// Displays the view of the window titled `title` now, as AppKit's
    /// display cycle would.
    pub fn displayForTest(title: [*:0]const u8) void {
        zmtl_test_display(title);
    }
    /// Keep a copy of each frame presented, for `pixelForTest`.
    pub fn captureForTest(self: *Renderer, enable: bool) void {
        if (self.native) |native| zmtl_test_capture(native, @intFromBool(enable));
    }
    /// 0xAARRGGBB (premultiplied) of the last frame presented while capturing.
    pub fn pixelForTest(self: *Renderer, x: u32, y: u32) u32 {
        return zmtl_test_pixel(self.native.?, x, y);
    }
    /// The whole last frame presented while capturing, `width` x `height`.
    pub fn pixelsForTest(self: *Renderer, pixels: []u32, width: u32, height: u32) !void {
        if (pixels.len != @as(usize, width) * height or zmtl_test_pixels(self.native.?, pixels.ptr, width, height) == 0) return error.InvalidGeometry;
    }
    pub fn layerShownForTest(self: *Renderer) bool {
        return zmtl_test_layer_shown(self.native.?) != 0;
    }
    pub fn layerUnderSubviewsForTest(self: *Renderer) bool {
        return zmtl_test_layer_under_subviews(self.native.?) != 0;
    }
    pub fn layerContentsFlippedForTest(self: *Renderer) c_int {
        return zmtl_test_layer_flipped(self.native.?);
    }
    pub fn atlasLevelsForTest(self: *Renderer) u32 {
        return zmtl_test_atlas_levels(self.native.?);
    }
};
