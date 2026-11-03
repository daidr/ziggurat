//! The Metal renderer draws what the Core Graphics renderer draws: the same
//! commands replayed on both compare pixel for pixel (text by its ink), and
//! a window's frames show on its CAMetalLayer, under its subviews, with
//! frames the GPU does not draw going to the software plane.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const metal = ui.metal;
const commands = ui.commands;
const drawing = ui.drawing;
const Color = commands.Color;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;

fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
const width = 192;
const height = 128;

fn channel(value: u32, shift: u5) i32 {
    return @intCast((value >> shift) & 255);
}
fn difference(a: u32, b: u32) i32 {
    var most: i32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| most = @max(most, @as(i32, @intCast(@abs(channel(a, shift) - channel(b, shift)))));
    return most;
}

const Images = struct {
    lease: drawing.Lease,
    image_pixels: [8 * 8 * 4]u8 = undefined,
    image_levels: [4]drawing.ImageLevel = undefined,
    level_pixels: [3][16 * 4]u8 = undefined,
    image: drawing.ImageView = undefined,
    mask_pixels: [12 * 10]u8 = undefined,
    mask: drawing.CoverageView = undefined,
    fn init(self: *Images, scale: f32) !void {
        self.lease = drawing.Lease.init(std.Thread.getCurrentId());
        // A checker of opaque red and translucent blue, with its mips.
        for (0..8) |y| for (0..8) |x| {
            const px = self.image_pixels[(y * 8 + x) * 4 ..][0..4];
            px.* = if ((x / 2 + y / 2) % 2 == 0) .{ 0, 0, 255, 255 } else .{ 128, 0, 0, 128 };
        };
        self.image_levels[0] = .{ .pixels = &self.image_pixels, .byte_len = self.image_pixels.len, .width = 8, .height = 8, .stride = 32 };
        var size: u32 = 4;
        for (0..3) |level| {
            @memset(&self.level_pixels[level], 96);
            self.image_levels[level + 1] = .{ .pixels = &self.level_pixels[level], .byte_len = size * size * 4, .width = size, .height = size, .stride = size * 4 };
            size /= 2;
        }
        self.image = .{ .lease = &self.lease, .identity = try drawing.reserveRasterIdentity(), .levels = &self.image_levels };
        for (0..10) |y| for (0..12) |x| {
            self.mask_pixels[y * 12 + x] = @intCast((x * 255) / 11);
        };
        self.mask = .{ .lease = &self.lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &self.mask_pixels, .width = 12, .height = 10, .stride = 12, .origin_x = 0, .origin_y = 0, .scale = scale } };
    }
};

fn scene(buffer: *commands.Buffer, images: *Images) !void {
    try buffer.fill(.{ .x = 0, .y = 0, .width = width, .height = height }, 0xf4f1ea);
    try buffer.fill(.{ .x = 4.5, .y = 4.25, .width = 30, .height = 20.5 }, 0x274c77);
    try buffer.roundedRect(.{ .x = 40, .y = 4, .width = 40, .height = 24 }, 8, rgba(0xe0, 0x40, 0x20, 0xff));
    try buffer.roundedRect(.{ .x = 86, .y = 4, .width = 30, .height = 24 }, 6, rgba(0x10, 0x80, 0x40, 0x80));
    try buffer.strokeRect(.{ .x = 122, .y = 4.5, .width = 40, .height = 24 }, 7, 3, rgba(0x30, 0x30, 0x90, 0xff));
    const stops = [_]commands.brushes.Stop{
        .{ .offset = 0, .color = rgba(255, 0, 0, 255) },
        .{ .offset = 0.5, .color = rgba(0, 255, 0, 160) },
        .{ .offset = 1, .color = rgba(0, 0, 255, 255) },
    };
    try buffer.gradientRect(.{ .x = 4, .y = 34, .width = 56, .height = 24 }, 4, .{ .linear = .{ .start = .{ .x = 4, .y = 34 }, .end = .{ .x = 60, .y = 34 }, .stops = &stops } });
    try buffer.gradientRect(.{ .x = 66, .y = 34, .width = 40, .height = 24 }, 0, .{ .radial = .{ .center = .{ .x = 86, .y = 46 }, .radius = .{ .x = 20, .y = 12 }, .stops = &stops } });
    try buffer.gradientRect(.{ .x = 112, .y = 34, .width = 24, .height = 24 }, 12, .{ .conic = .{ .center = .{ .x = 124, .y = 46 }, .start_angle_radians = 0.5, .stops = &stops } });
    try buffer.gradientStrokeRect(.{ .x = 142, .y = 34, .width = 44, .height = 24 }, 6, 4, .{ .linear = .{ .start = .{ .x = 142, .y = 0 }, .end = .{ .x = 152, .y = 0 }, .stops = &stops, .spread = .reflect } });
    try buffer.pushClip(.{ .x = 10.5, .y = 64, .width = 30, .height = 18.5 });
    try buffer.fill(.{ .x = 0, .y = 60, .width = 100, .height = 40 }, 0x8a2be2);
    try buffer.popClip();
    try buffer.image(.{ .x = 48, .y = 64, .width = 24, .height = 24 }, images.image, .{ .sampling = .nearest });
    try buffer.image(.{ .x = 78, .y = 64, .width = 24, .height = 16 }, images.image, .{ .fit = .stretch, .opacity = 200 });
    try buffer.coverage(.{ .x = 110, .y = 66 }, images.mask, rgba(0x20, 0x20, 0x20, 0xff));
    try buffer.text(.{ .x = 4, .y = 92, .width = 184, .height = 30 }, "Metal 图形 / 日本語", 0x101820);
    try buffer.finish();
}

/// The frame's pixels from both renderers at `scale`, compared.
fn compare(scale: f32) !bool {
    var images: Images = undefined;
    try images.init(scale);
    var buffer: commands.Buffer = .{};
    defer buffer.reset();
    try scene(&buffer, &images);
    const pw: u32 = @intFromFloat(@round(width * scale));
    const ph: u32 = @intFromFloat(@round(height * scale));
    const size: z.Size = .{ .width = pw, .height = ph, .scale = scale };

    var software: ui.SoftwareRenderer = .{};
    defer software.deinit();
    var dummy: u8 = 0;
    try software.uploadImage(images.image);
    try software.uploadCoverage(images.mask);
    try software.begin(.{ .native_context = &dummy, .size = size });
    try software.replayBuffer(&buffer);

    var gpu: metal.Renderer = .{};
    defer gpu.deinit();
    try gpu.init(.{});
    try gpu.uploadImage(images.image);
    try gpu.uploadCoverage(images.mask);
    try gpu.beginOffscreen(size, false);
    try std.testing.expect(gpu.prepareEffects(&buffer));
    try std.testing.expect(gpu.holdsFrame(&buffer));
    try gpu.replayBuffer(&buffer);
    const pixels = try std.heap.page_allocator.alloc(u8, @as(usize, pw) * ph * 4);
    defer std.heap.page_allocator.free(pixels);
    try gpu.endOffscreen(pixels, @as(usize, pw) * 4);
    try std.testing.expectEqual(@as(u32, 1), gpu.atlasLevelsForTest());

    const text_top: u32 = @intFromFloat(90 * scale);
    const linear_left: u32 = @intFromFloat(78 * scale);
    const linear_right: u32 = @intFromFloat(102 * scale);
    const linear_top: u32 = @intFromFloat(64 * scale);
    const linear_bottom: u32 = @intFromFloat(80 * scale);
    var linear_sums: [2][3]i64 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    var shape_misses: usize = 0;
    var tiles: [64 * 40]u32 = @splat(0);
    var samples: [64 * 40][4]u32 = undefined;
    var worst: i32 = 0;
    var worst_at: [2]u32 = .{ 0, 0 };
    var software_ink: usize = 0;
    var gpu_ink: usize = 0;
    for (0..ph) |y| for (0..pw) |x| {
        const at = (y * pw + x) * 4;
        const got = (@as(u32, pixels[at + 2]) << 16) | (@as(u32, pixels[at + 1]) << 8) | pixels[at];
        const want = zlc_test_raw_pixel(software.native.?, @intCast(x), @intCast(y)) & 0xffffff;
        if (y >= text_top) {
            if (difference(want, 0xf4f1ea) > 48) software_ink += 1;
            if (difference(got, 0xf4f1ea) > 48) gpu_ink += 1;
            continue;
        }
        // Core Graphics filters a linearly sampled image with its own
        // kernel: compare the region's average color instead.
        if (x >= linear_left and x < linear_right and y >= linear_top and y < linear_bottom) {
            inline for (.{ 0, 8, 16 }, 0..) |shift, k| {
                linear_sums[0][k] += channel(got, shift);
                linear_sums[1][k] += channel(want, shift);
            }
            continue;
        }
        const d = difference(got, want);
        if (d > worst) {
            worst = d;
            worst_at = .{ @intCast(x), @intCast(y) };
        }
        // Antialiased edges may round differently; interiors may not.
        if (d > 24) {
            shape_misses += 1;
            const tile = (y / 8) * 64 + x / 8;
            if (tile < tiles.len) {
                if (tiles[tile] == 0) samples[tile] = .{ @intCast(x), @intCast(y), got, want };
                tiles[tile] += 1;
            }
        }
    };
    for (tiles, 0..) |count, tile| if (count != 0) {
        const sample = samples[tile];
        std.debug.print("  tile {d},{d}: {d} misses, first at {d},{d} metal {x:0>6} software {x:0>6}\n", .{ (tile % 64) * 8, (tile / 64) * 8, count, sample[0], sample[1], sample[2], sample[3] });
    };
    software.abort();
    std.debug.print("metal parity at scale {d}: worst {d} at {d},{d}, {d} pixels beyond 24, ink {d} vs {d}\n", .{ scale, worst, worst_at[0], worst_at[1], shape_misses, software_ink, gpu_ink });
    const ink_ratio = @as(f64, @floatFromInt(gpu_ink)) / @as(f64, @floatFromInt(software_ink));
    const linear_pixels: i64 = @intCast(@as(u64, linear_right - linear_left) * (linear_bottom - linear_top));
    var linear_close = true;
    for (0..3) |k| {
        const got = @divTrunc(linear_sums[0][k], linear_pixels);
        const want = @divTrunc(linear_sums[1][k], linear_pixels);
        std.debug.print("  linear image channel {d}: metal {d} software {d}\n", .{ k, got, want });
        if (@abs(got - want) > 6) linear_close = false;
    }
    return linear_close and shape_misses * 400 < @as(usize, pw) * text_top and software_ink > 100 and gpu_ink > 100 and ink_ratio > 0.8 and ink_ratio < 1.25;
}

const Probe = struct {
    window: z.Window = undefined,
    content: ui.Context = undefined,
    images: Images = undefined,
    draw_image: bool = false,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        frame.rect(.{ .x = 10, .y = 10, .width = 60, .height = 40 }, 0x274c77);
        frame.roundedRect(.{ .x = 80, .y = 10, .width = 60, .height = 40 }, 10, rgba(0xe0, 0x40, 0x20, 0xff));
        frame.label(.{ .x = 10, .y = 60, .width = 280, .height = 30 }, "Metal / 图形", 0x123456);
        if (self.draw_image) frame.image(.{ .x = 200, .y = 10, .width = 32, .height = 32 }, self.images.image, .{}) catch {};
    }
    fn action(_: *anyopaque, _: u64) void {}
};

fn windowFrames(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    probe.window = try app.createWindow(.{ .title = "Metal", .width = 320, .height = 200 });
    probe.content = ui.Context.init(&probe, Probe.draw, Probe.action);
    try probe.content.attach(probe.window);
    try std.testing.expect(probe.content.gpu_renderer.native != null);
    try probe.images.init(1);
    probe.window.show();
    probe.content.gpu_renderer.captureForTest(true);
    metal.Renderer.displayForTest("Metal");
    try app.dispatch();
    std.debug.print("window frames: gpu {d}, software {d}, fallbacks {d}\n", .{ probe.content.gpu_frames, probe.content.gdi_frames, probe.content.fallbacks });
    try std.testing.expect(probe.content.gpu_frames >= 1);
    const gpu = &probe.content.gpu_renderer;
    try std.testing.expect(gpu.layerShownForTest());
    try std.testing.expect(gpu.layerUnderSubviewsForTest());
    try std.testing.expectEqual(@as(c_int, 0), gpu.layerContentsFlippedForTest());
    const scale: u32 = @intFromFloat(probe.content.last_paint_size.?.scale);
    try std.testing.expectEqual(@as(u32, 0xff274c77), gpu.pixelForTest(20 * scale, 20 * scale));
    try std.testing.expectEqual(@as(u32, 0xffe04020), gpu.pixelForTest(110 * scale, 30 * scale));
    try std.testing.expectEqual(@as(u32, 0xffffffff), gpu.pixelForTest(300 * scale, 180 * scale));

    // An image not yet uploaded draws in software, which hides the layer;
    // the next frame has it and draws on the GPU again.
    probe.draw_image = true;
    const software_before = probe.content.gdi_frames;
    metal.Renderer.displayForTest("Metal");
    try std.testing.expectEqual(software_before + 1, probe.content.gdi_frames);
    try std.testing.expect(!gpu.layerShownForTest());
    const gpu_before = probe.content.gpu_frames;
    metal.Renderer.displayForTest("Metal");
    try std.testing.expectEqual(gpu_before + 1, probe.content.gpu_frames);
    try std.testing.expect(gpu.layerShownForTest());

    // A capture of the window draws in software without hiding the layer.
    const shot = try probe.window.capture(allocator);
    allocator.free(shot.pixels);
    try std.testing.expect(gpu.layerShownForTest());
    try std.testing.expectEqual(@as(usize, 0), probe.content.fallbacks);

    // A new size presents with the transaction.
    const before = gpu.stats();
    try probe.window.resize(400, 240);
    metal.Renderer.displayForTest("Metal");
    const after = gpu.stats();
    try std.testing.expect(after.resizes > before.resizes);
    try std.testing.expect(after.transaction_presents > before.transaction_presents);
    try std.testing.expectEqual(@as(u32, 0xffffffff), gpu.pixelForTest(390 * scale, 230 * scale));
    _ = try probe.window.destroy();
    try app.dispatch();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var matched = true;
    for ([_]f32{ 1, 2, 1.5 }) |scale| if (!try compare(scale)) {
        matched = false;
    };
    try windowFrames(gpa.allocator());
    try std.testing.expect(matched);
    try std.testing.expectEqual(@as(u32, 0), metal.liveObjects());
    std.debug.print("metal smoke ok\n", .{});
}
