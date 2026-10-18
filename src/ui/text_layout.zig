const std = @import("std");
const builtin = @import("builtin");
pub const drawing = @import("ziggurat_drawing_resources");
pub const outlines = @import("text_layout_outline.zig");
pub const OutlineSnapshot = outlines.Snapshot;
pub const OutlineOptions = outlines.Options;

pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Rect = extern struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Affinity = enum { upstream, downstream };
pub const Caret = struct { byte_offset: usize, affinity: Affinity = .downstream };
pub const ByteRange = struct { start: usize, end: usize };
pub const Direction = enum { ltr, rtl };
pub const Wrap = enum(u32) { none, word, word_character };
pub const Options = struct {
    family: []const u8 = "",
    locale: []const u8 = "",
    size: f32 = 16,
    weight: u32 = 400,
    italic: bool = false,
    width: f32 = 0,
    wrap: Wrap = .none,
    direction: Direction = .ltr,
    /// Prepare platform lexical words plus maximal continuous nonword gaps.
    /// Default layouts perform no word SDK lookup/call or index allocation.
    word_ranges: bool = false,
    fn validate(self: Options) !void {
        if (!std.math.isFinite(self.size) or self.size < 1 or self.size > 512 or self.weight < 100 or self.weight > 900 or !std.math.isFinite(self.width) or self.width < 0 or self.width > 1_000_000 or (self.wrap != .none and self.width == 0)) return error.InvalidOptions;
        if (self.family.len > 255 or self.locale.len > 127) return error.InvalidOptions;
        try validateText(self.family);
        try validateText(self.locale);
    }
};
pub const Limits = struct {
    text_bytes: usize = 64 * 1024,
    graphemes: usize = 8192,
    lines: usize = 4096,
    span_rects: usize = 16384,
    live_layouts: usize = 64,
    layout_bytes: usize = 4 * 1024 * 1024,
    fn validate(self: Limits) !void {
        if (self.text_bytes == 0 or self.text_bytes > 65536 or self.graphemes == 0 or self.graphemes > 8192 or self.lines == 0 or self.lines > 4096 or self.span_rects == 0 or self.span_rects > 16384 or self.live_layouts == 0 or self.live_layouts > 64 or self.layout_bytes < @sizeOf(LayoutState) or self.layout_bytes > 4 * 1024 * 1024) return error.InvalidLimits;
    }
};
pub const Line = extern struct {
    start: u32,
    end: u32,
    next_start: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    baseline: f32,
};
pub const Metrics = extern struct { bounds: Rect, lines: u32, glyphs: u32, missing_glyphs: u32 };
/// DirectWrite creation-time query counters. Linux reports only cell counts;
/// zero query counters there do not mean that Pango was not called.
pub const NativeQueries = extern struct { position_queries: u32 = 0, range_queries: u32 = 0, cluster_queries: u32 = 0, line_queries: u32 = 0, bulk_cells: u32 = 0, fallback_cells: u32 = 0, draw_queries: u32 = 0, validation_runs: u32 = 0 };
pub const BuildStats = struct { scalar_count: usize, graphemes: usize, spans: usize, owned_bytes: usize, peak_owned_bytes: usize, native_calls: usize, snapshot_cells: usize, native_queries: NativeQueries, elapsed_ns: ?u64 };
pub const Hit = struct { caret: Caret, inside: bool };
pub const NativeError = extern struct { domain: u32 = 0, code: i32 = 0 };
pub const ResourceCounts = struct { engines: u32 = 0, layouts: u32 = 0, references: u32 = 0, modules: u32 = 0, prepared: u32 = 0 };
pub fn resourceCounts() ResourceCounts {
    var counts: ResourceCounts = .{};
    if (builtin.os.tag == .windows or builtin.os.tag == .linux) ztl_resources(&counts.engines, &counts.layouts, &counts.references, &counts.modules);
    if (builtin.os.tag == .windows or builtin.os.tag == .linux) counts.prepared = ztl_prepared_count();
    return counts;
}

/// Created on the process main thread, whose identity the host supplies from
/// its entrypoint. This mandatory parameter is never inferred from the caller.
/// Owning opaque pointers have one owner; other pointer copies are borrows.
pub const Engine = opaque {
    pub fn create(allocator: std.mem.Allocator, process_main_thread: std.Thread.Id, limits: Limits) !*Engine {
        if (std.Thread.getCurrentId() != process_main_thread) return error.WrongThread;
        try limits.validate();
        if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.UnsupportedPlatform;
        const state = try allocator.create(EngineState);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .owner = process_main_thread, .limits = limits };
        try nativeResult(ztl_engine_init(&state.native, &state.last_error));
        return @ptrCast(state);
    }
    pub fn close(self: *Engine) !void {
        const state = es(self);
        try state.check();
        if (state.busy) return error.Busy;
        if (state.live != 0) return error.LayoutsAlive;
        state.closing = true;
        ztl_engine_close(&state.native);
        const allocator = state.allocator;
        allocator.destroy(state);
    }
    /// The input storage stays alive through this call. Text is captured once
    /// after allocation; all validation and derived data use that owning copy.
    /// Font family/locale are captured before the first allocator callback.
    pub fn layout(self: *Engine, text: []const u8, options: Options) !*Layout {
        return self.layoutMode(null, text, options, false);
    }
    /// All layout and Prepared Zig allocations use this explicit allocator.
    /// Its context must outlive the layout and every Prepared derived from it.
    pub fn layoutAllocated(self: *Engine, allocator: std.mem.Allocator, text: []const u8, options: Options) !*Layout {
        return self.layoutMode(allocator, text, options, false);
    }
    /// Windows diagnostic oracle: retain per-position/range native queries.
    /// Linux keeps its existing cell snapshot. Construction can be much slower;
    /// never construct this diagnostic layout during paint.
    pub fn layoutReference(self: *Engine, text: []const u8, options: Options) !*Layout {
        return self.layoutMode(null, text, options, true);
    }
    fn layoutMode(self: *Engine, allocator: ?std.mem.Allocator, text: []const u8, options: Options, reference: bool) !*Layout {
        const state = es(self);
        try state.check();
        if (state.busy) return error.Busy;
        state.busy = true;
        defer state.busy = false;
        state.last_error = .{};
        if (text.len > state.limits.text_bytes) return error.TextCapacityExceeded;
        if (state.live == state.limits.live_layouts) return error.LayoutCapacityExceeded;
        return createLayout(state, allocator orelse state.allocator, text, options, reference);
    }
    pub fn lastNativeError(self: *const Engine) !NativeError {
        const state = es(@constCast(self));
        try state.check();
        return state.last_error;
    }
};

/// Immutable owning system layout. No shaping, allocation, native calls or
/// mutation occurs in its queries. Close only after all borrowed uses finish.
pub const Layout = opaque {
    pub fn close(self: *Layout) !void {
        const state = ls(self);
        try requireOwner(state.owner);
        if (state.closing) return error.Closed;
        if (state.operation_busy) return error.Busy;
        if (state.prepared_count != 0) return error.PreparedAlive;
        state.closing = true;
        const engine = state.engine;
        destroyLayout(state);
        engine.live -= 1;
    }
    pub fn prepare(self: *Layout, scale: f32, prepare_options: PrepareOptions) !*Prepared {
        const state = ls(self);
        try requireOwner(state.owner);
        if (state.closing) return error.Closed;
        if (state.operation_busy) return error.Busy;
        state.operation_busy = true;
        defer state.operation_busy = false;
        return prepareLayout(state, scale, prepare_options);
    }
    /// Copies the original shaped glyph runs into independent monochrome
    /// contours. This is explicit preparation; no shaping is repeated.
    pub fn outline(self: *Layout, allocator: std.mem.Allocator, outline_options: OutlineOptions) !*OutlineSnapshot {
        const state = ls(self);
        try requireOwner(state.owner);
        if (state.closing) return error.Closed;
        if (state.operation_busy) return error.Busy;
        try outline_options.limits.validate();
        try outline_options.check();
        if (state.metrics.glyphs > outline_options.limits.glyphs) return error.OutlineGlyphsExceeded;
        state.operation_busy = true;
        defer state.operation_busy = false;
        if (!outline_options.include_mapping) return @ptrCast(try outlineLayout(state, allocator, outline_options));
        var budget: OutlineBudget = .{ .child = allocator, .limit = outline_options.limits.bytes };
        const result = outlineLayout(state, budget.allocator(), outline_options) catch |err| return if (err == error.OutOfMemory and budget.denied) error.OutlineCapacityExceeded else err;
        result.allocator = allocator;
        result.metrics.peak_owned_bytes = budget.peak;
        std.debug.assert(result.metrics.owned_bytes == budget.live);
        return @ptrCast(result);
    }
    pub fn text(self: *const Layout) ![]const u8 {
        const state = ls(@constCast(self));
        try state.check();
        return state.text;
    }
    pub fn options(self: *const Layout) !Options {
        const state = ls(@constCast(self));
        try state.check();
        return state.options;
    }
    pub fn metrics(self: *const Layout) !Metrics {
        const state = ls(@constCast(self));
        try state.check();
        return state.metrics;
    }
    pub fn lines(self: *const Layout) ![]const Line {
        const state = ls(@constCast(self));
        try state.check();
        return state.lines[0..state.line_count];
    }
    /// Borrowed selection advance cells in visual line/X order. A grapheme may
    /// have several cells, or zero width; these are neither ink nor caret stops.
    /// Byte ranges refer to this immutable Layout's UTF-8 text. O(1), no native
    /// query or allocation; the slice expires when this Layout closes.
    pub fn advanceSpans(self: *const Layout) ![]const AdvanceSpan {
        const state = ls(@constCast(self));
        try state.check();
        return state.spans[0..state.span_count];
    }
    pub fn buildStats(self: *const Layout) !BuildStats {
        const state = ls(@constCast(self));
        try state.check();
        return state.stats;
    }
    pub fn utf16FromByte(self: *const Layout, byte_offset: usize) !usize {
        const state = ls(@constCast(self));
        try state.check();
        return state.scalars[try findScalar(state.scalars, byte_offset, .bytes)].utf16;
    }
    pub fn byteFromUtf16(self: *const Layout, utf16_offset: usize) !usize {
        const state = ls(@constCast(self));
        try state.check();
        return state.scalars[try findScalar(state.scalars, utf16_offset, .utf16)].bytes;
    }
    pub fn graphemeCount(self: *const Layout) !usize {
        const state = ls(@constCast(self));
        try state.check();
        return state.graphemes.len - 1;
    }
    pub fn graphemeByte(self: *const Layout, index: usize) !usize {
        const state = ls(@constCast(self));
        try state.check();
        if (index >= state.graphemes.len) return error.InvalidGrapheme;
        return state.graphemes[index].byte_offset;
    }
    pub fn caret(self: *const Layout, position: Caret) !Rect {
        const state = ls(@constCast(self));
        try state.check();
        const item = state.graphemes[try findGrapheme(state, position.byte_offset)];
        return if (position.affinity == .downstream) item.downstream else item.upstream;
    }
    /// Logical UTF-8 range in this immutable Layout. Only exact grapheme
    /// endpoints are accepted; affinity selects the logical side at a word/gap
    /// boundary. Both affinities clamp 0/EOF to the first/last unit.
    pub fn wordRangeAt(self: *const Layout, position: Caret) !ByteRange {
        const state = ls(@constCast(self));
        try state.check();
        if (!state.options.word_ranges) return error.WordRangesNotEnabled;
        _ = try findGrapheme(state, position.byte_offset);
        if (state.text.len == 0) return .{ .start = 0, .end = 0 };
        const index = state.words.?;
        return wordRangeAtEnds(wordEnds(index)[0..index.count], position.byte_offset, position.affinity == .downstream);
    }
    pub fn hitTest(self: *const Layout, point: Point) !Hit {
        const state = ls(@constCast(self));
        try state.check();
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidPoint;
        const line = lineAt(state, point.y);
        const edges = state.edges[state.line_edges[line]..state.line_edges[line + 1]];
        var low: usize = 0;
        var high: usize = edges.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (edges[mid].x < point.x) low = mid + 1 else high = mid;
        }
        var selected = @min(low, edges.len - 1);
        if (selected > 0 and @abs(@as(f64, edges[selected - 1].x) - point.x) <= @abs(@as(f64, edges[selected].x) - point.x)) selected -= 1;
        const bounds = state.metrics.bounds;
        return .{ .caret = edges[selected].caret, .inside = point.x >= bounds.x and point.y >= bounds.y and @as(f64, point.x) <= @as(f64, bounds.x) + bounds.width and @as(f64, point.y) <= @as(f64, bounds.y) + bounds.height };
    }
    /// Logical advance cells, optionally joined when exactly adjacent. These
    /// are selection geometry, not glyph ink bounds or UIA visible bounds.
    pub fn selectionRectCount(self: *const Layout, range: ByteRange) !usize {
        const state = ls(@constCast(self));
        try state.check();
        try validateRange(state, range);
        return selection(state, range, null);
    }
    pub fn selectionRects(self: *const Layout, range: ByteRange, output: []Rect) ![]const Rect {
        const state = ls(@constCast(self));
        try state.check();
        try validateRange(state, range);
        const count = selection(state, range, null);
        if (output.len < count) return error.OutputTooSmall;
        _ = selection(state, range, output);
        return output[0..count];
    }
};

pub const PrepareLimits = struct {
    pixels: usize = 16 * 1024 * 1024,
    bytes: usize = 64 * 1024 * 1024,
};
pub const PrepareOptions = struct { limits: PrepareLimits = .{}, viewport: ?drawing.Rect = null };
pub const max_prepared_per_layout = 8;
pub const PrepareStats = struct { owned_bytes: usize, peak_plane_bytes: usize, pixels: usize, elapsed_ns: ?u64 };

/// Prepared coverage is immutable and borrows the original native layout.
/// Frames pin its lease; close never frees storage still used by a replay.
pub const Prepared = opaque {
    pub fn view(self: *const Prepared) !drawing.PreparedTextView {
        const state = ps(@constCast(self));
        try state.check();
        return .{ .lease = &state.lease, .platform = if (builtin.os.tag == .windows) .windows else .linux, .native_layout = state.native_layout, .native_coverage = state.native_coverage, .coverage = state.coverage, .clip = state.clip };
    }
    pub fn inUse(self: *const Prepared) !bool {
        const state = ps(@constCast(self));
        try state.check();
        return state.lease.pins != 0;
    }
    pub fn ensureUnused(self: *const Prepared) !void {
        const state = ps(@constCast(self));
        try state.check();
        try state.lease.ensureUnused();
    }
    pub fn stats(self: *const Prepared) !PrepareStats {
        const state = ps(@constCast(self));
        try state.check();
        return state.stats;
    }
    pub fn close(self: *Prepared) !void {
        const state = ps(self);
        try state.check();
        try state.lease.ensureUnused();
        const parent = state.layout;
        if (parent.operation_busy) return error.Busy;
        parent.operation_busy = true;
        defer parent.operation_busy = false;
        state.closing = true;
        const allocator = parent.allocator;
        ztl_prepared_close(&state.native);
        allocator.free(state.coverage.pixels);
        allocator.destroy(state);
        parent.prepared_count -= 1;
    }
};

const NativeOptions = extern struct { size: f32, width: f32, weight: u32, italic: u32, wrap: u32, rtl: u32, family: [*:0]const u8, locale: [*:0]const u8 };
const NativeCell = extern struct { position: u32, line: u32 = 0, rect: Rect = .{}, rtl: u32 = 0, valid: u32 = 0 };
const NativeCluster = extern struct { storage: [2]u32 };
const NativeRange = extern struct { storage: [9]u32 };
extern fn ztl_engine_init(*anyopaque, *NativeError) c_int;
extern fn ztl_engine_close(*anyopaque) void;
extern fn ztl_layout_init(*anyopaque, *anyopaque, [*]const u8, u32, [*]const u16, u32, *const NativeOptions, *NativeError) c_int;
extern fn ztl_layout_close(*anyopaque) void;
extern fn ztl_metrics(*anyopaque, *Metrics, *NativeError) c_int;
extern fn ztl_graphemes(*anyopaque, [*]u32, u32, *u32, *NativeError) c_int;
extern fn ztl_word_ranges(*anyopaque, [*:0]const u8, ?[*]u32, u32, *u32, *NativeError) c_int;
extern fn ztl_lines(*anyopaque, [*]Line, u32, *u32, *NativeError) c_int;
extern fn ztl_caret(*anyopaque, u32, c_int, *Rect, *NativeError) c_int;
extern fn ztl_spans(*anyopaque, u32, u32, [*]Rect, u32, *u32, *NativeError) c_int;
extern fn ztl_cells(*anyopaque, [*]NativeCell, u32, *NativeError) c_int;
extern fn ztl_snapshot_needs(*anyopaque, *u32, *u32, *NativeError) c_int;
extern fn ztl_snapshot_cells(*anyopaque, [*]NativeCell, u32, [*]NativeCluster, u32, [*]NativeRange, u32, *NativeError) c_int;
extern fn ztl_snapshot_stats(*anyopaque, *NativeQueries) void;
extern fn ztl_finish_snapshot(*anyopaque) void;
extern fn ztl_ink_bounds(*anyopaque, *Rect, *NativeError) c_int;
extern fn ztl_outline(*anyopaque, ?[*]outlines.Segment, u32, *u32, ?[*]outlines.GlyphCell, u32, *u32, *NativeError) c_int;
extern fn ztl_outline_mapping(*anyopaque, ?[*]outlines.Segment, u32, *u32, *outlines.NativeMapping, *NativeError) c_int;
extern fn ztl_prepare(*anyopaque, *anyopaque, f32, i32, i32, u32, u32, u32, [*]u8, ?*const drawing.Rect, *NativeError) c_int;
extern fn ztl_prepared_close(*anyopaque) void;
extern fn ztl_native_layout(*anyopaque) ?*anyopaque;
extern fn ztl_native_coverage(*anyopaque) ?*anyopaque;
extern fn ztl_prepared_count() u32;
extern fn ztl_resources(*u32, *u32, *u32, *u32) void;
const EngineState = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    limits: Limits,
    live: usize = 0,
    busy: bool = false,
    closing: bool = false,
    last_error: NativeError = .{},
    native: [256]u8 align(16) = @splat(0),
    fn check(self: *const EngineState) !void {
        try requireOwner(self.owner);
        if (self.closing) return error.Closed;
    }
};
const Scalar = struct { bytes: u32, utf16: u32 };
const Grapheme = struct { byte_offset: u32, upstream: Rect, downstream: Rect };
const Edge = struct { caret: Caret, x: f32, line: usize };
pub const AdvanceSpan = struct { start: u32, end: u32, rect: Rect, line: usize };
const Span = AdvanceSpan;
const WordIndex = extern struct { count: u32, capacity: u32 };
const LayoutState = struct {
    owner: std.Thread.Id,
    allocator: std.mem.Allocator,
    engine: *EngineState,
    options: Options,
    text: [:0]u8,
    utf16: [:0]u16,
    family: [:0]u8,
    locale: [:0]u8,
    scalars: []Scalar,
    graphemes: []Grapheme,
    edges: []Edge,
    lines: []Line,
    line_edges: []usize,
    spans: []Span,
    words: ?*WordIndex,
    span_count: usize = 0,
    line_count: usize = 0,
    prepared_count: usize = 0,
    operation_busy: bool = false,
    closing: bool = false,
    metrics: Metrics = undefined,
    stats: BuildStats = undefined,
    native: [256]u8 align(16) = @splat(0),
    fn check(self: *const LayoutState) !void {
        try requireOwner(self.owner);
        if (self.closing) return error.Closed;
    }
};
const PreparedState = struct {
    lease: drawing.Lease,
    layout: *LayoutState,
    native_layout: *anyopaque,
    native_coverage: ?*anyopaque,
    coverage: drawing.Coverage,
    clip: ?drawing.Rect,
    stats: PrepareStats,
    closing: bool = false,
    native: [256]u8 align(16) = @splat(0),
    fn check(self: *const PreparedState) !void {
        try self.lease.checkOwner();
        if (self.closing) return error.Closed;
    }
};
fn ps(prepared: *Prepared) *PreparedState {
    return @ptrCast(@alignCast(prepared));
}
fn es(engine: *Engine) *EngineState {
    return @ptrCast(@alignCast(engine));
}
fn ls(layout: *Layout) *LayoutState {
    return @ptrCast(@alignCast(layout));
}
fn requireOwner(owner: std.Thread.Id) !void {
    if (owner != std.Thread.getCurrentId()) return error.WrongThread;
}
fn validateText(text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
}
fn outlineResult(result: c_int) !void {
    if (result == 2) return error.OutlineCapacityExceeded;
    if (result == 5) return error.UnsupportedGlyphOutline;
    if (result == 6) return error.OutlineWorkExceeded;
    if (result == 7) return error.UnsupportedGlyphMapping;
    if (result == 8) return error.Cancelled;
    try nativeResult(result);
}

fn outlineLayout(state: *LayoutState, allocator: std.mem.Allocator, options: OutlineOptions) !*outlines.State {
    var needed: u32 = 0;
    var cell_count: u32 = 0;
    const cell_limit: u32 = if (options.include_cells) @intCast(options.limits.glyphs) else 0;
    try outlineResult(ztl_outline(&state.native, null, @intCast(options.limits.commands), &needed, null, cell_limit, &cell_count, &state.engine.last_error));
    try options.check();
    const bytes = std.math.mul(usize, needed, @sizeOf(outlines.Segment)) catch return error.OutlineCapacityExceeded;
    const cell_bytes = std.math.mul(usize, cell_count, @sizeOf(outlines.GlyphCell)) catch return error.OutlineCapacityExceeded;
    var owned = std.math.add(usize, std.math.add(usize, bytes, cell_bytes) catch return error.OutlineCapacityExceeded, @sizeOf(outlines.State)) catch return error.OutlineCapacityExceeded;
    if (owned > options.limits.bytes) return error.OutlineCapacityExceeded;
    const result = try allocator.create(outlines.State);
    errdefer allocator.destroy(result);
    try options.check();
    const segments = try allocator.alloc(outlines.Segment, needed);
    errdefer allocator.free(segments);
    const cells = try allocator.alloc(outlines.GlyphCell, cell_count);
    errdefer allocator.free(cells);
    try options.check();
    var actual: u32 = 0;
    var actual_cells: u32 = 0;
    try outlineResult(ztl_outline(&state.native, segments.ptr, needed, &actual, if (options.include_cells) cells.ptr else null, cell_count, &actual_cells, &state.engine.last_error));
    if (actual != needed or actual_cells != cell_count) return error.NativeOutlineChanged;
    try options.check();
    try validateOutlineSegments(segments);
    for (cells) |cell| if (!validGlyphCell(cell)) return error.NativeOutlineFailed;
    var mapping: ?*outlines.MappingStorage = null;
    errdefer if (mapping) |value| {
        value.deinit(allocator);
        allocator.destroy(value);
    };
    var mapping_work: u64 = 0;
    if (options.include_mapping) {
        const base_work = @as(u64, needed) * 2;
        if (base_work > options.limits.work) return error.OutlineWorkExceeded;
        mapping_work = base_work;
        mapping = try buildOutlineMapping(state, allocator, options, @intCast(options.limits.commands - needed), &mapping_work);
        const value = mapping.?;
        owned += @sizeOf(outlines.MappingStorage) + value.source.len + value.glyphs.len * @sizeOf(outlines.Glyph) + value.clusters.len * @sizeOf(outlines.Cluster) + value.mapped_segments.len * @sizeOf(outlines.Segment);
    }
    try options.check();
    result.* = .{ .allocator = allocator, .owner = state.owner, .segments = segments, .cells = cells, .mapping = mapping, .metrics = .{
        .first_baseline = state.lines[0].baseline,
        .advance = state.metrics.bounds.width,
        .glyphs = state.metrics.glyphs,
        .commands = needed,
        .cells = cell_count,
        .owned_bytes = owned,
        .peak_owned_bytes = owned,
        .native_passes = if (mapping != null) 4 else 2,
        .mapped_commands = if (mapping) |value| value.mapped_segments.len else 0,
        .clusters = if (mapping) |value| value.clusters.len else 0,
        .mapping_work = mapping_work,
    } };
    return result;
}
fn validateOutlineSegments(segments: []const outlines.Segment) !void {
    for (segments) |segment| for (segment.points) |point| {
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.NativeOutlineFailed;
    };
}
fn validGlyphCell(cell: outlines.GlyphCell) bool {
    return std.math.isFinite(cell.x) and std.math.isFinite(cell.y) and std.math.isFinite(cell.width) and std.math.isFinite(cell.height) and cell.width >= 0 and cell.height >= 0 and std.math.isFinite(cell.x + cell.width) and std.math.isFinite(cell.y + cell.height);
}
fn outlineWork(work: *u64, amount: u64, limit: u64) !void {
    if (amount > limit -| work.*) return error.OutlineWorkExceeded;
    work.* += amount;
}
fn mappedRange(range: outlines.MappingRange, length: usize) bool {
    return range.start <= length and range.count <= length - range.start;
}
fn buildOutlineMapping(state: *LayoutState, allocator: std.mem.Allocator, options: OutlineOptions, command_limit: u32, work: *u64) !*outlines.MappingStorage {
    var native: outlines.NativeMapping = .{
        .glyph_capacity = @intCast(options.limits.glyphs),
        .cluster_capacity = @intCast(options.limits.clusters),
        .work_limit = options.limits.work - work.*,
        .cancellation = if (options.cancellation) |cancel| @ptrCast(cancel) else null,
    };
    var needed: u32 = 0;
    try outlineResult(ztl_outline_mapping(&state.native, null, command_limit, &needed, &native, &state.engine.last_error));
    try outlineWork(work, native.work, options.limits.work);
    try options.check();
    if (native.glyph_count != state.metrics.glyphs) return error.NativeOutlineChanged;
    const glyphs = try allocator.alloc(outlines.Glyph, native.glyph_count);
    errdefer allocator.free(glyphs);
    const raw = try allocator.alloc(outlines.NativeCluster, native.cluster_count);
    defer allocator.free(raw);
    const segments = try allocator.alloc(outlines.Segment, needed);
    errdefer allocator.free(segments);
    try options.check();
    var actual = native;
    actual.glyphs = glyphs.ptr;
    actual.clusters = raw.ptr;
    actual.glyph_capacity = native.glyph_count;
    actual.cluster_capacity = native.cluster_count;
    actual.work_limit = options.limits.work - work.*;
    var actual_count: u32 = 0;
    try outlineResult(ztl_outline_mapping(&state.native, segments.ptr, needed, &actual_count, &actual, &state.engine.last_error));
    try outlineWork(work, actual.work, options.limits.work);
    try options.check();
    if (actual_count != needed or actual.glyph_count != native.glyph_count or actual.cluster_count != native.cluster_count or actual.run_count != native.run_count) return error.NativeOutlineChanged;
    try validateOutlineSegments(segments);
    // Two native-unit -> byte lookups per cluster each binary-search the
    // immutable scalar index. Charge their worst-case comparison bound.
    const scalar_levels: u64 = if (state.scalars.len < 2) 1 else std.math.log2_int_ceil(usize, state.scalars.len) + 1;
    try outlineWork(work, @as(u64, glyphs.len) + @as(u64, raw.len) * (2 * scalar_levels + 1) + state.text.len, options.limits.work);
    for (glyphs) |glyph| {
        if (glyph.cluster >= raw.len or glyph.run >= actual.run_count or !mappedRange(glyph.mapped_segments, segments.len) or !validGlyphCell(glyph.cell) or !std.math.isFinite(glyph.pen.x) or !std.math.isFinite(glyph.pen.y) or !std.math.isFinite(glyph.origin.x) or !std.math.isFinite(glyph.origin.y) or !std.math.isFinite(glyph.advance)) return error.UnsupportedGlyphMapping;
    }
    for (raw, 0..) |*cluster, index| {
        if (cluster.source.start >= cluster.source.end or cluster.run >= actual.run_count or cluster.glyphs.count == 0 or cluster.glyphs.start > glyphs.len or cluster.glyphs.count > glyphs.len - cluster.glyphs.start or !mappedRange(cluster.mapped_segments, segments.len)) return error.UnsupportedGlyphMapping;
        cluster.source.start = try bytePosition(state.scalars, cluster.source.start);
        cluster.source.end = try bytePosition(state.scalars, cluster.source.end);
        var segment_at = cluster.mapped_segments.start;
        for (glyphs[cluster.glyphs.start..][0..cluster.glyphs.count]) |glyph| {
            if (glyph.cluster != index or glyph.run != cluster.run or glyph.bidi_level != cluster.bidi_level or glyph.mapped_segments.start != segment_at) return error.UnsupportedGlyphMapping;
            segment_at += glyph.mapped_segments.count;
        }
        if (segment_at != cluster.mapped_segments.start + cluster.mapped_segments.count) return error.UnsupportedGlyphMapping;
    }
    const order = try allocator.alloc(u32, raw.len);
    defer allocator.free(order);
    for (order, 0..) |*value, i| value.* = @intCast(i);
    // Heap sort has a bounded comparison count and does not allocate. Source
    // ordering is only temporary: public clusters preserve native enumeration.
    const levels: u64 = if (raw.len < 2) 0 else std.math.log2_int_ceil(usize, raw.len);
    try outlineWork(work, @as(u64, raw.len) * (levels * 2 + 4), options.limits.work);
    std.sort.heap(u32, order, raw, struct {
        fn less(values: []const outlines.NativeCluster, a: u32, b: u32) bool {
            return values[a].source.start < values[b].source.start;
        }
    }.less);
    var end: u32 = 0;
    var gaps: usize = 0;
    for (order) |index| {
        const range = raw[index].source;
        if (range.start < end) return error.UnsupportedGlyphMapping;
        if (range.start > end) gaps += 1;
        end = range.end;
    }
    if (end < state.text.len) gaps += 1;
    if (gaps > options.limits.clusters - raw.len) return error.OutlineCapacityExceeded;
    const clusters = try allocator.alloc(outlines.Cluster, raw.len + gaps);
    errdefer allocator.free(clusters);
    for (raw, clusters[0..raw.len]) |source, *cluster| cluster.* = .{ .source = source.source, .glyphs = source.glyphs, .mapped_segments = source.mapped_segments, .run = source.run, .bidi_level = source.bidi_level, .origin = glyphs[source.glyphs.start].origin };
    var gap_at = raw.len;
    end = 0;
    for (order) |index| {
        const range = raw[index].source;
        if (range.start > end) {
            clusters[gap_at] = omittedCluster(end, range.start, glyphs.len, segments.len);
            gap_at += 1;
        }
        end = range.end;
    }
    if (end < state.text.len) clusters[gap_at] = omittedCluster(end, @intCast(state.text.len), glyphs.len, segments.len);
    const source = try allocator.dupe(u8, state.text);
    errdefer allocator.free(source);
    try options.check();
    const result = try allocator.create(outlines.MappingStorage);
    errdefer allocator.destroy(result);
    try options.check();
    result.* = .{ .source = source, .glyphs = glyphs, .clusters = clusters, .mapped_segments = segments };
    return result;
}
fn omittedCluster(start: u32, end: u32, glyphs: usize, segments: usize) outlines.Cluster {
    return .{ .source = .{ .start = start, .end = end }, .glyphs = .{ .start = @intCast(glyphs), .count = 0 }, .mapped_segments = .{ .start = @intCast(segments), .count = 0 }, .run = null, .bidi_level = 0, .origin = null };
}
const OutlineBudget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    fn allocator(self: *OutlineBudget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *OutlineBudget = @ptrCast(@alignCast(ptr));
        if (length > self.limit -| self.live) {
            self.denied = true;
            return null;
        }
        const bytes = self.child.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        self.peak = @max(self.peak, self.live);
        return bytes;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *OutlineBudget = @ptrCast(@alignCast(ptr));
        self.child.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};
fn nativeResult(result: c_int) !void {
    switch (result) {
        0 => {},
        2 => return error.NativeCapacityExceeded,
        3 => return error.UnicodeSegmentationUnavailable,
        4 => return error.OutOfMemory,
        else => return error.NativeLayoutFailed,
    }
}
fn findScalar(map: []const Scalar, offset: usize, comptime unit: enum { bytes, utf16 }) !usize {
    var low: usize = 0;
    var high = map.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (@field(map[mid], @tagName(unit)) < offset) low = mid + 1 else high = mid;
    }
    if (low == map.len or @field(map[low], @tagName(unit)) != offset) return error.InvalidTextBoundary;
    return low;
}
fn findGrapheme(state: *const LayoutState, offset: usize) !usize {
    var low: usize = 0;
    var high = state.graphemes.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (state.graphemes[mid].byte_offset < offset) low = mid + 1 else high = mid;
    }
    if (low == state.graphemes.len or state.graphemes[low].byte_offset != offset) return error.InvalidCaret;
    return low;
}
fn wordEnds(index: *const WordIndex) []u32 {
    const units: [*]u32 = @ptrCast(@constCast(index));
    return units[2..][0..index.capacity];
}
fn freeWords(allocator: std.mem.Allocator, index: *WordIndex) void {
    const units: [*]u32 = @ptrCast(index);
    const capacity = index.capacity;
    allocator.free(units[0 .. @as(usize, capacity) + 2]);
}
fn wordRangeAtEnds(ends: []const u32, byte: usize, downstream: bool) ByteRange {
    std.debug.assert(ends.len != 0 and byte <= ends[ends.len - 1]);
    var low: usize = 0;
    var high = ends.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (if (downstream) ends[mid] <= byte else ends[mid] < byte) low = mid + 1 else high = mid;
    }
    const at = @min(low, ends.len - 1);
    return .{ .start = if (at == 0) 0 else ends[at - 1], .end = ends[at] };
}
// Positions remain in native units: later geometry still needs UTF-16 on
// Windows. This validation is opt-in, before deriving its WordIndex capacity.
fn validateWordPositions(scalars: []const Scalar, positions: []const u32) !void {
    if (positions.len == 0 or scalars.len == 0 or positions[0] != 0 or positions[positions.len - 1] != nativePosition(scalars[scalars.len - 1])) return error.NativeLayoutFailed;
    var scalar: usize = 0;
    var previous: u32 = 0;
    for (positions, 0..) |position, at| {
        if (at != 0 and position <= previous) return error.NativeLayoutFailed;
        while (scalar < scalars.len and nativePosition(scalars[scalar]) < position) scalar += 1;
        if (scalar == scalars.len or nativePosition(scalars[scalar]) != position) return error.NativeLayoutFailed;
        previous = position;
    }
}
noinline fn prepareWords(engine: *EngineState, allocator: std.mem.Allocator, storage: *[256]u8, locale: [:0]const u8, scalars: []const Scalar, positions: []const u32) !?*WordIndex {
    try validateWordPositions(scalars, positions);
    const capacity = positions.len - 1;
    if (capacity == 0) {
        var count: u32 = 0;
        // Enabled-empty still checks Windows' opt-in export. No index or
        // iterator allocation is needed for the empty partition.
        try nativeResult(ztl_word_ranges(storage, locale.ptr, null, 0, &count, &engine.last_error));
        if (count != 0) return error.NativeLayoutFailed;
        return null;
    }
    const units = try allocator.alloc(u32, capacity + 2);
    errdefer allocator.free(units);
    const index: *WordIndex = @ptrCast(units.ptr);
    index.* = .{ .count = 0, .capacity = @intCast(capacity) };
    const ends = wordEnds(index);
    try nativeResult(ztl_word_ranges(storage, locale.ptr, ends.ptr, index.capacity, &index.count, &engine.last_error));
    if (index.count == 0 or index.count > index.capacity) return error.NativeLayoutFailed;
    var scalar: usize = 0;
    var grapheme: usize = 0;
    var previous: u32 = 0;
    for (ends[0..index.count]) |*end| {
        const position = end.*;
        if (position <= previous) return error.NativeLayoutFailed;
        while (scalar < scalars.len and nativePosition(scalars[scalar]) < position) scalar += 1;
        while (grapheme < positions.len and positions[grapheme] < position) grapheme += 1;
        if (scalar == scalars.len or nativePosition(scalars[scalar]) != position or grapheme == positions.len or positions[grapheme] != position) return error.NativeLayoutFailed;
        end.* = scalars[scalar].bytes;
        previous = position;
    }
    if (previous != positions[positions.len - 1]) return error.NativeLayoutFailed;
    return index;
}
fn nativePosition(scalar: Scalar) u32 {
    return if (builtin.os.tag == .windows) scalar.utf16 else scalar.bytes;
}
fn bytePosition(map: []const Scalar, position: u32) !u32 {
    return map[try findScalar(map, position, if (builtin.os.tag == .windows) .utf16 else .bytes)].bytes;
}
fn validRect(rect: Rect) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and std.math.isFinite(rect.width) and std.math.isFinite(rect.height) and rect.width >= 0 and rect.height > 0;
}
fn lineAt(state: *const LayoutState, y: f32) usize {
    var low: usize = 0;
    var high = state.line_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (state.lines[mid].y <= y) low = mid + 1 else high = mid;
    }
    return low -| 1;
}
fn validateRange(state: *const LayoutState, range: ByteRange) !void {
    if (range.start > range.end) return error.InvalidRange;
    _ = try findGrapheme(state, range.start);
    _ = try findGrapheme(state, range.end);
}
fn selection(state: *const LayoutState, range: ByteRange, output: ?[]Rect) usize {
    var count: usize = 0;
    var pending: ?Rect = null;
    var pending_line: usize = 0;
    for (state.spans[0..state.span_count]) |span| {
        if (span.start < range.start or span.end > range.end or span.rect.width == 0) continue;
        if (pending) |*rect| {
            if (pending_line == span.line and rect.y == span.rect.y and rect.height == span.rect.height and @as(f64, span.rect.x) <= @as(f64, rect.x) + rect.width) {
                rect.width = @floatCast(@max(@as(f64, rect.x) + rect.width, @as(f64, span.rect.x) + span.rect.width) - rect.x);
                continue;
            }
            if (output) |out| out[count] = rect.*;
            count += 1;
        }
        pending = span.rect;
        pending_line = span.line;
    }
    if (pending) |rect| {
        if (output) |out| out[count] = rect;
        count += 1;
    }
    return count;
}
fn destroyLayout(state: *LayoutState) void {
    ztl_layout_close(&state.native);
    const allocator = state.allocator;
    if (state.words) |index| freeWords(allocator, index);
    allocator.free(state.text);
    allocator.free(state.utf16);
    allocator.free(state.family);
    allocator.free(state.locale);
    allocator.free(state.scalars);
    allocator.free(state.graphemes);
    allocator.free(state.edges);
    allocator.free(state.lines);
    allocator.free(state.line_edges);
    allocator.free(state.spans);
    allocator.destroy(state);
}
fn createLayout(engine: *EngineState, allocator: std.mem.Allocator, source: []const u8, options: Options, reference: bool) !*Layout {
    var timer = std.time.Timer.start() catch null;
    // These bounded strings must not remain caller aliases across allocation.
    // Text can be much larger, so its sole copy is allocated, then validated.
    if (options.family.len > 255 or options.locale.len > 127) return error.InvalidOptions;
    var family_storage: [255]u8 = undefined;
    var locale_storage: [127]u8 = undefined;
    const captured_family = family_storage[0..options.family.len];
    const captured_locale = locale_storage[0..options.locale.len];
    @memcpy(captured_family, options.family);
    @memcpy(captured_locale, options.locale);
    var captured_options = options;
    captured_options.family = captured_family;
    captured_options.locale = captured_locale;
    try captured_options.validate();
    const minimum_bytes = @sizeOf(LayoutState) + source.len + 1 + captured_family.len + 1 + captured_locale.len + 1 + @sizeOf(u16) + @sizeOf(Scalar) + @sizeOf(u32);
    if (minimum_bytes > engine.limits.layout_bytes) return error.LayoutByteCapacityExceeded;
    const state = try allocator.create(LayoutState);
    errdefer allocator.destroy(state);
    const text = try allocator.dupeZ(u8, source);
    errdefer allocator.free(text);
    // Never inspect source again. Allocator callbacks may have changed its
    // contents while its storage remained alive; counts must describe text.
    try validateText(text);
    const scalar_count = try std.unicode.utf8CountCodepoints(text);
    const utf16_count = try std.unicode.calcUtf16LeLen(text);
    var owned_bytes = @sizeOf(LayoutState) + text.len + 1 + (utf16_count + 1) * @sizeOf(u16) + captured_family.len + 1 + captured_locale.len + 1 + (scalar_count + 1) * @sizeOf(Scalar);
    const position_capacity = @min(engine.limits.graphemes + 1, scalar_count + 1);
    const cell_capacity = if (builtin.os.tag == .linux or (builtin.os.tag == .windows and !reference)) scalar_count else 0;
    const cell_bytes = cell_capacity * @sizeOf(NativeCell);
    if (owned_bytes + position_capacity * @sizeOf(u32) + cell_bytes > engine.limits.layout_bytes) return error.LayoutByteCapacityExceeded;
    const utf16 = try allocator.allocSentinel(u16, utf16_count, 0);
    errdefer allocator.free(utf16);
    const converted_units = try std.unicode.utf8ToUtf16Le(utf16, text);
    std.debug.assert(converted_units == utf16_count);
    const family = try allocator.dupeZ(u8, captured_family);
    errdefer allocator.free(family);
    const locale = try allocator.dupeZ(u8, captured_locale);
    errdefer allocator.free(locale);
    const scalars = try allocator.alloc(Scalar, scalar_count + 1);
    errdefer allocator.free(scalars);
    var byte: usize = 0;
    var unit: usize = 0;
    var index: usize = 0;
    while (byte < text.len) : (index += 1) {
        scalars[index] = .{ .bytes = @intCast(byte), .utf16 = @intCast(unit) };
        const len = try std.unicode.utf8ByteSequenceLength(text[byte]);
        const point = try std.unicode.utf8Decode(text[byte..][0..len]);
        byte += len;
        unit += if (point > 0xffff) @as(usize, 2) else 1;
    }
    scalars[index] = .{ .bytes = @intCast(byte), .utf16 = @intCast(unit) };
    state.owner = engine.owner;
    state.engine = engine;
    state.prepared_count = 0;
    state.operation_busy = false;
    state.closing = false;
    state.allocator = allocator;
    const native_options: NativeOptions = .{ .size = captured_options.size, .width = captured_options.width, .weight = captured_options.weight, .italic = @intFromBool(captured_options.italic), .wrap = @intFromEnum(captured_options.wrap), .rtl = @intFromBool(captured_options.direction == .rtl), .family = family.ptr, .locale = locale.ptr };
    try nativeResult(ztl_layout_init(&state.native, &engine.native, text.ptr, @intCast(text.len), utf16.ptr, @intCast(utf16.len), &native_options, &engine.last_error));
    errdefer ztl_layout_close(&state.native);
    var calls: usize = 1;
    var metrics: Metrics = undefined;
    try nativeResult(ztl_metrics(&state.native, &metrics, &engine.last_error));
    calls += 1;
    if (metrics.lines == 0 or metrics.lines > engine.limits.lines or !validRect(metrics.bounds)) return error.NativeCapacityExceeded;
    const positions = try allocator.alloc(u32, position_capacity);
    defer allocator.free(positions);
    var position_count: u32 = 0;
    try nativeResult(ztl_graphemes(&state.native, positions.ptr, @intCast(positions.len), &position_count, &engine.last_error));
    calls += 1;
    if (position_count == 0 or position_count > positions.len) return error.NativeLayoutFailed;
    const grapheme_count = position_count - 1;
    if (grapheme_count > engine.limits.graphemes) return error.NativeCapacityExceeded;
    const word_bytes: usize = if (captured_options.word_ranges and grapheme_count != 0) @sizeOf(WordIndex) + @as(usize, grapheme_count) * @sizeOf(u32) else 0;
    if (owned_bytes + word_bytes + positions.len * @sizeOf(u32) + cell_bytes > engine.limits.layout_bytes) return error.LayoutByteCapacityExceeded;
    owned_bytes += word_bytes;
    // Default callers never enter the new preparation/validation callee.
    const words = if (captured_options.word_ranges) try prepareWords(engine, allocator, &state.native, locale, scalars, positions[0..position_count]) else null;
    errdefer if (words) |index_words| freeWords(allocator, index_words);
    if (captured_options.word_ranges) calls += 1;
    const span_capacity = @min(engine.limits.span_rects, @max(1, grapheme_count) * 16);
    owned_bytes += position_count * (@sizeOf(Grapheme) + 2 * @sizeOf(Edge)) + metrics.lines * @sizeOf(Line) + (metrics.lines + 1) * @sizeOf(usize) + span_capacity * @sizeOf(Span);
    if (owned_bytes + positions.len * @sizeOf(u32) + cell_bytes > engine.limits.layout_bytes) return error.LayoutByteCapacityExceeded;
    const graphemes = try allocator.alloc(Grapheme, position_count);
    errdefer allocator.free(graphemes);
    const edges = try allocator.alloc(Edge, position_count * 2);
    errdefer allocator.free(edges);
    const lines = try allocator.alloc(Line, metrics.lines);
    errdefer allocator.free(lines);
    const line_edges = try allocator.alloc(usize, metrics.lines + 1);
    errdefer allocator.free(line_edges);
    const spans = try allocator.alloc(Span, span_capacity);
    errdefer allocator.free(spans);
    const cells = try allocator.alloc(NativeCell, cell_capacity);
    defer allocator.free(cells);
    defer ztl_finish_snapshot(&state.native);
    for (cells, scalars[0..cell_capacity]) |*cell, scalar| cell.* = .{ .position = nativePosition(scalar) };
    var snapshot_scratch_bytes: usize = 0;
    if (builtin.os.tag == .windows and !reference) {
        var cluster_count: u32 = 0;
        var range_count: u32 = 0;
        try nativeResult(ztl_snapshot_needs(&state.native, &cluster_count, &range_count, &engine.last_error));
        calls += 1;
        if (cluster_count > utf16.len or range_count > scalar_count + metrics.lines + 1) return error.NativeCapacityExceeded;
        snapshot_scratch_bytes = @as(usize, cluster_count) * @sizeOf(NativeCluster) + @as(usize, range_count) * @sizeOf(NativeRange);
        if (owned_bytes + positions.len * @sizeOf(u32) + cell_bytes + snapshot_scratch_bytes > engine.limits.layout_bytes) return error.LayoutByteCapacityExceeded;
        const clusters = try allocator.alloc(NativeCluster, cluster_count);
        defer allocator.free(clusters);
        const ranges = try allocator.alloc(NativeRange, range_count);
        defer allocator.free(ranges);
        try nativeResult(ztl_snapshot_cells(&state.native, cells.ptr, @intCast(cells.len), clusters.ptr, cluster_count, ranges.ptr, range_count, &engine.last_error));
        calls += 1;
    }
    var line_count: u32 = 0;
    try nativeResult(ztl_lines(&state.native, lines.ptr, @intCast(lines.len), &line_count, &engine.last_error));
    calls += 1;
    if (line_count != lines.len) return error.NativeLayoutFailed;
    for (lines) |*line| {
        line.start = try bytePosition(scalars, line.start);
        line.end = try bytePosition(scalars, line.end);
        line.next_start = try bytePosition(scalars, line.next_start);
        if (!validRect(.{ .x = line.x, .y = line.y, .width = line.width, .height = line.height }) or !std.math.isFinite(line.baseline)) return error.NativeLayoutFailed;
    }
    if (builtin.os.tag == .linux) {
        try nativeResult(ztl_cells(&state.native, cells.ptr, @intCast(cells.len), &engine.last_error));
        calls += 1;
    }
    // Install immutable array descriptors before using shared lookup helpers.
    state.text = text;
    state.utf16 = utf16;
    state.family = family;
    state.locale = locale;
    state.options = captured_options;
    state.options.family = family;
    state.options.locale = locale;
    state.scalars = scalars;
    state.graphemes = graphemes;
    state.edges = edges;
    state.lines = lines;
    state.line_edges = line_edges;
    state.spans = spans;
    state.words = words;
    state.metrics = metrics;
    state.line_count = lines.len;
    state.span_count = 0;
    for (positions[0..position_count], 0..) |position, gi| {
        const byte_offset = try bytePosition(scalars, position);
        if ((gi == 0 and byte_offset != 0) or (gi > 0 and byte_offset <= graphemes[gi - 1].byte_offset) or (gi + 1 == position_count and byte_offset != text.len)) return error.NativeLayoutFailed;
        var downstream: Rect = undefined;
        try nativeResult(ztl_caret(&state.native, position, 0, &downstream, &engine.last_error));
        calls += 1;
        var upstream = downstream;
        if (gi > 0) {
            const scalar_index = try findScalar(scalars, byte_offset, .bytes);
            try nativeResult(ztl_caret(&state.native, nativePosition(scalars[scalar_index - 1]), 1, &upstream, &engine.last_error));
            calls += 1;
        }
        if (!validRect(upstream) or !validRect(downstream)) return error.NativeLayoutFailed;
        graphemes[gi] = .{ .byte_offset = byte_offset, .upstream = upstream, .downstream = downstream };
        // Use an interior point; top-edge rounding must not classify a caret
        // or selection box as belonging to the preceding logical line.
        edges[gi * 2] = .{ .caret = .{ .byte_offset = byte_offset, .affinity = .upstream }, .x = upstream.x, .line = lineAt(state, upstream.y + upstream.height * 0.5) };
        edges[gi * 2 + 1] = .{ .caret = .{ .byte_offset = byte_offset, .affinity = .downstream }, .x = downstream.x, .line = lineAt(state, downstream.y + downstream.height * 0.5) };
        if (gi + 1 < position_count) {
            var local: [16]Rect = undefined;
            var count: u32 = 0;
            try nativeResult(ztl_spans(&state.native, position, positions[gi + 1], &local, local.len, &count, &engine.last_error));
            calls += 1;
            if (count > spans.len - state.span_count) return error.NativeCapacityExceeded;
            const end = try bytePosition(scalars, positions[gi + 1]);
            for (local[0..count]) |rect| {
                if (!validRect(rect)) return error.NativeLayoutFailed;
                spans[state.span_count] = .{ .start = byte_offset, .end = end, .rect = rect, .line = lineAt(state, rect.y + rect.height * 0.5) };
                state.span_count += 1;
            }
        }
    }
    const Sort = struct {
        fn edgeLess(_: void, a: Edge, b: Edge) bool {
            if (a.line != b.line) return a.line < b.line;
            if (a.x != b.x) return a.x < b.x;
            if (a.caret.byte_offset != b.caret.byte_offset) return a.caret.byte_offset < b.caret.byte_offset;
            return a.caret.affinity == .downstream and b.caret.affinity == .upstream;
        }
        fn spanLess(_: void, a: Span, b: Span) bool {
            return a.line < b.line or (a.line == b.line and a.rect.x < b.rect.x);
        }
    };
    std.mem.sort(Edge, edges, {}, Sort.edgeLess);
    std.mem.sort(Span, spans[0..state.span_count], {}, Sort.spanLess);
    var edge_index: usize = 0;
    for (0..lines.len) |li| {
        line_edges[li] = edge_index;
        while (edge_index < edges.len and edges[edge_index].line == li) edge_index += 1;
        if (line_edges[li] == edge_index) return error.NativeLayoutFailed;
    }
    line_edges[lines.len] = edges.len;
    // Native selection boxes also provide actual per-line advance extents.
    var span_index: usize = 0;
    for (lines, 0..) |*line, li| {
        var left = std.math.inf(f32);
        var right = -std.math.inf(f32);
        while (span_index < state.span_count and spans[span_index].line == li) : (span_index += 1) {
            const span = spans[span_index];
            left = @min(left, span.rect.x);
            right = @max(right, span.rect.x + span.rect.width);
        }
        if (std.math.isFinite(left)) {
            line.x = left;
            line.width = right - left;
        }
    }
    var queries: NativeQueries = .{};
    ztl_snapshot_stats(&state.native, &queries);
    calls += 1;
    state.stats = .{ .scalar_count = scalar_count, .graphemes = grapheme_count, .spans = state.span_count, .owned_bytes = owned_bytes, .peak_owned_bytes = owned_bytes + positions.len * @sizeOf(u32) + cell_bytes + snapshot_scratch_bytes, .native_calls = calls, .snapshot_cells = cell_capacity, .native_queries = queries, .elapsed_ns = if (timer) |*value| value.read() else null };
    engine.live += 1;
    return @ptrCast(state);
}

fn prepareLayout(parent: *LayoutState, scale: f32, options: PrepareOptions) !*Prepared {
    if (!std.math.isFinite(scale) or scale < 0.0625 or scale > 16) return error.InvalidPrepareScale;
    if (options.limits.pixels == 0 or options.limits.pixels > 16 * 1024 * 1024 or options.limits.bytes == 0 or options.limits.bytes > 64 * 1024 * 1024) return error.InvalidPrepareLimits;
    if (parent.prepared_count == max_prepared_per_layout) return error.PreparedCapacityExceeded;
    var timer = std.time.Timer.start() catch null;
    const engine = parent.engine;
    engine.last_error = .{};
    var ink: Rect = undefined;
    if (options.viewport) |r| {
        if (!std.math.isFinite(r.x) or !std.math.isFinite(r.y) or !std.math.isFinite(r.width) or !std.math.isFinite(r.height) or r.width <= 0 or r.height <= 0) return error.InvalidPrepareViewport;
        ink = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
    } else try nativeResult(ztl_ink_bounds(&parent.native, &ink, &engine.last_error));
    if (!std.math.isFinite(ink.x) or !std.math.isFinite(ink.y) or !std.math.isFinite(ink.width) or !std.math.isFinite(ink.height) or ink.width < 0 or ink.height < 0) return error.NativeLayoutFailed;
    const padding: f64 = if (options.viewport == null) 2 else 0;
    const edges = [_]f64{ @floor(@as(f64, ink.x) * scale) - padding, @floor(@as(f64, ink.y) * scale) - padding, @ceil((@as(f64, ink.x) + ink.width) * scale) + padding, @ceil((@as(f64, ink.y) + ink.height) * scale) + padding };
    for (edges) |edge| if (!std.math.isFinite(edge) or edge < std.math.minInt(i32) or edge > std.math.maxInt(i32)) return error.PreparedCapacityExceeded;
    const width_f = @max(1, edges[2] - edges[0]);
    const height_f = @max(1, edges[3] - edges[1]);
    if (width_f > 32768 or height_f > 32768) return error.PreparedCapacityExceeded;
    const width: u32 = @intFromFloat(width_f);
    const height: u32 = @intFromFloat(height_f);
    const pixels: usize = @as(usize, width) * height;
    const stride = (width + 3) & ~@as(u32, 3);
    const bytes: usize = @as(usize, stride) * height;
    const native_plane_bytes = if (builtin.os.tag == .windows) pixels * 4 else 0;
    const owned_bytes = bytes + @sizeOf(PreparedState);
    if (pixels > options.limits.pixels or owned_bytes + native_plane_bytes > options.limits.bytes) return error.PreparedCapacityExceeded;
    const allocator = parent.allocator;
    const state = try allocator.create(PreparedState);
    errdefer allocator.destroy(state);
    const mask = try allocator.alloc(u8, bytes);
    errdefer allocator.free(mask);
    @memset(mask, 0);
    state.* = .{ .lease = drawing.Lease.init(parent.owner), .layout = parent, .native_layout = ztl_native_layout(&parent.native).?, .native_coverage = null, .coverage = .{ .pixels = mask, .width = width, .height = height, .stride = stride, .origin_x = @intFromFloat(edges[0]), .origin_y = @intFromFloat(edges[1]), .scale = scale }, .clip = options.viewport, .stats = undefined };
    try nativeResult(ztl_prepare(&state.native, &parent.native, scale, state.coverage.origin_x, state.coverage.origin_y, width, height, stride, mask.ptr, if (options.viewport) |*r| r else null, &engine.last_error));
    state.native_coverage = ztl_native_coverage(&state.native);
    state.stats = .{ .owned_bytes = owned_bytes, .peak_plane_bytes = owned_bytes + native_plane_bytes, .pixels = pixels, .elapsed_ns = if (timer) |*t| t.read() else null };
    parent.prepared_count += 1;
    return @ptrCast(state);
}

test "word partition query uses logical affinity without scanning text" {
    const ends = [_]u32{ 2, 7, 10, 14, 15 };
    try std.testing.expectEqualDeep(@as(ByteRange, .{ .start = 0, .end = 2 }), wordRangeAtEnds(&ends, 0, false));
    try std.testing.expectEqualDeep(@as(ByteRange, .{ .start = 0, .end = 2 }), wordRangeAtEnds(&ends, 2, false));
    try std.testing.expectEqualDeep(@as(ByteRange, .{ .start = 2, .end = 7 }), wordRangeAtEnds(&ends, 2, true));
    for ([_]bool{ false, true }) |downstream| {
        try std.testing.expectEqualDeep(@as(ByteRange, .{ .start = 2, .end = 7 }), wordRangeAtEnds(&ends, 4, downstream));
        try std.testing.expectEqualDeep(@as(ByteRange, .{ .start = 14, .end = 15 }), wordRangeAtEnds(&ends, 15, downstream));
    }
    const map = [_]Scalar{ .{ .bytes = 0, .utf16 = 0 }, .{ .bytes = 1, .utf16 = 1 }, .{ .bytes = 5, .utf16 = 3 }, .{ .bytes = 6, .utf16 = 4 } };
    const positions = [_]u32{ 0, 1, nativePosition(map[2]), nativePosition(map[3]) };
    try validateWordPositions(&map, &positions);
    try std.testing.expectError(error.NativeLayoutFailed, validateWordPositions(&map, &.{ 0, 2, nativePosition(map[3]) }));
    try std.testing.expectError(error.NativeLayoutFailed, validateWordPositions(&map, &.{ 0, 1, 1, nativePosition(map[3]) }));
    try std.testing.expectError(error.NativeLayoutFailed, validateWordPositions(&map, &.{ 0, 1 }));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(WordIndex));
}
test "layout options limits and scalar coordinate boundaries are explicit" {
    try (Limits{}).validate();
    try std.testing.expectError(error.InvalidLimits, (Limits{ .graphemes = 0 }).validate());
    try (Options{}).validate();
    try std.testing.expectError(error.InvalidOptions, (Options{ .wrap = .word }).validate());
    try std.testing.expectError(error.InvalidOptions, (Options{ .size = std.math.nan(f32) }).validate());
    const map = [_]Scalar{ .{ .bytes = 0, .utf16 = 0 }, .{ .bytes = 1, .utf16 = 1 }, .{ .bytes = 5, .utf16 = 3 }, .{ .bytes = 8, .utf16 = 4 } };
    try std.testing.expectEqual(2, try findScalar(&map, 5, .bytes));
    try std.testing.expectError(error.InvalidTextBoundary, findScalar(&map, 2, .utf16));
    try std.testing.expectError(error.InvalidTextBoundary, findScalar(&map, 4, .bytes));
    try std.testing.expectError(error.InvalidUtf8, validateText("\xff"));
    try std.testing.expectError(error.EmbeddedNul, validateText("a\x00b"));
}
