const std = @import("std");
const v = @import("ziggurat_vector");
const n = @import("numbers.zig");
const refs = @import("references.zig");
const pre = @import("prepare.zig");

const Segment = struct { start: v.Point, end: v.Point, tangent: v.Point, distance: f64, length: f64 };
pub const Sample = struct { point: v.Point, tangent: v.Point };

/// Preparation-only exact open-polyline metric in the text's user space.
/// The referenced path's own transform applies here; its ancestors do not.
pub const Route = struct {
    allocator: std.mem.Allocator,
    segments: []Segment,
    length: f64,
    offset: f64,

    pub fn create(cache: anytype, allocator: std.mem.Allocator, index: usize) !*Route {
        const work = cache.work;
        const node = work.document.nodes[index];
        const id = try refs.href(work.document.nodes, index);
        try cache.charge(id.len * (1 + std.math.log2_int_ceil(usize, @max(@as(usize, 1), work.document.nodes.len))));
        const target = work.references.?.find(id) orelse return error.MissingReference;
        if (!std.mem.eql(u8, try pre.localName(work.document.nodes, target), "path")) return error.UnsupportedTextPathTarget;
        const path_node = work.document.nodes[target];
        const source = path_node.attribute("d") orelse "";
        const transform_source = path_node.attribute("transform") orelse "";
        try cache.charge(source.len + transform_source.len);
        const transform = try n.transform(transform_source);
        const path = try v.Path.parseData(allocator, source, .{ .limits = work.options.limits.path, .cancellation = work.options.cancellation });
        defer path.close() catch unreachable;
        // Reject unsupported geometry before allocating a metric or asking the
        // font provider. Both passes and every lookup consume the text work.
        try cache.charge(@as(u64, path.commands.len) * 2);
        var count: usize = 0;
        var length: f64 = 0;
        var pen: ?v.Point = null;
        for (path.commands, 0..) |command, at| {
            try work.check();
            switch (command) {
                .move => |point| {
                    if (at != 0) return error.UnsupportedTextPathSubpaths;
                    pen = transform.apply(point);
                    try v.validPoint(pen.?);
                },
                .line => |point| {
                    const end = transform.apply(point);
                    try v.validPoint(end);
                    const start = pen orelse return error.UnsupportedTextPathGeometry;
                    const size = std.math.hypot(end.x - start.x, end.y - start.y);
                    if (size != 0) {
                        const next = length + size;
                        if (!std.math.isFinite(next) or next <= length) return error.UnsupportedTextPathPrecision;
                        length = next;
                        count += 1;
                    }
                    pen = end;
                },
                else => return error.UnsupportedTextPathGeometry,
            }
        }
        if (count == 0) return error.UnsupportedTextPathGeometry;
        const offset_source = node.attribute("startOffset") orelse "0";
        try cache.charge(offset_source.len);
        const offset = try (try n.length(offset_source)).resolve(length);
        const segments = try allocator.alloc(Segment, count);
        errdefer allocator.free(segments);
        var distance: f64 = 0;
        count = 0;
        for (path.commands) |command| switch (command) {
            .move => |point| pen = transform.apply(point),
            .line => |point| {
                const end = transform.apply(point);
                const start = pen.?;
                const size = std.math.hypot(end.x - start.x, end.y - start.y);
                if (size != 0) {
                    segments[count] = .{ .start = start, .end = end, .tangent = .{ .x = (end.x - start.x) / size, .y = (end.y - start.y) / size }, .distance = distance, .length = size };
                    count += 1;
                    distance += size;
                }
                pen = end;
            },
            else => unreachable,
        };
        try work.check();
        const self = try allocator.create(Route);
        self.* = .{ .allocator = allocator, .segments = segments, .length = length, .offset = offset };
        return self;
    }
    pub fn close(self: *Route) void {
        const allocator = self.allocator;
        allocator.free(self.segments);
        allocator.destroy(self);
    }
    /// Endpoints extend along the first/last tangent. The caller separately
    /// proves that the glyph midpoint lies on the finite route.
    pub fn sample(self: *const Route, cache: anytype, distance: f64) !Sample {
        try cache.charge(1 + std.math.log2_int_ceil(usize, self.segments.len));
        if (!std.math.isFinite(distance)) return error.UnsupportedTextPathPrecision;
        var left: usize = 0;
        var right = self.segments.len;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const segment = self.segments[middle];
            if (distance > segment.distance + segment.length) left = middle + 1 else right = middle;
        }
        const segment = self.segments[@min(left, self.segments.len - 1)];
        const delta = distance - segment.distance;
        const point: v.Point = if (delta == segment.length) segment.end else .{ .x = segment.start.x + delta * segment.tangent.x, .y = segment.start.y + delta * segment.tangent.y };
        try v.validPoint(point);
        return .{ .point = point, .tangent = segment.tangent };
    }
    pub fn pose(self: *const Route, cache: anytype, midpoint: f64, advance: f64, raw_midpoint: f64, baseline: f64) !v.Transform {
        if (midpoint < 0 or midpoint > self.length) return error.UnsupportedTextPathOverflow;
        if (advance == 0) return error.UnsupportedTextPathZeroAdvance;
        const mid = try self.sample(cache, midpoint);
        const first = (try self.sample(cache, midpoint - @abs(advance) / 2)).point;
        const last = (try self.sample(cache, midpoint + @abs(advance) / 2)).point;
        const dx = last.x - first.x;
        const dy = last.y - first.y;
        const chord = std.math.hypot(dx, dy);
        if (chord == 0) return error.UnsupportedTextPathOrientation;
        const cosine = dx / chord;
        const sine = dy / chord;
        const transform: v.Transform = .{ .xx = cosine, .yx = sine, .xy = -sine, .yy = cosine, .x0 = mid.point.x - cosine * raw_midpoint + sine * baseline, .y0 = mid.point.y - sine * raw_midpoint - cosine * baseline };
        try transform.validate();
        return transform;
    }
};
