const std = @import("std");
const v = @import("ziggurat_vector");
const text = @import("text.zig");
const paints = @import("paint.zig");
const styles = @import("style.zig");
const adjustment = @import("text_adjust.zig");

/// A resolved paint value. currentColor and its fallback are captured from
/// the actual inherited style, never from a neighboring character or glyph.
pub const Fill = struct {
    paint: paints.Paint,
    opacity: f64,
    pub fn from(style: styles.Style) Fill {
        return .{ .paint = resolved(style.fill, style.color), .opacity = style.fill_opacity };
    }
    pub fn solid(self: Fill) bool {
        return self.paint == .none or self.paint == .color;
    }
    pub fn same(a: Fill, b: Fill) bool {
        if (a.solid() and b.solid()) {
            const ca: paints.Color = if (a.paint == .color) a.paint.color else .{ .a = 0 };
            const cb: paints.Color = if (b.paint == .color) b.paint.color else .{ .a = 0 };
            const aa = @as(f64, @floatFromInt(ca.a)) / 255 * a.opacity;
            const ab = @as(f64, @floatFromInt(cb.a)) / 255 * b.opacity;
            if (aa == 0 and ab == 0) return true;
            return aa == ab and ca.r == cb.r and ca.g == cb.g and ca.b == cb.b;
        }
        return a.opacity == b.opacity and samePaint(a.paint, b.paint);
    }
};
pub const Run = struct { start: usize, end: usize, fill: Fill };
pub const Part = struct { path: *v.Path, start: usize, end: usize, fill: Fill };
const CommandRun = struct { start: usize, end: usize, fill: Fill };
const Cells = union(enum) { aligned: []v.Bounds, corners: [][4]v.Point };

pub fn resolved(paint: paints.Paint, color: paints.Color) paints.Paint {
    return switch (paint) {
        .current_color => .{ .color = color },
        .reference => |reference| .{ .reference = .{ .id = reference.id, .fallback = switch (reference.fallback) {
            .current_color => .{ .color = color },
            else => reference.fallback,
        } } },
        else => paint,
    };
}
pub fn samePaint(a: paints.Paint, b: paints.Paint) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none, .current_color => true,
        .color => |color| std.meta.eql(color, b.color),
        .reference => |reference| (reference.id.ptr == b.reference.id.ptr and reference.id.len == b.reference.id.len or std.mem.eql(u8, reference.id, b.reference.id)) and std.meta.eql(reference.fallback, b.reference.fallback),
    };
}

/// The aggregate mapping owns whole-text geometry. Parts replace only its
/// fill phase. A preparation backend consumes each instance synchronously;
/// no Part pointer survives the next update of this private cache entry.
pub const Product = struct {
    allocator: std.mem.Allocator,
    mapping: *text.Mapping,
    cells: Cells,
    parts: []Part = &.{},
    commands: usize,

    /// Takes mapping only on success. The input is an unpublished candidate;
    /// placement may have happened on failure, but ownership stays caller's.
    pub fn create(cache: anytype, allocator: std.mem.Allocator, mapping: *text.Mapping, plan: anytype, font: text.Font, placement: adjustment.Horizontal) !*Product {
        const view = try mapping.view();
        try validate(cache, view, plan.source.items, font);
        try placement.checkOutline(cache, view.path.commands);
        const self = try allocator.create(Product);
        errdefer allocator.destroy(self);
        const cells = try allocator.alloc(v.Bounds, view.glyphs.len);
        errdefer allocator.free(cells);
        for (view.glyphs, cells) |glyph, *cell| {
            cell.* = glyph.cell;
            placement.cell(cell);
            try validCell(cell.*);
        }
        try placement.apply(cache, view.path.commands);
        self.* = .{ .allocator = allocator, .mapping = mapping, .cells = .{ .aligned = cells }, .commands = view.path.commands.len };
        errdefer self.clearParts();
        try self.update(cache, plan);
        return self;
    }
    /// Takes both already-positioned mapping and exact cell corners only on
    /// success. Placement has finished before the fill partition is built;
    /// this constructor and all later recolors never transform coordinates.
    pub fn adoptPositioned(cache: anytype, allocator: std.mem.Allocator, placed: adjustment.Positioned, plan: anytype) !*Product {
        const mapping = placed.mapping;
        const view = try mapping.view();
        // The private Positioned contract proves metadata before this entry.
        // Do not allocate another order array or sort the same clusters again.
        if (view.source.ptr != placed.source.ptr or view.source.len != placed.source.len or placed.quads.len != view.glyphs.len) return error.InvalidTextProviderMapping;
        try cache.charge(view.glyphs.len);
        for (view.glyphs) |glyph| {
            if (glyph.commands.count != 0 and view.path.commands[glyph.commands.start] != .move) return error.InvalidTextProviderMapping;
        }
        const self = try allocator.create(Product);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .mapping = mapping, .cells = .{ .corners = placed.quads }, .commands = view.path.commands.len };
        errdefer self.clearParts();
        try self.update(cache, plan);
        return self;
    }
    pub fn alignedCells(self: *const Product) ?[]v.Bounds {
        return switch (self.cells) {
            .aligned => |cells| cells,
            .corners => null,
        };
    }
    pub fn cellQuads(self: *const Product) ?[][4]v.Point {
        return switch (self.cells) {
            .aligned => null,
            .corners => |quads| quads,
        };
    }
    pub fn path(self: *Product) !*v.Path {
        return (try self.mapping.view()).path;
    }
    pub fn close(self: *Product) void {
        const allocator = self.allocator;
        self.clearParts();
        switch (self.cells) {
            .aligned => |cells| allocator.free(cells),
            .corners => |quads| allocator.free(quads),
        }
        self.mapping.close() catch unreachable;
        allocator.destroy(self);
    }
    fn clearParts(self: *Product) void {
        const old = self.parts;
        self.parts = &.{};
        for (old) |part| part.path.close() catch unreachable;
        self.allocator.free(old);
    }
    pub fn update(self: *Product, cache: anytype, plan: anytype) !void {
        const view = try self.mapping.view();
        try cache.charge(view.source.len);
        if (!std.mem.eql(u8, view.source, plan.source.items)) return error.InvalidTextProviderMapping;
        const limit = cache.work.options.limits.text.paint_runs -| cache.paint_runs;
        var desired: std.ArrayList(CommandRun) = .empty;
        defer desired.deinit(self.allocator);
        try cache.charge(@as(u64, view.clusters.len) * (std.math.log2_int_ceil(usize, @max(@as(usize, 1), plan.paints.items.len)) + 3));
        for (view.clusters) |cluster| {
            try cache.work.check();
            const fill = try clusterFill(plan.paints.items, cluster.source);
            if (desired.items.len != 0 and Fill.same(desired.items[desired.items.len - 1].fill, fill)) {
                desired.items[desired.items.len - 1].end = cluster.commands.start + cluster.commands.count;
            } else {
                if (desired.items.len == limit) return error.TextPaintRunsFull;
                try desired.append(self.allocator, .{ .start = cluster.commands.start, .end = cluster.commands.start + cluster.commands.count, .fill = fill });
            }
        }
        // Paint-only updates with the same partition reuse every owning Path.
        // Scene builders copy brush values, so the previous instance cannot
        // observe the replacement colors after its synchronous fill phase.
        var reuse = desired.items.len == self.parts.len;
        if (reuse) for (desired.items, self.parts) |run, part| {
            if (run.start != part.start or run.end != part.end) {
                reuse = false;
                break;
            }
        };
        if (reuse) {
            try cache.work.check();
            for (self.parts, desired.items) |*part, run| part.fill = run.fill;
            return;
        }
        const candidate = try self.allocator.alloc(Part, desired.items.len);
        var count: usize = 0;
        var published = false;
        errdefer if (!published) {
            for (candidate[0..count]) |part| part.path.close() catch unreachable;
            self.allocator.free(candidate);
        };
        for (desired.items, candidate) |run, *part| {
            try cache.work.check();
            try cache.charge(run.end - run.start);
            part.* = .{ .path = try v.Path.create(self.allocator, view.path.commands[run.start..run.end], cache.work.options.limits.path), .start = run.start, .end = run.end, .fill = run.fill };
            count += 1;
        }
        try cache.work.check();
        const old = self.parts;
        self.parts = candidate;
        published = true;
        // Ownership changes before foreign frees. Cancellation after these
        // frees still rejects the entire prepare, never publishes an image.
        for (old) |part| part.path.close() catch unreachable;
        self.allocator.free(old);
        try cache.work.check();
    }
};

fn clusterFill(runs: []const Run, source: text.mapping.Source) !Fill {
    var low: usize = 0;
    var high = runs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (runs[mid].end <= source.start) low = mid + 1 else high = mid;
    }
    if (low == runs.len or runs[low].start > source.start) return error.InvalidTextProviderMapping;
    if (source.end > runs[low].end) return error.UnsupportedTextPaintCluster;
    return runs[low].fill;
}
fn validate(cache: anytype, view: text.mapping.View, source: []const u8, font: text.Font) !void {
    if (!std.mem.eql(u8, source, view.source) or view.glyphs.len == 0 or view.clusters.len == 0) return error.InvalidTextProviderMapping;
    try cache.charge(view.source.len + view.glyphs.len * 5 + view.path.commands.len + @as(u64, view.clusters.len) * (std.math.log2_int_ceil(usize, @max(@as(usize, 1), view.clusters.len)) * 2 + 5));
    var command_at: usize = 0;
    for (view.glyphs) |glyph| {
        if (glyph.cluster >= view.clusters.len or glyph.commands.start != command_at or glyph.commands.count > view.path.commands.len -| command_at) return error.InvalidTextProviderMapping;
        if (glyph.commands.count != 0 and view.path.commands[command_at] != .move) return error.InvalidTextProviderMapping;
        command_at += glyph.commands.count;
        try v.validPoint(glyph.pen);
        if (!std.math.isFinite(glyph.advance)) return error.InvalidTextProviderMapping;
        try validCell(glyph.cell);
    }
    if (command_at != view.path.commands.len) return error.InvalidTextProviderMapping;
    const order = try view.path.allocator.alloc(usize, view.clusters.len);
    defer view.path.allocator.free(order);
    var glyph_at: usize = 0;
    command_at = 0;
    for (view.clusters, order, 0..) |cluster, *index, ci| {
        try cache.work.check();
        index.* = ci;
        if (cluster.source.start >= cluster.source.end or cluster.source.end > source.len or !boundary(source, cluster.source.start) or !boundary(source, cluster.source.end)) return error.InvalidTextProviderMapping;
        if (cluster.glyphs.count == 0) return error.UnsupportedTextPaintCluster;
        if ((cluster.bidi_level & 1) != @intFromBool(font.direction == .rtl)) return error.UnsupportedTextPaintBidi;
        if (cluster.glyphs.start != glyph_at or cluster.glyphs.count > view.glyphs.len -| glyph_at or cluster.commands.start != command_at or cluster.commands.count > view.path.commands.len -| command_at) return error.InvalidTextProviderMapping;
        for (view.glyphs[glyph_at..][0..cluster.glyphs.count]) |glyph| {
            if (glyph.cluster != ci or glyph.commands.start != command_at) return error.InvalidTextProviderMapping;
            command_at += glyph.commands.count;
        }
        if (command_at != cluster.commands.start + cluster.commands.count) return error.InvalidTextProviderMapping;
        glyph_at += cluster.glyphs.count;
    }
    if (glyph_at != view.glyphs.len or command_at != view.path.commands.len) return error.InvalidTextProviderMapping;
    std.sort.heap(usize, order, view.clusters, struct {
        fn less(clusters: []const text.mapping.Cluster, a: usize, b: usize) bool {
            return clusters[a].source.start < clusters[b].source.start;
        }
    }.less);
    var source_at: usize = 0;
    for (order) |index| {
        if (view.clusters[index].source.start != source_at) return error.InvalidTextProviderMapping;
        source_at = view.clusters[index].source.end;
    }
    if (source_at != source.len) return error.InvalidTextProviderMapping;
}
fn boundary(source: []const u8, at: usize) bool {
    return at == 0 or at == source.len or source[at] & 0xc0 != 0x80;
}
fn validCell(cell: v.Bounds) !void {
    if (!std.math.isFinite(cell.width) or !std.math.isFinite(cell.height) or cell.width < 0 or cell.height < 0) return error.InvalidTextProviderCells;
    try v.validPoint(.{ .x = cell.x, .y = cell.y });
    try v.validPoint(.{ .x = cell.x + cell.width, .y = cell.y + cell.height });
}
