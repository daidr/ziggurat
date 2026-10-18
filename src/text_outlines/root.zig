const std = @import("std");
const text = @import("ziggurat_text_layout");
const vector = @import("ziggurat_vector");

pub const Limits = struct { glyphs: usize = 8192, commands: usize = 65536, bytes: usize = 16 * 1024 * 1024, clusters: usize = 8192, work: u64 = 4 * 1024 * 1024 };
pub const Options = struct { limits: Limits = .{}, include_cells: bool = false, include_mapping: bool = false, cancellation: ?*const vector.Cancellation = null };
pub const Stats = struct { glyphs: u32, commands: usize, cells: usize = 0, first_baseline: f64, advance: f64, owned_bytes: usize, peak_owned_bytes: usize, mapped_commands: usize = 0, clusters: usize = 0, mapping_work: u64 = 0 };
pub const Glyph = text.outlines.Glyph;
pub const Cluster = text.outlines.Cluster;
pub const OwnedGeometry = struct { path: *vector.Path, cells: []vector.Bounds };

/// Explicit preparation bridge. The native layout is queried for its original
/// glyph contours; the independent Path keeps no layout/font/native reference.
pub fn fromLayout(layout: *text.Layout, allocator: std.mem.Allocator, options: Options) !*Shape {
    // This query establishes the layout owner before reading any other input.
    _ = try layout.metrics();
    if (options.limits.glyphs == 0 or options.limits.glyphs > 65536 or options.limits.commands == 0 or options.limits.commands > 65536 or options.limits.bytes == 0 or options.limits.bytes > 64 * 1024 * 1024) return error.InvalidOutlineLimits;
    try check(options);
    var budget: Budget = .{ .child = allocator, .limit = options.limits.bytes };
    return create(layout, &budget, options) catch |err| return if (err == error.OutlineCapacityExceeded or (err == error.OutOfMemory and budget.denied)) error.CapacityExceeded else err;
}
fn create(layout: *text.Layout, budget: *Budget, options: Options) !*Shape {
    const allocator = budget.allocator();
    const snapshot = try layout.outline(allocator, .{ .limits = .{ .glyphs = options.limits.glyphs, .commands = options.limits.commands, .bytes = @min(options.limits.bytes, 16 * 1024 * 1024), .clusters = options.limits.clusters, .work = options.limits.work }, .include_cells = options.include_cells, .include_mapping = options.include_mapping, .cancellation = if (options.cancellation) |cancel| &cancel.requested else null });
    var snapshot_alive = true;
    defer if (snapshot_alive) snapshot.close() catch unreachable;
    const metrics = try snapshot.metrics();
    const segments = try snapshot.segments();
    var mapping_work = metrics.mapping_work;
    if (options.include_mapping) {
        const value = (try snapshot.mapping()).?;
        // Conversion and the independent Path copy share the same job work
        // quota; opting in does not issue a second complete allowance.
        try work(&mapping_work, @as(u64, segments.len) * 2 + @as(u64, value.mapped_segments.len) * 2 + value.source.len + value.glyphs.len + value.clusters.len, options.limits.work);
    }
    const commands = try allocator.alloc(vector.Command, segments.len);
    var commands_alive = true;
    defer if (commands_alive) allocator.free(commands);
    for (segments, commands, 0..) |segment, *command, i| {
        if (i % 256 == 0) try check(options);
        command.* = switch (segment.kind) {
            .move => .{ .move = point(segment.points[0]) },
            .line => .{ .line = point(segment.points[0]) },
            .cubic => .{ .cubic = .{ .first = point(segment.points[0]), .second = point(segment.points[1]), .end = point(segment.points[2]) } },
            .close => .close,
        };
    }
    const path = try vector.Path.create(allocator, commands, .{ .commands = options.limits.commands, .bytes = @min(options.limits.bytes, 16 * 1024 * 1024) });
    errdefer path.close() catch unreachable;
    const source_cells = try snapshot.cells();
    const cell_values = try allocator.alloc(vector.Bounds, source_cells.len);
    errdefer allocator.free(cell_values);
    for (source_cells, cell_values) |cell, *value| value.* = .{ .x = cell.x, .y = cell.y, .width = cell.width, .height = cell.height };
    const mapping = if (try snapshot.mapping()) |value| try createMapping(value, allocator, options) else null;
    errdefer if (mapping) |value| closeMapping(value);
    try check(options);
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    const command_count = segments.len;
    // Every foreign temporary destructor runs while the independent output is
    // still a candidate. A cancellation raised by final scratch free must not
    // publish a new Shape. No foreign operation follows the final check.
    commands_alive = false;
    allocator.free(commands);
    snapshot_alive = false;
    snapshot.close() catch unreachable;
    try check(options);
    const owned = @sizeOf(State) + @sizeOf(vector.Path) + path.commands.len * @sizeOf(vector.Command) + cell_values.len * @sizeOf(vector.Bounds) + if (mapping) |value| value.owned_bytes else @as(usize, 0);
    state.* = .{ .allocator = budget.child, .owner = std.Thread.getCurrentId(), .path = path, .cells = cell_values, .mapping = mapping, .stats = .{
        .glyphs = metrics.glyphs,
        .commands = command_count,
        .cells = cell_values.len,
        .first_baseline = metrics.first_baseline,
        .advance = metrics.advance,
        .owned_bytes = owned,
        .peak_owned_bytes = budget.peak,
        .mapped_commands = metrics.mapped_commands,
        .clusters = metrics.clusters,
        .mapping_work = mapping_work,
    } };
    // Only these exact output allocations escape the temporary accounting
    // context. Scratch has already been released before publication.
    path.allocator = budget.child;
    if (mapping) |value| {
        value.allocator = budget.child;
        value.path.allocator = budget.child;
    }
    std.debug.assert(budget.live == owned);
    budget.live = 0;
    return @ptrCast(state);
}
pub const Shape = opaque {
    /// Borrowed independent mapping. Its segment ranges index only its path.
    /// Borrow ends at takeMapping, close, takePath or takeGeometry.
    pub fn mapping(self: *const Shape) !?*const Mapping {
        const state = cast(@constCast(self));
        try state.check();
        return if (state.mapping) |value| @ptrCast(value) else null;
    }
    /// Transfer the mapping's own path, source and metadata without consuming
    /// the batch Shape. It must subsequently be closed exactly once.
    pub fn takeMapping(self: *Shape) !*Mapping {
        const state = cast(self);
        try state.check();
        const value = state.mapping orelse return error.MappingNotRequested;
        state.mapping = null;
        state.stats.owned_bytes -= value.owned_bytes;
        state.stats.mapped_commands = 0;
        state.stats.clusters = 0;
        return @ptrCast(value);
    }
    pub fn cells(self: *const Shape) ![]const vector.Bounds {
        const state = cast(@constCast(self));
        try state.check();
        return state.cells;
    }
    /// Borrowed until close. The path coordinates have the layout's origin;
    /// translate by -first_baseline to place the first alphabetic baseline at 0.
    pub fn path(self: *const Shape) !*const vector.Path {
        const state = cast(@constCast(self));
        try state.check();
        return state.path;
    }
    pub fn stats(self: *const Shape) !Stats {
        const state = cast(@constCast(self));
        try state.check();
        return state.stats;
    }
    /// Transfers the independent owning path and consumes this Shape shell.
    /// Existing path borrows end; the returned owner must close the path once.
    pub fn takePath(self: *Shape) !*vector.Path {
        const state = cast(self);
        try state.check();
        state.closing = true;
        const allocator = state.allocator;
        const owned_path = state.path;
        const mapping_value = state.mapping;
        allocator.free(state.cells);
        if (mapping_value) |value| closeMapping(value);
        allocator.destroy(state);
        return owned_path;
    }
    /// Transfers path and per-glyph cells, consuming this shell. Both use
    /// path.allocator. Free the cells and close the path exactly once.
    pub fn takeGeometry(self: *Shape) !OwnedGeometry {
        const state = cast(self);
        try state.check();
        state.closing = true;
        const allocator = state.allocator;
        const result: OwnedGeometry = .{ .path = state.path, .cells = state.cells };
        if (state.mapping) |value| closeMapping(value);
        allocator.destroy(state);
        return result;
    }
    pub fn close(self: *Shape) !void {
        const state = cast(self);
        try state.check();
        state.closing = true;
        const allocator = state.allocator;
        allocator.free(state.cells);
        if (state.mapping) |value| closeMapping(value);
        try state.path.close();
        allocator.destroy(state);
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    path: *vector.Path,
    cells: []vector.Bounds,
    stats: Stats,
    mapping: ?*MappingState = null,
    closing: bool = false,
    fn check(self: *const State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
    }
};
/// Owning, immutable per-glyph native outline snapshot. This path is separate
/// from Shape.path: glyph/cluster mapped_segments index this path exclusively.
pub const Mapping = opaque {
    pub fn path(self: *const Mapping) !*const vector.Path {
        const state = mappingCast(@constCast(self));
        try state.check();
        return state.path;
    }
    pub fn source(self: *const Mapping) ![]const u8 {
        const state = mappingCast(@constCast(self));
        try state.check();
        return state.source;
    }
    pub fn glyphs(self: *const Mapping) ![]const Glyph {
        const state = mappingCast(@constCast(self));
        try state.check();
        return state.glyphs;
    }
    pub fn clusters(self: *const Mapping) ![]const Cluster {
        const state = mappingCast(@constCast(self));
        try state.check();
        return state.clusters;
    }
    pub fn ownedBytes(self: *const Mapping) !usize {
        const state = mappingCast(@constCast(self));
        try state.check();
        return state.owned_bytes;
    }
    pub fn close(self: *Mapping) !void {
        const state = mappingCast(self);
        try state.check();
        closeMapping(state);
    }
};
const MappingState = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    source: []u8,
    glyphs: []Glyph,
    clusters: []Cluster,
    path: *vector.Path,
    owned_bytes: usize,
    closing: bool = false,
    fn check(self: *const MappingState) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
    }
};
fn mappingCast(value: *Mapping) *MappingState {
    return @ptrCast(@alignCast(value));
}
fn closeMapping(state: *MappingState) void {
    state.closing = true;
    const allocator = state.allocator;
    const source = state.source;
    const glyphs = state.glyphs;
    const clusters = state.clusters;
    const path_value = state.path;
    allocator.free(source);
    allocator.free(glyphs);
    allocator.free(clusters);
    path_value.close() catch unreachable;
    allocator.destroy(state);
}
fn createMapping(value: text.outlines.MappingView, allocator: std.mem.Allocator, options: Options) !*MappingState {
    const source = try allocator.dupe(u8, value.source);
    errdefer allocator.free(source);
    const glyphs = try allocator.dupe(Glyph, value.glyphs);
    errdefer allocator.free(glyphs);
    const clusters = try allocator.dupe(Cluster, value.clusters);
    errdefer allocator.free(clusters);
    const commands = try allocator.alloc(vector.Command, value.mapped_segments.len);
    var commands_alive = true;
    defer if (commands_alive) allocator.free(commands);
    for (value.mapped_segments, commands, 0..) |segment, *command, i| {
        if (i % 256 == 0) try check(options);
        command.* = switch (segment.kind) {
            .move => .{ .move = point(segment.points[0]) },
            .line => .{ .line = point(segment.points[0]) },
            .cubic => .{ .cubic = .{ .first = point(segment.points[0]), .second = point(segment.points[1]), .end = point(segment.points[2]) } },
            .close => .close,
        };
    }
    const path_value = try vector.Path.create(allocator, commands, .{ .commands = options.limits.commands, .bytes = @min(options.limits.bytes, 16 * 1024 * 1024) });
    errdefer path_value.close() catch unreachable;
    commands_alive = false;
    allocator.free(commands);
    try check(options);
    const state = try allocator.create(MappingState);
    errdefer allocator.destroy(state);
    try check(options);
    state.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .source = source, .glyphs = glyphs, .clusters = clusters, .path = path_value, .owned_bytes = @sizeOf(MappingState) + @sizeOf(vector.Path) + source.len + glyphs.len * @sizeOf(Glyph) + clusters.len * @sizeOf(Cluster) + path_value.commands.len * @sizeOf(vector.Command) };
    return state;
}
fn cast(shape: *Shape) *State {
    return @ptrCast(@alignCast(shape));
}
fn check(options: Options) !void {
    if (options.cancellation) |cancel| try cancel.check();
}
fn work(current: *u64, amount: u64, limit: u64) !void {
    if (amount > limit -| current.*) return error.OutlineWorkExceeded;
    current.* += amount;
}
fn point(value: text.outlines.Point) vector.Point {
    return .{ .x = value.x, .y = value.y };
}
const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (length > self.limit -| self.live) {
            self.denied = true;
            return null;
        }
        const bytes = self.child.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        self.peak = @max(self.peak, self.live);
        return bytes;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.child.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};
