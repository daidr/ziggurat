const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const drawing = @import("ziggurat_drawing_resources");
const commands = @import("commands.zig");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const layers = @import("layers.zig");
const gaussian_scope = @import("gaussian_scope.zig");

/// Internal shared preflight and linear pin capture. No native operations.
pub const Options = struct {
    size: z.Size,
    max_depth: u8,
    legacy_text: layers.LegacyText,
    render_work: u64,
    texture_domain: ?*const drawing.GpuDomainEpoch = null,
    output_copy: bool = true,
    transform_plan: ?layers.Plan = null,
    gaussian_capacity: ?gaussian_scope.Capacity = null,
};

fn rect(value: layout.Rect, scale: f32) !void {
    if (!layout.validRect(value) or !std.math.isFinite(value.x + value.width) or !std.math.isFinite(value.y + value.height)) return error.InvalidGeometry;
    for ([_]f64{ @as(f64, value.x) * scale, @as(f64, value.y) * scale, (@as(f64, value.x) + value.width) * scale, (@as(f64, value.y) + value.height) * scale }) |coordinate| {
        if (coordinate < std.math.minInt(i32) or coordinate > std.math.maxInt(i32)) return error.InvalidGeometry;
    }
}
fn point(value: drawing.Point) !void {
    if (!std.math.isFinite(value.x) or !std.math.isFinite(value.y)) return error.InvalidGeometry;
}
pub fn preflight(buffer: *const commands.Buffer, options: Options) !u64 {
    // Validate lengths before calling any accessor on externally mutable storage.
    if (buffer.len > buffer.storage.len or buffer.text_len > buffer.text_storage.len or buffer.brush_len > buffer.brush_storage.len or buffer.prepared_text_len > buffer.prepared_text_storage.len or buffer.image_len > buffer.image_storage.len or buffer.coverage_len > buffer.coverage_storage.len or buffer.texture_len > buffer.texture_storage.len) return error.InvalidBuffer;
    if (buffer.transform_storage) |storage| if (!storage.bound or storage.len > storage.storage.len) return error.InvalidBuffer;
    if (buffer.filter_storage) |storage| if (!storage.bound or storage.len > storage.storage.len) return error.InvalidBuffer;
    if (options.texture_domain == null) try commands.rejectTextures(buffer.commands());
    try buffer.finish();
    _ = try commands.preflightGaussianScopes(buffer.commands(), options.max_depth, options.size.scale, buffer.coverageResources(), options.legacy_text == .grayscale, options.transform_plan, buffer.transformResources(), buffer.filterResources(), options.gaussian_capacity);
    for (buffer.brushResources()) |*brush| try brush.validate();
    for (buffer.preparedTextResources()) |view| {
        try view.validate();
        if (view.coverage.scale != options.size.scale) return error.PreparedDpiMismatch;
        if (view.platform != @as(drawing.Platform, if (builtin.os.tag == .linux) .linux else .windows)) return error.PreparedPlatformMismatch;
    }
    for (buffer.imageResources()) |view| try view.validate();
    for (buffer.textureResources()) |view| {
        try view.validate();
        const domain = options.texture_domain orelse return error.UnsupportedTextureBackend;
        if (view.domain != domain) return error.TextureDomainMismatch;
    }
    for (buffer.coverageResources()) |view| {
        try view.validate();
        if (view.coverage.scale != options.size.scale) return error.CoverageDpiMismatch;
    }
    const pixels: u64 = if ((buffer.transformResources().len != 0 or buffer.filterResources().len != 0) and options.transform_plan != null) options.transform_plan.?.pool_plane_bytes / 4 else @as(u64, options.size.width) * options.size.height;
    var visits: u64 = pixels * @as(u64, if (options.output_copy) 2 else 1);
    for (buffer.commands()) |command| {
        const weight: u64 = switch (command) {
            .fill => |value| blk: {
                try rect(value.bounds, options.size.scale);
                break :blk 1;
            },
            .shape => |value| blk: {
                _ = try geometry.plan(value);
                try rect(value.bounds, options.size.scale);
                break :blk 1;
            },
            .gradient => |value| blk: {
                if (value.brush >= buffer.brush_len) return error.MissingResources;
                _ = try geometry.plan(.{ .bounds = value.bounds, .radius = value.radius, .stroke_width = value.stroke_width, .color = geometry.Color.rgb(0) });
                try rect(value.bounds, options.size.scale);
                break :blk 1;
            },
            .text => |value| blk: {
                try rect(value.bounds, options.size.scale);
                if (value.offset > buffer.text_len or value.len > buffer.text_len - value.offset) return error.InvalidTextRange;
                if (value.len > 2048) return error.TextTooLong;
                if (!std.unicode.utf8ValidateSlice(buffer.textBytes()[value.offset..][0..value.len])) return error.InvalidUtf8;
                break :blk 3; // glyph scratch clear, draw and alpha composite
            },
            .prepared_text => |value| blk: {
                if (value.resource >= buffer.prepared_text_len) return error.MissingResources;
                try point(value.origin);
                break :blk 1;
            },
            .coverage => |value| blk: {
                if (value.resource >= buffer.coverage_len) return error.MissingResources;
                try point(value.origin);
                break :blk 1;
            },
            .texture => |value| blk: {
                if (value.resource >= buffer.texture_len) return error.MissingResources;
                try rect(value.destination, options.size.scale);
                _ = try drawing.planTexture(buffer.textureResources()[value.resource], .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, .{ .alignment = value.alignment, .fit = value.fit, .sampling = value.sampling, .opacity = value.opacity }, options.size.scale);
                break :blk 1;
            },
            .image => |value| blk: {
                if (value.resource >= buffer.image_len) return error.MissingResources;
                try rect(value.destination, options.size.scale);
                _ = try drawing.planImage(buffer.imageResources()[value.resource], .{ .x = value.destination.x, .y = value.destination.y, .width = value.destination.width, .height = value.destination.height }, .{ .alignment = value.alignment, .fit = value.fit, .sampling = value.sampling, .opacity = value.opacity }, options.size.scale);
                break :blk 1;
            },
            .push_clip => |value| blk: {
                try rect(value, options.size.scale);
                break :blk 0;
            },
            .begin_group => |value| blk: {
                try rect(value.bounds, options.size.scale);
                break :blk 1;
            },
            .end_group => 3, // opacity pass, parent mask read and composite
            .begin_transform => 1, // clear the reserved source including guard
            .end_transform => 1, // inverse sample and source-over composite
            .pop_clip => 0,
            .backdrop => |slot| blk: {
                const entries = buffer.backdropEntries();
                if (slot >= entries.len) return error.MissingResources;
                try rect(entries[slot].bounds, options.size.scale);
                break :blk 4; // copy, two filter passes and composite
            },
            .indicator => |slot| blk: {
                const entries = buffer.indicatorEntries();
                if (slot >= entries.len) return error.MissingResources;
                try rect(entries[slot].bounds, options.size.scale);
                break :blk 1;
            },
            .effect => |slot| blk: {
                const entries = buffer.shaderEntries();
                if (slot >= entries.len) return error.MissingResources;
                try rect(entries[slot].captureBounds(), options.size.scale);
                break :blk 6; // save, two fills and copies, recovery and composite
            },
            .end_effect => 0,
            .backdrop_shader => |slot| blk: {
                const entries = buffer.shaderEntries();
                if (slot >= entries.len) return error.MissingResources;
                try rect(entries[slot].box, options.size.scale);
                break :blk 2; // copy and shade
            },
        };
        visits = std.math.add(u64, visits, pixels * weight) catch return error.RenderWorkExceeded;
        if (visits > options.render_work) return error.RenderWorkExceeded;
    }
    if (visits > options.render_work) return error.RenderWorkExceeded;
    return visits;
}
pub fn capture(destination: *commands.Buffer, source: *const commands.Buffer) !void {
    if (destination == source) return error.BufferAlias;
    if (source.transform_storage) |storage| {
        if (!storage.bound or storage.len > storage.storage.len) return error.InvalidBuffer;
        if (storage.len != 0) {
            const target = destination.transform_storage orelse return error.TransformStorageRequired;
            if (target == storage) return error.BufferAlias;
            if (!target.bound or target.len != 0 or target.scale != storage.scale) return error.InvalidTransformStorage;
        }
    }
    if (source.filter_storage) |storage| {
        if (!storage.bound or storage.len > storage.storage.len) return error.InvalidBuffer;
        if (storage.len != 0) {
            const target = destination.filter_storage orelse return error.GaussianStorageRequired;
            if (target == storage) return error.BufferAlias;
            if (!target.bound or target.len != 0) return error.GaussianStorageInUse;
        }
    }
    std.debug.assert(destination.len == 0 and destination.prepared_text_len == 0 and destination.image_len == 0 and destination.coverage_len == 0 and destination.texture_len == 0);
    errdefer destination.reset();
    // Do not raw-copy an owning Buffer. Publish each resource count only after
    // its independent lease acquisition; rollback releases just those pins.
    for (source.preparedTextResources()) |view| {
        try view.lease.acquire();
        destination.prepared_text_storage[destination.prepared_text_len] = view;
        destination.prepared_text_len += 1;
    }
    for (source.imageResources()) |view| {
        try view.lease.acquire();
        destination.image_storage[destination.image_len] = view;
        destination.image_len += 1;
    }
    for (source.coverageResources()) |view| {
        try view.lease.acquire();
        destination.coverage_storage[destination.coverage_len] = view;
        destination.coverage_len += 1;
    }
    for (source.textureResources()) |view| {
        try view.lease.acquire();
        destination.texture_storage[destination.texture_len] = view;
        destination.texture_len += 1;
    }
    if (source.filterResources().len != 0) {
        const target = destination.filter_storage.?;
        for (source.filterResources()) |view| {
            try view.lease.acquire();
            target.storage[target.len] = view;
            target.len += 1;
        }
    }
    @memcpy(destination.storage[0..source.len], source.commands());
    @memcpy(destination.text_storage[0..source.text_len], source.textBytes());
    @memcpy(destination.brush_storage[0..source.brush_len], source.brushResources());
    if (source.transformResources().len != 0) {
        const target = destination.transform_storage.?;
        @memcpy(target.storage[0..source.transformResources().len], source.transformResources());
        target.len = source.transformResources().len;
    }
    destination.len = source.len;
    destination.text_len = source.text_len;
    destination.brush_len = source.brush_len;
    // Effect tables are plain values; the workspaces stay the source's.
    @memcpy(destination.backdrop_storage.entries[0..source.backdrop_storage.len], source.backdropEntries());
    destination.backdrop_storage.len = source.backdrop_storage.len;
    destination.backdrop_storage.workspace = source.backdrop_storage.workspace;
    @memcpy(destination.indicator_storage[0..source.indicator_len], source.indicatorEntries());
    destination.indicator_len = source.indicator_len;
    @memcpy(destination.shader_storage.entries[0..source.shader_storage.len], source.shaderEntries());
    destination.shader_storage.len = source.shader_storage.len;
    destination.shader_storage.workspace = source.shader_storage.workspace;
}

test "batch preflight bounds work and capture owns independent resource pins" {
    var image_lease = drawing.Lease.init(std.Thread.getCurrentId());
    var texture_lease = drawing.Lease.init(std.Thread.getCurrentId());
    const pixels = [_]u8{ 0, 0, 0, 0 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &pixels, .width = 1, .height = 1, .stride = 4, .byte_len = 4 }};
    var epoch: drawing.GpuDomainEpoch = .{ .identity = 2, .status = 1 };
    const token: drawing.GpuTextureToken = .{ .identity = 3, .generation = 1, .width = 1, .height = 1, .levels = 1 };
    var source: commands.Buffer = .{};
    defer source.reset();
    const bounds: layout.Rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 };
    try source.image(bounds, .{ .lease = &image_lease, .identity = 1, .levels = &levels }, .{});
    try source.texture(bounds, .{ .lease = &texture_lease, .domain = &epoch, .token = &token, .identity = 3, .generation = 1, .width = 1, .height = 1, .levels = 1 }, .{});
    var options: Options = .{ .size = .{ .width = 4, .height = 4, .scale = 1 }, .max_depth = 1, .legacy_text = .grayscale, .render_work = 48, .output_copy = false };
    try std.testing.expectError(error.UnsupportedTextureBackend, preflight(&source, options));
    options.texture_domain = &epoch;
    try std.testing.expectEqual(@as(u64, 48), try preflight(&source, options));
    options.render_work = 47;
    try std.testing.expectError(error.RenderWorkExceeded, preflight(&source, options));
    try std.testing.expectError(error.BufferAlias, capture(&source, &source));
    var target: commands.Buffer = .{};
    defer target.reset();
    texture_lease.pins = std.math.maxInt(usize);
    try std.testing.expectError(error.ResourcePinsFull, capture(&target, &source));
    try std.testing.expectEqual(@as(usize, 1), image_lease.pins);
    try std.testing.expectEqual(@as(usize, 0), target.image_len);
    texture_lease.pins = 1;
    try capture(&target, &source);
    source.reset();
    try std.testing.expectEqual(@as(usize, 1), image_lease.pins);
    try std.testing.expectEqual(@as(usize, 1), texture_lease.pins);
    try std.testing.expectEqual(@as(usize, 2), target.len);
    target.reset();
    try image_lease.ensureUnused();
    try texture_lease.ensureUnused();
    source.len = source.storage.len + 1;
    try std.testing.expectError(error.InvalidBuffer, preflight(&source, options));
    source.len = 0;
}

test "captured transform descriptors are independent and binding aliases fail before publication" {
    var source: commands.Buffer = .{};
    defer source.reset();
    var destination: commands.Buffer = .{};
    defer destination.reset();
    var from: commands.TransformStorage = .{};
    var to: commands.TransformStorage = .{};
    try source.bindTransformStorage(&from);
    const descriptor = try layers.NativeTransform.init(.{ .x0 = 2 }, .{ .width = 4, .height = 4 }, 1);
    try source.beginTransform(descriptor);
    try source.endTransform();
    try std.testing.expectError(error.TransformStorageRequired, capture(&destination, &source));
    destination.transform_storage = &from;
    try std.testing.expectError(error.BufferAlias, capture(&destination, &source));
    destination.transform_storage = null;
    try destination.bindTransformStorage(&to);
    try capture(&destination, &source);
    source.reset();
    from.storage[0].x0 = 1234;
    try std.testing.expectEqual(@as(f64, 2), destination.transformResources()[0].x0);
    destination.reset();
    try std.testing.expect(!from.bound and !to.bound);
    try std.testing.expectEqual(@as(usize, 0), to.len);
}
