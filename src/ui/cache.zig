//! A subtree kept as one image while what it draws stays the same.
//!
//! Between `Frame.beginCache` and `Frame.endCache` a frame records as
//! usual; at the end, the commands recorded in between are compared with
//! the last ones the cache drew, moved to its own origin. When they are the
//! same the cache draws its image in their place without rasterizing them;
//! when they differ (other content, size, scale or theme) it draws them
//! into a new image on an offscreen surface first. Hits, focus and
//! semantics are recorded as without the cache.
//!
//! Only plain drawings, clips, indicators and groups without a filter are
//! kept; a subtree with transforms, effects, backdrops, filters or GPU
//! textures, larger than `max_side` pixels across or `max_pixels` in all,
//! is drawn as it is. Text in the image is smoothed in grayscale, as on
//! any transparent offscreen surface.
const std = @import("std");
const z = @import("ziggurat");
const drawing = @import("ziggurat_drawing_resources");
const commands = @import("commands.zig");
const damage = @import("damage.zig");
const offscreen = @import("offscreen.zig");

pub const max_side = 4096;
pub const max_pixels = 2 * 1024 * 1024;

pub const Stats = struct {
    /// Frames that drew the subtree into a new image.
    renders: u64 = 0,
    /// Frames that drew the kept image without drawing the subtree.
    reuses: u64 = 0,
    /// Frames that drew the subtree as it is, as it could not be kept.
    direct: u64 = 0,
    /// The image's pixels, at the window's scale.
    width: u32 = 0,
    height: u32 = 0,
};

/// Takes a replaced image from the cache: the Context that drew it releases
/// it once no frame holds it. False when it cannot take it now.
pub const Retire = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, snapshot: *offscreen.Snapshot) bool,
};

/// Main-thread only. Create it with the window's App; destroy it before the
/// Context that draws it is destroyed.
pub const Cache = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    /// The subtree's commands at the cache's origin.
    buffer: *commands.Buffer,
    surface: ?*offscreen.Surface = null,
    surface_size: z.Size = .{ .width = 0, .height = 0, .scale = 0 },
    snapshot: ?*offscreen.Snapshot = null,
    hash: u64 = 0,
    /// Where the last image went when it is replaced or destroyed.
    retire: ?Retire = null,
    counters: Stats = .{},
    /// The image's top left, in device pixels of the window.
    origin: [2]i32 = .{ 0, 0 },

    pub fn create(app: *z.App, allocator: std.mem.Allocator) !*Cache {
        const buffer = try allocator.create(commands.Buffer);
        errdefer allocator.destroy(buffer);
        buffer.* = .{};
        const self = try allocator.create(Cache);
        self.* = .{ .app = app, .allocator = allocator, .buffer = buffer };
        return self;
    }

    /// Releases the surface and hands the image to the Context that drew
    /// it. Call between frames.
    pub fn destroy(self: *Cache) !void {
        if (self.snapshot) |snapshot| {
            if (self.retire) |retire| {
                if (!retire.call(retire.context, snapshot)) try snapshot.close();
            } else try snapshot.close();
            self.snapshot = null;
        }
        if (self.surface) |surface| try surface.close();
        self.surface = null;
        self.buffer.reset();
        self.allocator.destroy(self.buffer);
        self.allocator.destroy(self);
    }

    /// Draws the next frame's subtree into a new image even when it is the
    /// same, as after pixels it reads changed in place.
    pub fn invalidate(self: *Cache) void {
        self.hash = 0;
    }

    pub fn stats(self: *const Cache) Stats {
        return self.counters;
    }

    /// Replaces the commands `buffer` recorded since `mark` with the kept
    /// image, drawing them into it first when they differ from the last.
    /// False leaves them as recorded.
    pub fn resolve(self: *Cache, buffer: *commands.Buffer, mark: commands.Buffer.Checkpoint, scale: f32, retire: Retire) !bool {
        if (buffer.depth != mark.depth or buffer.group_depth != mark.group_depth) return error.UnbalancedCache;
        defer self.buffer.reset();
        if (!(try self.prepare(buffer, mark, scale, retire))) {
            self.counters.direct +%= 1;
            return false;
        }
        const snapshot = self.snapshot.?;
        const view = try snapshot.view();
        const s: f32 = scale;
        const size = self.surface_size;
        const origin = self.origin;
        buffer.rollback(mark);
        try buffer.image(.{ .x = @as(f32, @floatFromInt(origin[0])) / s, .y = @as(f32, @floatFromInt(origin[1])) / s, .width = @as(f32, @floatFromInt(size.width)) / s, .height = @as(f32, @floatFromInt(size.height)) / s }, view, .{});
        return true;
    }

    fn prepare(self: *Cache, buffer: *commands.Buffer, mark: commands.Buffer.Checkpoint, scale: f32, retire: Retire) !bool {
        const list = buffer.commands()[mark.len..];
        if (list.len == 0) return false;
        for (list) |command| if (!commands.Buffer.translatable(command)) return false;
        const box = damage.extent(list, damage.Sources.of(buffer), scale) orelse return false;
        const width: u32 = @intCast(box.x1 - box.x0);
        const height: u32 = @intCast(box.y1 - box.y0);
        if (width == 0 or height == 0 or width > max_side or height > max_side or @as(u64, width) * height > max_pixels) return false;
        const delta: drawing.Point = .{ .x = -@as(f32, @floatFromInt(box.x0)) / scale, .y = -@as(f32, @floatFromInt(box.y0)) / scale };
        self.buffer.reset();
        self.buffer.appendTranslated(buffer, mark.len, buffer.len, delta) catch return false;
        self.buffer.finish() catch return false;
        var hasher = std.hash.Wyhash.init(damage.hashCommands(self.buffer, 1.0 / 1024.0) orelse return false);
        hasher.update(std.mem.asBytes(&[_]u32{ width, height, @bitCast(scale) }));
        const hash = hasher.final() | 1;
        const size: z.Size = .{ .width = width, .height = height, .scale = scale };
        if (self.snapshot != null and hash == self.hash and std.meta.eql(size, self.surface_size)) {
            self.origin = .{ box.x0, box.y0 };
            self.counters.reuses +%= 1;
            return true;
        }
        if (!std.meta.eql(size, self.surface_size) or self.surface == null) {
            if (self.surface) |surface| {
                surface.close() catch return false;
                self.surface = null;
            }
            self.surface = offscreen.Surface.create(self.app, self.allocator, .{ .size = size }) catch return false;
            self.surface_size = size;
        }
        const surface = self.surface.?;
        for (self.buffer.imageResources()) |view| surface.uploadImage(view) catch return false;
        for (self.buffer.coverageResources()) |view| surface.uploadCoverage(view) catch return false;
        const next = surface.render(self.buffer) catch return false;
        if (self.snapshot) |old| if (!retire.call(retire.context, old)) {
            next.close() catch {};
            return false;
        };
        self.snapshot = next;
        self.retire = retire;
        self.hash = hash;
        self.origin = .{ box.x0, box.y0 };
        self.counters.renders +%= 1;
        self.counters.width = width;
        self.counters.height = height;
        return true;
    }
};

test "a kept subtree draws the pixels it would draw itself, and again only when it changes" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const linux = @import("linux.zig");
    const allocator = std.testing.allocator;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const kept = try Cache.create(app, allocator);
    const Retired = struct {
        list: [4]*offscreen.Snapshot = undefined,
        len: usize = 0,
        fn take(ptr: *anyopaque, snapshot: *offscreen.Snapshot) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.list[self.len] = snapshot;
            self.len += 1;
            return true;
        }
    };
    var retired: Retired = .{};
    const retire: Retire = .{ .context = &retired, .call = Retired.take };
    const size: z.Size = .{ .width = 120, .height = 80, .scale = 1.5 };
    const Scene = struct {
        fn background(buffer: *commands.Buffer) !void {
            try buffer.fill(.{ .x = 0, .y = 0, .width = 80, .height = 60 }, 0xf0f0f0);
        }
        fn card(buffer: *commands.Buffer, color: u32, x: f32) !void {
            try buffer.roundedRect(.{ .x = x, .y = 10.5, .width = 30, .height = 20 }, 6, .{ .r = @intCast(color >> 16), .g = 40, .b = 200, .a = 160 });
            try buffer.pushClip(.{ .x = x + 4, .y = 14, .width = 10, .height = 10 });
            try buffer.gradientRect(.{ .x = x, .y = 10, .width = 30, .height = 20 }, 0, .{ .linear = .{ .start = .{ .x = x, .y = 10 }, .end = .{ .x = x + 30, .y = 30 }, .stops = &.{ .{ .offset = 0, .color = .rgb(0xff0000) }, .{ .offset = 1, .color = .rgb(0x0000ff) } } } });
            try buffer.popClip();
        }
        fn draw(target: *linux.Renderer, buffer: *commands.Buffer, frame_size: z.Size) ![]u32 {
            var dummy: u8 = 0;
            try buffer.finish();
            try target.begin(.{ .native_context = &dummy, .size = frame_size });
            try target.residentFrame(buffer);
            try target.replayBuffer(buffer);
            var surface: @import("cpu_gradient.zig").Surface = undefined;
            if (target.testSurface(&surface) != 0) return error.DrawGradientFailed;
            const pixels = try std.testing.allocator.alloc(u32, surface.width * surface.height);
            for (0..surface.height) |y| @memcpy(pixels[y * surface.width ..][0..surface.width], surface.pixels[y * surface.stride ..][0..surface.width]);
            return pixels;
        }
    };
    var plain_renderer: linux.Renderer = .{};
    defer plain_renderer.deinit();
    var kept_renderer: linux.Renderer = .{};
    defer kept_renderer.deinit();
    for ([_]struct { color: u32, x: f32 }{ .{ .color = 0x200000, .x = 8 }, .{ .color = 0x200000, .x = 8 }, .{ .color = 0x200000, .x = 40 }, .{ .color = 0x900000, .x = 40 } }) |step| {
        var plain: commands.Buffer = .{};
        defer plain.reset();
        try Scene.background(&plain);
        try Scene.card(&plain, step.color, step.x);
        var buffer: commands.Buffer = .{};
        defer buffer.reset();
        try Scene.background(&buffer);
        const mark = buffer.checkpoint();
        try Scene.card(&buffer, step.color, step.x);
        try std.testing.expect(try kept.resolve(&buffer, mark, size.scale, retire));
        // The card is one image now.
        try std.testing.expectEqual(@as(usize, 2), buffer.commands().len);
        const want = try Scene.draw(&plain_renderer, &plain, size);
        defer std.testing.allocator.free(want);
        const got = try Scene.draw(&kept_renderer, &buffer, size);
        defer std.testing.allocator.free(got);
        // The image is drawn on a transparent plane and blended after, so
        // edges may round one or two steps apart.
        for (want, got) |a, b| for (0..4) |channel| {
            const shift: u5 = @intCast(channel * 8);
            const x: i32 = @intCast((a >> shift) & 255);
            const y: i32 = @intCast((b >> shift) & 255);
            if (@abs(x - y) > 3) {
                std.debug.print("pixel {x} against {x}\n", .{ a, b });
                return error.TestExpectedEqual;
            }
        };
    }
    // Moving the card by whole pixels keeps the image; another color draws
    // it again.
    try std.testing.expectEqual(@as(u64, 2), kept.stats().renders);
    try std.testing.expectEqual(@as(u64, 2), kept.stats().reuses);
    for (retired.list[0..retired.len]) |snapshot| {
        if (snapshot.view()) |view| _ = try kept_renderer.releaseImage(view.identity) else |_| {}
        try snapshot.close();
    }
    if (kept.snapshot) |snapshot| _ = try kept_renderer.releaseImage((try snapshot.view()).identity);
    kept.retire = null;
    try kept.destroy();
}
