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
const glass: ui.Rect = .{ .x = 110, .y = 10, .width = 80, .height = 40 };
const blur: ui.Rect = .{ .x = 60, .y = 60, .width = 80, .height = 20 };
const spinner: ui.Rect = .{ .x = 10, .y = 90, .width = 24, .height = 24 };

const State = struct {
    context: ui.Context = undefined,
    failure: ?anyerror = null,
    paints: usize = 0,
    phase: f64 = 0.25,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.paints += 1;
        frame.clear(0xffffff);
        // Black left half, white right half, a black bar under the glass.
        frame.rect(.{ .x = 0, .y = 0, .width = width / 2, .height = height }, 0x000000);
        frame.rect(.{ .x = 120, .y = 20, .width = 60, .height = 20 }, 0x000000);
        frame.backdropEffect(glass, 16, .{ .glass = .{} });
        frame.backdropEffect(blur, 0, .{ .blur = .{ .radius = 4 } });
        frame.loadingIndicator(spinner, .ring, self.phase, ui.Color.rgb(0x2050a0), .{});
        if (frame.failure) |err| self.failure = err;
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
    fn spinnerInk(self: *State) !usize {
        var ink: usize = 0;
        var y: f32 = spinner.y;
        while (y < spinner.y + spinner.height) : (y += 1) {
            var x: f32 = spinner.x;
            while (x < spinner.x + spinner.width) : (x += 1) {
                if (try self.pixel(x + 0.5, y + 0.5) != 0xffffff) ink += 1;
            }
        }
        return ink;
    }
};

fn green(rgb: u32) u32 {
    return (rgb >> 8) & 255;
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    state.context = ui.Context.init(&state, State.draw, State.action);
    const window = try app.createWindow(.{ .width = width, .height = height });
    try state.context.attach(window);

    // Before preparation every effect is an opaque fill.
    try state.paint(window);
    try std.testing.expect(state.context.backdropEffectStats().unprepared >= 2);
    const unfiltered = try state.pixel(150, 30);

    try state.context.prepareBackdropEffects(allocator, .{});
    try state.paint(window);
    const stats = state.context.backdropEffectStats();
    try std.testing.expectEqual(@as(u64, 2), stats.workspace.applied);
    try std.testing.expectEqual(@as(u64, 0), stats.workspace.fallbacks);
    // Regular light glass lifts the black bar beneath it toward white, but
    // the bar still shows through.
    const over_bar = try state.pixel(150, 30);
    try std.testing.expect(green(over_bar) > 0x60 and green(over_bar) < 0xf8);
    try std.testing.expect(over_bar != unfiltered);
    // The uniform blur ramps across the black and white boundary.
    const left = green(try state.pixel(98.5, 70));
    const right = green(try state.pixel(101.5, 70));
    try std.testing.expect(left > 0x08 and left < 0x80);
    try std.testing.expect(right > 0x80 and right < 0xf7);
    // Outside the panes the backdrop is untouched.
    try std.testing.expectEqual(@as(u32, 0x000000), try state.pixel(40, 30));
    try std.testing.expectEqual(@as(u32, 0xffffff), try state.pixel(150, 100));
    // The indicator draws, and a different phase draws a different pose.
    const ink = try state.spinnerInk();
    try std.testing.expect(ink > 20);
    const pose = try state.pixel(spinner.x + 12, spinner.y + 2);
    state.phase = 0.75;
    try state.paint(window);
    try std.testing.expect(pose != try state.pixel(spinner.x + 12, spinner.y + 2) or ink != try state.spinnerInk());

    // Reduced transparency draws the opaque fill.
    const applied = state.context.backdropEffectStats().workspace.applied;
    try state.context.setBackdropPreferences(.{ .reduce_transparency = true });
    try state.paint(window);
    try std.testing.expectEqual(unfiltered, try state.pixel(150, 30));
    try std.testing.expectEqual(applied, state.context.backdropEffectStats().workspace.applied);
    try state.context.setBackdropPreferences(.{});

    // A workspace too small for a region falls back for that region only.
    try state.context.prepareBackdropEffects(allocator, .{ .max_pixels = 64 });
    try state.paint(window);
    try std.testing.expectEqual(@as(u64, 2), state.context.backdropEffectStats().workspace.fallbacks);
    try std.testing.expectEqual(unfiltered, try state.pixel(150, 30));

    try state.context.releaseBackdropEffects();
    try std.testing.expectError(error.BackdropNotPrepared, state.context.releaseBackdropEffects());
    try state.context.prepareBackdropEffects(allocator, .{});
    _ = try window.destroy();
    try app.dispatch();
    // Detach releases the workspace.
    try std.testing.expect(state.context.window == null and state.context.backdrop_workspace == null);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("backdrop native: glass, blur and indicator pixels, opaque fallbacks and workspace lifetime passed\n", .{});
}
