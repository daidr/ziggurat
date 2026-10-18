const std = @import("std");
const api = @import("root.zig");
const kernel = @import("geometry_kernel.zig");
const Point = kernel.Point;
const Contour = kernel.Contour;
const Edge = kernel.Edge;
const Flat = kernel.Flat;
const Edges = kernel.Edges;
const Crossing = struct { x: f64, winding: i32 };

fn addBytes(total: *usize, count: usize, size: usize, limit: usize) !void {
    if (count > (limit -| total.*) / size) return error.CapacityExceeded;
    total.* += count * size;
    if (total.* > limit) return error.CapacityExceeded;
}

pub fn prepare(path: *const api.Path, allocator: std.mem.Allocator, options: api.PrepareOptions) !*api.Prepared {
    try options.check();
    const viewport = options.viewport;
    const scale: f64 = options.scale;
    if (!std.math.isFinite(scale) or scale < 0.0625 or scale > 16 or !std.math.isFinite(viewport.x) or !std.math.isFinite(viewport.y) or !std.math.isFinite(viewport.width) or !std.math.isFinite(viewport.height) or viewport.width <= 0 or viewport.height <= 0) return error.InvalidViewport;
    const left = @floor(@as(f64, viewport.x) * scale);
    const top = @floor(@as(f64, viewport.y) * scale);
    const right = @ceil((@as(f64, viewport.x) + viewport.width) * scale);
    const bottom = @ceil((@as(f64, viewport.y) + viewport.height) * scale);
    if (left < std.math.minInt(i32) or top < std.math.minInt(i32) or right > std.math.maxInt(i32) or bottom > std.math.maxInt(i32) or right - left > 16384 or bottom - top > 16384) return error.CapacityExceeded;
    const width: u32 = @intFromFloat(right - left);
    const height: u32 = @intFromFloat(bottom - top);
    if (width == 0 or height == 0) return error.UnrepresentableViewport;
    const stride = (width + 3) & ~@as(u32, 3);
    const pixels = @as(usize, stride) * height;
    if (pixels > 16 * 1024 * 1024) return error.CapacityExceeded;
    var flat: Flat = .{ .options = options };
    try flat.flatten(path.commands);
    var peak: usize = @sizeOf(api.Prepared);
    try addBytes(&peak, pixels, 1, options.limits.bytes);
    if (options.retain_samples) try addBytes(&peak, pixels, @sizeOf(u16), options.limits.bytes);
    try addBytes(&peak, flat.count, @sizeOf(Point), options.limits.bytes);
    try addBytes(&peak, flat.contour_count, @sizeOf(Contour), options.limits.bytes);
    const points = try allocator.alloc(Point, flat.count);
    defer allocator.free(points);
    const contours = try allocator.alloc(Contour, flat.contour_count);
    defer allocator.free(contours);
    flat = .{ .points = points, .contours = contours, .options = options };
    try flat.flatten(path.commands);
    var edges: Edges = .{ .options = options, .left = left, .top = top };
    try edges.build(points, contours);
    const scan_tests = @as(u64, height) * 4 * edges.count;
    if (scan_tests > options.limits.scan_tests) return error.ScanBudgetExceeded;
    try addBytes(&peak, edges.count, @sizeOf(Edge) + @sizeOf(Crossing), options.limits.bytes);
    try addBytes(&peak, width, 1, options.limits.bytes);
    const storage = try allocator.alloc(Edge, edges.count);
    defer allocator.free(storage);
    const crossings = try allocator.alloc(Crossing, edges.count);
    defer allocator.free(crossings);
    const row = try allocator.alloc(u8, width);
    defer allocator.free(row);
    const output = try allocator.alloc(u8, pixels);
    errdefer allocator.free(output);
    const samples = try allocator.alloc(u16, if (options.retain_samples) pixels else 0);
    errdefer allocator.free(samples);
    @memset(samples, 0);
    @memset(output, 0);
    edges = .{ .options = options, .left = left, .top = top, .storage = storage };
    try edges.build(points, contours);
    const even_odd = switch (options.style) {
        .fill => |rule| rule == .even_odd,
        .stroke => false,
    };
    const clip_left = @as(f64, viewport.x) * scale - left;
    const clip_top = @as(f64, viewport.y) * scale - top;
    const clip_right = (@as(f64, viewport.x) + viewport.width) * scale - left;
    const clip_bottom = (@as(f64, viewport.y) + viewport.height) * scale - top;
    for (0..height) |y| {
        try options.check();
        @memset(row, 0);
        for (0..4) |sub_y| {
            const ordinate = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sub_y)) + 0.5) / 4;
            if (ordinate < clip_top or ordinate >= clip_bottom) continue;
            var count: usize = 0;
            for (storage) |edge| {
                const low = @min(edge.a.y, edge.b.y);
                const high = @max(edge.a.y, edge.b.y);
                if (ordinate < low or ordinate >= high) continue;
                crossings[count] = .{ .x = edge.a.x + (ordinate - edge.a.y) / (edge.b.y - edge.a.y) * (edge.b.x - edge.a.x), .winding = if (edge.b.y > edge.a.y) 1 else -1 };
                count += 1;
            }
            std.mem.sort(Crossing, crossings[0..count], {}, struct {
                fn less(_: void, a: Crossing, b: Crossing) bool {
                    return a.x < b.x;
                }
            }.less);
            var winding: i32 = 0;
            var previous: f64 = 0;
            var index: usize = 0;
            while (index < count) {
                const current = crossings[index].x;
                if ((if (even_odd) @mod(winding, 2) != 0 else winding != 0) and current > previous) addSpan(row, if (options.retain_samples) samples[y * stride ..][0..width] else null, @intCast(sub_y * 4), @max(previous, clip_left), @min(current, clip_right));
                // Exact coincident crossings are a single topological event.
                while (index < count and crossings[index].x == current) : (index += 1) winding += crossings[index].winding;
                previous = current;
            }
        }
        for (row, 0..) |covered, x| output[y * stride + x] = @intCast((@as(u16, covered) * 255 + 8) / 16);
    }
    try options.check();
    const prepared = try allocator.create(api.Prepared);
    errdefer allocator.destroy(prepared);
    prepared.* = .{
        .allocator = allocator,
        .lease = api.drawing.Lease.init(std.Thread.getCurrentId()),
        .main_thread = options.main_thread,
        .adopted = std.Thread.getCurrentId() == options.main_thread,
        .identity = try api.drawing.reserveRasterIdentity(),
        .coverage = .{ .pixels = output, .width = width, .height = height, .stride = stride, .origin_x = @intFromFloat(left), .origin_y = @intFromFloat(top), .scale = options.scale },
        .samples = samples,
        .metrics = .{ .commands = path.commands.len, .vertices = flat.count, .edges = edges.count, .edge_attempts = edges.attempts, .stroke_steps = edges.stroke_work, .owned_bytes = @sizeOf(api.Prepared) + output.len + samples.len * @sizeOf(u16), .prepare_peak_bytes = peak, .scan_tests = scan_tests },
    };
    return prepared;
}

fn addSpan(row: []u8, samples: ?[]u16, shift: u4, left: f64, right: f64) void {
    if (right <= left) return;
    const maximum = @as(f64, @floatFromInt(row.len * 4));
    var start: usize = @intFromFloat(std.math.clamp(@ceil(left * 4 - 0.5), 0, maximum));
    const end: usize = @intFromFloat(std.math.clamp(@ceil(right * 4 - 0.5), 0, maximum));
    while (start < end and start % 4 != 0) : (start += 1) {
        row[start / 4] += 1;
        if (samples) |bits| bits[start / 4] |= @as(u16, 1) << (shift + @as(u4, @intCast(start % 4)));
    }
    while (end - start >= 4) : (start += 4) {
        row[start / 4] += 4;
        if (samples) |bits| bits[start / 4] |= @as(u16, 15) << shift;
    }
    while (start < end) : (start += 1) {
        row[start / 4] += 1;
        if (samples) |bits| bits[start / 4] |= @as(u16, 1) << (shift + @as(u4, @intCast(start % 4)));
    }
}
