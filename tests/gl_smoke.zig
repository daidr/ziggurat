//! The OpenGL renderer draws what the cairo renderer draws: the same
//! commands replayed on both compare pixel for pixel (text by its ink), and
//! a window's frames show through GDK's OpenGL context of its area, with
//! frames OpenGL cannot draw yet (shader programs not prepared, images not
//! uploaded) going to the software renderer, a frame drawing only what
//! changed over the one the renderer kept, groups (opacity, masks, Gaussian
//! filters), masked clips, opacities, raster transforms, gradients mixed in
//! other spaces, shader effects, backdrop effects and loading indicators
//! drawing what software draws, and device domains and offscreen surfaces
//! keeping their textures through device loss. Software rasterizers (llvmpipe) are
//! allowed here: run with ZIGGURAT_GL=on.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const gl = ui.gl;
const zio = @import("ziggurat_io");
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
    try buffer.text(.{ .x = 4, .y = 92, .width = 184, .height = 30 }, "OpenGL 图形 / 日本語", 0x101820);
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

    var gpu: gl.Renderer = .{};
    defer gpu.deinit();
    try gpu.init(.{ .own_context = true, .allow_software = true });
    try gpu.uploadImage(images.image);
    try gpu.uploadCoverage(images.mask);
    try gpu.beginOffscreen(size, false);
    try std.testing.expect(gpu.prepareEffects(&buffer));
    try std.testing.expect(gpu.holdsFrame(&buffer));
    try gpu.replayBuffer(&buffer);
    const pixels = try std.heap.page_allocator.alloc(u8, @as(usize, pw) * ph * 4);
    defer std.heap.page_allocator.free(pixels);
    try gpu.endOffscreen(pixels, @as(usize, pw) * 4);

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
        std.debug.print("  tile {d},{d}: {d} misses, first at {d},{d} gl {x:0>6} software {x:0>6}\n", .{ (tile % 64) * 8, (tile / 64) * 8, count, sample[0], sample[1], sample[2], sample[3] });
    };
    software.abort();
    std.debug.print("gl parity at scale {d}: worst {d} at {d},{d}, {d} pixels beyond 24, ink {d} vs {d}\n", .{ scale, worst, worst_at[0], worst_at[1], shape_misses, software_ink, gpu_ink });
    const ink_ratio = @as(f64, @floatFromInt(gpu_ink)) / @as(f64, @floatFromInt(software_ink));
    const linear_pixels: i64 = @intCast(@as(u64, linear_right - linear_left) * (linear_bottom - linear_top));
    var linear_close = true;
    for (0..3) |k| {
        const got = @divTrunc(linear_sums[0][k], linear_pixels);
        const want = @divTrunc(linear_sums[1][k], linear_pixels);
        std.debug.print("  linear image channel {d}: gl {d} software {d}\n", .{ k, got, want });
        if (@abs(got - want) > 6) linear_close = false;
    }
    return linear_close and shape_misses * 400 < @as(usize, pw) * text_top and software_ink > 100 and gpu_ink > 100 and ink_ratio > 0.8 and ink_ratio < 1.25;
}

const Probe = struct {
    window: z.Window = undefined,
    content: ui.Context = undefined,
    images: Images = undefined,
    draw_image: bool = false,
    effect: ?*ui.shader.Program = null,
    effect_values: ui.shader.Values = undefined,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        frame.rect(.{ .x = 10, .y = 10, .width = 60, .height = 40 }, 0x274c77);
        frame.roundedRect(.{ .x = 80, .y = 10, .width = 60, .height = 40 }, 10, rgba(0xe0, 0x40, 0x20, 0xff));
        frame.label(.{ .x = 10, .y = 60, .width = 280, .height = 30 }, "OpenGL / 图形", 0x123456);
        if (self.draw_image) frame.image(.{ .x = 200, .y = 10, .width = 32, .height = 32 }, self.images.image, .{}) catch {};
        if (self.effect) |program| {
            frame.beginEffect(.{ .x = 240, .y = 100, .width = 30, .height = 30 }, .{ .program = program, .values = &self.effect_values }, .{}) catch return;
            frame.rect(.{ .x = 240, .y = 100, .width = 30, .height = 30 }, 0xff0000);
            frame.endEffect() catch {};
        }
    }
    fn action(_: *anyopaque, _: u64) void {}
};

fn windowFrames(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    probe.window = try app.createWindow(.{ .title = "OpenGL", .width = 320, .height = 200 });
    probe.content = ui.Context.init(&probe, Probe.draw, Probe.action);
    try probe.content.attach(probe.window);
    try std.testing.expect(probe.content.gpu_renderer.native != null);
    try probe.images.init(1);
    probe.window.show();
    try app.dispatch();
    probe.content.gpu_renderer.captureForTest(true);
    gl.Renderer.displayForTest("OpenGL");
    std.debug.print("window frames: gpu {d}, software {d}, fallbacks {d}, renderer {s}\n", .{ probe.content.gpu_frames, probe.content.gdi_frames, probe.content.fallbacks, gl.probeRenderer() });
    try std.testing.expect(probe.content.gpu_frames >= 1);
    const gpu = &probe.content.gpu_renderer;
    try std.testing.expect(gpu.layerShownForTest());
    try std.testing.expect(gpu.backendForTest() == .gdk);
    const scale: u32 = @intFromFloat(probe.content.last_paint_size.?.scale);
    try std.testing.expectEqual(@as(u32, 0xff274c77), gpu.pixelForTest(20 * scale, 20 * scale));
    try std.testing.expectEqual(@as(u32, 0xffe04020), gpu.pixelForTest(110 * scale, 30 * scale));
    try std.testing.expectEqual(@as(u32, 0xffffffff), gpu.pixelForTest(300 * scale, 180 * scale));

    // An image not yet uploaded draws in software; the next frame has it
    // and draws with OpenGL again.
    probe.draw_image = true;
    const software_before = probe.content.gdi_frames;
    gl.Renderer.displayForTest("OpenGL");
    try std.testing.expectEqual(software_before + 1, probe.content.gdi_frames);
    try std.testing.expect(!gpu.layerShownForTest());
    const gpu_before = probe.content.gpu_frames;
    const partial_before = probe.content.damageStats().gpu_partial_frames;
    gl.Renderer.displayForTest("OpenGL");
    try std.testing.expectEqual(gpu_before + 1, probe.content.gpu_frames);
    try std.testing.expect(gpu.layerShownForTest());
    // The frame the renderer kept is the last OpenGL frame, without the
    // image: only the image's pixels are drawn again over it.
    const damaged = probe.content.damageStats();
    std.debug.print("partial gpu frame: {d} rectangles, full {}\n", .{ damaged.gpu_last.len, damaged.gpu_last.full });
    try std.testing.expectEqual(partial_before + 1, damaged.gpu_partial_frames);
    try std.testing.expect(!damaged.gpu_last.full and damaged.gpu_last.len != 0);
    try std.testing.expectEqual(@as(u32, 0xff274c77), gpu.pixelForTest(20 * scale, 20 * scale));
    try std.testing.expectEqual(@as(u32, 0xffe04020), gpu.pixelForTest(110 * scale, 30 * scale));
    try std.testing.expectEqual(@as(u32, 0xffffffff), gpu.pixelForTest(300 * scale, 180 * scale));
    try std.testing.expect(near(0xff0000, gpu.pixelForTest(203 * scale, 13 * scale) & 0xffffff, 2));
    // Nothing changed: nothing is drawn again, and the frame stays.
    gl.Renderer.displayForTest("OpenGL");
    try std.testing.expectEqual(partial_before + 2, probe.content.damageStats().gpu_partial_frames);
    try std.testing.expect(probe.content.damageStats().gpu_last.isNone());
    try std.testing.expectEqual(@as(u32, 0xff274c77), gpu.pixelForTest(20 * scale, 20 * scale));
    try std.testing.expect(near(0xff0000, gpu.pixelForTest(203 * scale, 13 * scale) & 0xffffff, 2));
    try std.testing.expect(gpu.stats().partial_frames >= 2);
    // The text texture drawn once is drawn from the cache after.
    try std.testing.expect(gpu.textStats().hits > 0);

    // A capture of the window draws in software.
    const shot = try probe.window.capture(allocator);
    allocator.free(shot.pixels);
    try std.testing.expectEqual(@as(usize, 0), probe.content.fallbacks);

    // A shader effect is software's to draw; the frame after it without one
    // is OpenGL's again.
    var diagnostic: ui.shader.Diagnostic = .{};
    const invert = try ui.shader.compile(allocator,
        \\vec4 color(vec2 position, vec4 pixel) {
        \\    return vec4(pixel.a - pixel.rgb, pixel.a);
        \\}
    , .{}, &diagnostic);
    defer invert.destroy();
    probe.effect_values = ui.shader.Values.init(invert);
    probe.effect = invert;
    try probe.content.prepareShaderEffects(allocator, .{});
    const effect_before = probe.content.gdi_frames;
    gl.Renderer.displayForTest("OpenGL");
    try std.testing.expectEqual(effect_before + 1, probe.content.gdi_frames);
    try std.testing.expect(!gpu.layerShownForTest());
    // Once its program is linked, OpenGL draws it.
    try std.testing.expectEqual(@as(usize, 1), try probe.content.prepareGpuShaders(allocator, &.{.{ .program = invert, .target = .element }}));
    const linked_before = probe.content.gpu_frames;
    gl.Renderer.displayForTest("OpenGL");
    try std.testing.expectEqual(linked_before + 1, probe.content.gpu_frames);
    try std.testing.expect(gpu.layerShownForTest());
    try std.testing.expect(gpu.effectPasses() > 0);
    try std.testing.expect(near(0x00ffff, gpu.pixelForTest(255 * scale, 115 * scale) & 0xffffff, 1));
    probe.effect = null;
    const gpu_again = probe.content.gpu_frames;
    gl.Renderer.displayForTest("OpenGL");
    try std.testing.expectEqual(gpu_again + 1, probe.content.gpu_frames);
    try std.testing.expect(gpu.layerShownForTest());

    // A new size makes the framebuffers again (where the X server's
    // window manager lets the window take it).
    const before = gpu.stats();
    try probe.window.resize(400, 240);
    var waited: usize = 0;
    while ((try probe.window.contentSize()).width < 400 * scale and waited < 100) : (waited += 1) {
        try app.dispatch();
        zio.sleep(5 * std.time.ns_per_ms);
    }
    gl.Renderer.displayForTest("OpenGL");
    if ((try probe.window.contentSize()).width >= 400 * scale) {
        try std.testing.expect(gpu.stats().resizes > before.resizes);
        try std.testing.expectEqual(@as(u32, 0xffffffff), gpu.pixelForTest(390 * scale, 230 * scale));
    } else std.debug.print("the window kept its size: no resize checked\n", .{});
    try std.testing.expectEqual(@as(usize, 0), probe.content.fallbacks);
    _ = try probe.window.destroy();
    try app.dispatch();
}

fn effectAt(pixels: []const u32, scale: f32, stride: usize, x: f32, y: f32) u32 {
    const px: usize = @intFromFloat(@floor(x * scale));
    const py: usize = @intFromFloat(@floor(y * scale));
    return pixels[py * stride + px] & 0xffffff;
}
fn near(expected: u32, actual: u32, tolerance: i32) bool {
    return difference(expected, actual) <= tolerance;
}

const LayerScene = struct {
    kernel: *ui.gaussian.Kernel,
    mask: drawing.CoverageView,
    failure: ?anyerror = null,
    paints: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *LayerScene = @ptrCast(@alignCast(ptr));
        self.paints += 1;
        self.record(frame) catch |err| {
            self.failure = err;
        };
        if (frame.failure) |err| self.failure = err;
    }
    fn record(self: *LayerScene, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        frame.rect(.{ .x = 0, .y = 60, .width = layer_width, .height = 20 }, 0x202020);
        // Overlapping content composited once at half opacity.
        try frame.beginGroup(.{ .x = 10, .y = 10, .width = 50, .height = 40 }, .{ .opacity = 128 });
        frame.rect(.{ .x = 10, .y = 10, .width = 30, .height = 30 }, 0xff0000);
        frame.rect(.{ .x = 25, .y = 20, .width = 35, .height = 30 }, 0x0000ff);
        try frame.endGroup();
        // Through a mask fading from left to right, under a clip.
        try frame.pushClip(.{ .x = 66, .y = 8, .width = 26, .height = 30 });
        try frame.beginGroup(.{ .x = 70, .y = 10, .width = 24, .height = 20 }, .{ .mask = self.mask, .mask_origin = .{ .x = 70, .y = 10 } });
        frame.rect(.{ .x = 60, .y = 0, .width = 50, .height = 50 }, 0x208040);
        try frame.endGroup();
        try frame.popClip();
        // Filtered, over the dark band.
        try frame.gaussianScope(.{ .x = 110, .y = 40, .width = 40, .height = 30 }, try self.kernel.view(), .{ .opacity = 220 }, self, blurred);
        // Turned and scaled, with a group inside its source.
        const angle: f64 = 0.35;
        try frame.beginTransform(.{ .width = 30, .height = 20 }, .{ .xx = 1.25 * @cos(angle), .yx = 1.25 * @sin(angle), .xy = -1.25 * @sin(angle), .yy = 1.25 * @cos(angle), .x0 = 30, .y0 = 85 });
        frame.rect(.{ .x = 0, .y = 0, .width = 30, .height = 20 }, 0x3060a0);
        try frame.beginGroup(.{ .x = 5, .y = 5, .width = 20, .height = 10 }, .{ .opacity = 160 });
        frame.rect(.{ .x = 5, .y = 5, .width = 20, .height = 10 }, 0xffcc00);
        try frame.endGroup();
        try frame.endTransform();
        // Gradients mixed in Oklab and in linear sRGB.
        const stops = [_]commands.brushes.Stop{ .{ .offset = 0, .color = rgba(0, 0, 255, 255) }, .{ .offset = 1, .color = rgba(255, 255, 0, 255) } };
        frame.gradientRect(.{ .x = 110, .y = 90, .width = 80, .height = 20 }, 0, .{ .linear = .{ .start = .{ .x = 110, .y = 0 }, .end = .{ .x = 190, .y = 0 }, .stops = &stops, .interpolation = .oklab } });
        frame.gradientRect(.{ .x = 110, .y = 114, .width = 80, .height = 20 }, 0, .{ .linear = .{ .start = .{ .x = 110, .y = 0 }, .end = .{ .x = 190, .y = 0 }, .stops = &stops, .interpolation = .srgb_linear } });
        // A rounded clip masks each drawing by itself: overlapping ones
        // draw in turn, the others together.
        try frame.pushRoundedClip(.{ .x = 152, .y = 4, .width = 44, .height = 32 }, 10, null);
        frame.rect(.{ .x = 140, .y = 0, .width = 30, .height = 26 }, 0xff0000);
        frame.rect(.{ .x = 160, .y = 12, .width = 40, .height = 30 }, 0x0000ff);
        frame.rect(.{ .x = 186, .y = 0, .width = 14, .height = 8 }, 0x00a000);
        try frame.popClip();
        // An opacity fades each drawing by itself: the blue shows the red
        // beneath it; a group inside fades as one drawing.
        try frame.pushOpacity(128);
        frame.rect(.{ .x = 74, .y = 96, .width = 20, .height = 20 }, 0xff0000);
        frame.rect(.{ .x = 84, .y = 106, .width = 22, .height = 30 }, 0x0000ff);
        try frame.beginGroup(.{ .x = 74, .y = 120, .width = 10, .height = 16 }, .{});
        frame.rect(.{ .x = 74, .y = 120, .width = 10, .height = 16 }, 0x00a000);
        frame.rect(.{ .x = 74, .y = 128, .width = 10, .height = 8 }, 0xffff00);
        try frame.endGroup();
        try frame.popOpacity();
    }
    fn blurred(_: *anyopaque, frame: *ui.Frame) !void {
        frame.rect(.{ .x = 120, .y = 45, .width = 20, .height = 20 }, 0x40c040);
    }
    fn action(_: *anyopaque, _: u64) void {}
};

/// Draw the layer scene on the GPU or in software and return its pixels.
fn renderLayers(allocator: std.mem.Allocator, app: *z.App, scene_state: *LayerScene, software: bool, pixels: *std.ArrayList(u32)) !gl.Stats {
    const title: [*:0]const u8 = if (software) "Layers software" else "Layers gl";
    const window = try app.createWindow(.{ .title = std.mem.span(title), .width = layer_width, .height = layer_height });
    defer _ = window.destroy() catch unreachable;
    var context = ui.Context.init(scene_state, LayerScene.draw, LayerScene.action);
    if (software) context.render_mode = .gdi;
    context.semantics_enabled = false;
    try context.attach(window);
    window.show();
    try app.dispatch();
    const size = try window.contentSize();
    const options: ui.layers.Options = .{ .size = size, .max_depth = 3, .legacy_text = .disabled };
    const source: ui.layout.Size = .{ .width = @as(f32, @floatFromInt(size.width)) / size.scale, .height = @as(f32, @floatFromInt(size.height)) / size.scale };
    try context.prepareTransforms(allocator, .{ .layers = options, .source_size = source });
    try context.prepareGaussianWorkspace(allocator, .{ .layers = options, .source_size = source, .max_radius = 32 });
    try context.uploadCoverage(scene_state.mask);
    try pixels.resize(allocator, @as(usize, size.width) * size.height);
    // A window makes its OpenGL context at its first frame, which uploads
    // the mask for the next and draws in software.
    if (!software) {
        gl.Renderer.displayForTest(title);
        if (scene_state.failure) |err| return err;
        try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
        context.window.?.invalidate();
    }
    const before = scene_state.paints;
    if (!software) context.gpu_renderer.captureForTest(true);
    const stats_before = if (software) gl.Stats{} else context.gpu_renderer.stats();
    gl.Renderer.displayForTest(title);
    if (scene_state.failure) |err| return err;
    try std.testing.expectEqual(before + 1, scene_state.paints);
    if (software) {
        try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
        for (pixels.items, 0..) |*out, i| out.* = zlc_test_raw_pixel(context.renderer.native.?, @intCast(i % size.width), @intCast(i / size.width));
        return .{};
    }
    std.debug.print("layer frames: gpu {d}, software {d}, fallbacks {d}\n", .{ context.gpu_frames, context.gdi_frames, context.fallbacks });
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    try std.testing.expectEqual(@as(usize, 0), context.fallbacks);
    try context.gpu_renderer.pixelsForTest(pixels.items, size.width, size.height);
    const after = context.gpu_renderer.stats();
    return .{ .layers = after.layers - stats_before.layers, .filter_passes = after.filter_passes - stats_before.filter_passes };
}

fn layerFrames(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const probe = try app.createWindow(.{ .width = layer_width, .height = layer_height });
    const size = try probe.contentSize();
    _ = try probe.destroy();
    const bank = try ui.gaussian.Bank.create(allocator, std.Thread.getCurrentId(), .{});
    defer bank.close() catch unreachable;
    const kernel = try bank.prepare(.{ .spec = .{ .sigma = 2, .scale = size.scale } });
    defer kernel.close() catch unreachable;
    // A mask of the group's physical pixels, clear on the left.
    const mask_width: u32 = @intFromFloat(@ceil(24 * size.scale));
    const mask_height: u32 = @intFromFloat(@ceil(20 * size.scale));
    const mask_pixels = try allocator.alloc(u8, @as(usize, mask_width) * mask_height);
    defer allocator.free(mask_pixels);
    for (0..mask_height) |y| for (0..mask_width) |x| {
        mask_pixels[y * mask_width + x] = @intCast((x * 255) / (mask_width - 1));
    };
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    var scene_state: LayerScene = .{ .kernel = kernel, .mask = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = mask_pixels, .width = mask_width, .height = mask_height, .stride = mask_width, .origin_x = 0, .origin_y = 0, .scale = size.scale } } };

    var gpu: std.ArrayList(u32) = .empty;
    defer gpu.deinit(allocator);
    var software: std.ArrayList(u32) = .empty;
    defer software.deinit(allocator);
    const stats = try renderLayers(allocator, app, &scene_state, false, &gpu);
    _ = try renderLayers(allocator, app, &scene_state, true, &software);
    // Five groups (one filtered), a transform, and the rounded clip's mask
    // drawn as two runs; two filter passes.
    std.debug.print("gl layers: {d} composited\n", .{stats.layers});
    try std.testing.expectEqual(@as(u64, 8), stats.layers);
    try std.testing.expectEqual(@as(u64, 2), stats.filter_passes);
    try std.testing.expectEqual(gpu.items.len, software.items.len);
    const stride: usize = size.width;
    // Red over blue inside the group, composited once at half opacity.
    try std.testing.expect(near(0xff7f7f, effectAt(gpu.items, size.scale, stride, 15, 15), 2));
    try std.testing.expect(near(0x7f7fff, effectAt(gpu.items, size.scale, stride, 30, 25), 2));
    // The mask hides the left of its group.
    try std.testing.expect(near(0xffffff, effectAt(gpu.items, size.scale, stride, 70.5, 20), 12));
    // Near the right of the clip the mask is almost opaque.
    const masked = effectAt(gpu.items, size.scale, stride, 91, 20);
    std.debug.print("masked group near its right: {x:0>6}\n", .{masked});
    try std.testing.expect(near(0x208040, masked, 40));
    try std.testing.expect(near(0xffffff, effectAt(gpu.items, size.scale, stride, 67, 20), 0));
    // Red and blue at half opacity each, the blue over the red.
    try std.testing.expect(near(0xff7f7f, effectAt(gpu.items, size.scale, stride, 78, 100), 2));
    try std.testing.expect(near(0x7f40bf, effectAt(gpu.items, size.scale, stride, 90, 110), 3));
    try std.testing.expect(near(0x7f7fff, effectAt(gpu.items, size.scale, stride, 100, 130), 2));
    // The group fades as one: its yellow covers its green.
    try std.testing.expect(near(0xffff7f, effectAt(gpu.items, size.scale, stride, 78, 132), 2));
    // Inside the rounded clip the blue covers the red; outside its corner
    // nothing shows.
    try std.testing.expect(near(0x0000ff, effectAt(gpu.items, size.scale, stride, 165, 20), 2));
    try std.testing.expect(near(0xff0000, effectAt(gpu.items, size.scale, stride, 158, 10), 2));
    try std.testing.expect(near(0xffffff, effectAt(gpu.items, size.scale, stride, 153, 5), 2));

    var worst: i32 = 0;
    var worst_at: usize = 0;
    var mismatches: usize = 0;
    for (gpu.items, software.items, 0..) |g, w, i| {
        const d = difference(g, w);
        if (d > worst) {
            worst = d;
            worst_at = i;
        }
        if (d > 3) {
            if (mismatches < 12) std.debug.print("pixel ({d}, {d}): gl {x:0>6} software {x:0>6}\n", .{ i % stride, i / stride, g & 0xffffff, w & 0xffffff });
            mismatches += 1;
        }
    }
    std.debug.print("gl layers: worst channel difference {d} at ({d}, {d}), {d} pixels beyond 3\n", .{ worst, worst_at % stride, worst_at / stride, mismatches });
    try std.testing.expect(mismatches * 1000 <= gpu.items.len);
}


const effect_width = 200;
const effect_height = 120;
const inverted: ui.Rect = .{ .x = 10, .y = 10, .width = 40, .height = 40 };
const moved: ui.Rect = .{ .x = 110, .y = 10, .width = 30, .height = 30 };
const faded: ui.Rect = .{ .x = 110, .y = 70, .width = 40, .height = 30 };
const glass: ui.Rect = .{ .x = 10, .y = 70, .width = 80, .height = 40 };
const ripple: ui.Rect = .{ .x = 160, .y = 10, .width = 30, .height = 50 };
const invert_source =
    \\vec4 color(vec2 position, vec4 pixel) {
    \\    return vec4(pixel.a - pixel.rgb, pixel.a);
    \\}
;
// A layer program sampling its neighbours, with a branch the translation
// runs as a block loop.
const ripple_source =
    \\uniform float strength;
    \\vec4 layer(vec2 position) {
    \\    vec4 sum = vec4(0.0);
    \\    for (int i = -1; i <= 1; i++) {
    \\        if (i == 0) continue;
    \\        sum += sample(position + vec2(float(i) * strength, 0.0));
    \\    }
    \\    return sum * 0.5;
    \\}
;
const EffectScene = struct {
    library: *ui.effects.Library,
    invert: *ui.shader.Program,
    invert_values: ui.shader.Values,
    ripple: *ui.shader.Program,
    ripple_values: ui.shader.Values,
    failure: ?anyerror = null,
    paints: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *EffectScene = @ptrCast(@alignCast(ptr));
        self.paints += 1;
        self.record(frame) catch |err| {
            self.failure = err;
        };
        if (frame.failure) |err| self.failure = err;
    }
    fn record(self: *EffectScene, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        frame.rect(.{ .x = 0, .y = 60, .width = 100, .height = 60 }, 0x000000);
        frame.rect(.{ .x = 150, .y = 30, .width = 50, .height = 40 }, 0x2050c0);
        try frame.beginEffect(inverted, .{ .program = self.invert, .values = &self.invert_values }, .{});
        frame.rect(inverted, 0xff0000);
        try frame.endEffect();
        var pose_values: ui.shader.Values = undefined;
        const pose = (try self.library.pose(&pose_values, .{ .x = 20 }, .{ moved.width, moved.height })).?;
        try frame.beginEffect(moved, pose, .{});
        frame.rect(moved, 0x0000ff);
        try frame.endEffect();
        try frame.beginEffect(faded, self.library.passthrough(), .{ .opacity = 128 });
        frame.rect(faded, 0x000000);
        try frame.endEffect();
        var glass_values: ui.shader.Values = undefined;
        frame.backdropShader(glass, 12, try self.library.glass(&glass_values, .{}, 12));
        // Under an opacity the backdrop shader mixes in at half.
        try frame.pushOpacity(128);
        frame.backdropShader(ripple, 6, .{ .program = self.ripple, .values = &self.ripple_values, .margin = 4 });
        try frame.popOpacity();
    }
    fn action(_: *anyopaque, _: u64) void {}
};

fn paintEffects(effects: *EffectScene, title: [*:0]const u8) !void {
    const before = effects.paints;
    gl.Renderer.displayForTest(title);
    if (effects.failure) |err| return err;
    try std.testing.expectEqual(before + 1, effects.paints);
}

/// Draw the effect scene with OpenGL or in software and return its pixels
/// (0xAARRGGBB) and the effect stats of the last frame.
fn renderEffects(allocator: std.mem.Allocator, app: *z.App, effects: *EffectScene, software: bool, pixels: *std.ArrayList(u32)) !ui.shader_effects.Stats {
    const title: [*:0]const u8 = if (software) "Effects software" else "Effects gl";
    const window = try app.createWindow(.{ .title = std.mem.span(title), .width = effect_width, .height = effect_height });
    defer _ = window.destroy() catch unreachable;
    var context = ui.Context.init(effects, EffectScene.draw, EffectScene.action);
    if (software) context.render_mode = .gdi;
    context.semantics_enabled = false;
    try context.attach(window);
    window.show();
    try app.dispatch();
    const size = try window.contentSize();
    try context.prepareShaderEffects(allocator, .{});
    try context.prepareBackdropEffects(allocator, .{});
    try context.prepareGaussianWorkspace(allocator, .{ .layers = .{ .size = size, .max_depth = 3, .legacy_text = .disabled }, .source_size = .{ .width = @as(f32, @floatFromInt(size.width)) / size.scale, .height = @as(f32, @floatFromInt(size.height)) / size.scale }, .max_radius = 1 });
    try pixels.resize(allocator, @as(usize, size.width) * size.height);
    if (software) {
        try paintEffects(effects, title);
        try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
        for (pixels.items, 0..) |*out, i| out.* = zlc_test_raw_pixel(context.renderer.native.?, @intCast(i % size.width), @intCast(i / size.width));
        return context.shaderEffectStats().workspace;
    }
    context.gpu_renderer.captureForTest(true);
    // Until its programs are prepared the frame draws in software, without
    // counting a device failure.
    try paintEffects(effects, title);
    try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
    try std.testing.expectEqual(@as(usize, 0), context.fallbacks);
    const library = effects.library.gpuShaders();
    const shaders = library ++ [_]ui.GpuShader{ .{ .program = effects.invert, .target = .element }, .{ .program = effects.ripple, .target = .backdrop } };
    try std.testing.expectEqual(@as(usize, shaders.len), try context.prepareGpuShaders(allocator, &shaders));
    const before = context.shaderEffectStats().workspace;
    const passes = context.gpu_renderer.effectPasses();
    try paintEffects(effects, title);
    std.debug.print("effect frames: gpu {d}, software {d}, fallbacks {d}\n", .{ context.gpu_frames, context.gdi_frames, context.fallbacks });
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    try std.testing.expectEqual(@as(usize, 0), context.fallbacks);
    // Three element passes and two backdrop passes.
    try std.testing.expectEqual(passes + 5, context.gpu_renderer.effectPasses());
    try context.gpu_renderer.pixelsForTest(pixels.items, size.width, size.height);
    const after = context.shaderEffectStats().workspace;
    return .{ .applied = after.applied - before.applied, .skipped = after.skipped - before.skipped, .pixels = after.pixels - before.pixels, .work = after.work - before.work };
}

fn effectFrames(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var diagnostic: ui.shader.Diagnostic = .{};
    const invert = try ui.shader.compile(allocator, invert_source, .{}, &diagnostic);
    defer invert.destroy();
    const ripple_program = try ui.shader.compile(allocator, ripple_source, .{}, &diagnostic);
    defer ripple_program.destroy();
    var effect_scene: EffectScene = .{ .library = try ui.effects.Library.create(allocator), .invert = invert, .invert_values = ui.shader.Values.init(invert), .ripple = ripple_program, .ripple_values = ui.shader.Values.init(ripple_program) };
    defer effect_scene.library.destroy();
    try effect_scene.ripple_values.set(ripple_program.uniform("strength").?, @as(f32, 3));

    var gpu: std.ArrayList(u32) = .empty;
    defer gpu.deinit(allocator);
    var software: std.ArrayList(u32) = .empty;
    defer software.deinit(allocator);
    const gpu_stats = try renderEffects(allocator, app, &effect_scene, false, &gpu);
    const software_stats = try renderEffects(allocator, app, &effect_scene, true, &software);
    try std.testing.expectEqual(@as(u64, 5), gpu_stats.applied);
    try std.testing.expectEqual(software_stats.applied, gpu_stats.applied);
    try std.testing.expectEqual(software_stats.skipped, gpu_stats.skipped);
    try std.testing.expectEqual(software_stats.pixels, gpu_stats.pixels);
    try std.testing.expectEqual(gpu.items.len, software.items.len);

    const probe = try app.createWindow(.{ .width = effect_width, .height = effect_height });
    const size = try probe.contentSize();
    _ = try probe.destroy();
    const stride: usize = size.width;
    // Inverted inside the box, untouched outside it.
    try std.testing.expect(near(0x00ffff, effectAt(gpu.items, size.scale, stride, 30, 30), 1));
    try std.testing.expect(near(0xffffff, effectAt(gpu.items, size.scale, stride, 55, 30), 0));
    // The pose moves the square right.
    try std.testing.expect(near(0xffffff, effectAt(gpu.items, size.scale, stride, 115, 25), 1));
    try std.testing.expect(near(0x0000ff, effectAt(gpu.items, size.scale, stride, 145, 25), 1));
    // Half-faded black over white.
    try std.testing.expect(near(0x7f7f7f, effectAt(gpu.items, size.scale, stride, 130, 85), 2));
    try std.testing.expect(near(0xffffff, effectAt(gpu.items, size.scale, stride, 130, 60), 0));

    // Every pixel matches the software planes up to rounding.
    var worst: i32 = 0;
    var mismatches: usize = 0;
    for (gpu.items, software.items, 0..) |g, w, i| {
        const d = difference(g, w);
        worst = @max(worst, d);
        if (d > 2) {
            if (mismatches < 8) std.debug.print("pixel ({d}, {d}): gl {x:0>6} software {x:0>6}\n", .{ i % stride, i / stride, g & 0xffffff, w & 0xffffff });
            mismatches += 1;
        }
    }
    std.debug.print("gl shader effects: worst channel difference {d}, {d} pixels beyond 2\n", .{ worst, mismatches });
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

const glass_width = 240;
const glass_height = 160;
const GlassScene = struct {
    library: *ui.effects.Library,
    failure: ?anyerror = null,
    paints: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *GlassScene = @ptrCast(@alignCast(ptr));
        self.paints += 1;
        self.record(frame) catch |err| {
            self.failure = err;
        };
        if (frame.failure) |err| self.failure = err;
    }
    fn record(self: *GlassScene, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        // Stripes and blocks for the effects to blur and bend.
        var x: f32 = 0;
        var index: u32 = 0;
        while (x < glass_width) : (x += 6) {
            frame.rect(.{ .x = x, .y = 0, .width = 3, .height = glass_height }, if (index % 3 == 0) 0x202020 else if (index % 3 == 1) 0xd04020 else 0x2060d0);
            index += 1;
        }
        frame.rect(.{ .x = 0, .y = 70, .width = glass_width, .height = 12 }, 0x10a050);
        frame.backdropEffect(.{ .x = 8, .y = 8, .width = 60, .height = 40 }, 10, .{ .blur = .{ .radius = 3 } });
        frame.backdropEffect(.{ .x = 76, .y = 8, .width = 70, .height = 50 }, 0, .{ .blur = .{ .radius = 6, .mask = .{ .from = 255, .to = 0, .angle = 180 } } });
        frame.backdropEffect(.{ .x = 154, .y = 8, .width = 78, .height = 56 }, 16, .{ .glass = .{ .tint = rgba(40, 120, 255, 90), .noise = 0.5 } });
        // Glass at an opacity shades at it.
        try frame.pushOpacity(160);
        frame.backdropEffect(.{ .x = 8, .y = 96, .width = 90, .height = 30 }, 15, .{ .glass = .{ .style = .clear } });
        try frame.popOpacity();
        frame.backdropEffect(.{ .x = 106, .y = 96, .width = 60, .height = 24 }, 0, .{ .scroll_edge = .{ .hard = true, .background = 0xf0f0f0 } });
        frame.loadingIndicator(.{ .x = 176, .y = 92, .width = 24, .height = 24 }, .arc, 0.3, .rgb(0x1060ff), .{});
        frame.loadingIndicator(.{ .x = 204, .y = 92, .width = 24, .height = 24 }, .classic, 0.6, .{ .r = 0, .g = 0, .b = 0, .a = 200 }, .{});
        frame.loadingIndicator(.{ .x = 176, .y = 124, .width = 48, .height = 24 }, .bouncing_dots, 0.2, .rgb(0xe03030), .{});
        // A shader effect and a backdrop effect inside a raster transform.
        try frame.beginTransform(.{ .width = 40, .height = 24 }, .{ .xx = 1.2, .yx = 0.2, .xy = -0.2, .yy = 1.2, .x0 = 20, .y0 = 128 });
        frame.rect(.{ .x = 0, .y = 0, .width = 40, .height = 24 }, 0x804020);
        try frame.beginEffect(.{ .x = 4, .y = 4, .width = 20, .height = 16 }, self.library.passthrough(), .{ .opacity = 160 });
        frame.rect(.{ .x = 4, .y = 4, .width = 20, .height = 16 }, 0xffff00);
        try frame.endEffect();
        frame.backdropEffect(.{ .x = 26, .y = 2, .width = 12, .height = 20 }, 3, .{ .blur = .{ .radius = 2 } });
        try frame.endTransform();
    }
    fn action(_: *anyopaque, _: u64) void {}
};

fn renderGlass(allocator: std.mem.Allocator, app: *z.App, scene_state: *GlassScene, software: bool, pixels: *std.ArrayList(u32)) !gl.Stats {
    const title: [*:0]const u8 = if (software) "Glass software" else "Glass gl";
    const window = try app.createWindow(.{ .title = std.mem.span(title), .width = glass_width, .height = glass_height });
    defer _ = window.destroy() catch unreachable;
    var context = ui.Context.init(scene_state, GlassScene.draw, GlassScene.action);
    if (software) context.render_mode = .gdi;
    context.semantics_enabled = false;
    try context.attach(window);
    window.show();
    try app.dispatch();
    const size = try window.contentSize();
    const options: ui.layers.Options = .{ .size = size, .max_depth = 3, .legacy_text = .disabled };
    const source: ui.layout.Size = .{ .width = @as(f32, @floatFromInt(size.width)) / size.scale, .height = @as(f32, @floatFromInt(size.height)) / size.scale };
    try context.prepareTransforms(allocator, .{ .layers = options, .source_size = source });
    try context.prepareShaderEffects(allocator, .{});
    try context.prepareBackdropEffects(allocator, .{});
    try context.prepareGaussianWorkspace(allocator, .{ .layers = options, .source_size = source, .max_radius = 1 });
    // Before the window's first frame the programs wait for its context.
    if (!software) try std.testing.expect(try context.prepareGpuShaders(allocator, &scene_state.library.gpuShaders()) > 0);
    try pixels.resize(allocator, @as(usize, size.width) * size.height);
    // The first frame makes the context and links the programs after it.
    if (!software) {
        gl.Renderer.displayForTest(title);
        if (scene_state.failure) |err| return err;
        try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
        context.window.?.invalidate();
    }
    const before = scene_state.paints;
    if (!software) context.gpu_renderer.captureForTest(true);
    const stats_before = if (software) gl.Stats{} else context.gpu_renderer.stats();
    gl.Renderer.displayForTest(title);
    if (scene_state.failure) |err| return err;
    try std.testing.expectEqual(before + 1, scene_state.paints);
    if (software) {
        try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
        for (pixels.items, 0..) |*out, i| out.* = zlc_test_raw_pixel(context.renderer.native.?, @intCast(i % size.width), @intCast(i / size.width));
        return .{};
    }
    std.debug.print("glass frames: gpu {d}, software {d}, fallbacks {d}, backdrop software frames {d}\n", .{ context.gpu_frames, context.gdi_frames, context.fallbacks, context.backdropEffectStats().software_frames });
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    try std.testing.expectEqual(@as(usize, 0), context.fallbacks);
    try std.testing.expectEqual(@as(usize, 0), context.backdropEffectStats().software_frames);
    try context.gpu_renderer.pixelsForTest(pixels.items, size.width, size.height);
    const after = context.gpu_renderer.stats();
    return .{ .backdrops = after.backdrops - stats_before.backdrops, .indicators = after.indicators - stats_before.indicators, .layers = after.layers - stats_before.layers };
}

fn glassFrames(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var scene_state: GlassScene = .{ .library = try ui.effects.Library.create(allocator) };
    defer scene_state.library.destroy();
    var gpu: std.ArrayList(u32) = .empty;
    defer gpu.deinit(allocator);
    var software: std.ArrayList(u32) = .empty;
    defer software.deinit(allocator);
    const stats = try renderGlass(allocator, app, &scene_state, false, &gpu);
    _ = try renderGlass(allocator, app, &scene_state, true, &software);
    try std.testing.expectEqual(@as(u64, 6), stats.backdrops);
    try std.testing.expectEqual(@as(u64, 3), stats.indicators);
    try std.testing.expectEqual(gpu.items.len, software.items.len);
    const probe = try app.createWindow(.{ .width = glass_width, .height = glass_height });
    const size = try probe.contentSize();
    _ = try probe.destroy();
    const stride: usize = size.width;
    var worst: i32 = 0;
    var worst_at: usize = 0;
    var mismatches: usize = 0;
    for (gpu.items, software.items, 0..) |g, w, i| {
        const d = difference(g, w);
        if (d > worst) {
            worst = d;
            worst_at = i;
        }
        if (d > 3) {
            if (mismatches < 12) std.debug.print("pixel ({d}, {d}): gl {x:0>6} software {x:0>6}\n", .{ i % stride, i / stride, g & 0xffffff, w & 0xffffff });
            mismatches += 1;
        }
    }
    std.debug.print("gl backdrops and indicators: worst channel difference {d} at ({d}, {d}), {d} pixels beyond 3\n", .{ worst, worst_at % stride, worst_at / stride, mismatches });
    try std.testing.expect(mismatches * 1000 <= gpu.items.len);
}

const layer_width = 200;
const layer_height = 140;
extern fn getenv([*:0]const u8) ?[*:0]const u8;

/// On a software rasterizer, unless asked, windows draw with the software
/// renderer, without reporting a failure.
fn softwareWindows(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    probe.window = try app.createWindow(.{ .title = "OpenGL", .width = 320, .height = 200 });
    probe.content = ui.Context.init(&probe, Probe.draw, Probe.action);
    try probe.content.attach(probe.window);
    probe.window.show();
    try app.dispatch();
    gl.Renderer.displayForTest("OpenGL");
    gl.Renderer.displayForTest("OpenGL");
    std.debug.print("software rasterizer windows: gpu {d}, software {d}, fallbacks {d}\n", .{ probe.content.gpu_frames, probe.content.gdi_frames, probe.content.fallbacks });
    try std.testing.expectEqual(@as(usize, 0), probe.content.gpu_frames);
    try std.testing.expect(probe.content.gdi_frames >= 2);
    try std.testing.expectEqual(@as(usize, 0), probe.content.fallbacks);
    _ = try probe.window.destroy();
    try app.dispatch();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    // The probe needs GTK's display.
    const app = try z.App.init(gpa.allocator());
    const probed = gl.probe();
    app.deinit();
    switch (probed) {
        .unavailable => {
            std.debug.print("gl smoke skipped: no OpenGL context\n", .{});
            return;
        },
        else => {},
    }
    std.debug.print("OpenGL renderer: {s}\n", .{gl.probeRenderer()});
    var matched = true;
    for ([_]f32{ 1, 2, 1.5 }) |scale| if (!try compare(scale)) {
        matched = false;
    };
    const forced = if (getenv("ZIGGURAT_GL")) |value| std.mem.eql(u8, std.mem.span(value), "on") else false;
    if (probed == .gpu or forced) {
        try windowFrames(gpa.allocator());
        try layerFrames(gpa.allocator());
        try effectFrames(gpa.allocator());
        try glassFrames(gpa.allocator());
    } else try softwareWindows(gpa.allocator());
    try std.testing.expect(matched);
    try @import("gpu_domain_lifetime.zig").run(gpa.allocator());
    try @import("gpu_offscreen_lifetime.zig").run(gpa.allocator());
    try std.testing.expectEqual(@as(u32, 0), gl.liveObjects());
    std.debug.print("gl smoke ok\n", .{});
}
