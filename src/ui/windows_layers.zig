const std = @import("std");
const z = @import("ziggurat");
const layers = @import("layers.zig");
const composite = @import("composite.zig");
const transform_composite = @import("transform_composite.zig");
const drawing = @import("ziggurat_drawing_resources");
const gaussian_scope = @import("gaussian_scope.zig");
const gaussian_workspace = @import("gaussian_workspace.zig");
const gaussian_kernel = @import("gaussian_kernel.zig");
const gaussian_composite = @import("gaussian_composite.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
/// Replaces a capture's Gaussian filter: rewrites the capture's planes in
/// place, given each plane's stride in pixels.
pub const CaptureFilter = struct {
    context: *const anyopaque,
    run: *const fn (context: *const anyopaque, source: []u32, source_stride: usize, scratch: []u32, scratch_stride: usize, capture: gaussian_scope.Capture) void,
};
pub const Surface = struct {
    dc: c.HDC = null,
    bitmap: c.HBITMAP = null,
    pixels: ?[*]u32 = null,
    original_bitmap: c.HGDIOBJ = null,
    font: c.HFONT = null,
    original_font: c.HGDIOBJ = null,
    owns_font: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    origin: [2]f64 = .{ 0, 0 },
    clips: [33][4]f64 = undefined,
    clip_depth: usize = 0,
    pub fn init(size: z.Size, quality: ?u32, borrowed_font: c.HFONT) !Surface {
        var self: Surface = .{ .width = size.width, .height = size.height };
        errdefer self.deinit();
        self.dc = c.CreateCompatibleDC(null);
        if (self.dc == null) return error.CreateSurfaceFailed;
        var info = std.mem.zeroes(c.BITMAPINFO);
        info.bmiHeader = .{ .biSize = @sizeOf(c.BITMAPINFOHEADER), .biWidth = @intCast(size.width), .biHeight = -@as(i32, @intCast(size.height)), .biPlanes = 1, .biBitCount = 32, .biCompression = c.BI_RGB, .biSizeImage = 0, .biXPelsPerMeter = 0, .biYPelsPerMeter = 0, .biClrUsed = 0, .biClrImportant = 0 };
        var pixels: ?*anyopaque = null;
        self.bitmap = c.CreateDIBSection(self.dc, &info, c.DIB_RGB_COLORS, &pixels, null, 0);
        if (self.bitmap == null) return error.CreateSurfaceFailed;
        self.pixels = @ptrCast(@alignCast(pixels orelse return error.CreateSurfaceFailed));
        self.original_bitmap = c.SelectObject(self.dc, self.bitmap);
        if (self.original_bitmap == null or @intFromPtr(self.original_bitmap) == std.math.maxInt(usize)) {
            self.original_bitmap = null;
            return error.SelectBitmapFailed;
        }
        self.font = borrowed_font;
        if (quality) |value| {
            self.font = c.CreateFontW(@intFromFloat(-16.0 * size.scale), 0, 0, 0, c.FW_NORMAL, c.FALSE, c.FALSE, c.FALSE, c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS, value, c.DEFAULT_PITCH, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"));
            if (self.font == null) return error.CreateFontFailed;
            self.owns_font = true;
        }
        if (self.font != null) {
            self.original_font = c.SelectObject(self.dc, self.font);
            if (self.original_font == null or @intFromPtr(self.original_font) == std.math.maxInt(usize)) {
                self.original_font = null;
                return error.SelectFontFailed;
            }
        }
        _ = c.SetBkMode(self.dc, c.TRANSPARENT);
        @memset(self.pixels.?[0 .. @as(usize, size.width) * size.height], 0);
        self.clips[0] = .{ 0, 0, @floatFromInt(size.width), @floatFromInt(size.height) };
        return self;
    }
    pub fn deinit(self: *Surface) void {
        if (self.original_font != null) _ = c.SelectObject(self.dc, self.original_font);
        if (self.original_bitmap != null) _ = c.SelectObject(self.dc, self.original_bitmap);
        if (self.owns_font and self.font != null) _ = c.DeleteObject(self.font);
        if (self.bitmap != null) _ = c.DeleteObject(self.bitmap);
        if (self.dc != null) _ = c.DeleteDC(self.dc);
        self.* = .{};
    }
    pub fn clip(self: *const Surface) [4]f64 {
        return self.clips[self.clip_depth];
    }
};
const Group = union(enum) { group: struct { bounds: [4]f64, options: layers.Group }, transform: layers.NativeTransform };
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    plan: layers.Plan,
    surfaces: [layers.max_depth + 3]Surface = @splat(.{}),
    groups: [layers.max_depth]Group = undefined,
    front_index: usize = 0,
    work_index: usize = 1,
    depth: usize = 0,
    active: bool = false,
    transparent_root: bool = false,
    front_transparent: bool = false,
    stats: layers.Stats = .{},
    gaussian: ?*gaussian_workspace.Owner = null,
    pub fn create(allocator: std.mem.Allocator, options: layers.Options) !*Workspace {
        return createWithFailure(allocator, options, 0);
    }
    pub fn createWithFailure(allocator: std.mem.Allocator, options: layers.Options, fault: u32) !*Workspace {
        const plan = try layers.Plan.init(options, .gdi);
        return createPlan(allocator, plan, fault);
    }
    pub fn createPlan(allocator: std.mem.Allocator, plan: layers.Plan, fault: u32) !*Workspace {
        const options = plan.options;
        const self = try allocator.create(Workspace);
        self.* = .{ .allocator = allocator, .plan = plan };
        errdefer self.deinit();
        if (fault == 1) return error.OutOfMemory;
        self.surfaces[0] = try Surface.init(options.size, c.CLEARTYPE_QUALITY, null);
        for (self.surfaces[1 .. options.max_depth + 2], 1..) |*surface, i| {
            if (fault == i + 1) return error.OutOfMemory;
            surface.* = try Surface.init(if (i < 2) options.size else plan.pool_size, null, self.surfaces[0].font);
        }
        if (options.legacy_text == .grayscale) {
            if (fault == options.max_depth + 3) return error.OutOfMemory;
            self.surfaces[options.max_depth + 2] = try Surface.init(plan.pool_size, c.ANTIALIASED_QUALITY, null);
        }
        @memset(self.surfaces[0].pixels.?[0 .. plan.plane_bytes / 4], 0xffffffff);
        self.stats = .{ .prepared = true, .pixel_bytes = plan.pixel_bytes, .plane_bytes = plan.plane_bytes, .planes = plan.planes, .max_depth = options.max_depth, .native_objects = @as(u32, plan.planes) * 2 + 1 + @as(u32, @intFromBool(options.legacy_text == .grayscale)), .candidate_peak_bytes = plan.pixel_bytes, .metadata_bytes = @sizeOf(Workspace) };
        self.stats.native_creations = self.stats.native_objects;
        return self;
    }
    pub fn deinit(self: *Workspace) void {
        // Borrowed fonts must leave every work DC before the owning front font.
        for (self.surfaces[1..]) |*surface| surface.deinit();
        self.surfaces[0].deinit();
        if (self.gaussian) |owner| owner.close();
        self.allocator.destroy(self);
    }
    pub fn prepareGaussian(self: *Workspace, plan: gaussian_scope.Plan) !void {
        std.debug.assert(self.gaussian == null and !self.active);
        self.gaussian = try gaussian_workspace.Owner.create(self.allocator, plan);
        self.stats.pixel_bytes = plan.pixel_bytes;
        self.stats.metadata_bytes += @sizeOf(gaussian_workspace.Owner);
    }
    pub fn current(self: *Workspace) *Surface {
        return &self.surfaces[if (self.depth == 0) self.work_index else self.depth + 1];
    }
    pub fn front(self: *Workspace) *Surface {
        return &self.surfaces[self.front_index];
    }
    pub fn takeFront(self: *Workspace) Surface {
        std.debug.assert(!self.active);
        var result = self.front().*;
        if (!result.owns_font) {
            result.owns_font = true;
            self.surfaces[0].owns_font = false;
        }
        self.front().* = .{};
        return result;
    }
    pub fn begin(self: *Workspace, size: z.Size) !void {
        try self.beginMode(size, false);
    }
    pub fn beginOffscreen(self: *Workspace) !void {
        if (self.active) return error.AlreadyDrawing;
        try self.beginMode(self.plan.options.size, true);
    }
    fn beginMode(self: *Workspace, size: z.Size, transparent_root: bool) !void {
        if (!self.plan.matches(size)) return error.LayersRequired;
        if (self.active) {
            if (self.transparent_root != transparent_root) return error.SurfaceModeMismatch;
            return;
        }
        self.active = true;
        self.transparent_root = transparent_root;
        self.depth = 0;
        if (self.gaussian) |owner| {
            owner.active = 0;
            owner.visits = 0;
        }
        const surface = self.current();
        surface.clip_depth = 0;
        surface.origin = .{ 0, 0 };
        surface.clips[0] = .{ 0, 0, @floatFromInt(size.width), @floatFromInt(size.height) };
        @memset(surface.pixels.?[0 .. self.plan.plane_bytes / 4], if (transparent_root) 0 else 0xffffffff);
        self.stats.clear_pixels +%= self.plan.plane_bytes / 4;
    }
    pub fn commitOffscreen(self: *Workspace, output: []u8) !void {
        if (!self.active) return error.NotDrawing;
        if (!self.transparent_root) return error.SurfaceModeMismatch;
        if (self.depth != 0 or self.current().clip_depth != 0) return error.UnbalancedGroups;
        if (output.len != self.plan.plane_bytes) return error.InvalidOutputSize;
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        const bytes = std.mem.sliceAsBytes(self.current().pixels.?[0 .. self.plan.plane_bytes / 4]);
        @memcpy(output, bytes);
        std.mem.swap(usize, &self.front_index, &self.work_index);
        self.front_transparent = true;
        self.active = false;
        self.stats.committed_frames +%= 1;
    }
    pub fn abort(self: *Workspace) void {
        if (self.active) {
            self.stats.aborted_frames +%= 1;
            self.active = false;
            self.depth = 0;
        }
    }
    pub fn commit(self: *Workspace, destination: ?*anyopaque) !void {
        if (!self.active) return error.NotDrawing;
        if (self.transparent_root) return error.SurfaceModeMismatch;
        if (self.depth != 0) {
            self.abort();
            return error.UnbalancedGroups;
        }
        const size = self.plan.options.size;
        var clip: c.RECT = undefined;
        const region = c.GetClipBox(destination, &clip);
        if (region == c.ERROR) {
            self.abort();
            return error.PresentSurfaceFailed;
        }
        // A hidden or fully occluded window has no destination pixels.
        if (region != c.NULLREGION and c.BitBlt(destination, 0, 0, @intCast(size.width), @intCast(size.height), self.current().dc, 0, 0, c.SRCCOPY) == 0) {
            self.abort();
            return error.PresentSurfaceFailed;
        }
        std.mem.swap(usize, &self.front_index, &self.work_index);
        self.front_transparent = false;
        self.active = false;
        self.stats.committed_frames +%= 1;
    }
    pub fn pushClip(self: *Workspace, r: drawing.Rect) !void {
        const surface = self.current();
        if (surface.clip_depth == 32) return error.ClipStackFull;
        const before = surface.clip();
        surface.clip_depth += 1;
        surface.clips[surface.clip_depth] = intersection(before, self.physicalRect(r));
    }
    pub fn popClip(self: *Workspace) !void {
        const surface = self.current();
        if (surface.clip_depth == 0) return error.ClipStackEmpty;
        surface.clip_depth -= 1;
    }
    pub fn beginGroup(self: *Workspace, bounds: drawing.Rect, options: layers.Group) !void {
        if (!self.active) return error.NotDrawing;
        if (self.depth == self.plan.options.max_depth) return error.LayerDepthExceeded;
        try layers.validateGroup(bounds, options, self.plan.options.size.scale);
        const origin = self.current().origin;
        const rect = self.physicalRect(bounds);
        const visible = intersection(self.current().clip(), rect);
        if (self.gaussian) |owner| owner.active &= ~(@as(u8, 1) << @intCast(self.depth));
        self.groups[self.depth] = .{ .group = .{ .bounds = rect, .options = options } };
        self.depth += 1;
        const target = self.current();
        target.clip_depth = 0;
        target.origin = origin;
        const box = integerBounds(visible, .{ .width = target.width, .height = target.height, .scale = self.plan.options.size.scale });
        target.clips[0] = .{ @floatFromInt(box[0]), @floatFromInt(box[1]), @floatFromInt(box[2]), @floatFromInt(box[3]) };
        for (box[1]..box[3]) |y| @memset(target.pixels.?[y * target.width + box[0] .. y * target.width + box[2]], 0);
        self.stats.groups +%= 1;
        self.stats.clear_pixels +%= @as(u64, box[2] - box[0]) * (box[3] - box[1]);
    }
    pub fn endGroup(self: *Workspace) !void {
        return self.endGroupFiltered(null);
    }
    /// Close a group; a capture opened by `beginGaussian` runs `filter` over
    /// its planes instead of its kernel.
    pub fn endGroupFiltered(self: *Workspace, filter: ?CaptureFilter) !void {
        if (self.depth == 0) return error.GroupStackEmpty;
        if (self.gaussian) |owner| if (owner.active & (@as(u8, 1) << @intCast(self.depth - 1)) != 0) return self.endGaussian(owner, filter);
        if (self.groups[self.depth - 1] != .group) return error.GroupStackEmpty;
        if (self.current().clip_depth != 0) return error.UnbalancedGroupClips;
        const source = self.current();
        self.depth -= 1;
        const destination = self.current();
        const group = self.groups[self.depth].group;
        const region = intersection(destination.clip(), group.bounds);
        const size: z.Size = .{ .width = destination.width, .height = destination.height, .scale = self.plan.options.size.scale };
        const box = integerBounds(region, size);
        const opacity = @as(f64, @floatFromInt(group.options.opacity)) / 255;
        for (box[1]..box[3]) |y| for (box[0]..box[2]) |x| {
            const fx: f64 = @floatFromInt(x);
            const fy: f64 = @floatFromInt(y);
            var amount = opacity * rectCoverage(region, fx, fy);
            if (group.options.mask) |view| {
                const sx = fx - destination.origin[0] - @as(f64, group.options.mask_origin.x) * size.scale - @as(f64, @floatFromInt(view.coverage.origin_x));
                const sy = fy - destination.origin[1] - @as(f64, group.options.mask_origin.y) * size.scale - @as(f64, @floatFromInt(view.coverage.origin_y));
                amount *= composite.sample(view.coverage, sx, sy) / 255;
            }
            const index = @as(usize, y) * size.width + x;
            const full_pixel = fx >= region[0] and fy >= region[1] and fx + 1 <= region[2] and fy + 1 <= region[3];
            const pixel = source.pixels.?[@as(usize, y) * source.width + x];
            destination.pixels.?[index] = if (group.options.mask == null and full_pixel) composite.overByte(pixel, destination.pixels.?[index], group.options.opacity) else composite.over(pixel, destination.pixels.?[index], amount);
        };
        self.stats.composite_pixels +%= @as(u64, box[2] - box[0]) * (box[3] - box[1]);
    }
    pub fn beginGaussian(self: *Workspace, bounds: drawing.Rect, options: layers.Group, kernel: *const gaussian_kernel.Kernel) !void {
        if (!self.active) return error.NotDrawing;
        if (self.depth == self.plan.options.max_depth) return error.LayerDepthExceeded;
        const owner = self.gaussian orelse return error.GaussianNotPrepared;
        try layers.validateGroup(bounds, options, self.plan.options.size.scale);
        const capture = try gaussian_scope.Capture.init(bounds, kernel);
        try owner.begin(self.depth, capture, kernel);
        self.groups[self.depth] = .{ .group = .{ .bounds = self.physicalRect(bounds), .options = options } };
        self.depth += 1;
        const target = self.current();
        target.origin = capture.origin();
        target.clip_depth = 0;
        target.clips[0] = .{ @floatFromInt(capture.radius), @floatFromInt(capture.radius), @floatFromInt(capture.radius + capture.width), @floatFromInt(capture.radius + capture.height) };
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        for (0..capture.pixelHeight()) |y| @memset(target.pixels.?[y * target.width ..][0..capture.pixelWidth()], 0);
        self.stats.groups +%= 1;
        self.stats.clear_pixels +%= @as(u64, capture.pixelWidth()) * capture.pixelHeight();
    }
    noinline fn endGaussian(self: *Workspace, owner: *gaussian_workspace.Owner, filter: ?CaptureFilter) !void {
        if (self.current().clip_depth != 0) return error.UnbalancedGroupClips;
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        const frame = &owner.frames[self.depth - 1];
        const capture = frame.capture;
        const source = self.current();
        const source_pixels = source.pixels.?[0 .. @as(usize, source.width) * source.height];
        var visits: u64 = 0;
        if (filter) |value| {
            value.run(value.context, source_pixels, source.width, owner.scratch, self.plan.pool_size.width, capture);
        } else try gaussian_kernel.apply(&frame.kernel, .{ .pixels = source_pixels, .width = capture.pixelWidth(), .height = capture.pixelHeight(), .stride = source.width }, .{ .pixels = owner.scratch, .width = capture.pixelWidth(), .height = capture.pixelHeight(), .stride = self.plan.pool_size.width }, .{ .pixels = source_pixels, .width = capture.pixelWidth(), .height = capture.pixelHeight(), .stride = source.width }, owner.capacity.filter_samples, null, &visits);
        const options = self.groups[self.depth - 1].group.options;
        self.depth -= 1;
        const destination = self.current();
        const result = try gaussian_composite.draw(.{ .pixels = source.pixels.?, .width = capture.pixelWidth(), .height = capture.pixelHeight(), .stride = source.width, .scale = capture.scale, .clip = source.clip(), .origin = source.origin }, .{ .pixels = destination.pixels.?, .width = destination.width, .height = destination.height, .stride = destination.width, .scale = capture.scale, .clip = destination.clip(), .origin = destination.origin }, capture, options);
        owner.active &= ~(@as(u8, 1) << @intCast(self.depth));
        self.stats.composite_pixels +%= result.visits;
    }
    pub fn glyph(self: *Workspace) !*Surface {
        if (self.plan.options.legacy_text == .disabled) return error.LayerTextDisabled;
        return &self.surfaces[self.plan.options.max_depth + 2];
    }
    pub fn beginTransform(self: *Workspace, value: layers.NativeTransform) !void {
        if (!self.active) return error.NotDrawing;
        try self.plan.validateTransform(value);
        if (self.depth == self.plan.options.max_depth) return error.LayerDepthExceeded;
        if (self.gaussian) |owner| owner.active &= ~(@as(u8, 1) << @intCast(self.depth));
        self.groups[self.depth] = .{ .transform = value };
        self.depth += 1;
        const target = self.current();
        target.origin = .{ 1, 1 };
        target.clip_depth = 0;
        target.clips[0] = .{ 1, 1, 1 + @as(f64, value.source_width) * self.plan.options.size.scale, 1 + @as(f64, value.source_height) * self.plan.options.size.scale };
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        for (0..value.pixel_height + 2) |y| @memset(target.pixels.?[y * target.width .. y * target.width + value.pixel_width + 2], 0);
        self.stats.clear_pixels +%= @as(u64, value.pixel_width + 2) * (value.pixel_height + 2);
    }
    pub fn endTransform(self: *Workspace) !void {
        if (self.depth == 0 or self.groups[self.depth - 1] != .transform) return error.TransformStackEmpty;
        if (self.current().clip_depth != 0) return error.UnbalancedGroupClips;
        if (c.GdiFlush() == 0) return error.FlushSurfaceFailed;
        const source = self.current();
        const value = self.groups[self.depth - 1].transform;
        self.depth -= 1;
        const parent = self.current();
        self.stats.composite_pixels +%= try transform_composite.draw(.{ .pixels = source.pixels.?, .width = value.pixel_width + 2, .height = value.pixel_height + 2, .stride = source.width }, .{ .pixels = parent.pixels.?, .width = parent.width, .height = parent.height, .stride = parent.width }, value.matrix(), self.plan.options.size.scale, parent.origin, parent.clip());
    }
    pub fn physicalRect(self: *Workspace, rect: drawing.Rect) [4]f64 {
        var result = physical(rect, self.plan.options.size.scale);
        const origin = self.current().origin;
        result[0] += origin[0];
        result[2] += origin[0];
        result[1] += origin[1];
        result[3] += origin[1];
        return result;
    }
};
pub fn physical(r: drawing.Rect, scale: f32) [4]f64 {
    return .{ @as(f64, r.x) * scale, @as(f64, r.y) * scale, (@as(f64, r.x) + r.width) * scale, (@as(f64, r.y) + r.height) * scale };
}
pub fn intersection(a: [4]f64, b: [4]f64) [4]f64 {
    return .{ @max(a[0], b[0]), @max(a[1], b[1]), @min(a[2], b[2]), @min(a[3], b[3]) };
}
pub fn integerBounds(rect: [4]f64, size: z.Size) [4]u32 {
    const left = std.math.clamp(@floor(rect[0]), 0, @as(f64, @floatFromInt(size.width)));
    const top = std.math.clamp(@floor(rect[1]), 0, @as(f64, @floatFromInt(size.height)));
    return .{ @intFromFloat(left), @intFromFloat(top), @intFromFloat(@max(left, @min(@ceil(rect[2]), @as(f64, @floatFromInt(size.width))))), @intFromFloat(@max(top, @min(@ceil(rect[3]), @as(f64, @floatFromInt(size.height))))) };
}
pub fn rectCoverage(rect: [4]f64, x: f64, y: f64) f64 {
    return @max(0, @min(x + 1, rect[2]) - @max(x, rect[0])) * @max(0, @min(y + 1, rect[3]) - @max(y, rect[1]));
}

test "GDI prepared layers keep fractional parent clip outside the transparent group and abort preserves front" {
    const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
    const options: layers.Options = .{ .size = .{ .width = 16, .height = 16, .scale = 1 } };
    {
        const workspace = try Workspace.create(std.testing.allocator, options);
        defer workspace.deinit();
        try workspace.begin(options.size);
        try workspace.pushClip(.{ .x = 0.25, .y = 0.25, .width = 2, .height = 2 });
        try workspace.beginGroup(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, .{ .opacity = 128 });
        // The fractional parent coverage must be absent inside this target.
        try std.testing.expectEqual(@as(f64, 0), workspace.current().clip()[0]);
        @memset(workspace.current().pixels.?[0..256], 0x80800000);
        try workspace.endGroup();
        const amount = @as(f64, 128) / 255 * 0.75 * 0.75;
        try std.testing.expectEqual(composite.over(0x80800000, 0xffffffff, amount), workspace.current().pixels.?[0]);
        try std.testing.expectEqual(@as(u32, 0xffffffff), workspace.front().pixels.?[0]);
        workspace.abort();
        try std.testing.expectEqual(@as(u32, 0xffffffff), workspace.front().pixels.?[0]);
        try workspace.begin(options.size);
        workspace.current().pixels.?[0] = 0xff123456;
        var destination = try Surface.init(options.size, null, null);
        defer destination.deinit();
        try workspace.commit(destination.dc);
        try std.testing.expectEqual(@as(u32, 0xff123456), workspace.front().pixels.?[0]);
        try std.testing.expectEqual(@as(u64, 1), workspace.stats.committed_frames);
        try std.testing.expectEqual(@as(u64, 1), workspace.stats.aborted_frames);
    }
    try std.testing.expectEqual(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
}
