//! Coverage masks of the clips a frame cuts drawing to beyond a rectangle:
//! a rounded rectangle, a gradient's alpha over a box, or a path. Each is an
//! A8 raster in the frame's device pixels, made once for each shape and size
//! it is drawn at and kept while paints use it: a mask no paint used since
//! the one before is let go when the next paint starts, so a still clip
//! costs nothing to cut to again and a moving one makes a new mask every
//! frame. The renderers read the mask as a clip's coverage (`Buffer.
//! pushMaskClip`): what is drawn inside shows as much as the mask there.
//!
//! A mask let go keeps its pixels' memory for the paint after, as a spare
//! a mask of another size takes in place of allocating its own: a clip
//! that grows or turns, as a card opening out to fill the window, makes a
//! new mask in every frame, and each takes the memory of the one before.
//! A side that outgrows the spare doubles it, so a growing clip allocates
//! a few times in place of every frame; a mask under a quarter of a spare
//! takes memory of its own size, so a clip that shrank much doesn't keep
//! its largest. Spares count toward `max_bytes` by the memory they keep,
//! and those no paint took go at the paint after.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
const vector = @import("ziggurat_vector");
const brushes = @import("brushes.zig");
const layout = @import("layout.zig");

pub const Rect = layout.Rect;

/// Masks kept at once, and the bytes their pixels take at most. A clip
/// that finds no room left draws cut to its rectangle only.
pub const max_masks = 128;
pub const max_bytes: usize = 64 * 1024 * 1024;
/// The largest width and height of a mask, in device pixels: what a clip
/// larger still is cut to shows only within this much of its corner.
pub const max_side = 8192;

pub const Stats = struct {
    /// Masks made since the cache was created, and those found made.
    made: u64 = 0,
    reused: u64 = 0,
    /// Masks let go because no paint used them since the one before.
    released: u64 = 0,
    /// Clips drawn cut to their rectangle only, for want of room.
    refused: u64 = 0,
    kept: usize = 0,
    bytes: usize = 0,
    /// Masks that took a spare's memory in place of allocating their own,
    /// and the spares kept now.
    recycled: u64 = 0,
    spares: usize = 0,
};

/// Spares of let go masks' memory kept at once.
pub const max_spares = 4;

/// What makes the coverage of a release: a renderer giving back the
/// residency of an identity it holds. Called before a mask's pixels go.
pub const Release = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, u64) void,
};

const Entry = struct {
    key: u64,
    used: u64,
    /// The memory the entry keeps: all of `pixels`, which may be more than
    /// its coverage takes, or a prepared path's coverage.
    bytes: usize,
    /// Owned pixels, or a prepared path's coverage.
    pixels: []u8 = &.{},
    lease: drawing.Lease,
    identity: u64 = 0,
    coverage: drawing.Coverage = undefined,
    prepared: ?*vector.Prepared = null,

    fn view(self: *Entry) !drawing.CoverageView {
        if (self.prepared) |value| return value.view();
        return .{ .lease = &self.lease, .identity = self.identity, .coverage = self.coverage };
    }
};

/// Main-thread only. Created by the Context that paints with it, at a
/// stable address.
pub const Masks = struct {
    allocator: std.mem.Allocator,
    entries: [max_masks]?Entry = @splat(null),
    /// Paints begun so far; an entry remembers the last that used it.
    paints: u64 = 0,
    /// The memory the masks and the spares keep.
    bytes: usize = 0,
    stats: Stats = .{},
    /// Memory of masks let go, each with the paint it was let go in.
    spares: [max_spares]?Spare = @splat(null),

    const Spare = struct { pixels: []u8, since: u64 };

    pub fn create(allocator: std.mem.Allocator) !*Masks {
        const self = try allocator.create(Masks);
        self.* = .{ .allocator = allocator };
        return self;
    }
    /// Let go of every mask; the renderers must hold none any more, or be
    /// given back their residency through `release`.
    pub fn destroy(self: *Masks, release: ?Release) void {
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (release) |r| r.call(r.context, entry.identity);
            self.free(entry);
            slot.* = null;
        };
        for (&self.spares) |*spare| self.dropSpare(spare);
        self.allocator.destroy(self);
    }
    /// Start a paint: let go of the masks no paint used since the one
    /// before, after `release` gave back their residency. No frame may hold
    /// any of them now.
    pub fn beginPaint(self: *Masks, release: ?Release) void {
        self.paints += 1;
        // Spares the paint before took no mask into are let go.
        for (&self.spares) |*spare| if (spare.*) |value| if (value.since + 1 < self.paints) self.dropSpare(spare);
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (entry.used + 1 >= self.paints) continue;
            if (entry.lease.pins > entry.lease.residency_pins) continue;
            if (release) |r| r.call(r.context, entry.identity);
            if (entry.lease.pins != 0) continue;
            self.free(entry);
            slot.* = null;
            self.stats.released += 1;
        };
    }
    /// Let go of a mask, its owned pixels' memory kept as a spare where
    /// there is room for one.
    fn free(self: *Masks, entry: *Entry) void {
        if (entry.prepared) |prepared| {
            prepared.close() catch {};
            self.bytes -= entry.bytes;
            return;
        }
        if (entry.pixels.len == 0) {
            self.bytes -= entry.bytes;
            return;
        }
        // The smallest spare goes for a larger one.
        var open: ?*?Spare = null;
        for (&self.spares) |*spare| {
            if (spare.* == null) {
                open = spare;
                break;
            }
            if (open == null or spare.*.?.pixels.len < open.?.*.?.pixels.len) open = spare;
        }
        if (open.?.*) |value| {
            if (value.pixels.len >= entry.pixels.len) {
                self.allocator.free(entry.pixels);
                self.bytes -= entry.bytes;
                return;
            }
            self.dropSpare(open.?);
        }
        // Its memory stays counted, as the spare's.
        open.?.* = .{ .pixels = entry.pixels, .since = self.paints };
    }
    fn dropSpare(self: *Masks, spare: *?Spare) void {
        const value = spare.* orelse return;
        self.allocator.free(value.pixels);
        self.bytes -= value.pixels.len;
        spare.* = null;
    }
    /// Zeroed memory for a mask of `bytes`: a spare's, the smallest that
    /// holds it, unless it takes less than a quarter of it, or new memory,
    /// twice as much for a mask that outgrew a spare, which goes, so that
    /// the masks of a clip growing take it for a while. The
    /// memory is counted in `bytes`; `room` made room for `bytes` of it.
    fn takePixels(self: *Masks, bytes: usize) ![]u8 {
        var best: ?*?Spare = null;
        var outgrown: ?*?Spare = null;
        for (&self.spares) |*spare| if (spare.*) |value| {
            const n = value.pixels.len;
            if (n >= bytes and bytes >= n / 4) {
                if (best == null or n < best.?.*.?.pixels.len) best = spare;
            } else if (n < bytes and (outgrown == null or n > outgrown.?.*.?.pixels.len)) outgrown = spare;
        };
        if (best) |spare| {
            const pixels = spare.*.?.pixels;
            spare.* = null;
            @memset(pixels, 0);
            self.stats.recycled += 1;
            return pixels;
        }
        var size = bytes;
        if (outgrown) |spare| {
            self.dropSpare(spare);
            if (self.bytes + 2 * bytes <= max_bytes) size = 2 * bytes;
        }
        const pixels = try self.allocator.alloc(u8, size);
        @memset(pixels, 0);
        self.bytes += size;
        return pixels;
    }
    /// Give back memory `takePixels` gave for a mask that is not made.
    fn returnPixels(self: *Masks, pixels: []u8) void {
        self.allocator.free(pixels);
        self.bytes -= pixels.len;
    }
    pub fn statsNow(self: *const Masks) Stats {
        var result = self.stats;
        result.bytes = self.bytes;
        for (self.entries) |slot| result.kept += @intFromBool(slot != null);
        for (self.spares) |spare| result.spares += @intFromBool(spare != null);
        return result;
    }
    fn find(self: *Masks, key: u64) ?*Entry {
        for (&self.entries) |*slot| if (slot.*) |*entry| if (entry.key == key) {
            entry.used = self.paints;
            self.stats.reused += 1;
            return entry;
        };
        return null;
    }
    /// A free slot with room for `bytes` more, letting go of masks this
    /// paint has not used; null when the paint's own masks fill it.
    fn room(self: *Masks, bytes: usize, release: ?Release) ?*?Entry {
        if (bytes > max_bytes) return null;
        while (true) {
            var open: ?*?Entry = null;
            for (&self.entries) |*slot| if (slot.* == null) {
                open = slot;
                break;
            };
            if (open != null and self.bytes + bytes <= max_bytes) return open;
            // A spare that holds the mask takes no more memory; others go
            // before any mask does.
            if (open != null) {
                for (self.spares) |spare| if (spare) |value| if (value.pixels.len >= bytes and bytes >= value.pixels.len / 4) return open;
                var dropped = false;
                for (&self.spares) |*spare| if (spare.* != null) {
                    self.dropSpare(spare);
                    dropped = true;
                    break;
                };
                if (dropped) continue;
            }
            // The mask used longest ago, and not in this paint.
            var oldest: ?*?Entry = null;
            for (&self.entries) |*slot| if (slot.*) |entry| {
                if (entry.used >= self.paints or entry.lease.pins > entry.lease.residency_pins) continue;
                if (oldest == null or entry.used < oldest.?.*.?.used) oldest = slot;
            };
            const victim = oldest orelse return null;
            if (release) |r| r.call(r.context, victim.*.?.identity);
            if (victim.*.?.lease.pins != 0) return null;
            self.free(&victim.*.?);
            victim.* = null;
            self.stats.released += 1;
        }
    }

    /// The mask of the rounded rectangle `rect` (window DIP, corners
    /// rounded by `radius`), times the alpha of `gradient` where it is set,
    /// in device pixels at `scale`, cut to `visible`; null when nothing of
    /// it shows or there is no room for it.
    pub fn shape(self: *Masks, rect: Rect, radius: f32, gradient: ?brushes.Gradient, visible: Rect, scale: f32, release: ?Release) !?drawing.CoverageView {
        const box = pixelBox(layout.intersect(rect, visible), scale) orelse return null;
        var hasher = std.hash.Wyhash.init(0x6d61736b);
        hasher.update(std.mem.asBytes(&[_]f32{ rect.x, rect.y, rect.width, rect.height, radius, scale }));
        hasher.update(std.mem.asBytes(&box));
        if (gradient) |g| hashGradient(&hasher, g);
        const key = hasher.final();
        if (self.find(key)) |entry| return try entry.view();
        const width: u32 = @intCast(box[2] - box[0]);
        const height: u32 = @intCast(box[3] - box[1]);
        const stride = (width + 3) & ~@as(u32, 3);
        const bytes = @as(usize, stride) * height;
        const slot = self.room(bytes, release) orelse {
            self.stats.refused += 1;
            return null;
        };
        const memory = try self.takePixels(bytes);
        errdefer self.returnPixels(memory);
        const pixels = memory[0..bytes];
        const stored: ?brushes.Stored = if (gradient) |g| try brushes.Stored.init(g) else null;
        fillShape(pixels, stride, box, rect, radius, if (stored) |*s| s else null, scale);
        const identity = try drawing.reserveRasterIdentity();
        slot.* = .{ .key = key, .used = self.paints, .bytes = memory.len, .pixels = memory, .lease = drawing.Lease.init(std.Thread.getCurrentId()), .identity = identity, .coverage = .{ .pixels = pixels, .width = width, .height = height, .stride = stride, .origin_x = box[0], .origin_y = box[1], .scale = scale } };
        self.stats.made += 1;
        return try slot.*.?.view();
    }

    /// The mask of the rounded rectangle `rect` times that of `layers`,
    /// composited as CSS's `mask-composite`: the first on top, each going
    /// with those under it as its `composite` says, each showing nothing
    /// outside its own box (window DIP). Kept as `shape` keeps its masks.
    pub fn layered(self: *Masks, rect: Rect, radius: f32, layers: []const Layer, visible: Rect, scale: f32, release: ?Release) !?drawing.CoverageView {
        if (layers.len == 0 or layers.len > max_layers) return error.InvalidMaskLayers;
        const box = pixelBox(layout.intersect(rect, visible), scale) orelse return null;
        var hasher = std.hash.Wyhash.init(0x6c617972);
        hasher.update(std.mem.asBytes(&[_]f32{ rect.x, rect.y, rect.width, rect.height, radius, scale }));
        hasher.update(std.mem.asBytes(&box));
        for (layers) |layer| {
            hashGradient(&hasher, layer.gradient);
            hasher.update(std.mem.asBytes(&[_]f32{ layer.box.x, layer.box.y, layer.box.width, layer.box.height, layer.radius }));
            hasher.update(&.{@backingInt(layer.composite)});
        }
        const key = hasher.final();
        if (self.find(key)) |entry| return try entry.view();
        const width: u32 = @intCast(box[2] - box[0]);
        const height: u32 = @intCast(box[3] - box[1]);
        const stride = (width + 3) & ~@as(u32, 3);
        const bytes = @as(usize, stride) * height;
        const slot = self.room(bytes, release) orelse {
            self.stats.refused += 1;
            return null;
        };
        const memory = try self.takePixels(bytes);
        errdefer self.returnPixels(memory);
        const pixels = memory[0..bytes];
        var stored: [max_layers]brushes.Stored = undefined;
        for (layers, 0..) |layer, i| stored[i] = try brushes.Stored.init(layer.gradient);
        for (0..height) |row| {
            const y = (@as(f32, @floatFromInt(box[1] + @as(i32, @intCast(row)))) + 0.5) / scale;
            for (0..width) |column| {
                const x = (@as(f32, @floatFromInt(box[0] + @as(i32, @intCast(column)))) + 0.5) / scale;
                const cover = roundedCoverage(rect, radius, x, y, scale);
                if (cover <= 0) continue;
                pixels[row * stride + column] = @intFromFloat(@round(std.math.clamp(cover * layeredAlpha(layers, stored[0..layers.len], x, y, scale), 0, 1) * 255));
            }
        }
        const identity = try drawing.reserveRasterIdentity();
        slot.* = .{ .key = key, .used = self.paints, .bytes = memory.len, .pixels = memory, .lease = drawing.Lease.init(std.Thread.getCurrentId()), .identity = identity, .coverage = .{ .pixels = pixels, .width = width, .height = height, .stride = stride, .origin_x = box[0], .origin_y = box[1], .scale = scale } };
        self.stats.made += 1;
        return try slot.*.?.view();
    }

    /// The mask of the inside of `path` (non-zero winding), mapped by
    /// `transform` into window DIP and cut to `visible`, in device pixels at
    /// `scale`; null when nothing of it shows or there is no room.
    pub fn path(self: *Masks, value: *const vector.Path, transform: vector.Transform, visible: Rect, scale: f32, release: ?Release) !?drawing.CoverageView {
        return self.pathWithRule(value, transform, .nonzero, visible, scale, release);
    }
    /// `path` filled by `rule`, as SVG's `clip-rule`.
    pub fn pathWithRule(self: *Masks, value: *const vector.Path, transform: vector.Transform, rule: vector.FillRule, visible: Rect, scale: f32, release: ?Release) !?drawing.CoverageView {
        const bounds = (try value.bounds(transform, null)) orelse return null;
        const extent: Rect = .{ .x = @floatCast(bounds.x), .y = @floatCast(bounds.y), .width = @floatCast(bounds.width), .height = @floatCast(bounds.height) };
        const shown = layout.intersect(.{ .x = extent.x - 1 / scale, .y = extent.y - 1 / scale, .width = extent.width + 2 / scale, .height = extent.height + 2 / scale }, visible);
        const box = pixelBox(shown, scale) orelse return null;
        var hasher = std.hash.Wyhash.init(0x70617468);
        hasher.update(std.mem.sliceAsBytes(value.commands));
        hasher.update(std.mem.asBytes(&transform));
        hasher.update(std.mem.asBytes(&box));
        hasher.update(std.mem.asBytes(&scale));
        hasher.update(&.{@backingInt(rule)});
        const key = hasher.final();
        if (self.find(key)) |entry| return try entry.view();
        const width: u32 = @intCast(box[2] - box[0]);
        const height: u32 = @intCast(box[3] - box[1]);
        const bytes = @as(usize, (width + 3) & ~@as(u32, 3)) * height;
        const slot = self.room(bytes, release) orelse {
            self.stats.refused += 1;
            return null;
        };
        const viewport: drawing.Rect = .{ .x = @as(f32, @floatFromInt(box[0])) / scale, .y = @as(f32, @floatFromInt(box[1])) / scale, .width = @as(f32, @floatFromInt(width)) / scale, .height = @as(f32, @floatFromInt(height)) / scale };
        const prepared = try value.prepare(self.allocator, .{ .main_thread = std.Thread.getCurrentId(), .viewport = viewport, .scale = scale, .transform = transform, .style = .{ .fill = rule } });
        errdefer prepared.close() catch {};
        if (!prepared.adopted) try prepared.adopt();
        const charge = @as(usize, prepared.coverage.stride) * prepared.coverage.height;
        slot.* = .{ .key = key, .used = self.paints, .bytes = charge, .lease = drawing.Lease.init(std.Thread.getCurrentId()), .identity = prepared.identity, .prepared = prepared };
        self.bytes += charge;
        self.stats.made += 1;
        return try slot.*.?.view();
    }
};

/// Layers of masks one clip takes at most.
pub const max_layers = 4;
/// How a layer of masks goes with those under it, as CSS's
/// `mask-composite`.
pub const Composite = enum(u8) {
    /// What either shows.
    add,
    /// The layer where those under it do not show.
    subtract,
    /// Where both show.
    intersect,
    /// Where one shows but not both.
    exclude,
};
/// One layer of a layered mask (`Masks.layered`): the alpha of `gradient`
/// across `box`, rounded by `radius`, outside which it shows nothing.
pub const Layer = struct {
    gradient: brushes.Gradient,
    box: Rect,
    radius: f32 = 0,
    composite: Composite = .add,
};
/// The alpha of `layers` at the DIP point (x, y), from the last, at the
/// bottom, up.
pub fn layeredAlpha(layers: []const Layer, stored: []const brushes.Stored, x: f32, y: f32, scale: f32) f32 {
    var below: f32 = 0;
    var index = layers.len;
    while (index > 0) {
        index -= 1;
        const layer = layers[index];
        const own = roundedCoverage(layer.box, layer.radius, x, y, scale) * gradientAlpha(&stored[index], x, y);
        if (index == layers.len - 1) {
            below = own;
            continue;
        }
        below = switch (layer.composite) {
            .add => own + below * (1 - own),
            .subtract => own * (1 - below),
            .intersect => own * below,
            .exclude => own * (1 - below) + below * (1 - own),
        };
    }
    return below;
}

/// Device pixels `rect` touches at `scale`, as left, top, right and bottom,
/// at most `max_side` each way; null when it is empty.
fn pixelBox(rect: Rect, scale: f32) ?[4]i32 {
    if (!(rect.width > 0 and rect.height > 0) or !std.math.isFinite(rect.x) or !std.math.isFinite(rect.y)) return null;
    const limit: f64 = 1 << 30;
    const x0 = std.math.clamp(@floor(@as(f64, rect.x) * scale), -limit, limit);
    const y0 = std.math.clamp(@floor(@as(f64, rect.y) * scale), -limit, limit);
    const x1 = std.math.clamp(@ceil((@as(f64, rect.x) + rect.width) * scale), -limit, limit);
    const y1 = std.math.clamp(@ceil((@as(f64, rect.y) + rect.height) * scale), -limit, limit);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ @intFromFloat(x0), @intFromFloat(y0), @intFromFloat(@min(x1, x0 + max_side)), @intFromFloat(@min(y1, y0 + max_side)) };
}

fn hashGradient(hasher: *std.hash.Wyhash, gradient: brushes.Gradient) void {
    hasher.update(std.mem.asBytes(&@backingInt(gradient)));
    switch (gradient) {
        .linear => |g| {
            hasher.update(std.mem.asBytes(&[_]f32{ g.start.x, g.start.y, g.end.x, g.end.y }));
            hasher.update(std.mem.asBytes(&g.spread));
        },
        .radial => |g| {
            hasher.update(std.mem.asBytes(&[_]f32{ g.center.x, g.center.y, g.radius.x, g.radius.y }));
            hasher.update(std.mem.asBytes(&g.spread));
        },
        .conic => |g| {
            hasher.update(std.mem.asBytes(&[_]f32{ g.center.x, g.center.y }));
            hasher.update(std.mem.asBytes(&g.start_angle_radians));
            hasher.update(std.mem.asBytes(&g.direction));
        },
    }
    for (switch (gradient) {
        inline else => |g| g.stops,
    }) |stop| hasher.update(std.mem.asBytes(&[_]f32{ stop.offset, @floatFromInt(stop.color.a) }));
}

/// How much of the pixel centered at (x, y), in DIP, the rounded rectangle
/// covers: its signed distance to the edge, smoothed across a pixel.
pub fn roundedCoverage(rect: Rect, radius: f32, x: f32, y: f32, scale: f32) f32 {
    const hw = rect.width / 2;
    const hh = rect.height / 2;
    const r = std.math.clamp(radius, 0, @min(hw, hh));
    const px = @abs(x - (rect.x + hw)) - (hw - r);
    const py = @abs(y - (rect.y + hh)) - (hh - r);
    const outside = @sqrt(@max(px, 0) * @max(px, 0) + @max(py, 0) * @max(py, 0));
    const distance = outside + @min(@max(px, py), 0) - r;
    return std.math.clamp(0.5 - distance * scale, 0, 1);
}

/// The alpha of `stored` at the DIP point (x, y), from 0 to 1, its stops'
/// alphas interpolated as the gradient places them.
pub fn gradientAlpha(stored: *const brushes.Stored, x: f32, y: f32) f32 {
    const stops = stored.stops[0..stored.len];
    if (stops.len == 0) return 1;
    var t: f32 = switch (stored.kind) {
        .linear => blk: {
            const dx = stored.b.x - stored.a.x;
            const dy = stored.b.y - stored.a.y;
            const length = dx * dx + dy * dy;
            break :blk if (length <= 0) 0 else ((x - stored.a.x) * dx + (y - stored.a.y) * dy) / length;
        },
        .radial => blk: {
            const rx = if (stored.b.x > 0) (x - stored.a.x) / stored.b.x else 0;
            const ry = if (stored.b.y > 0) (y - stored.a.y) / stored.b.y else 0;
            break :blk @sqrt(rx * rx + ry * ry);
        },
        .conic => blk: {
            // b.x holds the start angle and b.y the direction's sign.
            var angle = std.math.atan2(y - stored.a.y, x - stored.a.x) - stored.b.x;
            if (stored.b.y < 0) angle = -angle;
            const turn = angle / (2 * std.math.pi);
            break :blk turn - @floor(turn);
        },
    };
    if (stored.kind != .conic) switch (stored.spread) {
        .pad => {},
        .repeat => t -= @floor(t),
        .reflect => {
            const period = t - 2 * @floor(t / 2);
            t = if (period > 1) 2 - period else period;
        },
    };
    if (t <= stops[0].offset) return @as(f32, @floatFromInt(stops[0].color.a)) / 255;
    for (stops[1..], 1..) |stop, index| {
        if (t <= stop.offset) {
            const before = stops[index - 1];
            const span = stop.offset - before.offset;
            const f = if (span <= 0) 1 else (t - before.offset) / span;
            const a0: f32 = @floatFromInt(before.color.a);
            const a1: f32 = @floatFromInt(stop.color.a);
            return (a0 + (a1 - a0) * f) / 255;
        }
    }
    return @as(f32, @floatFromInt(stops[stops.len - 1].color.a)) / 255;
}

fn fillShape(pixels: []u8, stride: u32, box: [4]i32, rect: Rect, radius: f32, stored: ?*const brushes.Stored, scale: f32) void {
    const width: usize = @intCast(box[2] - box[0]);
    const height: usize = @intCast(box[3] - box[1]);
    for (0..height) |row| {
        const y = (@as(f32, @floatFromInt(box[1] + @as(i32, @intCast(row)))) + 0.5) / scale;
        for (0..width) |column| {
            const x = (@as(f32, @floatFromInt(box[0] + @as(i32, @intCast(column)))) + 0.5) / scale;
            var cover = roundedCoverage(rect, radius, x, y, scale);
            if (cover > 0) if (stored) |s| {
                cover *= gradientAlpha(s, x, y);
            };
            pixels[row * stride + column] = @intFromFloat(@round(std.math.clamp(cover, 0, 1) * 255));
        }
    }
}

test "rounded masks are smooth at the corners and solid inside" {
    const rect: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try std.testing.expectEqual(@as(f32, 1), roundedCoverage(rect, 6, 10, 10, 1));
    try std.testing.expectEqual(@as(f32, 0), roundedCoverage(rect, 6, 0.5, 0.5, 1));
    try std.testing.expectEqual(@as(f32, 1), roundedCoverage(rect, 0, 0.5, 0.5, 1));
    const edge = roundedCoverage(rect, 0, 20, 10, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), edge, 1e-4);
}

test "gradient alphas follow their stops" {
    const stops = [_]brushes.Stop{ .{ .offset = 0, .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 1, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } } };
    const stored = try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 100, .y = 0 }, .stops = &stops } });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), gradientAlpha(&stored, 50, 7), 1e-3);
    try std.testing.expectEqual(@as(f32, 0), gradientAlpha(&stored, -5, 0));
    const radial = try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 0, .y = 0 }, .radius = .{ .x = 10, .y = 10 }, .stops = &stops } });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), gradientAlpha(&radial, 5, 0), 1e-3);
    try std.testing.expectEqual(@as(f32, 1), gradientAlpha(&radial, 30, 30));
}

test "masks are kept while paints use them and let go after" {
    const masks = try Masks.create(std.testing.allocator);
    defer masks.destroy(null);
    masks.beginPaint(null);
    const rect: Rect = .{ .x = 2, .y = 2, .width = 16, .height = 16 };
    const visible: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const first = (try masks.shape(rect, 4, null, visible, 2, null)).?;
    try std.testing.expectEqual(@as(u32, 32), first.coverage.width);
    try std.testing.expectEqual(@as(i32, 4), first.coverage.origin_x);
    // The same shape again is the same mask.
    const again = (try masks.shape(rect, 4, null, visible, 2, null)).?;
    try std.testing.expectEqual(first.identity, again.identity);
    masks.beginPaint(null);
    _ = (try masks.shape(rect, 4, null, visible, 2, null)).?;
    try std.testing.expectEqual(@as(u64, 1), masks.stats.made);
    // Two paints without it let it go.
    masks.beginPaint(null);
    masks.beginPaint(null);
    try std.testing.expectEqual(@as(usize, 0), masks.statsNow().kept);
    // Nothing visible makes no mask.
    try std.testing.expectEqual(@as(?drawing.CoverageView, null), try masks.shape(rect, 4, null, .{ .x = 50, .y = 50, .width = 10, .height = 10 }, 1, null));
}

test "a path's mask covers its inside" {
    const masks = try Masks.create(std.testing.allocator);
    defer masks.destroy(null);
    masks.beginPaint(null);
    const triangle = try vector.Path.parseData(std.testing.allocator, "M0 0 L20 0 L0 20 Z", .{});
    defer triangle.close() catch {};
    const view = (try masks.path(triangle, .{ .x0 = 10, .y0 = 10 }, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, 1, null)).?;
    const c = view.coverage;
    const at = struct {
        fn value(cov: drawing.Coverage, x: i32, y: i32) u8 {
            return cov.pixels[@as(usize, @intCast(y - cov.origin_y)) * cov.stride + @as(usize, @intCast(x - cov.origin_x))];
        }
    };
    try std.testing.expectEqual(@as(u8, 255), at.value(c, 12, 12));
    try std.testing.expectEqual(@as(u8, 0), at.value(c, 28, 28));
}

test "an even-odd path mask leaves the overlap of its subpaths out" {
    const masks = try Masks.create(std.testing.allocator);
    defer masks.destroy(null);
    masks.beginPaint(null);
    const rings = try vector.Path.parseData(std.testing.allocator, "M0 0 H20 V20 H0 Z M5 5 H15 V15 H5 Z", .{});
    defer rings.close() catch {};
    const visible: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const filled = (try masks.pathWithRule(rings, .{}, .nonzero, visible, 1, null)).?.coverage;
    const holed = (try masks.pathWithRule(rings, .{}, .even_odd, visible, 1, null)).?.coverage;
    const at = struct {
        fn value(cov: drawing.Coverage, x: i32, y: i32) u8 {
            return cov.pixels[@as(usize, @intCast(y - cov.origin_y)) * cov.stride + @as(usize, @intCast(x - cov.origin_x))];
        }
    };
    try std.testing.expectEqual(@as(u8, 255), at.value(filled, 10, 10));
    try std.testing.expectEqual(@as(u8, 0), at.value(holed, 10, 10));
    try std.testing.expectEqual(@as(u8, 255), at.value(holed, 2, 10));
}

test "layers of masks composite from the bottom up" {
    const black: brushes.Stop = .{ .offset = 0, .color = .{ .r = 0, .g = 0, .b = 0 } };
    const solid: brushes.Gradient = .{ .linear = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 1, .y = 0 }, .stops = &.{ black, .{ .offset = 1, .color = black.color } } } };
    const outer: Rect = .{ .x = 0, .y = 0, .width = 40, .height = 40 };
    const inner: Rect = .{ .x = 10, .y = 10, .width = 20, .height = 20 };
    // A ring: the inner box excluded from the outer one.
    const ring = [_]Layer{ .{ .gradient = solid, .box = inner, .composite = .exclude }, .{ .gradient = solid, .box = outer } };
    var stored: [2]brushes.Stored = .{ try brushes.Stored.init(solid), try brushes.Stored.init(solid) };
    try std.testing.expectEqual(@as(f32, 1), layeredAlpha(&ring, &stored, 5.5, 5.5, 1));
    try std.testing.expectEqual(@as(f32, 0), layeredAlpha(&ring, &stored, 20.5, 20.5, 1));
    // Subtracted, intersected and added.
    var subtract = ring;
    subtract[0].composite = .subtract;
    try std.testing.expectEqual(@as(f32, 0), layeredAlpha(&subtract, &stored, 20.5, 20.5, 1));
    try std.testing.expectEqual(@as(f32, 0), layeredAlpha(&subtract, &stored, 5.5, 5.5, 1));
    var intersect = ring;
    intersect[0].composite = .intersect;
    try std.testing.expectEqual(@as(f32, 1), layeredAlpha(&intersect, &stored, 20.5, 20.5, 1));
    try std.testing.expectEqual(@as(f32, 0), layeredAlpha(&intersect, &stored, 5.5, 5.5, 1));
    var add = ring;
    add[0].composite = .add;
    try std.testing.expectEqual(@as(f32, 1), layeredAlpha(&add, &stored, 5.5, 5.5, 1));
    try std.testing.expectEqual(@as(f32, 1), layeredAlpha(&add, &stored, 20.5, 20.5, 1));
}

test "a clip growing in every paint takes the memory of its mask before" {
    const masks = try Masks.create(std.testing.allocator);
    defer masks.destroy(null);
    // Pull request CI sets ZIGGURAT_QUICK_TESTS: a quarter of the size
    // grows the same way at a sixteenth of the pixels.
    const scale: f32 = if (std.testing.environ.containsConstant("ZIGGURAT_QUICK_TESTS")) 0.25 else 1;
    const visible: Rect = .{ .x = 0, .y = 0, .width = 2400 * scale, .height = 1500 * scale };
    // A card opening out over 40 frames, from a cover to the window.
    var allocations: u64 = 0;
    for (0..40) |frame| {
        masks.beginPaint(null);
        const t: f32 = @as(f32, @floatFromInt(frame)) / 39;
        const rect: Rect = .{ .x = 100 * scale * (1 - t), .y = 100 * scale * (1 - t), .width = (200 + 2200 * t) * scale, .height = (120 + 1380 * t) * scale };
        const before = masks.stats.recycled;
        const view = (try masks.shape(rect, 24 * scale, null, visible, 1, null)).?;
        if (masks.stats.recycled == before) allocations += 1;
        // The mask is of the clip, whatever memory it took.
        const c = view.coverage;
        try std.testing.expectEqual(@as(u32, @intFromFloat(@ceil(rect.x + rect.width) - @floor(rect.x))), c.width);
        try std.testing.expectEqual(@as(u8, 255), c.pixels[(c.height / 2) * c.stride + c.width / 2]);
        try std.testing.expectEqual(@as(u8, 0), c.pixels[0]);
        try std.testing.expect(masks.bytes <= max_bytes);
    }
    std.debug.print("growing clip: {d} allocations in 40 frames, {d} bytes kept\n", .{ allocations, masks.bytes });
    try std.testing.expect(allocations <= 12);
}

test "a mask that shrank much takes memory of its own size, and idle spares go" {
    const masks = try Masks.create(std.testing.allocator);
    defer masks.destroy(null);
    const visible: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };
    masks.beginPaint(null);
    _ = (try masks.shape(.{ .x = 0, .y = 0, .width = 800, .height = 800 }, 8, null, visible, 1, null)).?;
    masks.beginPaint(null);
    masks.beginPaint(null);
    // The large mask went, its memory a spare, counted as it keeps it.
    try std.testing.expectEqual(@as(usize, 1), masks.statsNow().spares);
    try std.testing.expectEqual(@as(usize, 800 * 800), masks.bytes);
    // A small mask doesn't keep the large memory.
    _ = (try masks.shape(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, 8, null, visible, 1, null)).?;
    try std.testing.expectEqual(@as(u64, 0), masks.stats.recycled);
    try std.testing.expectEqual(@as(usize, 800 * 800 + 100 * 100), masks.bytes);
    // A paint that takes no spare lets it go at the next.
    masks.beginPaint(null);
    _ = (try masks.shape(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, 8, null, visible, 1, null)).?;
    masks.beginPaint(null);
    try std.testing.expectEqual(@as(usize, 0), masks.statsNow().spares);
    try std.testing.expectEqual(@as(usize, 100 * 100), masks.bytes);
}
