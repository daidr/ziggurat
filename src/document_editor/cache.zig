const std = @import("std");
const t = @import("ziggurat_text_layout");
const index = @import("index.zig");
const memory = @import("memory.zig");
const hit = @import("ziggurat_prepared_hit");
pub const max_rows = 32;
const layout_reservation = 4 * 1024 * 1024;
pub const Descriptor = struct { id: u64, epoch: u64, bytes: usize, terminated: bool };
pub const Stop = struct { caret: t.Caret, rect: t.Rect, line: usize };
/// Text shown at byte `at` of a batch that is not the Document's, as an inlay
/// hint. A caret at `at` shows after it unless it is `ghost` (a suggestion or
/// trailing text), and a range starting at `at` starts after it; a range
/// ending at `at` never covers it.
pub const Inlay = struct { at: usize, text: []const u8, ghost: bool };
/// An inlay in the shaped text: at source byte `at`, its text at shaped
/// bytes `display..display + len`.
pub const Insert = struct { at: usize, display: usize, len: usize, ghost: bool };
/// The extra state of a batch shaped with inlays: its source bytes, its
/// grapheme boundaries, lines and advance spans in source bytes.
const Mapped = struct {
    inserts: []Insert,
    source: []u8,
    graphemes: []usize,
    lines: []t.Line,
    spans: []t.AdvanceSpan,
    fn free(self: *Mapped, allocator: std.mem.Allocator) void {
        allocator.free(self.inserts);
        allocator.free(self.source);
        allocator.free(self.graphemes);
        allocator.free(self.lines);
        allocator.free(self.spans);
    }
};
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
    mapped: ?*Mapped = null,
    /// The batch's text in source bytes, whether or not it was shaped with
    /// inlays: every query but painting goes through it.
    pub fn text(self: *const Entry) Text {
        return .{ .entry = self };
    }
    pub fn inserts(self: *const Entry) []const Insert {
        return if (self.mapped) |value| value.inserts else &.{};
    }
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
        if (self.mapped) |value| {
            value.free(allocator);
            allocator.destroy(value);
        }
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
/// The queries of a batch's Layout in the Document's bytes: with inlays
/// shaped into it, offsets map past their text, which no query returns.
pub const Text = struct {
    entry: *const Entry,
    fn layout(self: Text) *const t.Layout {
        return self.entry.layout;
    }
    /// The shaped byte of source byte `at`: after the inlays there that are
    /// not ghosts when `after`, else before them all.
    pub fn toDisplay(self: Text, at: usize, after: bool) usize {
        const mapped = self.entry.mapped orelse return at;
        return displayOf(mapped.inserts, at, after);
    }
    /// The source byte of shaped byte `at`: an inlay's own bytes and both of
    /// its edges are the source byte it is at.
    pub fn toSource(self: Text, at: usize) usize {
        const mapped = self.entry.mapped orelse return at;
        return sourceOf(mapped.inserts, at);
    }
    pub fn text(self: Text) ![]const u8 {
        if (self.entry.mapped) |value| return value.source;
        return self.layout().text();
    }
    pub fn metrics(self: Text) !t.Metrics {
        return self.layout().metrics();
    }
    pub fn lines(self: Text) ![]const t.Line {
        if (self.entry.mapped) |value| return value.lines;
        return self.layout().lines();
    }
    pub fn advanceSpans(self: Text) ![]const t.AdvanceSpan {
        if (self.entry.mapped) |value| return value.spans;
        return self.layout().advanceSpans();
    }
    pub fn graphemeCount(self: Text) !usize {
        if (self.entry.mapped) |value| return value.graphemes.len - 1;
        return self.layout().graphemeCount();
    }
    pub fn graphemeByte(self: Text, at: usize) !usize {
        if (self.entry.mapped) |value| {
            if (at >= value.graphemes.len) return error.InvalidGrapheme;
            return value.graphemes[at];
        }
        return self.layout().graphemeByte(at);
    }
    pub fn caret(self: Text, position: t.Caret) !t.Rect {
        return self.layout().caret(.{ .byte_offset = self.toDisplay(position.byte_offset, true), .affinity = position.affinity });
    }
    pub fn wordRangeAt(self: Text, position: t.Caret) !t.ByteRange {
        const range = try self.layout().wordRangeAt(.{ .byte_offset = self.toDisplay(position.byte_offset, true), .affinity = position.affinity });
        return .{ .start = self.toSource(range.start), .end = self.toSource(range.end) };
    }
    fn shown(self: Text, range: t.ByteRange) t.ByteRange {
        const start = self.toDisplay(range.start, true);
        return .{ .start = start, .end = @max(start, self.toDisplay(range.end, false)) };
    }
    pub fn selectionRectCount(self: Text, range: t.ByteRange) !usize {
        return self.layout().selectionRectCount(self.shown(range));
    }
    pub fn selectionRects(self: Text, range: t.ByteRange, output: []t.Rect) ![]const t.Rect {
        return self.layout().selectionRects(self.shown(range), output);
    }
};
fn displayOf(list: []const Insert, at: usize, after: bool) usize {
    var shift: usize = 0;
    for (list) |item| {
        if (item.at > at or (item.at == at and (!after or item.ghost))) break;
        shift += item.len;
    }
    return at + shift;
}
fn sourceOf(list: []const Insert, at: usize) usize {
    var shift: usize = 0;
    for (list) |item| {
        if (at < item.display) break;
        if (at <= item.display + item.len) return item.at;
        shift += item.len;
    }
    return at - shift;
}
fn insideInlay(list: []const Insert, at: usize) bool {
    for (list) |item| if (at > item.display and at < item.display + item.len) return true;
    return false;
}
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
pub fn create(budget: *memory.Budget, engine: *t.Engine, bytes: []const u8, rows: []const index.Row, font: t.Options, generation: u64, stop_limit: usize, inlays: []const Inlay) !*Entry {
    const allocator = budget.allocator();
    // With inlays, their text goes into the shaped text at their bytes.
    var mapped: ?*Mapped = null;
    errdefer if (mapped) |value| {
        value.free(allocator);
        allocator.destroy(value);
    };
    var shaped: []const u8 = bytes;
    var shaped_storage: []u8 = &.{};
    defer allocator.free(shaped_storage);
    if (inlays.len > 0) {
        var total = bytes.len;
        for (inlays) |item| total += item.text.len;
        shaped_storage = try allocator.alloc(u8, total);
        const list = try allocator.alloc(Insert, inlays.len);
        errdefer allocator.free(list);
        var from: usize = 0;
        var out: usize = 0;
        for (inlays, list) |item, *insert| {
            std.debug.assert(item.at >= from and item.at <= bytes.len);
            @memcpy(shaped_storage[out..][0 .. item.at - from], bytes[from..item.at]);
            out += item.at - from;
            from = item.at;
            insert.* = .{ .at = item.at, .display = out, .len = item.text.len, .ghost = item.ghost };
            @memcpy(shaped_storage[out..][0..item.text.len], item.text);
            out += item.text.len;
        }
        @memcpy(shaped_storage[out..], bytes[from..]);
        shaped = shaped_storage;
        const source = try allocator.dupe(u8, bytes);
        errdefer allocator.free(source);
        const value = try allocator.create(Mapped);
        value.* = .{ .inserts = list, .source = source, .graphemes = &.{}, .lines = &.{}, .spans = &.{} };
        mapped = value;
    }
    try budget.reserve(layout_reservation);
    var external: usize = layout_reservation;
    errdefer budget.release(external);
    const layout = try engine.layout(shaped, font);
    errdefer layout.close() catch unreachable;
    const stats = try layout.buildStats();
    std.debug.assert(stats.owned_bytes <= layout_reservation);
    budget.release(external - stats.owned_bytes);
    external = stats.owned_bytes;
    if (mapped) |value| try mapSource(allocator, value, layout);
    const list: []const Insert = if (mapped) |value| value.inserts else &.{};
    // A stop in or at an inlay's text is the source byte it is at, so a hit
    // anywhere on it lands there.
    const count = (try layout.graphemeCount() + 1) * 2;
    if (count > stop_limit) return error.VisualCapacityExceeded;
    const stops = try allocator.alloc(Stop, count);
    errdefer allocator.free(stops);
    const lines = try layout.lines();
    var stop_at: usize = 0;
    for (0..try layout.graphemeCount() + 1) |at| {
        const position = try layout.graphemeByte(at);
        for ([_]t.Affinity{ .upstream, .downstream }) |affinity| {
            const rect = try layout.caret(.{ .byte_offset = position, .affinity = affinity });
            stops[stop_at] = .{ .caret = .{ .byte_offset = sourceOf(list, position), .affinity = affinity }, .rect = rect, .line = lineAt(lines, rect.y + rect.height * 0.5) };
            stop_at += 1;
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
    result.* = .{ .budget = budget, .layout = layout, .row_count = rows.len, .stops = stops, .first_upstream = first_upstream, .external = external, .generation = generation, .mapped = mapped };
    mapped = null;
    errdefer {
        mapped = result.mapped;
        result.mapped = null;
    }
    const source = result.text();
    var position: usize = 0;
    for (rows, 0..) |row, at| {
        result.rows[at] = .{ .id = row.id, .epoch = row.epoch, .bytes = row.bytes, .terminated = row.terminated };
        // A paragraph's top is its first byte's, before any inlay there.
        result.tops[at] = (try layout.caret(.{ .byte_offset = source.toDisplay(try snap(source, position, false), false), .affinity = .downstream })).y;
        position += row.bytes;
    }
    const metrics = try layout.metrics();
    for (rows, 0..) |row, at| {
        const bottom: f64 = if (at + 1 < rows.len) result.tops[at + 1] else if (row.terminated) (try layout.caret(.{ .byte_offset = shaped.len, .affinity = .downstream })).y else @as(f64, metrics.bounds.y) + metrics.bounds.height;
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
/// The source grapheme boundaries, lines and spans of a batch shaped with
/// inlays.
fn mapSource(allocator: std.mem.Allocator, mapped: *Mapped, layout: *const t.Layout) !void {
    const list = mapped.inserts;
    var graphemes: std.ArrayList(usize) = .empty;
    errdefer graphemes.deinit(allocator);
    for (0..try layout.graphemeCount() + 1) |at| {
        const byte = try layout.graphemeByte(at);
        if (insideInlay(list, byte)) continue;
        const source = sourceOf(list, byte);
        if (graphemes.items.len > 0 and graphemes.items[graphemes.items.len - 1] == source) continue;
        try graphemes.append(allocator, source);
    }
    const lines = try allocator.dupe(t.Line, try layout.lines());
    errdefer allocator.free(lines);
    for (lines) |*line| {
        line.start = @intCast(sourceOf(list, line.start));
        line.end = @intCast(sourceOf(list, line.end));
        line.next_start = @intCast(sourceOf(list, line.next_start));
    }
    var spans: std.ArrayList(t.AdvanceSpan) = .empty;
    errdefer spans.deinit(allocator);
    for (try layout.advanceSpans()) |span| {
        const start = sourceOf(list, span.start);
        const end = sourceOf(list, span.end);
        // An inlay's own text has no source bytes.
        if (end <= start) continue;
        var item = span;
        item.start = @intCast(start);
        item.end = @intCast(end);
        try spans.append(allocator, item);
    }
    const owned_graphemes = try graphemes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_graphemes);
    const owned_spans = try spans.toOwnedSlice(allocator);
    mapped.graphemes = owned_graphemes;
    mapped.lines = lines;
    mapped.spans = owned_spans;
}
pub fn snap(layout: Text, byte: usize, forwards: bool) !usize {
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
