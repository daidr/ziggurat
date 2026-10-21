//! Shader effects on OpenGL (Linux): element effects and backdrop shaders
//! run as fragment shaders over the software planes, and the frame matches
//! the same frame drawn on the CPU.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;

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

fn paint(scene: *Scene, window: z.Window) !void {
    const before = scene.paints;
    {
        const scope = window.beginCallback().?;
        defer scope.end();
        zlg_test_paint(scope.record.native.native.?, width, height);
    }
    if (scene.failure) |err| return err;
    try std.testing.expectEqual(before + 1, scene.paints);
}

/// Draw the scene with effects on OpenGL or the CPU and return its pixels
/// and effect stats.
fn render(allocator: std.mem.Allocator, app: *z.App, scene: *Scene, gl: bool, pixels: []u32) !ui.shader_effects.Stats {
    const window = try app.createWindow(.{ .width = width, .height = height });
    defer _ = window.destroy() catch unreachable;
    var context = ui.Context.init(scene, Scene.draw, Scene.action);
    context.semantics_enabled = false;
    context.gl_mode = if (gl) .on else .off;
    try context.attach(window);
    const size = try window.contentSize();
    try context.prepareShaderEffects(allocator, .{});
    try context.prepareBackdropEffects(allocator, .{});
    try context.prepareGaussianWorkspace(allocator, .{ .layers = .{ .size = size, .max_depth = 3, .legacy_text = .grayscale }, .source_size = .{ .width = @as(f32, @floatFromInt(size.width)) / size.scale, .height = @as(f32, @floatFromInt(size.height)) / size.scale }, .max_radius = 1 });
    const library = scene.library.gpuShaders();
    const shaders = library ++ [_]ui.GpuShader{ .{ .program = scene.invert, .target = .element }, .{ .program = scene.ripple, .target = .backdrop } };
    const ready = try context.prepareGpuShaders(allocator, &shaders);
    if (gl and ready == 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, if (gl) shaders.len else 0), ready);
    try paint(scene, window);
    if (gl) try std.testing.expectEqual(@as(u64, 5), context.renderer.effectPasses());
    const native = context.renderer.native.?;
    var i: usize = 0;
    var y: u32 = 0;
    while (y < size.height) : (y += 1) {
        var x: u32 = 0;
        while (x < size.width) : (x += 1) {
            pixels[i] = zlc_test_raw_pixel(native, x, y);
            i += 1;
        }
    }
    return context.shaderEffectStats().workspace;
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
    const gl = try allocator.alloc(u32, count);
    defer allocator.free(gl);
    const cpu = try allocator.alloc(u32, count);
    defer allocator.free(cpu);

    const gl_stats = render(allocator, app, &scene, true, gl) catch |err| switch (err) {
        error.SkipZigTest => {
            std.debug.print("shader effects GL: no OpenGL 3.3 context, skipped\n", .{});
            return;
        },
        else => return err,
    };
    const cpu_stats = try render(allocator, app, &scene, false, cpu);
    try std.testing.expectEqual(@as(u64, 5), gl_stats.applied);
    try std.testing.expectEqual(cpu_stats.applied, gl_stats.applied);
    try std.testing.expectEqual(cpu_stats.skipped, gl_stats.skipped);
    try std.testing.expectEqual(cpu_stats.pixels, gl_stats.pixels);

    var worst: u32 = 0;
    var mismatches: usize = 0;
    const stride: usize = size.width;
    for (gl, cpu, 0..) |g, s, i| {
        var shift: u5 = 0;
        while (true) : (shift += 8) {
            const a = (g >> shift) & 255;
            const b = (s >> shift) & 255;
            const d = if (a > b) a - b else b - a;
            if (d > worst) worst = d;
            if (d > 2) {
                if (mismatches < 8) std.debug.print("pixel ({d}, {d}): gl {x:0>8} cpu {x:0>8}\n", .{ i % stride, i / stride, g, s });
                mismatches += 1;
                break;
            }
            if (shift == 24) break;
        }
    }
    std.debug.print("shader effects GL: worst channel difference {d}, {d} pixels beyond 2\n", .{ worst, mismatches });
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    // The effects changed the frame: the inverted box is cyan.
    const at = @as(usize, @intFromFloat(@floor(30 * size.scale))) * stride + @as(usize, @intFromFloat(@floor(30 * size.scale)));
    try std.testing.expect(near(0x00ffff, gl[at] & 0xffffff, 1));
}

fn near(expected: u32, actual: u32, tolerance: u32) bool {
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const a = (expected >> shift) & 255;
        const b = (actual >> shift) & 255;
        if ((if (a > b) a - b else b - a) > tolerance) return false;
    }
    return true;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    std.debug.print("shader effects GL: element captures, backdrop shaders, stats and CPU parity passed\n", .{});
}
