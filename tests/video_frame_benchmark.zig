//! Frames of video an app decodes itself, drawn in a real window each frame
//! as they come: a new 1920×1080 frame every frame, shown at 1280×720.
//!
//! - `bgra`: converted to BGRA on the CPU, as a decoder's frames are before
//!   they reach a `ui.PixelImage`, and uploaded, 8 MB a frame;
//! - `nv12`: its NV12 planes as they are (`VideoImage.commitYuv`), 3 MB
//!   uploaded and converted in the shader;
//! - `i420`: its I420 planes, the chroma interleaved into the image's NV12
//!   plane on the way.
//!
//! With -Dgpu=true OpenGL (on llvmpipe only with ZIGGURAT_GL=on) or Metal
//! draws them, otherwise the software renderer does, converting as it
//! draws. Every frame is read back from the window, so a frame's time
//! includes what the GPU spent on it. The middle of each frame is checked
//! against the color its planes encode, so the run is also a check that
//! the renderers show an app's own planes in every layout and range.
//!
//! zig build benchmark-video-frames -Dgpu=true -- [frames]
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlm_test_paint(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;

const title = "Video frame benchmark";
const width = 1280;
const height = 720;
const frame_width = 1920;
const frame_height = 1080;
const gpu = @FieldType(ui.Context, "gpu_renderer") != void;

const Mode = enum { bgra, nv12, i420 };

const Screen = struct {
    image: *ui.VideoImage,
    fn build(self: *Screen, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .background = 0x000000 });
        if (self.image.view()) |shown| try v.image(shown, .{ .fit = .fill, .alt = "Frame" }, .{ .grow = 1, .self_align = .stretch });
        try v.end();
    }
};

/// Two frames, red and blue, which the run takes turns between, so that
/// each frame is a new picture, in each layout.
const Frames = struct {
    luma: [2][]u8,
    chroma: [2][]u8,
    u: [2][]u8,
    v: [2][]u8,
    bgra: [2][]u8,
    full_range: bool,

    // BT.709 red and blue: limited range, and full.
    const colors = [2][2][3]u8{ .{ .{ 63, 102, 240 }, .{ 32, 240, 118 } }, .{ .{ 54, 99, 255 }, .{ 18, 255, 116 } } };
    const want = [2][3]u8{ .{ 255, 0, 0 }, .{ 0, 0, 255 } };

    fn init(allocator: std.mem.Allocator, full_range: bool) !Frames {
        var self: Frames = undefined;
        self.full_range = full_range;
        const cw = frame_width / 2;
        const ch = frame_height / 2;
        for (0..2) |i| {
            const color = colors[@intFromBool(full_range)][i];
            self.luma[i] = try allocator.alloc(u8, frame_width * frame_height);
            self.chroma[i] = try allocator.alloc(u8, 2 * cw * ch);
            self.u[i] = try allocator.alloc(u8, cw * ch);
            self.v[i] = try allocator.alloc(u8, cw * ch);
            self.bgra[i] = try allocator.alloc(u8, frame_width * frame_height * 4);
            @memset(self.luma[i], color[0]);
            @memset(self.u[i], color[1]);
            @memset(self.v[i], color[2]);
            for (0..cw * ch) |p| {
                self.chroma[i][2 * p] = color[1];
                self.chroma[i][2 * p + 1] = color[2];
            }
        }
        return self;
    }
    fn deinit(self: *Frames, allocator: std.mem.Allocator) void {
        for (0..2) |i| for ([_][]u8{ self.luma[i], self.chroma[i], self.u[i], self.v[i], self.bgra[i] }) |bytes| allocator.free(bytes);
    }
    fn image(self: *const Frames, mode: Mode, i: usize) ui.YuvImage {
        return switch (mode) {
            .i420 => .{ .format = .i420, .width = frame_width, .height = frame_height, .planes = .{ self.luma[i], self.u[i], self.v[i] }, .strides = .{ frame_width, frame_width / 2, frame_width / 2 }, .matrix = .bt709, .full_range = self.full_range },
            else => .{ .format = .nv12, .width = frame_width, .height = frame_height, .planes = .{ self.luma[i], self.chroma[i], &.{} }, .strides = .{ frame_width, frame_width, 0 }, .matrix = .bt709, .full_range = self.full_range },
        };
    }
};

const Bench = struct {
    app: *z.App,
    window: z.Window,
    host: *view.Host,
    image: *ui.VideoImage,
    frames: *Frames,
    gpu_frames: usize = 0,

    /// Commits frame `i` in `mode`, draws the window and reads its middle.
    fn frame(self: *Bench, mode: Mode, i: usize) ![3]u8 {
        switch (mode) {
            .bgra => {
                // As a decoder in software would: convert, then upload.
                const yuv = self.frames.image(.nv12, i);
                const picture: ui.drawing.VideoPicture = .{ .width = frame_width, .height = frame_height, .matrix = yuv.videoMatrix(), .planes = .{ yuv.planes[0].ptr, yuv.planes[1].ptr }, .strides = .{ frame_width, frame_width } };
                if (!ui.video_image.toBgra(picture, self.frames.bgra[i], frame_width * 4)) return error.ConversionFailed;
                try self.image.commit(&self.host.context, .{ .width = frame_width, .height = frame_height, .format = .bgra, .planes = .{ self.frames.bgra[i].ptr, null }, .strides = .{ frame_width * 4, 0 } });
            },
            else => try self.image.commitYuv(&self.host.context, self.frames.image(mode, i)),
        }
        self.window.invalidate();
        var color: [3]u8 = .{ 0, 0, 0 };
        var drawn = false;
        if (gpu) {
            const renderer = &self.host.context.gpu_renderer;
            renderer.captureForTest(true);
            const before = self.host.context.gpu_frames;
            ui.GpuRenderer.displayForTest(title);
            if (self.host.context.gpu_frames > before) {
                self.gpu_frames += 1;
                drawn = true;
                const size = self.host.context.last_paint_size.?;
                const pixel = renderer.pixelForTest(size.width / 2, size.height / 2);
                color = .{ @truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel) };
            }
        }
        if (!drawn) {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            if (builtin.os.tag == .linux) zlg_test_paint(native, width, height) else zlm_test_paint(native);
            const size = self.host.context.last_paint_size orelse return error.NothingPainted;
            const pixel = zlc_test_raw_pixel(self.host.context.renderer.native.?, size.width / 2, size.height / 2);
            color = .{ @truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel) };
        }
        if (self.host.last_error) |err| return err;
        try self.app.dispatch();
        return color;
    }
};

fn near(color: [3]u8, want: [3]u8) bool {
    for (color, want) |a, b| if (@max(a, b) - @min(a, b) > 24) return false;
    return true;
}

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var count: usize = 30;
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len > 1) count = try std.fmt.parseInt(usize, args[1], 10);
    if (count < 2) return error.InvalidArguments;

    const app = try z.App.init(allocator);
    defer app.deinit();
    var image = ui.VideoImage.init(allocator);
    defer image.deinit();
    var screen: Screen = .{ .image = &image };
    var storage: view.Storage(8, 64) = .{};
    var host = view.Host.init(&screen, Screen.build, storage.buffers(), .{});
    const window = try app.createWindow(.{ .title = title, .width = width, .height = height });
    try host.attach(window);
    window.show();
    try app.dispatch();
    defer image.release(&host.context);

    const times = try allocator.alloc(u64, count);
    defer allocator.free(times);
    var bench: Bench = .{ .app = app, .window = window, .host = &host, .image = &image, .frames = undefined };
    std.debug.print("video frames: {d}×{d} frames shown at {d}×{d}, {d} a mode, each drawn and read back\n", .{ frame_width, frame_height, width, height, count });
    for ([_]bool{ false, true }) |full_range| {
        var frames = try Frames.init(allocator, full_range);
        defer frames.deinit(allocator);
        bench.frames = &frames;
        for ([_]Mode{ .bgra, .nv12, .i420 }) |mode| {
            // A frame before the clock, to upload the image once.
            _ = try bench.frame(mode, 1);
            const gpu_before = bench.gpu_frames;
            for (times, 0..) |*time, n| {
                var timer = try zio.Timer.start();
                const color = try bench.frame(mode, n % 2);
                time.* = timer.read();
                if (!near(color, Frames.want[n % 2])) {
                    std.debug.print("video frames: {s}{s} frame {d} shows {any}, want {any}\n", .{ @tagName(mode), if (full_range) " full range" else "", n, color, Frames.want[n % 2] });
                    return error.WrongColor;
                }
            }
            const on_gpu = bench.gpu_frames - gpu_before;
            std.debug.print("video frames: mode={s} range={s} renderer={s} median_ms={d:.2} min_ms={d:.2}\n", .{
                @tagName(mode),                                                                                                       if (full_range) "full" else "limited",
                if (on_gpu == count) (if (builtin.os.tag == .macos) "metal" else "gl") else if (on_gpu == 0) "software" else "mixed", @as(f64, @floatFromInt(median(times))) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(times[0])) / std.time.ns_per_ms,
            });
        }
    }
    // Metal always draws; OpenGL on a software rasterizer only when asked.
    const required = builtin.os.tag == .macos or if (zio.getenv("ZIGGURAT_GL")) |value| std.mem.eql(u8, value, "on") else false;
    if (gpu and required and bench.gpu_frames == 0) return error.NoGpuFrames;
}
