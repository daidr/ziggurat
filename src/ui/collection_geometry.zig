const std = @import("std");
const zio = @import("ziggurat_io");

/// Private math boundary. Both input and output are copied POD values; this
/// code has no Window, Context, allocator, registration or foreign callbacks.
/// Native callers may use it after App shutdown and from a COM request thread.
pub fn Geometry(comptime a: type) type {
    return struct {
        const Self = @This();
        pub const Point = extern struct { x: f64, y: f64 };
        pub const Rect = extern struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };
        pub const Mapping = extern struct {
            forward: [6]f64,
            viewport: Rect,
            polygon: [a.max_polygon_vertices]Point = undefined,
            count: u32,
            reserved: u32 = 0,
        };
        pub const Bounds = extern struct { rect: Rect = .{}, visible: u32 = 0, reserved: u32 = 0 };

        fn transform(mapping: *const Mapping) a.Affine {
            return .{ .xx = mapping.forward[0], .yx = mapping.forward[1], .xy = mapping.forward[2], .yy = mapping.forward[3], .x0 = mapping.forward[4], .y0 = mapping.forward[5] };
        }
        fn rect(value: Rect) a.Rect {
            return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
        }
        /// The expensive convexity check is bounded by 132*132 edge tests.
        /// It never scales with catalog row count or selected-row count.
        fn validate(mapping: *const Mapping, polygon: *a.Polygon) !void {
            if (mapping.reserved != 0 or mapping.count > a.max_polygon_vertices) return error.InvalidGeometry;
            try rect(mapping.viewport).validate();
            try transform(mapping).validate();
            var candidate: a.Polygon = .{ .len = mapping.count };
            for (mapping.polygon[0..mapping.count], 0..) |point, index| {
                const value: a.Point = .{ .x = point.x, .y = point.y };
                try value.validate();
                for (mapping.polygon[0..index]) |prior| if (prior.x == point.x and prior.y == point.y) return error.InvalidGeometry;
                candidate.storage[index] = value;
            }
            var sign: i2 = 0;
            for (candidate.points(), 0..) |first, index| {
                const last = candidate.storage[(index + 1) % candidate.len];
                for (candidate.points()) |point| {
                    const left = (last.x - first.x) * (point.y - first.y);
                    const right = (last.y - first.y) * (point.x - first.x);
                    const cross = left - right;
                    const error_bound = 8 * std.math.floatEps(f64) * (@abs(left) + @abs(right));
                    if (@abs(cross) <= error_bound) continue;
                    const current: i2 = if (cross > 0) 1 else -1;
                    if (sign != 0 and sign != current) return error.InvalidGeometry;
                    sign = current;
                }
            }
            polygon.* = candidate;
        }

        /// Called during the explicit frame stage. This captures the complete
        /// viewport clip once; providers do not rebuild a Frame or clip chain.
        pub fn prepare(geometry: anytype, reference: a.Ref, viewport: a.Rect) !Mapping {
            const space = try geometry.getSpace(reference.space);
            var visible: a.Polygon = .{};
            try geometry.visiblePolygon(reference, viewport, &visible);
            var local: a.Polygon = .{ .len = visible.len };
            for (visible.points(), 0..) |point, index| local.storage[index] = try space.localPoint(point);
            var clipped: a.Polygon = .{};
            try local.clipBounds(viewport, &clipped);
            const forward = space.to_window;
            var result: Mapping = .{
                .forward = .{ forward.xx, forward.yx, forward.xy, forward.yy, forward.x0, forward.y0 },
                .viewport = .{ .x = viewport.x, .y = viewport.y, .width = viewport.width, .height = viewport.height },
                .count = @intCast(clipped.len),
            };
            for (clipped.points(), 0..) |point, index| result.polygon[index] = .{ .x = point.x, .y = point.y };
            var checked: a.Polygon = .{};
            try validate(&result, &checked);
            return result;
        }

        /// Rows share the captured viewport's X/width, so they replace its
        /// horizontal strip planes and do not add another arbitrary polygon.
        /// Cropping to the viewport first handles distant offscreen rows before
        /// entering the bounded local-coordinate arithmetic domain.
        pub fn bounds(mapping: *const Mapping, top: f64, height: f64, origin: Point, scale: f64, output: *Bounds) !void {
            if (!std.math.isFinite(top) or !std.math.isFinite(height) or height < 0 or !std.math.isFinite(top + height) or
                !std.math.isFinite(origin.x) or !std.math.isFinite(origin.y) or !std.math.isFinite(scale) or scale <= 0) return error.InvalidGeometry;
            var polygon: a.Polygon = .{};
            try validate(mapping, &polygon);
            const viewport = rect(mapping.viewport);
            const first = @max(viewport.y, top);
            const last = @min(viewport.y + viewport.height, top + height);
            if (last <= first or viewport.width == 0 or polygon.len < 3) {
                output.* = .{};
                return;
            }
            const local: a.Rect = .{ .x = viewport.x, .y = first, .width = viewport.width, .height = last - first };
            var clipped: a.Polygon = .{};
            try polygon.clipBounds(local, &clipped);
            if (clipped.bounds() == null) {
                output.* = .{};
                return;
            }
            const space = try a.Space.init(transform(mapping));
            var window_polygon: a.Polygon = .{ .len = clipped.len };
            for (clipped.points(), 0..) |point, index| window_polygon.storage[index] = try space.windowPoint(point);
            const window_bounds = window_polygon.bounds() orelse {
                output.* = .{};
                return;
            };
            const result: Bounds = .{ .rect = .{
                .x = window_bounds.x * scale + origin.x,
                .y = window_bounds.y * scale + origin.y,
                .width = window_bounds.width * scale,
                .height = window_bounds.height * scale,
            }, .visible = 1 };
            inline for (zio.fields(Rect)) |field| if (!std.math.isFinite(@field(result.rect, field.name))) return error.GeometryOverflow;
            if (!std.math.isFinite(result.rect.x + result.rect.width) or !std.math.isFinite(result.rect.y + result.rect.height)) return error.GeometryOverflow;
            output.* = if (result.rect.width > 0 and result.rect.height > 0) result else .{};
        }

        /// Private C entry point; a stable wrapper exports it from the native
        /// adapter. Error leaves caller output bytes unchanged, including flags.
        pub fn nativeBounds(mapping: ?*const Mapping, top: f64, height: f64, origin_x: f64, origin_y: f64, scale: f64, output: ?*Bounds) callconv(.c) c_int {
            const target = output orelse return 1;
            const input = mapping orelse return 1;
            Self.bounds(input, top, height, .{ .x = origin_x, .y = origin_y }, scale, target) catch return 1;
            return 0;
        }
    };
}
