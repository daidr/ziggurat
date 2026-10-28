const std = @import("std");
const t = @import("ziggurat_text_layout");
const index = @import("index.zig");
const memory = @import("memory.zig");
const hit = @import("ziggurat_prepared_hit");
pub const max_rows = 32;
const layout_reservation = 4 * 1024 * 1024;
pub const Descriptor = struct { id: u64, epoch: u64, bytes: usize, terminated: bool };
pub const Stop = struct { caret: t.Caret, rect: t.Rect, line: usize };
pub const Entry = struct {
    budget: *memory.Budget,
    refs: usize = 1,
    layout: *t.Layout,
    rows: [max_rows]Descriptor = undefined,
    tops: [max_rows]f64 = undefined,
    heights: [max_rows]f64 = undefined,
    row_count: usize,
    stops: []Stop,
    first_upstream: usize,
    external: usize,
    generation: u64,
    pub fn retain(self: *Entry) *Entry {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Entry) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.layout.close() catch unreachable;
        self.budget.release(self.external);
        const allocator = self.budget.allocator();
        allocator.free(self.stops);
        allocator.destroy(self);
    }
    pub fn matches(self: *const Entry, storage: *index.Storage, root: *index.Node, row: usize, generation: u64) bool {
        if (generation != self.generation or self.row_count > root.sum.rows - row) return false;
        for (self.rows[0..self.row_count], 0..) |expected, offset| {
            const actual = index.get(storage, root, row + offset);
            if (actual.hidden or expected.id != actual.id or expected.epoch != actual.epoch or expected.bytes != actual.bytes or expected.terminated != actual.terminated) return false;
        }
        return true;
    }
};
pub const Prepared = struct {
    budget: *memory.Budget,
    refs: usize = 1,
    value: *t.Prepared,
    external: usize,
    viewport: t.drawing.Rect,
    scale: f32,
    pub fn retain(self: *Prepared) *Prepared {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Prepared) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.value.close() catch unreachable;
        self.budget.release(self.external);
        self.budget.allocator().destroy(self);
    }
};
pub fn create(budget: *memory.Budget, engine: *t.Engine, bytes: []const u8, rows: []const index.Row, font: t.Options, generation: u64, stop_limit: usize) !*Entry {
    const allocator = budget.allocator();
    try budget.reserve(layout_reservation);
    var external: usize = layout_reservation;
    errdefer budget.release(external);
    const layout = try engine.layout(bytes, font);
    errdefer layout.close() catch unreachable;
    const stats = try layout.buildStats();
    std.debug.assert(stats.owned_bytes <= layout_reservation);
    budget.release(external - stats.owned_bytes);
    external = stats.owned_bytes;
    const count = (try layout.graphemeCount() + 1) * 2;
    if (count > stop_limit) return error.VisualCapacityExceeded;
    const stops = try allocator.alloc(Stop, count);
    errdefer allocator.free(stops);
    const lines = try layout.lines();
    for (0..count / 2) |at| {
        const position = try layout.graphemeByte(at);
        for ([_]t.Affinity{ .upstream, .downstream }, 0..) |affinity, side| {
            const caret: t.Caret = .{ .byte_offset = position, .affinity = affinity };
            const rect = try layout.caret(caret);
            stops[at * 2 + side] = .{ .caret = caret, .rect = rect, .line = lineAt(lines, rect.y + rect.height * 0.5) };
        }
    }
    std.mem.sort(Stop, stops, {}, struct {
        fn less(_: void, a: Stop, b: Stop) bool {
            if (a.line != b.line) return a.line < b.line;
            if (a.rect.x != b.rect.x) return a.rect.x < b.rect.x;
            if (a.caret.byte_offset != b.caret.byte_offset) return a.caret.byte_offset < b.caret.byte_offset;
            return a.caret.affinity == .downstream and b.caret.affinity == .upstream;
        }
    }.less);
    const result = try allocator.create(Entry);
    errdefer allocator.destroy(result);
    var first_upstream: usize = 0;
    for (stops, 0..) |stop, at| if (stop.caret.byte_offset == 0 and stop.caret.affinity == .upstream) {
        first_upstream = at;
        break;
    };
    result.* = .{ .budget = budget, .layout = layout, .row_count = rows.len, .stops = stops, .first_upstream = first_upstream, .external = external, .generation = generation };
    var position: usize = 0;
    for (rows, 0..) |row, at| {
        result.rows[at] = .{ .id = row.id, .epoch = row.epoch, .bytes = row.bytes, .terminated = row.terminated };
        result.tops[at] = (try layout.caret(.{ .byte_offset = try snap(layout, position, false), .affinity = .downstream })).y;
        position += row.bytes;
    }
    const metrics = try layout.metrics();
    for (rows, 0..) |row, at| {
        const bottom: f64 = if (at + 1 < rows.len) result.tops[at + 1] else if (row.terminated) (try layout.caret(.{ .byte_offset = bytes.len, .affinity = .downstream })).y else @as(f64, metrics.bounds.y) + metrics.bounds.height;
        result.heights[at] = bottom - result.tops[at];
        if (!std.math.isFinite(result.heights[at]) or result.heights[at] <= 0) return error.InvalidParagraphMetrics;
    }
    return result;
}
pub fn prepare(budget: *memory.Budget, entry: *Entry, scale: f32, viewport: t.drawing.Rect, limits: t.PrepareLimits) !*Prepared {
    // The preparation byte limit covers temporary 32bpp raster and final A8;
    // reserve a separate bounded allowance for the opaque owning descriptor.
    const reservation = std.math.add(usize, limits.bytes, 4096) catch return error.CapacityExceeded;
    try budget.reserve(reservation);
    var external = reservation;
    errdefer budget.release(external);
    const value = try entry.layout.prepare(scale, .{ .limits = limits, .viewport = viewport });
    errdefer value.close() catch unreachable;
    const stats = try value.stats();
    std.debug.assert(stats.owned_bytes <= reservation);
    budget.release(external - stats.owned_bytes);
    external = stats.owned_bytes;
    const result = try budget.allocator().create(Prepared);
    result.* = .{ .budget = budget, .value = value, .external = external, .viewport = viewport, .scale = scale };
    return result;
}
pub fn snap(layout: *const t.Layout, byte: usize, forwards: bool) !usize {
    var low: usize = 0;
    var high = try layout.graphemeCount() + 1;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try layout.graphemeByte(middle) < byte) low = middle + 1 else high = middle;
    }
    if (try layout.graphemeByte(low) == byte or forwards) return layout.graphemeByte(low);
    return layout.graphemeByte(low -| 1);
}
pub fn lineAt(lines: []const t.Line, y: f32) usize {
    var low: usize = 0;
    var high = lines.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (y >= lines[middle].y + lines[middle].height) low = middle + 1 else high = middle;
    }
    return @min(low, lines.len - 1);
}
pub const LineStops = struct {
    items: []const Stop,
    omitted: ?usize,
    pub fn len(self: LineStops) usize {
        return self.items.len - @intFromBool(self.omitted != null);
    }
    pub fn raw(self: LineStops, index_value: usize) Stop {
        return virtualStop(self.items, self.omitted, index_value);
    }
    pub fn at(self: LineStops, index_value: usize) hit.Stop {
        const stop = self.raw(index_value);
        return .{ .x = stop.rect.x, .position = stop.caret.byte_offset, .affinity = @backingInt(stop.caret.affinity) };
    }
};
pub fn lineStops(entry: *const Entry, line: usize, has_previous: bool) LineStops {
    var low: usize = 0;
    var high = entry.stops.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (entry.stops[middle].line < line) low = middle + 1 else high = middle;
    }
    const first = low;
    high = entry.stops.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (entry.stops[middle].line <= line) low = middle + 1 else high = middle;
    }
    // A standalone layout invents an upstream edge at byte zero; globally
    // that edge belongs to the previous paragraph, outside this batch.
    const omitted: ?usize = if (has_previous and entry.first_upstream >= first and entry.first_upstream < low) entry.first_upstream - first else null;
    const stops = entry.stops[first..low];
    return .{ .items = stops, .omitted = omitted };
}
pub fn hitTest(entry: *const Entry, point: t.Point, has_previous: bool) !t.Caret {
    const stops = lineStops(entry, lineAt(try entry.layout.lines(), point.y), has_previous);
    return stops.raw(try hit.nearestStop(stops, point.x)).caret;
}
fn virtualStop(stops: []const Stop, omitted: ?usize, at: usize) Stop {
    return stops[at + @intFromBool(if (omitted) |value| at >= value else false)];
}
