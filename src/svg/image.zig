const std = @import("std");
const zio = @import("ziggurat_io");
const drawing = @import("ziggurat_drawing_resources");
const v = @import("ziggurat_vector");
const d = @import("document.zig");
const pre = @import("prepare.zig");
const shapes = @import("shape.zig");

/// Limits for one SVG preparation. bytes includes all retained borrowed image
/// levels and the tight base-level snapshots; scene.bytes separately bounds
/// every owned cache/paint descriptor and pixel allocation.
pub const Limits = struct {
    requests: usize = 64,
    instances: usize = 1024,
    pixels: usize = 16 * 1024 * 1024,
    bytes: usize = 96 * 1024 * 1024,
    work: u64 = 128 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.requests == 0 or self.requests > 4096 or self.instances == 0 or self.instances > 65536 or self.pixels == 0 or self.pixels > 16 * 1024 * 1024 or self.bytes == 0 or self.bytes > 256 * 1024 * 1024 or self.work == 0 or self.work > 1024 * 1024 * 1024) return error.InvalidImageLimits;
    }
};

/// A synchronous lookup into caller-prepared immutable image resources.
/// The complete canonical data URI is an opaque resource key. The caller owns
/// decoding and verifies that its resource corresponds to that key before
/// prepare; resolve must not decode, perform I/O, wait or create worker work.
/// The provider and every returned resource remain pinned through preparation.
pub const Provider = struct {
    context: *anyopaque,
    lease: *drawing.Lease,
    resolve_fn: *const fn (*anyopaque, []const u8) anyerror!drawing.ImageView,
    limits: Limits = .{},
};

/// Only explicitly embedded raster keys are accepted. No percent decoding,
/// whitespace, alternative alphabets, fragments or parameters are inferred.
pub fn href(nodes: []const d.Node, at: usize) ![]const u8 {
    const node = nodes[at];
    if (node.attribute("xlink:href")) |value| {
        var ancestor: ?usize = at;
        var valid = false;
        while (ancestor) |index| {
            if (nodes[index].attribute("xmlns:xlink")) |uri| {
                valid = std.mem.eql(u8, uri, "http://www.w3.org/1999/xlink");
                break;
            }
            ancestor = nodes[index].parent;
        }
        if (!valid) return error.UnsupportedNamespace;
        try validateKey(value);
    }
    const value = node.attribute("href") orelse node.attribute("xlink:href") orelse return error.MissingImageReference;
    try validateKey(value);
    return value;
}
fn base64Value(byte: u8) ?u6 {
    return switch (byte) {
        'A'...'Z' => @intCast(byte - 'A'),
        'a'...'z' => @intCast(byte - 'a' + 26),
        '0'...'9' => @intCast(byte - '0' + 52),
        '+' => 62,
        '/' => 63,
        else => null,
    };
}
pub fn validateKey(value: []const u8) !void {
    const prefixes = [_][]const u8{ "data:image/png;base64,", "data:image/jpeg;base64,", "data:image/bmp;base64,", "data:image/gif;base64,", "data:image/webp;base64," };
    var payload: ?[]const u8 = null;
    for (prefixes) |prefix| if (std.mem.startsWith(u8, value, prefix)) {
        payload = value[prefix.len..];
        break;
    };
    const bytes = payload orelse return error.ExternalImageDenied;
    if (bytes.len == 0 or bytes.len % 4 != 0) return error.InvalidImageDataUri;
    var padding: usize = 0;
    if (bytes[bytes.len - 1] == '=') padding += 1;
    if (bytes[bytes.len - 2] == '=') padding += 1;
    for (bytes[0 .. bytes.len - padding]) |byte| if (base64Value(byte) == null) return error.InvalidImageDataUri;
    if (padding == 1 and (base64Value(bytes[bytes.len - 2]).? & 3) != 0) return error.InvalidImageDataUri;
    if (padding == 2 and (base64Value(bytes[bytes.len - 3]).? & 15) != 0) return error.InvalidImageDataUri;
}

pub fn box(node: d.Node, viewport: shapes.Viewport) !pre.Box {
    if (node.attribute("width") == null or node.attribute("height") == null) return error.ImageSizeRequired;
    const result: pre.Box = .{ .x = try shapes.coordinate(node, "x", 0, viewport.width), .y = try shapes.coordinate(node, "y", 0, viewport.height), .width = try shapes.coordinate(node, "width", 0, viewport.width), .height = try shapes.coordinate(node, "height", 0, viewport.height) };
    if (result.width < 0 or result.height < 0) return error.InvalidImageSize;
    try v.validPoint(.{ .x = result.x, .y = result.y });
    try v.validPoint(.{ .x = result.x + result.width, .y = result.y + result.height });
    // Validate even disabled/culled images before a provider request.
    _ = try pre.viewTransform(.{ .width = 1, .height = 1 }, node, 1, 1);
    return result;
}

pub const Snapshot = struct {
    next: ?*Snapshot,
    key: []const u8,
    lease: *drawing.Lease,
    pixels: []u8,
    width: u32,
    height: u32,
};
pub const Paint = struct {
    next: ?*Paint = null,
    image: *const Snapshot,
    inverse: v.Transform,
    pub fn validate(self: Paint) !void {
        inline for (zio.fields(v.Transform)) |field| if (!std.math.isFinite(@field(self.inverse, field.name)) or @abs(@field(self.inverse, field.name)) > 1e15) return error.UnsupportedImagePrecision;
        if (self.image.width == 0 or self.image.height == 0 or @as(u64, self.image.width) * self.image.height * 4 != self.image.pixels.len) return error.InvalidImageResource;
    }
    /// Bilinear sampling of premultiplied BGRA8 at physical pixel centers.
    /// All channels stay continuous until the compositor's final resolve.
    pub fn sample(self: Paint, point: v.Point) ![4]f64 {
        const source = self.inverse.apply(point);
        if (!std.math.isFinite(source.x) or !std.math.isFinite(source.y)) return error.UnsupportedImagePrecision;
        const x = std.math.clamp(source.x - 0.5, 0, @as(f64, @floatFromInt(self.image.width - 1)));
        const y = std.math.clamp(source.y - 0.5, 0, @as(f64, @floatFromInt(self.image.height - 1)));
        const x0: usize = @intFromFloat(@floor(x));
        const y0: usize = @intFromFloat(@floor(y));
        const x1 = @min(x0 + 1, self.image.width - 1);
        const y1 = @min(y0 + 1, self.image.height - 1);
        const fx = x - @floor(x);
        const fy = y - @floor(y);
        const weights = [4]f64{ (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy };
        const offsets = [4]usize{ (y0 * self.image.width + x0) * 4, (y0 * self.image.width + x1) * 4, (y1 * self.image.width + x0) * 4, (y1 * self.image.width + x1) * 4 };
        var result: [4]f64 = @splat(0);
        for (offsets, weights) |offset, weight| for (&result, self.image.pixels[offset..][0..4]) |*channel, byte| {
            channel.* += @as(f64, @floatFromInt(byte)) * weight;
        };
        return result;
    }
};
pub const Placement = struct { rectangle: pre.Box, inverse: v.Transform };
pub fn place(node: d.Node, positioning: pre.Box, width: u32, height: u32, matrix: v.Transform) !?Placement {
    const fit = (try pre.viewTransform(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) }, node, positioning.width, positioning.height)).then(.{ .x0 = positioning.x, .y0 = positioning.y });
    const full = fit.then(matrix);
    inline for (zio.fields(v.Transform)) |field| if (!std.math.isFinite(@field(full, field.name)) or @abs(@field(full, field.name)) > 1e15) return error.UnsupportedImagePrecision;
    const determinant = full.xx * full.yy - full.xy * full.yx;
    if (determinant == 0) {
        if (pre.nonsingular(full)) return error.UnsupportedImagePrecision;
        return null;
    }
    const inverse: v.Transform = .{ .xx = full.yy / determinant, .xy = -full.xy / determinant, .yx = -full.yx / determinant, .yy = full.xx / determinant, .x0 = (full.xy * full.y0 - full.yy * full.x0) / determinant, .y0 = (full.yx * full.x0 - full.xx * full.y0) / determinant };
    inline for (zio.fields(v.Transform)) |field| if (!std.math.isFinite(@field(inverse, field.name)) or @abs(@field(inverse, field.name)) > 1e15) return error.UnsupportedImagePrecision;
    const left = @max(positioning.x, fit.x0);
    const top = @max(positioning.y, fit.y0);
    const right = @min(positioning.x + positioning.width, fit.x0 + fit.xx * @as(f64, @floatFromInt(width)));
    const bottom = @min(positioning.y + positioning.height, fit.y0 + fit.yy * @as(f64, @floatFromInt(height)));
    return .{ .rectangle = .{ .x = left, .y = top, .width = right - left, .height = bottom - top }, .inverse = inverse };
}
