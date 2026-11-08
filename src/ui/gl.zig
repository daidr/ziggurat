//! The Linux GPU renderer: replays a frame's commands with OpenGL 3.3
//! (src/ui/gl_renderer.c). Browsers draw with it on a canvas's WebGL2
//! (src/ui/gl_web.h, web/ziggurat.js), and fall back to the software
//! renderer where a page has none; a context the browser restores after a
//! loss makes the renderer upload its images again.
//!
//! A window's frames are drawn as GtkGLArea draws its own: with a GDK
//! OpenGL context of the window's drawing area, into a framebuffer the
//! renderer keeps, shown with `gdk_cairo_draw_from_gl` in the area's draw
//! signal. A window draws with OpenGL only where it runs on a GPU (a
//! context GDK makes for a hidden window of its own says, once per
//! process); on a software rasterizer such as llvmpipe its frames are drawn
//! in memory, by the software renderer, unless `Options.allow_software`
//! (`ZIGGURAT_GL=on`, or `RenderMode.warp`) asks for OpenGL there too.
//!
//! It draws fills, rounded shapes and strokes, gradients (linear, radial
//! and conic, padded, repeated or reflected, mixed in sRGB, linear sRGB or
//! Oklab), text (laid out and drawn with Pango as the software renderer
//! draws it, kept in a texture for later frames), prepared text, coverage
//! masks, images, clips, masked clips (each drawing masked by itself, as
//! the software planes mix them), opacities (each drawing faded by itself),
//! groups (at an opacity, through a mask, or filtered with a Gaussian
//! kernel), raster transforms, shader effects (element effects over a
//! capture of their content and backdrop shaders over a copy of the target,
//! with programs translated to GLSL and linked outside paint by
//! `prepareEffect`), backdrop effects (blur, glass and scroll edges,
//! filtered from a copy of the target as the software planes filter it) and
//! loading indicators (their scenes evaluated per pixel). Groups,
//! transforms and effects capture their content in textures of the frame
//! as the software planes do; their limits are the software renderer's
//! plan, which `Context` checks each frame against. A frame that uses
//! anything else (a shader program not prepared, GPU textures without a
//! device domain) draws on the software plane instead, as `prepareEffects`
//! tells; so does a frame drawing an image or mask not yet uploaded, or a
//! program not yet linked (`holdsFrame`), which `residentFrame` uploads and
//! links for the next: a window's renderer has its context from its first
//! frame on.
//!
//! The window's frame is kept between frames: `replayDamage` draws again
//! only the device pixels that changed (src/ui/damage.zig).
//!
//! A renderer made in a device domain (`Options.domain`,
//! src/ui/gpu_resources.zig) draws with the domain's surfaceless EGL
//! context, and draws the domain's GPU textures (`Frame.texture`); its
//! window frames are read back into memory and painted with cairo. When the
//! domain loses its device, the renderer's objects go with it; after
//! `DeviceDomain.recreate` the next frame or upload takes the new one, and
//! images and masks are uploaded again as frames draw them.
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
const gaussian = @import("gaussian_filter.zig");
const damage = @import("damage.zig");
const effect_host = @import("gpu_effect_host.zig");
const shader_effects = commands.shader_effects;
const backdrop = commands.backdrop;
const loading = commands.loading;

extern fn zglr_create(c_int) ?*anyopaque;
extern fn zglr_create_own(c_int, *c_int) ?*anyopaque;
extern fn zglr_create_in_domain(*anyopaque, *c_int) ?*anyopaque;
extern fn zglr_ready(*anyopaque) c_int;
extern fn zglr_software(*anyopaque) c_int;
extern fn zglr_rebuild(*anyopaque) c_int;
extern fn zglr_offscreen_prepare(*anyopaque, u32, u32) c_int;
extern fn zglr_texture(*anyopaque, *const drawing.GpuTextureToken, *const drawing.ImagePlan) c_int;
extern fn zglr_inject_loss(*anyopaque) void;
extern fn zglr_offscreen_commit(*anyopaque) void;
extern fn zglr_offscreen_objects(*anyopaque) u32;
extern fn zglr_read_front(*anyopaque, [*]u32, u32, u32) c_int;
extern fn zglr_destroy(?*anyopaque) void;
extern fn zglr_live_objects() u32;
extern fn zglr_probe() c_int;
extern fn zglr_restored(*anyopaque) c_int;
extern fn zglr_probe_renderer() [*:0]const u8;
extern fn zglr_begin(*anyopaque, ?*anyopaque, u32, u32, f32, c_int) c_int;
extern fn zglr_begin_offscreen(*anyopaque, u32, u32, f32, c_int) c_int;
extern fn zglr_scale(*anyopaque) f32;
extern fn zglr_fill(*anyopaque, f32, f32, f32, f32, u32) void;
extern fn zglr_shape(*anyopaque, f32, f32, f32, f32, f32, f32, u32) c_int;
extern fn zglr_gradient(*anyopaque, f32, f32, f32, f32, f32, f32, *const commands.brushes.Native, u32, u32) c_int;
extern fn zglr_begin_group(*anyopaque, *const layers.NativeGroup) c_int;
extern fn zglr_begin_gaussian(*anyopaque, *const layers.NativeGroup, i32, i32, u32, u32, u32, *const [gaussian.arithmetic.capacity]u32) c_int;
extern fn zglr_end_group(*anyopaque) c_int;
extern fn zglr_begin_transform(*anyopaque, u32, u32, f32, f32) c_int;
extern fn zglr_end_transform(*anyopaque, *const [6]f64, *const [4]f32) c_int;
extern fn zglr_plane(*anyopaque, *u64) c_int;
extern fn zglr_set_partial(*anyopaque, c_int) void;
extern fn zglr_clear_box(*anyopaque, i32, i32, i32, i32) void;
extern fn zglr_push_device_clip(*anyopaque, i32, i32, i32, i32) void;
extern fn zglr_forget_plane(*anyopaque) void;
extern fn zglr_push_clip(*anyopaque, f32, f32, f32, f32) void;
extern fn zglr_pop_clip(*anyopaque) void;
extern fn zglr_push_opacity(*anyopaque, u32) void;
extern fn zglr_pop_opacity(*anyopaque) void;
extern fn zglr_effect_install(*anyopaque, u32, [*]const u8, usize) c_int;
extern fn zglr_effect_installed(*anyopaque, u32) c_int;
extern fn zglr_effect_ready(*anyopaque) c_int;
extern fn zglr_effect_geometry(*anyopaque, *EffectGeometry) c_int;
extern fn zglr_begin_effect(*anyopaque, i32, i32, u32, u32, u32) c_int;
extern fn zglr_end_effect(*anyopaque, ?*const EffectPass, u32) c_int;
extern fn zglr_backdrop_shader(*anyopaque, *const EffectPass, *const [4]u32, *const [4]u32) c_int;
extern fn zglr_backdrop(*anyopaque, *const Glass, u32, [*]const GlassLevel, [*]const f32, u32) c_int;
extern fn zglr_indicator(*anyopaque, [*]const f32, u32, f32, f32, f32, *const [4]i32, u32, f32) c_int;
extern fn zglr_text(*anyopaque, f32, f32, f32, f32, [*]const u8, u32, u32, f32, u16, c_int, c_int, ?[*:0]const u8, f32) c_int;
extern fn zglr_text_stats(*anyopaque, *u32, *u64, *u64) void;
extern fn zglr_prepared(*anyopaque, *anyopaque, *const drawing.NativeCoverage, f32, f32, ?*const drawing.Rect, u32) c_int;
extern fn zglr_forget_prepared(*anyopaque) void;
extern fn zglr_reserve_images(*anyopaque, u32) c_int;
extern fn zglr_prepare_image(*anyopaque, [*]const drawing.ImageLevel, u32) c_int;
extern fn zglr_prepare_coverage(*anyopaque, *const drawing.NativeCoverage) c_int;
extern fn zglr_commit_image(*anyopaque, u32) void;
extern fn zglr_release_image(*anyopaque, u32) void;
extern fn zglr_update_image(*anyopaque, u32, [*]const drawing.ImageLevel, u32) c_int;
extern fn zglr_takes_video(*const drawing.VideoPicture) c_int;
extern fn zglr_prepare_video(*anyopaque, *const drawing.VideoPicture) c_int;
extern fn zglr_update_video(*anyopaque, u32, *const drawing.VideoPicture) c_int;
extern fn zglr_coverage(*anyopaque, u32, f32, f32, u32) c_int;
extern fn zglr_image(*anyopaque, u32, *const drawing.ImagePlan) c_int;
extern fn zglr_end(*anyopaque, ?*anyopaque) c_int;
extern fn zglr_end_offscreen(*anyopaque, ?[*]u8, usize) c_int;
extern fn zglr_abort(*anyopaque) void;
extern fn zglr_stats(*anyopaque, *NativeStats) void;
extern fn zglr_suspend(*anyopaque) c_int;
extern fn zglr_test_shown(*anyopaque) c_int;
extern fn zglr_test_display([*:0]const u8) void;
extern fn zglr_test_capture(*anyopaque, c_int) void;
extern fn zglr_test_pixel(*anyopaque, u32, u32) u32;
extern fn zglr_test_pixels(*anyopaque, [*]u32, u32, u32) c_int;
extern fn zglr_test_backend(*anyopaque) c_int;
extern fn zglr_test_damage(*[4]i32) u64;

const NativeStats = extern struct { device_creations: u32, context_creations: u32, resizes: u32, presents: u32, memory_presents: u32, busy_presents: u32, text_rasters: u32, text_entries: u32, frames: u64, instances: u64, batches: u64, layers: u64, filter_passes: u64, partial_frames: u64, text_hits: u64, offscreen_targets: u64, device_losses: u64, damage_submissions: u64, effect_passes: u64, backdrops: u64, indicators: u64, sweeps: u64 };
/// A backdrop effect's plan for src/ui/gl_renderer.c (ZlGlass).
const Glass = extern struct { box: [4]f32, clip: [4]f32, tone: [4]f32, tint: [4]f32, line: [4]f32, line2: [4]f32, misc: [4]f32, misc2: [4]f32, background: [4]f32, fill: [4]f32, region: [4]u32, out: [4]u32 };
const GlassLevel = extern struct { radius: u32, lo: f32, hi: f32, weights: u32 };
const kernel_len = 2 * backdrop.max_radius_pixels + 1;
const EffectPass = extern struct { words: [*]const u32, word_count: u32, slot: u32, params: effect_host.Params };
const EffectGeometry = extern struct { clip: [4]f64, scale: f32, origin: [2]f32, width: u32, height: u32, transparent: u32 };

/// Captures (groups, transforms and element effects) nested in one another
/// at most, as src/ui/gl_renderer.c holds them.
const max_capture_depth = 8;
/// Largest texture side a capture may have.
const max_texture = 16384;

pub const Driver = enum { hardware, warp };
pub const Options = struct {
    /// `warp` draws with OpenGL on a software rasterizer too (llvmpipe), as
    /// Direct3D's WARP device draws on the CPU.
    driver: Driver = .hardware,
    /// Draw with OpenGL wherever GDK makes a context, on a software
    /// rasterizer too; `ZIGGURAT_GL=on` asks the same of every window.
    allow_software: bool = false,
    /// Draw offscreen frames alone, with an EGL context of the renderer's
    /// own made now; a window renderer makes its context at its first frame.
    own_context: bool = false,
    /// Draw with this domain's context, and its textures.
    domain: ?*gpu_resources.DeviceDomain = null,
    /// Revoked by the domain when it loses its device; OpenGL frames never
    /// wait on a handle, so nothing is put in it.
    native_wait_slot: ?*?z.NativeWaitToken = null,
};
/// device_creations counts contexts made (and made again after a loss),
/// presents frames shown, memory_presents those read back and painted with
/// cairo (a domain's renderer), resizes framebuffers made again for a new
/// size, text_rasters texts drawn with Pango and text_hits those drawn
/// from the texture kept, layers groups and transforms composited,
/// filter_passes Gaussian filter passes, partial_frames frames that drew
/// only their damage, offscreen_targets offscreen targets made,
/// device_losses the devices this renderer lost with its domain,
/// damage_submissions what the toplevel added to the Wayland surface's
/// damage, effect_passes shader and backdrop passes run, backdrops backdrop
/// effects and indicators loading indicators drawn; sweeps the times the
/// renderer let go of texts no frame drew for a while and of pooled targets
/// no frame took (`gpu_sweep.h`).
pub const Stats = struct { device_creations: u32 = 0, context_creations: u32 = 0, resizes: u32 = 0, presents: u32 = 0, memory_presents: u32 = 0, busy_presents: u32 = 0, text_rasters: u32 = 0, text_entries: u32 = 0, frames: u64 = 0, instances: u64 = 0, batches: u64 = 0, layers: u64 = 0, filter_passes: u64 = 0, partial_frames: u64 = 0, text_hits: u64 = 0, offscreen_targets: u64 = 0, device_losses: u64 = 0, damage_submissions: u64 = 0, effect_passes: u64 = 0, backdrops: u64 = 0, indicators: u64 = 0, sweeps: u64 = 0 };

/// Renderers and device domains alive.
pub fn liveObjects() u32 {
    return zglr_live_objects();
}
/// As d3d11.globalResourceCount: the native objects alive, renderers and
/// device domains.
pub fn globalResourceCount() u32 {
    return zglr_live_objects();
}
/// Whether OpenGL contexts GDK makes draw on a GPU, asked once with a
/// context of a hidden window: `gpu`, a software rasterizer, or none.
pub const Probe = enum { gpu, software, unavailable };
pub fn probe() Probe {
    return switch (zglr_probe()) {
        1 => .gpu,
        0 => .software,
        else => .unavailable,
    };
}
/// The OpenGL renderer the probe found, empty before it ran or without one.
pub fn probeRenderer() []const u8 {
    return std.mem.span(zglr_probe_renderer());
}
/// The area the toplevel's draw signal last added to the Wayland surface's
/// damage (device-independent pixels of the surface: x0, y0, x1, y1), and
/// how many times it did; 0 off Wayland or below a scale of 2.
pub fn waylandDamageForTest(out: *[4]i32) u64 {
    return zglr_test_damage(out);
}

pub const Renderer = struct {
    native: ?*anyopaque = null,
    /// Kept for the shared failure report; OpenGL has no HRESULT.
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
    /// The cairo context of the area's draw signal the frame shows in.
    destination: ?*anyopaque = null,
    /// Shader programs linked or waiting for the renderer's context, the
    /// slot each of this frame's entries runs in, and the frame whose
    /// effects replay draws.
    effect_table: effect_host.Table = .{},
    effect_slots: [shader_effects.max_entries]u32 = undefined,
    effect_buffer: ?*const commands.Buffer = null,
    effect_slots_len: usize = 0,

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
            const native = zglr_create_in_domain(borrow.native, &failure) orelse {
                self.last_hresult = failure;
                return error.GraphicsInitializationFailed;
            };
            errdefer zglr_destroy(native);
            try domain.checkRendererReady();
            self.native = native;
            self.domain = domain;
            self.domain_borrow = borrow;
            self.device_generation = borrow.epoch.generation;
            return;
        }
        const allow: c_int = @intFromBool(options.allow_software or options.driver == .warp);
        if (options.own_context) {
            self.native = zglr_create_own(allow, &failure) orelse {
                self.last_hresult = failure;
                return error.GraphicsInitializationFailed;
            };
            return;
        }
        self.native = zglr_create(allow) orelse return error.GraphicsInitializationFailed;
    }
    /// For an offscreen surface (src/ui/gpu_offscreen_native.zig): success
    /// takes the surface's attachment; failure leaves it with the caller.
    pub fn initOffscreen(self: *Renderer, domain: *gpu_resources.DeviceDomain, borrow: gpu_resources.DeviceDomain.Borrow) !void {
        try domain.validateRendererBorrow(borrow);
        if (self.native != null) return error.AlreadyInitialized;
        var failure: c_int = 0;
        const native = zglr_create_in_domain(borrow.native, &failure) orelse {
            self.last_hresult = failure;
            return error.GraphicsInitializationFailed;
        };
        errdefer zglr_destroy(native);
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
        if (self.native) |native| zglr_destroy(native);
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
        switch (zglr_rebuild(self.native.?)) {
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

    /// error.DrawsInMemory: the window has no OpenGL context, or one on a
    /// software rasterizer it may not draw on; its frames are the software
    /// renderer's from now on.
    pub fn begin(self: *Renderer, paint: z.Paint) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        _ = try geometry.validateSurface(paint.size.width, paint.size.height, paint.size.scale);
        const scope = try self.enterDomain();
        errdefer self.leaveDomain(scope);
        // A browser restored the window's lost context: what was uploaded
        // went with it, and is uploaded again as frames draw it.
        if (zglr_restored(native) != 0) self.images.clear();
        switch (zglr_begin(native, paint.native_window, paint.size.width, paint.size.height, paint.size.scale, @intFromBool(paint.transparent))) {
            0 => {},
            1 => return error.NoSurface,
            5 => return error.DrawsInMemory,
            else => return error.GraphicsFailed,
        }
        self.destination = paint.native_context;
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
        if (zglr_begin_offscreen(native, size.width, size.height, size.scale, @intFromBool(transparent)) != 0) return error.GraphicsFailed;
        self.render_scope = scope;
        self.active = true;
        self.offscreen = true;
    }
    /// Premultiplied BGRA rows of `stride` bytes.
    pub fn endOffscreen(self: *Renderer, pixels: ?[]u8, stride: usize) !void {
        if (!self.active or !self.offscreen) return error.NotDrawing;
        defer self.finishScope();
        self.active = false;
        switch (zglr_end_offscreen(self.native.?, if (pixels) |value| value.ptr else null, stride)) {
            0 => {},
            3 => return error.DeviceLost,
            else => return error.GraphicsFailed,
        }
    }
    pub fn prepareOffscreen(self: *Renderer, size: z.Size) !void {
        if (zglr_offscreen_prepare(self.native orelse return error.NotInitialized, size.width, size.height) != 0) return error.GraphicsFailed;
    }
    pub fn commitOffscreen(self: *Renderer) void {
        zglr_offscreen_commit(self.native.?);
    }
    pub fn offscreenObjects(self: *const Renderer) u32 {
        return if (self.native) |native| zglr_offscreen_objects(native) else 0;
    }
    /// The committed front's 0xAARRGGBB pixels, premultiplied; for tests.
    pub fn readFront(self: *Renderer, pixels: []u32, width: u32, height: u32) !void {
        if (pixels.len != @as(usize, width) * height) return error.InvalidGeometry;
        if (zglr_read_front(self.native.?, pixels.ptr, width, height) != 0) return error.NoFrame;
    }
    /// The next offscreen frame fails as one on a lost device does.
    pub fn injectDeviceLoss(self: *Renderer) void {
        if (self.native) |native| zglr_inject_loss(native);
    }
    pub fn end(self: *Renderer) !void {
        if (!self.active) return error.NotDrawing;
        if (self.offscreen) return error.SurfaceModeMismatch;
        defer self.finishScope();
        self.active = false;
        const destination = self.destination;
        self.destination = null;
        if (zglr_end(self.native.?, destination) != 0) return error.GraphicsFailed;
    }
    pub fn abort(self: *Renderer) void {
        if (self.native) |native| zglr_abort(native);
        self.active = false;
        self.destination = null;
        self.finishScope();
    }
    pub fn discard(self: *Renderer) void {
        self.abort();
    }
    /// The software renderer paints its frames into the same draw signal:
    /// nothing of OpenGL's stays over them.
    pub fn suspendSurface(self: *Renderer) bool {
        if (self.native) |native| _ = zglr_suspend(native);
        return false;
    }
    pub fn restoreSurface(_: *Renderer) void {}
    pub fn frameReadyHandle(_: *const Renderer) ?*anyopaque {
        return null;
    }

    /// Whether OpenGL draws `buffer`; see the module's documentation. Each
    /// shader program it uses must have been prepared with `prepareEffect`;
    /// shader effects also need the frame's shader workspace and the
    /// frame's scale. Gaussian groups need kernels at the frame's scale;
    /// every capture must fit a texture.
    pub fn prepareEffects(self: *Renderer, buffer: *const commands.Buffer) bool {
        const native = self.native orelse return false;
        if (!self.active) return false;
        const scale = zglr_scale(native);
        if (self.domain_borrow == null) for (buffer.commands()) |op| switch (op) {
            .texture => return false,
            else => {},
        };
        for (buffer.preparedTextResources()) |view| if (view.native_coverage == null) return false;
        const entries = buffer.shaderEntries();
        const filters = buffer.filterResources();
        const transforms = buffer.transformResources();
        const workspace = buffer.shader_storage.workspace;
        var depth: usize = 0;
        var uses = false;
        // Masked clips draw as groups masked by their coverage: the clip
        // depth of each, a bit for each depth.
        var clip_depth: usize = 0;
        var masked: u64 = 0;
        for (buffer.commands()) |op| switch (op) {
            .push_clip, .push_opacity => clip_depth += 1,
            .push_mask_clip => {
                if (depth == max_capture_depth or clip_depth >= 64) return false;
                masked |= @as(u64, 1) << @intCast(clip_depth);
                clip_depth += 1;
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
                if (depth == max_capture_depth) return false;
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
                depth += 1;
            },
            .begin_transform => |slot| {
                if (depth == max_capture_depth or slot >= transforms.len) return false;
                const t = transforms[slot];
                if (t.pixel_width + 2 > max_texture or t.pixel_height + 2 > max_texture) return false;
                depth += 1;
            },
            .effect => |slot| {
                uses = true;
                if (depth == max_capture_depth) return false;
                const shaders = workspace orelse return false;
                if (slot >= entries.len) return false;
                const entry = &entries[slot];
                if (entry.scale != scale) return false;
                const kernel = shaders.carrierFor(entry.scale) catch return false;
                const capture = gaussian_scope.Capture.init(entry.captureRect(), kernel) catch return false;
                if (capture.pixelWidth() > max_texture or capture.pixelHeight() > max_texture) return false;
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
        self.effect_slots_len = 0;
        if (!uses) return true;
        if (entries.len > self.effect_slots.len) return false;
        self.effect_table.beginFrame();
        // A program waiting for the context is linked after this frame
        // (`holdsFrame`, `residentFrame`).
        for (entries, 0..) |*entry, i| self.effect_slots[i] = self.effect_table.find(entry.program.identity, entry.target) orelse return false;
        self.effect_slots_len = entries.len;
        return true;
    }
    /// Translate `program` drawn as `target` to GLSL and link it, outside a
    /// frame. False when the compiler rejects it: frames using it draw in
    /// software. A window's renderer before its first frame has no context
    /// yet: the program waits, translated, for the first frame that draws
    /// it (`residentFrame`).
    pub fn prepareEffect(self: *Renderer, allocator: std.mem.Allocator, program: *const shader_effects.shader.Program, target: shader_effects.Target) !bool {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        const scope = try self.enterDomain();
        defer self.leaveDomain(scope);
        const table = &self.effect_table;
        table.beginFrame();
        if (table.find(program.identity, target)) |slot| {
            if (zglr_effect_installed(native, slot) != 0) return true;
            return self.installEffect(slot);
        }
        if (table.failed(program.identity, target)) return false;
        var translation = shader_effects.shader.gpu.translate(allocator, program, .glsl) catch |err| switch (err) {
            error.UnsupportedProgram => {
                table.fail(program.identity, target);
                return false;
            },
            else => |e| return e,
        };
        defer translation.deinit();
        const source = try effect_host.sourceRows(allocator, &translation, program.kind, target, .glsl, .bottom_up);
        defer allocator.free(source);
        const slot = table.victim() orelse return false;
        const code = try allocator.dupe(u8, source[0 .. source.len + 1]);
        errdefer allocator.free(code);
        const inputs = try allocator.dupe(u16, translation.inputs);
        table.fill(slot, program.identity, target, inputs, code, allocator);
        return self.installEffect(slot);
    }
    /// Link the program the table holds in `slot` (its code ends with its
    /// NUL), or leave it waiting for the context; false and forgotten when
    /// the compiler rejects it.
    fn installEffect(self: *Renderer, slot: u32) bool {
        const native = self.native.?;
        if (zglr_effect_ready(native) == 0) return true;
        const entry = self.effect_table.entries[slot];
        switch (zglr_effect_install(native, slot, entry.code.ptr, entry.code.len - 1)) {
            0 => return true,
            2 => {
                self.effect_table.fail(entry.identity, entry.target);
                self.effect_table.forget(slot);
                return false;
            },
            else => return false,
        }
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
        switch (zglr_begin_effect(self.native.?, capture.left, capture.top, capture.width, capture.height, capture.radius)) {
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
            zglr_end_effect(self.native.?, null, entry.opacity)
        else status: {
            const pass = self.effectPass(open.slot, words, effect_host.elementParams(entry, capture), workspace);
            break :status zglr_end_effect(self.native.?, &pass, entry.opacity);
        };
        if (status != 0) return error.GraphicsFailed;
    }
    fn backdropShader(self: *Renderer, slot: u8, words: []u32) !void {
        const entry, const workspace = try self.effectSource(slot);
        var target: EffectGeometry = undefined;
        if (zglr_effect_geometry(self.native.?, &target) != 0) return error.NotDrawing;
        const origin = [2]f64{ target.origin[0], target.origin[1] };
        const plan = shader_effects.planBackdrop(target.width, target.height, target.scale, origin, target.clip, entry) orelse return;
        const room: ?usize = if (self.effect_buffer.?.backdrop_storage.workspace) |space| space.planes.len else null;
        if (!shader_effects.startBackdrop(workspace, entry, plan, room, target.scale)) return;
        const pass = self.effectPass(slot, words, effect_host.backdropParams(entry, plan, target.scale, origin, target.clip, target.transparent != 0), workspace);
        const region = [4]u32{ @intCast(plan.region[0]), @intCast(plan.region[1]), @intCast(plan.region[2]), @intCast(plan.region[3]) };
        const out = [4]u32{ @intCast(plan.out[0]), @intCast(plan.out[1]), @intCast(plan.out[2]), @intCast(plan.out[3]) };
        if (zglr_backdrop_shader(self.native.?, &pass, &region, &out) != 0) return error.GraphicsFailed;
    }
    /// Filters the target beneath a backdrop effect as the software planes
    /// do (src/ui/backdrop.zig), counting it in the workspace's statistics.
    fn backdropEffect(self: *Renderer, entry: backdrop.Entry, workspace: ?*backdrop.Workspace) !void {
        var target: EffectGeometry = undefined;
        if (zglr_effect_geometry(self.native.?, &target) != 0) return error.NotDrawing;
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
            .line2 = .{ 0, 0, 0, if (shading.kind == .glass) f(shading.rim_width) else 0 },
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
        if (zglr_backdrop(self.native.?, &glass, @intCast(count), &levels, &weights, weights.len) != 0) return error.GraphicsFailed;
    }
    /// Draws a loading indicator, its scene evaluated per pixel as the
    /// software planes rasterize it (src/ui/loading.zig).
    fn indicator(self: *Renderer, entry: loading.Entry) !void {
        var target: EffectGeometry = undefined;
        if (zglr_effect_geometry(self.native.?, &target) != 0) return error.NotDrawing;
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
        if (zglr_indicator(self.native.?, &elements, @intCast(scene.count), @floatCast(placed.ox - origin[0]), @floatCast(placed.oy - origin[1]), @floatCast(placed.k), &box, rgb, @as(f32, @floatFromInt(entry.color.a)) / 255) != 0) return error.GraphicsFailed;
    }
    fn effectPass(self: *Renderer, slot: u8, words: []u32, params: effect_host.Params, workspace: *shader_effects.Workspace) EffectPass {
        const installed = self.effect_slots[slot];
        const inputs = self.effect_table.entries[installed].inputs;
        for (inputs, 0..) |register, i| words[i] = workspace.machine.registers[register];
        return .{ .words = words.ptr, .word_count = @intCast(inputs.len), .slot = installed, .params = params };
    }
    /// Shader passes run on the GPU since the renderer was created.
    pub fn effectPasses(self: *const Renderer) u64 {
        return self.stats().effect_passes;
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
        return if (self.native) |native| self.active and !self.offscreen and zglr_plane(native, &generation) != 0 else false;
    }
    pub fn planeGeneration(self: *const Renderer) u64 {
        var generation: u64 = 0;
        if (self.native) |native| _ = zglr_plane(native, &generation);
        // Apart from the software plane's generations.
        return generation | (1 << 63);
    }
    pub fn forgetPlane(self: *Renderer) void {
        if (self.native) |native| zglr_forget_plane(native);
    }
    /// Draws `buffer` again only inside `region`, over the frame kept from
    /// the last one, as the software renderer's `replayDamage` does; a
    /// transparent frame's damage is cleared first. A whole region draws
    /// the frame as `replayBuffer` does.
    pub fn replayDamage(self: *Renderer, buffer: *const commands.Buffer, region: *const damage.Damage, transparent: bool) !void {
        if (!self.active) return error.NotDrawing;
        const native = self.native.?;
        if (region.full) return self.replayBuffer(buffer);
        zglr_set_partial(native, 1);
        for (region.slice()) |box| {
            zglr_push_device_clip(native, box.x0, box.y0, box.x1, box.y1);
            defer zglr_pop_clip(native);
            if (transparent) zglr_clear_box(native, box.x0, box.y0, box.x1, box.y1);
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
        try layers.validateGroup(bounds, options, zglr_scale(self.native.?));
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
            if (filter.scale != zglr_scale(native)) return error.GaussianDpiMismatch;
            const capture = try gaussian_scope.Capture.init(bounds, filter);
            break :status zglr_begin_gaussian(native, &descriptor, capture.left, capture.top, capture.width, capture.height, capture.radius, &filter.weights);
        } else zglr_begin_group(native, &descriptor);
        switch (status) {
            0 => {},
            1 => return error.LayerDepthExceeded,
            else => return error.GraphicsFailed,
        }
    }
    fn beginTransform(self: *Renderer, value: layers.NativeTransform) !void {
        try value.validate(zglr_scale(self.native.?));
        switch (zglr_begin_transform(self.native.?, value.pixel_width, value.pixel_height, value.source_width, value.source_height)) {
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
        const scale: f64 = zglr_scale(native);
        const to_parent = value.matrix();
        const inverse = try to_parent.inverse();
        const padded = try to_parent.mapBounds(.{ .x = -1 / scale, .y = -1 / scale, .width = @as(f64, @floatFromInt(value.pixel_width + 2)) / scale, .height = @as(f64, @floatFromInt(value.pixel_height + 2)) / scale });
        const bounds = [4]f32{ @floatCast(@floor(padded.x * scale)), @floatCast(@floor(padded.y * scale)), @floatCast(@ceil((padded.x + padded.width) * scale)), @floatCast(@ceil((padded.y + padded.height) * scale)) };
        const matrix = [6]f64{ inverse.xx, inverse.yx, inverse.xy, inverse.yy, inverse.x0, inverse.y0 };
        if (zglr_end_transform(native, &matrix, &bounds) != 0) return error.GraphicsFailed;
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
            _ = try drawing.planTexture(view, .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, value.options(), zglr_scale(self.native.?));
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
            for (0..count) |_| if (zglr_end_group(native) != 0) return error.GraphicsFailed;
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
    const Replay = struct {
        depth: usize = 0,
        /// The clips open that are masked, and those that are opacities, a
        /// bit for each depth.
        masked: u32 = 0,
        faded: u32 = 0,
        runs: MaskRuns = .{},
        effect_stack: [max_capture_depth]OpenEffect = undefined,
        effect_depth: usize = 0,
        transform_stack: [max_capture_depth]layers.NativeTransform = undefined,
        transform_depth: usize = 0,
        group_depth: usize = 0,
        words: [shader_effects.shader.gpu.max_input_words]u32 = undefined,

        fn level(self: *const Replay) usize {
            return self.group_depth + self.transform_depth + self.effect_depth;
        }
    };
    fn replayAll(self: *Renderer, ops: []const commands.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView, transforms: []const layers.NativeTransform, filters: []const gaussian.View) !void {
        if (!self.active) return error.NotDrawing;
        const native = self.native.?;
        try self.preflightTextures(ops, textures);
        if (resources.len > commands.brushes.max_brushes) return error.BrushesFull;
        for (resources) |*resource| try resource.validate();
        var replay_state: Replay = .{};
        const state = &replay_state;
        defer while (state.depth != 0) : (state.depth -= 1) {
            if (state.faded & (@as(u32, 1) << @intCast(state.depth - 1)) != 0) zglr_pop_opacity(native);
            zglr_pop_clip(native);
        };
        const runs = &state.runs;
        const box_sources: damage.Sources = .{ .prepared = prepared, .coverage = coverage_resources, .indicators = if (self.effect_buffer) |buffer| buffer.indicator_storage[0..buffer.indicator_len] else &.{} };
        const box_scale = zglr_scale(native);
        for (ops) |op| {
            const level = state.level();
            if (runs.len != 0) switch (op) {
                .fill, .shape, .gradient, .text, .prepared_text, .coverage, .image, .indicator, .texture => try runs.draw(self, level, damage.commandBox(op, box_sources, box_scale), coverage_resources, filters),
                .backdrop, .backdrop_shader => {
                    try runs.flush(self);
                    try runs.draw(self, level, null, coverage_resources, filters);
                },
                .push_clip, .push_mask_clip, .push_opacity, .pop_clip, .end_group, .end_transform, .end_effect => try runs.flush(self),
                .begin_group, .begin_transform, .effect => try runs.beginSpan(self, level, coverage_resources, filters),
            };
            try self.replayOne(op, text, resources, prepared, image_resources, coverage_resources, textures, transforms, filters, state);
        }
        try runs.flush(self);
        if (state.depth != 0) return error.UnbalancedClips;
        if (state.effect_depth != 0) return error.UnbalancedEffects;
        if (state.group_depth != 0) return error.UnbalancedGroups;
        if (state.transform_depth != 0) return error.UnbalancedTransforms;
    }
    fn replayOne(self: *Renderer, op: commands.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView, transforms: []const layers.NativeTransform, filters: []const gaussian.View, state: *Replay) !void {
        const native = self.native.?;
        const runs = &state.runs;
        switch (op) {
            .fill => |fill| {
                if (!layout.validRect(fill.bounds)) return error.InvalidGeometry;
                const r = fill.bounds;
                zglr_fill(native, r.x, r.y, r.width, r.height, fill.color);
            },
            .shape => |value| {
                const p = try geometry.plan(value);
                if (zglr_shape(native, p.bounds.x, p.bounds.y, p.bounds.width, p.bounds.height, p.radius, p.stroke_width, p.color.rgba()) != 0) return error.DrawShapeFailed;
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
                if (zglr_gradient(native, p.bounds.x, p.bounds.y, p.bounds.width, p.bounds.height, p.radius, p.stroke_width, &descriptor, spread, space) != 0) return error.DrawGradientFailed;
            },
            .text => |value| {
                if (!layout.validRect(value.bounds)) return error.InvalidGeometry;
                if (value.offset > text.len or value.len > text.len - value.offset) return error.InvalidTextRange;
                const bytes = text[value.offset..][0..value.len];
                if (bytes.len > 64 * 1024) return error.TextTooLong;
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
                const r = value.bounds;
                const font = value.font;
                if (zglr_text(native, r.x, r.y, r.width, r.height, bytes.ptr, @intCast(bytes.len), value.rgb(), font.size(), font.weight.value(), @intFromBool(font.italic), @intFromBool(font.monospace), if (font.family == 0) null else fonts.systemName(font.family).ptr, value.letterSpacing(text)) != 0) return error.DrawTextFailed;
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
                if (state.depth == 32) return error.ClipStackFull;
                state.depth += 1;
                zglr_push_clip(native, r.x, r.y, r.width, r.height);
            },
            .push_mask_clip => |value| {
                const r = value.bounds;
                if (!layout.validRect(r)) return error.InvalidGeometry;
                if (state.depth == 32) return error.ClipStackFull;
                if (value.mask >= coverage_resources.len) return error.MissingResources;
                if (runs.len == runs.scopes.len) return error.ClipStackFull;
                zglr_push_clip(native, r.x, r.y, r.width, r.height);
                state.masked |= @as(u32, 1) << @intCast(state.depth);
                state.depth += 1;
                runs.scopes[runs.len] = .{ .clip = value, .level = state.level() };
                runs.len += 1;
            },
            // Each drawing until its pop fades by itself: drawn at the
            // opacity, as a group, transform or effect composites.
            .push_opacity => |alpha| {
                if (state.depth == 32) return error.ClipStackFull;
                zglr_push_device_clip(native, std.math.minInt(i32), std.math.minInt(i32), std.math.maxInt(i32), std.math.maxInt(i32));
                zglr_push_opacity(native, alpha);
                state.faded |= @as(u32, 1) << @intCast(state.depth);
                state.depth += 1;
            },
            .pop_clip => {
                if (state.depth == 0) return error.ClipStackEmpty;
                state.depth -= 1;
                const bit = @as(u32, 1) << @intCast(state.depth);
                if (state.masked & bit != 0) {
                    state.masked &= ~bit;
                    if (runs.len == 0) return error.ClipStackEmpty;
                    runs.len -= 1;
                }
                if (state.faded & bit != 0) {
                    state.faded &= ~bit;
                    zglr_pop_opacity(native);
                }
                zglr_pop_clip(native);
            },
            .effect => |slot| {
                if (self.effect_buffer == null) return error.SoftwareOnlyCommands;
                if (state.effect_depth == state.effect_stack.len) return error.LayerDepthExceeded;
                state.effect_stack[state.effect_depth] = try self.beginEffect(slot);
                state.effect_depth += 1;
            },
            .end_effect => {
                if (state.effect_depth == 0) return error.UnbalancedEffects;
                state.effect_depth -= 1;
                try self.endEffect(state.effect_stack[state.effect_depth], &state.words);
                try runs.endSpan(self, state.level());
            },
            .backdrop_shader => |slot| {
                if (self.effect_buffer == null) return error.SoftwareOnlyCommands;
                try self.backdropShader(slot, &state.words);
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
                state.group_depth += 1;
            },
            .end_group => {
                if (state.group_depth == 0) return error.GroupStackEmpty;
                state.group_depth -= 1;
                if (zglr_end_group(native) != 0) return error.GraphicsFailed;
                try runs.endSpan(self, state.level());
            },
            .begin_transform => |slot| {
                if (slot >= transforms.len) return error.MissingResources;
                if (state.transform_depth == state.transform_stack.len) return error.LayerDepthExceeded;
                try self.beginTransform(transforms[slot]);
                state.transform_stack[state.transform_depth] = transforms[slot];
                state.transform_depth += 1;
            },
            .end_transform => {
                if (state.transform_depth == 0) return error.TransformStackEmpty;
                state.transform_depth -= 1;
                try self.endTransform(state.transform_stack[state.transform_depth]);
                try runs.endSpan(self, state.level());
            },
            .texture => |value| {
                const view = textures[value.resource];
                const plan = try drawing.planTexture(view, .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, value.options(), zglr_scale(native));
                if (plan.destination.width == 0 or plan.destination.height == 0 or plan.opacity == 0) return;
                if (zglr_texture(native, view.token, &plan) != 0) return error.DrawTextureFailed;
            },
        }
    }
    pub fn preparedText(self: *Renderer, view: drawing.PreparedTextView, origin: drawing.Point, tint: geometry.Color) !void {
        if (!self.active) return error.NotDrawing;
        try view.validate();
        if (view.platform != .linux) return error.PreparedPlatformMismatch;
        const key = view.native_coverage orelse return error.PreparedPlatformMismatch;
        if (zglr_scale(self.native.?) != view.coverage.scale) return error.PreparedDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        const c = view.coverage;
        const descriptor: drawing.NativeCoverage = .{ .pixels = c.pixels.ptr, .byte_len = @as(usize, c.stride) * c.height, .width = c.width, .height = c.height, .stride = c.stride, .origin_x = c.origin_x, .origin_y = c.origin_y, .scale = c.scale };
        if (zglr_prepared(self.native.?, key, &descriptor, origin.x, origin.y, if (view.clip) |*r| r else null, tint.rgba()) != 0) return error.DrawPreparedTextFailed;
    }

    /// Whether uploads can reach the GPU now: a window's renderer makes its
    /// context at its first frame, and uploads before it wait for the
    /// frames that draw them (`residentFrame`).
    fn ready(self: *const Renderer) bool {
        return zglr_ready(self.native.?) != 0 or self.domain != null;
    }
    pub fn uploadCoverage(self: *Renderer, view: drawing.CoverageView) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        const scope = try self.enterDomain();
        defer self.leaveDomain(scope);
        try view.validate();
        if (!self.ready()) return;
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
        if (zglr_prepare_coverage(native, &descriptor) != 0) return error.CoverageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.victim() orelse break, true);
        const slot = self.images.empty().?;
        zglr_commit_image(native, @intCast(slot));
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
        if (zglr_scale(native) != view.coverage.scale) return error.CoverageDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        const slot = try self.images.lookupCoverage(view.identity);
        const x = @as(f64, origin.x) + @as(f64, @floatFromInt(view.coverage.origin_x)) / view.coverage.scale;
        const y = @as(f64, origin.y) + @as(f64, @floatFromInt(view.coverage.origin_y)) / view.coverage.scale;
        if (@abs(x) > std.math.floatMax(f32) or @abs(y) > std.math.floatMax(f32)) return error.InvalidGeometry;
        if (zglr_coverage(native, @intCast(slot), @floatCast(x), @floatCast(y), tint.rgba()) != 0) return error.DrawCoverageFailed;
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
        const scope = try self.enterDomain();
        defer self.leaveDomain(scope);
        try view.validate();
        if (!self.ready()) return;
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
        if (try self.videoPicture(view)) |picture| {
            if (zglr_prepare_video(native, picture) != 0) return error.ImageUploadFailed;
        } else if (zglr_prepare_image(native, view.levels.ptr, @intCast(view.levels.len)) != 0) return error.ImageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.victim() orelse break, true);
        const slot = self.images.empty().?;
        zglr_commit_image(native, @intCast(slot));
        self.images.commitCharged(slot, view, dynamic, charge);
    }
    /// Frames of video upload as their decoder left them (`drawing.VideoPicture`):
    /// NV12 planes, which the shader converts, or a browser's video element.
    pub const samples_video = true;
    /// The picture of a frame of video OpenGL samples where it is, or null
    /// for an image, or for a picture it takes converted into the view's
    /// levels, as one it cannot read in place.
    fn videoPicture(_: *Renderer, view: drawing.ImageView) !?*const drawing.VideoPicture {
        const source = view.video orelse return null;
        if (zglr_takes_video(&source.picture) != 0) return &source.picture;
        if (!source.ensure(view)) return error.ImageUploadFailed;
        return null;
    }
    pub fn updateImage(self: *Renderer, old_identity: u64, view: drawing.ImageView) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        const scope = try self.enterDomain();
        defer self.leaveDomain(scope);
        const slot = try self.images.updateSlot(old_identity, view);
        if (self.images.entries[slot].?.view.identity == view.identity) return;
        try view.lease.acquireResidency();
        errdefer view.lease.releaseResidency();
        if (try self.videoPicture(view)) |picture| {
            // A picture of another kind or size does not fit the texture:
            // it uploads again.
            if (zglr_update_video(native, @intCast(slot), picture) != 0) {
                self.dropImage(slot, false);
                return error.ImageNotUploaded;
            }
        } else if (zglr_update_image(native, @intCast(slot), view.levels.ptr, @intCast(view.levels.len)) != 0) return error.ImageUpdateFailed;
        self.images.replace(slot, view);
    }
    fn dropImage(self: *Renderer, slot: usize, eviction: bool) void {
        zglr_release_image(self.native.?, @intCast(slot));
        self.images.drop(slot, eviction);
    }
    fn reserveSlot(self: *Renderer) !void {
        if (self.images.empty() != null) return;
        if (self.images.nextCapacity()) |capacity| {
            if (zglr_reserve_images(self.native.?, @intCast(capacity)) == 0) {
                if (self.images.grow(capacity)) return else |_| {}
            }
        } else |_| {}
        self.dropImage(self.images.victim() orelse return error.ImageSlotsFull, true);
    }
    /// Whether every image and coverage mask a frame draws is uploaded; a
    /// frame missing one draws in software and `residentFrame` uploads them.
    pub fn holdsFrame(self: *const Renderer, buffer: *const commands.Buffer) bool {
        if (self.domain_borrow) |borrow| if (borrow.epoch.generation != self.device_generation) return false;
        for (buffer.imageResources()) |view| if (self.images.find(view.identity) == null) return false;
        for (buffer.coverageResources()) |view| if (self.images.findCoverage(view.identity) == null) return false;
        for (self.effect_slots[0..self.effect_slots_len]) |slot| if (zglr_effect_installed(self.native.?, slot) == 0) return false;
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
        // Programs waiting for the context, or linked again after a loss.
        for (self.effect_slots[0..self.effect_slots_len]) |slot| {
            if (self.effect_table.entries[slot].identity != 0 and zglr_effect_installed(self.native.?, slot) == 0) _ = self.installEffect(slot);
        }
        self.effect_slots_len = 0;
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
        const plan = try drawing.planImage(view, .{ .x = destination.x, .y = destination.y, .width = destination.width, .height = destination.height }, options, zglr_scale(self.native.?));
        if (plan.destination.width == 0 or plan.destination.height == 0 or plan.opacity == 0) return;
        const slot = try self.images.lookup(view.identity);
        if (zglr_image(self.native.?, @intCast(slot), &plan) != 0) return error.DrawImageFailed;
    }

    /// Groups and transforms capture into textures of their frame: OpenGL
    /// prepares no layer planes of its own.
    pub fn layerStats(_: *const Renderer) layers.Stats {
        return .{};
    }
    pub fn stats(self: *const Renderer) Stats {
        const native = self.native orelse return .{};
        var values: NativeStats = undefined;
        zglr_stats(native, &values);
        var result: Stats = undefined;
        inline for (zio.fields(Stats)) |field| @field(result, field.name) = @field(values, field.name);
        return result;
    }
    /// Texts kept in textures, those drawn with Pango and those drawn
    /// from a texture kept.
    pub fn textStats(self: *const Renderer) struct { entries: u32, rasters: u64, hits: u64 } {
        var entries: u32 = 0;
        var rasters: u64 = 0;
        var hits: u64 = 0;
        if (self.native) |native| zglr_text_stats(native, &entries, &rasters, &hits);
        return .{ .entries = entries, .rasters = rasters, .hits = hits };
    }
    /// Whether the context draws on a software rasterizer (llvmpipe).
    pub fn softwareRasterizer(self: *const Renderer) bool {
        return if (self.native) |native| zglr_software(native) != 0 else false;
    }
    /// Paints the window titled `title` now, as GTK's draw signal would,
    /// into an image as large as its area.
    pub fn displayForTest(title: [*:0]const u8) void {
        zglr_test_display(title);
    }
    /// Whether the last frame the window showed was OpenGL's.
    pub fn layerShownForTest(self: *Renderer) bool {
        return zglr_test_shown(self.native.?) != 0;
    }
    /// Keep a copy of each frame drawn for the window, for `pixelForTest`.
    pub fn captureForTest(self: *Renderer, enable: bool) void {
        if (self.native) |native| zglr_test_capture(native, @intFromBool(enable));
    }
    /// 0xAARRGGBB (premultiplied) of the last frame drawn while capturing.
    pub fn pixelForTest(self: *Renderer, x: u32, y: u32) u32 {
        return zglr_test_pixel(self.native.?, x, y);
    }
    pub fn pixelsForTest(self: *Renderer, pixels: []u32, width: u32, height: u32) !void {
        if (pixels.len != @as(usize, width) * height or zglr_test_pixels(self.native.?, pixels.ptr, width, height) == 0) return error.InvalidGeometry;
    }
    /// How the renderer draws: with GDK's context of the window, with
    /// EGL, or not yet.
    pub fn backendForTest(self: *Renderer) enum { none, gdk, egl } {
        return switch (zglr_test_backend(self.native.?)) {
            1 => .gdk,
            2 => .egl,
            else => .none,
        };
    }
};
