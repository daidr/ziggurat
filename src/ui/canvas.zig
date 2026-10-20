//! A picture drawn once into an offscreen image and reused by every frame
//! until the application invalidates it, so costly content, such as an
//! effect-heavy chart, is not recorded and rasterized on each paint.
const std = @import("std");
const z = @import("ziggurat");
const drawing = @import("ziggurat_drawing_resources");
const commands = @import("commands.zig");
const input = @import("input.zig");
const offscreen = @import("offscreen.zig");

/// Records the picture into `buffer`, whose coordinates span `size` in DIP.
pub const Draw = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, buffer: *commands.Buffer, size: z.Size) anyerror!void,
};
pub const Stats = struct { renders: u64, reuses: u64, pixel_bytes: usize };

/// Main-thread only. The App and allocator must outlive the Canvas.
pub const Canvas = struct {
    allocator: std.mem.Allocator,
    surface: *offscreen.Surface,
    buffer: *commands.Buffer,
    snapshot: ?*offscreen.Snapshot = null,
    size: z.Size,
    renders: u64 = 0,
    reuses: u64 = 0,

    /// `options.size` is the image in physical pixels and its scale.
    pub fn create(app: *z.App, allocator: std.mem.Allocator, options: offscreen.Options) !*Canvas {
        const buffer = try allocator.create(commands.Buffer);
        errdefer allocator.destroy(buffer);
        buffer.* = .{};
        const surface = try offscreen.Surface.create(app, allocator, options);
        errdefer surface.close() catch {};
        const self = try allocator.create(Canvas);
        self.* = .{ .allocator = allocator, .surface = surface, .buffer = buffer, .size = options.size };
        return self;
    }
    /// Release the image and surface. Fails with `Busy` while a frame still
    /// holds the image.
    pub fn destroy(self: *Canvas) !void {
        if (self.snapshot) |snapshot| {
            try snapshot.close();
            self.snapshot = null;
        }
        try self.surface.close();
        self.allocator.destroy(self.buffer);
        self.allocator.destroy(self);
    }
    /// Drop the image; the next `view` or `paint` draws it again. Call
    /// between frames: an image a recorded frame still holds cannot close.
    pub fn invalidate(self: *Canvas) !void {
        const snapshot = self.snapshot orelse return;
        try snapshot.close();
        self.snapshot = null;
    }
    pub fn valid(self: *const Canvas) bool {
        return self.snapshot != null;
    }
    /// The image, drawn through `draw` first when there is none.
    pub fn view(self: *Canvas, draw: Draw) !drawing.ImageView {
        if (self.snapshot) |snapshot| {
            self.reuses +%= 1;
            return snapshot.view();
        }
        defer self.buffer.reset();
        try draw.run(draw.context, self.buffer, self.size);
        const snapshot = try self.surface.render(self.buffer);
        self.snapshot = snapshot;
        self.renders +%= 1;
        return snapshot.view();
    }
    /// Draw the image into `frame` over `destination`; `frame` is a
    /// `ui.Frame` or any value with its `image` method.
    pub fn paint(self: *Canvas, frame: anytype, destination: input.Rect, draw: Draw, options: drawing.ImageOptions) !void {
        try frame.image(destination, try self.view(draw), options);
    }
    pub fn stats(self: *const Canvas) Stats {
        return .{ .renders = self.renders, .reuses = self.reuses, .pixel_bytes = @as(usize, self.size.width) * self.size.height * 4 };
    }
};

test "a canvas draws once and redraws only after invalidation" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const canvas = try Canvas.create(app, std.testing.allocator, .{ .size = .{ .width = 4, .height = 4, .scale = 1 } });
    defer canvas.destroy() catch unreachable;
    const Picture = struct {
        draws: usize = 0,
        color: u8 = 255,
        fn run(context: *anyopaque, buffer: *commands.Buffer, size: z.Size) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.draws += 1;
            try buffer.roundedRect(.{ .x = 0, .y = 0, .width = @floatFromInt(size.width), .height = @floatFromInt(size.height) }, 0, .{ .r = self.color, .g = 0, .b = 0, .a = 255 });
        }
    };
    var picture: Picture = .{};
    const draw: Draw = .{ .context = &picture, .run = Picture.run };
    const first = try canvas.view(draw);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, first.levels[0].pixels[0..4]);
    _ = try canvas.view(draw);
    try std.testing.expectEqual(@as(usize, 1), picture.draws);
    try canvas.invalidate();
    picture.color = 0;
    const second = try canvas.view(draw);
    try std.testing.expectEqual(@as(usize, 2), picture.draws);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, second.levels[0].pixels[0..4]);
    try std.testing.expectEqual(Stats{ .renders = 2, .reuses = 1, .pixel_bytes = 64 }, canvas.stats());
}
