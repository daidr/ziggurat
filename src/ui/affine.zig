const std = @import("std");

/// Double-precision DIP geometry, independent of a renderer or native window.
/// These numerical limits do not replace physical surface/work budgets.
pub const max_component: f64 = 1e12;
pub const max_condition: f64 = 1e12;
pub const max_clip_depth = 32;
pub const max_polygon_vertices = 4 + 4 * max_clip_depth;
pub const Error = error{ InvalidGeometry, InvalidTransform, GeometryOverflow, SpacesFull, ClipsFull, ClipDepthExceeded, InvalidSpace, InvalidClip, InvalidCheckpoint, PolygonFull };

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn from(value: anytype) Point {
        return .{ .x = value.x, .y = value.y };
    }
    pub fn validate(self: Point) Error!void {
        if (!bounded(self.x) or !bounded(self.y)) return error.InvalidGeometry;
    }
};

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn from(value: anytype) Rect {
        return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
    }
    pub fn validate(self: Rect) Error!void {
        if (!bounded(self.x) or !bounded(self.y) or !std.math.isFinite(self.width) or !std.math.isFinite(self.height) or self.width < 0 or self.height < 0 or self.width > 2 * max_component or self.height > 2 * max_component or !bounded(self.x + self.width) or !bounded(self.y + self.height)) return error.InvalidGeometry;
    }
    /// Local rectangles are half open, including under a reflection.
    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.x and point.y >= self.y and point.x < self.x + self.width and point.y < self.y + self.height;
    }
    pub fn empty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }
};

/// x' = xx*x + xy*y + x0, y' = yx*x + yy*y + y0.
/// Singular and poorly conditioned transforms are outside this contract.
pub const Affine = struct {
    xx: f64 = 1,
    yx: f64 = 0,
    xy: f64 = 0,
    yy: f64 = 1,
    x0: f64 = 0,
    y0: f64 = 0,

    pub fn translation(offset: Point) Error!Affine {
        const result: Affine = .{ .x0 = offset.x, .y0 = offset.y };
        try result.validate();
        return result;
    }
    pub fn scaling(factors: Point) Error!Affine {
        const result: Affine = .{ .xx = factors.x, .yy = factors.y };
        try result.validate();
        return result;
    }
    /// Radians. Positive angles rotate clockwise in a downward Y axis.
    pub fn rotation(radians: f64) Error!Affine {
        if (!bounded(radians)) return error.InvalidTransform;
        const cosine = @cos(radians);
        const sine = @sin(radians);
        return .{ .xx = cosine, .yx = sine, .xy = -sine, .yy = cosine };
    }
    pub fn validate(self: Affine) Error!void {
        _ = try self.inverse();
    }
    fn validateComponents(self: Affine) Error!void {
        inline for (std.meta.fields(Affine)) |field| if (!bounded(@field(self, field.name))) return error.InvalidTransform;
    }
    pub fn inverse(self: Affine) Error!Affine {
        try self.validateComponents();
        const scale = @max(@max(@abs(self.xx), @abs(self.xy)), @max(@abs(self.yx), @abs(self.yy)));
        if (scale == 0) return error.InvalidTransform;
        const a = self.xx / scale;
        const b = self.xy / scale;
        const c = self.yx / scale;
        const d = self.yy / scale;
        const determinant = a * d - b * c;
        if (determinant == 0) return error.InvalidTransform;
        const norm = @max(@abs(a) + @abs(b), @abs(c) + @abs(d));
        const adjugate_norm = @max(@abs(d) + @abs(b), @abs(c) + @abs(a));
        if (norm * adjugate_norm / @abs(determinant) > max_condition) return error.InvalidTransform;
        const factor = (1 / scale) / determinant;
        var result: Affine = .{ .xx = d * factor, .xy = -b * factor, .yx = -c * factor, .yy = a * factor };
        result.x0 = -(result.xx * self.x0 + result.xy * self.y0);
        result.y0 = -(result.yx * self.x0 + result.yy * self.y0);
        try result.validateComponents();
        return result;
    }
    /// Apply self first, then outer. No native matrix convention is implicit.
    pub fn then(self: Affine, outer: Affine) Error!Affine {
        try self.validate();
        try outer.validate();
        const result: Affine = .{
            .xx = outer.xx * self.xx + outer.xy * self.yx,
            .xy = outer.xx * self.xy + outer.xy * self.yy,
            .yx = outer.yx * self.xx + outer.yy * self.yx,
            .yy = outer.yx * self.xy + outer.yy * self.yy,
            .x0 = outer.xx * self.x0 + outer.xy * self.y0 + outer.x0,
            .y0 = outer.yx * self.x0 + outer.yy * self.y0 + outer.y0,
        };
        try result.validate();
        return result;
    }
    /// Canonicalize once when a float native backend will consume the matrix.
    /// Use the returned value for both drawing and input, or reject the scope.
    /// A double-precision invertible matrix may become singular when narrowed.
    pub fn narrowed(self: Affine) Error!Affine {
        try self.validate();
        var result: Affine = undefined;
        inline for (std.meta.fields(Affine)) |field| {
            const value: f32 = @floatCast(@field(self, field.name));
            @field(result, field.name) = value;
        }
        try result.validate();
        return result;
    }
    pub fn mapPoint(self: Affine, point: Point) Error!Point {
        try self.validate();
        return map(self, point, true);
    }
    pub fn mapVector(self: Affine, vector: Point) Error!Point {
        try self.validate();
        return map(self, vector, false);
    }
    pub fn mapBounds(self: Affine, bounds: Rect) Error!Rect {
        return (try Space.init(self)).windowBounds(bounds);
    }
};

/// A pure value, not a live frame/window handle or permission to use a frame.
/// A UI host must publish its Space with the successful frame snapshot and use
/// that same committed value for editor input and native caret coordinates.
pub const Space = struct {
    to_window: Affine = .{},
    to_local: Affine = .{},

    pub fn init(to_window: Affine) Error!Space {
        return .{ .to_window = to_window, .to_local = try to_window.inverse() };
    }
    pub fn child(self: Space, to_parent: Affine) Error!Space {
        return init(try to_parent.then(self.to_window));
    }
    pub fn windowPoint(self: Space, local: Point) Error!Point {
        return map(self.to_window, local, true);
    }
    pub fn localPoint(self: Space, window: Point) Error!Point {
        return map(self.to_local, window, true);
    }
    pub fn windowVector(self: Space, local: Point) Error!Point {
        return map(self.to_window, local, false);
    }
    pub fn localVector(self: Space, window: Point) Error!Point {
        return map(self.to_local, window, false);
    }
    pub fn windowQuad(self: Space, local: Rect) Error![4]Point {
        try local.validate();
        return .{
            try self.windowPoint(.{ .x = local.x, .y = local.y }),
            try self.windowPoint(.{ .x = local.x + local.width, .y = local.y }),
            try self.windowPoint(.{ .x = local.x + local.width, .y = local.y + local.height }),
            try self.windowPoint(.{ .x = local.x, .y = local.y + local.height }),
        };
    }
    pub fn windowBounds(self: Space, local: Rect) Error!Rect {
        const quad = try self.windowQuad(local);
        return boundsOf(&quad);
    }
    /// System IME candidates accept an axis-aligned window rectangle. This maps
    /// the logical caret; it does not rotate the native candidate window.
    pub fn windowCaret(self: Space, local_caret: Rect) Error!Rect {
        return self.windowBounds(local_caret);
    }
    pub fn contains(self: Space, local_bounds: Rect, window_point: Point) Error!bool {
        try local_bounds.validate();
        try window_point.validate();
        // A point outside the local numerical domain is outside every valid
        // local rectangle. It is an ordinary miss, not an input-path failure.
        const local: Point = .{ .x = self.to_local.xx * window_point.x + self.to_local.xy * window_point.y + self.to_local.x0, .y = self.to_local.yx * window_point.x + self.to_local.yy * window_point.y + self.to_local.y0 };
        return local_bounds.contains(local);
    }
};

pub const SpaceId = enum(u16) { identity = 0, _ };
pub const ClipId = enum(u16) { _ };
/// IDs belong to one table snapshot. Reset/rollback invalidates removed IDs;
/// they are not generation handles and must not escape their owning snapshot.
pub const Ref = struct { space: SpaceId = .identity, clip: ?ClipId = null };
pub const Checkpoint = struct { spaces: usize, clips: usize };
const Clip = struct { bounds: Rect, space: SpaceId, parent: ?ClipId, depth: u8 };

/// Convex visible geometry in window DIP. Boundary is closed for calculating
/// area/bounds; Input.contains retains half-open local rectangle hit semantics.
pub const Polygon = struct {
    storage: [max_polygon_vertices]Point = undefined,
    len: usize = 0,

    pub fn points(self: *const Polygon) []const Point {
        return self.storage[0..self.len];
    }
    pub fn bounds(self: *const Polygon) ?Rect {
        if (self.len < 3 or self.doubleArea() == 0) return null;
        return boundsOf(self.points());
    }
    /// Convex clipping without allocating or changing the source value.
    pub fn clipBounds(self: *const Polygon, rect: Rect, output: *Polygon) Error!void {
        try rect.validate();
        var candidate = self.*;
        var scratch: Polygon = .{};
        for (clipPlanes(.{}, rect)) |plane| {
            try clipPlane(&candidate, plane, &scratch);
            std.mem.swap(Polygon, &candidate, &scratch);
        }
        output.* = candidate;
    }
    fn doubleArea(self: *const Polygon) f64 {
        if (self.len < 3) return 0;
        // Triangles relative to one vertex avoid subtracting huge absolute
        // coordinate products when a small polygon is far from the origin.
        const origin = self.storage[0];
        var area: f64 = 0;
        for (1..self.len - 1) |index| {
            const a = self.storage[index];
            const b = self.storage[index + 1];
            area += (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x);
        }
        return area;
    }
    fn append(self: *Polygon, point: Point) Error!void {
        if (self.len > 0 and std.meta.eql(self.storage[self.len - 1], point)) return;
        if (self.len == self.storage.len) return error.PolygonFull;
        self.storage[self.len] = point;
        self.len += 1;
    }
    fn trim(self: *Polygon) void {
        if (self.len > 1 and std.meta.eql(self.storage[0], self.storage[self.len - 1])) self.len -= 1;
    }
};

/// Fixed storage intended for an explicitly prepared optional UI workspace.
/// Every append validates a candidate before publishing its count. Entries
/// contain values only, so a committed table can be copied to native snapshots.
/// Clip parents always precede children; depth is capped independently of slots.
pub fn GeometryTable(comptime space_capacity: usize, comptime clip_capacity: usize) type {
    if (space_capacity == 0 or space_capacity > 65535 or clip_capacity > 65535) @compileError("invalid affine table capacities");
    return struct {
        const Self = @This();
        spaces: [space_capacity]Space = blk: {
            var storage: [space_capacity]Space = undefined;
            storage[0] = .{};
            break :blk storage;
        },
        clips: [clip_capacity]Clip = undefined,
        space_len: usize = 1,
        clip_len: usize = 0,

        pub fn init() Self {
            return .{};
        }
        pub fn reset(self: *Self) void {
            self.spaces[0] = .{};
            self.space_len = 1;
            self.clip_len = 0;
        }
        pub fn checkpoint(self: *const Self) Checkpoint {
            return .{ .spaces = self.space_len, .clips = self.clip_len };
        }
        pub fn rollback(self: *Self, mark: Checkpoint) Error!void {
            try self.validLengths();
            if (mark.spaces == 0 or mark.spaces > self.space_len or mark.clips > self.clip_len) return error.InvalidCheckpoint;
            for (self.clips[0..mark.clips]) |clip| if (@intFromEnum(clip.space) >= mark.spaces) return error.InvalidCheckpoint;
            self.space_len = mark.spaces;
            self.clip_len = mark.clips;
        }
        pub fn addSpace(self: *Self, to_window: Affine) Error!SpaceId {
            try self.validLengths();
            const candidate = try Space.init(to_window);
            if (self.space_len == space_capacity) return error.SpacesFull;
            const id: SpaceId = @enumFromInt(self.space_len);
            self.spaces[self.space_len] = candidate;
            self.space_len += 1;
            return id;
        }
        pub fn addChild(self: *Self, parent: SpaceId, to_parent: Affine) Error!SpaceId {
            return self.addSpace(try to_parent.then((try self.getSpace(parent)).to_window));
        }
        pub fn addClip(self: *Self, space_id: SpaceId, parent: ?ClipId, bounds: Rect) Error!ClipId {
            try self.validLengths();
            const space = try self.getSpace(space_id);
            try bounds.validate();
            _ = try space.windowQuad(bounds);
            const depth = if (parent) |id| (try self.getClip(id)).depth + @as(usize, 1) else 1;
            if (depth > max_clip_depth) return error.ClipDepthExceeded;
            if (self.clip_len == clip_capacity) return error.ClipsFull;
            const id: ClipId = @enumFromInt(self.clip_len);
            if (clip_capacity > 0) self.clips[self.clip_len] = .{ .bounds = bounds, .space = space_id, .parent = parent, .depth = @intCast(depth) } else return error.ClipsFull;
            self.clip_len += 1;
            return id;
        }
        pub fn getSpace(self: *const Self, id: SpaceId) Error!Space {
            try self.validLengths();
            const index = @intFromEnum(id);
            if (index >= self.space_len) return error.InvalidSpace;
            return self.spaces[index];
        }
        fn getClip(self: *const Self, id: ClipId) Error!Clip {
            try self.validLengths();
            const index = @intFromEnum(id);
            if (index >= self.clip_len) return error.InvalidClip;
            return if (clip_capacity > 0) self.clips[index] else error.InvalidClip;
        }
        fn validLengths(self: *const Self) Error!void {
            if (self.space_len == 0 or self.space_len > space_capacity) return error.InvalidSpace;
            if (self.clip_len > clip_capacity) return error.InvalidClip;
        }
        fn chain(self: *const Self, leaf: ?ClipId, output: *[max_clip_depth]ClipId) Error!usize {
            var current = leaf;
            var len: usize = 0;
            while (current) |id| {
                if (len == output.len) return error.ClipDepthExceeded;
                const clip = try self.getClip(id);
                _ = try self.getSpace(clip.space);
                if (clip.parent) |parent| if (@intFromEnum(parent) >= @intFromEnum(id)) return error.InvalidClip;
                output[len] = id;
                len += 1;
                current = clip.parent;
            }
            return len;
        }
        pub fn contains(self: *const Self, ref: Ref, local_bounds: Rect, window_point: Point) Error!bool {
            const space = try self.getSpace(ref.space);
            try local_bounds.validate();
            try window_point.validate();
            var ids: [max_clip_depth]ClipId = undefined;
            const count = try self.chain(ref.clip, &ids);
            if (!(try space.contains(local_bounds, window_point))) return false;
            for (ids[0..count]) |id| {
                const clip = try self.getClip(id);
                if (!(try (try self.getSpace(clip.space)).contains(clip.bounds, window_point))) return false;
            }
            return true;
        }
        /// Output is unchanged on error. No allocator/native operation occurs.
        /// Work is bounded by 4*max_clip_depth*max_polygon_vertices edge tests.
        pub fn visiblePolygon(self: *const Self, ref: Ref, local_bounds: Rect, output: *Polygon) Error!void {
            const space = try self.getSpace(ref.space);
            try local_bounds.validate();
            var ids: [max_clip_depth]ClipId = undefined;
            const count = try self.chain(ref.clip, &ids);
            var candidate: Polygon = .{};
            if (!local_bounds.empty()) {
                const quad = try space.windowQuad(local_bounds);
                @memcpy(candidate.storage[0..4], &quad);
                candidate.len = 4;
            }
            var scratch: Polygon = .{};
            for (ids[0..count]) |id| {
                const clip = try self.getClip(id);
                if (clip.bounds.empty()) {
                    candidate.len = 0;
                    break;
                }
                const clip_space = try self.getSpace(clip.space);
                const planes = clipPlanes(clip_space.to_local, clip.bounds);
                for (planes) |plane| {
                    try clipPlane(&candidate, plane, &scratch);
                    std.mem.swap(Polygon, &candidate, &scratch);
                    if (candidate.len == 0) break;
                }
                if (candidate.len == 0) break;
            }
            output.* = candidate;
        }
        pub fn visibleBounds(self: *const Self, ref: Ref, local_bounds: Rect) Error!?Rect {
            var polygon: Polygon = .{};
            try self.visiblePolygon(ref, local_bounds, &polygon);
            return polygon.bounds();
        }
        /// A system-layout caret is often a zero-width segment. Clip it as a
        /// segment instead of discarding it for having no filled area. Caret
        /// anchors use closed clip boundaries; pointer hits remain half open.
        pub fn visibleCaretBounds(self: *const Self, ref: Ref, local_caret: Rect) Error!?Rect {
            if (!local_caret.empty()) return self.visibleBounds(ref, local_caret);
            const space = try self.getSpace(ref.space);
            try local_caret.validate();
            const first = try space.windowPoint(.{ .x = local_caret.x, .y = local_caret.y });
            const last = try space.windowPoint(.{ .x = local_caret.x + local_caret.width, .y = local_caret.y + local_caret.height });
            var ids: [max_clip_depth]ClipId = undefined;
            const count = try self.chain(ref.clip, &ids);
            var start: f64 = 0;
            var end: f64 = 1;
            for (ids[0..count]) |id| {
                const clip = try self.getClip(id);
                if (clip.bounds.empty()) return null;
                const clip_space = try self.getSpace(clip.space);
                for (clipPlanes(clip_space.to_local, clip.bounds)) |plane| {
                    const before = plane.distance(first);
                    const after = plane.distance(last);
                    if (before < 0 and after < 0) return null;
                    if ((before < 0) != (after < 0)) {
                        const fraction = std.math.clamp(before / (before - after), 0, 1);
                        if (before < 0) start = @max(start, fraction) else end = @min(end, fraction);
                        if (start > end) return null;
                    }
                }
            }
            const clipped = [_]Point{
                .{ .x = first.x + (last.x - first.x) * start, .y = first.y + (last.y - first.y) * start },
                .{ .x = first.x + (last.x - first.x) * end, .y = first.y + (last.y - first.y) * end },
            };
            return boundsOf(&clipped);
        }
    };
}

fn bounded(value: f64) bool {
    return std.math.isFinite(value) and @abs(value) <= max_component;
}
fn map(matrix: Affine, point: Point, translate: bool) Error!Point {
    try point.validate();
    const result: Point = .{ .x = matrix.xx * point.x + matrix.xy * point.y + (if (translate) matrix.x0 else @as(f64, 0)), .y = matrix.yx * point.x + matrix.yy * point.y + (if (translate) matrix.y0 else @as(f64, 0)) };
    if (!bounded(result.x) or !bounded(result.y)) return error.GeometryOverflow;
    return result;
}
fn boundsOf(points: []const Point) Rect {
    std.debug.assert(points.len > 0);
    var left = points[0].x;
    var right = left;
    var top = points[0].y;
    var bottom = top;
    for (points[1..]) |point| {
        left = @min(left, point.x);
        top = @min(top, point.y);
        right = @max(right, point.x);
        bottom = @max(bottom, point.y);
    }
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}
const Plane = struct {
    x: f64,
    y: f64,
    origin: f64,
    fn distance(self: Plane, point: Point) f64 {
        return self.x * point.x + self.y * point.y + self.origin;
    }
};
fn clipPlanes(inverse: Affine, rect: Rect) [4]Plane {
    return .{
        .{ .x = inverse.xx, .y = inverse.xy, .origin = inverse.x0 - rect.x },
        .{ .x = -inverse.xx, .y = -inverse.xy, .origin = rect.x + rect.width - inverse.x0 },
        .{ .x = inverse.yx, .y = inverse.yy, .origin = inverse.y0 - rect.y },
        .{ .x = -inverse.yx, .y = -inverse.yy, .origin = rect.y + rect.height - inverse.y0 },
    };
}
fn clipPlane(input: *const Polygon, plane: Plane, output: *Polygon) Error!void {
    output.len = 0;
    if (input.len == 0) return;
    var previous = input.storage[input.len - 1];
    var previous_distance = plane.distance(previous);
    for (input.points()) |current| {
        const distance = plane.distance(current);
        if ((distance >= 0) != (previous_distance >= 0)) {
            const fraction = std.math.clamp(previous_distance / (previous_distance - distance), 0, 1);
            try output.append(.{ .x = previous.x + (current.x - previous.x) * fraction, .y = previous.y + (current.y - previous.y) * fraction });
        }
        if (distance >= 0) try output.append(current);
        previous = current;
        previous_distance = distance;
    }
    output.trim();
}
