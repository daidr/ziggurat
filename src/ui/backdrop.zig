//! Backdrop effects read what has already been drawn beneath an element in
//! the current target plane, filter it and write the result back inside the
//! element's rounded rectangle. They run on the software planes; a frame that
//! holds one is replayed in software.
const std = @import("std");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const cpu = @import("cpu_gradient.zig");
pub const Rect = layout.Rect;
pub const Color = geometry.Color;
pub const Dirty = cpu.Dirty;

/// Backdrop commands one Buffer can hold.
pub const max_entries = 16;
/// Largest Gaussian reach in physical pixels; stronger blurs are clamped.
pub const max_radius_pixels = 128;
pub const max_bytes = 256 * 1024 * 1024;

pub const Style = enum(u8) {
    /// Frosted, lightened in light mode and darkened in dark mode, so text
    /// on it stays legible.
    regular,
    /// Barely blurred or toned, for glass over photos and video.
    clear,
};
pub const Glass = struct {
    style: Style = .regular,
    /// Straight-alpha color the pane leans toward, weighted by its alpha.
    tint: ?Color = null,
    /// Grain amplitude from 0 to 1, fixed per physical pixel; zero has none.
    noise: f32 = 0,
};
/// Varies a blur along a line by alpha: 255 applies the full radius, 0 none.
pub const Mask = struct {
    from: u8 = 255,
    to: u8 = 0,
    /// Gradient angle in degrees: 180 runs from the top edge to the bottom,
    /// 0 from the bottom to the top and 90 from left to right.
    angle: f32 = 180,
    /// Positions of `from` and `to` along the line, as fractions of it.
    start: f32 = 0,
    end: f32 = 1,
};
pub const Blur = struct {
    /// Gaussian standard deviation in DIP.
    radius: f32,
    /// Null blurs uniformly; a mask makes the blur progressive.
    mask: ?Mask = null,
};
/// Where scrolling content meets a bar of controls. Size it to the bar's
/// height, plus 10 DIP for the soft style.
pub const ScrollEdge = struct {
    /// Soft fades the content out; hard frosts it under a hairline.
    hard: bool = false,
    /// The bar sits at the bottom edge instead of the top.
    bottom: bool = false,
    /// Opaque RGB the content fades or tones toward; null is the theme background.
    background: ?u32 = null,
};
pub const Effect = union(enum) { blur: Blur, glass: Glass, scroll_edge: ScrollEdge };
/// The system's accessibility appearance, chosen by the host. Either flag
/// replaces every backdrop effect with an opaque fill.
pub const Preferences = struct {
    reduce_transparency: bool = false,
    high_contrast: bool = false,
    pub fn opaqueFill(self: Preferences) bool {
        return self.reduce_transparency or self.high_contrast;
    }
};

pub const Kind = enum(u8) { blur, glass, edge };
/// One recorded effect in absolute DIP; everything that depends on the
/// target's scale is derived during replay.
pub const Entry = struct {
    bounds: Rect,
    radius: f32 = 0,
    kind: Kind,
    style: Style = .regular,
    dark: bool = false,
    /// Blur standard deviation in DIP; used by `blur` only.
    sigma: f32 = 0,
    mask: ?Mask = null,
    tint: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    noise: f32 = 0,
    /// Opaque RGB for the hard scroll edge's tone.
    background: u32 = 0,
    /// Straight-alpha fill drawn when the region exceeds the workspace.
    fallback: Color,
};

pub const Options = struct {
    /// Largest sampled region in physical pixels, including the blur's and
    /// refraction's reach around the element.
    max_pixels: u32 = 1024 * 1024,
};
pub const Stats = struct {
    /// Effects filtered from the backdrop.
    applied: u64 = 0,
    /// Effects drawn as their opaque fallback because the region was larger
    /// than the workspace.
    fallbacks: u64 = 0,
    /// Pixels sampled by filtered effects.
    pixels: u64 = 0,
    capacity_pixels: u32 = 0,
    bytes: usize = 0,
};

/// Scratch planes, allocated once by `create`. Replay never allocates.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    planes: []u32,
    capacity: u32,
    stats: Stats = .{},

    pub fn bytesFor(options: Options) !usize {
        if (options.max_pixels == 0) return error.InvalidBackdropOptions;
        const bytes = std.math.mul(usize, @as(usize, options.max_pixels) * 3, 4) catch return error.BackdropBudgetExceeded;
        if (bytes > max_bytes) return error.BackdropBudgetExceeded;
        return bytes;
    }
    pub fn create(allocator: std.mem.Allocator, options: Options) !*Workspace {
        const bytes = try bytesFor(options);
        const self = try allocator.create(Workspace);
        errdefer allocator.destroy(self);
        const planes = try allocator.alloc(u32, bytes / 4);
        self.* = .{ .allocator = allocator, .planes = planes, .capacity = options.max_pixels, .stats = .{ .capacity_pixels = options.max_pixels, .bytes = bytes + @sizeOf(Workspace) } };
        return self;
    }
    pub fn destroy(self: *Workspace) void {
        const allocator = self.allocator;
        allocator.free(self.planes);
        allocator.destroy(self);
    }
    fn plane(self: *Workspace, index: usize, len: usize) []u32 {
        return self.planes[index * self.capacity ..][0..len];
    }
};

/// A Buffer's effect table and the workspace bound for one replay.
pub const Storage = struct {
    entries: [max_entries]Entry = undefined,
    len: usize = 0,
    workspace: ?*Workspace = null,
};

/// The opaque fill that stands in for an effect under reduced transparency
/// or high contrast, and when a region does not fit the workspace.
pub fn fallbackColor(effect: Effect, background: u32, control: u32) Color {
    const dark = luma(background) < 0.5;
    return switch (effect) {
        .glass => |glass| blk: {
            var base = mix(background, if (dark) control else 0xffffff, if (dark) 0.5 else 0.6);
            if (glass.tint) |tint| base = mix(base, (@as(u32, tint.r) << 16) | (@as(u32, tint.g) << 8) | tint.b, @as(f64, @floatFromInt(tint.a)) / 255 * 0.88);
            break :blk .rgb(base);
        },
        .blur => .rgb(background),
        .scroll_edge => |edge| .rgb(edge.background orelse background),
    };
}
pub fn isDark(background: u32) bool {
    return luma(background) < 0.5;
}

/// Ends of a mask's line across `bounds`, in the same coordinates.
pub fn maskPoints(mask: Mask, bounds: Rect) [2]layout.Point {
    const angle = @as(f32, mask.angle) * std.math.pi / 180;
    const dx = @sin(angle);
    const dy = -@cos(angle);
    const cx = bounds.x + bounds.width / 2;
    const cy = bounds.y + bounds.height / 2;
    const half = (@abs(bounds.width * dx) + @abs(bounds.height * dy)) / 2;
    const end: f32 = if (mask.start == 0 and mask.end == 0) 1 else mask.end;
    return .{
        .{ .x = cx - dx * half + dx * 2 * half * mask.start, .y = cy - dy * half + dy * 2 * half * mask.start },
        .{ .x = cx - dx * half + dx * 2 * half * end, .y = cy - dy * half + dy * 2 * half * end },
    };
}

/// GPU renderers have no backdrop sampler; such a frame replays in software.
pub fn requiresSoftware(list: anytype) bool {
    for (list) |command| if (command == .backdrop) return true;
    return false;
}

const Box = struct { x0: f64, y0: f64, x1: f64, y1: f64, radius: f64 };
const Region = struct { x0: usize, y0: usize, x1: usize, y1: usize };

/// Filter the target beneath `entry` and write the result inside it. The
/// surface's clip bounds the written pixels; samples may come from anywhere
/// on the plane, and beyond its edges repeat the nearest pixel.
pub fn apply(surface: cpu.Surface, transparent: bool, entry: Entry, workspace: ?*Workspace) Dirty {
    const empty: Dirty = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const s: f64 = surface.scale;
    const b = entry.bounds;
    const box: Box = blk: {
        const x0 = @round(@as(f64, b.x) * s + surface.origin[0]);
        const y0 = @round(@as(f64, b.y) * s + surface.origin[1]);
        const x1 = @round((@as(f64, b.x) + b.width) * s + surface.origin[0]);
        const y1 = @round((@as(f64, b.y) + b.height) * s + surface.origin[1]);
        break :blk .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .radius = @min(@as(f64, entry.radius) * s, @min(x1 - x0, y1 - y0) / 2) };
    };
    if (!(box.x1 > box.x0 and box.y1 > box.y0)) return empty;
    const width: f64 = @floatFromInt(surface.width);
    const height: f64 = @floatFromInt(surface.height);
    const clip = surface.clip;
    const fx0 = @max(@max(box.x0, @floor(clip[0])), 0);
    const fy0 = @max(@max(box.y0, @floor(clip[1])), 0);
    const fx1 = @min(@min(box.x1, @ceil(clip[2])), width);
    const fy1 = @min(@min(box.y1, @ceil(clip[3])), height);
    if (!(fx1 > fx0 and fy1 > fy0)) return empty;
    const out: Region = .{ .x0 = @intFromFloat(fx0), .y0 = @intFromFloat(fy0), .x1 = @intFromFloat(fx1), .y1 = @intFromFloat(fy1) };
    const dirty: Dirty = .{ .left = @intCast(out.x0), .top = @intCast(out.y0), .right = @intCast(out.x1), .bottom = @intCast(out.y1) };

    const shading = Shading.init(entry, box, s);
    const reach: usize = shading.radius + @as(usize, @intFromFloat(@ceil(shading.refraction))) + 1;
    const sample: Region = .{
        .x0 = out.x0 -| reach,
        .y0 = out.y0 -| reach,
        .x1 = @min(out.x1 + reach, surface.width),
        .y1 = @min(out.y1 + reach, surface.height),
    };
    const sw = sample.x1 - sample.x0;
    const sh = sample.y1 - sample.y0;
    const space = workspace orelse {
        fill(surface, transparent, box, out, entry.fallback);
        return dirty;
    };
    if (sw * sh > space.capacity) {
        space.stats.fallbacks += 1;
        fill(surface, transparent, box, out, entry.fallback);
        return dirty;
    }
    space.stats.applied += 1;
    space.stats.pixels += sw * sh;
    const current = space.plane(0, sw * sh);
    const scratch = space.plane(1, sw * sh);
    for (0..sh) |row| @memcpy(current[row * sw ..][0..sw], surface.pixels[(sample.y0 + row) * surface.stride + sample.x0 ..][0..sw]);
    const plane: Plane = .{ .pixels = current, .width = sw, .height = sh, .x0 = sample.x0, .y0 = sample.y0 };

    // A progressive blur blends successive blur levels into a third plane.
    var result = plane;
    if (shading.progressive) |line| {
        result.pixels = space.plane(2, sw * sh);
        @memcpy(result.pixels, current);
        var levels: [16]Level = undefined;
        const count = blurLevels(&levels, line.least, line.most);
        for (levels[0..count]) |level| {
            gaussian(plane, scratch, level.blur);
            for (out.y0..out.y1) |y| for (out.x0..out.x1) |x| {
                const blur = line.blurAt(@as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5);
                const weight = std.math.clamp((blur - level.lo) / (level.hi - level.lo), 0, 1);
                if (weight == 0) continue;
                const at = (y - sample.y0) * sw + x - sample.x0;
                result.pixels[at] = lerp(result.pixels[at], current[at], weight);
            };
        }
    } else gaussian(plane, scratch, shading.sigma);

    for (out.y0..out.y1) |y| for (out.x0..out.x1) |x| {
        const px = @as(f64, @floatFromInt(x)) + 0.5;
        const py = @as(f64, @floatFromInt(y)) + 0.5;
        const sd = roundedDistance(box, px, py);
        const amount = std.math.clamp(0.5 - sd, 0, 1) * clipCoverage(clip, @floatFromInt(x), @floatFromInt(y));
        if (amount == 0) continue;
        const color = shading.shade(result, x, y, px, py, -sd, box);
        const at = y * surface.stride + x;
        surface.pixels[at] = composite(surface.pixels[at], color, amount, transparent);
    };
    return dirty;
}

const Plane = struct {
    pixels: []u32,
    width: usize,
    height: usize,
    x0: usize,
    y0: usize,
    fn at(self: Plane, x: usize, y: usize) u32 {
        return self.pixels[(y - self.y0) * self.width + x - self.x0];
    }
    /// Bilinear sample at a physical position, clamped to the plane.
    fn sample(self: Plane, x: f64, y: f64) [4]f64 {
        const lx = std.math.clamp(x - 0.5 - @as(f64, @floatFromInt(self.x0)), 0, @as(f64, @floatFromInt(self.width - 1)));
        const ly = std.math.clamp(y - 0.5 - @as(f64, @floatFromInt(self.y0)), 0, @as(f64, @floatFromInt(self.height - 1)));
        const ix: usize = @intFromFloat(@floor(lx));
        const iy: usize = @intFromFloat(@floor(ly));
        const jx = @min(ix + 1, self.width - 1);
        const jy = @min(iy + 1, self.height - 1);
        const tx = lx - @floor(lx);
        const ty = ly - @floor(ly);
        const a = channels(self.pixels[iy * self.width + ix]);
        const b = channels(self.pixels[iy * self.width + jx]);
        const c = channels(self.pixels[jy * self.width + ix]);
        const d = channels(self.pixels[jy * self.width + jx]);
        var result: [4]f64 = undefined;
        for (0..4) |i| result[i] = (a[i] * (1 - tx) + b[i] * tx) * (1 - ty) + (c[i] * (1 - tx) + d[i] * tx) * ty;
        return result;
    }
};

/// Lightness mapping of a glass style: luma maps from [0,1] to [low,high]
/// along `1 - (1 - l)^curve`, and chroma scales by `(high - low) * saturation`.
pub const Tone = struct { low: f64, high: f64, curve: f64, saturation: f64 };
pub fn glassTone(style: Style, dark: bool) Tone {
    return switch (style) {
        .clear => .{ .low = 0.125, .high = 1.082, .curve = 1, .saturation = 1 },
        .regular => if (dark) .{ .low = 0.15, .high = 0.51, .curve = 2, .saturation = 2.2 } else .{ .low = 0.541, .high = 1, .curve = 1.2, .saturation = 1 },
    };
}
pub const rim_opacity = 0.35;
pub const hard_edge_blur = 6.4;
pub const soft_edge_alpha = 0.85;

const Line = struct {
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
    length: f64,
    from: f64,
    to: f64,
    least: f64,
    most: f64,
    fn blurAt(self: Line, px: f64, py: f64) f64 {
        const t = if (self.length > 0) std.math.clamp(((px - self.x) * self.dx + (py - self.y) * self.dy) / self.length, 0, 1) else @as(f64, if ((px - self.x) * self.dx + (py - self.y) * self.dy >= 0) 1 else 0);
        return self.from + (self.to - self.from) * t;
    }
};
fn maskLine(mask: Mask, box: Box, sigma: f64) Line {
    const angle = @as(f64, mask.angle) * std.math.pi / 180;
    const dx = @sin(angle);
    const dy = -@cos(angle);
    const cx = (box.x0 + box.x1) / 2;
    const cy = (box.y0 + box.y1) / 2;
    const half = (@abs((box.x1 - box.x0) * dx) + @abs((box.y1 - box.y0) * dy)) / 2;
    const start: f64 = mask.start;
    const end: f64 = if (mask.start == 0 and mask.end == 0) 1 else mask.end;
    const from = @as(f64, @floatFromInt(mask.from)) / 255 * sigma;
    const to = @as(f64, @floatFromInt(mask.to)) / 255 * sigma;
    return .{
        .x = cx - dx * half + dx * 2 * half * start,
        .y = cy - dy * half + dy * 2 * half * start,
        .dx = dx,
        .dy = dy,
        .length = 2 * half * (end - start),
        .from = from,
        .to = to,
        .least = @min(from, to),
        .most = @max(from, to),
    };
}

pub const Level = struct { blur: f64, lo: f64, hi: f64 };
/// Blur levels from `least` to `most` pixels: each level adds the variance
/// that takes the previous level's blur to its own, halving from `most`
/// down to 2 pixels.
pub fn blurLevels(out: *[16]Level, least_value: f64, most: f64) usize {
    const least = @max(least_value, 0);
    if (most <= least) {
        if (least <= 0) return 0;
        out[0] = .{ .blur = least, .lo = -1, .hi = 0 };
        return 1;
    }
    var his: [15]f64 = undefined;
    var count: usize = 0;
    var h = most;
    while (count < his.len) {
        his[count] = h;
        count += 1;
        if (!(h > 2 and h / 2 > least)) break;
        h /= 2;
    }
    var len: usize = 0;
    if (least > 0) {
        out[0] = .{ .blur = least, .lo = -1, .hi = 0 };
        len = 1;
    }
    var lo = least;
    var index = count;
    while (index > 0) {
        index -= 1;
        const hi = his[index];
        out[len] = .{ .blur = @sqrt(hi * hi - lo * lo), .lo = lo, .hi = hi };
        len += 1;
        lo = hi;
    }
    return len;
}

const Shading = struct {
    kind: Kind,
    sigma: f64,
    radius: usize,
    refraction: f64 = 0,
    bezel: f64 = 0,
    tone: Tone = .{ .low = 0, .high = 1, .curve = 1, .saturation = 1 },
    tint: [4]f64 = .{ 0, 0, 0, 0 },
    noise: f64 = 0,
    background: [3]f64 = .{ 0, 0, 0 },
    progressive: ?Line = null,

    fn init(entry: Entry, box: Box, s: f64) Shading {
        var result: Shading = .{ .kind = entry.kind, .sigma = 0, .radius = 0 };
        switch (entry.kind) {
            .blur => {
                result.sigma = @as(f64, entry.sigma) * s;
                if (entry.mask) |mask| {
                    const line = maskLine(mask, box, result.sigma);
                    if (line.least != line.most) result.progressive = line else result.sigma = line.most;
                }
            },
            .glass => {
                const m = @min(box.x1 - box.x0, box.y1 - box.y0) / s;
                result.bezel = @min(36, m / 2) * s;
                result.refraction = 1.6 * result.bezel;
                result.sigma = if (entry.style == .clear) s else std.math.clamp(m * 0.035, 1, 10) * s;
                result.tone = glassTone(entry.style, entry.dark);
                if (entry.tint.a != 0) result.tint = .{ @as(f64, @floatFromInt(entry.tint.r)) / 255, @as(f64, @floatFromInt(entry.tint.g)) / 255, @as(f64, @floatFromInt(entry.tint.b)) / 255, @as(f64, @floatFromInt(entry.tint.a)) / 255 * 0.88 };
                result.noise = std.math.clamp(@as(f64, entry.noise), 0, 1);
            },
            .edge => {
                result.sigma = hard_edge_blur * s;
                result.background = toned(rgb(entry.background), 0.947, 0.03);
            },
        }
        const most = if (result.progressive) |line| line.most else result.sigma;
        result.sigma = @min(result.sigma, @as(f64, max_radius_pixels) / 3);
        result.radius = @min(max_radius_pixels, @as(usize, @intFromFloat(@ceil(3 * @min(most, @as(f64, max_radius_pixels) / 3)))));
        return result;
    }

    /// Premultiplied BGRA for one output pixel. `depth` is the distance
    /// inside the pane's edge.
    fn shade(self: Shading, plane: Plane, x: usize, y: usize, px: f64, py: f64, depth_value: f64, box: Box) u32 {
        switch (self.kind) {
            .blur => return plane.at(x, y),
            .edge => {
                const c = toned(straight(channels(plane.at(x, y))), 0.25, 0.03);
                var out: [3]f64 = undefined;
                for (0..3) |i| out[i] = c[i] + (self.background[i] - c[i]) * 0.8245;
                return pack(out);
            },
            .glass => {
                const depth = @max(depth_value, 0);
                const rim_width: f64 = 1;
                var nx: f64 = 0;
                var ny: f64 = 0;
                if (depth < self.bezel or depth < 3 * rim_width) {
                    const n = normal(px, py, box);
                    nx = n[0];
                    ny = n[1];
                }
                var sx = px;
                var sy = py;
                if (depth < self.bezel) {
                    const d = self.refraction * lens(depth, self.bezel);
                    sx -= nx * d;
                    sy -= ny * d;
                }
                var c = applyTone(straight(plane.sample(sx, sy)), self.tone);
                if (self.tint[3] > 0) for (0..3) |i| {
                    c[i] += (self.tint[i] - c[i]) * self.tint[3];
                };
                if (depth < 3 * rim_width) {
                    const q = depth / rim_width;
                    const a = rim_opacity * @exp(-q * q);
                    // Light comes from above and below.
                    const light = @abs(ny);
                    for (0..3) |i| c[i] += (light - c[i]) * a;
                }
                if (self.noise > 0) {
                    const grain = (hash(x, y) - 0.5) * self.noise * 0.08;
                    for (0..3) |i| c[i] += grain;
                }
                return pack(c);
            },
        }
    }
};

/// Fraction of the refraction applied at `t` pixels inside a bezel of
/// width `bezel`: 1 at the edge, 0 at its inner end. The bezel's surface
/// height follows `(1 - u^4)^(1/4)`, refracting with index 1.5.
pub fn lens(t: f64, bezel: f64) f64 {
    if (bezel <= 0 or t >= bezel) return 0;
    const u = 1 - @max(t, 0) / bezel;
    const v = 1 - u * u * u * u;
    const a = @sqrt(v * @sqrt(v));
    const b = u * u * u;
    const n = @sqrt(a * a + b * b);
    const s = b / n;
    const c = a / n;
    const st = s / 1.5;
    const ct = @sqrt(1 - st * st);
    const bend = (s * ct - c * st) / (c * ct + s * st);
    return bend / 1.1180339887498949;
}

/// Outward unit normal of the pane's edge nearest a point.
fn normal(px: f64, py: f64, box: Box) [2]f64 {
    const hx = (box.x1 - box.x0) / 2;
    const hy = (box.y1 - box.y0) / 2;
    const cx = px - box.x0 - hx;
    const cy = py - box.y0 - hy;
    const rad = @min(1.5 * box.radius, @min(hx, hy));
    const qx = @abs(cx) - (hx - rad);
    const qy = @abs(cy) - (hy - rad);
    if (qx > 0 or qy > 0) {
        const mx = @max(qx, 0);
        const my = @max(qy, 0);
        const n = @sqrt(mx * mx + my * my);
        return .{ sign(cx) * mx / n, sign(cy) * my / n };
    }
    return if (qx > qy) .{ sign(cx), 0 } else .{ 0, sign(cy) };
}
fn sign(value: f64) f64 {
    return if (value > 0) 1 else if (value < 0) -1 else 0;
}

fn roundedDistance(box: Box, x: f64, y: f64) f64 {
    const hx = (box.x1 - box.x0) * 0.5;
    const hy = (box.y1 - box.y0) * 0.5;
    const qx = @abs(x - (box.x0 + hx)) - (hx - box.radius);
    const qy = @abs(y - (box.y0 + hy)) - (hy - box.radius);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - box.radius;
}
fn clipCoverage(clip: [4]f64, x: f64, y: f64) f64 {
    return @max(0, @min(x + 1, clip[2]) - @max(x, clip[0])) * @max(0, @min(y + 1, clip[3]) - @max(y, clip[1]));
}

/// Separable Gaussian over premultiplied channels; edges repeat.
fn gaussian(plane: Plane, scratch: []u32, sigma: f64) void {
    if (!(sigma > 0)) return;
    const radius: usize = @min(max_radius_pixels, @as(usize, @intFromFloat(@ceil(3 * sigma))));
    if (radius == 0) return;
    var weights: [2 * max_radius_pixels + 1]f64 = undefined;
    var total: f64 = 0;
    for (0..2 * radius + 1) |i| {
        const d = @as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(radius));
        weights[i] = @exp(-d * d / (2 * sigma * sigma));
        total += weights[i];
    }
    for (weights[0 .. 2 * radius + 1]) |*w| w.* /= total;
    const w = plane.width;
    const h = plane.height;
    for (0..h) |y| {
        const row = plane.pixels[y * w ..][0..w];
        for (0..w) |x| {
            var acc = [4]f64{ 0, 0, 0, 0 };
            for (0..2 * radius + 1) |k| {
                const sx = std.math.clamp(@as(isize, @intCast(x + k)) - @as(isize, @intCast(radius)), 0, @as(isize, @intCast(w - 1)));
                const c = channels(row[@intCast(sx)]);
                for (0..4) |i| acc[i] += c[i] * weights[k];
            }
            scratch[y * w + x] = packChannels(acc);
        }
    }
    for (0..w) |x| for (0..h) |y| {
        var acc = [4]f64{ 0, 0, 0, 0 };
        for (0..2 * radius + 1) |k| {
            const sy = std.math.clamp(@as(isize, @intCast(y + k)) - @as(isize, @intCast(radius)), 0, @as(isize, @intCast(h - 1)));
            const c = channels(scratch[@as(usize, @intCast(sy)) * w + x]);
            for (0..4) |i| acc[i] += c[i] * weights[k];
        }
        plane.pixels[y * w + x] = packChannels(acc);
    };
}

fn fill(surface: cpu.Surface, transparent: bool, box: Box, out: Region, color: Color) void {
    if (color.a == 0) return;
    const alpha = @as(f64, @floatFromInt(color.a)) / 255;
    const source = pack(.{ @as(f64, @floatFromInt(color.r)) / 255, @as(f64, @floatFromInt(color.g)) / 255, @as(f64, @floatFromInt(color.b)) / 255 });
    for (out.y0..out.y1) |y| for (out.x0..out.x1) |x| {
        const sd = roundedDistance(box, @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5);
        const amount = std.math.clamp(0.5 - sd, 0, 1) * clipCoverage(surface.clip, @floatFromInt(x), @floatFromInt(y)) * alpha;
        if (amount == 0) continue;
        const at = y * surface.stride + x;
        surface.pixels[at] = composite(surface.pixels[at], source, amount, transparent);
    };
}

/// Replace `amount` of the destination with a premultiplied source. Opaque
/// targets keep full alpha.
fn composite(destination: u32, source: u32, amount: f64, transparent: bool) u32 {
    const result = lerp(destination, source, amount);
    return if (transparent) result else result | 0xff000000;
}
fn lerp(a: u32, b: u32, t: f64) u32 {
    if (t >= 1) return b;
    var result: u32 = 0;
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const x: f64 = @floatFromInt((a >> shift) & 255);
        const y: f64 = @floatFromInt((b >> shift) & 255);
        result |= @as(u32, @intFromFloat(std.math.clamp(@round(x + (y - x) * t), 0, 255))) << shift;
    }
    return result;
}
/// B, G, R, A of a packed pixel as 0..255.
fn channels(pixel: u32) [4]f64 {
    return .{ @floatFromInt(pixel & 255), @floatFromInt((pixel >> 8) & 255), @floatFromInt((pixel >> 16) & 255), @floatFromInt(pixel >> 24) };
}
fn packChannels(value: [4]f64) u32 {
    var result: u32 = 0;
    inline for (0..4) |i| result |= @as(u32, @intFromFloat(std.math.clamp(@round(value[i]), 0, 255))) << (8 * i);
    return result;
}
/// Straight R, G, B in 0..1 from premultiplied B, G, R, A channels.
fn straight(c: [4]f64) [3]f64 {
    if (c[3] == 0) return .{ 0, 0, 0 };
    const a = c[3];
    return .{ @min(1, c[2] / a), @min(1, c[1] / a), @min(1, c[0] / a) };
}
/// An opaque pixel from straight R, G, B in 0..1.
fn pack(c: [3]f64) u32 {
    var result: u32 = 0xff000000;
    result |= @as(u32, @intFromFloat(@round(std.math.clamp(c[0], 0, 1) * 255))) << 16;
    result |= @as(u32, @intFromFloat(@round(std.math.clamp(c[1], 0, 1) * 255))) << 8;
    result |= @as(u32, @intFromFloat(@round(std.math.clamp(c[2], 0, 1) * 255)));
    return result;
}
fn rgb(value: u32) [3]f64 {
    return .{ @as(f64, @floatFromInt((value >> 16) & 255)) / 255, @as(f64, @floatFromInt((value >> 8) & 255)) / 255, @as(f64, @floatFromInt(value & 255)) / 255 };
}
fn lumaOf(c: [3]f64) f64 {
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
fn luma(value: u32) f64 {
    return lumaOf(rgb(value));
}
fn mix(a: u32, b: u32, t: f64) u32 {
    const x = rgb(a);
    const y = rgb(b);
    var result: u32 = 0;
    for (0..3) |i| result = (result << 8) | @as(u32, @intFromFloat(@round(std.math.clamp(x[i] + (y[i] - x[i]) * t, 0, 1) * 255)));
    return result;
}
pub fn applyTone(c: [3]f64, tone: Tone) [3]f64 {
    const l = lumaOf(c);
    const target = tone.low + (tone.high - tone.low) * (1 - std.math.pow(f64, @max(1 - l, 0), tone.curve));
    const k = (tone.high - tone.low) * tone.saturation;
    var result: [3]f64 = undefined;
    for (0..3) |i| result[i] = std.math.clamp(target + (c[i] - l) * k, 0, 1);
    return result;
}
/// Scale chroma around luma by `saturation`, then lift by `offset`.
pub fn toned(c: [3]f64, saturation: f64, offset: f64) [3]f64 {
    const l = lumaOf(c);
    var result: [3]f64 = undefined;
    for (0..3) |i| result[i] = std.math.clamp(l + (c[i] - l) * saturation + offset, 0, 1);
    return result;
}
fn hash(x: usize, y: usize) f64 {
    var v: u32 = @truncate(x *% 73856093 ^ y *% 19349663);
    v ^= v >> 16;
    v *%= 0x7feb352d;
    v ^= v >> 15;
    v *%= 0x846ca68b;
    v ^= v >> 16;
    return @as(f64, @floatFromInt(v)) / 4294967296.0;
}

fn testSurface(pixels: []u32, width: u32, height: u32, scale: f32) cpu.Surface {
    return .{ .pixels = pixels.ptr, .width = width, .height = height, .stride = width, .scale = scale, .clip = .{ 0, 0, @floatFromInt(width), @floatFromInt(height) } };
}

test "lens bends fully at the edge and not past the bezel" {
    try std.testing.expectApproxEqAbs(@as(f64, 1), lens(0, 36), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), lens(36, 36));
    try std.testing.expectEqual(@as(f64, 0), lens(5, 0));
    try std.testing.expect(lens(10, 36) < lens(2, 36));
}

test "blur levels add variance from the least to the most blur" {
    var levels: [16]Level = undefined;
    const count = blurLevels(&levels, 0, 12);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), levels[0].blur, 1e-9);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f64, 9 - 2.25)), levels[1].blur, 1e-9);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f64, 144 - 36)), levels[3].blur, 1e-9);
    try std.testing.expectEqual(@as(f64, 6), levels[3].lo);
    try std.testing.expectEqual(@as(usize, 1), blurLevels(&levels, 4, 4));
    try std.testing.expectEqual(@as(usize, 0), blurLevels(&levels, 0, 0));
    // A nonzero least blur gets a base level that always applies.
    const based = blurLevels(&levels, 3, 12);
    try std.testing.expectEqual(@as(f64, 3), levels[0].blur);
    try std.testing.expectEqual(@as(f64, -1), levels[0].lo);
    try std.testing.expect(based >= 2);
}

test "glass tone maps black and white to the style's lightness bounds" {
    const light = glassTone(.regular, false);
    try std.testing.expectApproxEqAbs(light.low, applyTone(.{ 0, 0, 0 }, light)[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1), applyTone(.{ 1, 1, 1 }, light)[1], 1e-9);
    const dark = glassTone(.regular, true);
    try std.testing.expectApproxEqAbs(dark.high, applyTone(.{ 1, 1, 1 }, dark)[2], 1e-9);
}

test "uniform blur averages a hard edge only inside the rounded pane" {
    var pixels: [32 * 16]u32 = undefined;
    for (0..16) |y| for (0..32) |x| {
        pixels[y * 32 + x] = if (x < 16) 0xff000000 else 0xffffffff;
    };
    const workspace = try Workspace.create(std.testing.allocator, .{ .max_pixels = 32 * 16 });
    defer workspace.destroy();
    const dirty = apply(testSurface(&pixels, 32, 16, 1), false, .{ .bounds = .{ .x = 8, .y = 0, .width = 16, .height = 16 }, .kind = .blur, .sigma = 2, .fallback = .rgb(0xff0000) }, workspace);
    try std.testing.expectEqual(Dirty{ .left = 8, .top = 0, .right = 24, .bottom = 16 }, dirty);
    // Outside the pane nothing changes; across the edge the values ramp.
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[8 * 32 + 7]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[8 * 32 + 24]);
    const left = pixels[8 * 32 + 15] & 255;
    const right = pixels[8 * 32 + 16] & 255;
    try std.testing.expect(left > 40 and left < 128);
    try std.testing.expect(right > 128 and right < 215);
    try std.testing.expectEqual(@as(u32, 0xff), pixels[8 * 32 + 15] >> 24);
    try std.testing.expectEqual(@as(u64, 1), workspace.stats.applied);
}

test "a region larger than the workspace draws the fallback and counts it" {
    var pixels = [_]u32{0xff000000} ** (16 * 16);
    const workspace = try Workspace.create(std.testing.allocator, .{ .max_pixels = 16 });
    defer workspace.destroy();
    _ = apply(testSurface(&pixels, 16, 16, 1), false, .{ .bounds = .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .kind = .glass, .fallback = .rgb(0x336699) }, workspace);
    try std.testing.expectEqual(@as(u32, 0xff336699), pixels[8 * 16 + 8]);
    try std.testing.expectEqual(@as(u64, 1), workspace.stats.fallbacks);
    try std.testing.expectEqual(@as(u64, 0), workspace.stats.applied);
    try std.testing.expectError(error.InvalidBackdropOptions, Workspace.bytesFor(.{ .max_pixels = 0 }));
    try std.testing.expectError(error.BackdropBudgetExceeded, Workspace.bytesFor(.{ .max_pixels = std.math.maxInt(u32) }));
}

test "workspace allocation failures leave nothing allocated" {
    var index: usize = 0;
    while (true) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        const workspace = Workspace.create(failing.allocator(), .{ .max_pixels = 64 }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        workspace.destroy();
        break;
    }
}

test "regular glass lightens dark content in light mode and rims the edge" {
    var pixels = [_]u32{0xff202020} ** (64 * 40);
    const workspace = try Workspace.create(std.testing.allocator, .{ .max_pixels = 64 * 40 });
    defer workspace.destroy();
    _ = apply(testSurface(&pixels, 64, 40, 1), false, .{ .bounds = .{ .x = 8, .y = 8, .width = 48, .height = 24 }, .radius = 12, .kind = .glass, .fallback = .rgb(0) }, workspace);
    const center = pixels[20 * 64 + 32];
    try std.testing.expect((center & 255) > 0x80);
    try std.testing.expectEqual(@as(u32, 0xff202020), pixels[2 * 64 + 2]);
    // The top rim is lit; the left rim is not.
    const top = pixels[8 * 64 + 32] & 255;
    const side = pixels[20 * 64 + 8] & 255;
    try std.testing.expect(top > side);
    // Dark mode darkens light content.
    var white = [_]u32{0xffffffff} ** (64 * 40);
    _ = apply(testSurface(&white, 64, 40, 1), false, .{ .bounds = .{ .x = 8, .y = 8, .width = 48, .height = 24 }, .radius = 12, .kind = .glass, .dark = true, .fallback = .rgb(0) }, workspace);
    try std.testing.expect((white[20 * 64 + 32] & 255) < 0xa0);
}

test "a progressive blur leaves its unmasked end sharp" {
    var pixels: [32 * 32]u32 = undefined;
    for (0..32) |y| for (0..32) |x| {
        pixels[y * 32 + x] = if ((x / 2) % 2 == 0) 0xff000000 else 0xffffffff;
    };
    const original = pixels;
    const workspace = try Workspace.create(std.testing.allocator, .{ .max_pixels = 32 * 32 });
    defer workspace.destroy();
    _ = apply(testSurface(&pixels, 32, 32, 1), false, .{ .bounds = .{ .x = 0, .y = 0, .width = 32, .height = 32 }, .kind = .blur, .sigma = 4, .mask = .{ .from = 255, .to = 0 }, .fallback = .rgb(0) }, workspace);
    // Top rows are blurred toward gray, bottom rows keep their stripes.
    const top = pixels[1 * 32 + 8] & 255;
    try std.testing.expect(top > 60 and top < 200);
    const sharp = @as(i32, @intCast(pixels[31 * 32 + 8] & 255)) - @as(i32, @intCast(original[31 * 32 + 8] & 255));
    try std.testing.expect(@abs(sharp) <= 8);
}

test "hard scroll edge tones content toward the background" {
    var pixels = [_]u32{0xff000000} ** (32 * 16);
    const workspace = try Workspace.create(std.testing.allocator, .{ .max_pixels = 32 * 16 });
    defer workspace.destroy();
    _ = apply(testSurface(&pixels, 32, 16, 1), false, .{ .bounds = .{ .x = 0, .y = 0, .width = 32, .height = 8 }, .kind = .edge, .background = 0xffffff, .fallback = .rgb(0xffffff) }, workspace);
    try std.testing.expect((pixels[4 * 32 + 16] & 255) > 0xc0);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[12 * 32 + 16]);
}

test "clip bounds the written pixels and a transparent layer keeps its alpha" {
    var pixels = [_]u32{0} ** (16 * 16);
    pixels[0] = 0x80808080;
    const workspace = try Workspace.create(std.testing.allocator, .{ .max_pixels = 16 * 16 });
    defer workspace.destroy();
    var surface = testSurface(&pixels, 16, 16, 1);
    surface.clip = .{ 0, 0, 8, 16 };
    _ = apply(surface, true, .{ .bounds = .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .kind = .blur, .sigma = 1, .fallback = .rgb(0) }, workspace);
    try std.testing.expect(pixels[0] >> 24 < 0x80 and pixels[0] >> 24 > 0);
    try std.testing.expectEqual(@as(u32, 0), pixels[12]);
}

test "fallback colors follow light and dark backgrounds" {
    const light = fallbackColor(.{ .glass = .{} }, 0xffffff, 0xeeeeee);
    const dark = fallbackColor(.{ .glass = .{} }, 0x181c22, 0x2a313a);
    try std.testing.expect(light.r > 0xf0);
    try std.testing.expect(dark.r < 0x40);
    try std.testing.expectEqual(Color.rgb(0x123456), fallbackColor(.{ .scroll_edge = .{ .background = 0x123456 } }, 0xffffff, 0));
}
