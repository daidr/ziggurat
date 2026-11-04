//! How the software planes draw a masked clip (`Command.push_mask_clip`):
//! each drawing inside shows as much as the mask, one by one, as if its own
//! coverage were multiplied by the mask, so two overlapping children inside
//! a half-transparent part of the mask both show through each other as they
//! would with their own opacity, not as one layer would. The pixels a
//! drawing may change are kept before it draws; after, each becomes the kept
//! one mixed toward the drawn one by the masks there. Drawings that do not
//! overlap gather into one run and are mixed together, which is the same.
//! A group, transform or effect inside is one drawing: what it draws on its
//! own layer is masked as it composites onto the plane the clip opened on,
//! and masked clips opened inside it mask what is drawn on that layer.
//! An opacity (`Command.push_opacity`) is a mask of one value everywhere,
//! cutting nothing: each drawing fades by itself, as if its colors were
//! multiplied by the opacity.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
const cpu_gradient = @import("cpu_gradient.zig");
const damage = @import("damage.zig");
const layout = @import("layout.zig");

pub const max_depth = 32;
/// Drawings one run may gather before it is mixed.
pub const max_pieces = 32;

/// Where a mask lies on a plane: its pixel (0, 0) is at device pixel
/// `x`, `y` of the plane, which may fall between pixels.
pub const Placement = struct { x: f64, y: f64 };

pub const Scope = struct {
    /// Device pixels of the plane the clip covers: left, top, right, bottom.
    box: [4]u32,
    /// Null for an opacity: `value` everywhere.
    coverage: ?drawing.Coverage,
    /// An opacity's value, 0 to 256.
    value: u32 = 256,
    place: Placement,
    /// The layer the clip opened on: drawings on it are masked by it.
    level: u32,
};

/// Pixels kept before a drawing, to mix it by the masks after.
pub const Piece = struct { box: [4]u32, offset: usize, level: u32 };

/// The masked clips open, innermost last, and the pixels kept beneath the
/// drawings they mask now.
pub const Stack = struct {
    scopes: [max_depth]Scope = undefined,
    len: usize = 0,
    pixels: std.ArrayListUnmanaged(u32) = .empty,
    /// The run on the current layer: drawings that do not overlap.
    pieces: [max_pieces]Piece = undefined,
    piece_len: usize = 0,
    /// Groups, transforms and effects open on a masked layer, innermost
    /// last: what each covered before it began.
    spans: [max_depth]Piece = undefined,
    span_len: usize = 0,

    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        self.pixels.deinit(allocator);
        self.* = .{};
    }
    pub fn reset(self: *Stack) void {
        self.len = 0;
        self.piece_len = 0;
        self.span_len = 0;
        self.pixels.clearRetainingCapacity();
    }
    /// Open a clip on `surface`, layer `level`, over `rect` (DIP, within its
    /// clip), masked by `coverage` placed from `origin`. Mix the run first.
    pub fn open(self: *Stack, surface: cpu_gradient.Surface, rect: layout.Rect, origin: drawing.Point, coverage: drawing.Coverage, level: u32) !void {
        if (self.len == max_depth) return error.ClipStackFull;
        if (self.piece_len != 0) return error.MaskRunOpen;
        const scale: f64 = surface.scale;
        self.scopes[self.len] = .{
            .box = deviceBox(surface, rect),
            .coverage = coverage,
            .place = .{ .x = @as(f64, origin.x) * scale + @as(f64, @floatFromInt(coverage.origin_x)) + surface.origin[0], .y = @as(f64, origin.y) * scale + @as(f64, @floatFromInt(coverage.origin_y)) + surface.origin[1] },
            .level = level,
        };
        self.len += 1;
    }
    /// Open an opacity of `alpha` (of 255) on `surface`, layer `level`:
    /// a mask of that value over the whole plane. Mix the run first.
    pub fn openOpacity(self: *Stack, surface: cpu_gradient.Surface, alpha: u8, level: u32) !void {
        if (self.len == max_depth) return error.ClipStackFull;
        if (self.piece_len != 0) return error.MaskRunOpen;
        self.scopes[self.len] = .{
            .box = .{ 0, 0, surface.width, surface.height },
            .coverage = null,
            .value = (@as(u32, alpha) * 256 + 127) / 255,
            .place = .{ .x = 0, .y = 0 },
            .level = level,
        };
        self.len += 1;
    }
    /// Close the innermost clip. Mix the run first.
    pub fn close(self: *Stack) !void {
        if (self.len == 0) return error.ClipStackEmpty;
        if (self.piece_len != 0) return error.MaskRunOpen;
        self.len -= 1;
    }
    /// Whether drawings on layer `level` are masked now.
    pub fn masks(self: *const Stack, level: u32) bool {
        return self.innermost(level) != null;
    }
    fn innermost(self: *const Stack, level: u32) ?*const Scope {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes[i].level == level) return &self.scopes[i];
        }
        return null;
    }
    /// Before a drawing on layer `level` that changes at most `box` (device
    /// pixels before the plane's origin, from `damage.commandBox`; null for
    /// any): keep what it may change. When it overlaps the run, the run is
    /// mixed first; returns the pixels that changed then, if any.
    pub fn draw(self: *Stack, allocator: std.mem.Allocator, surface: cpu_gradient.Surface, level: u32, box: ?damage.Box) !?[4]u32 {
        const scope = self.innermost(level) orelse return null;
        var piece = scope.box;
        if (box) |b| piece = intersect(piece, .{
            clampPixel(@as(f64, @floatFromInt(b.x0)) + @floor(surface.origin[0])),
            clampPixel(@as(f64, @floatFromInt(b.y0)) + @floor(surface.origin[1])),
            clampPixel(@as(f64, @floatFromInt(b.x1)) + @ceil(surface.origin[0])),
            clampPixel(@as(f64, @floatFromInt(b.y1)) + @ceil(surface.origin[1])),
        });
        var changed: ?[4]u32 = null;
        if (self.piece_len == max_pieces or (self.piece_len != 0 and self.pieces[0].level != level)) {
            changed = try self.flush(surface);
        } else for (self.pieces[0..self.piece_len]) |kept| if (overlaps(kept.box, piece)) {
            changed = try self.flush(surface);
            break;
        };
        if (piece[2] <= piece[0] or piece[3] <= piece[1]) return changed;
        self.pieces[self.piece_len] = try self.keep(allocator, surface, piece, level);
        self.piece_len += 1;
        return changed;
    }
    /// Mix the run by the masks of its layer; returns the pixels changed.
    pub fn flush(self: *Stack, surface: cpu_gradient.Surface) !?[4]u32 {
        if (self.piece_len == 0) return null;
        var changed: [4]u32 = self.pieces[0].box;
        for (self.pieces[0..self.piece_len]) |piece| {
            self.mixPiece(surface, piece);
            changed = unite(changed, piece.box);
        }
        self.pixels.shrinkRetainingCapacity(self.pieces[0].offset);
        self.piece_len = 0;
        return changed;
    }
    /// Before a group, transform or effect begins on layer `level`: mix the
    /// run, then keep what it may cover when the layer is masked. Returns
    /// whether it was, and the pixels the run changed.
    pub fn beginSpan(self: *Stack, allocator: std.mem.Allocator, surface: cpu_gradient.Surface, level: u32) !struct { masked: bool, changed: ?[4]u32 } {
        const changed = try self.flush(surface);
        const scope = self.innermost(level) orelse return .{ .masked = false, .changed = changed };
        if (self.span_len == max_depth) return error.ClipStackFull;
        self.spans[self.span_len] = try self.keep(allocator, surface, scope.box, level);
        self.span_len += 1;
        return .{ .masked = true, .changed = changed };
    }
    /// After the innermost masked span composited: mix what it drew by the
    /// masks of its layer. Returns the pixels changed.
    pub fn endSpan(self: *Stack, surface: cpu_gradient.Surface) ![4]u32 {
        if (self.span_len == 0) return error.UnbalancedGroups;
        if (self.piece_len != 0) return error.MaskRunOpen;
        self.span_len -= 1;
        const span = self.spans[self.span_len];
        self.mixPiece(surface, span);
        self.pixels.shrinkRetainingCapacity(span.offset);
        return span.box;
    }
    fn keep(self: *Stack, allocator: std.mem.Allocator, surface: cpu_gradient.Surface, box: [4]u32, level: u32) !Piece {
        const offset = self.pixels.items.len;
        const width = box[2] - box[0];
        try self.pixels.ensureUnusedCapacity(allocator, @as(usize, width) * (box[3] - box[1]));
        for (box[1]..box[3]) |y| self.pixels.appendSliceAssumeCapacity(surface.pixels[y * surface.stride + box[0] ..][0..width]);
        return .{ .box = box, .offset = offset, .level = level };
    }
    fn mixPiece(self: *Stack, surface: cpu_gradient.Surface, piece: Piece) void {
        var at = piece.offset;
        for (piece.box[1]..piece.box[3]) |y| {
            const row = surface.pixels[y * surface.stride ..];
            for (piece.box[0]..piece.box[2]) |x| {
                const kept = self.pixels.items[at];
                at += 1;
                // The masks of the layer multiply.
                var m: u32 = 256;
                for (self.scopes[0..self.len]) |scope| {
                    if (scope.level != piece.level) continue;
                    if (m == 0) break;
                    const value = if (x < scope.box[0] or x >= scope.box[2] or y < scope.box[1] or y >= scope.box[3]) 0 else if (scope.coverage) |coverage| sample(coverage, @as(f64, @floatFromInt(x)) - scope.place.x, @as(f64, @floatFromInt(y)) - scope.place.y) else scope.value;
                    m = (m * value + 128) >> 8;
                }
                row[x] = mix(kept, row[x], m);
            }
        }
    }
};

fn clampPixel(value: f64) u32 {
    return @intFromFloat(std.math.clamp(value, 0, std.math.maxInt(u31)));
}
fn intersect(a: [4]u32, b: [4]u32) [4]u32 {
    const out = [4]u32{ @max(a[0], b[0]), @max(a[1], b[1]), @min(a[2], b[2]), @min(a[3], b[3]) };
    return .{ out[0], out[1], @max(out[0], out[2]), @max(out[1], out[3]) };
}
fn unite(a: [4]u32, b: [4]u32) [4]u32 {
    return .{ @min(a[0], b[0]), @min(a[1], b[1]), @max(a[2], b[2]), @max(a[3], b[3]) };
}
fn overlaps(a: [4]u32, b: [4]u32) bool {
    return @max(a[0], b[0]) < @min(a[2], b[2]) and @max(a[1], b[1]) < @min(a[3], b[3]);
}

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
    try stack.open(surface, .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{}, .{ .pixels = &mask, .width = 4, .height = 4, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = 1 }, 0);
    _ = try stack.draw(std.testing.allocator, surface, 0, null);
    @memset(&pixels, 0xffff0000);
    try std.testing.expectEqual([4]u32{ 0, 0, 4, 4 }, (try stack.flush(surface)).?);
    try stack.close();
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
    try stack.open(surface, .{ .x = 0, .y = 0, .width = 3, .height = 1 }, .{}, .{ .pixels = &mask, .width = 2, .height = 1, .stride = 2, .origin_x = 0, .origin_y = 0, .scale = 2 }, 0);
    _ = try stack.draw(std.testing.allocator, surface, 0, null);
    @memset(&pixels, 0xffffffff);
    _ = try stack.flush(surface);
    try stack.close();
    try std.testing.expectEqual(@as(u32, 0), pixels[2]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[3]);
    try std.testing.expectEqual(@as(u32, 0), pixels[4]);
    // Outside the clip's box the drawn pixels stay.
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[0]);
}

test "overlapping drawings are masked one by one, as their own opacity would" {
    // One pixel, mask half; red then blue drawn opaque over it.
    var pixels = [_]u32{0};
    const surface: cpu_gradient.Surface = .{ .pixels = &pixels, .width = 1, .height = 1, .stride = 1, .scale = 1, .clip = .{ 0, 0, 1, 1 }, .origin = .{ 0, 0 } };
    var stack: Stack = .{};
    defer stack.deinit(std.testing.allocator);
    const mask = [_]u8{128};
    try stack.open(surface, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{}, .{ .pixels = &mask, .width = 1, .height = 1, .stride = 1, .origin_x = 0, .origin_y = 0, .scale = 1 }, 0);
    const box: damage.Box = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
    _ = try stack.draw(std.testing.allocator, surface, 0, box);
    pixels[0] = 0xffff0000;
    // The second overlaps the first: the first is mixed before it draws.
    try std.testing.expect(try stack.draw(std.testing.allocator, surface, 0, box) != null);
    pixels[0] = 0xff0000ff;
    _ = try stack.flush(surface);
    try stack.close();
    // Blue at half over red at half over nothing: red shows a quarter,
    // where one layer masked as one would show no red at all.
    const red = (pixels[0] >> 16) & 0xff;
    const blue = pixels[0] & 0xff;
    const alpha = pixels[0] >> 24;
    try std.testing.expect(red > 56 and red < 72);
    try std.testing.expect(blue > 120 and blue < 136);
    try std.testing.expect(alpha > 184 and alpha < 200);
}

test "drawings that do not overlap gather into one run; a span on a masked layer is one drawing" {
    var pixels: [4]u32 = @splat(0);
    const surface: cpu_gradient.Surface = .{ .pixels = &pixels, .width = 4, .height = 1, .stride = 4, .scale = 1, .clip = .{ 0, 0, 4, 1 }, .origin = .{ 0, 0 } };
    var stack: Stack = .{};
    defer stack.deinit(std.testing.allocator);
    const mask = [_]u8{ 255, 255, 255, 255 };
    try stack.open(surface, .{ .x = 0, .y = 0, .width = 4, .height = 1 }, .{}, .{ .pixels = &mask, .width = 4, .height = 1, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = 1 }, 0);
    try std.testing.expectEqual(@as(?[4]u32, null), try stack.draw(std.testing.allocator, surface, 0, .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }));
    try std.testing.expectEqual(@as(?[4]u32, null), try stack.draw(std.testing.allocator, surface, 0, .{ .x0 = 2, .y0 = 0, .x1 = 3, .y1 = 1 }));
    try std.testing.expectEqual(@as(usize, 2), stack.pixels.items.len);
    // Drawings on another layer are not masked by this clip.
    const span = try stack.beginSpan(std.testing.allocator, surface, 0);
    try std.testing.expect(span.masked and span.changed != null);
    try std.testing.expect(!stack.masks(1));
    try std.testing.expectEqual(@as(?[4]u32, null), try stack.draw(std.testing.allocator, surface, 1, null));
    try std.testing.expectEqual([4]u32{ 0, 0, 4, 1 }, try stack.endSpan(surface));
    try stack.close();
    try std.testing.expectEqual(@as(usize, 0), stack.pixels.items.len);
}

test "an opacity fades each drawing by itself and cuts nothing" {
    // Two pixels; red then blue drawn opaque over the first at half.
    var pixels = [_]u32{ 0, 0 };
    const surface: cpu_gradient.Surface = .{ .pixels = &pixels, .width = 2, .height = 1, .stride = 2, .scale = 1, .clip = .{ 0, 0, 2, 1 }, .origin = .{ 0, 0 } };
    var stack: Stack = .{};
    defer stack.deinit(std.testing.allocator);
    try stack.openOpacity(surface, 128, 0);
    const box: damage.Box = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
    _ = try stack.draw(std.testing.allocator, surface, 0, box);
    pixels[0] = 0xffff0000;
    _ = try stack.draw(std.testing.allocator, surface, 0, box);
    pixels[0] = 0xff0000ff;
    // A drawing anywhere on the plane fades, none is cut.
    _ = try stack.draw(std.testing.allocator, surface, 0, .{ .x0 = 1, .y0 = 0, .x1 = 2, .y1 = 1 });
    pixels[1] = 0xff00ff00;
    _ = try stack.flush(surface);
    try stack.close();
    const red = (pixels[0] >> 16) & 0xff;
    const blue = pixels[0] & 0xff;
    try std.testing.expect(red > 56 and red < 72);
    try std.testing.expect(blue > 120 and blue < 136);
    const green = (pixels[1] >> 8) & 0xff;
    try std.testing.expect(green > 120 and green < 136 and pixels[1] >> 24 > 120 and pixels[1] >> 24 < 136);
}
