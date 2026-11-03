//! The Linux GPU renderer: replays a frame's commands with OpenGL 3.3
//! (src/ui/gl_renderer.c).
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
//! masks, images, clips, groups (at an opacity, through a mask, or filtered
//! with a Gaussian kernel) and raster transforms, which capture their
//! content in textures of the frame as the software planes do; their limits
//! are the software renderer's plan, which `Context` checks each frame
//! against. A frame that uses anything else (shader effects, backdrop
//! effects, loading indicators, GPU textures without a device domain) draws
//! on the software plane instead, as `prepareEffects` tells, where shader
//! effects still run on OpenGL; so does a frame drawing an image or mask not
//! yet uploaded (`holdsFrame`), which `residentFrame` uploads for the next.
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
extern fn zglr_text(*anyopaque, f32, f32, f32, f32, [*]const u8, u32, u32, f32, u16, c_int, c_int, ?[*:0]const u8) c_int;
extern fn zglr_text_stats(*anyopaque, *u32, *u64, *u64) void;
extern fn zglr_prepared(*anyopaque, *anyopaque, *const drawing.NativeCoverage, f32, f32, ?*const drawing.Rect, u32) c_int;
extern fn zglr_forget_prepared(*anyopaque) void;
extern fn zglr_reserve_images(*anyopaque, u32) c_int;
extern fn zglr_prepare_image(*anyopaque, [*]const drawing.ImageLevel, u32) c_int;
extern fn zglr_prepare_coverage(*anyopaque, *const drawing.NativeCoverage) c_int;
extern fn zglr_commit_image(*anyopaque, u32) void;
extern fn zglr_release_image(*anyopaque, u32) void;
extern fn zglr_update_image(*anyopaque, u32, [*]const drawing.ImageLevel, u32) c_int;
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

const NativeStats = extern struct { device_creations: u32, context_creations: u32, resizes: u32, presents: u32, memory_presents: u32, busy_presents: u32, text_rasters: u32, text_entries: u32, frames: u64, instances: u64, batches: u64, layers: u64, filter_passes: u64, partial_frames: u64, text_hits: u64, offscreen_targets: u64, device_losses: u64, damage_submissions: u64 };

/// Captures (groups and transforms) nested in one another at most, as
/// src/ui/gl_renderer.c holds them.
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
/// device_losses the devices this renderer lost with its domain and
/// damage_submissions what the toplevel added to the Wayland surface's
/// damage.
pub const Stats = struct { device_creations: u32 = 0, context_creations: u32 = 0, resizes: u32 = 0, presents: u32 = 0, memory_presents: u32 = 0, busy_presents: u32 = 0, text_rasters: u32 = 0, text_entries: u32 = 0, frames: u64 = 0, instances: u64 = 0, batches: u64 = 0, layers: u64 = 0, filter_passes: u64 = 0, partial_frames: u64 = 0, text_hits: u64 = 0, offscreen_targets: u64 = 0, device_losses: u64 = 0, damage_submissions: u64 = 0 };

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

    /// Whether OpenGL draws `buffer`; see the module's documentation.
    /// Gaussian groups need kernels at the frame's scale; every capture
    /// must fit a texture.
    pub fn prepareEffects(self: *Renderer, buffer: *const commands.Buffer) bool {
        const native = self.native orelse return false;
        if (!self.active) return false;
        const scale = zglr_scale(native);
        if (self.domain_borrow == null) for (buffer.commands()) |op| switch (op) {
            .texture => return false,
            else => {},
        };
        for (buffer.preparedTextResources()) |view| if (view.native_coverage == null) return false;
        const filters = buffer.filterResources();
        const transforms = buffer.transformResources();
        var depth: usize = 0;
        for (buffer.commands()) |op| switch (op) {
            .effect, .backdrop_shader, .backdrop, .indicator => return false,
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
            .end_group, .end_transform => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        };
        return depth == 0;
    }

    pub fn replayBuffer(self: *Renderer, buffer: *const commands.Buffer) !void {
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
    fn replayAll(self: *Renderer, ops: []const commands.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView, textures: []const drawing.TextureView, transforms: []const layers.NativeTransform, filters: []const gaussian.View) !void {
        if (!self.active) return error.NotDrawing;
        const native = self.native.?;
        try self.preflightTextures(ops, textures);
        if (resources.len > commands.brushes.max_brushes) return error.BrushesFull;
        for (resources) |*resource| try resource.validate();
        var depth: usize = 0;
        defer while (depth != 0) : (depth -= 1) zglr_pop_clip(native);
        var transform_stack: [max_capture_depth]layers.NativeTransform = undefined;
        var transform_depth: usize = 0;
        var group_depth: usize = 0;
        for (ops) |op| switch (op) {
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
                if (brush.isTransparent()) continue;
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
                if (zglr_text(native, r.x, r.y, r.width, r.height, bytes.ptr, @intCast(bytes.len), value.color, font.size(), font.weight.value(), @intFromBool(font.italic), @intFromBool(font.monospace), if (font.family == 0) null else fonts.systemName(font.family).ptr) != 0) return error.DrawTextFailed;
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
                zglr_push_clip(native, r.x, r.y, r.width, r.height);
            },
            .pop_clip => {
                if (depth == 0) return error.ClipStackEmpty;
                depth -= 1;
                zglr_pop_clip(native);
            },
            .effect, .end_effect, .backdrop_shader, .backdrop, .indicator => return error.SoftwareOnlyCommands,
            .begin_group => |value| {
                try self.beginGroup(value, coverage_resources, filters);
                group_depth += 1;
            },
            .end_group => {
                if (group_depth == 0) return error.GroupStackEmpty;
                group_depth -= 1;
                if (zglr_end_group(native) != 0) return error.GraphicsFailed;
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
            },
            .texture => |value| {
                const view = textures[value.resource];
                const plan = try drawing.planTexture(view, .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, value.options(), zglr_scale(native));
                if (plan.destination.width == 0 or plan.destination.height == 0 or plan.opacity == 0) continue;
                if (zglr_texture(native, view.token, &plan) != 0) return error.DrawTextureFailed;
            },
        };
        if (depth != 0) return error.UnbalancedClips;
        if (group_depth != 0) return error.UnbalancedGroups;
        if (transform_depth != 0) return error.UnbalancedTransforms;
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
        if (zglr_prepare_image(native, view.levels.ptr, @intCast(view.levels.len)) != 0) return error.ImageUploadFailed;
        while (self.images.needsEviction(charge)) self.dropImage(self.images.victim() orelse break, true);
        const slot = self.images.empty().?;
        zglr_commit_image(native, @intCast(slot));
        self.images.commitCharged(slot, view, dynamic, charge);
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
        if (zglr_update_image(native, @intCast(slot), view.levels.ptr, @intCast(view.levels.len)) != 0) return error.ImageUpdateFailed;
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
