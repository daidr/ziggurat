//! Which device pixels of a software plane a frame changes since the last
//! frame drawn on it.
//!
//! Each frame folds a hash of every drawing command, with the clips around
//! it and the resources it reads, into the tiles its bounds cover, in order.
//! Tiles whose hash differs from the last frame's are damaged; the rest are
//! left as they are on the plane, which keeps its pixels between frames.
//! Damaged tiles become at most `max_rects` rectangles apart from each
//! other, each redrawn on its own under a clip. A frame drawing commands
//! whose pixels depend on others around them (groups, transforms, effects,
//! backdrops) is drawn whole, as is a frame whose damage covers half of it.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
const commands = @import("commands.zig");
const loading = @import("loading.zig");

pub const Rect = commands.Rect;
pub const Command = commands.Command;

/// Rectangles one frame draws again, at most.
pub const max_rects = 8;
/// Tiles a plane is split into, at most; tiles grow for larger planes.
pub const max_tiles = 2048;
const min_tile = 16;
/// Device pixels added around each command's bounds, for antialiasing and
/// filtered image edges.
const margin = 2;
/// Runs of damaged tiles merged into rectangles, at most, before the frame
/// is drawn whole.
const max_runs = 96;
const max_clips = 32;

/// A rectangle of device pixels, `x0`/`y0` inclusive, `x1`/`y1` exclusive.
pub const Box = struct {
    x0: i32 = 0,
    y0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,

    pub fn isEmpty(self: Box) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }
    pub fn intersect(self: Box, other: Box) Box {
        return .{ .x0 = @max(self.x0, other.x0), .y0 = @max(self.y0, other.y0), .x1 = @min(self.x1, other.x1), .y1 = @min(self.y1, other.y1) };
    }
    pub fn unite(self: Box, other: Box) Box {
        return .{ .x0 = @min(self.x0, other.x0), .y0 = @min(self.y0, other.y0), .x1 = @max(self.x1, other.x1), .y1 = @max(self.y1, other.y1) };
    }
    pub fn intersects(self: Box, other: Box) bool {
        return !self.intersect(other).isEmpty();
    }
    pub fn area(self: Box) u64 {
        if (self.isEmpty()) return 0;
        return @as(u64, @intCast(self.x1 - self.x0)) * @as(u64, @intCast(self.y1 - self.y0));
    }
    /// The rectangle in DIP for a plane at `scale`.
    pub fn dip(self: Box, scale: f32) Rect {
        return .{ .x = @as(f32, @floatFromInt(self.x0)) / scale, .y = @as(f32, @floatFromInt(self.y0)) / scale, .width = @as(f32, @floatFromInt(self.x1 - self.x0)) / scale, .height = @as(f32, @floatFromInt(self.y1 - self.y0)) / scale };
    }
};

/// What a frame draws: everything, nothing, or a few rectangles.
pub const Damage = struct {
    full: bool = true,
    len: u8 = 0,
    rects: [max_rects]Box = undefined,

    pub const whole: Damage = .{};
    pub fn slice(self: *const Damage) []const Box {
        return self.rects[0..self.len];
    }
    pub fn isNone(self: Damage) bool {
        return !self.full and self.len == 0;
    }
    /// Device pixels drawn again, for a plane of `width` by `height`.
    pub fn pixels(self: Damage, width: u32, height: u32) u64 {
        if (self.full) return @as(u64, width) * height;
        var total: u64 = 0;
        for (self.slice()) |box| total += box.area();
        return total;
    }
};

/// The resources a command reads, by index.
pub const Sources = struct {
    text: []const u8 = &.{},
    brushes: []const commands.brushes.Stored = &.{},
    prepared: []const drawing.PreparedTextView = &.{},
    images: []const drawing.ImageView = &.{},
    coverage: []const drawing.CoverageView = &.{},
    indicators: []const loading.Entry = &.{},

    pub fn of(buffer: *const commands.Buffer) Sources {
        return .{ .text = buffer.textBytes(), .brushes = buffer.brushResources(), .prepared = buffer.preparedTextResources(), .images = buffer.imageResources(), .coverage = buffer.coverageResources(), .indicators = buffer.indicator_storage[0..buffer.indicator_len] };
    }
};

/// The device pixels a drawing command can change at `scale`, before
/// clips, or null for a command that is not a plain drawing (clips, groups,
/// transforms, effects, backdrops) or reads a resource it does not have.
pub fn commandBox(command: Command, sources: Sources, scale: f32) ?Box {
    const rect: Rect = switch (command) {
        .fill => |value| value.bounds,
        .shape => |value| value.bounds,
        .gradient => |value| value.bounds,
        .text => |value| value.bounds,
        .image => |value| value.destination,
        .prepared_text => |value| {
            if (value.resource >= sources.prepared.len) return null;
            const view = sources.prepared[value.resource];
            const c = view.coverage;
            if (!(c.scale > 0)) return null;
            var box = toBox(.{ .x = value.origin.x + @as(f32, @floatFromInt(c.origin_x)) / c.scale, .y = value.origin.y + @as(f32, @floatFromInt(c.origin_y)) / c.scale, .width = @as(f32, @floatFromInt(c.width)) / c.scale, .height = @as(f32, @floatFromInt(c.height)) / c.scale }, scale) orelse return null;
            if (view.clip) |clip| box = box.intersect(toBox(.{ .x = value.origin.x + clip.x, .y = value.origin.y + clip.y, .width = clip.width, .height = clip.height }, scale) orelse return null);
            return box;
        },
        .coverage => |value| rect: {
            if (value.resource >= sources.coverage.len) return null;
            const c = sources.coverage[value.resource].coverage;
            if (!(c.scale > 0)) return null;
            break :rect .{ .x = value.origin.x + @as(f32, @floatFromInt(c.origin_x)) / c.scale, .y = value.origin.y + @as(f32, @floatFromInt(c.origin_y)) / c.scale, .width = @as(f32, @floatFromInt(c.width)) / c.scale, .height = @as(f32, @floatFromInt(c.height)) / c.scale };
        },
        .indicator => |slot| rect: {
            if (slot >= sources.indicators.len) return null;
            break :rect sources.indicators[slot].bounds;
        },
        else => return null,
    };
    return toBox(rect, scale);
}

/// The device pixels a rectangle in DIP touches at `scale`, with `margin`
/// around them, or null when it is not finite.
pub fn toBox(rect: Rect, scale: f32) ?Box {
    const s: f64 = scale;
    const x0 = @floor(@as(f64, rect.x) * s) - margin;
    const y0 = @floor(@as(f64, rect.y) * s) - margin;
    const x1 = @ceil((@as(f64, rect.x) + @max(0, rect.width)) * s) + margin;
    const y1 = @ceil((@as(f64, rect.y) + @max(0, rect.height)) * s) + margin;
    const limit: f64 = 1 << 30;
    if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or !std.math.isFinite(x1) or !std.math.isFinite(y1)) return null;
    return .{ .x0 = @intFromFloat(std.math.clamp(x0, -limit, limit)), .y0 = @intFromFloat(std.math.clamp(y0, -limit, limit)), .x1 = @intFromFloat(std.math.clamp(x1, -limit, limit)), .y1 = @intFromFloat(std.math.clamp(y1, -limit, limit)) };
}

/// A clip's device pixels: those it leaves any coverage in.
fn clipBox(rect: Rect, scale: f32) ?Box {
    var box = toBox(rect, scale) orelse return null;
    box.x0 += margin;
    box.y0 += margin;
    box.x1 -= margin;
    box.y1 -= margin;
    return box;
}

/// Keeps the tile hashes of the last frame a plane drew.
pub const Tracker = struct {
    width: u32 = 0,
    height: u32 = 0,
    scale: f32 = 0,
    transparent: bool = false,
    /// Which plane the hashes describe, as its renderer counts them.
    plane: u64 = 0,
    /// The hashes in `tiles[front]` describe the plane's pixels.
    valid: bool = false,
    /// The last plan hashed its frame, so `commit` can trust the hashes.
    hashed: bool = false,
    front: u1 = 0,
    tile: u32 = min_tile,
    columns: u32 = 0,
    rows: u32 = 0,
    tiles: [2][max_tiles]u64 = undefined,

    /// The plane no longer shows what the last plan described: the next
    /// frame is drawn whole.
    pub fn invalidate(self: *Tracker) void {
        self.valid = false;
        self.hashed = false;
    }

    /// Hashes the frame in `buffer` and returns what to draw again on
    /// `plane`, `width` by `height` at `scale`. Call `commit` once the
    /// plane drew it, or `invalidate` when it did not.
    pub fn plan(self: *Tracker, buffer: *const commands.Buffer, plane: u64, width: u32, height: u32, scale: f32, transparent: bool) Damage {
        if (plane != self.plane) {
            self.plane = plane;
            self.valid = false;
        }
        if (width != self.width or height != self.height or scale != self.scale or transparent != self.transparent or self.columns == 0) {
            self.width = width;
            self.height = height;
            self.scale = scale;
            self.transparent = transparent;
            self.valid = false;
            self.tile = min_tile;
            while (true) {
                self.columns = (width + self.tile - 1) / self.tile;
                self.rows = (height + self.tile - 1) / self.tile;
                if (@as(u64, self.columns) * self.rows <= max_tiles) break;
                self.tile *= 2;
            }
        }
        const count = self.columns * self.rows;
        const back = self.front ^ 1;
        const tiles = self.tiles[back][0..count];
        self.hashed = self.hash(buffer, tiles);
        if (!self.hashed) {
            self.valid = false;
            return .whole;
        }
        if (!self.valid) return .whole;
        return self.collect(self.tiles[self.front][0..count], tiles);
    }

    /// The plane now shows the frame the last `plan` hashed.
    pub fn commit(self: *Tracker) void {
        if (!self.hashed) return;
        self.hashed = false;
        self.front ^= 1;
        self.valid = true;
    }

    fn hash(self: *Tracker, buffer: *const commands.Buffer, tiles: []u64) bool {
        const seed = std.hash.Wyhash.hash(0x5a17, std.mem.asBytes(&self.scale));
        @memset(tiles, seed);
        const sources = Sources.of(buffer);
        const surface: Box = .{ .x1 = @intCast(self.width), .y1 = @intCast(self.height) };
        var clips: [max_clips + 1]Box = undefined;
        var states: [max_clips + 1]u64 = undefined;
        clips[0] = surface;
        states[0] = seed;
        var depth: usize = 0;
        for (buffer.commands()) |command| {
            switch (command) {
                .push_clip => |rect| {
                    if (depth == max_clips) return false;
                    const box = clipBox(rect, self.scale) orelse return false;
                    var hasher = std.hash.Wyhash.init(states[depth]);
                    put(&hasher, rect);
                    depth += 1;
                    clips[depth] = clips[depth - 1].intersect(box);
                    states[depth] = hasher.final();
                    continue;
                },
                .pop_clip => {
                    if (depth == 0) return false;
                    depth -= 1;
                    continue;
                },
                .fill, .shape, .gradient, .text, .image, .prepared_text, .coverage, .indicator => {},
                else => return false,
            }
            const box = (commandBox(command, sources, self.scale) orelse return false).intersect(clips[depth]);
            if (box.isEmpty()) continue;
            var hasher = std.hash.Wyhash.init(states[depth]);
            if (!hashCommand(&hasher, command, sources)) return false;
            const value = hasher.final();
            const tile: i32 = @intCast(self.tile);
            const c0: u32 = @intCast(@divFloor(box.x0, tile));
            const r0: u32 = @intCast(@divFloor(box.y0, tile));
            const c1: u32 = @intCast(@divFloor(box.x1 - 1, tile));
            const r1: u32 = @intCast(@divFloor(box.y1 - 1, tile));
            var row = r0;
            while (row <= r1) : (row += 1) {
                var column = c0;
                while (column <= c1) : (column += 1) {
                    const slot = &tiles[row * self.columns + column];
                    slot.* = std.hash.Wyhash.hash(value, std.mem.asBytes(slot));
                }
            }
        }
        return depth == 0;
    }

    fn collect(self: *Tracker, before: []const u64, after: []const u64) Damage {
        var runs: [max_runs]Box = undefined;
        var len: usize = 0;
        const tile: i32 = @intCast(self.tile);
        var row: u32 = 0;
        while (row < self.rows) : (row += 1) {
            var column: u32 = 0;
            while (column < self.columns) {
                if (before[row * self.columns + column] == after[row * self.columns + column]) {
                    column += 1;
                    continue;
                }
                const start = column;
                while (column < self.columns and before[row * self.columns + column] != after[row * self.columns + column]) column += 1;
                const box: Box = .{ .x0 = @as(i32, @intCast(start)) * tile, .y0 = @as(i32, @intCast(row)) * tile, .x1 = @as(i32, @intCast(column)) * tile, .y1 = @as(i32, @intCast(row + 1)) * tile };
                // Grow the run of the row above that has the same columns.
                const above = for (runs[0..len]) |*run| {
                    if (run.x0 == box.x0 and run.x1 == box.x1 and run.y1 == box.y0) break run;
                } else null;
                if (above) |run| {
                    run.y1 = box.y1;
                    continue;
                }
                if (len == max_runs) return .whole;
                runs[len] = box;
                len += 1;
            }
        }
        const surface: Box = .{ .x1 = @intCast(self.width), .y1 = @intCast(self.height) };
        len = merge(runs[0..len], max_rects);
        var result: Damage = .{ .full = false };
        var total: u64 = 0;
        for (runs[0..len]) |box| {
            const clipped = box.intersect(surface);
            if (clipped.isEmpty()) continue;
            result.rects[result.len] = clipped;
            result.len += 1;
            total += clipped.area();
        }
        if (total * 2 > surface.area()) return .whole;
        return result;
    }
};

/// Whether two rectangles overlap or share an edge.
fn meets(a: Box, b: Box) bool {
    return a.x0 <= b.x1 and b.x0 <= a.x1 and a.y0 <= b.y1 and b.y0 <= a.y1;
}

/// Merges rectangles until they are apart from each other and at most
/// `limit` remain: overlapping ones always (each is drawn on its own, so
/// none may cover another's pixels), touching ones whose union covers
/// nothing more, then the pairs whose union grows least. Returns the count.
pub fn merge(boxes: []Box, limit: usize) usize {
    var len = boxes.len;
    while (len > 1) {
        var pair: ?[2]usize = null;
        var least: u64 = std.math.maxInt(u64);
        search: for (0..len) |a| for (a + 1..len) |b| {
            const growth = boxes[a].unite(boxes[b]).area() -| boxes[a].area() -| boxes[b].area();
            if (boxes[a].intersects(boxes[b]) or (meets(boxes[a], boxes[b]) and growth == 0)) {
                pair = .{ a, b };
                break :search;
            }
            if (len > limit and growth < least) {
                least = growth;
                pair = .{ a, b };
            }
        };
        const chosen = pair orelse break;
        boxes[chosen[0]] = boxes[chosen[0]].unite(boxes[chosen[1]]);
        boxes[chosen[1]] = boxes[len - 1];
        len -= 1;
    }
    return len;
}

fn hashCommand(hasher: *std.hash.Wyhash, command: Command, sources: Sources) bool {
    put(hasher, @backingInt(std.meta.activeTag(command)));
    switch (command) {
        .fill => |value| put(hasher, value),
        .shape => |value| put(hasher, value),
        .gradient => |value| {
            if (value.brush >= sources.brushes.len) return false;
            put(hasher, value);
            const brush = sources.brushes[value.brush];
            put(hasher, .{ brush.kind, brush.a, brush.b, brush.len, brush.interpolation, brush.spread });
            for (brush.stops[0..@min(brush.len, brush.stops.len)]) |stop| put(hasher, stop);
        },
        .text => |value| {
            if (value.offset > sources.text.len or value.len > sources.text.len - value.offset) return false;
            put(hasher, .{ value.bounds, value.color, @as(u32, @bitCast(value.font)) });
            hasher.update(sources.text[value.offset..][0..value.len]);
        },
        .prepared_text => |value| {
            if (value.resource >= sources.prepared.len) return false;
            const view = sources.prepared[value.resource];
            const c = view.coverage;
            put(hasher, .{ value.origin, value.color, @intFromPtr(view.native_layout), @intFromPtr(view.native_coverage), c.width, c.height, c.stride, c.origin_x, c.origin_y, c.scale, view.clip != null });
            if (view.clip) |clip| put(hasher, clip);
            const bytes = @as(usize, c.stride) * c.height;
            if (bytes > c.pixels.len) return false;
            hasher.update(c.pixels[0..bytes]);
        },
        .coverage => |value| {
            if (value.resource >= sources.coverage.len) return false;
            const view = sources.coverage[value.resource];
            const c = view.coverage;
            put(hasher, .{ value.origin, value.color, view.identity, c.width, c.height, c.origin_x, c.origin_y, c.scale });
        },
        .image => |value| {
            if (value.resource >= sources.images.len) return false;
            put(hasher, .{ value.destination, value.alignment, value.fit, value.sampling, value.opacity, sources.images[value.resource].identity });
        },
        .indicator => |slot| {
            if (slot >= sources.indicators.len) return false;
            put(hasher, sources.indicators[slot]);
        },
        else => return false,
    }
    return true;
}

/// Feeds a value field by field, so padding never reaches the hash.
fn put(hasher: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .float => {
            // -0 and 0 draw the same; NaN never reaches a plane.
            const widened: f64 = if (value == 0) 0 else value;
            hasher.update(std.mem.asBytes(&widened));
        },
        .int, .comptime_int => {
            const widened: u64 = @truncate(@as(u128, @bitCast(@as(i128, value))));
            hasher.update(std.mem.asBytes(&widened));
        },
        .bool => put(hasher, @intFromBool(value)),
        .@"enum" => put(hasher, @backingInt(value)),
        .optional => if (value) |inner| {
            put(hasher, 1);
            put(hasher, inner);
        } else put(hasher, 0),
        .array => for (value) |item| put(hasher, item),
        .@"struct" => |info| {
            if (info.layout == .@"packed") {
                put(hasher, @as(info.backing_integer.?, @bitCast(value)));
            } else inline for (info.field_names) |name| put(hasher, @field(value, name));
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("untagged union " ++ @typeName(T));
            put(hasher, @backingInt(std.meta.activeTag(value)));
            switch (value) {
                inline else => |inner| put(hasher, inner),
            }
        },
        .void => {},
        else => @compileError("cannot hash " ++ @typeName(T)),
    }
}

fn testPlan(tracker: *Tracker, buffer: *const commands.Buffer) Damage {
    const value = tracker.plan(buffer, 1, 256, 128, 1, false);
    tracker.commit();
    return value;
}

test "only the tiles a changed command covers are damaged" {
    var tracker: Tracker = .{};
    var buffer: commands.Buffer = .{};
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0xffffff);
    try buffer.fill(.{ .x = 10, .y = 10, .width = 20, .height = 20 }, 0xff0000);
    try buffer.text(.{ .x = 100, .y = 80, .width = 100, .height = 20 }, "Hello", 0);
    // The first frame draws the plane whole.
    try std.testing.expect(testPlan(&tracker, &buffer).full);
    // The same frame again draws nothing.
    try std.testing.expect(testPlan(&tracker, &buffer).isNone());
    // Another color for the square damages the tiles under it only.
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0xffffff);
    try buffer.fill(.{ .x = 10, .y = 10, .width = 20, .height = 20 }, 0x00ff00);
    try buffer.text(.{ .x = 100, .y = 80, .width = 100, .height = 20 }, "Hello", 0);
    const changed = testPlan(&tracker, &buffer);
    try std.testing.expect(!changed.full);
    try std.testing.expectEqual(@as(u8, 1), changed.len);
    try std.testing.expectEqual(Box{ .x0 = 0, .y0 = 0, .x1 = 32, .y1 = 32 }, changed.rects[0]);
    // Other text in the same place damages the text's tiles.
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0xffffff);
    try buffer.fill(.{ .x = 10, .y = 10, .width = 20, .height = 20 }, 0x00ff00);
    try buffer.text(.{ .x = 100, .y = 80, .width = 100, .height = 20 }, "World", 0);
    const text = testPlan(&tracker, &buffer);
    try std.testing.expect(!text.full);
    try std.testing.expectEqual(@as(u8, 1), text.len);
    try std.testing.expect(text.rects[0].x0 <= 96 and text.rects[0].x1 >= 202 and text.rects[0].y0 <= 78 and text.rects[0].y1 >= 102);
}

test "damage far apart stays in separate rectangles and a moved clip damages both places" {
    var tracker: Tracker = .{};
    var buffer: commands.Buffer = .{};
    const Frame = struct {
        fn draw(target: *commands.Buffer, a: u32, b: u32, clip_x: f32) !void {
            target.reset();
            try target.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0xffffff);
            try target.fill(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, a);
            try target.fill(.{ .x = 240, .y = 112, .width = 8, .height = 8 }, b);
            try target.pushClip(.{ .x = clip_x, .y = 64, .width = 16, .height = 16 });
            try target.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0x0000ff);
            try target.popClip();
        }
    };
    try Frame.draw(&buffer, 1, 2, 64);
    _ = testPlan(&tracker, &buffer);
    try Frame.draw(&buffer, 3, 4, 64);
    const corners = testPlan(&tracker, &buffer);
    try std.testing.expectEqual(@as(u8, 2), corners.len);
    try std.testing.expectEqual(@as(u64, 16 * 16 + 32 * 32), corners.pixels(256, 128));
    try Frame.draw(&buffer, 3, 4, 160);
    const moved = testPlan(&tracker, &buffer);
    try std.testing.expectEqual(@as(u8, 2), moved.len);
    for (moved.slice()) |box| try std.testing.expect(box.y0 <= 64 and box.y1 >= 80);
}

test "groups, transforms and effects draw the frame whole, as does damage over half the plane" {
    var tracker: Tracker = .{};
    var buffer: commands.Buffer = .{};
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0xffffff);
    _ = testPlan(&tracker, &buffer);
    try buffer.backdropEffect(.{ .bounds = .{ .x = 8, .y = 0, .width = 16, .height = 16 }, .kind = .blur, .sigma = 2, .fallback = .rgb(0xff0000) });
    try std.testing.expect(testPlan(&tracker, &buffer).full);
    // The frame after a whole one compares with nothing it can trust.
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0xffffff);
    try std.testing.expect(testPlan(&tracker, &buffer).full);
    try std.testing.expect(testPlan(&tracker, &buffer).isNone());
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0x000000);
    try std.testing.expect(testPlan(&tracker, &buffer).full);
}

test "merging keeps rectangles apart and within the limit" {
    var boxes = [_]Box{
        .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .{ .x0 = 10, .y0 = 0, .x1 = 20, .y1 = 10 },
        .{ .x0 = 100, .y0 = 100, .x1 = 110, .y1 = 110 },
        .{ .x0 = 200, .y0 = 0, .x1 = 210, .y1 = 10 },
    };
    try std.testing.expectEqual(@as(usize, 3), merge(&boxes, 8));
    try std.testing.expectEqual(@as(usize, 2), merge(&boxes, 2));
}
