const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const gaussian = @import("ziggurat_gaussian");
const drawing = ui.drawing;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_layer_test_pixel(*anyopaque, c_int, u32, u32) u32;
extern fn zlc_layer_live_objects() u32;
extern fn zlc_test_live_image_objects() u32;

const source_width = 16;
const source_height = 12;
const target_width = 40;
const target_height = 32;
const sigma: f32 = 1;

fn nativeCount() u32 {
    return if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS) else zlc_layer_live_objects() + zlc_test_live_image_objects();
}
fn pixel(level: drawing.ImageLevel, x: usize, y: usize) u32 {
    const bytes = level.pixels[y * level.stride + x * 4 ..][0..4];
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
}
fn near(expected: u32, actual: u32, label: []const u8, scale: f32, x: usize, y: usize) !u32 {
    var maximum: u32 = 0;
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const a = (expected >> shift) & 255;
        const b = (actual >> shift) & 255;
        const difference = if (a > b) a - b else b - a;
        maximum = @max(maximum, difference);
        if (difference > 1) {
            std.debug.print("gaussian {s} DPI={d} pixel={d},{d} channel={d} expected={x} actual={x} error={d}\n", .{ label, scale, x, y, shift, expected, actual, difference });
            return error.GaussianPixelMismatch;
        }
    }
    return maximum;
}

const Captured = struct { snapshot: *ui.offscreen.Snapshot, work: ?gaussian.Work };
fn composed(allocator: std.mem.Allocator, app: *z.App, processor: ?*gaussian.Processor, scale: f32) !Captured {
    const size: z.Size = .{ .width = @intFromFloat(source_width * scale), .height = @intFromFloat(source_height * scale), .scale = scale };
    var mask_lease = drawing.Lease.init(std.Thread.getCurrentId());
    const mask_pixels = try allocator.alloc(u8, @as(usize, size.width) * size.height);
    defer allocator.free(mask_pixels);
    @memset(mask_pixels, 192);
    const surface = try ui.offscreen.Surface.create(app, allocator, .{ .size = size, .max_depth = 2 });
    var surface_live = true;
    defer if (surface_live) surface.close() catch unreachable;
    const mask: drawing.CoverageView = .{ .lease = &mask_lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = mask_pixels, .width = size.width, .height = size.height, .stride = size.width, .origin_x = 0, .origin_y = 0, .scale = scale } };
    try surface.uploadCoverage(mask);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.beginGroup(.{ .x = 0, .y = 0, .width = source_width, .height = source_height }, .{ .opacity = 180, .mask = mask });
    try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, 0, .{ .r = 255, .g = 0, .b = 0, .a = 160 });
    try buffer.roundedRect(.{ .x = 6, .y = 4, .width = 10, .height = 8 }, 0, .{ .r = 0, .g = 0, .b = 255, .a = 128 });
    try buffer.endGroup();
    const snapshot = try surface.render(&buffer);
    errdefer snapshot.close() catch unreachable;
    const view = try snapshot.view();
    const first = pixel(view.levels[0], @intFromFloat(3 * scale), @intFromFloat(3 * scale));
    const overlap = pixel(view.levels[0], @intFromFloat(8 * scale), @intFromFloat(6 * scale));
    try std.testing.expect(first >> 24 > 0 and first >> 24 < 160);
    try std.testing.expect(overlap >> 24 > first >> 24 and overlap & 255 != 0 and (overlap >> 16) & 255 != 0);
    var work: ?gaussian.Work = null;
    errdefer if (work) |value| value.close() catch unreachable;
    if (processor) |value| {
        work = try value.capture(view, .{ .sigma = sigma, .scale = scale });
        try std.testing.expectError(error.ResourceInUse, snapshot.close());
    }
    buffer.reset();
    try surface.close();
    surface_live = false;
    try mask_lease.ensureUnused();
    // Only Snapshot pixels (and the optional Work pin) survive this function.
    return .{ .snapshot = snapshot, .work = work };
}

const Worker = struct {
    work: gaussian.Work,
    failure: ?anyerror = null,
    thread_id: std.Thread.Id = 0,
    fn run(self: *Worker) void {
        self.thread_id = std.Thread.getCurrentId();
        self.work.run() catch |err| {
            self.failure = err;
        };
    }
};
fn execute(work: gaussian.Work) !void {
    try std.testing.expectEqual(gaussian.Status.captured, try work.status());
    var worker: Worker = .{ .work = work };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    // Explicit console-harness handoff, outside App.run/native callbacks.
    // The worker itself performs no allocator, Lease, App or native operation.
    thread.join();
    try std.testing.expect(worker.thread_id != std.Thread.getCurrentId());
    if (worker.failure) |err| return err;
    try std.testing.expectEqual(gaussian.Status.complete, try work.status());
}

fn directOracle(source: drawing.ImageLevel, view: drawing.ImageView, info: gaussian.ResultStats) !void {
    const radius: usize = @intFromFloat(@ceil(3 * @as(f64, sigma) * info.scale));
    try std.testing.expectEqual(@as(u32, @intCast(radius)), info.radius);
    try std.testing.expectEqual(source.width + 2 * info.radius, info.width);
    try std.testing.expectEqual(source.height + 2 * info.radius, info.height);
    try std.testing.expectEqual(-@as(f32, @floatFromInt(radius)) / info.scale, info.placement.x);
    try std.testing.expectEqual(info.placement.x, info.placement.y);
    try std.testing.expectEqual(@as(usize, info.width) * info.height * 4, info.pixel_bytes);
    try std.testing.expectEqual(@as(usize, info.width) * source.height * 4, info.scratch_bytes);
    try std.testing.expect(!info.identity);
    // Independent direct 2D kernel, without a horizontal intermediate or the
    // production kernel/plan. Read the actual native-composited source bytes.
    const diameter = radius * 2 + 1;
    var weights: [13 * 13]f64 = undefined;
    try std.testing.expect(diameter * diameter <= weights.len);
    const variance = @as(f64, sigma) * info.scale * @as(f64, sigma) * info.scale;
    var sum: f64 = 0;
    for (0..diameter) |ky| for (0..diameter) |kx| {
        const dx = @as(f64, @floatFromInt(kx)) - @as(f64, @floatFromInt(radius));
        const dy = @as(f64, @floatFromInt(ky)) - @as(f64, @floatFromInt(radius));
        const value = @exp(-(dx * dx + dy * dy) / (2 * variance));
        weights[ky * diameter + kx] = value;
        sum += value;
    };
    var maximum: u32 = 0;
    var halo: usize = 0;
    var transparent: usize = 0;
    for (0..info.height) |y| for (0..info.width) |x| {
        var color: [4]f64 = @splat(0);
        for (0..diameter) |ky| for (0..diameter) |kx| {
            const sx = @as(i64, @intCast(x + kx)) - @as(i64, @intCast(radius * 2));
            const sy = @as(i64, @intCast(y + ky)) - @as(i64, @intCast(radius * 2));
            if (sx < 0 or sy < 0 or sx >= source.width or sy >= source.height) continue;
            const at = @as(usize, @intCast(sy)) * source.stride + @as(usize, @intCast(sx)) * 4;
            const weight = weights[ky * diameter + kx] / sum;
            for (&color, 0..) |*channel, index| channel.* += @as(f64, @floatFromInt(source.pixels[at + index])) * weight;
        };
        var expected: u32 = 0;
        for (color, [_]u5{ 0, 8, 16, 24 }) |channel, shift| expected |= @as(u32, @intFromFloat(@round(std.math.clamp(channel, 0, 255)))) << shift;
        const actual = pixel(view.levels[0], x, y);
        maximum = @max(maximum, try near(expected, actual, "direct-2d", info.scale, x, y));
        const alpha = actual >> 24;
        for ([_]u5{ 0, 8, 16 }) |shift| try std.testing.expect((actual >> shift) & 255 <= alpha);
        if (alpha == 0) transparent += 1;
        if ((x < radius or y < radius or x >= source.width + radius or y >= source.height + radius) and alpha != 0) halo += 1;
    };
    try std.testing.expect(halo != 0 and transparent != 0);
    std.debug.print("gaussian direct2d DPI={d} expanded={d}x{d} R={d} placement={d},{d} max_byte_difference={d} halo={d}\n", .{ info.scale, info.width, info.height, info.radius, info.placement.x, info.placement.y, maximum, halo });
}

fn isGdi(comptime Renderer: type) bool {
    return builtin.os.tag == .windows and Renderer == ui.SoftwareRenderer;
}
fn identity(renderer: anytype, allocator: std.mem.Allocator, app: *z.App, processor: *gaussian.Processor, scale: f32, backend: []const u8) !void {
    const captured = try composed(allocator, app, null, scale);
    const snapshot = captured.snapshot;
    var source_live = true;
    defer if (source_live) snapshot.close() catch unreachable;
    const source = try snapshot.view();
    // Ordinary GDI static images have no residency. Its explicit dynamic CPU
    // residency supplies a real independent pin for this lifetime subcase.
    if (comptime isGdi(@TypeOf(renderer.*))) try renderer.uploadDynamicImage(source) else try renderer.uploadImage(source);
    var resident = true;
    defer if (resident) {
        _ = renderer.releaseImage(source.identity) catch unreachable;
    };
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.image(.{ .x = 0, .y = 0, .width = source_width, .height = source_height }, source, .{ .sampling = .nearest });
    const before = renderer.imageStats();
    try std.testing.expect(before.resident_entries > 0);
    const work = try processor.capture(source, .{ .sigma = 0, .scale = scale });
    var work_live = true;
    defer if (work_live) work.close() catch unreachable;
    try execute(work);
    const prepared = work.finish() catch |err| {
        work_live = false;
        return err;
    };
    work_live = false;
    var prepared_live = true;
    defer if (prepared_live) prepared.close() catch unreachable;
    const view = try prepared.view();
    try std.testing.expect(view.identity == source.identity and view.lease == source.lease and view.levels.ptr == source.levels.ptr);
    const stats = try prepared.stats();
    try std.testing.expect(stats.identity and stats.pixel_bytes == 0 and stats.scratch_bytes == 0 and stats.filter_samples == 0);
    if (comptime isGdi(@TypeOf(renderer.*))) try renderer.uploadDynamicImage(view) else try renderer.uploadImage(view);
    const after = renderer.imageStats();
    try std.testing.expectEqual(before.uploads, after.uploads);
    try std.testing.expectEqual(before.resident_entries, after.resident_entries);
    try std.testing.expectEqual(before.native_creations, after.native_creations);
    try prepared.close();
    prepared_live = false;
    try std.testing.expectError(error.ResourceInUse, snapshot.close());
    buffer.reset();
    try std.testing.expectError(error.ResourceInUse, snapshot.close());
    try std.testing.expect(try renderer.releaseImage(source.identity));
    resident = false;
    try snapshot.close();
    source_live = false;
    std.debug.print("gaussian sigma0 backend={s} DPI={d} identity/lease/levels=unchanged uploads={d}->{d} resident_entries={d}->{d} native_creations={d}->{d}; wrapper/frame/residency released\n", .{ backend, scale, before.uploads, after.uploads, before.resident_entries, after.resident_entries, before.native_creations, after.native_creations });
}

fn expectedReplay(view: drawing.ImageView, info: gaussian.ResultStats, x: usize, y: usize, clipped: bool) u32 {
    const scale: f64 = info.scale;
    const left: i64 = @intFromFloat(@round((8 + @as(f64, info.placement.x)) * scale));
    const top: i64 = @intFromFloat(@round((8 + @as(f64, info.placement.y)) * scale));
    const sx = @as(i64, @intCast(x)) - left;
    const sy = @as(i64, @intCast(y)) - top;
    if (sx < 0 or sy < 0 or sx >= info.width or sy >= info.height) return 0xffffffff;
    const sample = pixel(view.levels[0], @intCast(sx), @intCast(sy));
    const xx: f64 = @floatFromInt(x);
    const yy: f64 = @floatFromInt(y);
    const coverage = if (clipped)
        @max(0, @min(xx + 1, 25.75 * scale) - @max(xx, 9.25 * scale)) * @max(0, @min(yy + 1, 23.25 * scale) - @max(yy, 7.75 * scale))
    else
        1;
    const factor = coverage * @as(f64, if (clipped) 128.0 / 255.0 else 1);
    var result: u32 = 0xff000000;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const channel: f64 = @floatFromInt((sample >> shift) & 255);
        const alpha: f64 = @floatFromInt(sample >> 24);
        result |= @as(u32, @intFromFloat(@round(255 + (channel - alpha) * factor))) << shift;
    }
    return result;
}
fn replay(renderer: anytype, allocator: std.mem.Allocator, app: *z.App, processor: *gaussian.Processor, prepared: *gaussian.Prepared, scale: f32, context: *anyopaque, window: ?*anyopaque, backend: []const u8) !void {
    const view = try prepared.view();
    const info = try prepared.stats();
    const size: z.Size = .{ .width = @intFromFloat(target_width * scale), .height = @intFromFloat(target_height * scale), .scale = scale };
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = size };
    try renderer.uploadImage(view);
    var resident = true;
    defer if (resident) {
        _ = renderer.releaseImage(view.identity) catch unreachable;
    };
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var pixels: [80 * 64]u32 = undefined;
    var maximum: u32 = 0;
    for (0..2) |stage| {
        buffer.reset();
        // Ordinary GDI clipping is an integer native region. The explicitly
        // prepared workspace supplies the precise fractional parent clip.
        if (stage != 0) try renderer.prepareLayers(allocator, .{ .size = size, .max_depth = 1 });
        try buffer.fill(.{ .x = 0, .y = 0, .width = target_width, .height = target_height }, 0xffffff);
        if (stage != 0) {
            try buffer.pushClip(.{ .x = 9.25, .y = 7.75, .width = 16.5, .height = 15.5 });
            try buffer.beginGroup(.{ .x = 0, .y = 0, .width = target_width, .height = target_height }, .{ .opacity = 128 });
        }
        try buffer.image(.{ .x = 8 + info.placement.x, .y = 8 + info.placement.y, .width = @as(f32, @floatFromInt(info.width)) / scale, .height = @as(f32, @floatFromInt(info.height)) / scale }, view, .{ .sampling = .nearest });
        if (stage != 0) {
            try buffer.endGroup();
            try buffer.popClip();
        }
        try std.testing.expectError(error.ResourceInUse, prepared.close());
        try renderer.begin(paint);
        errdefer renderer.abort();
        try renderer.replayBuffer(&buffer);
        // The prepared stage is checked only after successful commit; its
        // whole-plane readback is the front after the final parent composite.
        if (stage != 0) {
            if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else try renderer.end();
        }
        if (@TypeOf(renderer.*) != ui.SoftwareRenderer) {
            const output = pixels[0 .. @as(usize, size.width) * size.height];
            if (stage == 0) try renderer.readPixelsForTest(size.width, size.height, output) else try renderer.readLayerPixels(true, output);
        } else if (builtin.os.tag == .windows) _ = c.GdiFlush();
        for (0..size.height) |y| for (0..size.width) |x| {
            const actual = if (@TypeOf(renderer.*) != ui.SoftwareRenderer) pixels[y * size.width + x] else if (builtin.os.tag == .windows) renderer.pixels.?[y * size.width + x] else if (stage == 0) zlc_test_raw_pixel(renderer.native.?, @intCast(x), @intCast(y)) else zlc_layer_test_pixel(renderer.native.?, 1, @intCast(x), @intCast(y));
            // Stage zero uses the opaque-window RGB/XRGB diagnostic contract.
            // Stage one reads a real BGRA work plane after group composition.
            if (stage != 0 and actual >> 24 != 255) {
                std.debug.print("gaussian BGRA alpha backend={s} DPI={d} pixel={d},{d} actual={x}\n", .{ backend, scale, x, y, actual });
                return error.GaussianReplayAlphaMismatch;
            }
            const normalized = if (stage == 0) actual | 0xff000000 else actual;
            maximum = @max(maximum, try near(expectedReplay(view, info, x, y, stage != 0), normalized, if (stage == 0) "nearest" else "postfilter-clip-opacity", scale, x, y));
        };
        if (stage == 0) {
            if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else try renderer.end();
        }
    }
    buffer.reset();
    if (comptime isGdi(@TypeOf(renderer.*))) try renderer.uploadDynamicImage(view);
    try std.testing.expectError(error.ResourceInUse, prepared.close());
    try std.testing.expect(try renderer.releaseImage(view.identity));
    resident = false;
    try identity(renderer, allocator, app, processor, scale, backend);
    std.debug.print("gaussian replay backend={s} DPI={d} prepared_pixel_max_difference={d}, BGRA alpha255 after parent group; identity residency unchanged\n", .{ backend, scale, maximum });
}

fn scenario(allocator: std.mem.Allocator, app: *z.App, scale: f32) !void {
    const processor = try gaussian.Processor.create(allocator, std.Thread.getCurrentId(), .{});
    defer processor.close() catch unreachable;
    const captured = try composed(allocator, app, processor, scale);
    const snapshot = captured.snapshot;
    var source_live = true;
    defer if (source_live) snapshot.close() catch unreachable;
    const work = captured.work.?;
    var work_live = true;
    defer if (work_live) work.close() catch unreachable;
    const source = try snapshot.view();
    var source_level = source.levels[0];
    const source_bytes = try allocator.dupe(u8, source_level.pixels[0..source_level.byte_len]);
    defer allocator.free(source_bytes);
    source_level.pixels = source_bytes.ptr;
    try execute(work);
    const prepared = work.finish() catch |err| {
        work_live = false;
        return err;
    };
    work_live = false;
    defer prepared.close() catch unreachable;
    try std.testing.expectError(error.Busy, processor.close());
    const view = try prepared.view();
    try std.testing.expect(view.identity != source.identity and view.lease != source.lease);
    try snapshot.close();
    source_live = false;
    try std.testing.expectEqual(@as(usize, 0), (try processor.stats()).borrowed_source_bytes);
    try directOracle(source_level, view, try prepared.stats());
    if (builtin.os.tag == .windows) {
        const window = try app.createWindow(.{ .width = 160, .height = 120 });
        defer _ = window.destroy() catch unreachable;
        const dc = c.GetDC(window.nativeHandle()) orelse return error.GetDcFailed;
        defer _ = c.ReleaseDC(window.nativeHandle(), dc);
        var software: ui.SoftwareRenderer = .{};
        defer software.deinit();
        try replay(&software, allocator, app, processor, prepared, scale, dc, window.nativeHandle(), "gdi");
        if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
            var gpu: ui.d3d11.Renderer = .{};
            try gpu.init(.{ .driver = driver });
            defer gpu.deinit();
            try replay(&gpu, allocator, app, processor, prepared, scale, dc, window.nativeHandle(), @tagName(driver));
        };
    } else {
        const target = cairo_image_surface_create(0, @intFromFloat(target_width * scale), @intFromFloat(target_height * scale)) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(target);
        const context = cairo_create(target) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(context);
        var software: ui.SoftwareRenderer = .{};
        defer software.deinit();
        try replay(&software, allocator, app, processor, prepared, scale, context, null, "cairo");
    }
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const process_initial = nativeCount();
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        // App's first native GUI initialization has its own process lifetime
        // cost. Gaussian/backend teardown must retain this initialized baseline.
        const baseline = nativeCount();
        for ([_]f32{ 1, 1.5, 2 }) |scale| try scenario(allocator, app, scale);
        const resources = app.resourceStats();
        std.debug.print("gaussian before App deinit: live_windows={d} allocated_records={d} stops={d} native_count={d} baseline={d}\n", .{ resources.live_windows, resources.allocated_records, resources.stop_participants, nativeCount(), baseline });
        try std.testing.expectEqual(@as(usize, 0), resources.live_windows);
        try std.testing.expectEqual(@as(usize, 0), resources.allocated_records);
        try std.testing.expectEqual(@as(usize, 0), resources.stop_participants);
        try std.testing.expectEqual(baseline, nativeCount());
    }
    std.debug.print("gaussian after App deinit: native_count={d} process_initial={d} GPU_refs={d}\n", .{ nativeCount(), process_initial, if (ui.capabilities.gpu) ui.d3d11.globalResourceCount() else 0 });
    if (builtin.os.tag != .windows) try std.testing.expectEqual(process_initial, nativeCount());
    if (ui.capabilities.gpu) try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
    std.debug.print("gaussian: real composed Snapshot/group/mask -> explicit worker -> independent Prepared; direct2D <=1, nearest replay/clip/opacity, sigma0 identity/residency, 3 DPI, framework resources=0 and initialized-App native baseline retained\n", .{});
}
