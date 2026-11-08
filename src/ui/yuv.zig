//! Frames of video in Y′CbCr with their chroma at half the size both ways
//! (4:2:0), as video decoders give them, for a `VideoImage` to show without
//! converting them to BGRA (`VideoImage.commitYuv`): the GPU renderers
//! upload the planes, 1.5 bytes a pixel against BGRA's 4, and convert them
//! as they sample them, so that showing a frame costs the CPU no conversion.
//!
//! NV12's planes go to the renderers as they are; I420's Cb and Cr are
//! interleaved into a plane of NV12's chroma that the image keeps, a quarter
//! of the frame's bytes, so that the renderers and their shaders know one
//! layout of planes.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");

/// How a `YuvImage` lays out its samples.
pub const YuvFormat = enum(u8) {
    /// A plane of luma and one of chroma, Cb and Cr interleaved, as hardware
    /// decoders leave pictures (VideoToolbox, Direct3D, VA-API).
    nv12,
    /// A plane of luma, one of Cb and one of Cr, as software decoders leave
    /// pictures (FFmpeg's YUV420P).
    i420,
    _,
};

/// The standard whose coefficients convert Y′CbCr to RGB.
pub const YuvMatrix = enum(u8) {
    /// Standard definition video's, and JPEG's.
    bt601,
    /// HD video's, as most streams, cameras and screen recordings are.
    bt709,
    /// UHD video's. Only its matrix applies: HDR video shows with the
    /// transfer of SDR.
    bt2020,
    _,
};

/// Why `YuvImage.check` refuses a picture.
pub const YuvError = error{ InvalidSize, InvalidFormat, InvalidMatrix, PlaneTooSmall, OddChromaStride };

/// A picture in Y′CbCr 4:2:0. The planes are borrowed: keep them as they
/// are until the next commit.
pub const YuvImage = struct {
    format: YuvFormat = .nv12,
    /// The picture's size in pixels. Its chroma is half as wide and high,
    /// rounded up.
    width: u32,
    height: u32,
    /// The luma, a byte a pixel, then NV12's chroma, Cb and Cr interleaved,
    /// a pair of bytes for each sample, or I420's Cb and Cr, a byte each.
    planes: [3][]const u8 = .{ &.{}, &.{}, &.{} },
    /// The rows' lengths in bytes, which may be longer than the samples, as
    /// decoders pad them.
    strides: [3]u32 = .{ 0, 0, 0 },
    /// Converts the samples to RGB.
    matrix: YuvMatrix = .bt709,
    /// The samples take all of 0 to 255 rather than video's range, 16 to
    /// 235 for luma and 16 to 240 for chroma, as JPEG's do and video's
    /// rarely do.
    full_range: bool = false,

    pub fn chromaWidth(self: YuvImage) u32 {
        return (self.width + 1) / 2;
    }
    pub fn chromaHeight(self: YuvImage) u32 {
        return (self.height + 1) / 2;
    }
    /// The renderers' matrix: the standard and the range.
    pub fn videoMatrix(self: YuvImage) drawing.VideoMatrix {
        return drawing.VideoMatrix.of(@backingInt(self.matrix), self.full_range);
    }

    /// Whether the planes hold the picture, so that no renderer reads past
    /// them; `picture` panics where this returns an error.
    pub fn check(self: YuvImage) YuvError!void {
        if (self.width == 0 or self.height == 0 or self.width > 16384 or self.height > 16384 or @as(u64, self.width) * self.height > 16 * 1024 * 1024) return error.InvalidSize;
        if (@backingInt(self.matrix) > @backingInt(YuvMatrix.bt2020)) return error.InvalidMatrix;
        try self.plane(0, self.width, self.height);
        const cw = self.chromaWidth();
        const ch = self.chromaHeight();
        switch (self.format) {
            .nv12 => {
                try self.plane(1, 2 * cw, ch);
                // The renderers read the chroma in pairs of bytes, rows of
                // whole pairs.
                if (self.strides[1] % 2 != 0) return error.OddChromaStride;
            },
            .i420 => {
                try self.plane(1, cw, ch);
                try self.plane(2, cw, ch);
            },
            _ => return error.InvalidFormat,
        }
    }
    fn plane(self: YuvImage, index: usize, width: u32, rows: u32) YuvError!void {
        const stride = self.strides[index];
        if (stride < width or self.planes[index].len < @as(u64, stride) * (rows - 1) + width) return error.PlaneTooSmall;
    }

    /// The picture the renderers take: NV12's planes as they are, I420's
    /// chroma interleaved into `chroma`, which grows (with `allocator`) as
    /// needed; `old` is set to the buffer it replaced, for the caller to
    /// free once the renderers no longer read it. Panics on planes that
    /// cannot hold the picture (`check`).
    pub fn picture(self: YuvImage, allocator: std.mem.Allocator, chroma: *[]u8, old: *[]u8) !drawing.VideoPicture {
        self.check() catch |err| std.debug.panic("ui: a {d}×{d} {s} YuvImage: {s} (planes of {d}, {d} and {d} bytes in rows of {d}, {d} and {d})", .{
            self.width, self.height, if (@backingInt(self.format) <= 1) @tagName(self.format) else "unknown", @errorName(err),
            self.planes[0].len, self.planes[1].len, self.planes[2].len, self.strides[0], self.strides[1], self.strides[2],
        });
        old.* = &.{};
        var result: drawing.VideoPicture = .{ .width = self.width, .height = self.height, .format = .nv12, .matrix = self.videoMatrix(), .planes = .{ self.planes[0].ptr, null }, .strides = .{ self.strides[0], 0 } };
        switch (self.format) {
            .nv12 => {
                result.planes[1] = self.planes[1].ptr;
                result.strides[1] = self.strides[1];
            },
            .i420 => {
                const cw = self.chromaWidth();
                const ch = self.chromaHeight();
                const bytes = @as(usize, 2 * cw) * ch;
                if (chroma.len < bytes) {
                    const grown = try allocator.alloc(u8, bytes);
                    old.* = chroma.*;
                    chroma.* = grown;
                }
                const out = chroma.*[0..bytes];
                for (0..ch) |y| interleave(out[2 * cw * y ..][0 .. 2 * cw], self.planes[1][self.strides[1] * y ..][0..cw], self.planes[2][self.strides[2] * y ..][0..cw]);
                result.planes[1] = out.ptr;
                result.strides[1] = 2 * cw;
            },
            _ => unreachable,
        }
        return result;
    }
};

/// Writes `u` and `v` into `dst`, a byte of each in turn, as NV12's chroma
/// holds them.
pub fn interleave(dst: []u8, u: []const u8, v: []const u8) void {
    std.debug.assert(dst.len == 2 * u.len and u.len == v.len);
    var x: usize = 0;
    while (x + 8 <= u.len) : (x += 8) {
        const a: @Vector(8, u8) = u[x..][0..8].*;
        const b: @Vector(8, u8) = v[x..][0..8].*;
        dst[2 * x ..][0..16].* = @shuffle(u8, a, b, [16]i32{ 0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8 });
    }
    while (x < u.len) : (x += 1) {
        dst[2 * x] = u[x];
        dst[2 * x + 1] = v[x];
    }
}

test "interleaving Cb and Cr writes them in turn" {
    var u: [19]u8 = undefined;
    var v: [19]u8 = undefined;
    for (&u, &v, 0..) |*a, *b, i| {
        a.* = @intCast(i);
        b.* = @intCast(100 + i);
    }
    var out: [38]u8 = undefined;
    interleave(&out, &u, &v);
    for (0..19) |i| {
        try std.testing.expectEqual(u[i], out[2 * i]);
        try std.testing.expectEqual(v[i], out[2 * i + 1]);
    }
}
