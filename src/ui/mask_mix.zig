//! How the software planes draw a masked clip (`Command.push_mask_clip`):
//! the pixels beneath the clip are kept when it opens, what is inside is
//! drawn on the plane as usual, and when it closes each pixel becomes the
//! kept one mixed toward the drawn one by the mask there. For drawing that
//! composites over what lies beneath, that is the same as drawing it into a
//! layer and compositing the layer through the mask, without a layer:
//! gradients, effects and groups inside draw on the plane as they always do.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
const cpu_gradient = @import("cpu_gradient.zig");
const layout = @import("layout.zig");

pub const max_depth = 32;

/// Where a mask lies on a plane: its pixel (0, 0) is at device pixel
/// `x`, `y` of the plane, which may fall between pixels.
pub const Placement = struct { x: f64, y: f64 };

pub const Scope = struct {
    /// Device pixels of the plane the clip covers: left, top, right, bottom.
    box: [4]u32,
    /// Where its kept pixels start in `Stack.pixels`.
    offset: usize,
    coverage: drawing.Coverage,
    place: Placement,
};

/// The kept pixels of the masked clips open, innermost last.
pub const Stack = struct {
    scopes: [max_depth]Scope = undefined,
    len: usize = 0,
    pixels: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        self.pixels.deinit(allocator);
        self.* = .{};
    }
    pub fn reset(self: *Stack) void {
        self.len = 0;
        self.pixels.clearRetainingCapacity();
    }
    /// Keep the pixels of `surface` under `rect` (DIP, within its clip) for
    /// the clip that opens now, masked by `coverage` placed from `origin`.
    pub fn open(self: *Stack, allocator: std.mem.Allocator, surface: cpu_gradient.Surface, rect: layout.Rect, origin: drawing.Point, coverage: drawing.Coverage) !void {
        if (self.len == max_depth) return error.ClipStackFull;
        const box = deviceBox(surface, rect);
        const offset = self.pixels.items.len;
        const width = box[2] - box[0];
        const height = box[3] - box[1];
        try self.pixels.ensureUnusedCapacity(allocator, @as(usize, width) * height);
        for (box[1]..box[3]) |y| self.pixels.appendSliceAssumeCapacity(surface.pixels[y * surface.stride + box[0] ..][0..width]);
        const scale: f64 = surface.scale;
        self.scopes[self.len] = .{
            .box = box,
            .offset = offset,
            .coverage = coverage,
            .place = .{ .x = @as(f64, origin.x) * scale + @as(f64, @floatFromInt(coverage.origin_x)) + surface.origin[0], .y = @as(f64, origin.y) * scale + @as(f64, @floatFromInt(coverage.origin_y)) + surface.origin[1] },
        };
        self.len += 1;
    }
    /// Close the innermost clip on `surface`, the plane it opened on: mix
    /// each of its pixels from the kept one by the mask. Returns the box
    /// it changed.
    pub fn close(self: *Stack, surface: cpu_gradient.Surface) ![4]u32 {
        if (self.len == 0) return error.ClipStackEmpty;
        self.len -= 1;
        const scope = self.scopes[self.len];
        defer self.pixels.shrinkRetainingCapacity(scope.offset);
        const width = scope.box[2] - scope.box[0];
        var at = scope.offset;
        for (scope.box[1]..scope.box[3]) |y| {
            const row = surface.pixels[y * surface.stride ..];
            for (scope.box[0]..scope.box[2]) |x| {
                const kept = self.pixels.items[at];
                at += 1;
                const m = sample(scope.coverage, @as(f64, @floatFromInt(x)) - scope.place.x, @as(f64, @floatFromInt(y)) - scope.place.y);
                row[x] = mix(kept, row[x], m);
            }
        }
        _ = width;
        return scope.box;
    }
};

/// The device pixels of `surface` that `rect` (DIP) touches, within its
/// clip and size.
fn deviceBox(surface: cpu_gradient.Surface, rect: layout.Rect) [4]u32 {
    const scale: f64 = surface.scale;
    const x0 = @max(@as(f64, rect.x) * scale + surface.origin[0], surface.clip[0], 0);
    const y0 = @max(@as(f64, rect.y) * scale + surface.origin[1], surface.clip[1], 0);
    const x1 = @min((@as(f64, rect.x) + rect.width) * scale + surface.origin[0], surface.clip[2], @as(f64, @floatFromInt(surface.width)));
    const y1 = @min((@as(f64, rect.y) + rect.height) * scale + surface.origin[1], surface.clip[3], @as(f64, @floatFromInt(surface.height)));
    if (!(x1 > x0 and y1 > y0)) return .{ 0, 0, 0, 0 };
    const left: u32 = @intFromFloat(@floor(x0));
    const top: u32 = @intFromFloat(@floor(y0));
    return .{ left, top, @max(left, @as(u32, @intFromFloat(@ceil(x1)))), @max(top, @as(u32, @intFromFloat(@ceil(y1)))) };
}

/// The mask's value, 0 to 256, at the pixel whose top left corner is
/// (u, v) in its own pixels: sampled between its pixels, none outside.
fn sample(c: drawing.Coverage, u: f64, v: f64) u32 {
    const fu = @floor(u);
    const fv = @floor(v);
    const ix: i64 = @intFromFloat(fu);
    const iy: i64 = @intFromFloat(fv);
    const tx = u - fu;
    const ty = v - fv;
    if (tx == 0 and ty == 0) return @as(u32, texel(c, ix, iy)) * 256 / 255;
    const a: f64 = @floatFromInt(texel(c, ix, iy));
    const b: f64 = @floatFromInt(texel(c, ix + 1, iy));
    const d: f64 = @floatFromInt(texel(c, ix, iy + 1));
    const e: f64 = @floatFromInt(texel(c, ix + 1, iy + 1));
    const value = (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty;
    return @intFromFloat(@round(value * 256 / 255));
}
fn texel(c: drawing.Coverage, x: i64, y: i64) u8 {
    if (x < 0 or y < 0 or x >= c.width or y >= c.height) return 0;
    return c.pixels[@as(usize, @intCast(y)) * c.stride + @as(usize, @intCast(x))];
}
/// `kept` moved toward `drawn` by `m` of 256, channel by channel, as both
/// are premultiplied.
fn mix(kept: u32, drawn: u32, m: u32) u32 {
    if (m >= 256) return drawn;
    if (m == 0) return kept;
    var out: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |shift| {
        const k: i32 = @intCast((kept >> shift) & 0xff);
        const d: i32 = @intCast((drawn >> shift) & 0xff);
        const v = k + (((d - k) * @as(i32, @intCast(m)) + 128) >> 8);
        out |= @as(u32, @intCast(std.math.clamp(v, 0, 255))) << shift;
    }
    return out;
}

test "a masked clip keeps what is beneath where its mask is clear" {
    var pixels: [4 * 4]u32 = @splat(0xff0000ff);
    const surface: cpu_gradient.Surface = .{ .pixels = &pixels, .width = 4, .height = 4, .stride = 4, .scale = 1, .clip = .{ 0, 0, 4, 4 }, .origin = .{ 0, 0 } };
    var stack: Stack = .{};
    defer stack.deinit(std.testing.allocator);
    // A mask over the clip's left half, solid, and half on its second column.
    const mask = [_]u8{ 255, 128, 0, 0, 255, 128, 0, 0, 255, 128, 0, 0, 255, 128, 0, 0 };
    try stack.open(std.testing.allocator, surface, .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{}, .{ .pixels = &mask, .width = 4, .height = 4, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = 1 });
    @memset(&pixels, 0xffff0000);
    const box = try stack.close(surface);
    try std.testing.expectEqual([4]u32{ 0, 0, 4, 4 }, box);
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[2]);
    const half = pixels[1];
    try std.testing.expect((half >> 16) & 0xff > 120 and (half >> 16) & 0xff < 136);
    try std.testing.expect(half & 0xff > 120 and half & 0xff < 136);
    try std.testing.expectEqual(@as(usize, 0), stack.pixels.items.len);
}

test "a mask lies where its origin and the plane's origin place it" {
    var pixels: [8 * 2]u32 = @splat(0);
    const surface: cpu_gradient.Surface = .{ .pixels = &pixels, .width = 8, .height = 2, .stride = 8, .scale = 2, .clip = .{ 0, 0, 8, 2 }, .origin = .{ 2, 0 } };
    var stack: Stack = .{};
    defer stack.deinit(std.testing.allocator);
    // One solid pixel at the mask's device pixel 1, the plane's 1 + 2.
    const mask = [_]u8{ 0, 255 };
    try stack.open(std.testing.allocator, surface, .{ .x = 0, .y = 0, .width = 3, .height = 1 }, .{}, .{ .pixels = &mask, .width = 2, .height = 1, .stride = 2, .origin_x = 0, .origin_y = 0, .scale = 2 });
    @memset(&pixels, 0xffffffff);
    _ = try stack.close(surface);
    try std.testing.expectEqual(@as(u32, 0), pixels[2]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[3]);
    try std.testing.expectEqual(@as(u32, 0), pixels[4]);
    // Outside the clip's box the drawn pixels stay.
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[0]);
}
