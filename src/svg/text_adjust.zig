const std = @import("std");
const v = @import("ziggurat_vector");
const text = @import("text.zig");
const positioning = @import("text_position.zig");

/// Private, allocation-free horizontal placement shared by the ordinary batch
/// and an unposed paint Mapping. Measure/anchor once, then transform the sole
/// candidate before producing fill parts. This is not a cluster pose product.
pub const Horizontal = struct {
    advance: f64,
    stretch: f64,
    offset: v.Point = .{ .x = 0, .y = 0 },

    pub fn measure(natural: f64, desired: ?f64) !Horizontal {
        const advance = desired orelse natural;
        const stretch = if (desired != null) blk: {
            if (natural == 0) {
                if (advance != 0) return error.UnsupportedTextLengthZeroAdvance;
                break :blk 1;
            }
            const ratio = advance / natural;
            if (!std.math.isFinite(ratio) or (ratio == 0 and advance != 0)) return error.UnsupportedTextLengthPrecision;
            break :blk ratio;
        } else 1;
        return .{ .advance = advance, .stretch = stretch };
    }
    pub fn anchored(self: Horizontal, direction: text.Direction, anchor: text.Anchor, cursor: v.Point, baseline: f64) Horizontal {
        var result = self;
        result.offset = .{ .x = cursor.x - switch (anchor) {
            .middle => self.advance / 2,
            .start => if (direction == .rtl) self.advance else 0,
            .end => if (direction == .ltr) self.advance else 0,
        }, .y = cursor.y - baseline };
        return result;
    }
    /// Nonidentity x scaling cannot be represented by updating only an arc's
    /// endpoint. Prove this before changing the candidate's commands.
    pub fn checkOutline(self: Horizontal, cache: anytype, commands: []const v.Command) !void {
        if (self.stretch != 1) {
            try cache.charge(commands.len);
            for (commands) |command| if (command == .arc) return error.UnsupportedTextLengthOutline;
        }
    }
    pub fn apply(self: Horizontal, cache: anytype, commands: []v.Command) !void {
        try cache.charge(commands.len);
        for (commands) |*command| switch (command.*) {
            .move, .line => |*p| try self.point(p),
            .quadratic => |*curve| {
                try self.point(&curve.control);
                try self.point(&curve.end);
            },
            .cubic => |*curve| {
                try self.point(&curve.first);
                try self.point(&curve.second);
                try self.point(&curve.end);
            },
            .arc => |*arc| try self.point(&arc.end),
            .close => {},
        };
    }
    pub fn cell(self: Horizontal, value: *v.Bounds) void {
        value.x = value.x * self.stretch + self.offset.x;
        value.y += self.offset.y;
        value.width *= self.stretch;
    }
    fn point(self: Horizontal, value: *v.Point) !void {
        value.x = value.x * self.stretch + self.offset.x;
        value.y += self.offset.y;
        try v.validPoint(value.*);
    }
};

pub const Quad = [4]v.Point;
const Pose = struct { pivot: v.Point, shift: v.Point, rotation: f64, advance: f64 };
/// Private preparation product, constructed by position only after apply has
/// proved source coverage, metadata ranges/parity and every placed coordinate.
/// The caller owns mapping/quads until a paint Product successfully adopts it.
pub const Positioned = struct { mapping: *text.Mapping, quads: []Quad, source: []const u8 };

pub fn position(cache: anytype, allocator: std.mem.Allocator, mapping: *text.Mapping, plan: *const positioning.Plan, font: text.Font, anchor: text.Anchor, cursor: v.Point, baseline: f64) !Positioned {
    const view = try mapping.view();
    const quads = try apply(cache, allocator, view, plan, font, anchor, cursor, baseline);
    return .{ .mapping = mapping, .quads = quads, .source = view.source };
}

/// Mutates only the owning mapped candidate, never the original batch path.
/// Returns exact full-cell corners; taking an AABB before an outer affine
/// transform would lose the original rotated/skewed cell geometry.
pub fn apply(cache: anytype, allocator: std.mem.Allocator, view: text.mapping.View, plan: *const positioning.Plan, font: text.Font, anchor: text.Anchor, cursor: v.Point, baseline: f64) ![]Quad {
    if (!std.mem.eql(u8, view.source, plan.source.items) or view.glyphs.len == 0 or view.clusters.len == 0) return error.UnsupportedTextPositionCluster;
    if (view.clusters.len > plan.character_count or plan.characters.items.len != plan.character_count) return error.InvalidTextProviderMapping;
    const poses = try allocator.alloc(Pose, view.clusters.len);
    defer allocator.free(poses);
    const order = try allocator.alloc(usize, view.clusters.len);
    defer allocator.free(order);
    try cache.charge(@as(u64, view.glyphs.len) * 8 + view.path.commands.len * 3 + view.source.len + @as(u64, view.clusters.len) * (std.math.log2_int_ceil(usize, @max(@as(usize, 1), view.clusters.len)) * 2 + 8));
    var command_at: usize = 0;
    for (view.glyphs) |glyph| {
        if (glyph.cluster >= view.clusters.len or glyph.commands.start != command_at or glyph.commands.count > view.path.commands.len -| command_at) return error.InvalidTextProviderMapping;
        command_at += glyph.commands.count;
        try v.validPoint(glyph.pen);
        if (!std.math.isFinite(glyph.advance)) return error.InvalidTextProviderMapping;
        try validCell(glyph.cell);
    }
    if (command_at != view.path.commands.len) return error.InvalidTextProviderMapping;
    var glyph_at: usize = 0;
    command_at = 0;
    for (view.clusters, order, 0..) |cluster, *index, ci| {
        index.* = ci;
        // UTF-8 boundaries are proved against the normalized scalar records
        // during the ordered walk. Do not repeatedly decode overlapping,
        // potentially invalid provider ranges before checking their order.
        if (cluster.source.start >= cluster.source.end or cluster.source.end > view.source.len) return error.InvalidTextProviderMapping;
        if (cluster.glyphs.count == 0) return error.UnsupportedTextPositionCluster;
        if (plan.route != null and cluster.glyphs.count != 1) return error.UnsupportedTextPathCluster;
        if ((cluster.bidi_level & 1) != @intFromBool(font.direction == .rtl)) return error.UnsupportedTextPositionBidi;
        if (cluster.glyphs.start != glyph_at or cluster.glyphs.count > view.glyphs.len -| glyph_at or cluster.commands.start != command_at or cluster.commands.count > view.path.commands.len -| command_at) return error.InvalidTextProviderMapping;
        const first = view.glyphs[glyph_at];
        var left: f64 = std.math.inf(f64);
        var right: f64 = -std.math.inf(f64);
        for (view.glyphs[glyph_at..][0..cluster.glyphs.count]) |glyph| {
            if (glyph.cluster != ci) return error.InvalidTextProviderMapping;
            if (glyph.pen.y != first.pen.y) return error.UnsupportedTextPositionCluster;
            left = @min(left, @min(glyph.pen.x, glyph.pen.x + glyph.advance));
            right = @max(right, @max(glyph.pen.x, glyph.pen.x + glyph.advance));
            if (glyph.commands.start != command_at) return error.InvalidTextProviderMapping;
            command_at += glyph.commands.count;
        }
        if (command_at != cluster.commands.start + cluster.commands.count) return error.InvalidTextProviderMapping;
        glyph_at += cluster.glyphs.count;
        poses[ci] = .{ .pivot = .{ .x = if (font.direction == .rtl) right else left, .y = first.pen.y }, .shift = .{ .x = 0, .y = 0 }, .rotation = 0, .advance = (right - left) * @as(f64, if (font.direction == .rtl) -1 else 1) };
    }
    if (glyph_at != view.glyphs.len or command_at != view.path.commands.len) return error.InvalidTextProviderMapping;
    std.sort.heap(usize, order, view.clusters, struct {
        fn less(clusters: []const text.mapping.Cluster, a: usize, b: usize) bool {
            return clusters[a].source.start < clusters[b].source.start;
        }
    }.less);
    var source_at: usize = 0;
    var character_at: usize = 0;
    var cumulative: v.Point = .{ .x = 0, .y = 0 };
    var minimum: f64 = std.math.inf(f64);
    var maximum: f64 = -std.math.inf(f64);
    for (order) |index| {
        const cluster = view.clusters[index];
        if (cluster.source.start != source_at or character_at >= plan.characters.items.len or plan.characters.items[character_at].start != source_at) return error.InvalidTextProviderMapping;
        const first = plan.characters.items[character_at];
        cumulative.x += first.dx;
        cumulative.y += first.dy;
        try v.validPoint(cumulative);
        poses[index].shift = cumulative;
        poses[index].rotation = first.rotate;
        const x = poses[index].pivot.x + cumulative.x;
        minimum = @min(minimum, @min(x, x + poses[index].advance));
        maximum = @max(maximum, @max(x, x + poses[index].advance));
        while (character_at < plan.characters.items.len and plan.characters.items[character_at].start < cluster.source.end) : (character_at += 1) {
            const current = plan.characters.items[character_at];
            if (current.end > cluster.source.end) return error.InvalidTextProviderMapping;
            // Middle scalar shifts carry to the next typographic unit; its
            // rotation is the first scalar's value. A final list value still
            // repeats through subsequent addressable characters in Plan.
            if (current.start != first.start) {
                cumulative.x += current.dx;
                cumulative.y += current.dy;
                try v.validPoint(cumulative);
            }
        }
        source_at = cluster.source.end;
    }
    if (source_at != view.source.len or character_at != plan.characters.items.len) return error.InvalidTextProviderMapping;
    if (plan.spacing_length) {
        const desired = plan.text_length orelse return error.InvalidTextProviderMapping;
        if (order.len == 1) {
            // Spacing has no adjustable gap inside an indivisible unit.
            if (desired != maximum - minimum) return error.UnsupportedTextLengthSingleCluster;
        } else {
            try cache.charge(@as(u64, order.len) * 4);
            const delta = (desired - (maximum - minimum)) * @as(f64, if (font.direction == .rtl) -1 else 1);
            const step = delta / @as(f64, @floatFromInt(order.len - 1));
            if (!std.math.isFinite(step)) return error.UnsupportedTextLengthPrecision;
            minimum = std.math.inf(f64);
            maximum = -std.math.inf(f64);
            for (order, 0..) |index, rank| {
                // Keep the last displacement equal to delta rather than a
                // sum of rounded steps. Glyph shapes and advances stay rigid.
                poses[index].shift.x += if (rank + 1 == order.len) delta else step * @as(f64, @floatFromInt(rank));
                try v.validPoint(poses[index].shift);
                const x = poses[index].pivot.x + poses[index].shift.x;
                minimum = @min(minimum, @min(x, x + poses[index].advance));
                maximum = @max(maximum, @max(x, x + poses[index].advance));
            }
        }
    }
    const reference = switch (anchor) {
        .middle => (minimum + maximum) / 2,
        .start => if (font.direction == .rtl) maximum else minimum,
        .end => if (font.direction == .rtl) minimum else maximum,
    };
    const offset: v.Point = .{ .x = cursor.x - reference, .y = cursor.y - baseline };
    try v.validPoint(offset);
    const quads = try allocator.alloc(Quad, view.glyphs.len);
    errdefer allocator.free(quads);
    for (view.clusters, poses) |cluster, pose| {
        try cache.work.check();
        const radians = pose.rotation * std.math.pi / 180;
        const cosine = @cos(radians);
        const sine = @sin(radians);
        const transform: v.Transform = if (plan.route) |route| try route.pose(cache, pose.pivot.x + pose.advance / 2 + offset.x + route.offset, pose.advance, pose.pivot.x + pose.advance / 2, baseline) else .{ .xx = cosine, .yx = sine, .xy = -sine, .yy = cosine, .x0 = pose.pivot.x + pose.shift.x + offset.x - cosine * pose.pivot.x + sine * pose.pivot.y, .y0 = pose.pivot.y + pose.shift.y + offset.y - sine * pose.pivot.x - cosine * pose.pivot.y };
        try transform.validate();
        for (view.path.commands[cluster.commands.start..][0..cluster.commands.count]) |*command| switch (command.*) {
            .move, .line => |*point| try map(point, transform),
            .quadratic => |*q| {
                try map(&q.control, transform);
                try map(&q.end, transform);
            },
            .cubic => |*c| {
                try map(&c.first, transform);
                try map(&c.second, transform);
                try map(&c.end, transform);
            },
            .arc => return error.UnsupportedTextPositionOutline,
            .close => {},
        };
        for (cluster.glyphs.start..cluster.glyphs.start + cluster.glyphs.count) |gi| {
            const cell = view.glyphs[gi].cell;
            quads[gi] = .{ .{ .x = cell.x, .y = cell.y }, .{ .x = cell.x + cell.width, .y = cell.y }, .{ .x = cell.x, .y = cell.y + cell.height }, .{ .x = cell.x + cell.width, .y = cell.y + cell.height } };
            for (&quads[gi]) |*point| try map(point, transform);
        }
    }
    return quads;
}
fn map(point: *v.Point, transform: v.Transform) !void {
    point.* = transform.apply(point.*);
    try v.validPoint(point.*);
}
fn validCell(cell: v.Bounds) !void {
    if (!std.math.isFinite(cell.width) or !std.math.isFinite(cell.height) or cell.width < 0 or cell.height < 0) return error.InvalidTextProviderMapping;
    try v.validPoint(.{ .x = cell.x, .y = cell.y });
    try v.validPoint(.{ .x = cell.x + cell.width, .y = cell.y + cell.height });
}
