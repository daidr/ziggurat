//! Frames of video shown as an image that changes with each of them: a
//! `VideoImage` takes the pictures a system decoder leaves where it decoded
//! them (`drawing.VideoPicture`), NV12 planes in memory or a picture on the
//! GPU, and `Frame.image(…, view())` draws the one committed last.
//!
//! The GPU renderers take the picture as it is: OpenGL (and WebGL) upload
//! its two planes and convert them in the shader, half the bytes BGRA
//! takes; Metal wraps a CVPixelBuffer as textures without a copy; WebGL
//! uploads a video element's picture GPU to GPU. The software renderers
//! draw BGRA: the picture converts into the image's own buffer when one of
//! them draws it, and only then, so a window the GPU draws never converts.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");

/// Main-thread only. Keep it at a stable address while committed.
pub const VideoImage = struct {
    allocator: std.mem.Allocator,
    lease: drawing.Lease,
    width: u32 = 0,
    height: u32 = 0,
    /// The BGRA buffers the software renderers draw, a picture's taking
    /// turns, allocated at the pictures' size.
    buffers: [2][]u8 = .{ &.{}, &.{} },
    levels: [2][1]drawing.ImageLevel = undefined,
    identities: [2]u64 = .{ 0, 0 },
    back: u1 = 0,
    /// The identity the renderers hold, once a commit uploaded it.
    committed: ?u64 = null,
    source: drawing.VideoSource = .{ .picture = .{ .width = 0, .height = 0 }, .convert = convertSource },

    pub fn init(allocator: std.mem.Allocator) VideoImage {
        return .{ .allocator = allocator, .lease = drawing.Lease.init(std.Thread.getCurrentId()) };
    }
    /// Releases the buffers; call `release` first while a window still
    /// shows the picture.
    pub fn deinit(self: *VideoImage) void {
        for (self.buffers) |buffer| if (buffer.len != 0) self.allocator.free(buffer);
        self.* = undefined;
    }

    /// The committed picture, or null before the first commit.
    pub fn view(self: *VideoImage) ?drawing.ImageView {
        if (self.committed == null) return null;
        const front = self.back ^ 1;
        return .{ .lease = &self.lease, .identity = self.identities[front], .levels = &self.levels[front], .video = &self.source };
    }

    /// Shows `picture` from the next paint on, in `context`, a `ui.Context`
    /// attached to a window. Call it outside paint. The picture's planes or
    /// native picture stay valid until the next commit, or `release`.
    pub fn commit(self: *VideoImage, context: anytype, picture: drawing.VideoPicture) !void {
        try picture.validate();
        if (picture.width != self.width or picture.height != self.height) {
            // A new size is a new image.
            self.release(context);
            try self.resize(picture.width, picture.height);
        }
        const index = self.back;
        const identity = drawing.reserveRasterIdentity() catch return error.ImageIdentityExhausted;
        self.levels[index] = .{.{ .pixels = self.buffers[index].ptr, .byte_len = self.buffers[index].len, .width = self.width, .height = self.height, .stride = self.width * 4 }};
        self.identities[index] = identity;
        self.source.picture = picture;
        self.source.converted = 0;
        const next: drawing.ImageView = .{ .lease = &self.lease, .identity = identity, .levels = &self.levels[index], .video = &self.source };
        if (self.committed) |old| {
            context.updateImage(old, next) catch |err| {
                const reason: anyerror = err;
                if (reason == error.ImageNotUploaded) {
                    try context.uploadDynamicImage(next);
                } else if (reason == error.ImageNotDynamic) {
                    _ = try context.releaseImage(old);
                    try context.uploadDynamicImage(next);
                } else return err;
            };
        } else try context.uploadDynamicImage(next);
        self.committed = identity;
        self.back ^= 1;
    }

    /// Keeps the committed picture as BGRA of the image's own, for its
    /// producer to free the picture it gave, as a closing engine does.
    pub fn keep(self: *VideoImage) void {
        const shown = self.view() orelse return;
        if (!self.source.ensure(shown)) @memset(@constCast(shown.levels[0].pixels)[0..shown.levels[0].byte_len], 0);
        self.source.converted = shown.identity;
        self.source.picture = .{ .width = self.width, .height = self.height, .format = .bgra, .planes = .{ shown.levels[0].pixels, null }, .strides = .{ self.width * 4, 0 } };
    }

    /// Lets the renderers drop the picture, as before `deinit` or when the
    /// producer frees it.
    pub fn release(self: *VideoImage, context: anytype) void {
        if (self.committed) |identity| _ = context.releaseImage(identity) catch {};
        if (self.source.software != 0 and self.source.software != self.committed) _ = context.releaseImage(self.source.software) catch {};
        self.committed = null;
        self.source.software = 0;
        self.source.converted = 0;
    }

    fn resize(self: *VideoImage, width: u32, height: u32) !void {
        const bytes = @as(usize, width) * height * 4;
        for (&self.buffers) |*buffer| {
            if (buffer.len != 0) self.allocator.free(buffer.*);
            buffer.* = &.{};
        }
        self.width = 0;
        self.height = 0;
        const first = try self.allocator.alloc(u8, bytes);
        errdefer self.allocator.free(first);
        const second = try self.allocator.alloc(u8, bytes);
        @memset(first, 0);
        @memset(second, 0);
        self.buffers = .{ first, second };
        self.width = width;
        self.height = height;
    }

    fn convertSource(source: *drawing.VideoSource, image: drawing.ImageView) bool {
        const level = image.levels[0];
        const pixels: [*]u8 = @constCast(level.pixels);
        return toBgra(source.picture, pixels[0..level.byte_len], level.stride);
    }
};

/// Writes `picture` into `pixels` as premultiplied BGRA rows of `stride`
/// bytes, as the shaders sample it: each pixel's chroma bilinear between
/// the chroma samples around it, centered between luma's (as MPEG-1 and
/// JPEG place them). False for a picture it cannot read.
pub fn toBgra(picture: drawing.VideoPicture, pixels: []u8, stride: u32) bool {
    const w = picture.width;
    const h = picture.height;
    if (w == 0 or h == 0 or stride < w * 4 or pixels.len < @as(usize, stride) * (h - 1) + w * 4) return false;
    const luma = picture.planes[0] orelse {
        const read = picture.read orelse return false;
        return read(picture.read_context, &picture, pixels.ptr, stride);
    };
    switch (picture.format) {
        .bgra => {
            for (0..h) |y| @memcpy(pixels[y * stride ..][0 .. w * 4], luma[y * picture.strides[0] ..][0 .. w * 4]);
            return true;
        },
        .nv12 => {},
    }
    const chroma = picture.planes[1] orelse return false;
    const k = Coefficients.of(picture.matrix);
    const cw = picture.chromaWidth();
    const ch = picture.chromaHeight();
    const cs = picture.strides[1];
    for (0..h) |y| {
        // The chroma sample's center is at (2i+1)/2 in luma pixels.
        const fy = (@as(f32, @floatFromInt(y)) + 0.5) / 2 - 0.5;
        const y0f = @floor(fy);
        const ty = fy - y0f;
        const y0: i64 = @intFromFloat(y0f);
        const r0: usize = @intCast(std.math.clamp(y0, 0, @as(i64, ch) - 1));
        const r1: usize = @intCast(std.math.clamp(y0 + 1, 0, @as(i64, ch) - 1));
        const row0 = chroma + r0 * cs;
        const row1 = chroma + r1 * cs;
        const out = pixels[y * stride ..];
        const lrow = luma + y * picture.strides[0];
        for (0..w) |x| {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5) / 2 - 0.5;
            const x0f = @floor(fx);
            const tx = fx - x0f;
            const x0: i64 = @intFromFloat(x0f);
            const c0: usize = @intCast(std.math.clamp(x0, 0, @as(i64, cw) - 1));
            const c1: usize = @intCast(std.math.clamp(x0 + 1, 0, @as(i64, cw) - 1));
            var c: [2]f32 = undefined;
            inline for (0..2) |n| {
                const a = sample(row0, c0, n) * (1 - tx) + sample(row0, c1, n) * tx;
                const b = sample(row1, c0, n) * (1 - tx) + sample(row1, c1, n) * tx;
                c[n] = a * (1 - ty) + b * ty;
            }
            const rgb = k.rgb(@as(f32, @floatFromInt(lrow[x])) / 255, c[0], c[1]);
            const o = out[x * 4 ..][0..4];
            o[0] = to8(rgb[2]);
            o[1] = to8(rgb[1]);
            o[2] = to8(rgb[0]);
            o[3] = 255;
        }
    }
    return true;
}

inline fn sample(row: [*]const u8, column: usize, component: usize) f32 {
    return @as(f32, @floatFromInt(row[column * 2 + component])) / 255;
}
fn to8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
}

/// Kr and Kb of a standard, and its range, as the shaders' yuvToRGB.
pub const Coefficients = struct {
    kr: f32,
    kb: f32,
    full: bool,

    pub fn of(matrix: drawing.VideoMatrix) Coefficients {
        const code = @backingInt(matrix);
        const full = code >= 3;
        return switch (code % 3) {
            0 => .{ .kr = 0.299, .kb = 0.114, .full = full },
            1 => .{ .kr = 0.2126, .kb = 0.0722, .full = full },
            else => .{ .kr = 0.2627, .kb = 0.0593, .full = full },
        };
    }
    /// Samples 0 to 1 to RGB, clamped.
    pub fn rgb(self: Coefficients, y_in: f32, cb_in: f32, cr_in: f32) [3]f32 {
        var y = y_in;
        var cb = cb_in - 128.0 / 255.0;
        var cr = cr_in - 128.0 / 255.0;
        if (!self.full) {
            y = (y - 16.0 / 255.0) * (255.0 / 219.0);
            cb *= 255.0 / 224.0;
            cr *= 255.0 / 224.0;
        }
        const r = y + 2 * (1 - self.kr) * cr;
        const b = y + 2 * (1 - self.kb) * cb;
        const g = (y - self.kr * r - self.kb * b) / (1 - self.kr - self.kb);
        return .{ std.math.clamp(r, 0, 1), std.math.clamp(g, 0, 1), std.math.clamp(b, 0, 1) };
    }
};

test "limited range BT.601 NV12 converts to the colors it encodes" {
    // Red, green, blue and white as BT.601 limited range samples.
    const colors = [_][3]u8{ .{ 81, 90, 240 }, .{ 145, 54, 34 }, .{ 41, 240, 110 }, .{ 235, 128, 128 } };
    const want = [_][3]u8{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 255, 255, 255 } };
    for (colors, want) |yuv, rgb| {
        const luma: [16]u8 = @splat(yuv[0]);
        var chroma: [8]u8 = undefined;
        for (0..4) |i| chroma[i * 2 ..][0..2].* = .{ yuv[1], yuv[2] };
        var pixels: [64]u8 = undefined;
        try std.testing.expect(toBgra(.{ .width = 4, .height = 4, .matrix = .bt601, .planes = .{ &luma, &chroma }, .strides = .{ 4, 4 } }, &pixels, 16));
        for (0..16) |i| {
            const p = pixels[i * 4 ..][0..4];
            for (0..3) |c| try std.testing.expect(@abs(@as(i32, p[2 - c]) - rgb[c]) <= 3);
            try std.testing.expectEqual(@as(u8, 255), p[3]);
        }
    }
}

test "full range BT.709 and odd sizes, with chroma interpolated between samples" {
    // 3×1: a chroma plane of 2×1, gray on the left, the right more red.
    const luma = [_]u8{ 128, 128, 128 };
    const chroma = [_]u8{ 128, 128, 128, 255 };
    var pixels: [12]u8 = undefined;
    try std.testing.expect(toBgra(.{ .width = 3, .height = 1, .matrix = .bt709_full, .planes = .{ &luma, &chroma }, .strides = .{ 3, 4 } }, &pixels, 12));
    // The first pixel is gray, the next ones redder.
    try std.testing.expectEqual(pixels[0], pixels[2]);
    try std.testing.expect(pixels[6] > pixels[2] and pixels[10] > pixels[6]);
    try std.testing.expect(!toBgra(.{ .width = 3, .height = 1, .planes = .{ &luma, &chroma }, .strides = .{ 3, 4 } }, &pixels, 8));
}

test "a video image takes turns between two buffers and converts when asked" {
    var image = VideoImage.init(std.testing.allocator);
    defer image.deinit();
    const Uploads = struct {
        held: ?u64 = null,
        uploads: usize = 0,
        fn uploadDynamicImage(self: *@This(), next: drawing.ImageView) !void {
            try next.validate();
            self.held = next.identity;
            self.uploads += 1;
        }
        fn updateImage(self: *@This(), old: u64, next: drawing.ImageView) !void {
            if (self.held != old) return error.ImageNotUploaded;
            self.held = next.identity;
        }
        fn releaseImage(self: *@This(), identity: u64) !bool {
            if (self.held != identity) return false;
            self.held = null;
            return true;
        }
    };
    var context: Uploads = .{};
    const white: [4]u8 = @splat(235);
    const neutral: [2]u8 = @splat(128);
    try image.commit(&context, .{ .width = 2, .height = 2, .matrix = .bt601, .planes = .{ &white, &neutral }, .strides = .{ 2, 2 } });
    const first = image.view().?;
    try std.testing.expect(first.video != null);
    try std.testing.expect(first.video.?.ensure(first));
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, first.levels[0].pixels[0..4]);
    const black: [4]u8 = @splat(16);
    try image.commit(&context, .{ .width = 2, .height = 2, .matrix = .bt601, .planes = .{ &black, &neutral }, .strides = .{ 2, 2 } });
    const second = image.view().?;
    try std.testing.expect(second.levels[0].pixels != first.levels[0].pixels);
    try std.testing.expect(second.video.?.ensure(second));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, second.levels[0].pixels[0..4]);
    try std.testing.expectEqual(context.held.?, second.identity);
    // Another size is another image.
    const wide: [8]u8 = @splat(16);
    const wide_chroma: [4]u8 = @splat(128);
    try image.commit(&context, .{ .width = 4, .height = 2, .matrix = .bt601, .planes = .{ &wide, &wide_chroma }, .strides = .{ 4, 4 } });
    try std.testing.expectEqual(@as(usize, 2), context.uploads);
    image.release(&context);
    try std.testing.expect(context.held == null and image.view() == null);
}
