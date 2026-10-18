const std = @import("std");

pub const Point = extern struct { x: f32 = 0, y: f32 = 0 };
pub const Kind = enum(u32) { move, line, cubic, close };
pub const Segment = extern struct { kind: Kind, points: [3]Point = @splat(.{}) };
/// Full horizontal glyph cell in layout DIP, including its actual font's
/// ascent/descent and shaped advance/offset. This is distinct from glyph ink.
pub const GlyphCell = extern struct { x: f64, y: f64, width: f64, height: f64 };
pub const Position = extern struct { x: f64, y: f64 };
/// Half-open original UTF-8 byte range, independent of glyph order.
pub const SourceRange = extern struct { start: u32, end: u32 };
/// Index/count into MappingView.mapped_segments only, never Snapshot.segments.
pub const MappingRange = extern struct { start: u32, count: u32 };
pub const GlyphRange = extern struct { start: u32, count: u32 };
pub const Glyph = extern struct {
    glyph_id: u32,
    cluster: u32,
    run: u32,
    bidi_level: u32,
    mapped_segments: MappingRange,
    pen: Position,
    origin: Position,
    advance: f64,
    cell: GlyphCell,
};
pub const Cluster = struct {
    source: SourceRange,
    glyphs: GlyphRange,
    mapped_segments: MappingRange,
    /// Null for source omitted by native rendering, such as line separators.
    run: ?u32,
    bidi_level: u32,
    origin: ?Position,
};
pub const MappingView = struct {
    source: []const u8,
    glyphs: []const Glyph,
    clusters: []const Cluster,
    /// Explicit per-glyph native outlines in original layout coordinates.
    /// Floating-point grouping can differ from the unchanged batch segments.
    mapped_segments: []const Segment,
};
pub const NativeCluster = extern struct {
    source: SourceRange,
    glyphs: GlyphRange,
    mapped_segments: MappingRange,
    run: u32,
    bidi_level: u32,
};
pub const NativeMapping = extern struct {
    glyphs: ?[*]Glyph = null,
    clusters: ?[*]NativeCluster = null,
    glyph_capacity: u32,
    cluster_capacity: u32,
    glyph_count: u32 = 0,
    cluster_count: u32 = 0,
    run_count: u32 = 0,
    reserved: u32 = 0,
    cancellation: ?*const u8 = null,
    work_limit: u64,
    work: u64 = 0,
};
pub const Limits = struct {
    glyphs: usize = 8192,
    commands: usize = 65536,
    bytes: usize = 4 * 1024 * 1024,
    clusters: usize = 8192,
    work: u64 = 4 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.glyphs == 0 or self.glyphs > 65536 or self.commands == 0 or self.commands > 262144 or self.bytes == 0 or self.bytes > 16 * 1024 * 1024) return error.InvalidOutlineLimits;
        if (self.clusters == 0 or self.clusters > 131072 or self.work == 0 or self.work > 256 * 1024 * 1024) return error.InvalidOutlineLimits;
    }
};
pub const Options = struct {
    limits: Limits = .{},
    include_cells: bool = false,
    /// Explicit extra native enumeration and independent owning mapping.
    /// Batch and mapped segment counts share limits.commands and limits.bytes.
    include_mapping: bool = false,
    /// Checked before/after each bounded native call and foreign allocation.
    /// One native font/path operation cannot be interrupted.
    cancellation: ?*const std.atomic.Value(bool) = null,
    pub fn check(self: Options) !void {
        if (self.cancellation) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
    }
};
pub const Metrics = struct {
    first_baseline: f32,
    advance: f32,
    glyphs: u32,
    commands: usize,
    cells: usize = 0,
    owned_bytes: usize,
    peak_owned_bytes: usize = 0,
    /// Count/write enumerations of the same immutable native layout: two for
    /// the batch path, plus two only when mapping was requested.
    native_passes: u32 = 2,
    mapped_commands: usize = 0,
    clusters: usize = 0,
    mapping_work: u64 = 0,
};

/// Independent, immutable monochrome outline snapshot in layout DIP coordinates.
/// Segment borrows end at close; no native layout/font handle is retained.
pub const Snapshot = opaque {
    pub fn mapping(self: *const Snapshot) !?MappingView {
        const state = cast(@constCast(self));
        try state.check();
        return if (state.mapping) |value| .{ .source = value.source, .glyphs = value.glyphs, .clusters = value.clusters, .mapped_segments = value.mapped_segments } else null;
    }
    pub fn cells(self: *const Snapshot) ![]const GlyphCell {
        const state = cast(@constCast(self));
        try state.check();
        return state.cells;
    }
    pub fn segments(self: *const Snapshot) ![]const Segment {
        const state = cast(@constCast(self));
        try state.check();
        return state.segments;
    }
    pub fn metrics(self: *const Snapshot) !Metrics {
        const state = cast(@constCast(self));
        try state.check();
        return state.metrics;
    }
    pub fn close(self: *Snapshot) !void {
        const state = cast(self);
        try state.check();
        state.closing = true;
        const allocator = state.allocator;
        const values = state.segments;
        const cell_values = state.cells;
        const mapping_value = state.mapping;
        state.segments = &.{};
        state.cells = &.{};
        state.mapping = null;
        allocator.free(values);
        allocator.free(cell_values);
        if (mapping_value) |value| {
            value.deinit(allocator);
            allocator.destroy(value);
        }
        allocator.destroy(state);
    }
};
pub const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    segments: []Segment,
    cells: []GlyphCell,
    metrics: Metrics,
    mapping: ?*MappingStorage = null,
    closing: bool = false,
    fn check(self: *const State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
    }
};
pub const MappingStorage = struct {
    source: []u8,
    glyphs: []Glyph,
    clusters: []Cluster,
    mapped_segments: []Segment,
    pub fn deinit(self: MappingStorage, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.glyphs);
        allocator.free(self.clusters);
        allocator.free(self.mapped_segments);
    }
};
fn cast(snapshot: *Snapshot) *State {
    return @ptrCast(@alignCast(snapshot));
}

test "outline limits reject invalid budgets before native work" {
    try (Limits{}).validate();
    try std.testing.expectError(error.InvalidOutlineLimits, (Limits{ .glyphs = 0 }).validate());
    try std.testing.expectError(error.InvalidOutlineLimits, (Limits{ .commands = 262145 }).validate());
    try std.testing.expectError(error.InvalidOutlineLimits, (Limits{ .clusters = 0 }).validate());
    try std.testing.expectError(error.InvalidOutlineLimits, (Limits{ .clusters = 131073 }).validate());
    try std.testing.expectError(error.InvalidOutlineLimits, (Limits{ .work = 0 }).validate());
    try std.testing.expectError(error.InvalidOutlineLimits, (Limits{ .work = 268435457 }).validate());
    var cancellation = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, (Options{ .cancellation = &cancellation }).check());
}
