const std = @import("std");
const api = @import("root.zig");
const kernel = @import("geometry_kernel.zig");
const Point = kernel.Point;
const Contour = kernel.Contour;
const Edge = kernel.Edge;
const Flat = kernel.Flat;
const Edges = kernel.Edges;
pub const Crossing = struct { x: f64, winding: i32 };

// Preparation-only geometry; ordinary A8 preparation does not create a cache.
// A compiled object owns its edges; row caches borrow it with an explicit pin.
pub const Options = struct {
    transform: api.Transform = .{},
    stroke_output: ?*const api.Transform = null,
    style: api.Style = .{ .fill = .nonzero },
    scale: f32 = 1,
    tolerance: f64 = 0.125,
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    limits: api.PrepareLimits = .{},
    cancellation: ?*const api.Cancellation = null,

    fn native(self: Options) api.PrepareOptions {
        return .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 1, .height = 1 }, .transform = self.transform, .stroke_output = self.stroke_output, .style = self.style, .scale = self.scale, .tolerance = self.tolerance, .limits = self.limits, .cancellation = self.cancellation };
    }
};
pub const Metrics = struct {
    vertices: usize,
    edges: usize,
    edge_attempts: u64,
    stroke_steps: u64,
    owned_bytes: usize,
    peak_bytes: usize,
};
pub const Geometry = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    edges: []const Edge,
    even_odd: bool,
    bounds: ?api.Bounds,
    metrics: Metrics,
    row_users: usize = 0,

    pub fn checkOwner(self: *const Geometry) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    pub fn stats(self: *const Geometry) !Metrics {
        try self.checkOwner();
        return self.metrics;
    }
    pub fn close(self: *Geometry) !void {
        try self.checkOwner();
        if (self.row_users != 0) return error.ResourceInUse;
        const allocator = self.allocator;
        allocator.free(self.edges);
        allocator.destroy(self);
    }
};
fn addBytes(total: *usize, count: usize, size: usize, limit: usize) !void {
    if (count > (limit -| total.*) / size) return error.CapacityExceeded;
    total.* += count * size;
    if (total.* > limit) return error.CapacityExceeded;
}
pub fn compile(path: *const api.Path, allocator: std.mem.Allocator, options: Options) !*Geometry {
    try path.checkOwner();
    try options.limits.validate();
    try options.transform.validate();
    if (options.stroke_output) |output| {
        if (options.style != .stroke or options.style.stroke.space != .transformed) return error.InvalidStrokeSpace;
        try output.validate();
    }
    if (!std.math.isFinite(options.scale) or options.scale < 0.0625 or options.scale > 16) return error.InvalidScale;
    if (!std.math.isFinite(options.tolerance) or options.tolerance < 0.015625 or options.tolerance > 1) return error.InvalidTolerance;
    if (options.style == .stroke) try options.style.stroke.validate();
    const output_value: ?api.Transform = if (options.stroke_output) |output| output.* else null;
    var native = options.native();
    native.stroke_output = if (output_value) |*output| output else null;
    try native.check();
    var flat: Flat = .{ .options = native };
    try flat.flatten(path.commands);
    var peak: usize = @sizeOf(Geometry);
    try addBytes(&peak, flat.count, @sizeOf(Point), options.limits.bytes);
    try addBytes(&peak, flat.contour_count, @sizeOf(Contour), options.limits.bytes);
    const points = try allocator.alloc(Point, flat.count);
    defer allocator.free(points);
    const contours = try allocator.alloc(Contour, flat.contour_count);
    defer allocator.free(contours);
    flat = .{ .points = points, .contours = contours, .options = native };
    try flat.flatten(path.commands);
    var edges: Edges = .{ .options = native, .left = @floatFromInt(options.origin_x), .top = @floatFromInt(options.origin_y) };
    try edges.build(points, contours);
    try addBytes(&peak, edges.count, @sizeOf(Edge), options.limits.bytes);
    const storage = try allocator.alloc(Edge, edges.count);
    errdefer allocator.free(storage);
    edges.storage = storage;
    edges.count = 0;
    edges.attempts = 0;
    edges.stroke_work = 0;
    try edges.build(points, contours);
    var minimum: Point = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
    var maximum: Point = .{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) };
    for (storage) |edge| {
        minimum.x = @min(minimum.x, edge.a.x, edge.b.x);
        minimum.y = @min(minimum.y, edge.a.y, edge.b.y);
        maximum.x = @max(maximum.x, edge.a.x, edge.b.x);
        maximum.y = @max(maximum.y, edge.a.y, edge.b.y);
    }
    try native.check();
    const result = try allocator.create(Geometry);
    result.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .edges = storage, .even_odd = options.style == .fill and options.style.fill == .even_odd, .bounds = if (storage.len == 0) null else .{ .x = minimum.x, .y = minimum.y, .width = maximum.x - minimum.x, .height = maximum.y - minimum.y }, .metrics = .{ .vertices = flat.count, .edges = storage.len, .edge_attempts = edges.attempts, .stroke_steps = edges.stroke_work, .owned_bytes = @sizeOf(Geometry) + storage.len * @sizeOf(Edge), .peak_bytes = peak } };
    return result;
}

// One scan test is one edge/subrow test. Sort work counts comparisons.
// Sample work reserves at most seventeen u16 writes per output pixel (clear
// plus sixteen potentially separate sample-bit merges). Heap sort is in-place
// and cancellable: O(C log C), no allocation, C <= charged edges.
pub const Work = struct {
    scan_limit: u64 = 128 * 1024 * 1024,
    sort_limit: u64 = 512 * 1024 * 1024,
    sample_limit: u64 = 128 * 1024 * 1024,
    scan_tests: u64 = 0,
    sort_tests: u64 = 0,
    sample_work: u64 = 0,
    fn scan(self: *Work, amount: u64) !void {
        if (amount > self.scan_limit -| self.scan_tests) return error.ScanBudgetExceeded;
        self.scan_tests += amount;
    }
    fn samples(self: *Work, amount: u64) !void {
        if (amount > self.sample_limit -| self.sample_work) return error.SampleWorkExceeded;
        self.sample_work += amount;
    }
    fn less(self: *Work, a: Crossing, b: Crossing, cancellation: ?*const api.Cancellation) !bool {
        if (self.sort_tests >= self.sort_limit) return error.SortBudgetExceeded;
        if (self.sort_tests % 256 == 0) if (cancellation) |cancel| try cancel.check();
        self.sort_tests += 1;
        return a.x < b.x;
    }
};
pub const Row = struct {
    owner: std.Thread.Id,
    events: [4][]const Crossing,
    even_odd: bool,

    // The result borrows its Rows scratch until the same entry attempts to
    // prepare a different y or Rows closes. Other entries have disjoint ranges.
    pub fn writeSamples(self: Row, x: i32, output: []u16, work: *Work) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (output.len > 16384) return error.CapacityExceeded;
        try work.samples(@as(u64, @intCast(output.len)) * 17);
        @memset(output, 0);
        if (output.len == 0) return;
        const left: f64 = @floatFromInt(x);
        const right = left + @as(f64, @floatFromInt(output.len));
        for (self.events, 0..) |events, sub_y| {
            var low: usize = 0;
            var high = events.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (events[middle].x <= left) low = middle + 1 else high = middle;
            }
            var winding: i32 = if (low == 0) 0 else events[low - 1].winding;
            var previous = left;
            var index = low;
            while (previous < right) {
                const end = if (index < events.len) @min(events[index].x, right) else right;
                if ((if (self.even_odd) @mod(winding, 2) != 0 else winding != 0) and end > previous) addBits(output, @intCast(sub_y * 4), previous - left, end - left);
                if (index == events.len or end == right) break;
                previous = events[index].x;
                winding = events[index].winding;
                index += 1;
            }
        }
    }
};
fn addBits(output: []u16, shift: u4, left: f64, right: f64) void {
    const maximum = @as(f64, @floatFromInt(output.len * 4));
    var start: usize = @intFromFloat(std.math.clamp(@ceil(left * 4 - 0.5), 0, maximum));
    const end: usize = @intFromFloat(std.math.clamp(@ceil(right * 4 - 0.5), 0, maximum));
    while (start < end and start % 4 != 0) : (start += 1) output[start / 4] |= @as(u16, 1) << (shift + @as(u4, @intCast(start % 4)));
    while (end - start >= 4) : (start += 4) output[start / 4] |= @as(u16, 15) << shift;
    while (start < end) : (start += 1) output[start / 4] |= @as(u16, 1) << (shift + @as(u4, @intCast(start % 4)));
}
fn siftCrossings(buffer: []Crossing, start: usize, work: *Work, cancellation: ?*const api.Cancellation) !void {
    var root = start;
    while (root < buffer.len / 2) {
        var child = root * 2 + 1;
        if (child + 1 < buffer.len and try work.less(buffer[child], buffer[child + 1], cancellation)) child += 1;
        if (!try work.less(buffer[root], buffer[child], cancellation)) return;
        std.mem.swap(Crossing, &buffer[root], &buffer[child]);
        root = child;
    }
}
fn sortCrossings(buffer: []Crossing, work: *Work, cancellation: ?*const api.Cancellation) !void {
    var start = buffer.len / 2;
    while (start != 0) {
        start -= 1;
        try siftCrossings(buffer, start, work, cancellation);
    }
    var end = buffer.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Crossing, &buffer[0], &buffer[end]);
        try siftCrossings(buffer[0..end], 0, work, cancellation);
    }
}
const Entry = struct { geometry: *Geometry, offset: usize, y: ?i32 = null, row: Row = undefined };
pub const Rows = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    entries: []Entry,
    scratch: []Crossing,
    owned_bytes: usize,

    // The limit includes ALL entries' four-subrow scratch, even when their
    // bounds do not meet the current row. The scene adds geometry and pixel
    // storage to this exact byte count under its one aggregate peak budget.
    pub fn create(allocator: std.mem.Allocator, geometries: []const *Geometry, byte_limit: usize) !*Rows {
        if (geometries.len > 65536) return error.CapacityExceeded;
        var bytes: usize = @sizeOf(Rows);
        try addBytes(&bytes, geometries.len, @sizeOf(Entry), byte_limit);
        var count: usize = 0;
        for (geometries) |geometry| {
            try geometry.checkOwner();
            // A caller may list one geometry more than once. Reserve enough
            // pin headroom for every entry before any pin is committed.
            if (geometry.row_users > std.math.maxInt(usize) - geometries.len) return error.CapacityExceeded;
            try addBytes(&bytes, geometry.edges.len, 4 * @sizeOf(Crossing), byte_limit);
            count += geometry.edges.len * 4;
        }
        const entries = try allocator.alloc(Entry, geometries.len);
        errdefer allocator.free(entries);
        const scratch = try allocator.alloc(Crossing, count);
        errdefer allocator.free(scratch);
        const result = try allocator.create(Rows);
        var offset: usize = 0;
        for (entries, geometries) |*entry, geometry| {
            entry.* = .{ .geometry = geometry, .offset = offset };
            offset += geometry.edges.len * 4;
            geometry.row_users += 1;
        }
        result.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .entries = entries, .scratch = scratch, .owned_bytes = bytes };
        return result;
    }
    fn checkOwner(self: *const Rows) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    pub fn stats(self: *const Rows) !usize {
        try self.checkOwner();
        return self.owned_bytes;
    }
    pub fn prepare(self: *Rows, index: usize, y: i32, work: *Work, cancellation: ?*const api.Cancellation) !Row {
        try self.checkOwner();
        if (index >= self.entries.len) return error.InvalidGeometryIndex;
        if (cancellation) |cancel| try cancel.check();
        const entry = &self.entries[index];
        if (entry.y == y) return entry.row;
        const geometry = entry.geometry;
        const bounds = geometry.bounds;
        var row: Row = .{ .owner = self.owner, .events = @splat(&.{}), .even_odd = geometry.even_odd };
        if (bounds) |box| {
            const top: f64 = @floatFromInt(y);
            if (top < box.y + box.height and top + 1 > box.y) {
                try work.scan(@as(u64, @intCast(geometry.edges.len)) * 4);
                // Invalidate before touching borrowed scratch. Cancellation may
                // leave private scratch partial, but never publishes a Row.
                entry.y = null;
                for (0..4) |sub_y| {
                    const ordinate = top + (@as(f64, @floatFromInt(sub_y)) + 0.5) / 4;
                    const buffer = self.scratch[entry.offset + sub_y * geometry.edges.len ..][0..geometry.edges.len];
                    var count: usize = 0;
                    for (geometry.edges, 0..) |edge, edge_index| {
                        if (edge_index % 256 == 0) if (cancellation) |cancel| try cancel.check();
                        if (ordinate < @min(edge.a.y, edge.b.y) or ordinate >= @max(edge.a.y, edge.b.y)) continue;
                        buffer[count] = .{ .x = edge.a.x + (ordinate - edge.a.y) / (edge.b.y - edge.a.y) * (edge.b.x - edge.a.x), .winding = if (edge.b.y > edge.a.y) 1 else -1 };
                        count += 1;
                    }
                    try sortCrossings(buffer[0..count], work, cancellation);
                    var read: usize = 0;
                    var write: usize = 0;
                    var winding: i32 = 0;
                    while (read < count) {
                        const x = buffer[read].x;
                        while (read < count and buffer[read].x == x) : (read += 1) winding += buffer[read].winding;
                        buffer[write] = .{ .x = x, .winding = winding };
                        write += 1;
                    }
                    row.events[sub_y] = buffer[0..write];
                }
            }
        }
        if (cancellation) |cancel| try cancel.check();
        entry.row = row;
        entry.y = y;
        return row;
    }
    pub fn close(self: *Rows) !void {
        try self.checkOwner();
        for (self.entries) |entry| entry.geometry.row_users -= 1;
        const allocator = self.allocator;
        allocator.free(self.scratch);
        allocator.free(self.entries);
        allocator.destroy(self);
    }
};
