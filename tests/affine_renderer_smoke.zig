const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlc_layer_live_objects() u32;
extern fn zlc_test_live_image_objects() u32;
fn near(want: u32, actual: u32, tolerance: u32) !void {
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| if (@abs(@as(i32, @intCast((want >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > tolerance) {
        std.debug.print("affine pixel expected={x}, actual={x}\n", .{ want, actual });
        return error.PixelMismatch;
    };
}
fn pixel(view: ui.drawing.ImageView, x: usize, y: usize) u32 {
    const level = view.levels[0];
    return std.mem.readInt(u32, level.pixels[y * level.stride + x * 4 ..][0..4], .little);
}
fn base(buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, scale: f32) !void {
    buffer.reset();
    table.scale = scale;
    try buffer.bindTransformStorage(table);
}
fn fractional(buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, scale: f32, source_width: f32) !void {
    try base(buffer, table, scale);
    // Physical half-texel translation and 3/4 parent coverage at every DPI.
    try buffer.pushClip(.{ .x = 2.25 / scale, .y = 0, .width = 20, .height = 20 });
    try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .x0 = 2.5 / @as(f64, scale), .y0 = 2 / @as(f64, scale) }, .{ .width = source_width / scale, .height = 2 / scale }, scale));
    try buffer.fill(.{ .x = -1, .y = -1, .width = 4, .height = 4 }, 0xff0000);
    try buffer.endTransform();
    try buffer.popClip();
}
fn largeSource(buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, scale: f32) !void {
    try base(buffer, table, scale);
    try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = 0.25, .yy = 0.25 }, .{ .width = 20, .height = 20 }, scale));
    try buffer.beginGroup(.{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{});
    try buffer.fill(.{ .x = 12, .y = 12, .width = 4, .height = 4 }, 0x0000ff);
    try buffer.endGroup();
    try buffer.endTransform();
}
fn quadrants(buffer: *ui.commands.Buffer, variant: bool) !void {
    const colors = if (variant) [_]ui.Color{ ui.Color.rgb(0xffff00), ui.Color.rgb(0x0000ff), .{ .r = 0, .g = 255, .b = 0, .a = 64 }, .{ .r = 255, .g = 0, .b = 0, .a = 128 } } else [_]ui.Color{ .{ .r = 255, .g = 0, .b = 0, .a = 128 }, .{ .r = 0, .g = 255, .b = 0, .a = 64 }, ui.Color.rgb(0x0000ff), ui.Color.rgb(0xffff00) };
    for (colors, 0..) |color, index| try buffer.roundedRect(.{ .x = @as(f32, @floatFromInt(index % 2)) * 2, .y = @as(f32, @floatFromInt(index / 2)) * 2, .width = 2, .height = 2 }, 0, color);
}
fn read(surface: anytype, buffer: *const ui.commands.Buffer, pixels: []u32) !void {
    if (@TypeOf(surface) == *ui.offscreen.Surface) {
        const image = try surface.render(buffer);
        defer image.close() catch unreachable;
        const view = try image.view();
        for (pixels, 0..) |*p, index| p.* = pixel(view, index % view.levels[0].width, index / view.levels[0].width);
    } else {
        try surface.render(buffer);
        try surface.readFrontForTest(pixels);
    }
}
fn colorAt(x: i64, y: i64, scale: f32, variant: bool) u32 {
    const side: i64 = @intFromFloat(4 * scale);
    if (x < 0 or y < 0 or x >= side or y >= side) return 0;
    const split: i64 = @divExact(side, 2);
    const index: usize = @as(usize, @intFromBool(x >= split)) + 2 * @as(usize, @intFromBool(y >= split));
    return (if (variant) [_]u32{ 0xffffff00, 0xff0000ff, 0x40004000, 0x80800000 } else [_]u32{ 0x80800000, 0x40004000, 0xff0000ff, 0xffffff00 })[index];
}
// Independent f128 inverse and analytic source cells, without using the
// renderer's inverse-map, plane sampler, or source-over implementation.
const SampleClass = struct { mixed: bool = false, partial_clip: bool = false };
fn oracle(scope: ui.layers.NativeTransform, x: usize, y: usize, scale: f32, variant: bool, before: u32, classification: ?*SampleClass) u32 {
    const a: f128 = scope.xx;
    const b: f128 = scope.xy;
    const c0: f128 = scope.yx;
    const d: f128 = scope.yy;
    const determinant = a * d - b * c0;
    const px = (@as(f128, @floatFromInt(x)) + 0.5) / scale - scope.x0;
    const py = (@as(f128, @floatFromInt(y)) + 0.5) / scale - scope.y0;
    const sx = (d * px - b * py) / determinant * scale - 0.5;
    const sy = (a * py - c0 * px) / determinant * scale - 0.5;
    const bx: i64 = @intFromFloat(@floor(sx));
    const by: i64 = @intFromFloat(@floor(sy));
    const fx = sx - @floor(sx);
    const fy = sy - @floor(sy);
    var sums: [4]f128 = @splat(0);
    var first: ?u32 = null;
    var mixed = false;
    for (0..2) |iy| for (0..2) |ix| {
        const p = colorAt(bx + @as(i64, @intCast(ix)), by + @as(i64, @intCast(iy)), scale, variant);
        const weight = (if (ix == 0) 1 - fx else fx) * (if (iy == 0) 1 - fy else fy);
        if (weight > 0) {
            if (first) |previous| {
                mixed = mixed or previous != p;
            } else first = p;
        }
        inline for (0..4) |channel| sums[channel] += @as(f128, @floatFromInt((p >> @as(u5, @intCast(channel * 8))) & 255)) * weight;
    };
    var sampled: [4]u32 = undefined;
    inline for (0..4) |channel| sampled[channel] = @intFromFloat(@round(sums[channel]));
    // The parent clip is [.25,7.75] DIP in both axes, applied at this
    // composite only, rather than baked into the source bitmap.
    const left: f128 = 0.25 * @as(f128, scale);
    const right: f128 = 7.75 * @as(f128, scale);
    const dx: f128 = @floatFromInt(x);
    const dy: f128 = @floatFromInt(y);
    const coverage = @max(0, @min(dx + 1, right) - @max(dx, left)) * @max(0, @min(dy + 1, right) - @max(dy, left));
    if (classification) |value| value.* = .{ .mixed = mixed, .partial_clip = coverage > 0 and coverage < 1 };
    const alpha = @as(f128, @floatFromInt(sampled[3])) * coverage / 255;
    var result: u32 = 0;
    inline for (0..4) |channel| {
        const shift: u5 = @intCast(channel * 8);
        const value: u32 = @intFromFloat(@round(@as(f128, @floatFromInt(sampled[channel])) * coverage + @as(f128, @floatFromInt((before >> shift) & 255)) * (1 - alpha)));
        result |= @as(u32, @min(255, value)) << shift;
    }
    return result;
}
fn cairoQuantization() !void {
    // Official Pixman 0.42.2 uses seven fractional weight bits, truncated.
    // This independent single-axis example has no geometric AA or clip:
    // red(alpha128) -> opaque blue sampled at fraction .1.
    const fraction: f64 = 0.1;
    const fixed = @floor(fraction * 128) / 128;
    const alpha: u32 = @intFromFloat(@floor(128 * (1 - fixed) + 255 * fixed));
    const red: u32 = @intFromFloat(@floor(128 * (1 - fixed)));
    const blue: u32 = @intFromFloat(@floor(255 * fixed));
    try equal(@as(u32, 0x8b740017), alpha << 24 | red << 16 | blue);
    try near(0x8d73001a, alpha << 24 | red << 16 | blue, 3);
}
// Each stage consumes an already quantized byte plane. This oracle does not
// combine nested matrices or use renderer interpolation/coordinate helpers.
fn planeOracle(scope: ui.layers.NativeTransform, x: usize, y: usize, scale: f32, source: []const u32, width: usize, height: usize) u32 {
    const a: f128 = scope.xx;
    const b: f128 = scope.xy;
    const c0: f128 = scope.yx;
    const d: f128 = scope.yy;
    const determinant = a * d - b * c0;
    const px = (@as(f128, @floatFromInt(x)) + 0.5) / scale - scope.x0;
    const py = (@as(f128, @floatFromInt(y)) + 0.5) / scale - scope.y0;
    const sx = (d * px - b * py) / determinant * scale - 0.5;
    const sy = (a * py - c0 * px) / determinant * scale - 0.5;
    const bx: i64 = @intFromFloat(@floor(sx));
    const by: i64 = @intFromFloat(@floor(sy));
    const fx = sx - @floor(sx);
    const fy = sy - @floor(sy);
    var sums: [4]f128 = @splat(0);
    for (0..2) |iy| for (0..2) |ix| {
        const ax = bx + @as(i64, @intCast(ix));
        const ay = by + @as(i64, @intCast(iy));
        const p = if (ax >= 0 and ay >= 0 and ax < width and ay < height) source[@as(usize, @intCast(ay)) * width + @as(usize, @intCast(ax))] else 0;
        const weight = (if (ix == 0) 1 - fx else fx) * (if (iy == 0) 1 - fy else fy);
        inline for (0..4) |channel| sums[channel] += @as(f128, @floatFromInt((p >> @as(u5, @intCast(channel * 8))) & 255)) * weight;
    };
    var result: u32 = 0;
    inline for (0..4) |channel| result |= @as(u32, @intFromFloat(@round(sums[channel]))) << @as(u5, @intCast(channel * 8));
    return result;
}
const original_inner: ui.affine.Affine = .{ .xx = 0.8, .xy = 0.25, .yy = 1.1, .x0 = 1.2, .y0 = 0.7 };
const binary_inner: ui.affine.Affine = .{ .xx = 0.75, .xy = 0.25, .yy = 1.125, .x0 = 1.25, .y0 = 1 };
const original_outer: ui.affine.Affine = .{ .xx = 0.9, .yx = 0.2, .xy = -0.1, .yy = 0.8, .x0 = 0.9, .y0 = 0.6 };
fn multiStage(surface: anytype, buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, size: z.Size, inner_matrix: ui.affine.Affine) !void {
    const count: usize = size.width * size.height;
    const source_side: usize = @intFromFloat(4 * size.scale);
    var source: [64]u32 = undefined;
    for (source[0 .. source_side * source_side], 0..) |*value, at| value.* = colorAt(@intCast(at % source_side), @intCast(at / source_side), size.scale, false);
    const inner = try ui.layers.NativeTransform.init(inner_matrix, .{ .width = 4, .height = 4 }, size.scale);
    const outer = try ui.layers.NativeTransform.init(original_outer, .{ .width = 8, .height = 8 }, size.scale);
    try base(buffer, table, size.scale);
    try buffer.beginTransform(inner);
    try quadrants(buffer, false);
    try buffer.endTransform();
    var first: [256]u32 = undefined;
    try read(surface, buffer, first[0..count]);
    const stage_tolerance: u32 = 2;
    for (first[0..count], 0..) |actual, at| near(planeOracle(inner, at % size.width, at / size.width, size.scale, source[0 .. source_side * source_side], source_side, source_side), actual, stage_tolerance) catch |err| {
        std.debug.print("multistage first scale={d} xy={d},{d}\n", .{ size.scale, at % size.width, at / size.width });
        return err;
    };

    try base(buffer, table, size.scale);
    try buffer.beginTransform(outer);
    try buffer.beginTransform(inner);
    try quadrants(buffer, false);
    try buffer.endTransform();
    try buffer.endTransform();
    var nested: [256]u32 = undefined;
    try read(surface, buffer, nested[0..count]);
    // Check the second stage against the first stage's actual byte raster,
    // instead of claiming a single-stage tolerance bounds the whole scene.
    for (nested[0..count], 0..) |actual, at| near(planeOracle(outer, at % size.width, at / size.width, size.scale, first[0..count], size.width, size.height), actual, stage_tolerance) catch |err| {
        std.debug.print("multistage second scale={d} xy={d},{d}\n", .{ size.scale, at % size.width, at / size.width });
        return err;
    };

    var lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = std.mem.sliceAsBytes(first[0..count]);
    const levels = [_]ui.drawing.ImageLevel{.{ .pixels = bytes.ptr, .byte_len = bytes.len, .width = size.width, .height = size.height, .stride = size.width * 4 }};
    const view: ui.drawing.ImageView = .{ .lease = &lease, .identity = try ui.drawing.reserveRasterIdentity(), .levels = &levels };
    try surface.uploadImage(view);
    defer _ = surface.releaseImage(view.identity) catch unreachable;
    defer buffer.reset();
    try base(buffer, table, size.scale);
    try buffer.beginTransform(outer);
    try buffer.image(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, view, .{ .sampling = .nearest });
    try buffer.endTransform();
    var replayed: [256]u32 = undefined;
    try read(surface, buffer, replayed[0..count]);
    for (nested[0..count], replayed[0..count], 0..) |actual, expected, at| near(expected, actual, 2) catch |err| {
        std.debug.print("multistage uploaded reference scale={d} xy={d},{d}\n", .{ size.scale, at % size.width, at / size.width });
        return err;
    };

    var merged = try inner.matrix().then(outer.matrix());
    // Canonicalizing the product makes this a real alternate one-stage draw,
    // whose output must differ from the two independently sampled stages.
    merged = try merged.narrowed();
    try base(buffer, table, size.scale);
    try buffer.beginTransform(try ui.layers.NativeTransform.init(merged, .{ .width = 4, .height = 4 }, size.scale));
    try quadrants(buffer, false);
    try buffer.endTransform();
    try read(surface, buffer, replayed[0..count]);
    var different: usize = 0;
    for (nested[0..count], replayed[0..count]) |actual, single| different += @intFromBool(actual != single);
    try expect(different > 0);
}
fn rejectedNested(surface: *ui.gpu_offscreen.Surface, buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, size: z.Size) !void {
    const snapshot = try surface.snapshot();
    defer snapshot.close() catch unreachable;
    defer buffer.reset();
    var before: [256]u32 = undefined;
    var after: [256]u32 = undefined;
    const count: usize = size.width * size.height;
    try surface.readFrontForTest(before[0..count]);
    for ([_]bool{ false, true }) |with_texture| {
        try base(buffer, table, size.scale);
        try buffer.fill(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0x00ff00);
        try buffer.beginTransform(try ui.layers.NativeTransform.init(original_outer, .{ .width = 8, .height = 8 }, size.scale));
        try buffer.beginTransform(try ui.layers.NativeTransform.init(original_inner, .{ .width = 4, .height = 4 }, size.scale));
        if (with_texture) try buffer.texture(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, try snapshot.view(), .{}) else try quadrants(buffer, false);
        try buffer.endTransform();
        try buffer.endTransform();
        const prior = try surface.stats();
        try expectError(error.UnsupportedTransformPrecision, surface.render(buffer));
        const current = try surface.stats();
        try equal(prior.renders, current.renders);
        try std.testing.expectEqualDeep(prior.layers, current.layers);
        try surface.readFrontForTest(after[0..count]);
        try std.testing.expectEqualSlices(u32, before[0..count], after[0..count]);
    }
}
fn matrices(surface: anytype, buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, size: z.Size) !void {
    const cases = [_]ui.affine.Affine{
        .{ .x0 = 1, .y0 = 1 },               .{ .xx = -1, .x0 = 6, .y0 = 1 },                                      .{ .xx = 0, .yx = 1, .xy = -1, .yy = 0, .x0 = 6, .y0 = 1 },
        .{ .xy = 0.25, .x0 = 0.5, .y0 = 1 }, .{ .xx = 0.8, .yx = 0.6, .xy = -0.6, .yy = 0.8, .x0 = 3, .y0 = 0.5 }, .{ .xx = 0.5, .yy = 1.25, .x0 = 1, .y0 = 1 },
    };
    var pixels: [256]u32 = undefined;
    for (cases, 0..) |matrix, case| {
        try base(buffer, table, size.scale);
        try buffer.pushClip(.{ .x = 0.25, .y = 0.25, .width = 7.5, .height = 7.5 });
        const scope = try ui.layers.NativeTransform.init(matrix, .{ .width = 4, .height = 4 }, size.scale);
        try buffer.beginTransform(scope);
        try quadrants(buffer, false);
        try buffer.endTransform();
        // Same-depth reuse with different source colors must not mutate the
        // first queued consumer's bitmap contents.
        if (case == 0) {
            try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .x0 = 3, .y0 = 3 }, .{ .width = 4, .height = 4 }, size.scale));
            try quadrants(buffer, true);
            try buffer.endTransform();
        }
        try buffer.popClip();
        try read(surface, buffer, pixels[0 .. size.width * size.height]);
        for (0..size.height) |y| for (0..size.width) |x| {
            var classification: SampleClass = .{};
            var want = oracle(scope, x, y, size.scale, false, 0, &classification);
            if (case == 0) want = oracle(try ui.layers.NativeTransform.init(.{ .x0 = 3, .y0 = 3 }, .{ .width = 4, .height = 4 }, size.scale), x, y, size.scale, true, want, null);
            // GDI and Cairo use the same bounded source sampler. Constant
            // samples and right-angle cases retain the stricter one-byte bound.
            const tolerance: u32 = if (!classification.mixed and case != 0) 1 else 2;
            near(want, pixels[y * size.width + x], tolerance) catch |err| {
                std.debug.print("affine matrix case={d}, scale={d}, xy={d},{d}\n", .{ case, size.scale, x, y });
                return err;
            };
        };
    }
    try base(buffer, table, size.scale);
    try buffer.pushClip(.{ .x = 0.25, .y = 0.25, .width = 7.5, .height = 7.5 });
    try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = 0.25, .yy = 0.25 }, .{ .width = 20, .height = 20 }, size.scale));
    try buffer.beginGroup(.{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{});
    try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .x0 = 12, .y0 = 12 }, .{ .width = 4, .height = 4 }, size.scale));
    try quadrants(buffer, false);
    try buffer.endTransform();
    try buffer.endGroup();
    try buffer.endTransform();
    try buffer.popClip();
    try read(surface, buffer, pixels[0 .. size.width * size.height]);
    const combined = try ui.layers.NativeTransform.init(.{ .xx = 0.25, .yy = 0.25, .x0 = 3, .y0 = 3 }, .{ .width = 4, .height = 4 }, size.scale);
    for (0..size.height) |y| for (0..size.width) |x| {
        // The inner translation is an integral physical offset at each DPI;
        // only the outer scale resamples. Parent clip is consumed once.
        try near(oracle(combined, x, y, size.scale, false, 0, null), pixels[y * size.width + x], 2);
    };
}
fn rasterInputs(surface: anytype, buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, size: z.Size) !void {
    var image_lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{ 0, 128, 0, 128 };
    const levels = [_]ui.drawing.ImageLevel{.{ .pixels = &bytes, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
    const image: ui.drawing.ImageView = .{ .lease = &image_lease, .identity = try ui.drawing.reserveRasterIdentity(), .levels = &levels };
    try surface.uploadImage(image);
    defer _ = surface.releaseImage(image.identity) catch unreachable;
    var mask_lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    var mask_pixels: [64]u8 = @splat(255);
    const side: u32 = @intFromFloat(4 * size.scale);
    const mask: ui.drawing.CoverageView = .{ .lease = &mask_lease, .identity = try ui.drawing.reserveRasterIdentity(), .coverage = .{ .pixels = mask_pixels[0 .. side * side], .width = side, .height = side, .stride = side, .origin_x = 0, .origin_y = 0, .scale = size.scale } };
    try surface.uploadCoverage(mask);
    defer _ = surface.releaseCoverage(mask.identity) catch unreachable;
    defer buffer.reset();
    var pixels: [256]u32 = undefined;
    const at: usize = @intFromFloat(3.5 * size.scale);
    for (0..4) |case| {
        try base(buffer, table, size.scale);
        try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = 0.25, .yy = 0.25 }, .{ .width = 20, .height = 20 }, size.scale));
        const bounds: ui.layout.Rect = .{ .x = 12, .y = 12, .width = 4, .height = 4 };
        const expected: u32 = switch (case) {
            0 => blk: {
                try buffer.image(bounds, image, .{});
                break :blk 0x80008000;
            },
            1 => blk: {
                try buffer.coverage(.{ .x = 12, .y = 12 }, mask, .{ .r = 255, .g = 255, .b = 0, .a = 64 });
                break :blk 0x40404000;
            },
            2 => blk: {
                try buffer.beginGroup(bounds, .{ .mask = mask, .mask_origin = .{ .x = 12, .y = 12 }, .opacity = 128 });
                try buffer.fill(bounds, 0x0000ff);
                try buffer.endGroup();
                break :blk 0x80000080;
            },
            else => blk: {
                const stops = [_]ui.commands.brushes.Stop{ .{ .offset = 0, .color = ui.Color.rgb(0xff0000) }, .{ .offset = 0.5, .color = ui.Color.rgb(0xff0000) }, .{ .offset = 0.5, .color = ui.Color.rgb(0x0000ff) }, .{ .offset = 1, .color = ui.Color.rgb(0x0000ff) } };
                try buffer.gradientRect(bounds, 0, .{ .linear = .{ .start = .{ .x = 12, .y = 12 }, .end = .{ .x = 16, .y = 12 }, .stops = &stops } });
                break :blk if (size.scale == 1) 0xff800080 else 0xff0000ff;
            },
        };
        try buffer.endTransform();
        try read(surface, buffer, pixels[0 .. size.width * size.height]);
        near(expected, pixels[at * size.width + at], 1) catch |err| {
            std.debug.print("affine raster input case={d}, scale={d}\n", .{ case, size.scale });
            return err;
        };
    }
}
fn glyph(surface: anytype, reference: anytype, allocator: std.mem.Allocator, size: z.Size) !void {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const engine = try text.Engine.create(failing.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const layout = try engine.layout("O A", .{ .size = 10 });
    defer layout.close() catch unreachable;
    const prepared = try layout.prepare(size.scale, .{});
    defer prepared.close() catch unreachable;
    const view = try prepared.view();
    const shaped = try layout.buildStats();
    failing.fail_index = failing.alloc_index;
    var source: ui.commands.Buffer = .{};
    defer source.reset();
    const color: ui.Color = .{ .r = 220, .g = 110, .b = 30, .a = 128 };
    try source.preparedText(.{}, view, color);
    const side: usize = @intFromFloat(20 * size.scale);
    var expected: [1600]u32 = undefined;
    try read(reference, &source, expected[0 .. side * side]);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var table: ui.commands.TransformStorage = .{ .scale = size.scale };
    try buffer.bindTransformStorage(&table);
    try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .x0 = 1 / @as(f64, size.scale), .y0 = 1 / @as(f64, size.scale) }, .{ .width = 20, .height = 20 }, size.scale));
    try buffer.preparedText(.{}, view, color);
    try buffer.endTransform();
    try expectError(error.ResourceInUse, prepared.close());
    var pixels: [256]u32 = undefined;
    try read(surface, &buffer, pixels[0 .. size.width * size.height]);
    var changed: usize = 0;
    for (0..size.height) |y| for (0..size.width) |x| {
        const want = if (x == 0 or y == 0) 0 else expected[(y - 1) * side + x - 1];
        try near(want, pixels[y * size.width + x], 1);
        changed += @intFromBool(pixels[y * size.width + x] != 0);
    };
    try expect(changed > 3);
    try equal(shaped, try layout.buildStats());
}
fn softwarePass(allocator: std.mem.Allocator, app: *z.App, buffer: *const ui.commands.Buffer) !void {
    const surface = try ui.offscreen.Surface.create(app, allocator, .{ .size = .{ .width = 12, .height = 12, .scale = 1.5 }, .max_depth = 4, .transform_source = .{ .width = 20, .height = 20 } });
    defer surface.close() catch unreachable;
    const image = try surface.render(buffer);
    defer image.close() catch unreachable;
}
fn gpuPass(allocator: std.mem.Allocator, domain: *ui.gpu_resources.DeviceDomain, buffer: *const ui.commands.Buffer) !void {
    const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = .{ .width = 12, .height = 12, .scale = 1.5 }, .max_depth = 4, .transform_source = .{ .width = 20, .height = 20 }, .resident_bytes = 0 });
    defer surface.close() catch unreachable;
    try surface.render(buffer);
    const snapshot = try surface.snapshot();
    defer snapshot.close() catch unreachable;
}
const CaptureAllocator = struct {
    child: std.mem.Allocator,
    buffer: *ui.commands.Buffer,
    table: *ui.commands.TransformStorage,
    surface: ?*ui.offscreen.Surface = null,
    triggered: bool = false,
    failure: ?anyerror = null,
    fn allocator(self: *CaptureAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CaptureAllocator = @ptrCast(@alignCast(context));
        if (!self.triggered) if (self.surface) |surface| {
            self.triggered = true;
            self.buffer.reset();
            self.table.storage[0].x0 = 1234;
            expectError(error.Busy, surface.close()) catch |err| {
                self.failure = err;
            };
        };
        return self.child.rawAlloc(length, alignment, ret);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CaptureAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(bytes, alignment, ret);
    }
};
fn transactions(allocator: std.mem.Allocator, app: *z.App) !void {
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var table: ui.commands.TransformStorage = .{};
    try fractional(&buffer, &table, 1.5, 2);
    try std.testing.checkAllAllocationFailures(allocator, softwarePass, .{ app, &buffer });
    var hook: CaptureAllocator = .{ .child = allocator, .buffer = &buffer, .table = &table };
    const surface = try ui.offscreen.Surface.create(app, hook.allocator(), .{ .size = .{ .width = 12, .height = 12, .scale = 1.5 }, .transform_source = .{ .width = 20, .height = 20 } });
    defer surface.close() catch unreachable;
    hook.surface = surface;
    const image = try surface.render(&buffer);
    defer image.close() catch unreachable;
    hook.surface = null;
    try expect(hook.triggered);
    if (hook.failure) |err| return err;
    try equal(@as(usize, 0), buffer.len);
    try near(0x60600000, pixel(try image.view(), 2, 2), 1);
}
fn software(allocator: std.mem.Allocator, app: *z.App, scale: f32) !void {
    const size: z.Size = .{ .width = @intFromFloat(8 * scale), .height = @intFromFloat(8 * scale), .scale = scale };
    const surface = try ui.offscreen.Surface.create(app, allocator, .{ .size = size, .max_depth = 4, .transform_source = .{ .width = 20, .height = 20 } });
    defer surface.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var table: ui.commands.TransformStorage = .{};
    try fractional(&buffer, &table, scale, 2);
    const image = try surface.render(&buffer);
    defer image.close() catch unreachable;
    const view = try image.view();
    try near(0x60600000, pixel(view, 2, 2), 1);
    try near(0xffff0000, pixel(view, 3, 2), 1);
    try near(0x80800000, pixel(view, 4, 2), 1);
    try fractional(&buffer, &table, scale, 2.25);
    const fractional_image = try surface.render(&buffer);
    defer fractional_image.close() catch unreachable;
    try near(0x60600000, pixel(try fractional_image.view(), 2, 2), 1);
    try near(0xa0a00000, pixel(try fractional_image.view(), 4, 2), 1);
    try near(0x20200000, pixel(try fractional_image.view(), 5, 2), 1);
    try largeSource(&buffer, &table, scale);
    const large = try surface.render(&buffer);
    defer large.close() catch unreachable;
    const middle: usize = @intFromFloat(3.5 * scale);
    try near(0xff0000ff, pixel(try large.view(), middle, middle), 1);
    const warm = (try surface.stats()).layers.native_creations;
    for (0..8) |_| {
        const repeat = try surface.render(&buffer);
        try repeat.close();
    }
    try equal(warm, (try surface.stats()).layers.native_creations);
    try matrices(surface, &buffer, &table, size);
    try multiStage(surface, &buffer, &table, size, original_inner);
    try multiStage(surface, &buffer, &table, size, binary_inner);
    try rasterInputs(surface, &buffer, &table, size);
    const reference = try ui.offscreen.Surface.create(app, allocator, .{ .size = .{ .width = @intFromFloat(20 * scale), .height = @intFromFloat(20 * scale), .scale = scale } });
    defer reference.close() catch unreachable;
    try glyph(surface, reference, allocator, size);
    std.debug.print("affine software scale={d}: guarded edges, shared larger source/group, warm objects stable\n", .{scale});
}
fn gpu(allocator: std.mem.Allocator, app: *z.App, scale: f32, driver: ui.gpu_resources.Driver) !void {
    const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const size: z.Size = .{ .width = @intFromFloat(8 * scale), .height = @intFromFloat(8 * scale), .scale = scale };
    const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = size, .max_depth = 4, .resident_bytes = 64 * 1024, .transform_source = .{ .width = 20, .height = 20 } });
    defer surface.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var table: ui.commands.TransformStorage = .{};
    errdefer {
        std.debug.print("affine GPU failure driver={s} scale={d} descriptors={d}\n", .{ @tagName(driver), scale, table.len });
        for (buffer.transformResources(), 0..) |value, index| std.debug.print("  slot={d} matrix={any} source={d}x{d} pixels={d}x{d}\n", .{ index, value.matrix(), value.source_width, value.source_height, value.pixel_width, value.pixel_height });
    }
    var pixels: [256]u32 = undefined;
    try fractional(&buffer, &table, scale, 2);
    try surface.render(&buffer);
    try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
    try near(0x60600000, pixels[2 * size.width + 2], 1);
    try near(0xffff0000, pixels[2 * size.width + 3], 1);
    try near(0x80800000, pixels[2 * size.width + 4], 1);
    try fractional(&buffer, &table, scale, 2.25);
    try surface.render(&buffer);
    try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
    try near(0x60600000, pixels[2 * size.width + 2], 1);
    try near(0xa0a00000, pixels[2 * size.width + 4], 1);
    try near(0x20200000, pixels[2 * size.width + 5], 1);
    try largeSource(&buffer, &table, scale);
    try surface.render(&buffer);
    try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
    const middle: usize = @intFromFloat(3.5 * scale);
    try near(0xff0000ff, pixels[middle * size.width + middle], 1);
    const warm = (try surface.stats()).layers.native_creations;
    for (0..8) |_| try surface.render(&buffer);
    try equal(warm, (try surface.stats()).layers.native_creations);
    try matrices(surface, &buffer, &table, size);
    try rejectedNested(surface, &buffer, &table, size);
    try multiStage(surface, &buffer, &table, size, binary_inner);
    try rasterInputs(surface, &buffer, &table, size);
    const reference = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = .{ .width = @intFromFloat(20 * scale), .height = @intFromFloat(20 * scale), .scale = scale }, .resident_bytes = 0 });
    defer reference.close() catch unreachable;
    try glyph(surface, reference, allocator, size);
    try fractional(&buffer, &table, scale, 2);
    try surface.render(&buffer);
    var before: [256]u32 = undefined;
    try surface.readFrontForTest(before[0 .. size.width * size.height]);
    const committed = (try surface.stats()).layers.committed_frames;
    table.storage[0].pixel_width += 1;
    try expectError(error.InvalidTransform, surface.render(&buffer));
    table.storage[0].pixel_width -= 1;
    try equal(committed, (try surface.stats()).layers.committed_frames);
    try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
    try std.testing.expectEqualSlices(u32, before[0 .. size.width * size.height], pixels[0 .. size.width * size.height]);
    try surface.injectDeviceLossForTest();
    try expectError(error.DeviceLost, surface.render(&buffer));
    try equal(@as(usize, 0), (try surface.stats()).workspace_actual);
    try domain.recreate();
    try surface.render(&buffer);
    try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
    try std.testing.expectEqualSlices(u32, before[0 .. size.width * size.height], pixels[0 .. size.width * size.height]);
    if (scale == 1.5) try std.testing.checkAllAllocationFailures(allocator, gpuPass, .{ domain, &buffer });
    std.debug.print("affine {s} scale={d}: guarded edges, shared larger source/group, warm objects stable\n", .{ @tagName(driver), scale });
}
const NestedContext = struct {
    nested: bool = false,
    draws: u32 = 0,
    fn draw(pointer: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(pointer));
        self.draws += 1;
        frame.clear(0x00ff00);
        if (self.nested) {
            frame.beginTransform(.{ .width = 8, .height = 8 }, original_outer) catch unreachable;
            frame.beginTransform(.{ .width = 4, .height = 4 }, original_inner) catch unreachable;
            const colors = [_]ui.Color{ .{ .r = 255, .g = 0, .b = 0, .a = 128 }, .{ .r = 0, .g = 255, .b = 0, .a = 64 }, ui.Color.rgb(0x0000ff), ui.Color.rgb(0xffff00) };
            for (colors, 0..) |color, index| frame.roundedRect(.{ .x = @as(f32, @floatFromInt(index % 2)) * 2, .y = @as(f32, @floatFromInt(index / 2)) * 2, .width = 2, .height = 2 }, 0, color);
            frame.endTransform() catch unreachable;
            frame.endTransform() catch unreachable;
        }
    }
    fn action(_: *anyopaque, _: u64) void {}
};
fn contextNestedFallback(allocator: std.mem.Allocator, app: *z.App, driver: ui.RenderMode) !void {
    var state: NestedContext = .{};
    var context = ui.Context.init(&state, NestedContext.draw, NestedContext.action);
    context.render_mode = driver;
    const window = try app.createWindow(.{ .width = 64, .height = 64 });
    defer _ = window.destroy() catch unreachable;
    const size = try window.contentSize();
    const reference_size: z.Size = .{ .width = @intFromFloat(8 * size.scale), .height = @intFromFloat(8 * size.scale), .scale = size.scale };
    try context.attach(window);
    try context.prepareTransforms(allocator, .{ .layers = .{ .size = size, .max_depth = 4, .legacy_text = .disabled }, .source_size = .{ .width = 20, .height = 20 } });
    const reference = try ui.offscreen.Surface.create(app, allocator, .{ .size = reference_size, .max_depth = 4, .transform_source = .{ .width = 20, .height = 20 } });
    defer reference.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var table: ui.commands.TransformStorage = .{};
    try base(&buffer, &table, size.scale);
    try buffer.beginTransform(try ui.layers.NativeTransform.init(original_inner, .{ .width = 4, .height = 4 }, size.scale));
    try quadrants(&buffer, false);
    try buffer.endTransform();
    const first = try allocator.alloc(u32, reference_size.width * reference_size.height);
    defer allocator.free(first);
    try read(reference, &buffer, first);
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try equal(@as(u32, 1), state.draws);
    try equal(@as(u64, 1), context.gpu_frames);
    state.nested = true;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try equal(@as(u32, 2), state.draws);
    try equal(@as(u64, 1), context.gdi_frames);
    try equal(@as(u64, 1), context.fallbacks);
    try equal(@as(u64, 1), context.gpu_frames);
    _ = c.GdiFlush();
    const outer = try ui.layers.NativeTransform.init(original_outer, .{ .width = 8, .height = 8 }, size.scale);
    for (0..reference_size.height) |y| for (0..reference_size.width) |x| {
        const transparent = planeOracle(outer, x, y, size.scale, first, reference_size.width, reference_size.height);
        const alpha: f128 = @as(f128, @floatFromInt(transparent >> 24)) / 255;
        const green = @as(u32, @intFromFloat(@round(@as(f128, @floatFromInt((transparent >> 8) & 255)) + 255 * (1 - alpha))));
        const expected = (transparent & 0x00ff00ff) | (green << 8) | 0xff000000;
        try near(expected, context.renderer.pixels.?[y * size.width + x] | 0xff000000, 2);
    };
    state.nested = false;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try equal(@as(u32, 3), state.draws);
    try equal(@as(u64, 2), context.gpu_frames);
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug.deinit() == .leak) @panic("affine renderer leaked");
    const allocator = debug.allocator();
    var diagnostics: z.diagnostics.Recorder(32) = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = diagnostics.sink() });
    defer app.deinit();
    const before = if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS) else zlc_layer_live_objects() + zlc_test_live_image_objects();
    try cairoQuantization();
    try transactions(allocator, app);
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        try software(allocator, app, scale);
        if (comptime builtin.os.tag == .windows and ui.gpu_offscreen.available) {
            for ([_]ui.gpu_resources.Driver{ .hardware, .warp }) |driver| try gpu(allocator, app, scale, driver);
        }
    }
    if (builtin.os.tag == .windows) {
        if (ui.gpu_offscreen.available) {
            try contextNestedFallback(allocator, app, .hardware);
            try contextNestedFallback(allocator, app, .warp);
            var values: [32]z.diagnostics.Diagnostic = undefined;
            const count = diagnostics.snapshot(&values).count;
            try equal(@as(usize, 2), count);
            for (values[0..count]) |entry| {
                try equal(error.UnsupportedTransformPrecision, entry.err.?);
                try equal(.renderer, entry.domain);
                try equal(null, entry.code);
            }
        }
        // Font subsystem initialization may keep its documented process cache;
        // every explicit layer target/DC/bitmap must still be balanced.
        try expect(c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS) <= before + 1);
        if (ui.gpu_offscreen.available) try equal(@as(u32, 0), ui.d3d11.globalResourceCount());
    } else try equal(before, zlc_layer_live_objects() + zlc_test_live_image_objects());
}
