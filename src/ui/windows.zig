const std = @import("std");
const gaussian = @import("gaussian_filter.zig");
const gaussian_scope = @import("gaussian_scope.zig");
const z = @import("ziggurat");
const Rect = @import("input.zig").Rect;
const commands = @import("commands.zig");
const fonts = @import("ziggurat_fonts");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const drawing = @import("ziggurat_drawing_resources");
const image_sampling = @import("image_sampling.zig");
const image_cache = @import("image_cache.zig");
const cpu_gradient = @import("cpu_gradient.zig");
const layers = @import("layers.zig");
const windows_layers = @import("windows_layers.zig");
const composite = @import("composite.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});

pub const Renderer = struct {
    dc: c.HDC = null,
    bitmap: c.HBITMAP = null,
    pixels: ?[*]u32 = null,
    original_bitmap: c.HGDIOBJ = null,
    font: c.HFONT = null,
    original_font: c.HGDIOBJ = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: f32 = 0,
    images: image_cache.Cache = .{},
    layer_workspace: ?*windows_layers.Workspace = null,
    layer_fault: u32 = 0,
    /// The Buffer whose backdrop and indicator tables the current replay reads.
    backdrop_source: ?*const commands.Buffer = null,
    /// Element effects open as Gaussian captures, innermost last.
    effect_scopes: [layers.max_depth]EffectScope = undefined,
    effect_count: usize = 0,
    layer_candidate_peak: usize = 0,
    /// Fonts other than the default label font, created on first use and
    /// kept until deinit; the oldest is replaced when all are taken.
    variant_fonts: [8]VariantFont = @splat(.{}),
    variant_next: u8 = 0,
    const VariantFont = struct { key: u32 = 0, scale: f32 = 0, font: c.HFONT = null };
    pub const LayerCandidate = *windows_layers.Workspace;
    pub fn layerMetadataBytes() usize {
        return @sizeOf(windows_layers.Workspace);
    }
    pub fn prepareOffscreen(_: *Renderer) !void {}
    pub fn beginOffscreen(self: *Renderer) !void {
        const workspace = self.layer_workspace orelse return error.LayersRequired;
        try workspace.beginOffscreen();
        self.bindSurface(workspace.current());
    }
    pub fn endOffscreen(self: *Renderer, pixels: []u8) !void {
        const workspace = self.layer_workspace orelse return error.LayersRequired;
        try workspace.commitOffscreen(pixels);
        self.bindSurface(workspace.front());
    }
    pub fn createLayerCandidate(self: *Renderer, allocator: std.mem.Allocator, options: layers.Options) !LayerCandidate {
        return self.createPlanCandidate(allocator, try layers.Plan.init(options, .gdi));
    }
    pub fn createTransformCandidate(self: *Renderer, allocator: std.mem.Allocator, options: layers.TransformOptions) !LayerCandidate {
        return self.createPlanCandidate(allocator, try layers.Plan.initTransforms(options, .gdi));
    }
    fn createPlanCandidate(self: *Renderer, allocator: std.mem.Allocator, plan: layers.Plan) !LayerCandidate {
        if (self.layer_workspace) |workspace| if (workspace.active) return error.AlreadyDrawing;
        self.layer_candidate_peak = @max(self.layer_candidate_peak, self.layerSurfaceBytes() + plan.pixel_bytes);
        const fault = self.layer_fault;
        self.layer_fault = 0;
        const candidate = try windows_layers.Workspace.createPlan(allocator, plan, fault);
        errdefer candidate.deinit();
        if (self.width == plan.options.size.width and self.height == plan.options.size.height and self.scale == plan.options.size.scale and self.pixels != null) {
            if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
            @memcpy(candidate.front().pixels.?[0 .. plan.plane_bytes / 4], self.pixels.?[0 .. plan.plane_bytes / 4]);
            candidate.front_transparent = if (self.layer_workspace) |old| old.front_transparent else false;
        }
        return candidate;
    }
    pub fn destroyLayerCandidate(candidate: LayerCandidate) void {
        candidate.deinit();
    }
    pub fn commitLayerCandidate(self: *Renderer, candidate: LayerCandidate) void {
        if (self.layer_workspace) |old| old.deinit() else self.releaseSurface();
        self.layer_workspace = candidate;
        self.width = candidate.plan.options.size.width;
        self.height = candidate.plan.options.size.height;
        self.scale = candidate.plan.options.size.scale;
        self.bindSurface(candidate.front());
    }
    pub fn prepareLayers(self: *Renderer, allocator: std.mem.Allocator, options: layers.Options) !void {
        if (self.layer_workspace) |workspace| if (workspace.active) return error.AlreadyDrawing;
        const candidate = try self.createLayerCandidate(allocator, options);
        self.commitLayerCandidate(candidate);
    }
    pub fn prepareTransforms(self: *Renderer, allocator: std.mem.Allocator, options: layers.TransformOptions) !void {
        self.commitLayerCandidate(try self.createTransformCandidate(allocator, options));
    }
    pub fn createGaussianCandidate(self: *Renderer, allocator: std.mem.Allocator, plan: gaussian_scope.Plan) !LayerCandidate {
        const candidate = try self.createPlanCandidate(allocator, plan.layers);
        errdefer candidate.deinit();
        try candidate.prepareGaussian(plan);
        self.layer_candidate_peak = @max(self.layer_candidate_peak, self.layerSurfaceBytes() + plan.pixel_bytes);
        return candidate;
    }
    pub fn prepareGaussian(self: *Renderer, allocator: std.mem.Allocator, options: gaussian_scope.Options) !void {
        self.commitLayerCandidate(try self.createGaussianCandidate(allocator, try gaussian_scope.Plan.init(options, .gdi, self.transformOptions())));
    }
    pub fn gaussianCapacity(self: *const Renderer) ?gaussian_scope.Capacity {
        return if (self.layer_workspace) |workspace| if (workspace.gaussian) |owner| owner.capacity else null else null;
    }
    pub fn gaussianMetadataBytes() usize {
        return @sizeOf(@import("gaussian_workspace.zig").Owner);
    }
    pub fn releaseGaussian(self: *Renderer) !void {
        const workspace = self.layer_workspace orelse return;
        if (workspace.active) return error.AlreadyDrawing;
        const owner = workspace.gaussian orelse return;
        workspace.gaussian = null;
        workspace.stats.pixel_bytes = workspace.plan.pixel_bytes;
        workspace.stats.metadata_bytes -= @sizeOf(@import("gaussian_workspace.zig").Owner);
        owner.close();
    }
    pub fn transformOptions(self: *const Renderer) ?layers.TransformOptions {
        return if (self.layer_workspace) |workspace| workspace.plan.transformOptions() else null;
    }
    pub fn releaseLayers(self: *Renderer) !void {
        const workspace = self.layer_workspace orelse return;
        if (workspace.active) return error.AlreadyDrawing;
        if (workspace.front_transparent) return error.OffscreenSurface;
        var front = workspace.takeFront();
        workspace.deinit();
        self.layer_workspace = null;
        self.bindSurface(&front);
    }
    pub fn injectLayerPreparationFailureForTest(self: *Renderer, one_based_plane: u32) void {
        self.layer_fault = one_based_plane;
    }
    pub fn layerSurfaceBytes(self: *const Renderer) usize {
        return if (self.layer_workspace) |workspace| workspace.stats.pixel_bytes else if (self.dc != null) @as(usize, self.width) * self.height * 4 else 0;
    }
    pub fn layerOptions(self: *const Renderer) ?layers.Options {
        return if (self.layer_workspace) |workspace| workspace.plan.options else null;
    }
    pub fn layerPlan(self: *const Renderer) ?layers.Plan {
        return if (self.layer_workspace) |workspace| workspace.plan else null;
    }
    pub fn layerStats(self: *const Renderer) layers.Stats {
        var stats = if (self.layer_workspace) |workspace| workspace.stats else layers.Stats{};
        stats.candidate_peak_bytes = self.layer_candidate_peak;
        return stats;
    }
    fn bindSurface(self: *Renderer, surface: *const windows_layers.Surface) void {
        self.dc = surface.dc;
        self.bitmap = surface.bitmap;
        self.pixels = surface.pixels;
        self.original_bitmap = surface.original_bitmap;
        self.font = surface.font;
        self.original_font = surface.original_font;
        self.width = surface.width;
        self.height = surface.height;
    }
    pub fn abort(self: *Renderer) void {
        if (self.layer_workspace) |workspace| {
            workspace.abort();
            self.bindSurface(workspace.front());
        }
    }
    pub fn beginGroup(self: *Renderer, group_bounds: drawing.Rect, options: layers.Group) !void {
        const workspace = self.layer_workspace orelse return error.LayersRequired;
        try workspace.beginGroup(group_bounds, options);
        self.bindSurface(workspace.current());
    }
    pub fn beginGaussian(self: *Renderer, group_bounds: drawing.Rect, options: layers.Group, view: gaussian.View) !void {
        try view.validate();
        if (view.descriptor.radius == 0) return self.beginGroup(group_bounds, options);
        const workspace = self.layer_workspace orelse return error.GaussianNotPrepared;
        try workspace.beginGaussian(group_bounds, options, view.descriptor);
        self.bindSurface(workspace.current());
    }
    pub fn endGroup(self: *Renderer) !void {
        const workspace = self.layer_workspace orelse return error.LayersRequired;
        try workspace.endGroup();
        self.bindSurface(workspace.current());
    }
    const EffectScope = struct { entry: *const commands.shader_effects.Entry, workspace: ?*commands.shader_effects.Workspace };
    const Resources = struct {
        text_bytes: []const u8,
        brushes: []const commands.brushes.Stored,
        prepared: []const drawing.PreparedTextView,
        images: []const drawing.ImageView,
        coverage: []const drawing.CoverageView,
        transforms: []const layers.NativeTransform,
        filters: []const gaussian.View,
    };
    /// Open an element effect's Gaussian capture when one is prepared with
    /// room for it; false leaves the effect to isolation on the target.
    fn captureEffect(self: *Renderer, entry: *const commands.shader_effects.Entry) !bool {
        const workspace = self.layer_workspace orelse return false;
        if (!workspace.active or self.effect_count == self.effect_scopes.len) return false;
        const capacity = self.gaussianCapacity() orelse return false;
        const effects = self.backdrop_source.?.shader_storage.workspace orelse return false;
        const kernel = effects.carrierFor(entry.scale) catch return false;
        const capture_bounds = entry.captureRect();
        const capture = gaussian_scope.Capture.init(capture_bounds, kernel) catch return false;
        capture.check(capacity) catch return false;
        workspace.beginGaussian(capture_bounds, .{ .opacity = entry.opacity }, kernel) catch |err| switch (err) {
            // The layer depth or the frame's filter budget is spent.
            error.LayerDepthExceeded, error.GaussianWorkExceeded => return false,
            else => return err,
        };
        self.bindSurface(workspace.current());
        return true;
    }
    fn runEffect(context: *const anyopaque, source: []u32, source_stride: usize, scratch: []u32, scratch_stride: usize, capture: gaussian_scope.Capture) void {
        const scope: *const EffectScope = @ptrCast(@alignCast(context));
        const width = capture.pixelWidth();
        const height = capture.pixelHeight();
        commands.shader_effects.applyElement(scope.entry, .{ .pixels = source, .width = width, .height = height, .stride = source_stride }, .{ .pixels = scratch, .width = width, .height = height, .stride = scratch_stride }, capture, scope.workspace);
    }
    /// The current target as a CPU surface, after batched GDI drawing.
    fn targetSurface(self: *Renderer) !cpu_gradient.Surface {
        const clip = try self.physicalClip();
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        return .{ .pixels = self.pixels orelse return error.NoSurface, .width = self.width, .height = self.height, .stride = self.width, .scale = self.scale, .clip = clip, .origin = self.pixelOrigin() };
    }
    /// Draw `body` isolated on the current target and composite it through
    /// the effect; without a workspace or room it is drawn plainly.
    fn isolateEffect(self: *Renderer, body: []const commands.Command, entry: *const commands.shader_effects.Entry, resources: Resources) anyerror!void {
        const effects = commands.shader_effects;
        const workspace = self.backdrop_source.?.shader_storage.workspace orelse return self.execute(body, resources);
        var surface = try self.targetSurface();
        const region = effects.twoPassRegion(surface, entry, workspace) orelse return self.execute(body, resources);
        effects.beginIsolation(surface, region, workspace);
        errdefer effects.cancelIsolation(surface, region, workspace);
        try self.execute(body, resources);
        surface = try self.targetSurface();
        effects.secondIsolation(surface, region, workspace);
        try self.execute(body, resources);
        surface = try self.targetSurface();
        _ = effects.finishIsolation(surface, self.transparent(), region, entry, workspace);
    }
    pub fn beginTransform(self: *Renderer, value: layers.NativeTransform) !void {
        const workspace = self.layer_workspace orelse return error.TransformsRequired;
        try workspace.beginTransform(value);
        self.bindSurface(workspace.current());
    }
    pub fn endTransform(self: *Renderer) !void {
        const workspace = self.layer_workspace orelse return error.TransformsRequired;
        try workspace.endTransform();
        self.bindSurface(workspace.current());
    }
    fn pixelOrigin(self: *const Renderer) [2]f64 {
        return if (self.layer_workspace) |workspace| workspace.current().origin else .{ 0, 0 };
    }
    fn physicalRect(self: *const Renderer, rect: drawing.Rect) [4]f64 {
        return if (self.layer_workspace) |workspace| workspace.physicalRect(rect) else windows_layers.physical(rect, self.scale);
    }
    fn transparent(self: *const Renderer) bool {
        return if (self.layer_workspace) |workspace| workspace.active and (workspace.depth != 0 or workspace.transparent_root) else false;
    }
    fn physicalClip(self: *const Renderer) ![4]f64 {
        if (self.layer_workspace) |workspace| if (workspace.active) {
            const clip = workspace.current().clip();
            const width: f64 = @floatFromInt(self.width);
            const height: f64 = @floatFromInt(self.height);
            return .{ std.math.clamp(clip[0], 0, width), std.math.clamp(clip[1], 0, height), std.math.clamp(clip[2], 0, width), std.math.clamp(clip[3], 0, height) };
        };
        var clip: c.RECT = undefined;
        if (c.GetClipBox(self.dc, &clip) == c.ERROR) return error.ReadClipFailed;
        return .{ @floatFromInt(clip.left), @floatFromInt(clip.top), @floatFromInt(clip.right), @floatFromInt(clip.bottom) };
    }
    pub fn uploadCoverage(self: *Renderer, view: drawing.CoverageView) !void {
        try view.validate();
        self.images.coverage_stats.upload_requests +%= 1;
        if (self.images.find(view.identity) != null) return error.RasterIdentityConflict;
    }
    pub fn releaseCoverage(_: *Renderer, _: u64) !bool {
        return false;
    }
    pub fn coverage(self: *Renderer, view: drawing.CoverageView, origin: drawing.Point, tint: geometry.Color) !void {
        try view.validate();
        if (self.dc == null) return error.NoSurface;
        if (view.coverage.scale != self.scale) return error.CoverageDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        self.images.coverage_stats.draws +%= 1;
        try self.drawCoverage(view.coverage, origin, tint, null);
    }
    pub fn coverageStats(self: *const Renderer) drawing.CoverageStats {
        return self.images.coverage_stats;
    }
    /// Images and alpha_coverage share the same bounded residency budget.
    pub fn setRasterBudget(self: *Renderer, bytes: usize) !void {
        try self.setImageBudget(bytes);
    }
    pub fn rasterStats(self: *const Renderer) drawing.RasterStats {
        return .{ .images = self.imageStats(), .coverage = self.coverageStats(), .resident_entries = self.images.totalEntries(), .pixel_bytes = self.images.totalBytes(), .budget_bytes = self.images.stats.budget_bytes, .peak_reserved_bytes = self.images.raster_peak_bytes };
    }
    pub fn uploadImage(self: *Renderer, view: drawing.ImageView) !void {
        try view.validate();
        self.images.stats.upload_requests +%= 1;
        if (self.images.findCoverage(view.identity) != null) return error.RasterIdentityConflict;
        // GDI reads the caller's prepared CPU pixels directly. It has no
        // independent residency, upload, resource pin or texture allocation.
    }
    pub fn uploadDynamicImage(self: *Renderer, view: drawing.ImageView) !void {
        try view.validate();
        self.images.stats.upload_requests +%= 1;
        if (self.images.findCoverage(view.identity) != null) return error.RasterIdentityConflict;
        if (self.images.find(view.identity)) |slot| {
            self.images.touch(slot);
            return;
        }
        const charge = view.pixelBytes();
        if (charge > self.images.stats.budget_bytes) return error.ImageBudgetExceeded;
        if (self.images.empty() == null) {
            if (self.images.nextCapacity()) |capacity| self.images.grow(capacity) catch {} else |_| {}
            if (self.images.empty() == null) self.images.drop(self.images.victim() orelse return error.ImageSlotsFull, true);
        }
        try view.lease.acquireResidency();
        self.images.stats.peak_reserved_bytes = @max(self.images.stats.peak_reserved_bytes, self.images.stats.pixel_bytes + charge);
        self.images.reserveCandidate(charge);
        while (self.images.needsEviction(charge)) self.images.drop(self.images.victim() orelse break, true);
        self.images.commitCharged(self.images.empty().?, view, true, charge);
    }
    pub fn updateImage(self: *Renderer, old_identity: u64, view: drawing.ImageView) !void {
        const slot = try self.images.updateSlot(old_identity, view);
        if (self.images.entries[slot].?.view.identity == view.identity) return;
        try view.lease.acquireResidency();
        self.images.replace(slot, view);
    }
    pub fn releaseImage(self: *Renderer, identity: u64) !bool {
        const slot = self.images.find(identity) orelse return false;
        try self.images.entries[slot].?.view.lease.checkOwner();
        self.images.drop(slot, false);
        return true;
    }
    pub fn setImageBudget(self: *Renderer, bytes: usize) !void {
        if (bytes == 0 or bytes > drawing.max_image_budget) return error.InvalidImageBudget;
        try self.images.checkOwners();
        self.images.stats.budget_bytes = bytes;
        while (self.images.totalBytes() > bytes) self.images.drop(self.images.oldest().?, true);
    }
    pub fn imageStats(self: *const Renderer) drawing.ImageStats {
        return self.images.stats;
    }
    /// GDI draws from the caller's CPU pixels, so a frame needs no uploads.
    pub fn residentFrame(self: *Renderer, buffer: *const commands.Buffer) !void {
        _ = self;
        _ = buffer;
    }
    pub fn image(self: *Renderer, view: drawing.ImageView, destination: Rect, options: drawing.ImageOptions) !void {
        const plan = try drawing.planImage(view, .{ .x = destination.x, .y = destination.y, .width = destination.width, .height = destination.height }, options, self.scale);
        if (self.dc == null) return error.NoSurface;
        if (plan.destination.width == 0 or plan.destination.height == 0 or plan.opacity == 0) return;
        self.images.stats.draws +%= 1;
        if (self.images.stats.dynamic_entries != 0) if (self.images.find(view.identity)) |slot| self.images.touch(slot);
        const r = plan.destination;
        const pixel_origin = self.pixelOrigin();
        const dx = @as(f64, r.x) * self.scale + pixel_origin[0];
        const dy = @as(f64, r.y) * self.scale + pixel_origin[1];
        const dw = @as(f64, r.width) * self.scale;
        const dh = @as(f64, r.height) * self.scale;
        const clip = try self.physicalClip();
        const left = @max(@as(f64, 0), @max(@floor(clip[0]), @floor(dx)));
        const top = @max(@as(f64, 0), @max(@floor(clip[1]), @floor(dy)));
        const right = @min(@as(f64, @floatFromInt(self.width)), @min(@ceil(clip[2]), @ceil(dx + dw)));
        const bottom = @min(@as(f64, @floatFromInt(self.height)), @min(@ceil(clip[3]), @ceil(dy + dh)));
        if (right <= left or bottom <= top) return;
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        const pixels = self.pixels orelse return error.NoSurface;
        var y: u32 = @intFromFloat(top);
        while (y < @as(u32, @intFromFloat(bottom))) : (y += 1) {
            var x: u32 = @intFromFloat(left);
            while (x < @as(u32, @intFromFloat(right))) : (x += 1) {
                const fx: f64 = @floatFromInt(x);
                const fy: f64 = @floatFromInt(y);
                const source_x = plan.source.x + (fx + 0.5 - dx) / dw * plan.source.width;
                const source_y = plan.source.y + (fy + 0.5 - dy) / dh * plan.source.height;
                const sampled = image_sampling.sample(view.levels[plan.level], source_x, source_y, plan.sampling != 0);
                var alpha_coverage = @max(0, @min(fx + 1, dx + dw) - @max(fx, dx)) * @max(0, @min(fy + 1, dy + dh) - @max(fy, dy));
                if (self.layer_workspace != null) alpha_coverage *= windows_layers.rectCoverage(clip, fx, fy);
                const index = @as(usize, y) * self.width + x;
                pixels[index] = if (self.transparent()) image_sampling.overAlpha(sampled, pixels[index], alpha_coverage * plan.opacity) else image_sampling.over(sampled, pixels[index], alpha_coverage * plan.opacity);
            }
        }
    }
    pub fn hasSurface(self: *const Renderer) bool {
        return self.dc != null;
    }

    pub fn begin(self: *Renderer, paint: z.Paint) !void {
        _ = try geometry.validateSurface(paint.size.width, paint.size.height, paint.size.scale);
        if (self.layer_workspace) |workspace| {
            try workspace.begin(paint.size);
            self.bindSurface(workspace.current());
            return;
        }
        if (self.width != paint.size.width or self.height != paint.size.height or self.scale != paint.size.scale) {
            self.releaseSurface();
            errdefer self.releaseSurface();
            self.dc = c.CreateCompatibleDC(@ptrCast(@alignCast(paint.native_context)));
            if (self.dc == null) return error.CreateSurfaceFailed;
            var info = std.mem.zeroes(c.BITMAPINFO);
            info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
            info.bmiHeader.biWidth = @intCast(paint.size.width);
            info.bmiHeader.biHeight = -@as(i32, @intCast(paint.size.height));
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = c.BI_RGB;
            var pixels: ?*anyopaque = null;
            self.bitmap = c.CreateDIBSection(self.dc, &info, c.DIB_RGB_COLORS, &pixels, null, 0);
            if (self.bitmap == null) return error.CreateSurfaceFailed;
            self.pixels = @ptrCast(@alignCast(pixels orelse return error.CreateSurfaceFailed));
            @memset(self.pixels.?[0 .. @as(usize, paint.size.width) * paint.size.height], 0xffffffff);
            const original_bitmap = c.SelectObject(self.dc, self.bitmap);
            if (original_bitmap == null or @intFromPtr(original_bitmap) == std.math.maxInt(usize)) return error.SelectBitmapFailed;
            self.original_bitmap = original_bitmap;
            self.font = c.CreateFontW(@intFromFloat(-16.0 * paint.size.scale), 0, 0, 0, c.FW_NORMAL, c.FALSE, c.FALSE, c.FALSE, c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS, c.CLEARTYPE_QUALITY, c.DEFAULT_PITCH, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"));
            if (self.font == null) return error.CreateFontFailed;
            const original_font = c.SelectObject(self.dc, self.font);
            if (original_font == null or @intFromPtr(original_font) == std.math.maxInt(usize)) return error.SelectFontFailed;
            self.original_font = original_font;
            _ = c.SetBkMode(self.dc, c.TRANSPARENT);
            self.width = paint.size.width;
            self.height = paint.size.height;
            self.scale = paint.size.scale;
        }
    }
    pub fn end(self: *Renderer, paint: z.Paint) void {
        self.endChecked(paint) catch {};
    }
    pub fn endChecked(self: *Renderer, paint: z.Paint) !void {
        if (self.layer_workspace) |workspace| {
            try workspace.commit(paint.native_context);
            self.bindSurface(workspace.front());
            return;
        }
        var clip: c.RECT = undefined;
        const region = c.GetClipBox(paint.native_context, &clip);
        if (region == c.ERROR) return error.PresentSurfaceFailed;
        if (region != c.NULLREGION and c.BitBlt(@ptrCast(@alignCast(paint.native_context)), 0, 0, @intCast(self.width), @intCast(self.height), self.dc, 0, 0, c.SRCCOPY) == 0) return error.PresentSurfaceFailed;
    }
    fn bounds(self: *const Renderer, r: Rect) !c.RECT {
        if (!layout.validRect(r) or !std.math.isFinite(self.scale) or self.scale <= 0) return error.InvalidGeometry;
        const scale: f64 = self.scale;
        const origin = self.pixelOrigin();
        const edges = [_]f64{ @as(f64, r.x) * scale + origin[0], @as(f64, r.y) * scale + origin[1], (@as(f64, r.x) + r.width) * scale + origin[0], (@as(f64, r.y) + r.height) * scale + origin[1] };
        for (edges) |edge| if (!std.math.isFinite(edge) or edge < std.math.minInt(i32) or edge > std.math.maxInt(i32)) return error.InvalidGeometry;
        return .{ .left = @intFromFloat(edges[0]), .top = @intFromFloat(edges[1]), .right = @intFromFloat(edges[2]), .bottom = @intFromFloat(edges[3]) };
    }
    fn color(rgb: u32) u32 {
        return ((rgb >> 16) & 0xff) | (rgb & 0xff00) | ((rgb & 0xff) << 16);
    }
    pub fn fill(self: *Renderer, r: Rect, rgb: u32) !void {
        if (self.layer_workspace != null) {
            const p = try geometry.plan(.{ .bounds = r, .color = geometry.Color.rgb(rgb) });
            _ = try self.bounds(r);
            const rect = self.physicalRect(.{ .x = r.x, .y = r.y, .width = r.width, .height = r.height });
            const clip = try self.physicalClip();
            const region = windows_layers.intersection(rect, clip);
            const size: z.Size = .{ .width = self.width, .height = self.height, .scale = self.scale };
            const box = windows_layers.integerBounds(region, size);
            const pixels = self.pixels orelse return error.NoSurface;
            if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
            const full_left: usize = @intFromFloat(std.math.clamp(@ceil(region[0]), @as(f64, @floatFromInt(box[0])), @as(f64, @floatFromInt(box[2]))));
            const full_right: usize = @intFromFloat(std.math.clamp(@floor(region[2]), @as(f64, @floatFromInt(full_left)), @as(f64, @floatFromInt(box[2]))));
            const argb = 0xff000000 | (rgb & 0xffffff);
            for (box[1]..box[3]) |y| {
                const fy: f64 = @floatFromInt(y);
                const offset = y * self.width;
                const complete_row = fy >= region[1] and fy + 1 <= region[3];
                const interior_left = if (complete_row) full_left else box[2];
                const interior_right = if (complete_row) full_right else box[2];
                @memset(pixels[offset + interior_left .. offset + interior_right], argb);
                for (box[0]..interior_left) |x| self.fillEdge(p, pixels, offset + x, x, y, clip, argb);
                for (interior_right..box[2]) |x| self.fillEdge(p, pixels, offset + x, x, y, clip, argb);
            }
            return;
        }
        var rect = try self.bounds(r);
        _ = c.SetDCBrushColor(self.dc, color(rgb));
        _ = c.FillRect(self.dc, &rect, @ptrCast(@alignCast(c.GetStockObject(c.DC_BRUSH))));
    }
    fn fillEdge(self: *Renderer, p: geometry.Plan, pixels: [*]u32, index: usize, x: usize, y: usize, clip: [4]f64, source: u32) void {
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        const origin = self.pixelOrigin();
        const shape_coverage = geometry.coverage(p, (fx + 0.5 - origin[0]) / self.scale, (fy + 0.5 - origin[1]) / self.scale, 1 / @as(f64, self.scale));
        const amount = @as(f64, @floatFromInt(shape_coverage)) / 255 * windows_layers.rectCoverage(clip, fx, fy);
        pixels[index] = composite.over(source, pixels[index], amount);
    }
    pub fn text(self: *Renderer, r: Rect, utf8: []const u8, rgb: u32) !void {
        return self.textFont(r, utf8, rgb, .{});
    }
    /// The GDI font for `key` at the current scale; null for the default
    /// font already selected into every surface.
    fn variantFont(self: *Renderer, key: commands.FontKey) !c.HFONT {
        const bits: u32 = @bitCast(key);
        for (self.variant_fonts) |entry| if (entry.font != null and entry.key == bits and entry.scale == self.scale) return entry.font;
        const height: c_int = @intFromFloat(@round(-key.size() * self.scale));
        var named: [fonts.max_name_bytes + 1]u16 = undefined;
        const family: [*:0]const u16 = if (key.family != 0) named: {
            const length = std.unicode.utf8ToUtf16Le(&named, fonts.systemName(key.family)) catch 0;
            named[length] = 0;
            break :named named[0..length :0];
        } else if (key.monospace) std.unicode.utf8ToUtf16LeStringLiteral("Consolas") else std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        const font = c.CreateFontW(height, 0, 0, 0, key.weight.value(), @intFromBool(key.italic), c.FALSE, c.FALSE, c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS, c.CLEARTYPE_QUALITY, if (key.monospace) c.FIXED_PITCH else c.DEFAULT_PITCH, family) orelse return error.CreateFontFailed;
        const slot = &self.variant_fonts[self.variant_next];
        // A replaced font is never selected: text restores the default font
        // before returning.
        if (slot.font != null) _ = c.DeleteObject(slot.font);
        slot.* = .{ .key = bits, .scale = self.scale, .font = font };
        self.variant_next = (self.variant_next + 1) % @as(u8, self.variant_fonts.len);
        return font;
    }
    fn releaseVariantFonts(self: *Renderer) void {
        for (&self.variant_fonts) |*entry| {
            if (entry.font != null) _ = c.DeleteObject(entry.font);
            entry.* = .{};
        }
    }
    pub fn textFont(self: *Renderer, r: Rect, utf8: []const u8, rgb: u32, key: commands.FontKey) !void {
        _ = try self.bounds(r);
        var buffer: [2048]u16 = undefined;
        if (utf8.len > buffer.len) return error.TextTooLong;
        const count = try std.unicode.utf8ToUtf16Le(&buffer, utf8);
        const variant: c.HFONT = if (key.isDefault()) null else try self.variantFont(key);
        if (self.layer_workspace) |workspace| {
            const scratch = try workspace.glyph();
            const previous = if (variant) |font| c.SelectObject(scratch.dc, font) else null;
            defer if (previous) |font| {
                _ = c.SelectObject(scratch.dc, font);
            };
            const physical = self.physicalRect(.{ .x = r.x, .y = r.y, .width = r.width, .height = r.height });
            const region = windows_layers.intersection(physical, try self.physicalClip());
            const size: z.Size = .{ .width = self.width, .height = self.height, .scale = self.scale };
            const clear = windows_layers.integerBounds(physical, size);
            const box = windows_layers.integerBounds(region, size);
            if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
            for (clear[1]..clear[3]) |y| @memset(scratch.pixels.?[y * scratch.width + clear[0] .. y * scratch.width + clear[2]], 0);
            _ = c.SetTextColor(scratch.dc, 0xffffff);
            var text_rect = try self.bounds(r);
            _ = c.DrawTextW(scratch.dc, &buffer, @intCast(count), &text_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
            if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
            for (box[1]..box[3]) |y| for (box[0]..box[2]) |x| {
                const index = @as(usize, y) * self.width + x;
                const mask = scratch.pixels.?[@as(usize, y) * scratch.width + x];
                const gray: f64 = @floatFromInt(((mask >> 16) & 255) * 54 + ((mask >> 8) & 255) * 183 + (mask & 255) * 19);
                const amount = gray / 256 * windows_layers.rectCoverage(region, @floatFromInt(x), @floatFromInt(y));
                self.pixels.?[index] = composite.over(composite.tint(rgb, amount), self.pixels.?[index], 1);
            };
            return;
        }
        _ = c.SetTextColor(self.dc, color(rgb));
        var rect = try self.bounds(r);
        const previous = if (variant) |font| c.SelectObject(self.dc, font) else null;
        defer if (previous) |font| {
            _ = c.SelectObject(self.dc, font);
        };
        _ = c.DrawTextW(self.dc, &buffer, @intCast(count), &rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
    }
    pub fn preparedText(self: *Renderer, view: drawing.PreparedTextView, origin: drawing.Point, tint: geometry.Color) !void {
        try view.validate();
        if (view.platform != .windows) return error.PreparedPlatformMismatch;
        if (self.dc == null) return error.NoSurface;
        if (view.coverage.scale != self.scale) return error.PreparedDpiMismatch;
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        if (tint.a == 0) return;
        try self.drawCoverage(view.coverage, origin, tint, view.clip);
    }
    fn drawCoverage(self: *Renderer, mask: drawing.Coverage, origin: drawing.Point, tint: geometry.Color, mask_clip: ?drawing.Rect) !void {
        const pixel_origin = self.pixelOrigin();
        const dx = @as(f64, origin.x) * self.scale + @as(f64, @floatFromInt(mask.origin_x)) + pixel_origin[0];
        const dy = @as(f64, origin.y) * self.scale + @as(f64, @floatFromInt(mask.origin_y)) + pixel_origin[1];
        const clip = try self.physicalClip();
        var left = @max(@as(f64, 0), @max(@floor(clip[0]), @floor(dx)));
        var top = @max(@as(f64, 0), @max(@floor(clip[1]), @floor(dy)));
        var right = @min(@as(f64, @floatFromInt(self.width)), @min(@ceil(clip[2]), @ceil(dx + @as(f64, @floatFromInt(mask.width)))));
        var bottom = @min(@as(f64, @floatFromInt(self.height)), @min(@ceil(clip[3]), @ceil(dy + @as(f64, @floatFromInt(mask.height)))));
        var viewport: ?[4]f64 = null;
        if (mask_clip) |r| {
            viewport = .{ (@as(f64, origin.x) + r.x) * self.scale + pixel_origin[0], (@as(f64, origin.y) + r.y) * self.scale + pixel_origin[1], (@as(f64, origin.x) + r.x + r.width) * self.scale + pixel_origin[0], (@as(f64, origin.y) + r.y + r.height) * self.scale + pixel_origin[1] };
            left = @max(left, @floor(viewport.?[0]));
            top = @max(top, @floor(viewport.?[1]));
            right = @min(right, @ceil(viewport.?[2]));
            bottom = @min(bottom, @ceil(viewport.?[3]));
        }
        if (right <= left or bottom <= top) return;
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        const pixels = self.pixels orelse return error.NoSurface;
        var y: u32 = @intFromFloat(top);
        while (y < @as(u32, @intFromFloat(bottom))) : (y += 1) {
            var x: u32 = @intFromFloat(left);
            while (x < @as(u32, @intFromFloat(right))) : (x += 1) {
                const sx = @as(f64, @floatFromInt(x)) - dx;
                const sy = @as(f64, @floatFromInt(y)) - dy;
                // Translation reuses the prepared grid; fractional origins use
                // bilinear alpha_coverage, never a new glyph raster or layout.
                const x0: i64 = @intFromFloat(@floor(sx));
                const y0: i64 = @intFromFloat(@floor(sy));
                const fx = sx - @floor(sx);
                const fy = sy - @floor(sy);
                var alpha_coverage: f64 = 0;
                for (0..2) |iy| for (0..2) |ix| {
                    const mx = x0 + @as(i64, @intCast(ix));
                    const my = y0 + @as(i64, @intCast(iy));
                    if (mx < 0 or my < 0 or mx >= mask.width or my >= mask.height) continue;
                    alpha_coverage += @as(f64, @floatFromInt(mask.pixels[@as(usize, @intCast(my)) * mask.stride + @as(usize, @intCast(mx))])) * (if (ix == 0) 1 - fx else fx) * (if (iy == 0) 1 - fy else fy);
                };
                if (viewport) |v| {
                    alpha_coverage *= @max(0, @min(@as(f64, @floatFromInt(x + 1)), v[2]) - @max(@as(f64, @floatFromInt(x)), v[0]));
                    alpha_coverage *= @max(0, @min(@as(f64, @floatFromInt(y + 1)), v[3]) - @max(@as(f64, @floatFromInt(y)), v[1]));
                }
                if (self.layer_workspace != null) alpha_coverage *= windows_layers.rectCoverage(clip, @floatFromInt(x), @floatFromInt(y));
                const alpha: u32 = @intFromFloat(@round(alpha_coverage * @as(f64, @floatFromInt(tint.a)) / 255));
                if (alpha == 0) continue;
                const index = @as(usize, y) * self.width + x;
                const before = pixels[index];
                if (self.transparent()) {
                    pixels[index] = composite.overFull(composite.tintByte((@as(u32, tint.r) << 16) | (@as(u32, tint.g) << 8) | tint.b, alpha), before);
                    continue;
                }
                const inverse = 255 - alpha;
                const red = (@as(u32, tint.r) * alpha + ((before >> 16) & 255) * inverse + 127) / 255;
                const green = (@as(u32, tint.g) * alpha + ((before >> 8) & 255) * inverse + 127) / 255;
                const blue = (@as(u32, tint.b) * alpha + (before & 255) * inverse + 127) / 255;
                pixels[index] = 0xff000000 | (red << 16) | (green << 8) | blue;
            }
        }
    }
    fn shape(self: *Renderer, value: geometry.Shape, gradient: ?*const commands.brushes.Stored) !void {
        const p = try geometry.plan(value);
        _ = try self.bounds(p.bounds);
        if (p.color.a == 0 or p.bounds.width == 0 or p.bounds.height == 0) return;
        if (gradient) |brush| if (brush.isTransparent()) return;
        const clip = try self.physicalClip();
        // GDI batches opaque fills/text. Complete them before reading the same
        // DIB through its explicitly owned CPU pixel pointer.
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        if (gradient) |brush| {
            const surface: cpu_gradient.Surface = .{ .pixels = self.pixels orelse return error.NoSurface, .width = self.width, .height = self.height, .stride = self.width, .scale = self.scale, .clip = clip, .origin = self.pixelOrigin() };
            _ = if (self.transparent()) cpu_gradient.drawTransparent(surface, p, brush) else cpu_gradient.draw(surface, p, brush);
            return;
        }
        const scale: f64 = self.scale;
        const pixel_origin = self.pixelOrigin();
        const left: i32 = @intFromFloat(@max(0, @max(@floor(clip[0]), @floor(@as(f64, p.bounds.x) * scale + pixel_origin[0]))));
        const top: i32 = @intFromFloat(@max(0, @max(@floor(clip[1]), @floor(@as(f64, p.bounds.y) * scale + pixel_origin[1]))));
        const right: i32 = @intFromFloat(@min(@as(f64, @floatFromInt(self.width)), @min(@ceil(clip[2]), @ceil((@as(f64, p.bounds.x) + p.bounds.width) * scale + pixel_origin[0]))));
        const bottom: i32 = @intFromFloat(@min(@as(f64, @floatFromInt(self.height)), @min(@ceil(clip[3]), @ceil((@as(f64, p.bounds.y) + p.bounds.height) * scale + pixel_origin[1]))));
        if (right <= left or bottom <= top) return;
        const pixels = self.pixels orelse return error.NoSurface;
        const transparent_target = self.transparent();
        const partial_clip = self.layer_workspace != null and (@as(f64, @floatFromInt(left)) < clip[0] or @as(f64, @floatFromInt(top)) < clip[1] or @as(f64, @floatFromInt(right)) > clip[2] or @as(f64, @floatFromInt(bottom)) > clip[3]);
        var y = top;
        while (y < bottom) : (y += 1) {
            var x = left;
            while (x < right) : (x += 1) {
                var alpha_coverage: u32 = geometry.coverage(p, (@as(f64, @floatFromInt(x)) + 0.5 - pixel_origin[0]) / scale, (@as(f64, @floatFromInt(y)) + 0.5 - pixel_origin[1]) / scale, 1 / scale);
                if (partial_clip) alpha_coverage = @intFromFloat(@round(@as(f64, @floatFromInt(alpha_coverage)) * windows_layers.rectCoverage(clip, @floatFromInt(x), @floatFromInt(y))));
                const index = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
                const alpha = (@as(u32, p.color.a) * alpha_coverage + 127) / 255;
                if (alpha == 0) continue;
                const before = pixels[index];
                if (transparent_target) {
                    pixels[index] = composite.overFull(composite.tintByte((@as(u32, p.color.r) << 16) | (@as(u32, p.color.g) << 8) | p.color.b, alpha), before);
                    continue;
                }
                const inverse = 255 - alpha;
                const red = (@as(u32, p.color.r) * alpha + ((before >> 16) & 255) * inverse + 127) / 255;
                const green = (@as(u32, p.color.g) * alpha + ((before >> 8) & 255) * inverse + 127) / 255;
                const blue = (@as(u32, p.color.b) * alpha + (before & 255) * inverse + 127) / 255;
                pixels[index] = 0xff000000 | (red << 16) | (green << 8) | blue;
            }
        }
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
        const layer_plan: ?layers.Plan = if (self.layer_workspace) |workspace| workspace.plan else null;
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
        defer while (self.layer_workspace == null and depth != 0) : (depth -= 1) {
            _ = c.RestoreDC(self.dc, -1);
        };
        var index: usize = 0;
        while (index < list.len) : (index += 1) switch (list[index]) {
            .fill => |fill_command| try self.fill(fill_command.bounds, fill_command.color),
            .shape => |shape_command| try self.shape(shape_command, null),
            .gradient => |value| {
                if (value.brush >= resources.len) return error.MissingResources;
                try self.shape(.{ .bounds = value.bounds, .radius = value.radius, .stroke_width = value.stroke_width, .color = geometry.Color.rgb(0) }, &resources[value.brush]);
            },
            .text => |text_command| {
                if (text_command.offset > text_bytes.len or text_command.len > text_bytes.len - text_command.offset) return error.InvalidTextRange;
                try self.textFont(text_command.bounds, text_bytes[text_command.offset..][0..text_command.len], text_command.color, text_command.font);
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
                const group_bounds: drawing.Rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
                const options = try commands.groupOptions(value, coverage_resources);
                if (value.filter_slot == commands.no_filter) try self.beginGroup(group_bounds, options) else try self.beginGaussian(group_bounds, options, filters[value.filter_slot]);
            },
            .end_group => try self.endGroup(),
            .effect => |slot| {
                const source = self.backdrop_source orelse return error.MissingResources;
                if (slot >= source.shader_storage.len) return error.MissingResources;
                const entry = &source.shader_storage.entries[slot];
                const effect_end = commands.effectEnd(list, index) orelse return error.UnbalancedEffects;
                if (try self.captureEffect(entry)) {
                    self.effect_scopes[self.effect_count] = .{ .entry = entry, .workspace = source.shader_storage.workspace };
                    self.effect_count += 1;
                } else {
                    try self.isolateEffect(list[index + 1 .. effect_end], entry, all);
                    index = effect_end;
                }
            },
            .end_effect => {
                if (self.effect_count == 0) return error.UnbalancedEffects;
                self.effect_count -= 1;
                const workspace = self.layer_workspace orelse return error.LayersRequired;
                try workspace.endGroupFiltered(.{ .context = &self.effect_scopes[self.effect_count], .run = runEffect });
                self.bindSurface(workspace.current());
            },
            .backdrop_shader => |slot| {
                const source = self.backdrop_source orelse return error.MissingResources;
                if (slot >= source.shader_storage.len) return error.MissingResources;
                const surface = try self.targetSurface();
                const scratch = if (source.backdrop_storage.workspace) |workspace| workspace.planes else null;
                _ = commands.shader_effects.applyBackdrop(surface, self.transparent(), &source.shader_storage.entries[slot], scratch, source.shader_storage.workspace);
            },
            .begin_transform => |slot| try self.beginTransform(transforms[slot]),
            .end_transform => try self.endTransform(),
            .backdrop => |slot| {
                const source = self.backdrop_source orelse return error.MissingResources;
                if (slot >= source.backdrop_storage.len) return error.MissingResources;
                const clip = try self.physicalClip();
                // Complete batched GDI drawing before reading the DIB.
                if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
                const surface: cpu_gradient.Surface = .{ .pixels = self.pixels orelse return error.NoSurface, .width = self.width, .height = self.height, .stride = self.width, .scale = self.scale, .clip = clip, .origin = self.pixelOrigin() };
                _ = commands.backdrop.apply(surface, self.transparent(), source.backdrop_storage.entries[slot], source.backdrop_storage.workspace);
            },
            .indicator => |slot| {
                const source = self.backdrop_source orelse return error.MissingResources;
                if (slot >= source.indicator_len) return error.MissingResources;
                const clip = try self.physicalClip();
                if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
                const surface: cpu_gradient.Surface = .{ .pixels = self.pixels orelse return error.NoSurface, .width = self.width, .height = self.height, .stride = self.width, .scale = self.scale, .clip = clip, .origin = self.pixelOrigin() };
                _ = commands.loading.draw(surface, self.transparent(), source.indicator_storage[slot]);
            },
            .push_clip => |clip| {
                if (depth == 32) return error.ClipStackFull;
                if (self.layer_workspace) |workspace| {
                    try workspace.pushClip(.{ .x = clip.x, .y = clip.y, .width = clip.width, .height = clip.height });
                    depth += 1;
                    continue;
                }
                if (c.SaveDC(self.dc) == 0) return error.SaveClipFailed;
                depth += 1;
                const rect = try self.bounds(clip);
                if (c.IntersectClipRect(self.dc, rect.left, rect.top, rect.right, rect.bottom) == c.ERROR) return error.SetClipFailed;
            },
            .pop_clip => {
                if (depth == 0) return error.ClipStackEmpty;
                if (self.layer_workspace) |workspace| {
                    try workspace.popClip();
                    depth -= 1;
                    continue;
                }
                if (c.RestoreDC(self.dc, -1) == 0) return error.RestoreClipFailed;
                depth -= 1;
            },
        };
        if (depth != 0) return error.UnbalancedClips;
    }
    pub fn deinit(self: *Renderer) void {
        self.releaseVariantFonts();
        if (self.layer_workspace) |workspace| {
            workspace.deinit();
            self.layer_workspace = null;
        } else self.releaseSurface();
        self.images.deinit();
        self.* = .{};
    }
    fn releaseSurface(self: *Renderer) void {
        if (self.original_font != null) _ = c.SelectObject(self.dc, self.original_font);
        if (self.original_bitmap != null) _ = c.SelectObject(self.dc, self.original_bitmap);
        if (self.font != null) _ = c.DeleteObject(self.font);
        if (self.bitmap != null) _ = c.DeleteObject(self.bitmap);
        if (self.dc != null) _ = c.DeleteDC(self.dc);
        self.original_font = null;
        self.original_bitmap = null;
        self.font = null;
        self.bitmap = null;
        self.dc = null;
        self.pixels = null;
        self.width = 0;
        self.height = 0;
        self.scale = 0;
    }
};

test "GDI bounds reject finite pixel overflow before integer conversion" {
    var renderer: Renderer = .{ .scale = 3 };
    const good = try renderer.bounds(.{ .x = -2, .y = 3, .width = 5, .height = 7 });
    try std.testing.expectEqual(-6, good.left);
    try std.testing.expectEqual(9, good.right);
    for ([_]Rect{
        .{ .x = 1e20, .y = 0, .width = 10, .height = 10 },
        .{ .x = 1e9, .y = 0, .width = 10, .height = 10 },
        .{ .x = std.math.floatMax(f32), .y = 0, .width = std.math.floatMax(f32), .height = 1 },
        .{ .x = 0, .y = 0, .width = -1, .height = 1 },
    }) |invalid| try std.testing.expectError(error.InvalidGeometry, renderer.bounds(invalid));
    renderer.scale = 1;
    try std.testing.expectError(error.InvalidGeometry, renderer.bounds(.{ .x = 2147483648, .y = 0, .width = 1, .height = 1 }));
    const edge = try renderer.bounds(.{ .x = -2147483648, .y = 0, .width = 0, .height = 0 });
    try std.testing.expectEqual(std.math.minInt(i32), edge.left);
}

test "GDI raster scopes preserve guarded fractional edges and larger nested sources" {
    var renderer: Renderer = .{};
    defer renderer.deinit();
    const size: z.Size = .{ .width = 8, .height = 8, .scale = 1 };
    try renderer.prepareTransforms(std.testing.allocator, .{ .layers = .{ .size = size }, .source_size = .{ .width = 20, .height = 20 } });
    try renderer.beginOffscreen();
    try renderer.beginTransform(try layers.NativeTransform.init(.{ .x0 = 2.5, .y0 = 2 }, .{ .width = 2, .height = 2 }, 1));
    try renderer.fill(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, 0xff0000);
    try renderer.endTransform();
    var output: [8 * 8 * 4]u8 = undefined;
    try renderer.endOffscreen(&output);
    try std.testing.expectEqual(@as(u32, 0x80800000), std.mem.readInt(u32, output[(2 * 8 + 2) * 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, output[(2 * 8 + 3) * 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x80800000), std.mem.readInt(u32, output[(2 * 8 + 4) * 4 ..][0..4], .little));
    try renderer.beginOffscreen();
    try renderer.beginTransform(try layers.NativeTransform.init(.{ .xx = 0.25, .yy = 0.25 }, .{ .width = 20, .height = 20 }, 1));
    try renderer.beginGroup(.{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{});
    try renderer.fill(.{ .x = 12, .y = 12, .width = 4, .height = 4 }, 0x0000ff);
    try renderer.endGroup();
    try renderer.endTransform();
    try renderer.endOffscreen(&output);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), std.mem.readInt(u32, output[(3 * 8 + 3) * 4 ..][0..4], .little));
}

test "GDI invalid frame restores clip and keeps the renderer usable" {
    const destination = c.CreateCompatibleDC(null) orelse return error.CreateSurfaceFailed;
    defer _ = c.DeleteDC(destination);
    const bitmap = c.CreateCompatibleBitmap(destination, 32, 32) orelse return error.CreateSurfaceFailed;
    defer _ = c.DeleteObject(bitmap);
    const original = c.SelectObject(destination, bitmap);
    defer _ = c.SelectObject(destination, original);
    var renderer: Renderer = .{};
    defer renderer.deinit();
    try renderer.begin(.{ .native_context = destination, .size = .{ .width = 32, .height = 32, .scale = 1 } });
    var buffer: commands.Buffer = .{};
    try buffer.pushClip(.{ .x = 1, .y = 1, .width = 5, .height = 5 });
    try buffer.fill(.{ .x = 1e20, .y = 0, .width = 10, .height = 10 }, 0);
    try buffer.popClip();
    try std.testing.expectError(error.InvalidGeometry, renderer.replay(buffer.commands(), buffer.textBytes()));
    var box: c.RECT = undefined;
    try std.testing.expect(c.GetClipBox(renderer.dc, &box) != c.ERROR);
    try std.testing.expectEqual(0, box.left);
    try std.testing.expectEqual(32, box.right);
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, 0xffffff);
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try std.testing.expectEqual(@as(c.COLORREF, 0xffffff), c.GetPixel(renderer.dc, 20, 20));
}

test "GDI layers draw premultiplied shapes and grayscale text without committing failed frames" {
    const size: z.Size = .{ .width = 64, .height = 48, .scale = 1 };
    var destination = try windows_layers.Surface.init(size, null, null);
    defer destination.deinit();
    var renderer: Renderer = .{};
    defer renderer.deinit();
    try renderer.prepareLayers(std.testing.allocator, .{ .size = size });
    const paint: z.Paint = .{ .native_context = destination.dc.?, .size = size };
    try renderer.begin(paint);
    try renderer.beginGroup(.{ .x = 0, .y = 0, .width = 32, .height = 20 }, .{ .opacity = 128 });
    var buffer: commands.Buffer = .{};
    defer buffer.reset();
    try buffer.roundedRect(.{ .x = 2, .y = 2, .width = 12, .height = 12 }, 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try buffer.roundedRect(.{ .x = 8, .y = 2, .width = 12, .height = 12 }, 0, .{ .r = 0, .g = 0, .b = 255, .a = 128 });
    try renderer.replayBuffer(&buffer);
    try std.testing.expectEqual(@as(u32, 0xc0400080), renderer.pixels.?[6 * 64 + 10]);
    try renderer.endGroup();
    const expected = composite.over(0xc0400080, 0xffffffff, 128.0 / 255.0);
    try std.testing.expectEqual(expected, renderer.pixels.?[6 * 64 + 10]);
    try renderer.beginGroup(.{ .x = 0, .y = 20, .width = 64, .height = 28 }, .{ .opacity = 180 });
    try renderer.text(.{ .x = 2, .y = 20, .width = 60, .height = 24 }, "Text", 0x204060);
    var ink: usize = 0;
    for (renderer.pixels.?[20 * 64 .. 48 * 64]) |pixel| {
        const alpha = pixel >> 24;
        if (alpha == 0) continue;
        ink += 1;
        try std.testing.expect(((pixel >> 16) & 255) <= alpha and ((pixel >> 8) & 255) <= alpha and (pixel & 255) <= alpha);
    }
    try std.testing.expect(ink > 10);
    try renderer.endGroup();
    try renderer.endChecked(paint);
    try std.testing.expectEqual(expected, renderer.pixels.?[6 * 64 + 10]);
    const objects = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
    try renderer.begin(paint);
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, 0);
    try buffer.fill(.{ .x = 1e20, .y = 0, .width = 4, .height = 4 }, 0);
    try std.testing.expectError(error.InvalidGeometry, renderer.replayBuffer(&buffer));
    try std.testing.expectError(error.NotDrawing, renderer.endChecked(paint));
    try std.testing.expectEqual(expected, renderer.pixels.?[6 * 64 + 10]);
    try std.testing.expectEqual(objects, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
    try renderer.releaseLayers();
    var metrics: c.TEXTMETRICW = undefined;
    try std.testing.expect(c.GetTextMetricsW(renderer.dc, &metrics) != 0);
    try std.testing.expect(metrics.tmHeight >= 12);
}

test "prepared opaque row fill preserves shape AA and fractional clip on transparent planes" {
    var renderer: Renderer = .{};
    defer renderer.deinit();
    const allocator = std.testing.allocator;
    const reference = try allocator.alloc(u32, 32 * 32);
    defer allocator.free(reference);
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const size: z.Size = .{ .width = 32, .height = 32, .scale = scale };
        try renderer.prepareLayers(allocator, .{ .size = size });
        for ([_]f32{ 0, 0.125, 0.25, 0.5, 0.75, -0.25 }) |fraction| {
            for ([_]bool{ false, true }) |fast| {
                try renderer.begin(.{ .native_context = renderer.dc.?, .size = size });
                try renderer.beginGroup(.{ .x = 0, .y = 0, .width = 32 / scale, .height = 32 / scale }, .{});
                @memset(renderer.pixels.?[0 .. 32 * 32], 0x80400080);
                const clip: drawing.Rect = .{ .x = (2 + fraction) / scale, .y = (1 + fraction) / scale, .width = 17.5 / scale, .height = 19.25 / scale };
                try renderer.layer_workspace.?.pushClip(clip);
                const shape_bounds: Rect = .{ .x = (3 + fraction) / scale, .y = (2 + fraction) / scale, .width = 18.25 / scale, .height = 18.5 / scale };
                if (fast) try renderer.fill(shape_bounds, 0x20cc70) else try renderer.shape(.{ .bounds = shape_bounds, .color = geometry.Color.rgb(0x20cc70) }, null);
                if (fast) {
                    for (reference, renderer.pixels.?[0 .. 32 * 32]) |expected, actual| inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                        const a: i32 = @intCast((expected >> shift) & 255);
                        const b: i32 = @intCast((actual >> shift) & 255);
                        try std.testing.expect(@abs(a - b) <= 1);
                    };
                } else @memcpy(reference, renderer.pixels.?[0 .. 32 * 32]);
                renderer.abort();
            }
        }
    }
}

test "GDI text follows the command font and reuses its fonts" {
    const destination = c.CreateCompatibleDC(null) orelse return error.CreateSurfaceFailed;
    defer _ = c.DeleteDC(destination);
    var renderer: Renderer = .{};
    defer renderer.deinit();
    try renderer.begin(.{ .native_context = destination, .size = .{ .width = 160, .height = 48, .scale = 1 } });
    const Ink = struct {
        fn measure(target: *Renderer, font: commands.Font) !usize {
            var buffer: commands.Buffer = .{};
            try buffer.fill(.{ .x = 0, .y = 0, .width = 160, .height = 48 }, 0xffffff);
            try buffer.textFont(.{ .x = 0, .y = 0, .width = 160, .height = 48 }, "Wide", 0, font);
            try target.replay(buffer.commands(), buffer.textBytes());
            if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
            var dark: usize = 0;
            for (target.pixels.?[0 .. 160 * 48]) |pixel| {
                if (pixel & 0xff < 0x80) dark += 1;
            }
            return dark;
        }
    };
    const body = try Ink.measure(&renderer, .body);
    const heading = try Ink.measure(&renderer, .heading1);
    const objects = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
    try std.testing.expectEqual(heading, try Ink.measure(&renderer, .heading1));
    try std.testing.expectEqual(objects, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
    try std.testing.expect(body > 0);
    try std.testing.expect(heading > body * 2);
    try std.testing.expect(try Ink.measure(&renderer, .{ .weight = .bold }) > body);
    try std.testing.expectEqual(body, try Ink.measure(&renderer, .{}));
}

test "GDI backdrop effects filter the plane drawn so far and fall back without a workspace" {
    const destination = c.CreateCompatibleDC(null) orelse return error.CreateSurfaceFailed;
    defer _ = c.DeleteDC(destination);
    const bitmap = c.CreateCompatibleBitmap(destination, 32, 16) orelse return error.CreateSurfaceFailed;
    defer _ = c.DeleteObject(bitmap);
    const original = c.SelectObject(destination, bitmap);
    defer _ = c.SelectObject(destination, original);
    var renderer: Renderer = .{};
    defer renderer.deinit();
    try renderer.begin(.{ .native_context = destination, .size = .{ .width = 32, .height = 16, .scale = 1 } });
    const workspace = try commands.backdrop.Workspace.create(std.testing.allocator, .{ .max_pixels = 32 * 16 });
    defer workspace.destroy();
    var buffer: commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, 0x000000);
    try buffer.fill(.{ .x = 16, .y = 0, .width = 16, .height = 16 }, 0xffffff);
    try buffer.backdropEffect(.{ .bounds = .{ .x = 8, .y = 0, .width = 16, .height = 16 }, .kind = .blur, .sigma = 2, .fallback = .rgb(0xff0000) });
    buffer.backdrop_storage.workspace = workspace;
    try renderer.replayBuffer(&buffer);
    const left = renderer.pixels.?[8 * 32 + 15] & 255;
    try std.testing.expect(left > 40 and left < 128);
    try std.testing.expectEqual(@as(u32, 0), renderer.pixels.?[8 * 32 + 7] & 0xffffff);
    try std.testing.expectEqual(@as(u64, 1), workspace.stats.applied);
    buffer.backdrop_storage.workspace = null;
    try renderer.replayBuffer(&buffer);
    try std.testing.expectEqual(@as(u32, 0xff0000), renderer.pixels.?[8 * 32 + 15] & 0xffffff);
}
