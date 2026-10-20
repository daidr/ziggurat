const std = @import("std");
const layout = @import("layout.zig");
pub const drawing = @import("ziggurat_drawing_resources");
pub const Rect = layout.Rect;
pub const geometry = @import("geometry.zig");
pub const Color = geometry.Color;
pub const Shape = geometry.Shape;
pub const brushes = @import("brushes.zig");
pub const Gradient = brushes.Gradient;
pub const layers = @import("layers.zig");
pub const gaussian = @import("gaussian_filter.zig");
const gaussian_scope = @import("gaussian_scope.zig");
pub const backdrop = @import("backdrop.zig");
pub const loading = @import("loading.zig");
pub const shader_effects = @import("shader_effects.zig");
pub const no_filter: u8 = 255;
pub const GroupCommand = struct { bounds: Rect, mask_origin: drawing.Point = .{}, opacity: u8 = 255, mask_resource: ?u8 = null, filter_slot: u8 = no_filter };
pub const GradientShape = struct { bounds: Rect, radius: f32 = 0, stroke_width: f32 = 0, brush: u8 };
/// Font of a text command: size in DIP, weight, slant and whether to use
/// the platform's fixed-pitch family instead of the interface family.
pub const Font = struct {
    size: f32 = 16,
    weight: Weight = .regular,
    italic: bool = false,
    monospace: bool = false,

    pub const Weight = enum(u8) {
        regular,
        medium,
        semibold,
        bold,
        /// The CSS-style numeric weight that native font APIs take.
        pub fn value(self: Weight) u16 {
            return 400 + 100 * @as(u16, @intFromEnum(self));
        }
    };
    /// Presets for document text: body copy, six heading levels from
    /// largest to smallest, and fixed-pitch code.
    pub const body: Font = .{};
    pub const heading1: Font = .{ .size = 32, .weight = .bold };
    pub const heading2: Font = .{ .size = 26, .weight = .bold };
    pub const heading3: Font = .{ .size = 22, .weight = .semibold };
    pub const heading4: Font = .{ .size = 19, .weight = .semibold };
    pub const heading5: Font = .{ .size = 16, .weight = .semibold };
    pub const heading6: Font = .{ .size = 14, .weight = .semibold };
    pub const code: Font = .{ .size = 14, .monospace = true };
    pub const smallest: f32 = 1;
    pub const largest: f32 = 1024;
    pub fn valid(self: Font) bool {
        return std.math.isFinite(self.size) and self.size >= smallest and self.size <= largest;
    }
    /// The compact form stored in a command; sizes round to 1/16 DIP.
    pub fn key(self: Font) FontKey {
        return .{ .sixteenths = @intFromFloat(@round(self.size * 16)), .weight = self.weight, .italic = self.italic, .monospace = self.monospace };
    }
};
pub const FontKey = packed struct(u32) {
    sixteenths: u16 = 16 * 16,
    weight: Font.Weight = .regular,
    italic: bool = false,
    monospace: bool = false,
    _: u6 = 0,
    pub fn size(self: FontKey) f32 {
        return @as(f32, @floatFromInt(self.sixteenths)) / 16;
    }
    pub fn isDefault(self: FontKey) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(FontKey{}));
    }
};
pub const Text = struct { bounds: Rect, color: u32, offset: u16, len: u16, font: FontKey = .{} };
pub const ImageCommand = struct { destination: Rect, alignment: drawing.Point, fit: drawing.ImageFit, sampling: drawing.ImageSampling, opacity: u8, resource: u8 };
pub const Command = union(enum) {
    fill: struct { bounds: Rect, color: u32 },
    shape: Shape,
    gradient: GradientShape,
    text: Text,
    prepared_text: struct { origin: drawing.Point, color: Color, resource: u8 },
    coverage: struct { origin: drawing.Point, color: Color, resource: u8 },
    image: ImageCommand,
    texture: ImageCommand,
    push_clip: Rect,
    pop_clip,
    begin_group: GroupCommand,
    end_group,
    begin_transform: u8,
    end_transform,
    /// Index into the Buffer's backdrop table.
    backdrop: u8,
    /// Index into the Buffer's loading indicator table.
    indicator: u8,
    /// Index into the Buffer's shader table: opens an element effect, closed
    /// by the matching `end_effect`.
    effect: u8,
    end_effect,
    /// Index into the Buffer's shader table: a backdrop shader.
    backdrop_shader: u8,
};
comptime {
    if (@sizeOf(Command) != 32 or @sizeOf(GroupCommand) != 28) @compileError("command ABI mismatch");
}
pub const Error = brushes.Error || error{ InvalidGeometry, CommandsFull, TextStorageFull, ClipStackFull, ClipStackEmpty, UnbalancedClips, BrushesFull, GroupStackFull, GroupStackEmpty, UnbalancedGroups, UnbalancedGroupClips, TransformStackEmpty, TransformStorageRequired, TransformStorageInUse, TransformsFull, BufferNotEmpty };
pub const TransformStorage = struct {
    storage: [64]layers.NativeTransform = undefined,
    len: usize = 0,
    scale: f32 = 1,
    bound: bool = false,
};
pub const FilterStorage = struct {
    storage: [32]gaussian.View = undefined,
    len: usize = 0,
    bound: bool = false,
};
const ScopeKind = enum { group, transform, gaussian, effect };

/// Backdrop effects, loading indicators and shader effects are drawn on the
/// software planes; a GPU renderer rejects a batch that holds one.
pub fn softwareOnly(list: []const Command) bool {
    for (list) |command| switch (command) {
        .backdrop, .indicator, .effect, .end_effect, .backdrop_shader => return true,
        else => {},
    };
    return false;
}

/// Reject the entire batch before a software backend changes its work plane.
pub fn rejectTextures(list: []const Command) error{UnsupportedTextureBackend}!void {
    for (list) |command| if (command == .texture) return error.UnsupportedTextureBackend;
}

/// Caller-owned frame storage. Reset after the last replay, including failures.
/// Text is copied; prepared resources are borrowed and pinned until reset.
/// Do not copy a Buffer while it contains prepared resources.
pub const Buffer = struct {
    storage: [2048]Command = undefined,
    text_storage: [64 * 1024]u8 = undefined,
    brush_storage: [brushes.max_brushes]brushes.Stored = undefined,
    prepared_text_storage: [32]drawing.PreparedTextView = undefined,
    prepared_text_len: usize = 0,
    image_storage: [32]drawing.ImageView = undefined,
    image_len: usize = 0,
    coverage_storage: [32]drawing.CoverageView = undefined,
    coverage_len: usize = 0,
    texture_storage: [32]drawing.TextureView = undefined,
    texture_len: usize = 0,
    len: usize = 0,
    text_len: usize = 0,
    depth: usize = 0,
    brush_len: usize = 0,
    group_depth: usize = 0,
    group_clips: [layers.max_depth]usize = undefined,
    scope_kinds: [layers.max_depth]ScopeKind = undefined,
    transform_storage: ?*TransformStorage = null,
    filter_storage: ?*FilterStorage = null,
    backdrop_storage: backdrop.Storage = .{},
    indicator_storage: [loading.max_entries]loading.Entry = undefined,
    indicator_len: usize = 0,
    shader_storage: shader_effects.Storage = .{},

    pub fn reset(self: *Buffer) void {
        for (self.preparedTextResources()) |view| view.lease.release();
        for (self.imageResources()) |view| view.lease.release();
        for (self.coverageResources()) |view| view.lease.release();
        for (self.textureResources()) |view| view.lease.release();
        if (self.filter_storage) |storage| {
            for (storage.storage[0..storage.len]) |view| view.lease.release();
            storage.len = 0;
            storage.bound = false;
            self.filter_storage = null;
        }
        self.prepared_text_len = 0;
        self.image_len = 0;
        self.coverage_len = 0;
        self.texture_len = 0;
        self.len = 0;
        self.text_len = 0;
        self.depth = 0;
        self.brush_len = 0;
        self.group_depth = 0;
        self.backdrop_storage.len = 0;
        self.backdrop_storage.workspace = null;
        self.indicator_len = 0;
        self.shader_storage.len = 0;
        self.shader_storage.workspace = null;
        if (self.transform_storage) |storage| {
            storage.len = 0;
            storage.bound = false;
            self.transform_storage = null;
        }
    }
    /// Storage must stay at this address until reset. A second Buffer cannot
    /// bind it concurrently. Ordinary buffers need no transform table.
    pub fn bindTransformStorage(self: *Buffer, storage: *TransformStorage) !void {
        if (self.len != 0 or self.group_depth != 0 or self.depth != 0 or self.transform_storage != null) return error.BufferNotEmpty;
        if (storage.bound or storage.len != 0) return error.TransformStorageInUse;
        if (!std.math.isFinite(storage.scale) or storage.scale <= 0) return error.InvalidTransformSource;
        storage.bound = true;
        self.transform_storage = storage;
    }
    pub fn transformResources(self: *const Buffer) []const layers.NativeTransform {
        return if (self.transform_storage) |storage| storage.storage[0..storage.len] else &.{};
    }
    pub fn bindFilterStorage(self: *Buffer, storage: *FilterStorage) !void {
        if (self.len != 0 or self.group_depth != 0 or self.depth != 0 or self.filter_storage != null) return error.BufferNotEmpty;
        if (storage.bound or storage.len != 0) return error.GaussianStorageInUse;
        storage.bound = true;
        self.filter_storage = storage;
    }
    pub fn filterResources(self: *const Buffer) []const gaussian.View {
        return if (self.filter_storage) |storage| storage.storage[0..storage.len] else &.{};
    }
    pub const Checkpoint = struct {
        len: usize,
        text_len: usize,
        depth: usize,
        brush_len: usize,
        prepared: usize,
        images: usize,
        coverage: usize,
        textures: usize,
        group_depth: usize,
        filters: usize,
        transforms: usize,
        backdrops: usize,
        indicators: usize,
        shaders: usize,
    };
    pub fn checkpoint(self: *const Buffer) Checkpoint {
        return .{ .len = self.len, .text_len = self.text_len, .depth = self.depth, .brush_len = self.brush_len, .prepared = self.prepared_text_len, .images = self.image_len, .coverage = self.coverage_len, .textures = self.texture_len, .group_depth = self.group_depth, .filters = self.filterResources().len, .transforms = self.transformResources().len, .backdrops = self.backdrop_storage.len, .indicators = self.indicator_len, .shaders = self.shader_storage.len };
    }
    /// Only the same owning Buffer may roll back to its earlier scope mark.
    /// No allocator or foreign destructor is called while releasing these pins.
    pub fn rollback(self: *Buffer, mark: Checkpoint) void {
        for (self.preparedTextResources()[mark.prepared..]) |view| view.lease.release();
        for (self.imageResources()[mark.images..]) |view| view.lease.release();
        for (self.coverageResources()[mark.coverage..]) |view| view.lease.release();
        for (self.textureResources()[mark.textures..]) |view| view.lease.release();
        if (self.filter_storage) |storage| {
            for (storage.storage[mark.filters..storage.len]) |view| view.lease.release();
            storage.len = mark.filters;
        }
        if (self.transform_storage) |storage| storage.len = mark.transforms;
        self.len = mark.len;
        self.text_len = mark.text_len;
        self.depth = mark.depth;
        self.brush_len = mark.brush_len;
        self.prepared_text_len = mark.prepared;
        self.image_len = mark.images;
        self.coverage_len = mark.coverage;
        self.texture_len = mark.textures;
        self.group_depth = mark.group_depth;
        self.backdrop_storage.len = mark.backdrops;
        self.indicator_len = mark.indicators;
        self.shader_storage.len = mark.shaders;
    }
    pub fn beginTransform(self: *Buffer, value: layers.NativeTransform) !void {
        const storage = self.transform_storage orelse return error.TransformStorageRequired;
        try value.validate(storage.scale);
        if (self.group_depth == layers.max_depth) return error.GroupStackFull;
        if (self.len == self.storage.len) return error.CommandsFull;
        if (storage.len > storage.storage.len) return error.TransformsFull;
        var index: usize = 0;
        while (index < storage.len) : (index += 1) if (std.meta.eql(storage.storage[index], value)) break;
        if (index == storage.storage.len) return error.TransformsFull;
        if (index == storage.len) {
            storage.storage[index] = value;
            storage.len += 1;
        }
        self.storage[self.len] = .{ .begin_transform = @intCast(index) };
        self.len += 1;
        self.group_clips[self.group_depth] = self.depth;
        self.scope_kinds[self.group_depth] = .transform;
        self.group_depth += 1;
    }
    pub fn endTransform(self: *Buffer) Error!void {
        if (self.group_depth == 0 or self.scope_kinds[self.group_depth - 1] != .transform) return error.TransformStackEmpty;
        if (self.depth != self.group_clips[self.group_depth - 1]) return error.UnbalancedGroupClips;
        try self.append(.end_transform);
        self.group_depth -= 1;
    }
    pub fn commands(self: *const Buffer) []const Command {
        return self.storage[0..self.len];
    }
    pub fn textBytes(self: *const Buffer) []const u8 {
        return self.text_storage[0..self.text_len];
    }
    pub fn brushResources(self: *const Buffer) []const brushes.Stored {
        return self.brush_storage[0..self.brush_len];
    }
    pub fn preparedTextResources(self: *const Buffer) []const drawing.PreparedTextView {
        return self.prepared_text_storage[0..self.prepared_text_len];
    }
    pub fn imageResources(self: *const Buffer) []const drawing.ImageView {
        return self.image_storage[0..self.image_len];
    }
    pub fn coverageResources(self: *const Buffer) []const drawing.CoverageView {
        return self.coverage_storage[0..self.coverage_len];
    }
    pub fn textureResources(self: *const Buffer) []const drawing.TextureView {
        return self.texture_storage[0..self.texture_len];
    }
    pub fn texture(self: *Buffer, destination: Rect, view: drawing.TextureView, options: drawing.ImageOptions) !void {
        _ = try drawing.planTexture(view, .{ .x = destination.x, .y = destination.y, .width = destination.width, .height = destination.height }, options, 1);
        if (self.len == self.storage.len) return error.CommandsFull;
        var index: usize = 0;
        while (index < self.texture_len) : (index += 1) if (self.texture_storage[index].lease == view.lease) break;
        if (index == self.texture_len) {
            if (index == self.texture_storage.len) return error.TextureResourcesFull;
            try view.lease.acquire();
            self.texture_storage[index] = view;
            self.texture_len += 1;
        }
        self.storage[self.len] = .{ .texture = .{ .destination = destination, .alignment = options.alignment, .fit = options.fit, .sampling = options.sampling, .opacity = options.opacity, .resource = @intCast(index) } };
        self.len += 1;
    }
    pub fn coverage(self: *Buffer, origin: drawing.Point, view: drawing.CoverageView, color: Color) !void {
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        try view.validate();
        if (self.len == self.storage.len) return error.CommandsFull;
        var index: usize = 0;
        while (index < self.coverage_len) : (index += 1) if (self.coverage_storage[index].lease == view.lease) break;
        if (index == self.coverage_len) {
            if (index == self.coverage_storage.len) return error.CoverageResourcesFull;
            try view.lease.acquire();
            self.coverage_storage[index] = view;
            self.coverage_len += 1;
        }
        self.storage[self.len] = .{ .coverage = .{ .origin = origin, .color = color, .resource = @intCast(index) } };
        self.len += 1;
    }
    /// Paint an immutable A8 raster with a gradient in the current user space.
    /// Explicit layer preparation and coverage residency are required at replay.
    /// Commit the balanced scope and its resources only after every check passes.
    pub fn gradientCoverage(self: *Buffer, origin: drawing.Point, view: drawing.CoverageView, gradient: Gradient) !void {
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        try view.validate();
        const bounds = try gradientCoverageBounds(origin, view.coverage);
        const resource = try brushes.Stored.init(gradient);
        if (self.group_depth == layers.max_depth) return error.GroupStackFull;
        if (self.storage.len - self.len < 3) return error.CommandsFull;
        var brush: usize = 0;
        while (brush < self.brush_len) : (brush += 1) if (brushes.Stored.eql(&resource, &self.brush_storage[brush])) break;
        if (brush == self.brush_len and brush == self.brush_storage.len) return error.BrushesFull;
        var mask: usize = 0;
        while (mask < self.coverage_len) : (mask += 1) if (self.coverage_storage[mask].lease == view.lease) break;
        if (mask == self.coverage_len) {
            if (mask == self.coverage_storage.len) return error.CoverageResourcesFull;
            try view.lease.acquire();
        }
        // No allocation, callback or fallible operation follows the new pin.
        if (mask == self.coverage_len) {
            self.coverage_storage[mask] = view;
            self.coverage_len += 1;
        }
        if (brush == self.brush_len) {
            self.brush_storage[brush] = resource;
            self.brush_len += 1;
        }
        self.storage[self.len] = .{ .begin_group = .{ .bounds = bounds, .mask_origin = origin, .mask_resource = @intCast(mask) } };
        self.storage[self.len + 1] = .{ .gradient = .{ .bounds = bounds, .brush = @intCast(brush) } };
        self.storage[self.len + 2] = .end_group;
        self.len += 3;
    }
    pub fn beginGroup(self: *Buffer, bounds: Rect, options: layers.Group) !void {
        try layers.validateGroup(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height }, options, if (options.mask) |mask| mask.coverage.scale else 1);
        if (self.group_depth == layers.max_depth) return error.GroupStackFull;
        if (self.len == self.storage.len) return error.CommandsFull;
        var resource: ?u8 = null;
        if (options.mask) |view| {
            var index: usize = 0;
            while (index < self.coverage_len) : (index += 1) if (self.coverage_storage[index].lease == view.lease) break;
            if (index == self.coverage_len) {
                if (index == self.coverage_storage.len) return error.CoverageResourcesFull;
                try view.lease.acquire();
                self.coverage_storage[index] = view;
                self.coverage_len += 1;
            }
            resource = @intCast(index);
        }
        self.storage[self.len] = .{ .begin_group = .{ .bounds = bounds, .opacity = options.opacity, .mask_origin = options.mask_origin, .mask_resource = resource } };
        self.len += 1;
        self.group_clips[self.group_depth] = self.depth;
        self.scope_kinds[self.group_depth] = .group;
        self.group_depth += 1;
    }
    pub fn endGroup(self: *Buffer) Error!void {
        if (self.group_depth == 0 or self.scope_kinds[self.group_depth - 1] != .group) return error.GroupStackEmpty;
        if (self.depth != self.group_clips[self.group_depth - 1]) return error.UnbalancedGroupClips;
        try self.append(.end_group);
        self.group_depth -= 1;
    }
    /// Capture/filters are visual only. The body is recorded exactly once by
    /// Frame.gaussianScope; the prepared kernel is pinned once per Buffer.
    pub fn beginGaussian(self: *Buffer, bounds: Rect, view: gaussian.View, options: layers.Group) !void {
        try view.validate();
        if (view.descriptor.radius == 0) {
            try self.beginGroup(bounds, options);
            self.scope_kinds[self.group_depth - 1] = .gaussian;
            return;
        }
        _ = try gaussian_scope.Capture.init(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height }, view.descriptor);
        try layers.validateGroup(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height }, options, view.descriptor.scale);
        const storage = self.filter_storage orelse return error.GaussianStorageRequired;
        if (self.group_depth == layers.max_depth) return error.GroupStackFull;
        if (self.len == self.storage.len) return error.CommandsFull;
        var filter: usize = 0;
        while (filter < storage.len) : (filter += 1) if (storage.storage[filter].lease == view.lease and storage.storage[filter].identity == view.identity) break;
        if (filter == storage.len and filter == storage.storage.len) return error.GaussianResourcesFull;
        var mask: usize = 0;
        if (options.mask) |value| {
            while (mask < self.coverage_len) : (mask += 1) if (self.coverage_storage[mask].lease == value.lease) break;
            if (mask == self.coverage_len and mask == self.coverage_storage.len) return error.CoverageResourcesFull;
        }
        var mask_pin = false;
        if (options.mask) |value| if (mask == self.coverage_len) {
            try value.lease.acquire();
            mask_pin = true;
        };
        errdefer if (mask_pin) options.mask.?.lease.release();
        if (filter == storage.len) try view.lease.acquire();
        // All checks and pins succeed before any Buffer/storage publication.
        if (mask_pin) {
            self.coverage_storage[mask] = options.mask.?;
            self.coverage_len += 1;
        }
        if (filter == storage.len) {
            storage.storage[filter] = view;
            storage.len += 1;
        }
        self.storage[self.len] = .{ .begin_group = .{ .bounds = bounds, .opacity = options.opacity, .mask_origin = options.mask_origin, .mask_resource = if (options.mask != null) @intCast(mask) else null, .filter_slot = @intCast(filter) } };
        self.len += 1;
        self.group_clips[self.group_depth] = self.depth;
        self.scope_kinds[self.group_depth] = .gaussian;
        self.group_depth += 1;
    }
    pub fn endGaussian(self: *Buffer) Error!void {
        if (self.group_depth == 0 or self.scope_kinds[self.group_depth - 1] != .gaussian) return error.GroupStackEmpty;
        if (self.depth != self.group_clips[self.group_depth - 1]) return error.UnbalancedGroupClips;
        try self.append(.end_group);
        self.group_depth -= 1;
    }
    /// Record a backdrop effect in absolute DIP. It reads the target plane
    /// as drawn so far, so only software replay can draw it.
    pub fn backdropEffect(self: *Buffer, entry: backdrop.Entry) !void {
        if (!layout.validRect(entry.bounds) or !std.math.isFinite(entry.bounds.x + entry.bounds.width) or !std.math.isFinite(entry.bounds.y + entry.bounds.height) or !std.math.isFinite(entry.radius) or entry.radius < 0 or !std.math.isFinite(entry.sigma) or entry.sigma < 0 or !std.math.isFinite(entry.noise)) return error.InvalidGeometry;
        if (entry.mask) |mask| if (!std.math.isFinite(mask.angle) or !std.math.isFinite(mask.start) or !std.math.isFinite(mask.end)) return error.InvalidGeometry;
        if (self.len == self.storage.len) return error.CommandsFull;
        const table = &self.backdrop_storage;
        if (table.len == table.entries.len) return error.BackdropsFull;
        table.entries[table.len] = entry;
        self.storage[self.len] = .{ .backdrop = @intCast(table.len) };
        table.len += 1;
        self.len += 1;
    }
    /// Record a loading indicator in absolute DIP at a pose the caller chose.
    pub fn loadingIndicator(self: *Buffer, entry: loading.Entry) !void {
        if (!layout.validRect(entry.bounds) or !std.math.isFinite(entry.bounds.x + entry.bounds.width) or !std.math.isFinite(entry.bounds.y + entry.bounds.height) or !std.math.isFinite(entry.phase)) return error.InvalidGeometry;
        if (self.len == self.storage.len) return error.CommandsFull;
        if (self.indicator_len == self.indicator_storage.len) return error.IndicatorsFull;
        self.indicator_storage[self.indicator_len] = entry;
        self.storage[self.len] = .{ .indicator = @intCast(self.indicator_len) };
        self.indicator_len += 1;
        self.len += 1;
    }
    /// Open an element effect over the entry's box plus margin; the
    /// renderer isolates what is drawn until `endEffect`.
    pub fn beginEffect(self: *Buffer, entry: shader_effects.Entry) !void {
        try shader_effects.validate(entry);
        if (entry.target != .element) return error.InvalidGeometry;
        try entry.carrier.validate();
        if (self.group_depth == layers.max_depth) return error.GroupStackFull;
        if (self.len == self.storage.len) return error.CommandsFull;
        const table = &self.shader_storage;
        if (table.len == table.entries.len) return error.ShaderEffectsFull;
        table.entries[table.len] = entry;
        self.storage[self.len] = .{ .effect = @intCast(table.len) };
        table.len += 1;
        self.len += 1;
        self.group_clips[self.group_depth] = self.depth;
        self.scope_kinds[self.group_depth] = .effect;
        self.group_depth += 1;
    }
    pub fn endEffect(self: *Buffer) Error!void {
        if (self.group_depth == 0 or self.scope_kinds[self.group_depth - 1] != .effect) return error.GroupStackEmpty;
        if (self.depth != self.group_clips[self.group_depth - 1]) return error.UnbalancedGroupClips;
        try self.append(.end_effect);
        self.group_depth -= 1;
    }
    /// Record a backdrop shader in absolute DIP. Like a backdrop effect it
    /// reads the target plane as drawn so far.
    pub fn backdropShader(self: *Buffer, entry: shader_effects.Entry) !void {
        try shader_effects.validate(entry);
        if (entry.target != .backdrop) return error.InvalidGeometry;
        if (self.len == self.storage.len) return error.CommandsFull;
        const table = &self.shader_storage;
        if (table.len == table.entries.len) return error.ShaderEffectsFull;
        table.entries[table.len] = entry;
        self.storage[self.len] = .{ .backdrop_shader = @intCast(table.len) };
        table.len += 1;
        self.len += 1;
    }
    pub fn shaderEntries(self: *const Buffer) []const shader_effects.Entry {
        return self.shader_storage.entries[0..self.shader_storage.len];
    }
    pub fn indicatorEntries(self: *const Buffer) []const loading.Entry {
        return self.indicator_storage[0..self.indicator_len];
    }
    pub fn backdropEntries(self: *const Buffer) []const backdrop.Entry {
        return self.backdrop_storage.entries[0..self.backdrop_storage.len];
    }
    pub fn image(self: *Buffer, destination: Rect, view: drawing.ImageView, options: drawing.ImageOptions) !void {
        if (!layout.validRect(destination) or !std.math.isFinite(destination.x + destination.width) or !std.math.isFinite(destination.y + destination.height)) return error.InvalidGeometry;
        try options.validate();
        try view.validate();
        if (self.len == self.storage.len) return error.CommandsFull;
        var index: usize = 0;
        while (index < self.image_len) : (index += 1) if (self.image_storage[index].lease == view.lease) break;
        if (index == self.image_len) {
            if (index == self.image_storage.len) return error.ImageResourcesFull;
            try view.lease.acquire();
            self.image_storage[index] = view;
            self.image_len += 1;
        }
        self.storage[self.len] = .{ .image = .{ .destination = destination, .alignment = options.alignment, .fit = options.fit, .sampling = options.sampling, .opacity = options.opacity, .resource = @intCast(index) } };
        self.len += 1;
    }
    pub fn preparedText(self: *Buffer, origin: drawing.Point, view: drawing.PreparedTextView, color: Color) !void {
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGeometry;
        try view.validate();
        if (self.len == self.storage.len) return error.CommandsFull;
        var index: usize = 0;
        while (index < self.prepared_text_len) : (index += 1) if (self.prepared_text_storage[index].lease == view.lease) break;
        if (index == self.prepared_text_len) {
            if (index == self.prepared_text_storage.len) return error.PreparedTextResourcesFull;
            try view.lease.acquire();
            self.prepared_text_storage[index] = view;
            self.prepared_text_len += 1;
        }
        self.storage[self.len] = .{ .prepared_text = .{ .origin = origin, .color = color, .resource = @intCast(index) } };
        self.len += 1;
    }
    pub fn finish(self: *const Buffer) Error!void {
        if (self.group_depth != 0) return error.UnbalancedGroups;
        if (self.depth != 0) return error.UnbalancedClips;
    }
    fn append(self: *Buffer, command: Command) Error!void {
        if (self.len == self.storage.len) return error.CommandsFull;
        self.storage[self.len] = command;
        self.len += 1;
    }
    pub fn fill(self: *Buffer, bounds: Rect, color: u32) Error!void {
        if (!layout.validRect(bounds)) return error.InvalidGeometry;
        try self.append(.{ .fill = .{ .bounds = bounds, .color = color } });
    }
    pub fn roundedRect(self: *Buffer, bounds: Rect, radius: f32, color: Color) Error!void {
        const shape: Shape = .{ .bounds = bounds, .radius = radius, .color = color };
        _ = try geometry.plan(shape);
        try self.append(.{ .shape = shape });
    }
    pub fn strokeRect(self: *Buffer, bounds: Rect, radius: f32, width: f32, color: Color) Error!void {
        if (!std.math.isFinite(width) or width <= 0) return error.InvalidGeometry;
        const shape: Shape = .{ .bounds = bounds, .radius = radius, .stroke_width = width, .color = color };
        _ = try geometry.plan(shape);
        try self.append(.{ .shape = shape });
    }
    pub fn gradientRect(self: *Buffer, bounds: Rect, radius: f32, gradient: Gradient) Error!void {
        try self.gradientShape(bounds, radius, 0, gradient);
    }
    pub fn gradientStrokeRect(self: *Buffer, bounds: Rect, radius: f32, width: f32, gradient: Gradient) Error!void {
        if (!std.math.isFinite(width) or width <= 0) return error.InvalidGeometry;
        try self.gradientShape(bounds, radius, width, gradient);
    }
    fn gradientShape(self: *Buffer, bounds: Rect, radius: f32, width: f32, gradient: Gradient) Error!void {
        _ = try geometry.plan(.{ .bounds = bounds, .radius = radius, .stroke_width = width, .color = Color.rgb(0) });
        const resource = try brushes.Stored.init(gradient);
        if (self.len == self.storage.len) return error.CommandsFull;
        var index: usize = 0;
        while (index < self.brush_len) : (index += 1) if (brushes.Stored.eql(&resource, &self.brush_storage[index])) break;
        if (index == self.brush_len and self.brush_len == self.brush_storage.len) return error.BrushesFull;
        // All fallible work is complete before mutating either table.
        if (index == self.brush_len) {
            self.brush_storage[index] = resource;
            self.brush_len += 1;
        }
        try self.append(.{ .gradient = .{ .bounds = bounds, .radius = radius, .stroke_width = width, .brush = @intCast(index) } });
    }
    pub fn text(self: *Buffer, bounds: Rect, utf8: []const u8, color: u32) !void {
        return self.textFont(bounds, utf8, color, .{});
    }
    pub fn textFont(self: *Buffer, bounds: Rect, utf8: []const u8, color: u32, font: Font) !void {
        if (!layout.validRect(bounds)) return error.InvalidGeometry;
        if (!font.valid()) return error.InvalidFont;
        if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
        if (utf8.len > 2048) return error.TextTooLong;
        if (utf8.len > self.text_storage.len - self.text_len) return error.TextStorageFull;
        // Storage is 64 KiB, so a non-empty run always starts below 65536.
        const offset: u16 = if (utf8.len == 0) 0 else @intCast(self.text_len);
        try self.append(.{ .text = .{ .bounds = bounds, .color = color, .offset = offset, .len = @intCast(utf8.len), .font = font.key() } });
        @memcpy(self.text_storage[self.text_len..][0..utf8.len], utf8);
        self.text_len += utf8.len;
    }
    pub fn pushClip(self: *Buffer, bounds: Rect) Error!void {
        if (!layout.validRect(bounds)) return error.InvalidGeometry;
        if (self.depth == 32) return error.ClipStackFull;
        try self.append(.{ .push_clip = bounds });
        self.depth += 1;
    }
    pub fn popClip(self: *Buffer) Error!void {
        if (self.depth == 0 or (self.group_depth != 0 and self.depth == self.group_clips[self.group_depth - 1])) return error.ClipStackEmpty;
        try self.append(.pop_clip);
        self.depth -= 1;
    }
};

fn gradientCoverageBounds(origin: drawing.Point, mask: drawing.Coverage) error{InvalidGeometry}!Rect {
    // The common bilinear sampler is zero at texel coordinates <= -1 and
    // >= width/height. One transparent texel on each side also keeps the
    // gradient rectangle's antialiased edge outside every contributing cell.
    const inverse = 1 / @as(f64, mask.scale);
    const left = @as(f64, origin.x) + (@as(f64, @floatFromInt(mask.origin_x)) - 1) * inverse;
    const top = @as(f64, origin.y) + (@as(f64, @floatFromInt(mask.origin_y)) - 1) * inverse;
    const right = @as(f64, origin.x) + (@as(f64, @floatFromInt(mask.origin_x)) + @as(f64, @floatFromInt(mask.width)) + 1) * inverse;
    const bottom = @as(f64, origin.y) + (@as(f64, @floatFromInt(mask.origin_y)) + @as(f64, @floatFromInt(mask.height)) + 1) * inverse;
    const x = try gradientCoverageBound(left, false);
    const y = try gradientCoverageBound(top, false);
    const far_x = try gradientCoverageBound(right, true);
    const far_y = try gradientCoverageBound(bottom, true);
    // Keep even native f32 x+width/y+height additions outside the exact edge.
    const width = try gradientCoverageBound(@as(f64, far_x) - x, true);
    const height = try gradientCoverageBound(@as(f64, far_y) - y, true);
    const result: Rect = .{ .x = x, .y = y, .width = width, .height = height };
    _ = try geometry.plan(.{ .bounds = result, .color = Color.rgb(0) });
    return result;
}

fn gradientCoverageBound(value: f64, upper: bool) error{InvalidGeometry}!f32 {
    if (!std.math.isFinite(value) or @abs(value) > std.math.floatMax(f32)) return error.InvalidGeometry;
    const result: f32 = @floatCast(value);
    if ((upper and @as(f64, result) < value) or (!upper and @as(f64, result) > value)) {
        const outward = std.math.nextAfter(f32, result, if (upper) std.math.inf(f32) else -std.math.inf(f32));
        if (!std.math.isFinite(outward)) return error.InvalidGeometry;
        return outward;
    }
    return result;
}

test "Gaussian commands commit pins together and identity needs no filter storage" {
    const bank = try gaussian.Bank.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer bank.close() catch unreachable;
    const kernel = try bank.prepare(.{ .spec = .{ .sigma = 1 } });
    defer kernel.close() catch unreachable;
    const zero = try bank.prepare(.{ .spec = .{ .sigma = 0 } });
    defer zero.close() catch unreachable;
    var buffer: Buffer = .{};
    defer buffer.reset();
    const bounds: Rect = .{ .x = -2, .y = 1, .width = 4, .height = 3 };
    try buffer.beginGaussian(bounds, try zero.view(), .{});
    try std.testing.expectError(error.GroupStackEmpty, buffer.endGroup());
    try buffer.endGaussian();
    try buffer.finish();
    try std.testing.expectEqual(@as(usize, 0), (try zero.view()).lease.pins);
    buffer.reset();
    try std.testing.expectError(error.GaussianStorageRequired, buffer.beginGaussian(bounds, try kernel.view(), .{}));
    var storage: FilterStorage = .{};
    try buffer.bindFilterStorage(&storage);
    var mask_lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{255};
    const mask: drawing.CoverageView = .{ .lease = &mask_lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &bytes, .width = 1, .height = 1, .stride = 1, .origin_x = 0, .origin_y = 0, .scale = 1 } };
    const view = try kernel.view();
    view.lease.pins = std.math.maxInt(usize);
    try std.testing.expectError(error.ResourcePinsFull, buffer.beginGaussian(bounds, view, .{ .mask = mask }));
    try std.testing.expectEqual(@as(usize, 0), mask_lease.pins);
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    try std.testing.expectEqual(@as(usize, 0), buffer.coverage_len);
    try std.testing.expectEqual(@as(usize, 0), storage.len);
    view.lease.pins = 0;
    for (0..2) |_| {
        try buffer.beginGaussian(bounds, view, .{ .mask = mask, .opacity = 128 });
        try buffer.endGaussian();
    }
    try std.testing.expectEqual(@as(usize, 1), view.lease.pins);
    try std.testing.expectEqual(@as(usize, 1), mask_lease.pins);
    try std.testing.expectError(error.ResourceInUse, kernel.close());
    const capacity: gaussian_scope.Capacity = .{ .source_width = 4, .source_height = 3, .max_radius = 3, .scale = 1, .filter_samples = 2520 };
    try std.testing.expectEqual(@as(u64, 2520), try preflightGaussianScopes(buffer.commands(), 2, 1, buffer.coverageResources(), true, null, &.{}, buffer.filterResources(), capacity));
    var short = capacity;
    short.filter_samples -= 1;
    try std.testing.expectError(error.GaussianWorkExceeded, preflightGaussianScopes(buffer.commands(), 2, 1, buffer.coverageResources(), true, null, &.{}, buffer.filterResources(), short));
    buffer.reset();
    try view.lease.ensureUnused();
    try mask_lease.ensureUnused();
    try std.testing.expect(!storage.bound and storage.len == 0);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Command));
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(GroupCommand));
    std.debug.print("Gaussian recording sizes command={d} group={d} buffer={d} filterStorage={d} view={d}\n", .{ @sizeOf(Command), @sizeOf(GroupCommand), @sizeOf(Buffer), @sizeOf(FilterStorage), @sizeOf(gaussian.View) });
}

/// Index of the `end_effect` matching the `effect` at `start`.
pub fn effectEnd(list: []const Command, start: usize) ?usize {
    var depth: usize = 0;
    for (list[start..], start..) |command, index| switch (command) {
        .effect => depth += 1,
        .end_effect => {
            depth -= 1;
            if (depth == 0) return index;
        },
        else => {},
    };
    return null;
}

pub fn groupOptions(value: GroupCommand, coverage_resources: []const drawing.CoverageView) !layers.Group {
    const mask = if (value.mask_resource) |index| blk: {
        if (index >= coverage_resources.len) return error.MissingResources;
        break :blk coverage_resources[index];
    } else null;
    return .{ .opacity = value.opacity, .mask = mask, .mask_origin = value.mask_origin };
}
/// Validate group policy before replay can touch an ordinary opaque front.
pub fn preflightGroups(list: []const Command, capacity: u8, scale: f32, coverage_resources: []const drawing.CoverageView, legacy_text: bool) !void {
    return preflightScopes(list, capacity, scale, coverage_resources, legacy_text, null, &.{});
}

test "conic command copies caller stops and angle before atomic bounded publication" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 24, .height = 16 };
    var stops = [_]brushes.Stop{ .{ .offset = 0, .color = .rgb(0xff0000) }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
    try buffer.gradientRect(bounds, 4, .{ .conic = .{ .center = .{ .x = 12, .y = 8 }, .stops = &stops } });
    stops[0].color = .rgb(0x00ff00);
    try std.testing.expectEqual(@as(usize, 1), buffer.len);
    try std.testing.expectEqual(@as(usize, 1), buffer.brush_len);
    try std.testing.expectEqual(Color.rgb(0xff0000), buffer.brush_storage[0].stops[0].color);
    try std.testing.expectError(error.InvalidGradient, buffer.gradientRect(bounds, 0, .{ .conic = .{ .center = .{}, .start_angle_radians = std.math.nan(f64), .stops = &stops } }));
    try std.testing.expectEqual(@as(usize, 1), buffer.len);
    try std.testing.expectEqual(@as(usize, 1), buffer.brush_len);
    buffer.len = buffer.storage.len;
    try std.testing.expectError(error.CommandsFull, buffer.gradientRect(bounds, 0, .{ .conic = .{ .center = .{}, .stops = &stops } }));
    try std.testing.expectEqual(@as(usize, 1), buffer.brush_len);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Command));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(brushes.Stored));
}
pub fn preflightScopes(list: []const Command, capacity: u8, scale: f32, coverage_resources: []const drawing.CoverageView, legacy_text: bool, plan: ?layers.Plan, transforms: []const layers.NativeTransform) !void {
    _ = try preflightGaussianScopes(list, capacity, scale, coverage_resources, legacy_text, plan, transforms, &.{}, null);
}
pub fn preflightGaussianScopes(list: []const Command, capacity: u8, scale: f32, coverage_resources: []const drawing.CoverageView, legacy_text: bool, plan: ?layers.Plan, transforms: []const layers.NativeTransform, filters: []const gaussian.View, filter_capacity: ?gaussian_scope.Capacity) !u64 {
    if (capacity > layers.max_depth) return error.InvalidLayerLimits;
    if (transforms.len > 64) return error.TransformsFull;
    var groups: usize = 0;
    var clips: usize = 0;
    var saved: [layers.max_depth]usize = undefined;
    var kinds: [layers.max_depth]ScopeKind = undefined;
    var filter_work: u64 = 0;
    for (list) |op| switch (op) {
        .begin_group => |value| {
            if (capacity == 0) return error.LayersRequired;
            if (groups == capacity) return error.LayerDepthExceeded;
            const options = try groupOptions(value, coverage_resources);
            const r = value.bounds;
            try layers.validateGroup(.{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }, options, scale);
            if (value.filter_slot != no_filter) {
                if (value.filter_slot >= filters.len) return error.MissingResources;
                const view = filters[value.filter_slot];
                try view.validate();
                if (view.descriptor.scale != scale) return error.GaussianDpiMismatch;
                const filter_plan = filter_capacity orelse return error.GaussianNotPrepared;
                const capture = try gaussian_scope.Capture.init(.{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }, view.descriptor);
                try capture.check(filter_plan);
                filter_work = std.math.add(u64, filter_work, capture.samples()) catch return error.GaussianWorkExceeded;
                if (filter_work > filter_plan.filter_samples) return error.GaussianWorkExceeded;
            }
            saved[groups] = clips;
            kinds[groups] = .group;
            groups += 1;
        },
        .end_group => {
            if (groups == 0 or kinds[groups - 1] != .group) return error.GroupStackEmpty;
            if (clips != saved[groups - 1]) return error.UnbalancedGroupClips;
            groups -= 1;
        },
        .begin_transform => |slot| {
            const workspace = plan orelse return error.TransformsRequired;
            if (workspace.transform_source == null) return error.TransformsRequired;
            if (slot >= transforms.len) return error.MissingResources;
            try workspace.validateTransform(transforms[slot]);
            if (groups == capacity) return error.LayerDepthExceeded;
            saved[groups] = clips;
            kinds[groups] = .transform;
            groups += 1;
        },
        .end_transform => {
            if (groups == 0 or kinds[groups - 1] != .transform) return error.TransformStackEmpty;
            if (clips != saved[groups - 1]) return error.UnbalancedGroupClips;
            groups -= 1;
        },
        .push_clip => {
            if (clips == 32) return error.ClipStackFull;
            clips += 1;
        },
        .pop_clip => {
            if (clips == 0 or (groups != 0 and clips == saved[groups - 1])) return error.ClipStackEmpty;
            clips -= 1;
        },
        .text => if (!legacy_text) return error.LayerTextDisabled,
        else => {},
    };
    if (groups != 0) return error.UnbalancedGroups;
    if (clips != 0) return error.UnbalancedClips;
    return filter_work;
}

test "frame buffer owns text and failures do not partially append" {
    var buffer: Buffer = .{};
    var temporary = [_]u8{ 'h', 'i' };
    const rect: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try buffer.text(rect, &temporary, 0xffffff);
    temporary[0] = 'x';
    try std.testing.expectEqualStrings("hi", buffer.textBytes());
    try std.testing.expectError(error.InvalidUtf8, buffer.text(rect, "\xff", 0));
    try std.testing.expectEqual(1, buffer.len);
    try buffer.pushClip(rect);
    try std.testing.expectError(error.UnbalancedClips, buffer.finish());
    try buffer.popClip();
    try buffer.finish();
    try std.testing.expectError(error.ClipStackEmpty, buffer.popClip());
    while (buffer.len < buffer.storage.len) try buffer.fill(rect, 0);
    try std.testing.expectError(error.CommandsFull, buffer.text(rect, "extra", 0));
    try std.testing.expectEqual(2, buffer.text_len);
    buffer.reset();
    try std.testing.expectEqual(0, buffer.commands().len);
}

test "explicit transform storage is exclusive transactional and shares scope depth" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    var other: Buffer = .{};
    defer other.reset();
    var storage: TransformStorage = .{ .scale = 1.5 };
    const scope = try layers.NativeTransform.init(.{}, .{ .width = 8, .height = 6 }, 1.5);
    try std.testing.expectError(error.TransformStorageRequired, buffer.beginTransform(scope));
    try buffer.bindTransformStorage(&storage);
    try std.testing.expectError(error.TransformStorageInUse, other.bindTransformStorage(&storage));
    var bad = scope;
    bad.pixel_width += 1;
    try std.testing.expectError(error.InvalidTransform, buffer.beginTransform(bad));
    try std.testing.expectEqual(@as(usize, 0), storage.len);
    try buffer.beginTransform(scope);
    try std.testing.expectError(error.GroupStackEmpty, buffer.endGroup());
    try buffer.beginGroup(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{});
    try std.testing.expectError(error.TransformStackEmpty, buffer.endTransform());
    try buffer.endGroup();
    try buffer.endTransform();
    try buffer.beginTransform(scope);
    try buffer.endTransform();
    try std.testing.expectEqual(@as(usize, 1), storage.len);
    try buffer.finish();
    const plan = try layers.Plan.initTransforms(.{ .layers = .{ .size = .{ .width = 16, .height = 12, .scale = 1.5 } }, .source_size = .{ .width = 8, .height = 6 } }, .gdi);
    try preflightScopes(buffer.commands(), 2, 1.5, &.{}, true, plan, buffer.transformResources());
    try std.testing.expectError(error.TransformsRequired, preflightGroups(buffer.commands(), 2, 1.5, &.{}, true));
    buffer.reset();
    try std.testing.expect(buffer.transform_storage == null and !storage.bound and storage.len == 0);
    try other.bindTransformStorage(&storage);
}

test "prepared text pins are deduplicated bounded and released after every reset" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    var leases: [33]drawing.Lease = undefined;
    for (&leases) |*lease| lease.* = drawing.Lease.init(std.Thread.getCurrentId());
    const View = struct {
        fn make(lease: *drawing.Lease) drawing.PreparedTextView {
            return .{ .lease = lease, .platform = .windows, .native_layout = lease, .native_coverage = null, .coverage = .{ .pixels = &.{255}, .width = 1, .height = 1, .stride = 1, .origin_x = 0, .origin_y = 0, .scale = 1 } };
        }
    };
    const color = Color.rgb(0);
    try buffer.preparedText(.{}, View.make(&leases[0]), color);
    try buffer.preparedText(.{ .x = 20 }, View.make(&leases[0]), color);
    try std.testing.expectEqual(1, leases[0].pins);
    try std.testing.expectError(error.ResourceInUse, leases[0].ensureUnused());
    for (leases[1..32]) |*lease| try buffer.preparedText(.{}, View.make(lease), color);
    const count = buffer.len;
    try std.testing.expectError(error.PreparedTextResourcesFull, buffer.preparedText(.{}, View.make(&leases[32]), color));
    try std.testing.expectEqual(count, buffer.len);
    try std.testing.expectEqual(0, leases[32].pins);
    buffer.len = buffer.storage.len;
    try std.testing.expectError(error.CommandsFull, buffer.preparedText(.{}, View.make(&leases[0]), color));
    try std.testing.expectEqual(1, leases[0].pins);
    buffer.reset();
    buffer.reset();
    for (leases) |lease| try lease.ensureUnused();
    try std.testing.expectEqual(0, buffer.preparedTextResources().len);
}

test "image frame resources pin once and reject bad capacity and geometry without mutation" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    var leases: [33]drawing.Lease = undefined;
    for (&leases) |*lease| lease.* = drawing.Lease.init(std.Thread.getCurrentId());
    const levels = [_]drawing.ImageLevel{.{ .pixels = &.{ 0, 0, 0, 255 }, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 30, .height = 20 };
    const view: drawing.ImageView = .{ .lease = &leases[0], .identity = 1, .levels = &levels };
    try std.testing.expectError(error.InvalidImageOptions, buffer.image(bounds, view, .{ .alignment = .{ .x = -1 } }));
    try std.testing.expectError(error.InvalidGeometry, buffer.image(.{ .x = 0, .y = 0, .width = std.math.inf(f32), .height = 1 }, view, .{}));
    try std.testing.expectEqual(0, buffer.len);
    try std.testing.expectEqual(0, leases[0].pins);
    try buffer.image(bounds, view, .{});
    try buffer.image(bounds, view, .{ .opacity = 128, .fit = .cover });
    try std.testing.expectEqual(1, leases[0].pins);
    for (leases[1..32], 1..) |*lease, identity| try buffer.image(bounds, .{ .lease = lease, .identity = identity + 1, .levels = &levels }, .{});
    const count = buffer.len;
    try std.testing.expectError(error.ImageResourcesFull, buffer.image(bounds, .{ .lease = &leases[32], .identity = 33, .levels = &levels }, .{}));
    try std.testing.expectEqual(count, buffer.len);
    try std.testing.expectEqual(0, leases[32].pins);
    buffer.len = buffer.storage.len;
    try std.testing.expectError(error.CommandsFull, buffer.image(bounds, view, .{}));
    try std.testing.expectEqual(1, leases[0].pins);
    buffer.reset();
    buffer.reset();
    for (leases) |lease| try lease.ensureUnused();
}

test "coverage table pins once and rejects invalid or full appends transactionally" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    var leases: [33]drawing.Lease = undefined;
    for (&leases) |*lease| lease.* = drawing.Lease.init(std.Thread.getCurrentId());
    const pixels = [_]u8{ 0, 64, 128, 255 };
    var view: drawing.CoverageView = .{ .lease = &leases[0], .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &pixels, .width = 2, .height = 2, .stride = 2, .origin_x = -1, .origin_y = -1, .scale = 1 } };
    try std.testing.expectError(error.InvalidGeometry, buffer.coverage(.{ .x = std.math.inf(f32) }, view, Color.rgb(0)));
    const color: Color = .{ .r = 1, .g = 2, .b = 3, .a = 128 };
    try buffer.coverage(.{}, view, color);
    try buffer.coverage(.{ .x = 5 }, view, color);
    try std.testing.expectEqual(1, leases[0].pins);
    for (leases[1..32]) |*lease| {
        view.lease = lease;
        view.identity = try drawing.reserveRasterIdentity();
        try buffer.coverage(.{}, view, color);
    }
    view.lease = &leases[32];
    view.identity = try drawing.reserveRasterIdentity();
    const count = buffer.len;
    try std.testing.expectError(error.CoverageResourcesFull, buffer.coverage(.{}, view, color));
    try std.testing.expectEqual(count, buffer.len);
    try std.testing.expectEqual(0, leases[32].pins);
    view.coverage.stride = 4;
    try std.testing.expectError(error.InvalidCoverageResource, buffer.coverage(.{}, view, color));
    view.coverage.stride = 2;
    buffer.len = buffer.storage.len;
    try std.testing.expectError(error.CommandsFull, buffer.coverage(.{}, view, color));
    buffer.reset();
    buffer.reset();
    for (leases) |lease| try lease.ensureUnused();
    try std.testing.expectEqual(0, buffer.coverageResources().len);
}

test "coverage gradients atomically record a balanced scope and share one mask pin" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{ 0, 64, 128, 255 };
    const view: drawing.CoverageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &bytes, .width = 2, .height = 2, .stride = 2, .origin_x = -1, .origin_y = 2, .scale = 1.5 } };
    var stops = [_]brushes.Stop{ .{ .offset = 0, .color = Color.rgb(0xff0000) }, .{ .offset = 1, .color = Color.rgb(0x0000ff) } };
    const origin: drawing.Point = .{ .x = 4.25, .y = -2.5 };
    const gradient: Gradient = .{ .conic = .{ .center = .{ .x = 4, .y = 5 }, .stops = &stops, .interpolation = .oklab } };
    try buffer.gradientCoverage(origin, view, gradient);
    try std.testing.expectEqual(3, buffer.len);
    try std.testing.expectEqual(0, buffer.group_depth);
    try std.testing.expectEqual(1, buffer.brush_len);
    try std.testing.expectEqual(1, buffer.coverage_len);
    try std.testing.expectEqual(1, lease.pins);
    const group = buffer.storage[0].begin_group;
    try std.testing.expectEqualDeep(origin, group.mask_origin);
    try std.testing.expectEqual(@as(?u8, 0), group.mask_resource);
    try std.testing.expectEqual(@as(u8, 255), group.opacity);
    try std.testing.expectEqualDeep(group.bounds, buffer.storage[1].gradient.bounds);
    try std.testing.expect(buffer.storage[2] == .end_group);
    try buffer.finish();
    try preflightGroups(buffer.commands(), 1, 1.5, buffer.coverageResources(), true);
    try std.testing.expectError(error.LayersRequired, preflightGroups(buffer.commands(), 0, 1.5, buffer.coverageResources(), true));
    try std.testing.expectError(error.CoverageDpiMismatch, preflightGroups(buffer.commands(), 1, 2, buffer.coverageResources(), true));
    try buffer.gradientCoverage(origin, view, gradient);
    try std.testing.expectEqual(1, buffer.brush_len);
    try std.testing.expectEqual(1, buffer.coverage_len);
    try std.testing.expectEqual(1, lease.pins);
    stops[0].color = Color.rgb(0x00ff00);
    try std.testing.expectEqualDeep(Color.rgb(0xff0000), buffer.brush_storage[0].stops[0].color);
    try std.testing.expectEqualDeep(gradient.conic.center, buffer.brush_storage[0].a);
    try buffer.beginGroup(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{});
    const depth = buffer.group_depth;
    try buffer.gradientCoverage(origin, view, gradient);
    try std.testing.expectEqual(depth, buffer.group_depth);
    try buffer.endGroup();
    try buffer.finish();
    buffer.reset();
    try lease.ensureUnused();
}

test "coverage gradient failures preserve commands resources depths and existing pins" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    var leases: [33]drawing.Lease = undefined;
    for (&leases) |*lease| lease.* = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{ 0, 64, 128, 255 };
    var view: drawing.CoverageView = .{ .lease = &leases[0], .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &bytes, .width = 2, .height = 2, .stride = 2, .origin_x = 0, .origin_y = 0, .scale = 1 } };
    const stops = [_]brushes.Stop{ .{ .offset = 0, .color = Color.rgb(0xff0000) }, .{ .offset = 1, .color = Color.rgb(0x0000ff) } };
    const gradient: Gradient = .{ .linear = .{ .start = .{}, .end = .{ .x = 10 }, .stops = &stops } };
    try buffer.gradientCoverage(.{}, view, gradient);
    const initial_group = buffer.storage[0].begin_group;
    const initial_brush = buffer.brush_storage[0];
    var invalid = view;
    invalid.coverage.stride = 1;
    try expectCoverageGradientFailure(&buffer, invalid, gradient, error.InvalidCoverageResource);
    try expectCoverageGradientFailure(&buffer, view, .{ .linear = .{ .start = .{}, .end = .{}, .stops = &stops } }, error.InvalidGradient);
    buffer.len = buffer.storage.len - 2;
    try expectCoverageGradientFailure(&buffer, view, gradient, error.CommandsFull);
    buffer.len = 3;
    buffer.group_depth = layers.max_depth;
    try expectCoverageGradientFailure(&buffer, view, gradient, error.GroupStackFull);
    buffer.group_depth = 0;
    for (1..brushes.max_brushes) |index| try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, 0, gradient.translated(.{ .x = @floatFromInt(index) }));
    try expectCoverageGradientFailure(&buffer, view, gradient.translated(.{ .x = 100 }), error.BrushesFull);
    // A full brush table still accepts a reused descriptor.
    try buffer.gradientCoverage(.{}, view, gradient);
    for (leases[1..32]) |*lease| {
        view.lease = lease;
        view.identity = try drawing.reserveRasterIdentity();
        try buffer.coverage(.{}, view, Color.rgb(0));
    }
    view.lease = &leases[32];
    view.identity = try drawing.reserveRasterIdentity();
    try expectCoverageGradientFailure(&buffer, view, gradient, error.CoverageResourcesFull);
    try std.testing.expectEqual(0, leases[32].pins);
    // Full resource tables do not prevent reuse or acquire a second pin.
    view = buffer.coverage_storage[0];
    try buffer.gradientCoverage(.{}, view, gradient);
    try std.testing.expectEqual(1, leases[0].pins);
    try std.testing.expectEqualDeep(initial_group, buffer.storage[0].begin_group);
    try std.testing.expect(brushes.Stored.eql(&initial_brush, &buffer.brush_storage[0]));
    try buffer.finish();
    buffer.reset();
    for (leases) |lease| try lease.ensureUnused();
    leases[0].pins = std.math.maxInt(usize);
    try expectCoverageGradientFailure(&buffer, view, gradient, error.ResourcePinsFull);
    leases[0].pins = 0;
    try buffer.finish();
}

fn expectCoverageGradientFailure(buffer: *Buffer, view: drawing.CoverageView, gradient: Gradient, expected: anyerror) !void {
    const before = .{ buffer.len, buffer.brush_len, buffer.coverage_len, buffer.depth, buffer.group_depth, buffer.text_len, view.lease.pins };
    try std.testing.expectError(expected, buffer.gradientCoverage(.{}, view, gradient));
    try std.testing.expectEqualDeep(before, .{ buffer.len, buffer.brush_len, buffer.coverage_len, buffer.depth, buffer.group_depth, buffer.text_len, view.lease.pins });
}

test "coverage gradient bounds cover fractional bilinear support without moving the brush" {
    const bytes = [_]u8{255};
    for ([_]f32{ 0.0625, 1, 1.5, 2, 16 }) |scale| for ([_]f32{ -16777216, -2.75, 0, 3.125, 16777216 }) |delta| {
        const mask: drawing.Coverage = .{ .pixels = &bytes, .width = 1, .height = 1, .stride = 1, .origin_x = -2, .origin_y = 3, .scale = scale };
        const origin: drawing.Point = .{ .x = delta, .y = -delta };
        const bounds = try gradientCoverageBounds(origin, mask);
        const left = @as(f64, origin.x) + (-3.0 / scale);
        const top = @as(f64, origin.y) + (2.0 / scale);
        const right = @as(f64, origin.x); // origin_x + width + guard == 0
        const bottom = @as(f64, origin.y) + (5.0 / scale);
        try std.testing.expect(@as(f64, bounds.x) <= left);
        try std.testing.expect(@as(f64, bounds.y) <= top);
        try std.testing.expect(@as(f64, bounds.x) + bounds.width >= right);
        try std.testing.expect(@as(f64, bounds.y) + bounds.height >= bottom);
        try std.testing.expect(@as(f64, bounds.x + bounds.width) >= right);
        try std.testing.expect(@as(f64, bounds.y + bounds.height) >= bottom);
    };
    try std.testing.expectError(error.InvalidGeometry, gradientCoverageBounds(.{ .x = std.math.inf(f32) }, .{ .pixels = &bytes, .width = 1, .height = 1, .stride = 1, .origin_x = 0, .origin_y = 0, .scale = 1 }));
}

test "shape commands validate before consuming bounded frame storage" {
    var buffer: Buffer = .{};
    const bounds: Rect = .{ .x = 1, .y = 2, .width = 30, .height = 20 };
    const color: Color = .{ .r = 1, .g = 2, .b = 3, .a = 128 };
    try buffer.roundedRect(bounds, 999, color);
    try buffer.strokeRect(bounds, 3, 8, color);
    try std.testing.expectEqual(color, buffer.commands()[0].shape.color);
    try std.testing.expectEqual(@as(f32, 3), buffer.commands()[1].shape.radius);
    try std.testing.expectError(error.InvalidGeometry, buffer.roundedRect(bounds, std.math.nan(f32), color));
    try std.testing.expectError(error.InvalidGeometry, buffer.roundedRect(bounds, -1, color));
    try std.testing.expectError(error.InvalidGeometry, buffer.strokeRect(bounds, 3, 0, color));
    try std.testing.expectError(error.InvalidGeometry, buffer.strokeRect(bounds, 3, std.math.inf(f32), color));
    try std.testing.expectEqual(2, buffer.len);
    while (buffer.len < buffer.storage.len) try buffer.roundedRect(bounds, 0, color);
    try std.testing.expectError(error.CommandsFull, buffer.strokeRect(bounds, 3, 2, color));
    try std.testing.expectEqual(buffer.storage.len, buffer.len);
    try std.testing.expectEqual(0, buffer.text_len);
}

test "gradient storage is bounded transactional and movable without borrowed pointers" {
    var buffer: Buffer = .{};
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 30, .height = 20 };
    const stops = [_]brushes.Stop{ .{ .offset = 0, .color = Color.rgb(0xff0000) }, .{ .offset = 1, .color = Color.rgb(0x0000ff) } };
    const gradient: Gradient = .{ .linear = .{ .start = .{}, .end = .{ .x = 10 }, .stops = &stops } };
    try std.testing.expectError(error.InvalidGradient, buffer.gradientRect(bounds, 0, .{ .linear = .{ .start = .{}, .end = .{}, .stops = &stops } }));
    try std.testing.expectError(error.InvalidGradient, buffer.gradientRect(bounds, 0, .{ .radial = .{ .center = .{}, .radius = .{ .x = 0, .y = 2 }, .stops = &stops } }));
    var invalid = stops;
    invalid[0].offset = std.math.nan(f32);
    try std.testing.expectError(error.InvalidGradient, buffer.gradientRect(bounds, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 10 }, .stops = &invalid } }));
    const excess: [brushes.max_stops + 1]brushes.Stop = @splat(stops[0]);
    try std.testing.expectError(error.GradientStopsFull, buffer.gradientRect(bounds, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 10 }, .stops = &excess } }));
    try buffer.gradientRect(bounds, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 10 }, .stops = &.{ .{ .offset = 0.5, .color = Color.rgb(0xff0000) }, .{ .offset = 0.5, .color = Color.rgb(0x0000ff) } } } });
    try std.testing.expectEqual(1, buffer.len);
    try std.testing.expectEqual(1, buffer.brush_len);
    buffer.reset();
    try std.testing.expectEqual(0, buffer.len);
    try std.testing.expectEqual(0, buffer.brush_len);
    for (0..brushes.max_brushes) |index| try buffer.gradientRect(bounds, 0, gradient.translated(.{ .x = @floatFromInt(index) }));
    try std.testing.expectError(error.BrushesFull, buffer.gradientRect(bounds, 0, gradient.translated(.{ .x = 99 })));
    try std.testing.expectEqual(brushes.max_brushes, buffer.len);
    try std.testing.expectEqual(brushes.max_brushes, buffer.brush_len);
    try buffer.gradientRect(bounds, 0, gradient);
    try std.testing.expectEqual(brushes.max_brushes, buffer.brush_len);
    var moved = buffer;
    buffer.reset();
    try buffer.gradientRect(bounds, 0, gradient.translated(.{ .x = 99 }));
    try std.testing.expectEqual(@as(f32, 0), moved.brushResources()[0].a.x);
    try std.testing.expectEqual(@as(f32, 99), buffer.brushResources()[0].a.x);
    while (buffer.len < buffer.storage.len) try buffer.fill(bounds, 0);
    try std.testing.expectError(error.CommandsFull, buffer.gradientRect(bounds, 0, gradient));
    try std.testing.expectEqual(1, buffer.brush_len);
    try std.testing.expectEqual(buffer.storage.len, buffer.len);
    // Gradient stops live in one small table, not in every command.
    try std.testing.expect(@sizeOf(Command) <= 40);
    try std.testing.expect(@sizeOf(brushes.Stored) * brushes.max_brushes <= 6 * 1024);
}

test "gradient spread identity is copied deduplicated and transactionally bounded" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    const rect: Rect = .{ .x = 0, .y = 0, .width = 8, .height = 4 };
    var stops = [_]brushes.Stop{ .{ .offset = 0, .color = Color.rgb(0) }, .{ .offset = 1, .color = Color.rgb(0xffffff) } };
    var descriptor: Gradient = .{ .linear = .{ .start = .{}, .end = .{ .x = 4 }, .stops = &stops } };
    inline for (.{ brushes.Spread.pad, brushes.Spread.repeat, brushes.Spread.reflect }) |spread| {
        descriptor.linear.spread = spread;
        try buffer.gradientRect(rect, 0, descriptor);
    }
    try std.testing.expectEqual(@as(usize, 3), buffer.brush_len);
    descriptor.linear.spread = .repeat;
    try buffer.gradientRect(rect, 0, descriptor);
    try std.testing.expectEqual(@as(usize, 3), buffer.brush_len);
    try std.testing.expectEqual(@as(u8, 1), buffer.commands()[3].gradient.brush);
    stops[0].color = Color.rgb(0xff0000);
    try std.testing.expectEqual(Color.rgb(0), buffer.brushResources()[1].stops[0].color);
    while (buffer.len < buffer.storage.len) try buffer.fill(rect, 0);
    const old_brush_count = buffer.brush_len;
    try std.testing.expectError(error.CommandsFull, buffer.gradientRect(rect, 0, descriptor));
    try std.testing.expectEqual(old_brush_count, buffer.brush_len);
    try buffer.finish();
    buffer.reset();
    for (0..brushes.max_brushes) |index| try buffer.gradientRect(rect, 0, descriptor.translated(.{ .x = @floatFromInt(index) }));
    try std.testing.expectError(error.BrushesFull, buffer.gradientRect(rect, 0, descriptor.translated(.{ .x = 99 })));
    try std.testing.expectEqual(@as(usize, brushes.max_brushes), buffer.brush_len);
    try std.testing.expectEqual(@as(usize, brushes.max_brushes), buffer.len);
}

test "group commands pin masks transactionally and isolate clip stack ownership" {
    var buffer: Buffer = .{};
    defer buffer.reset();
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{255};
    const mask: drawing.CoverageView = .{ .lease = &lease, .identity = 1, .coverage = .{ .pixels = &bytes, .width = 1, .height = 1, .stride = 1, .origin_x = 0, .origin_y = 0, .scale = 1 } };
    const rect: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try buffer.pushClip(rect);
    try buffer.beginGroup(rect, .{ .mask = mask });
    try std.testing.expectError(error.ClipStackEmpty, buffer.popClip());
    try std.testing.expectEqual(@as(usize, 1), buffer.depth);
    try buffer.pushClip(rect);
    try std.testing.expectError(error.UnbalancedGroupClips, buffer.endGroup());
    try buffer.popClip();
    try buffer.endGroup();
    try buffer.popClip();
    try buffer.finish();
    try std.testing.expectEqual(@as(usize, 1), lease.pins);
    try preflightGroups(buffer.commands(), 2, 1, buffer.coverageResources(), true);
    try std.testing.expectError(error.LayersRequired, preflightGroups(buffer.commands(), 0, 1, buffer.coverageResources(), true));
    try std.testing.expectError(error.CoverageDpiMismatch, preflightGroups(buffer.commands(), 2, 2, buffer.coverageResources(), true));
    buffer.reset();
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
    for (0..layers.max_depth) |_| try buffer.beginGroup(rect, .{});
    const count = buffer.len;
    try std.testing.expectError(error.GroupStackFull, buffer.beginGroup(rect, .{ .mask = mask }));
    try std.testing.expectEqual(count, buffer.len);
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
    buffer.reset();
    buffer.len = buffer.storage.len;
    try std.testing.expectError(error.CommandsFull, buffer.beginGroup(rect, .{ .mask = mask }));
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
    try std.testing.expectEqual(@as(usize, 0), buffer.group_depth);
}

test "typed textures pin once and reject capacity or loss transactionally" {
    var epoch: drawing.GpuDomainEpoch = .{ .identity = 1, .status = 1 };
    var leases: [33]drawing.Lease = undefined;
    var tokens: [33]drawing.GpuTextureToken = undefined;
    var views: [33]drawing.TextureView = undefined;
    for (&leases, &tokens, &views, 0..) |*lease, *token, *view, index| {
        lease.* = drawing.Lease.init(std.Thread.getCurrentId());
        token.* = .{ .identity = index + 2, .generation = 1, .width = 1, .height = 1, .levels = 1 };
        view.* = .{ .lease = lease, .domain = &epoch, .token = token, .identity = token.identity, .generation = 1, .width = 1, .height = 1, .levels = 1 };
    }
    var buffer: Buffer = .{};
    defer buffer.reset();
    const rect: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try buffer.fill(rect, 0x123456);
    for (views[0..32]) |view| try buffer.texture(rect, view, .{});
    try buffer.texture(rect, views[0], .{});
    try std.testing.expectEqual(@as(usize, 1), leases[0].pins);
    try std.testing.expectEqual(@as(usize, 32), buffer.texture_len);
    const old_len = buffer.len;
    try std.testing.expectError(error.TextureResourcesFull, buffer.texture(rect, views[32], .{}));
    try std.testing.expectEqual(old_len, buffer.len);
    try std.testing.expectEqual(@as(usize, 0), leases[32].pins);
    try std.testing.expectError(error.UnsupportedTextureBackend, rejectTextures(buffer.commands()));
    epoch.status = 2;
    try std.testing.expectError(error.TextureDeviceLost, buffer.texture(rect, views[0], .{}));
    try std.testing.expectEqual(old_len, buffer.len);
    buffer.reset();
    for (&leases) |*lease| try lease.ensureUnused();
    epoch.status = 1;
    buffer.len = buffer.storage.len;
    try std.testing.expectError(error.CommandsFull, buffer.texture(rect, views[0], .{}));
    try std.testing.expectEqual(@as(usize, 0), leases[0].pins);
    try std.testing.expectEqual(@as(usize, 0), buffer.texture_len);
}

test "text commands carry their font compactly" {
    var buffer: Buffer = .{};
    try buffer.textFont(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, "x", 0, .heading2);
    try buffer.text(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, "y", 0);
    const list = buffer.commands();
    try std.testing.expectEqual(@as(f32, 26), list[0].text.font.size());
    try std.testing.expectEqual(Font.Weight.bold, list[0].text.font.weight);
    try std.testing.expect(!list[0].text.font.isDefault() and list[1].text.font.isDefault());
    try std.testing.expectEqual(@as(u16, 700), Font.Weight.bold.value());
    try std.testing.expectEqual(@as(f32, 14.5), (Font{ .size = 14.5, .monospace = true }).key().size());
    try std.testing.expectError(error.InvalidFont, buffer.textFont(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, "z", 0, .{ .size = 0 }));
    try std.testing.expectError(error.InvalidFont, buffer.textFont(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, "z", 0, .{ .size = std.math.nan(f32) }));
    try std.testing.expectEqual(@as(usize, 2), buffer.len);
}
