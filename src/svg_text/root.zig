const std = @import("std");
const builtin = @import("builtin");
const svg = @import("ziggurat_svg");
const text = @import("ziggurat_text_layout");
const outlines = @import("ziggurat_text_outlines");

pub const Options = struct { layout: text.Limits = .{} };
pub const Stats = struct { requests: u64, glyphs: u64, commands: u64 };
/// Optional main-thread font adapter for explicit SVG preparation. It keeps
/// one system Engine; all per-request candidates use the scene allocator.
pub const Provider = opaque {
    pub fn create(allocator: std.mem.Allocator, process_main_thread: std.Thread.Id, options: Options) !*Provider {
        if (std.Thread.getCurrentId() != process_main_thread) return error.WrongThread;
        const engine = try text.Engine.create(allocator, process_main_thread, options.layout);
        errdefer engine.close() catch unreachable;
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .owner = process_main_thread, .engine = engine, .lease = svg.text.Lease.init(process_main_thread) };
        return @ptrCast(state);
    }
    pub fn interface(self: *Provider) !svg.text.Provider {
        const state = cast(self);
        try state.check();
        return .{ .context = state, .shape = shape, .lease = &state.lease, .supports_mapping = true };
    }
    pub fn stats(self: *const Provider) !Stats {
        const state = cast(@constCast(self));
        try state.check();
        if (state.busy or state.lease.pins != 0) return error.Busy;
        return .{ .requests = state.requests, .glyphs = state.glyphs, .commands = state.commands };
    }
    pub fn close(self: *Provider) !void {
        const state = cast(self);
        try state.check();
        if (state.busy or state.lease.pins != 0) return error.Busy;
        state.closing = true;
        const allocator = state.allocator;
        try state.engine.close();
        allocator.destroy(state);
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    engine: *text.Engine,
    lease: svg.text.Lease,
    busy: bool = false,
    closing: bool = false,
    requests: u64 = 0,
    glyphs: u64 = 0,
    commands: u64 = 0,
    fn check(self: *const State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
    }
};
fn cast(provider: *Provider) *State {
    return @ptrCast(@alignCast(provider));
}
fn shape(context: *anyopaque, allocator: std.mem.Allocator, request: svg.text.Request) !svg.text.Result {
    const state: *State = @ptrCast(@alignCast(context));
    try state.check();
    if (state.busy) return error.Busy;
    state.busy = true;
    defer state.busy = false;
    if (request.cancellation) |cancel| try cancel.check();
    if (request.max_glyphs == 0 or request.max_commands == 0 or request.max_bytes == 0) return error.TextCapacityExceeded;
    if (request.max_work == 0) return error.TextWorkExceeded;
    if (!std.math.isFinite(request.font.size) or request.font.size < 1 or request.font.size > 512) return error.UnsupportedFontSize;
    const family: []const u8 = switch (request.font.generic) {
        .named => request.font.family,
        .sans_serif => "",
        .serif => if (builtin.os.tag == .windows) "Times New Roman" else "Serif",
        .monospace => if (builtin.os.tag == .windows) "Consolas" else "Monospace",
    };
    const layout = try state.engine.layoutAllocated(allocator, request.utf8, .{
        .family = family,
        .locale = request.font.locale,
        .size = @floatCast(request.font.size),
        .weight = request.font.weight,
        .italic = request.font.italic,
        .direction = if (request.font.direction == .rtl) .rtl else .ltr,
    });
    var layout_alive = true;
    defer if (layout_alive) layout.close() catch unreachable;
    // Unicode separators can create forced lines even with wrapping disabled.
    // The caller supplies one positioned chunk per request. Forced lines need
    // an additional positioning contract rather than a second implicit chunk.
    if ((try layout.metrics()).lines != 1) return error.UnsupportedTextMultiline;
    const output = outlines.fromLayout(layout, allocator, .{ .limits = .{ .glyphs = @min(request.max_glyphs, 65536), .commands = @min(request.max_commands, 65536), .bytes = @min(request.max_bytes, 64 * 1024 * 1024), .work = @min(request.max_work, 256 * 1024 * 1024) }, .include_cells = !request.include_mapping, .include_mapping = request.include_mapping, .cancellation = request.cancellation }) catch |err| return if (err == error.OutlineWorkExceeded) error.TextWorkExceeded else err;
    var output_alive = true;
    defer if (output_alive) output.close() catch unreachable;
    const metrics = try output.stats();
    var mapping: ?*svg.text.Mapping = null;
    errdefer if (mapping) |value| value.close() catch unreachable;
    var consumed = metrics.mapping_work;
    if (request.include_mapping) {
        const original = try output.takeMapping();
        var original_alive = true;
        defer if (original_alive) original.close() catch unreachable;
        const levels = std.math.log2_int_ceil(usize, @max(@as(usize, 1), (try layout.graphemeCount()) + 1)) + 1;
        const extra = @as(u64, metrics.mapped_commands) * 2 + request.utf8.len + (try original.glyphs()).len + (try original.clusters()).len * (2 * levels + 1);
        if (extra > request.max_work -| consumed) return error.TextWorkExceeded;
        consumed += extra;
        mapping = try copyMapping(allocator, layout, original, request);
        original_alive = false;
        try original.close();
    }
    const geometry = try output.takeGeometry();
    output_alive = false;
    errdefer {
        allocator.free(geometry.cells);
        geometry.path.close() catch unreachable;
    }
    layout_alive = false;
    try layout.close();
    if (request.cancellation) |cancel| try cancel.check();
    state.requests +|= 1;
    state.glyphs +|= metrics.glyphs;
    state.commands +|= metrics.commands;
    return .{ .path = geometry.path, .cells = if (request.include_mapping) null else geometry.cells, .mapping = mapping, .work = consumed, .first_baseline = metrics.first_baseline, .advance = metrics.advance, .glyphs = metrics.glyphs };
}

fn copyMapping(a: std.mem.Allocator, layout: *text.Layout, original: *outlines.Mapping, request: svg.text.Request) !*svg.text.Mapping {
    const glyphs = try a.alloc(svg.text.mapping.Glyph, (try original.glyphs()).len);
    errdefer a.free(glyphs);
    for (try original.glyphs(), glyphs) |input, *g| g.* = .{ .commands = .{ .start = input.mapped_segments.start, .count = input.mapped_segments.count }, .cluster = input.cluster, .pen = .{ .x = input.pen.x, .y = input.pen.y }, .advance = input.advance, .cell = .{ .x = input.cell.x, .y = input.cell.y, .width = input.cell.width, .height = input.cell.height } };
    const clusters = try a.alloc(svg.text.mapping.Cluster, (try original.clusters()).len);
    errdefer a.free(clusters);
    for (try original.clusters(), clusters) |input, *cluster| {
        // A native cluster split inside a grapheme is insufficient proof for
        // independently positioning a typographic unit. Keep it explicit.
        if (!try boundary(layout, input.source.start) or !try boundary(layout, input.source.end)) return error.UnsupportedTextPositionCluster;
        cluster.* = .{ .source = .{ .start = input.source.start, .end = input.source.end }, .glyphs = .{ .start = input.glyphs.start, .count = input.glyphs.count }, .commands = .{ .start = input.mapped_segments.start, .count = input.mapped_segments.count }, .bidi_level = input.bidi_level };
    }
    const source = try a.dupe(u8, try original.source());
    errdefer a.free(source);
    const path = try svg.text.mapping.Path.create(a, (try original.path()).commands, .{ .commands = @min(request.max_commands, 65536), .bytes = @min(request.max_bytes, 16 * 1024 * 1024) });
    errdefer path.close() catch unreachable;
    if (request.cancellation) |cancel| try cancel.check();
    return svg.text.Mapping.adopt(a, .{ .path = path, .source = source, .glyphs = glyphs, .clusters = clusters });
}
fn boundary(layout: *text.Layout, byte: usize) !bool {
    var lo: usize = 0;
    var hi = (try layout.graphemeCount()) + 1;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (try layout.graphemeByte(mid) < byte) lo = mid + 1 else hi = mid;
    }
    return lo <= try layout.graphemeCount() and try layout.graphemeByte(lo) == byte;
}
