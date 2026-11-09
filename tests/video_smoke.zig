//! The system's media engine plays a clip in a real window: GStreamer on
//! Linux, AVFoundation on macOS, Media Foundation on Windows. Its pictures reach the window through the
//! posted task, and the window's frames show them: red, then green, then
//! blue to the clip's end; a paused clip shows the picture each seek asks
//! for, and one played again after its end starts over. The frames are
//! drawn in software (a capture of the window), and with -Dgpu=true by
//! OpenGL or Metal too, which sample the decoder's NV12 planes (on macOS
//! its CVPixelBuffer, without a copy) and convert them as they draw.
//! A system without an engine or an H.264 decoder skips it.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const video = @import("ziggurat_view_video");
const system_video = @import("ziggurat_video");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlm_test_paint(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern "user32" fn InvalidateRect(?*anyopaque, ?*const anyopaque, c_int) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(?*anyopaque, u32, usize, isize) callconv(.winapi) isize;

const title = "Video smoke";
const width = 160;
const height = 120;
// Direct3D 11 draws the BGRA pictures as images: the software capture serves.
const gpu = builtin.os.tag != .windows and @FieldType(ui.Context, "gpu_renderer") != void;
const ms = std.time.ns_per_ms;

const Screen = struct {
    player: ?*video.Player = null,
    fn build(self: *Screen, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .background = 0x000000 });
        if (self.player) |player| try player.show(v, .{ .fit = .fill, .alt = "Clip" }, .{ .grow = 1, .self_align = .stretch });
        try v.end();
    }
};

const Smoke = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window,
    host: *view.Host,
    player: *video.Player,
    frames_on_gpu: usize = 0,

    /// Draws a frame, takes what the engine posted, and reads the middle of
    /// the window as RGB.
    fn frame(self: *Smoke) ![3]u8 {
        var color: [3]u8 = undefined;
        if (gpu) {
            const renderer = &self.host.context.gpu_renderer;
            renderer.captureForTest(true);
            const before = self.host.context.gpu_frames;
            ui.GpuRenderer.displayForTest(title);
            if (self.host.context.gpu_frames > before) {
                self.frames_on_gpu += 1;
                const size = self.host.context.last_paint_size.?;
                const pixel = renderer.pixelForTest(size.width / 2, size.height / 2);
                color = .{ @truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel) };
            }
        }
        // A frame drawn in software, as the window draws one, and read.
        if (builtin.os.tag == .windows) {
            // The window's paint, delivered at once: a hidden window may
            // hold back UpdateWindow's.
            const hwnd = self.window.nativeHandle();
            _ = InvalidateRect(hwnd, null, 0);
            _ = SendMessageW(hwnd, 0x000F, 0, 0); // WM_PAINT
        } else {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            if (builtin.os.tag == .linux) zlg_test_paint(native, width, height) else zlm_test_paint(native);
        }
        if (self.host.last_error) |err| return err;
        if (!gpu or self.frames_on_gpu == 0) {
            const size = self.host.context.last_paint_size.?;
            const pixel = if (builtin.os.tag == .windows) windows: {
                const renderer = &self.host.context.renderer;
                const pixels = renderer.pixels orelse return error.NoSurface;
                break :windows pixels[@as(usize, size.height / 2) * renderer.width + size.width / 2];
            } else zlc_test_raw_pixel(self.host.context.renderer.native.?, size.width / 2, size.height / 2);
            color = .{ @truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel) };
        }
        try self.app.dispatch();
        if (self.player.last_error) |err| return err;
        if (self.player.err()) |err| return err;
        return color;
    }
    /// Draws frames until `done` holds, for at most ten seconds.
    fn until(self: *Smoke, what: []const u8, comptime done: fn (*Smoke, [3]u8) bool) !void {
        var tries: usize = 0;
        while (tries < 1000) : (tries += 1) {
            const color = try self.frame();
            if (done(self, color)) return;
            zio.sleep(10 * ms);
        }
        std.debug.print("video smoke: timed out waiting for {s}; state ready {}, playing {}, ended {}, at {d} ms\n", .{ what, self.player.ready(), self.player.playing(), self.player.ended(), self.player.position() / ms });
        return error.Timeout;
    }
};

fn near(color: [3]u8, want: [3]u8) bool {
    for (color, want) |a, b| if (@max(a, b) - @min(a, b) > 32) return false;
    return true;
}
fn showing(comptime want: [3]u8) fn (*Smoke, [3]u8) bool {
    return struct {
        fn check(_: *Smoke, color: [3]u8) bool {
            return near(color, want);
        }
    }.check;
}
fn ready(self: *Smoke, _: [3]u8) bool {
    return self.player.ready();
}
fn ended(self: *Smoke, color: [3]u8) bool {
    return self.player.ended() and near(color, blue);
}
const red = [3]u8{ 255, 0, 0 };
const green = [3]u8{ 0, 255, 0 };
const blue = [3]u8{ 0, 0, 255 };

/// The frames the GPU renderer drew, or null when skipped.
fn run(allocator: std.mem.Allocator) !?usize {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var screen: Screen = .{};
    var storage: view.Storage(8, 64) = .{};
    var host = view.Host.init(&screen, Screen.build, storage.buffers(), .{});
    const window = try app.createWindow(.{ .title = title, .width = width, .height = height });
    try host.attach(window);
    var player = system_video.openData(allocator, &host, system_video.test_clip) catch |err| switch (err) {
        error.Unsupported => {
            std.debug.print("video smoke: skipped, the system has no media engine\n", .{});
            return null;
        },
        else => return err,
    };
    defer player.deinit();
    // Silent, not muted: a muted video is a picture, which holds still
    // while out of sight, as a hidden test window may be.
    player.setVolume(0);
    screen.player = &player;
    window.show();
    try app.dispatch();
    var smoke: Smoke = .{ .allocator = allocator, .app = app, .window = window, .host = &host, .player = &player };

    smoke.until("the first picture", ready) catch |err| {
        if (player.err()) |failure| {
            std.debug.print("video smoke: skipped, the system does not decode the clip: {s}\n", .{@errorName(failure)});
            return null;
        }
        return err;
    };
    try std.testing.expectEqual(view.Size{ .width = 64, .height = 48 }, player.size());
    const length = player.duration();
    try std.testing.expect(length >= 1100 * ms and length <= 1300 * ms);
    // Played through: red, then green, then blue to its end.
    try smoke.until("red", showing(red));
    try smoke.until("green", showing(green));
    try smoke.until("blue", showing(blue));
    try smoke.until("the end", ended);
    try std.testing.expect(!player.playing());

    // Paused, each seek shows its picture.
    player.pause();
    const stops = [_]struct { at: u64, color: [3]u8, check: *const fn (*Smoke, [3]u8) bool }{
        .{ .at = 500 * ms, .color = green, .check = showing(green) },
        .{ .at = 100 * ms, .color = red, .check = showing(red) },
        .{ .at = 900 * ms, .color = blue, .check = showing(blue) },
    };
    for (stops) |stop| {
        player.seek(stop.at);
        var tries: usize = 0;
        while (true) : (tries += 1) {
            if (tries == 1000) return error.Timeout;
            if (stop.check(&smoke, try smoke.frame())) break;
            zio.sleep(10 * ms);
        }
        const at = player.position();
        try std.testing.expect(at + 150 * ms >= stop.at and at <= stop.at + 150 * ms);
        try std.testing.expect(!player.playing());
    }
    // Played to its end again, then once more from its start.
    player.play();
    try smoke.until("the end again", ended);
    player.play();
    try smoke.until("red from the start", showing(red));
    std.debug.print("video smoke: {d} frames drawn with the GPU renderer\n", .{smoke.frames_on_gpu});
    // OpenGL on a software rasterizer draws only with ZIGGURAT_GL=on.
    const required = builtin.os.tag == .macos or if (std.c.getenv("ZIGGURAT_GL")) |value| std.mem.eql(u8, std.mem.span(value), "on") else false;
    if (gpu and required) try std.testing.expect(smoke.frames_on_gpu > 0);
    return smoke.frames_on_gpu;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const on_gpu = try run(gpa.allocator()) orelse return;
    std.debug.print("video native: the system's engine decoded the clip in a window, which showed red, green and blue to its end, the picture of each seek while paused, and the clip again from its start{s}\n", .{if (on_gpu > 0) ", drawn from NV12 on the GPU" else ""});
}
