const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlg_resource_count() u32;

const State = struct {
    context: ui.Context = undefined,
    failure: ?anyerror = null,
    reject_frame: bool = false,
    paints: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.paints += 1;
        self.emit(frame) catch |err| {
            self.failure = err;
            frame.failure = err;
        };
    }
    fn emit(self: *State, frame: *ui.Frame) !void {
        try std.testing.expectError(error.Busy, self.context.setTheme(.light()));
        frame.clear(frame.currentTheme().palette.background);
        try frame.button(1, .{ .x = 4, .y = 4, .width = 80, .height = 24 }, "");
        try frame.checkbox(2, .{ .x = 4, .y = 36, .width = 80, .height = 24 }, "", true, .{});
        try frame.checkbox(3, .{ .x = 90, .y = 36, .width = 80, .height = 24 }, "", true, .{ .enabled = false });
        try frame.progress(4, .{ .x = 4, .y = 70, .width = 100, .height = 20 }, 0.5, .{ .name = "Work" });
        try frame.slider(5, .{ .x = 4, .y = 100, .width = 100, .height = 20 }, 5, .{ .minimum = 0, .maximum = 10, .step = 1 }, .{});
        if (self.reject_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn value(_: *anyopaque, _: u64, _: ui.ValueChange) void {}
    fn sliderTrack(self: *const State) !ui.Rect {
        for (self.context.input_state.hits[0..self.context.input_state.len]) |hit| if (hit.id == 5) {
            return (hit.options.range orelse return error.MissingSliderRange).track;
        };
        return error.MissingSlider;
    }
    fn paint(self: *State, window: z.Window) !void {
        const before = self.paints;
        if (builtin.os.tag == .windows) {
            _ = c.SendMessageW(@ptrCast(window.nativeHandle()), c.WM_PAINT, 0, 0);
        } else {
            const scope = window.beginCallback().?;
            defer scope.end();
            zlg_test_paint(scope.record.native.native.?, 180, 130);
        }
        try std.testing.expectEqual(before + 1, self.paints);
        if (self.failure) |err| return err;
    }
    fn pixel(self: *State, x: u32, y: u32) !u32 {
        const size = self.context.last_paint_size.?;
        const px: u32 = @intFromFloat((@as(f32, @floatFromInt(x)) + 0.25) * size.scale);
        const py: u32 = @intFromFloat((@as(f32, @floatFromInt(y)) + 0.25) * size.scale);
        if (builtin.os.tag == .windows) {
            const color = c.GetPixel(self.context.renderer.dc, @intCast(px), @intCast(py));
            if (color == c.CLR_INVALID) return error.PixelReadFailed;
            return ((color & 255) << 16) | (color & 0xff00) | ((color >> 16) & 255);
        }
        return zlc_test_raw_pixel(self.context.renderer.native.?, px, py) & 0xffffff;
    }
};
fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.render_mode = .gdi;
    state.context.on_value = State.value;
    const window = try app.createWindow(.{ .width = 180, .height = 130 });
    try state.context.attach(window);
    var theme = ui.Theme.dark();
    theme.palette.border = 0x112233;
    theme.palette.control = 0x445566;
    theme.palette.accent = 0xaa2200;
    theme.palette.on_accent = 0x00ff77;
    theme.palette.trough = 0x223344;
    try std.testing.expect(try state.context.setTheme(theme));
    try state.paint(window);
    const probes = .{ .{ 4, 4, theme.palette.border }, .{ 8, 8, theme.palette.control }, .{ 7, 40, theme.palette.accent }, .{ 14, 47, theme.palette.on_accent }, .{ 8, 74, theme.palette.accent }, .{ 60, 74, theme.palette.trough } };
    inline for (probes) |probe| try std.testing.expectEqual(probe[2], try state.pixel(probe[0], probe[1]));
    const frames = state.context.frames;
    const old_track = try state.sliderTrack();
    var contrast = ui.Theme.highContrast();
    contrast.metrics.thumb_size = 8;
    _ = try state.context.setTheme(contrast);
    state.reject_frame = true;
    try state.paint(window);
    try std.testing.expectEqual(frames, state.context.frames);
    try std.testing.expectEqualDeep(old_track, try state.sliderTrack());
    try std.testing.expectEqual(theme.palette.control, try state.pixel(8, 8));
    state.reject_frame = false;
    try state.paint(window);
    try std.testing.expectEqual(ui.Theme.highContrast().palette.control, try state.pixel(8, 8));
    const track = try state.sliderTrack();
    try std.testing.expectEqual(@as(f32, 8), track.x);
    try std.testing.expectEqual(@as(f32, 92), track.width);
    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expect(state.context.window == null);
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("theme native: custom widget pixels, update/copy, busy draw and failed-front transaction passed\n", .{});
}
