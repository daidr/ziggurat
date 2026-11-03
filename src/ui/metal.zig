//! The macOS GPU renderer: replays a frame's commands with Metal into a
//! CAMetalLayer of the window's view (src/ui/metal.m).
//!
//! It draws fills, rounded shapes and strokes, gradients in sRGB
//! interpolation (linear, radial and conic, padded, repeated or
//! reflected), text, prepared text, coverage masks, images and clips. A frame
//! that uses anything else (groups, transforms, Gaussian filters, shader
//! and backdrop effects, loading indicators, GPU textures, gradients
//! interpolated in another space) draws on the software plane instead, as
//! `prepareEffects` tells; so does a frame drawing an image or mask not yet
//! uploaded (`holdsFrame`), which `residentFrame` uploads for the next.
const std = @import("std");
const fonts = @import("ziggurat_fonts");
const z = @import("ziggurat");
pub const commands = @import("commands.zig");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const drawing = @import("ziggurat_drawing_resources");
const image_cache = @import("image_cache.zig");
const layers = @import("layers.zig");
const gpu_resources = @import("gpu_resources.zig");
const shader_effects = commands.shader_effects;

extern fn zmtl_create(*c_int) ?*anyopaque;
extern fn zmtl_destroy(?*anyopaque) void;
extern fn zmtl_live_objects() u32;
extern fn zmtl_begin(*anyopaque, ?*anyopaque, u32, u32, f32, c_int) c_int;
extern fn zmtl_begin_offscreen(*anyopaque, u32, u32, f32, c_int) c_int;
extern fn zmtl_scale(*anyopaque) f32;
extern fn zmtl_fill(*anyopaque, f32, f32, f32, f32, u32) void;
extern fn zmtl_shape(*anyopaque, f32, f32, f32, f32, f32, f32, u32) c_int;
extern fn zmtl_gradient(*anyopaque, f32, f32, f32, f32, f32, f32, *const commands.brushes.Native, u32) c_int;
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
extern fn zmtl_test_display([*:0]const u8) void;
extern fn zmtl_test_capture(*anyopaque, c_int) void;
extern fn zmtl_test_pixel(*anyopaque, u32, u32) u32;
extern fn zmtl_test_layer_shown(*anyopaque) c_int;
extern fn zmtl_test_layer_under_subviews(*anyopaque) c_int;
extern fn zmtl_test_layer_flipped(*anyopaque) c_int;
extern fn zmtl_test_atlas_levels(*anyopaque) u32;

const NativeStats = extern struct { device_creations: u32, layer_creations: u32, resizes: u32, presents: u32, transaction_presents: u32, busy_presents: u32, atlas_pages: u32, glyphs: u32, frames: u64, instances: u64, batches: u64 };

pub const Driver = enum { hardware, warp };
pub const Options = struct {
    /// Metal always uses the system's default device.
    driver: Driver = .hardware,
    /// Shared device domains are a D3D11 facility; Metal refuses one.
    domain: ?*gpu_resources.DeviceDomain = null,
    native_wait_slot: ?*?z.NativeWaitToken = null,
};
/// presents counts drawables presented, transaction_presents those presented
/// with the Core Animation transaction (frames that changed the layer and
/// those of a live resize), busy_presents frames for which no drawable came.
pub const Stats = struct { device_creations: u32 = 0, layer_creations: u32 = 0, resizes: u32 = 0, presents: u32 = 0, transaction_presents: u32 = 0, busy_presents: u32 = 0, atlas_pages: u32 = 0, glyphs: u32 = 0, frames: u64 = 0, instances: u64 = 0, batches: u64 = 0 };

pub fn liveObjects() u32 {
    return zmtl_live_objects();
}

pub const Renderer = struct {
    native: ?*anyopaque = null,
    /// Kept for the shared failure report; Metal has no HRESULT.
    last_hresult: i32 = 0,
    active: bool = false,
    offscreen: bool = false,
    /// Device domains are not shared on macOS.
    domain_borrow: ?gpu_resources.DeviceDomain.Borrow = null,
    interpolation_mutating: bool = false,
    images: image_cache.Cache = .{},
    /// The view is being drawn into a capture: its software frame must not
    /// hide the layer the window shows.
    capturing: bool = false,

    pub fn init(self: *Renderer, options: Options) !void {
        if (self.native != null) return error.AlreadyInitialized;
        if (options.domain != null) return error.UnsupportedDomainRenderMode;
        var failure: c_int = 0;
        self.native = zmtl_create(&failure) orelse return error.GraphicsInitializationFailed;
        self.last_hresult = failure;
    }
    pub fn deinit(self: *Renderer) void {
        if (self.native) |native| zmtl_destroy(native);
        self.images.deinit();
        self.* = .{};
    }

    pub fn begin(self: *Renderer, paint: z.Paint) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        _ = try geometry.validateSurface(paint.size.width, paint.size.height, paint.size.scale);
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
        self.active = true;
        self.offscreen = false;
    }
    /// A frame drawn into an owned texture rather than the window, read
    /// back by `endOffscreen`; for checks that compare it with software.
    pub fn beginOffscreen(self: *Renderer, size: z.Size, transparent: bool) !void {
        if (self.active) return error.AlreadyDrawing;
        const native = self.native orelse return error.NotInitialized;
        _ = try geometry.validateSurface(size.width, size.height, size.scale);
        if (zmtl_begin_offscreen(native, size.width, size.height, size.scale, @intFromBool(transparent)) != 0) return error.GraphicsFailed;
        self.active = true;
        self.offscreen = true;
    }
    /// Premultiplied BGRA rows of `stride` bytes.
    pub fn endOffscreen(self: *Renderer, pixels: ?[]u8, stride: usize) !void {
        if (!self.active or !self.offscreen) return error.NotDrawing;
        self.active = false;
        if (zmtl_end_offscreen(self.native.?, if (pixels) |value| value.ptr else null, stride) != 0) return error.GraphicsFailed;
    }
    pub fn end(self: *Renderer) !void {
        if (!self.active) return error.NotDrawing;
        if (self.offscreen) return error.SurfaceModeMismatch;
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

    /// Whether the GPU draws `buffer`; see the module's documentation.
    pub fn prepareEffects(self: *Renderer, buffer: *const commands.Buffer) bool {
        if (self.native == null or !self.active) return false;
        const brushes = buffer.brushResources();
        for (buffer.commands()) |op| switch (op) {
            .backdrop, .indicator, .effect, .end_effect, .backdrop_shader, .begin_group, .end_group, .begin_transform, .end_transform, .texture => return false,
            .gradient => |value| if (value.brush < brushes.len and brushes[value.brush].interpolation != .srgb) return false,
            else => {},
        };
        for (buffer.preparedTextResources()) |view| if (view.native_coverage == null) return false;
        return true;
    }
    /// Shader programs run on the software planes on macOS for now.
    pub fn prepareEffect(_: *Renderer, _: std.mem.Allocator, _: *const shader_effects.shader.Program, _: shader_effects.Target) !bool {
        return false;
    }

    pub fn replayBuffer(self: *Renderer, buffer: *const commands.Buffer) !void {
        try self.replayWithResources(buffer.commands(), buffer.textBytes(), buffer.brushResources(), buffer.preparedTextResources(), buffer.imageResources(), buffer.coverageResources());
    }
    pub fn replay(self: *Renderer, ops: []const commands.Command, text: []const u8) !void {
        try self.replayWithResources(ops, text, &.{}, &.{}, &.{}, &.{});
    }
    pub fn replayWithResources(self: *Renderer, ops: []const commands.Command, text: []const u8, resources: []const commands.brushes.Stored, prepared: []const drawing.PreparedTextView, image_resources: []const drawing.ImageView, coverage_resources: []const drawing.CoverageView) !void {
        if (!self.active) return error.NotDrawing;
        const native = self.native.?;
        if (resources.len > commands.brushes.max_brushes) return error.BrushesFull;
        for (resources) |*resource| try resource.validate();
        var depth: usize = 0;
        defer while (depth != 0) : (depth -= 1) zmtl_pop_clip(native);
        for (ops) |op| switch (op) {
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
                if (brush.isTransparent()) continue;
                if (brush.interpolation != .srgb) return error.UnsupportedGradient;
                const descriptor = brush.native();
                const spread: u32 = switch (brush.spread) {
                    .pad => 0,
                    .repeat => 1,
                    .reflect => 2,
                };
                if (zmtl_gradient(native, p.bounds.x, p.bounds.y, p.bounds.width, p.bounds.height, p.radius, p.stroke_width, &descriptor, spread) != 0) return error.DrawGradientFailed;
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
            .pop_clip => {
                if (depth == 0) return error.ClipStackEmpty;
                depth -= 1;
                zmtl_pop_clip(native);
            },
            // prepareEffects leaves these frames to software.
            .backdrop, .indicator, .effect, .end_effect, .backdrop_shader, .begin_group, .end_group, .begin_transform, .end_transform, .texture => return error.UnsupportedCommand,
        };
        if (depth != 0) return error.UnbalancedClips;
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
        for (buffer.imageResources()) |view| if (self.images.find(view.identity) == null) return false;
        for (buffer.coverageResources()) |view| if (self.images.findCoverage(view.identity) == null) return false;
        return true;
    }
    pub fn residentFrame(self: *Renderer, buffer: *const commands.Buffer) !void {
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

    /// No GPU layer planes on macOS: frames with groups draw in software.
    pub fn layerStats(_: *const Renderer) layers.Stats {
        return .{};
    }
    pub fn stats(self: *const Renderer) Stats {
        const native = self.native orelse return .{};
        var values: NativeStats = undefined;
        zmtl_stats(native, &values);
        return .{ .device_creations = values.device_creations, .layer_creations = values.layer_creations, .resizes = values.resizes, .presents = values.presents, .transaction_presents = values.transaction_presents, .busy_presents = values.busy_presents, .atlas_pages = values.atlas_pages, .glyphs = values.glyphs, .frames = values.frames, .instances = values.instances, .batches = values.batches };
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
