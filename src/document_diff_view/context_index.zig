const std = @import("std");
const diff = @import("ziggurat_document_diff");
const aligned = @import("index.zig");
pub const Mode = enum { split, unified };
pub const Options = struct { context_lines: usize = 3, minimum_hidden: usize = 4, regions: usize = 4096, rows: usize = 2097152, bytes: usize = 1024 * 1024 };
/// Only unchanged records can be hidden. `first-1` is the retained real header;
/// ranges a/b describe hidden original source lines, never synthetic text.
pub const Region = struct { id: u64, first: usize, end: usize, a: diff.LineRange, b: diff.LineRange, collapsed: bool = true };
pub const Segment = struct { first: usize, raw: usize, count: usize };
/// Exclusive-owner derived metadata. Construction reads no document bytes or
/// native layout. IDs identify the same common segment within one comparison;
/// the coordinating owner additionally gates its pair identity and serial.
pub const Index = struct {
    allocator: std.mem.Allocator,
    regions: []Region,
    segments: []Segment,
    segment_count: usize = 0,
    raw_rows: usize,
    visible_rows: usize = 0,
    bytes: usize,
    options: Options,
    a: diff.Stamp,
    b: diff.Stamp,
    owned: bool = true,
    pub fn create(allocator: std.mem.Allocator, result: *const diff.Result, mode: Mode, options: Options) !Index {
        if (!result.isOwned()) return error.ResultMoved;
        try validateOptions(options);
        var count: usize = 0;
        const rows = try walk(result, mode, options, null, &count);
        const bytes = try footprint(count);
        if (bytes > options.bytes) return error.CapacityExceeded;
        const regions = try allocator.alloc(Region, count);
        errdefer allocator.free(regions);
        const segments = try allocator.alloc(Segment, count + 1);
        var written: usize = 0;
        _ = walk(result, mode, options, regions, &written) catch unreachable;
        var self: Index = .{ .allocator = allocator, .regions = regions, .segments = segments, .raw_rows = rows, .bytes = bytes, .options = options, .a = result.a, .b = result.b };
        self.rebuild();
        return self;
    }
    pub fn close(self: *Index) void {
        if (!self.owned) return;
        const allocator = self.allocator;
        const regions = self.regions;
        const segments = self.segments;
        self.owned = false;
        self.regions = &.{};
        self.segments = &.{};
        self.segment_count = 0;
        allocator.free(regions);
        allocator.free(segments);
    }
    pub fn clone(self: *const Index, allocator: std.mem.Allocator) !Index {
        if (!self.owned) return error.Closed;
        const regions = try allocator.dupe(Region, self.regions);
        errdefer allocator.free(regions);
        const segments = try allocator.dupe(Segment, self.segments);
        var output = self.*;
        output.allocator = allocator;
        output.regions = regions;
        output.segments = segments;
        return output;
    }
    pub fn setCollapsed(self: *Index, id: u64, collapsed: bool) !bool {
        if (!self.owned) return error.Closed;
        const at = self.find(id) orelse return error.FoldNotFound;
        if (self.regions[at].collapsed == collapsed) return false;
        self.regions[at].collapsed = collapsed;
        self.rebuild();
        return true;
    }
    pub fn find(self: *const Index, id: u64) ?usize {
        var lo: usize = 0;
        var hi = self.regions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.regions[mid].id < id) lo = mid + 1 else hi = mid;
        }
        return if (lo < self.regions.len and self.regions[lo].id == id) lo else null;
    }
    pub fn containing(self: *const Index, raw: usize) !?usize {
        if (!self.owned) return error.Closed;
        if (raw >= self.raw_rows) return error.InvalidRow;
        var lo: usize = 0;
        var hi = self.regions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.regions[mid].first <= raw) lo = mid + 1 else hi = mid;
        }
        return if (lo != 0 and raw < self.regions[lo - 1].end) lo - 1 else null;
    }
    pub fn visibleToRaw(self: *const Index, row: usize) !usize {
        if (!self.owned) return error.Closed;
        if (row >= self.visible_rows) return error.InvalidRow;
        var lo: usize = 0;
        var hi = self.segment_count;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.segments[mid].first <= row) lo = mid else hi = mid;
        }
        return self.segments[lo].raw + row - self.segments[lo].first;
    }
    pub fn rawToVisible(self: *const Index, raw: usize) !?usize {
        if (!self.owned) return error.Closed;
        if (raw >= self.raw_rows) return error.InvalidRow;
        var lo: usize = 0;
        var hi = self.segment_count;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.segments[mid].raw <= raw) lo = mid else hi = mid;
        }
        const segment = self.segments[lo];
        return if (raw >= segment.raw and raw - segment.raw < segment.count) segment.first + raw - segment.raw else null;
    }
    /// Expand a containing region without changing any Document selection.
    pub fn reveal(self: *Index, raw: usize) !bool {
        const at = (try self.containing(raw)) orelse return false;
        if (!self.regions[at].collapsed) return false;
        self.regions[at].collapsed = false;
        self.rebuild();
        return true;
    }
    fn rebuild(self: *Index) void {
        self.segment_count = 0;
        self.visible_rows = 0;
        var raw: usize = 0;
        for (self.regions) |region| if (region.collapsed) {
            self.keep(raw, region.first);
            raw = region.end;
        };
        self.keep(raw, self.raw_rows);
    }
    fn keep(self: *Index, first: usize, end: usize) void {
        if (first == end) return;
        self.segments[self.segment_count] = .{ .first = self.visible_rows, .raw = first, .count = end - first };
        self.segment_count += 1;
        self.visible_rows += end - first;
    }
    /// Intersect existing aligned/unified segments with visible metadata. The
    /// returned height index contains real source IDs, with no zero-height rows.
    /// The temporary base index and candidate both count against byte_limit.
    pub fn project(self: *const Index, allocator: std.mem.Allocator, base: *const aligned.Index, byte_limit: usize) !aligned.Index {
        if (!self.owned) return error.Closed;
        if (base.heights.len != self.raw_rows) return error.ForeignIndex;
        const capacity = try add(base.segment_count, try mul(self.regions.len, 2));
        const bytes = try add(try mul(capacity, @sizeOf(aligned.Segment)), try mul(try add(try mul(self.visible_rows, 2), 1), @sizeOf(u64)));
        if (base.bytes > byte_limit or bytes > byte_limit - base.bytes) return error.CapacityExceeded;
        const segments = try allocator.alloc(aligned.Segment, capacity);
        errdefer allocator.free(segments);
        const heights = try allocator.alloc(u64, self.visible_rows);
        errdefer allocator.free(heights);
        const tree = try allocator.alloc(u64, self.visible_rows + 1);
        @memset(tree, 0);
        var at: usize = 0;
        var count: usize = 0;
        for (self.segments[0..self.segment_count]) |kept| {
            var raw = kept.raw;
            while (raw < kept.raw + kept.count) {
                while (at < base.segment_count and base.segments[at].first + base.segments[at].count <= raw) at += 1;
                const source = base.segments[at];
                const offset = raw - source.first;
                const length = @min(source.count - offset, kept.raw + kept.count - raw);
                const first = kept.first + raw - kept.raw;
                const before_a = @min(source.count_a, offset);
                const before_b = @min(source.count_b, offset);
                segments[count] = .{ .first = first, .count = length, .a = source.a + before_a, .b = source.b + before_b, .count_a = @min(source.count_a - before_a, length), .count_b = @min(source.count_b - before_b, length), .hunk = source.hunk };
                count += 1;
                @memcpy(heights[first..][0..length], base.heights[raw..][0..length]);
                raw += length;
            }
        }
        for (1..tree.len) |i| {
            tree[i] += heights[i - 1];
            const parent = i + (i & (~i + 1));
            if (parent < tree.len) tree[parent] += tree[i];
        }
        return .{ .allocator = allocator, .segments = segments, .segment_count = count, .heights = heights, .tree = tree, .bytes = bytes };
    }
};
pub fn validateOptions(options: Options) !void {
    if (options.context_lines == 0 or options.context_lines > 16384 or options.minimum_hidden == 0 or options.minimum_hidden > 2097152 or options.regions == 0 or options.regions > 65536 or options.rows == 0 or options.rows > 2097152 or options.bytes == 0 or options.bytes > 64 * 1024 * 1024) return error.InvalidLimits;
}
fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.CapacityExceeded;
}
fn mul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.CapacityExceeded;
}
fn footprint(count: usize) !usize {
    return add(try mul(count, @sizeOf(Region)), try mul(try add(count, 1), @sizeOf(Segment)));
}
fn walk(result: *const diff.Result, mode: Mode, options: Options, output: ?[]Region, count: *usize) !usize {
    var a: usize = 0;
    var b: usize = 0;
    var rows: usize = 0;
    for (result.hunks, 0..) |hunk, ordinal| {
        if (hunk.a.lines.start < a or hunk.b.lines.start < b or hunk.a.lines.end < hunk.a.lines.start or hunk.b.lines.end < hunk.b.lines.start or hunk.a.lines.end > result.stats.lines_a or hunk.b.lines.end > result.stats.lines_b or hunk.a.lines.start - a != hunk.b.lines.start - b) return error.InvalidResult;
        const common = hunk.a.lines.start - a;
        try emitRegion(options, output, count, ordinal + 1, rows, a, b, common);
        rows = try add(rows, common);
        const na = hunk.a.lines.end - hunk.a.lines.start;
        const nb = hunk.b.lines.end - hunk.b.lines.start;
        rows = try add(rows, if (mode == .split) @max(na, nb) else try add(na, nb));
        if (rows > options.rows) return error.RowCapacityExceeded;
        a = hunk.a.lines.end;
        b = hunk.b.lines.end;
    }
    if (a > result.stats.lines_a or b > result.stats.lines_b or result.stats.lines_a - a != result.stats.lines_b - b) return error.InvalidResult;
    const common = result.stats.lines_a - a;
    try emitRegion(options, output, count, try add(result.hunks.len, 1), rows, a, b, common);
    rows = try add(rows, common);
    if (rows > options.rows) return error.RowCapacityExceeded;
    return rows;
}
fn emitRegion(options: Options, output: ?[]Region, count: *usize, id: usize, row: usize, a: usize, b: usize, common: usize) !void {
    const margins = try mul(options.context_lines, 2);
    if (common <= margins or common - margins < options.minimum_hidden) return;
    if (count.* == options.regions) return error.FoldCapacityExceeded;
    const start = options.context_lines;
    const end = common - options.context_lines;
    if (output) |entries| entries[count.*] = .{ .id = @intCast(id), .first = try add(row, start), .end = try add(row, end), .a = .{ .start = try add(a, start), .end = try add(a, end) }, .b = .{ .start = try add(b, start), .end = try add(b, end) } };
    count.* += 1;
}
test {
    _ = @import("context_index_test.zig");
}
