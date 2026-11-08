//! Animated PNG decoding: each frame drawn over what the ones before it
//! left, as its disposal (none, background, previous) and blending
//! (source, over) say, into one picture of premultiplied BGRA. Every frame
//! stays compressed, as a PNG of its own, and decodes only as it plays. A
//! PNG that is not animated is an animation of one frame.
//!
//! Frames show as browsers show them: a frame of 10 ms or less shows for
//! 100 ms. The count of plays the PNG gives is not kept: whoever plays it
//! says whether it plays again.
const std = @import("std");
const png = @import("ziggurat_png");

pub const Error = error{ NotPng, Truncated, BadHeader, BadFrameControl, FrameOutOfPicture, EmptyFrame, NoImage, TooLarge, OutOfMemory };

/// How long a frame of 10 ms or less shows, and the one frame of a PNG
/// that is not animated, in nanoseconds.
pub const default_frame: u64 = 100 * std.time.ns_per_ms;
/// Pixels a picture may have at most.
pub const max_pixels: u64 = 1 << 27;

const signature = "\x89PNG\r\n\x1a\n";

/// What a frame leaves for the next one: itself, its rectangle cleared to
/// transparent, or the picture as it was before it drew. Values the
/// format does not know count as `none`.
pub const Dispose = enum { none, background, previous };
/// How a frame draws: replacing its rectangle, or over what is there.
pub const Blend = enum { source, over };

pub const Frame = struct {
    /// A PNG of the frame alone, owned by the animation.
    png: []u8,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    /// How long it shows, in nanoseconds.
    delay: u64,
    dispose: Dispose,
    blend: Blend,
};

pub const Animation = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    frames: []Frame,
    /// The frame `next` draws.
    index: usize = 0,
    /// The picture so far: premultiplied BGRA rows from the top.
    canvas: []u8,
    /// The picture before the last frame that disposes to the previous
    /// one drew, else empty.
    saved: []u8 = &.{},

    /// Read the frames of `bytes`, which need not outlive the animation.
    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) Error!Animation {
        if (!std.mem.startsWith(u8, bytes, signature)) return error.NotPng;
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(allocator);
        errdefer for (frames.items) |frame| allocator.free(frame.png);
        // PLTE and tRNS, as each frame's PNG needs them.
        var extra: std.ArrayList(u8) = .empty;
        defer extra.deinit(allocator);
        // The compressed pixels of the frame being read.
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        var ihdr: ?*const [13]u8 = null;
        var current: ?Frame = null;
        var animated = false;
        var saw_idat = false;
        var width: u32 = 0;
        var height: u32 = 0;

        var rest = bytes[signature.len..];
        while (rest.len >= 12) {
            const n = std.mem.readInt(u32, rest[0..4], .big);
            if (@as(u64, n) + 12 > rest.len) return error.Truncated;
            const kind = rest[4..8];
            const chunk = rest[8..][0..n];
            const raw = rest[0 .. 12 + n];
            rest = rest[12 + n ..];
            if (std.mem.eql(u8, kind, "IHDR")) {
                if (n != 13) return error.BadHeader;
                ihdr = chunk[0..13];
                width = std.mem.readInt(u32, chunk[0..4], .big);
                height = std.mem.readInt(u32, chunk[4..8], .big);
                if (@as(u64, width) * height > max_pixels) return error.TooLarge;
            } else if (std.mem.eql(u8, kind, "PLTE") or std.mem.eql(u8, kind, "tRNS")) {
                try extra.appendSlice(allocator, raw);
            } else if (std.mem.eql(u8, kind, "acTL")) {
                animated = true;
            } else if (std.mem.eql(u8, kind, "fcTL")) {
                const header = ihdr orelse return error.BadFrameControl;
                if (n != 26) return error.BadFrameControl;
                try finish(allocator, &frames, &current, &body, header, extra.items);
                const fw = std.mem.readInt(u32, chunk[4..8], .big);
                const fh = std.mem.readInt(u32, chunk[8..12], .big);
                const fx = std.mem.readInt(u32, chunk[12..16], .big);
                const fy = std.mem.readInt(u32, chunk[16..20], .big);
                if (fw == 0 or fh == 0 or @as(u64, fx) + fw > width or @as(u64, fy) + fh > height) return error.FrameOutOfPicture;
                const num = std.mem.readInt(u16, chunk[20..22], .big);
                var den = std.mem.readInt(u16, chunk[22..24], .big);
                if (den == 0) den = 100;
                var delay = @as(u64, num) * std.time.ns_per_s / den;
                if (delay <= 10 * std.time.ns_per_ms) delay = default_frame;
                var disposal: Dispose = switch (chunk[24]) {
                    1 => .background,
                    2 => .previous,
                    else => .none,
                };
                // Nothing came before the first frame to go back to.
                if (frames.items.len == 0 and disposal == .previous) disposal = .background;
                current = .{ .png = &.{}, .x = fx, .y = fy, .width = fw, .height = fh, .delay = delay, .dispose = disposal, .blend = if (chunk[25] == 1) .over else .source };
            } else if (std.mem.eql(u8, kind, "IDAT")) {
                // The default image is the first frame when a frame
                // control comes before it; else, in an animated PNG, it is
                // not a frame.
                saw_idat = true;
                if (current != null or !animated) try body.appendSlice(allocator, chunk);
            } else if (std.mem.eql(u8, kind, "fdAT")) {
                if (current != null and n >= 4) try body.appendSlice(allocator, chunk[4..]);
            } else if (std.mem.eql(u8, kind, "IEND")) {
                break;
            }
        }
        const header = ihdr orelse return error.NoImage;
        if (!saw_idat) return error.NoImage;
        try finish(allocator, &frames, &current, &body, header, extra.items);
        if (frames.items.len == 0) {
            if (body.items.len == 0) return error.NoImage;
            const whole = try framePng(allocator, header, extra.items, width, height, body.items);
            frames.append(allocator, .{ .png = whole, .x = 0, .y = 0, .width = width, .height = height, .delay = default_frame, .dispose = .none, .blend = .source }) catch |err| {
                allocator.free(whole);
                return err;
            };
        }
        const canvas = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(canvas);
        @memset(canvas, 0);
        const owned = try frames.toOwnedSlice(allocator);
        return .{ .allocator = allocator, .width = width, .height = height, .frames = owned, .canvas = canvas };
    }

    pub fn deinit(self: *Animation) void {
        for (self.frames) |frame| self.allocator.free(frame.png);
        self.allocator.free(self.frames);
        self.allocator.free(self.canvas);
        if (self.saved.len != 0) self.allocator.free(self.saved);
        self.* = undefined;
    }

    /// Draw the next frame onto `canvas` and return how long it shows, in
    /// nanoseconds, or null after the last.
    pub fn next(self: *Animation) !?u64 {
        const i = self.index;
        if (i >= self.frames.len) return null;
        const frame = self.frames[i];
        const image = try png.decode(self.allocator, frame.png, @as(u64, frame.width) * frame.height);
        defer self.allocator.free(image.pixels);
        if (image.width != frame.width or image.height != frame.height) return error.InvalidPng;
        if (i > 0) self.dispose(self.frames[i - 1]);
        if (frame.dispose == .previous) {
            if (self.saved.len == 0) self.saved = try self.allocator.alloc(u8, self.canvas.len);
            @memcpy(self.saved, self.canvas);
        }
        self.draw(frame, image.pixels);
        self.index += 1;
        return frame.delay;
    }

    /// Go back to before the first frame, with the picture transparent.
    pub fn rewind(self: *Animation) void {
        self.index = 0;
        @memset(self.canvas, 0);
    }

    /// The length of the animation, in nanoseconds.
    pub fn duration(self: *const Animation) u64 {
        var total: u64 = 0;
        for (self.frames) |frame| total += frame.delay;
        return total;
    }

    /// Undo `frame` as its disposal says, before the next draws: clear its
    /// rectangle to transparent, put back what was under it, or leave it.
    fn dispose(self: *Animation, frame: Frame) void {
        switch (frame.dispose) {
            .none => {},
            .background => for (frame.y..frame.y + frame.height) |y| {
                @memset(self.canvas[(y * self.width + frame.x) * 4 ..][0 .. frame.width * 4], 0);
            },
            .previous => if (self.saved.len != 0) @memcpy(self.canvas, self.saved),
        }
    }

    /// Draw the straight RGBA `pixels` of `frame` into its rectangle.
    fn draw(self: *Animation, frame: Frame, pixels: []const u8) void {
        for (0..frame.height) |row| {
            const line = pixels[row * frame.width * 4 ..][0 .. frame.width * 4];
            const out = self.canvas[((frame.y + row) * self.width + frame.x) * 4 ..][0 .. frame.width * 4];
            var at: usize = 0;
            while (at < line.len) : (at += 4) {
                const a: u32 = line[at + 3];
                const source = [4]u8{ premultiply(line[at + 2], a), premultiply(line[at + 1], a), premultiply(line[at], a), @intCast(a) };
                const target = out[at..][0..4];
                switch (frame.blend) {
                    .source => target.* = source,
                    .over => {
                        const keep = 255 - a;
                        for (target, source) |*d, s| d.* = @intCast(s + (@as(u32, d.*) * keep + 127) / 255);
                    },
                }
            }
        }
    }
};

fn premultiply(channel: u8, alpha: u32) u8 {
    return @intCast((@as(u32, channel) * alpha + 127) / 255);
}

/// Move the frame being read, if any, to `frames`, as a PNG of its own.
fn finish(allocator: std.mem.Allocator, frames: *std.ArrayList(Frame), current: *?Frame, body: *std.ArrayList(u8), ihdr: *const [13]u8, extra: []const u8) Error!void {
    var frame = current.* orelse return;
    if (body.items.len == 0) return error.EmptyFrame;
    frame.png = try framePng(allocator, ihdr, extra, frame.width, frame.height, body.items);
    frames.append(allocator, frame) catch |err| {
        allocator.free(frame.png);
        return err;
    };
    current.* = null;
    body.clearRetainingCapacity();
}

/// A PNG of a frame alone: the animated PNG's header at the frame's size,
/// its palette and transparency, and the frame's pixels.
fn framePng(allocator: std.mem.Allocator, ihdr: *const [13]u8, extra: []const u8, width: u32, height: u32, body: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, signature.len + 25 + extra.len + 12 + body.len + 12);
    out.appendSliceAssumeCapacity(signature);
    var header = ihdr.*;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    writeChunk(&out, "IHDR", &header);
    out.appendSliceAssumeCapacity(extra);
    writeChunk(&out, "IDAT", body);
    writeChunk(&out, "IEND", "");
    return out.toOwnedSlice(allocator);
}

fn writeChunk(out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(data.len), .big);
    out.appendSliceAssumeCapacity(&n);
    out.appendSliceAssumeCapacity(kind);
    out.appendSliceAssumeCapacity(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    std.mem.writeInt(u32, &n, crc.final(), .big);
    out.appendSliceAssumeCapacity(&n);
}

// Tests build animated PNGs from frames of solid colors.

const testing = std.testing;

const Spec = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
    /// RGBA of every pixel.
    color: [4]u8,
    num: u16 = 1,
    den: u16 = 10,
    dispose: u8 = 0,
    blend: u8 = 0,
};

/// The zlib stream of a PNG of `spec`'s size and color.
fn pixelsOf(spec: Spec) ![]u8 {
    const pixels = try testing.allocator.alloc(u8, spec.width * spec.height * 4);
    defer testing.allocator.free(pixels);
    for (0..spec.width * spec.height) |i| pixels[i * 4 ..][0..4].* = spec.color;
    const whole = try png.encodeForTest(testing.allocator, spec.width, spec.height, pixels, 1);
    defer testing.allocator.free(whole);
    // The IDAT follows the signature and the IHDR chunk.
    const at = signature.len + 25;
    const n = std.mem.readInt(u32, whole[at..][0..4], .big);
    return testing.allocator.dupe(u8, whole[at + 8 ..][0..n]);
}

fn appendChunk(out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    try out.ensureUnusedCapacity(testing.allocator, data.len + 12);
    writeChunk(out, kind, data);
}

/// An APNG of `width` by `height` with `frames`; with `default_first`
/// the default image (IDAT) is the first frame, else a still image of
/// `still` that is not one.
fn build(width: u32, height: u32, frames: []const Spec, default_first: bool, still: ?Spec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try appendChunk(&out, "IHDR", &ihdr);
    if (frames.len != 0) {
        var actl: [8]u8 = undefined;
        std.mem.writeInt(u32, actl[0..4], @intCast(frames.len), .big);
        std.mem.writeInt(u32, actl[4..8], 0, .big);
        try appendChunk(&out, "acTL", &actl);
    }
    if (still) |spec| {
        const data = try pixelsOf(spec);
        defer testing.allocator.free(data);
        try appendChunk(&out, "IDAT", data);
    }
    var sequence: u32 = 0;
    for (frames, 0..) |spec, i| {
        var fctl: [26]u8 = undefined;
        std.mem.writeInt(u32, fctl[0..4], sequence, .big);
        sequence += 1;
        std.mem.writeInt(u32, fctl[4..8], spec.width, .big);
        std.mem.writeInt(u32, fctl[8..12], spec.height, .big);
        std.mem.writeInt(u32, fctl[12..16], spec.x, .big);
        std.mem.writeInt(u32, fctl[16..20], spec.y, .big);
        std.mem.writeInt(u16, fctl[20..22], spec.num, .big);
        std.mem.writeInt(u16, fctl[22..24], spec.den, .big);
        fctl[24] = spec.dispose;
        fctl[25] = spec.blend;
        try appendChunk(&out, "fcTL", &fctl);
        const data = try pixelsOf(spec);
        defer testing.allocator.free(data);
        if (i == 0 and default_first) {
            try appendChunk(&out, "IDAT", data);
        } else {
            const fdat = try testing.allocator.alloc(u8, data.len + 4);
            defer testing.allocator.free(fdat);
            std.mem.writeInt(u32, fdat[0..4], sequence, .big);
            sequence += 1;
            @memcpy(fdat[4..], data);
            try appendChunk(&out, "fdAT", fdat);
        }
    }
    try appendChunk(&out, "IEND", "");
    return out.toOwnedSlice(testing.allocator);
}

/// The premultiplied BGRA of the canvas at `x`, `y`.
fn pixelAt(animation: *const Animation, x: u32, y: u32) [4]u8 {
    return animation.canvas[(y * animation.width + x) * 4 ..][0..4].*;
}

const red = [4]u8{ 255, 0, 0, 255 };
const green = [4]u8{ 0, 255, 0, 255 };
const blue = [4]u8{ 0, 0, 255, 255 };
const bgra_red = [4]u8{ 0, 0, 255, 255 };
const bgra_green = [4]u8{ 0, 255, 0, 255 };
const bgra_blue = [4]u8{ 255, 0, 0, 255 };
const clear = [4]u8{ 0, 0, 0, 0 };

test "a PNG that is not animated is an animation of one frame" {
    const bytes = try build(3, 2, &.{}, false, .{ .width = 3, .height = 2, .color = red });
    defer testing.allocator.free(bytes);
    var animation = try Animation.init(testing.allocator, bytes);
    defer animation.deinit();
    try testing.expectEqual(@as(usize, 1), animation.frames.len);
    try testing.expectEqual(default_frame, animation.duration());
    try testing.expectEqual(@as(?u64, default_frame), try animation.next());
    try testing.expectEqual(bgra_red, pixelAt(&animation, 2, 1));
    try testing.expectEqual(@as(?u64, null), try animation.next());
}

test "frames draw at their offsets, replacing or over what is there, and keep what they leave" {
    const frames = [_]Spec{
        .{ .width = 4, .height = 4, .color = red },
        // Source replaces even with transparency.
        .{ .x = 1, .y = 1, .width = 2, .height = 1, .color = .{ 0, 0, 0, 0 } },
        // Over leaves what shows under transparency, and covers with an
        // opaque color.
        .{ .x = 0, .y = 2, .width = 2, .height = 2, .color = .{ 0, 0, 0, 0 }, .blend = 1 },
        .{ .x = 3, .y = 3, .width = 1, .height = 1, .color = blue, .blend = 1 },
    };
    const bytes = try build(4, 4, &frames, true, null);
    defer testing.allocator.free(bytes);
    var animation = try Animation.init(testing.allocator, bytes);
    defer animation.deinit();
    for (0..frames.len) |_| _ = (try animation.next()).?;
    try testing.expectEqual(bgra_red, pixelAt(&animation, 0, 0));
    try testing.expectEqual(clear, pixelAt(&animation, 1, 1));
    try testing.expectEqual(clear, pixelAt(&animation, 2, 1));
    try testing.expectEqual(bgra_red, pixelAt(&animation, 3, 1));
    try testing.expectEqual(bgra_red, pixelAt(&animation, 0, 3));
    try testing.expectEqual(bgra_blue, pixelAt(&animation, 3, 3));
}

test "a translucent frame blends over the picture in premultiplied color" {
    const frames = [_]Spec{
        .{ .width = 1, .height = 1, .color = red },
        .{ .width = 1, .height = 1, .color = .{ 0, 0, 255, 128 }, .blend = 1 },
    };
    const bytes = try build(1, 1, &frames, true, null);
    defer testing.allocator.free(bytes);
    var animation = try Animation.init(testing.allocator, bytes);
    defer animation.deinit();
    _ = try animation.next();
    _ = try animation.next();
    // Blue at 128 over opaque red: 128 of blue, 127 of red, opaque.
    try testing.expectEqual([4]u8{ 128, 0, 127, 255 }, pixelAt(&animation, 0, 0));
}

test "a frame that disposes to the background clears its rectangle before the next" {
    const frames = [_]Spec{
        .{ .width = 3, .height = 1, .color = red },
        .{ .x = 1, .width = 1, .height = 1, .color = green, .dispose = 1 },
        .{ .x = 2, .width = 1, .height = 1, .color = blue },
    };
    const bytes = try build(3, 1, &frames, true, null);
    defer testing.allocator.free(bytes);
    var animation = try Animation.init(testing.allocator, bytes);
    defer animation.deinit();
    _ = try animation.next();
    _ = try animation.next();
    try testing.expectEqual(bgra_green, pixelAt(&animation, 1, 0));
    _ = try animation.next();
    try testing.expectEqual(bgra_red, pixelAt(&animation, 0, 0));
    try testing.expectEqual(clear, pixelAt(&animation, 1, 0));
    try testing.expectEqual(bgra_blue, pixelAt(&animation, 2, 0));
}

test "a frame that disposes to the previous picture puts back what was under it" {
    const frames = [_]Spec{
        // The first frame has nothing before it: it clears instead.
        .{ .width = 2, .height = 1, .color = red, .dispose = 2 },
        .{ .width = 1, .height = 1, .color = green },
        .{ .x = 1, .width = 1, .height = 1, .color = blue, .dispose = 2 },
        .{ .width = 1, .height = 1, .color = .{ 0, 0, 0, 0 }, .blend = 1 },
    };
    const bytes = try build(2, 1, &frames, true, null);
    defer testing.allocator.free(bytes);
    var animation = try Animation.init(testing.allocator, bytes);
    defer animation.deinit();
    try testing.expectEqual(Dispose.background, animation.frames[0].dispose);
    _ = try animation.next();
    _ = try animation.next();
    try testing.expectEqual(bgra_green, pixelAt(&animation, 0, 0));
    try testing.expectEqual(clear, pixelAt(&animation, 1, 0));
    _ = try animation.next();
    try testing.expectEqual(bgra_blue, pixelAt(&animation, 1, 0));
    _ = try animation.next();
    try testing.expectEqual(bgra_green, pixelAt(&animation, 0, 0));
    try testing.expectEqual(clear, pixelAt(&animation, 1, 0));

    // Played again from a transparent picture.
    animation.rewind();
    _ = try animation.next();
    try testing.expectEqual(bgra_red, pixelAt(&animation, 1, 0));
}

test "delays: a fraction of a second, a hundredth by default, and at least past 10 ms" {
    const frames = [_]Spec{
        .{ .width = 1, .height = 1, .color = red, .num = 1, .den = 4 },
        .{ .width = 1, .height = 1, .color = red, .num = 3, .den = 0 },
        .{ .width = 1, .height = 1, .color = red, .num = 1, .den = 100 },
        .{ .width = 1, .height = 1, .color = red, .num = 0, .den = 1 },
    };
    const bytes = try build(1, 1, &frames, true, null);
    defer testing.allocator.free(bytes);
    var animation = try Animation.init(testing.allocator, bytes);
    defer animation.deinit();
    const expected = [_]u64{ 250 * std.time.ns_per_ms, 30 * std.time.ns_per_ms, default_frame, default_frame };
    for (expected) |delay| try testing.expectEqual(@as(?u64, delay), try animation.next());
    try testing.expectEqual(@as(u64, 480 * std.time.ns_per_ms), animation.duration());
}

test "a default image before the first frame control is not a frame" {
    const frames = [_]Spec{.{ .width = 2, .height = 2, .color = green }};
    const bytes = try build(2, 2, &frames, false, .{ .width = 2, .height = 2, .color = red });
    defer testing.allocator.free(bytes);
    var animation = try Animation.init(testing.allocator, bytes);
    defer animation.deinit();
    try testing.expectEqual(@as(usize, 1), animation.frames.len);
    _ = try animation.next();
    try testing.expectEqual(bgra_green, pixelAt(&animation, 1, 1));
}

test "what is not an animated PNG it can play is refused" {
    try testing.expectError(error.NotPng, Animation.init(testing.allocator, "GIF89a"));
    const good = try build(2, 2, &.{.{ .width = 2, .height = 2, .color = red }}, true, null);
    defer testing.allocator.free(good);
    try testing.expectError(error.Truncated, Animation.init(testing.allocator, good[0 .. signature.len + 20]));
    const outside = try build(2, 2, &.{.{ .x = 1, .width = 2, .height = 2, .color = red }}, true, null);
    defer testing.allocator.free(outside);
    try testing.expectError(error.FrameOutOfPicture, Animation.init(testing.allocator, outside));
    // Only a header: no image.
    try testing.expectError(error.NoImage, Animation.init(testing.allocator, good[0 .. signature.len + 25]));
}
