const std = @import("std");
const zio = @import("ziggurat_io");
const vector = @import("ziggurat_vector");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const path = try vector.Path.parseData(allocator, "M2 16C2 7 7 2 16 2A14 14 0 0 1 30 16C30 25 25 30 16 30A14 14 0 0 1 2 16Z M11 10L23 16L11 22Z", .{});
    defer path.close() catch unreachable;
    std.debug.print("vector prepare median7: allocator=page, four-by-four samples; excludes parse, close, upload and display\n", .{});
    for ([_]f32{ 32, 128, 512 }) |side| for ([_]f32{ 1, 2 }) |scale| for ([_]bool{ false, true }) |stroke| {
        const options: vector.PrepareOptions = .{
            .main_thread = std.Thread.getCurrentId(),
            .viewport = .{ .width = side, .height = side },
            .scale = scale,
            .transform = .{ .xx = side / 32, .yy = side / 32 },
            .style = if (stroke) .{ .stroke = .{ .width = 1.2, .cap = .round, .join = .round } } else .{ .fill = .even_odd },
        };
        const warm = try path.prepare(allocator, options);
        try warm.close();
        var samples: [7]u64 = undefined;
        var metrics: vector.Stats = undefined;
        for (&samples) |*sample| {
            var clock = try zio.Timer.start();
            const prepared = try path.prepare(allocator, options);
            sample.* = clock.read();
            metrics = try prepared.stats();
            try prepared.close();
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.debug.print("side_dip={d} scale={d} style={s} prepare_ns={d} owned={d} peak={d} vertices={d} edges={d} attempts_per_pass={d} scan_tests={d}\n", .{ side, scale, if (stroke) "round-stroke" else "even-odd", samples[3], metrics.owned_bytes, metrics.prepare_peak_bytes, metrics.vertices, metrics.edges, metrics.edge_attempts, metrics.scan_tests });
    };
}
