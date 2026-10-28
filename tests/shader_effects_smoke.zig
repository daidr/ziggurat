const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlg_resource_count() u32;

const width = 200;
const height = 120;
const inverted: ui.Rect = .{ .x = 10, .y = 10, .width = 40, .height = 40 };
const moved: ui.Rect = .{ .x = 110, .y = 10, .width = 30, .height = 30 };
const faded: ui.Rect = .{ .x = 110, .y = 70, .width = 40, .height = 30 };
const glass: ui.Rect = .{ .x = 10, .y = 70, .width = 80, .height = 40 };

const invert_source =
    \\vec4 color(vec2 position, vec4 pixel) {
    \\    return vec4(pixel.a - pixel.rgb, pixel.a);
    \\}
;

const State = struct {
    context: ui.Context = undefined,
    library: *ui.effects.Library = undefined,
    invert: *ui.shader.Program = undefined,
    invert_values: ui.shader.Values = undefined,
    failure: ?anyerror = null,
    paints: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.paints += 1;
        self.record(frame) catch |err| {
            self.failure = err;
        };
        if (frame.failure) |err| self.failure = err;
    }
    fn record(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        frame.rect(.{ .x = 0, .y = 60, .width = 100, .height = 60 }, 0x000000);
        // Red inverted to cyan inside its box only.
        try frame.beginEffect(inverted, .{ .program = self.invert, .values = &self.invert_values }, .{});
        frame.rect(inverted, 0xff0000);
        try frame.endEffect();
        // A square drawn at `moved`, shown 20 DIP to the right.
        var pose_values: ui.shader.Values = undefined;
        const pose = (try self.library.pose(&pose_values, .{ .x = 20 }, .{ moved.width, moved.height })).?;
        try frame.beginEffect(moved, pose, .{});
        frame.rect(moved, 0x0000ff);
        try frame.endEffect();
        // Black faded to half over white.
        try frame.beginEffect(faded, self.library.passthrough(), .{ .opacity = 128 });
        frame.rect(faded, 0x000000);
        try frame.endEffect();
        var glass_values: ui.shader.Values = undefined;
        frame.backdropShader(glass, 12, try self.library.glass(&glass_values, .{}, 12));
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn paint(self: *State, window: z.Window) !void {
        const before = self.paints;
        if (builtin.os.tag == .windows) {
            _ = c.SendMessageW(@ptrCast(window.nativeHandle()), c.WM_PAINT, 0, 0);
        } else {
            const scope = window.beginCallback().?;
            defer scope.end();
            zlg_test_paint(scope.record.native.native.?, width, height);
        }
        try std.testing.expectEqual(before + 1, self.paints);
        if (self.failure) |err| return err;
    }
    fn pixel(self: *State, x: f32, y: f32) !u32 {
        const size = self.context.last_paint_size.?;
        const px: u32 = @intFromFloat(@floor(x * size.scale));
        const py: u32 = @intFromFloat(@floor(y * size.scale));
        if (builtin.os.tag == .windows) {
            const color = c.GetPixel(self.context.renderer.dc, @intCast(px), @intCast(py));
            if (color == c.CLR_INVALID) return error.PixelReadFailed;
            return ((color & 255) << 16) | (color & 0xff00) | ((color >> 16) & 255);
        }
        return zlc_test_raw_pixel(self.context.renderer.native.?, px, py) & 0xffffff;
    }
};

fn near(expected: u32, actual: u32, tolerance: u32) !void {
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const a = (expected >> shift) & 255;
        const b = (actual >> shift) & 255;
        if ((if (a > b) a - b else b - a) > tolerance) {
            std.debug.print("expected {x:0>6}, got {x:0>6}\n", .{ expected, actual });
            return error.TestUnexpectedPixel;
        }
    }
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    state.library = try ui.effects.Library.create(allocator);
    defer state.library.destroy();
    var diagnostic: ui.shader.Diagnostic = .{};
    state.invert = try ui.shader.compile(allocator, invert_source, .{}, &diagnostic);
    defer state.invert.destroy();
    state.invert_values = ui.shader.Values.init(state.invert);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.setFrameStats(.{ .enabled = true, .slow_ns = null });
    const window = try app.createWindow(.{ .width = width, .height = height });
    try state.context.attach(window);

    // Unprepared, every effect draws its content as it is.
    try state.paint(window);
    try std.testing.expectEqual(@as(u64, 4), state.context.shaderEffectStats().unprepared);
    try near(0xff0000, try state.pixel(30, 30), 0);
    try near(0x0000ff, try state.pixel(115, 25), 0);
    try near(0x000000, try state.pixel(130, 85), 0);

    try state.context.prepareShaderEffects(allocator, .{});
    try state.context.prepareBackdropEffects(allocator, .{});
    try state.paint(window);
    const stats = state.context.shaderEffectStats();
    try std.testing.expectEqual(@as(u64, 4), stats.workspace.applied);
    try std.testing.expectEqual(@as(u64, 0), stats.workspace.faulted_pixels);
    // Inverted inside the box, untouched outside it.
    try near(0x00ffff, try state.pixel(30, 30), 1);
    try near(0xffffff, try state.pixel(55, 30), 0);
    // The pose moves the square right: its old left edge shows white.
    try near(0xffffff, try state.pixel(115, 25), 1);
    try near(0x0000ff, try state.pixel(145, 25), 1);
    // Half-faded black over white.
    try near(0x7f7f7f, try state.pixel(130, 85), 2);
    // Glass over the black half lifts the rim but not the white beyond it.
    try near(0xffffff, try state.pixel(150, 60), 0);
    try std.testing.expect(state.context.frameStats().frames >= 2);
    try std.testing.expect(state.context.frameStats().last.commands > 0);

    try state.context.releaseShaderEffects();
    try std.testing.expectError(error.ShaderEffectsNotPrepared, state.context.releaseShaderEffects());
    try state.context.prepareShaderEffects(allocator, .{});
    _ = try window.destroy();
    try app.dispatch();
    // Detach releases the workspace.
    try std.testing.expect(state.context.window == null and state.context.shader_workspace == null);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("shader effects native: color, pose and fade pixels, backdrop shader, unprepared fallbacks, frame stats and workspace lifetime passed\n", .{});
}
