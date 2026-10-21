//! Shader effects on Direct3D 11 (WARP): element effects run over their
//! Gaussian capture and backdrop shaders over a copy of the target, and the
//! frame matches the same frame drawn on the software planes.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});

const width = 200;
const height = 120;
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

const Scene = struct {
    library: *ui.effects.Library,
    invert: *ui.shader.Program,
    invert_values: ui.shader.Values,
    ripple: *ui.shader.Program,
    ripple_values: ui.shader.Values,
    failure: ?anyerror = null,
    paints: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Scene = @ptrCast(@alignCast(ptr));
        self.paints += 1;
        self.record(frame) catch |err| {
            self.failure = err;
        };
        if (frame.failure) |err| self.failure = err;
    }
    fn record(self: *Scene, frame: *ui.Frame) !void {
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
        frame.backdropShader(ripple, 6, .{ .program = self.ripple, .values = &self.ripple_values, .margin = 4 });
    }
    fn action(_: *anyopaque, _: u64) void {}
};

fn near(expected: u32, actual: u32, tolerance: u32) bool {
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const a = (expected >> shift) & 255;
        const b = (actual >> shift) & 255;
        if ((if (a > b) a - b else b - a) > tolerance) return false;
    }
    return true;
}

fn paint(scene: *Scene, window: z.Window) !void {
    const before = scene.paints;
    _ = c.SendMessageW(@ptrCast(window.nativeHandle()), c.WM_PAINT, 0, 0);
    if (scene.failure) |err| return err;
    try std.testing.expectEqual(before + 1, scene.paints);
}

/// Draw the scene in `mode` and return its pixels and the effect stats of
/// the last frame.
fn render(allocator: std.mem.Allocator, app: *z.App, scene: *Scene, mode: ui.RenderMode, pixels: []u32) !ui.shader_effects.Stats {
    const window = try app.createWindow(.{ .width = width, .height = height });
    defer _ = window.destroy() catch unreachable;
    var context = ui.Context.init(scene, Scene.draw, Scene.action);
    context.render_mode = mode;
    context.semantics_enabled = false;
    try context.attach(window);
    const size = try window.contentSize();
    if (@as(usize, size.width) * size.height != pixels.len) return error.InvalidFixtureSize;
    try context.prepareShaderEffects(allocator, .{});
    try context.prepareBackdropEffects(allocator, .{});
    try context.prepareGaussianWorkspace(allocator, .{ .layers = .{ .size = size, .max_depth = 3, .legacy_text = .disabled }, .source_size = .{ .width = @as(f32, @floatFromInt(size.width)) / size.scale, .height = @as(f32, @floatFromInt(size.height)) / size.scale }, .max_radius = 1 });
    if (mode == .gdi) {
        try std.testing.expectEqual(@as(usize, 0), try context.prepareGpuShaders(allocator, &scene.library.gpuShaders()));
        try paint(scene, window);
        try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
        for (pixels, context.renderer.pixels.?[0..pixels.len]) |*out, value| out.* = value;
        return context.shaderEffectStats().workspace;
    }
    // Until its programs are prepared the frame draws in software, without
    // counting a device failure.
    try paint(scene, window);
    try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
    try std.testing.expectEqual(@as(usize, 0), context.fallbacks);
    const library = scene.library.gpuShaders();
    const shaders = library ++ [_]ui.GpuShader{ .{ .program = scene.invert, .target = .element }, .{ .program = scene.ripple, .target = .backdrop } };
    try std.testing.expectEqual(@as(usize, shaders.len), try context.prepareGpuShaders(allocator, &shaders));
    const before = context.shaderEffectStats().workspace;
    try paint(scene, window);
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    try std.testing.expectEqual(@as(usize, 0), context.fallbacks);
    // Three element passes and two backdrop passes.
    try std.testing.expectEqual(@as(u64, 5), context.gpu_renderer.effectPasses());
    try context.gpu_renderer.readLayerPixels(true, pixels);
    const after = context.shaderEffectStats().workspace;
    return .{ .applied = after.applied - before.applied, .skipped = after.skipped - before.skipped, .pixels = after.pixels - before.pixels, .work = after.work - before.work };
}

fn at(pixels: []const u32, scale: f32, stride: usize, x: f32, y: f32) u32 {
    const px: usize = @intFromFloat(@floor(x * scale));
    const py: usize = @intFromFloat(@floor(y * scale));
    return pixels[py * stride + px] & 0xffffff;
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var diagnostic: ui.shader.Diagnostic = .{};
    const invert = try ui.shader.compile(allocator, invert_source, .{}, &diagnostic);
    defer invert.destroy();
    const ripple_program = try ui.shader.compile(allocator, ripple_source, .{}, &diagnostic);
    defer ripple_program.destroy();
    var scene: Scene = .{ .library = try ui.effects.Library.create(allocator), .invert = invert, .invert_values = ui.shader.Values.init(invert), .ripple = ripple_program, .ripple_values = ui.shader.Values.init(ripple_program) };
    defer scene.library.destroy();
    try scene.ripple_values.set(ripple_program.uniform("strength").?, @as(f32, 3));

    const probe = try app.createWindow(.{ .width = width, .height = height });
    const size = try probe.contentSize();
    _ = try probe.destroy();
    const count = @as(usize, size.width) * size.height;
    const gpu = try allocator.alloc(u32, count);
    defer allocator.free(gpu);
    const software = try allocator.alloc(u32, count);
    defer allocator.free(software);

    const gpu_stats = try render(allocator, app, &scene, .warp, gpu);
    const software_stats = try render(allocator, app, &scene, .gdi, software);
    try std.testing.expectEqual(@as(u64, 5), gpu_stats.applied);
    try std.testing.expectEqual(software_stats.applied, gpu_stats.applied);
    try std.testing.expectEqual(software_stats.skipped, gpu_stats.skipped);
    try std.testing.expectEqual(software_stats.pixels, gpu_stats.pixels);

    const stride: usize = size.width;
    // Inverted inside the box, untouched outside it.
    try std.testing.expect(near(0x00ffff, at(gpu, size.scale, stride, 30, 30), 1));
    try std.testing.expect(near(0xffffff, at(gpu, size.scale, stride, 55, 30), 0));
    // The pose moves the square right.
    try std.testing.expect(near(0xffffff, at(gpu, size.scale, stride, 115, 25), 1));
    try std.testing.expect(near(0x0000ff, at(gpu, size.scale, stride, 145, 25), 1));
    // Half-faded black over white.
    try std.testing.expect(near(0x7f7f7f, at(gpu, size.scale, stride, 130, 85), 2));
    try std.testing.expect(near(0xffffff, at(gpu, size.scale, stride, 150, 60), 0));

    // Every pixel matches the software planes up to rounding.
    var worst: u32 = 0;
    var mismatches: usize = 0;
    for (gpu, software, 0..) |g, s, i| {
        var shift: u5 = 0;
        while (shift < 24) : (shift += 8) {
            const a = (g >> shift) & 255;
            const b = (s >> shift) & 255;
            const d = if (a > b) a - b else b - a;
            if (d > worst) worst = d;
            if (d > 2) {
                if (mismatches < 8) std.debug.print("pixel ({d}, {d}): gpu {x:0>6} software {x:0>6}\n", .{ i % stride, i / stride, g & 0xffffff, s & 0xffffff });
                mismatches += 1;
                break;
            }
        }
    }
    std.debug.print("shader effects GPU: worst channel difference {d}, {d} pixels beyond 2\n", .{ worst, mismatches });
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    std.debug.print("shader effects GPU: element captures, backdrop copies, stats and software parity passed\n", .{});
}
