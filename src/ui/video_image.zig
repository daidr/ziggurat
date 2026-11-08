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
const yuv_image = @import("yuv.zig");

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
    /// The chroma of the last I420 frame, interleaved as NV12's
    /// (`commitYuv`).
    chroma: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) VideoImage {
        return .{ .allocator = allocator, .lease = drawing.Lease.init(std.Thread.getCurrentId()) };
    }
    /// Releases the buffers; call `release` first while a window still
    /// shows the picture.
    pub fn deinit(self: *VideoImage) void {
        for (self.buffers) |buffer| if (buffer.len != 0) self.allocator.free(buffer);
        if (self.chroma.len != 0) self.allocator.free(self.chroma);
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

    /// Shows a frame of video in Y′CbCr, as a decoder of the app's own (such
    /// as FFmpeg) gives it, without converting it: `commit` of its planes,
    /// NV12's as they are and I420's Cb and Cr interleaved into a plane of
    /// NV12's chroma the image keeps. The GPU renderers upload the planes
    /// and convert them as they sample them; the software renderers, and
    /// captures, convert the frame as they draw it. The planes are taken
    /// without a copy, but for I420's chroma: keep them as they are until
    /// the next commit. The frame shows at its size, which the GPU scales
    /// as it samples it, without the halved copies of an image shown much
    /// smaller: have the decoder give the size it shows at, where it can.
    /// Panics on a frame its planes cannot hold (`YuvImage.check`).
    pub fn commitYuv(self: *VideoImage, context: anytype, image: yuv_image.YuvImage) !void {
        var old: []u8 = &.{};
        const previous = self.chroma;
        const picture = try image.picture(self.allocator, &self.chroma, &old);
        self.commit(context, picture) catch |err| {
            // The renderers still show the frame before, whose chroma is
            // the buffer replaced.
            if (old.len != 0 or (previous.len == 0 and self.chroma.len != 0)) {
                self.allocator.free(self.chroma);
                self.chroma = previous;
            }
            return err;
        };
        if (old.len != 0) self.allocator.free(old);
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

/// A w×h picture of bars in NV12, and the same picture in I420, every
/// plane in rows padded past their samples, as decoders pad them.
const Frames = struct {
    luma: []u8,
    nv12_chroma: []u8,
    u: []u8,
    v: []u8,
    nv12: yuv_image.YuvImage,
    i420: yuv_image.YuvImage,

    fn init(allocator: std.mem.Allocator, w: u32, h: u32, matrix: yuv_image.YuvMatrix) !Frames {
        const cw = (w + 1) / 2;
        const ch = (h + 1) / 2;
        const ls = w + 3;
        const ns = 2 * cw + 6;
        const cs = cw + 5;
        const luma = try allocator.alloc(u8, ls * h);
        const nv12_chroma = try allocator.alloc(u8, ns * ch);
        const u = try allocator.alloc(u8, cs * ch);
        const v = try allocator.alloc(u8, cs * ch);
        @memset(luma, 0xee);
        @memset(nv12_chroma, 0xee);
        @memset(u, 0xee);
        @memset(v, 0xee);
        for (0..h) |y| for (0..w) |x| {
            luma[y * ls + x] = @intCast(16 + (x * 219) / w);
        };
        for (0..ch) |y| for (0..cw) |x| {
            const cb: u8 = @intCast(16 + (x * 224) / cw);
            const cr: u8 = @intCast(240 - (y * 224) / ch);
            nv12_chroma[y * ns + 2 * x] = cb;
            nv12_chroma[y * ns + 2 * x + 1] = cr;
            u[y * cs + x] = cb;
            v[y * cs + x] = cr;
        };
        return .{
            .luma = luma,
            .nv12_chroma = nv12_chroma,
            .u = u,
            .v = v,
            .nv12 = .{ .format = .nv12, .width = w, .height = h, .matrix = matrix, .planes = .{ luma, nv12_chroma, &.{} }, .strides = .{ ls, ns, 0 } },
            .i420 = .{ .format = .i420, .width = w, .height = h, .matrix = matrix, .planes = .{ luma, u, v }, .strides = .{ ls, cs, cs } },
        };
    }
    fn deinit(self: Frames, allocator: std.mem.Allocator) void {
        for ([_][]u8{ self.luma, self.nv12_chroma, self.u, self.v }) |bytes| allocator.free(bytes);
    }
};

const TestUploads = struct {
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

fn drawn(allocator: std.mem.Allocator, image: *VideoImage) ![]u8 {
    const shown = image.view().?;
    try std.testing.expect(shown.video.?.ensure(shown));
    return allocator.dupe(u8, shown.levels[0].pixels[0..shown.levels[0].byte_len]);
}

test "frames in NV12 and I420 show the pixels their planes convert to, NV12's without a copy" {
    const allocator = std.testing.allocator;
    const w = 37;
    const h = 21;
    const frames = try Frames.init(allocator, w, h, .bt709);
    defer frames.deinit(allocator);
    var image = VideoImage.init(allocator);
    defer image.deinit();
    var context: TestUploads = .{};

    try image.commitYuv(&context, frames.nv12);
    const picture = image.source.picture;
    try std.testing.expectEqual(drawing.VideoFormat.nv12, picture.format);
    try std.testing.expectEqual(drawing.VideoMatrix.bt709, picture.matrix);
    try std.testing.expectEqual(@as(?[*]const u8, frames.luma.ptr), picture.planes[0]);
    try std.testing.expectEqual(@as(?[*]const u8, frames.nv12_chroma.ptr), picture.planes[1]);
    try std.testing.expectEqual(@as(usize, 0), image.chroma.len);
    const want = try drawn(allocator, &image);
    defer allocator.free(want);

    try image.commitYuv(&context, frames.i420);
    const interleaved = image.source.picture;
    try std.testing.expectEqual(@as(?[*]const u8, frames.luma.ptr), interleaved.planes[0]);
    try std.testing.expectEqual(@as(u32, 2 * ((w + 1) / 2)), interleaved.strides[1]);
    try std.testing.expectEqual(@as(?[*]const u8, image.chroma.ptr), interleaved.planes[1]);
    const got = try drawn(allocator, &image);
    defer allocator.free(got);
    try std.testing.expectEqualSlices(u8, want, got);
    // The next I420 frame interleaves into the same plane, and the frames
    // of one size are one image, which the renderers update in place.
    const chroma = image.chroma.ptr;
    try image.commitYuv(&context, frames.i420);
    try std.testing.expectEqual(chroma, image.chroma.ptr);
    try std.testing.expectEqual(@as(usize, 1), context.uploads);

    // Another size is another image; its chroma plane grows.
    const big = try Frames.init(allocator, 64, 48, .bt601);
    defer big.deinit(allocator);
    try image.commitYuv(&context, big.i420);
    try std.testing.expectEqual(@as(usize, 2), context.uploads);
    try std.testing.expect(image.chroma.len >= 64 * 24);
    image.release(&context);
}

test "a frame's matrix and range reach the renderers" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { matrix: yuv_image.YuvMatrix, full: bool, want: drawing.VideoMatrix }{
        .{ .matrix = .bt601, .full = false, .want = .bt601 },
        .{ .matrix = .bt709, .full = false, .want = .bt709 },
        .{ .matrix = .bt2020, .full = false, .want = .bt2020 },
        .{ .matrix = .bt601, .full = true, .want = .bt601_full },
        .{ .matrix = .bt709, .full = true, .want = .bt709_full },
        .{ .matrix = .bt2020, .full = true, .want = .bt2020_full },
    };
    var chroma: []u8 = &.{};
    defer if (chroma.len != 0) allocator.free(chroma);
    for (cases) |case| {
        const frames = try Frames.init(allocator, 4, 4, case.matrix);
        defer frames.deinit(allocator);
        var image = frames.nv12;
        image.full_range = case.full;
        var old: []u8 = &.{};
        try std.testing.expectEqual(case.want, (try image.picture(allocator, &chroma, &old)).matrix);
    }
    // The full range converts otherwise than video's: black at 16 is gray.
    const luma: [4]u8 = @splat(16);
    const neutral: [2]u8 = @splat(128);
    var pixels: [16]u8 = undefined;
    try std.testing.expect(toBgra(.{ .width = 2, .height = 2, .matrix = .bt709_full, .planes = .{ &luma, &neutral }, .strides = .{ 2, 2 } }, &pixels, 8));
    try std.testing.expectEqual(@as(u8, 16), pixels[0]);
    try std.testing.expect(toBgra(.{ .width = 2, .height = 2, .matrix = .bt709, .planes = .{ &luma, &neutral }, .strides = .{ 2, 2 } }, &pixels, 8));
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
}

test "a frame whose planes do not hold its picture is refused" {
    const allocator = std.testing.allocator;
    const frames = try Frames.init(allocator, 9, 7, .bt709);
    defer frames.deinit(allocator);
    const Change = *const fn (*yuv_image.YuvImage) void;
    const changes = [_]struct { err: yuv_image.YuvError, change: Change }{
        .{ .err = error.InvalidSize, .change = struct {
            fn f(m: *yuv_image.YuvImage) void {
                m.width = 0;
            }
        }.f },
        .{ .err = error.PlaneTooSmall, .change = struct {
            fn f(m: *yuv_image.YuvImage) void {
                m.planes[0] = m.planes[0][0 .. m.strides[0] * (m.height - 1) + m.width - 1];
            }
        }.f },
        .{ .err = error.PlaneTooSmall, .change = struct {
            fn f(m: *yuv_image.YuvImage) void {
                m.strides[0] = m.width - 1;
            }
        }.f },
        .{ .err = error.PlaneTooSmall, .change = struct {
            fn f(m: *yuv_image.YuvImage) void {
                m.planes[1] = m.planes[1][0 .. m.strides[1] * (m.chromaHeight() - 1) + 2 * m.chromaWidth() - 1];
            }
        }.f },
        .{ .err = error.PlaneTooSmall, .change = struct {
            fn f(m: *yuv_image.YuvImage) void {
                m.format = .i420;
                m.planes[2] = &.{};
            }
        }.f },
        .{ .err = error.OddChromaStride, .change = struct {
            fn f(m: *yuv_image.YuvImage) void {
                m.strides[1] -= 1;
            }
        }.f },
        .{ .err = error.InvalidMatrix, .change = struct {
            fn f(m: *yuv_image.YuvImage) void {
                m.matrix = @fromBackingInt(@intCast(3));
            }
        }.f },
        .{ .err = error.InvalidFormat, .change = struct {
            fn f(m: *yuv_image.YuvImage) void {
                m.format = @fromBackingInt(@intCast(2));
            }
        }.f },
    };
    try frames.nv12.check();
    try frames.i420.check();
    for (changes) |case| {
        var image = frames.nv12;
        case.change(&image);
        try std.testing.expectError(case.err, image.check());
    }
}
