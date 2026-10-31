//! PNG decoding for the images programs send (Kitty graphics, `f=100`):
//! every color type and bit depth, interlaced or not, to 8-bit RGBA with
//! straight alpha. Ancillary chunks are skipped but `tRNS`, which gives a
//! palette's alpha or the color that is transparent; checksums are not
//! checked.
const std = @import("std");
const zio = @import("ziggurat_io");

pub const Error = error{ InvalidPng, UnsupportedPng, TooLarge, OutOfMemory };

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA, row by row, owned by the caller.
    pixels: []u8,
};

/// Inflate zlib data, refusing more than `limit` bytes out.
pub fn inflate(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) error{ InvalidData, TooLarge, OutOfMemory }![]u8 {
    var in: std.Io.Reader = .fixed(bytes);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, window);
    return decompress.reader.allocRemaining(allocator, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        error.ReadFailed => error.InvalidData,
    };
}

/// Inflate zlib data to fill `out`; what follows is not read.
fn inflateInto(allocator: std.mem.Allocator, bytes: []const u8, out: []u8) Error!void {
    var in: std.Io.Reader = .fixed(bytes);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, window);
    decompress.reader.readSliceAll(out) catch return error.InvalidPng;
}

const signature = "\x89PNG\r\n\x1a\n";

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: u8,
    interlaced: bool,

    fn channels(self: Header) u8 {
        return switch (self.color) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => unreachable,
        };
    }
    fn bitsPerPixel(self: Header) usize {
        return @as(usize, self.channels()) * self.depth;
    }
    fn rowBytes(self: Header, width: u32) usize {
        return (@as(usize, width) * self.bitsPerPixel() + 7) / 8;
    }
};

/// Decode a PNG of at most `max_pixels` pixels.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, max_pixels: u64) Error!Image {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], signature)) return error.InvalidPng;
    var header: ?Header = null;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var palette_len: usize = 0;
    // The color key of gray and RGB images, at the image's depth.
    var key: ?[3]u16 = null;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    var at: usize = signature.len;
    while (true) {
        if (bytes.len - at < 12) return error.InvalidPng;
        const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        if (len > bytes.len - at - 12) return error.InvalidPng;
        const body = bytes[at + 8 ..][0..len];
        at += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13 or header != null) return error.InvalidPng;
            const h: Header = .{
                .width = std.mem.readInt(u32, body[0..4], .big),
                .height = std.mem.readInt(u32, body[4..8], .big),
                .depth = body[8],
                .color = body[9],
                .interlaced = body[12] == 1,
            };
            if (h.width == 0 or h.height == 0 or body[10] != 0 or body[11] != 0 or body[12] > 1) return error.InvalidPng;
            const depth_ok = switch (h.color) {
                0 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8 or h.depth == 16,
                3 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8,
                2, 4, 6 => h.depth == 8 or h.depth == 16,
                else => return error.UnsupportedPng,
            };
            if (!depth_ok) return error.UnsupportedPng;
            if (@as(u64, h.width) * h.height > max_pixels) return error.TooLarge;
            header = h;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len / 3 > 256) return error.InvalidPng;
            palette_len = len / 3;
            for (0..palette_len) |i| palette[i] = .{ body[3 * i], body[3 * i + 1], body[3 * i + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            const h = header orelse return error.InvalidPng;
            switch (h.color) {
                3 => for (body[0..@min(len, 256)], 0..) |alpha, i| {
                    palette[i][3] = alpha;
                },
                0 => if (len >= 2) {
                    const gray = std.mem.readInt(u16, body[0..2], .big);
                    key = .{ gray, gray, gray };
                },
                2 => if (len >= 6) {
                    key = .{ std.mem.readInt(u16, body[0..2], .big), std.mem.readInt(u16, body[2..4], .big), std.mem.readInt(u16, body[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try data.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        } else if (kind[0] & 0x20 == 0) {
            // An unknown chunk the image cannot do without.
            return error.UnsupportedPng;
        }
    }
    const h = header orelse return error.InvalidPng;
    if (h.color == 3 and palette_len == 0) return error.InvalidPng;

    // Each pass's rows, each with its filter byte.
    var expected: usize = 0;
    for (passes(h.interlaced)) |pass| {
        const size = pass.size(h.width, h.height);
        if (size.width == 0 or size.height == 0) continue;
        expected += size.height * (1 + h.rowBytes(size.width));
    }
    const raw = try allocator.alloc(u8, expected);
    defer allocator.free(raw);
    try inflateInto(allocator, data.items, raw);

    const pixels = try allocator.alloc(u8, @as(usize, h.width) * h.height * 4);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    const bpp = @max(1, h.bitsPerPixel() / 8);
    var offset: usize = 0;
    var previous: std.ArrayList(u8) = .empty;
    defer previous.deinit(allocator);
    for (passes(h.interlaced)) |pass| {
        const size = pass.size(h.width, h.height);
        if (size.width == 0 or size.height == 0) continue;
        const row_bytes = h.rowBytes(size.width);
        previous.clearRetainingCapacity();
        try previous.appendNTimes(allocator, 0, row_bytes);
        for (0..size.height) |y| {
            const filter = raw[offset];
            const line = raw[offset + 1 ..][0..row_bytes];
            offset += 1 + row_bytes;
            try unfilter(filter, line, previous.items, bpp);
            @memcpy(previous.items, line);
            for (0..size.width) |x| {
                const px = pass.x0 + x * pass.dx;
                const py = pass.y0 + y * pass.dy;
                const out = pixels[(py * h.width + px) * 4 ..][0..4];
                out.* = pixel(h, line, x, &palette, key);
            }
        }
    }
    return .{ .width = h.width, .height = h.height, .pixels = pixels };
}

const Pass = struct {
    x0: usize,
    y0: usize,
    dx: usize,
    dy: usize,

    fn size(self: Pass, width: u32, height: u32) struct { width: u32, height: u32 } {
        return .{
            .width = @intCast(if (width > self.x0) (width - self.x0 + self.dx - 1) / self.dx else 0),
            .height = @intCast(if (height > self.y0) (height - self.y0 + self.dy - 1) / self.dy else 0),
        };
    }
};

const adam7 = [_]Pass{
    .{ .x0 = 0, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 4, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 0, .y0 = 4, .dx = 4, .dy = 8 },
    .{ .x0 = 2, .y0 = 0, .dx = 4, .dy = 4 },
    .{ .x0 = 0, .y0 = 2, .dx = 2, .dy = 4 },
    .{ .x0 = 1, .y0 = 0, .dx = 2, .dy = 2 },
    .{ .x0 = 0, .y0 = 1, .dx = 1, .dy = 2 },
};
const whole = [_]Pass{.{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1 }};

fn passes(interlaced: bool) []const Pass {
    return if (interlaced) &adam7 else &whole;
}

fn unfilter(filter: u8, line: []u8, previous: []const u8, bpp: usize) Error!void {
    switch (filter) {
        0 => {},
        1 => for (bpp..line.len) |i| {
            line[i] +%= line[i - bpp];
        },
        2 => for (line, previous) |*b, up| {
            b.* +%= up;
        },
        3 => for (line, 0..) |*b, i| {
            const left: u16 = if (i >= bpp) line[i - bpp] else 0;
            b.* +%= @intCast((left + previous[i]) / 2);
        },
        4 => for (line, 0..) |*b, i| {
            const left: i16 = if (i >= bpp) line[i - bpp] else 0;
            const up: i16 = previous[i];
            const corner: i16 = if (i >= bpp) previous[i - bpp] else 0;
            const p = left + up - corner;
            const pa = @abs(p - left);
            const pb = @abs(p - up);
            const pc = @abs(p - corner);
            const predicted = if (pa <= pb and pa <= pc) left else if (pb <= pc) up else corner;
            b.* +%= @intCast(zio.asUnsigned(predicted));
        },
        else => return error.InvalidPng,
    }
}

/// Sample `index` of a row at the image's depth.
fn sample(h: Header, line: []const u8, index: usize) u16 {
    return switch (h.depth) {
        16 => std.mem.readInt(u16, line[index * 2 ..][0..2], .big),
        8 => line[index],
        else => {
            const bit = index * h.depth;
            const shift: u3 = @intCast(8 - h.depth - bit % 8);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(h.depth)) - 1);
            return (line[bit / 8] >> shift) & mask;
        },
    };
}

/// A sample scaled to 8 bits.
fn to8(h: Header, value: u16) u8 {
    return switch (h.depth) {
        16 => @intCast(value >> 8),
        8 => @intCast(value),
        else => @intCast(value * 255 / ((@as(u16, 1) << @intCast(h.depth)) - 1)),
    };
}

fn pixel(h: Header, line: []const u8, x: usize, palette: *const [256][4]u8, key: ?[3]u16) [4]u8 {
    switch (h.color) {
        3 => return palette[@min(sample(h, line, x), 255)],
        0 => {
            const g = sample(h, line, x);
            const v = to8(h, g);
            const alpha: u8 = if (key) |k| (if (k[0] == g) 0 else 255) else 255;
            return .{ v, v, v, alpha };
        },
        4 => {
            const v = to8(h, sample(h, line, 2 * x));
            return .{ v, v, v, to8(h, sample(h, line, 2 * x + 1)) };
        },
        2 => {
            const r = sample(h, line, 3 * x);
            const g = sample(h, line, 3 * x + 1);
            const b = sample(h, line, 3 * x + 2);
            const alpha: u8 = if (key) |k| (if (k[0] == r and k[1] == g and k[2] == b) 0 else 255) else 255;
            return .{ to8(h, r), to8(h, g), to8(h, b), alpha };
        },
        6 => return .{ to8(h, sample(h, line, 4 * x)), to8(h, sample(h, line, 4 * x + 1)), to8(h, sample(h, line, 4 * x + 2)), to8(h, sample(h, line, 4 * x + 3)) },
        else => unreachable,
    }
}

/// A PNG of `pixels`, RGBA, filtered with `filter` and stored without
/// compression, for tests.
pub fn encodeForTest(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u8, filter: u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    for (0..height) |y| {
        try raw.append(allocator, filter);
        const row = pixels[y * width * 4 ..][0 .. width * 4];
        for (row, 0..) |b, i| {
            const left: u8 = if (i >= 4) row[i - 4] else 0;
            const up: u8 = if (y > 0) pixels[(y - 1) * width * 4 + i] else 0;
            try raw.append(allocator, switch (filter) {
                1 => b -% left,
                2 => b -% up,
                3 => b -% @as(u8, @intCast((@as(u16, left) + up) / 2)),
                else => b,
            });
        }
    }
    // A zlib stream of stored blocks.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(allocator);
    try z.appendSlice(allocator, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 65535));
        try z.append(allocator, if (n == rest.len) 1 else 0);
        try z.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
        try z.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
        try z.appendSlice(allocator, rest[0..n]);
        rest = rest[n..];
        if (rest.len == 0) break;
    }
    try z.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(allocator, &out, "IHDR", &ihdr);
    try chunk(allocator, &out, "IDAT", z.items);
    try chunk(allocator, &out, "IEND", "");
    return out.toOwnedSlice(allocator);
}

fn chunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, body: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(body.len), .big);
    try out.appendSlice(allocator, &len);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, body);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(allocator, &sum);
}

test "decodes filtered RGBA" {
    const allocator = std.testing.allocator;
    var pixels: [3 * 2 * 4]u8 = undefined;
    for (&pixels, 0..) |*b, i| b.* = @intCast(i * 7 % 256);
    for (0..4) |filter| {
        const encoded = try encodeForTest(allocator, 3, 2, &pixels, @intCast(filter));
        defer allocator.free(encoded);
        const image = try decode(allocator, encoded, 100);
        defer allocator.free(image.pixels);
        try std.testing.expectEqual(@as(u32, 3), image.width);
        try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
    }
    const encoded = try encodeForTest(allocator, 3, 2, &pixels, 0);
    defer allocator.free(encoded);
    try std.testing.expectError(error.TooLarge, decode(allocator, encoded, 5));
    try std.testing.expectError(error.InvalidPng, decode(allocator, encoded[0 .. encoded.len - 20], 100));
}

test "decodes the bits of small depths, palettes and paeth" {
    // Gray at 2 bits: 0, 1, 2, 3 make 0, 85, 170, 255.
    const h: Header = .{ .width = 4, .height = 1, .depth = 2, .color = 0, .interlaced = false };
    const line = [_]u8{0b00011011};
    try std.testing.expectEqual([4]u8{ 85, 85, 85, 255 }, pixel(h, &line, 1, &@splat(.{ 0, 0, 0, 255 }), null));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 0 }, pixel(h, &line, 3, &@splat(.{ 0, 0, 0, 255 }), .{ 3, 3, 3 }));
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    palette[2] = .{ 9, 8, 7, 6 };
    const p: Header = .{ .width = 4, .height = 1, .depth = 2, .color = 3, .interlaced = false };
    try std.testing.expectEqual([4]u8{ 9, 8, 7, 6 }, pixel(p, &line, 2, &palette, null));
    var row = [_]u8{ 10, 20, 30 };
    try unfilter(4, &row, &.{ 1, 2, 3 }, 1);
    // Paeth: the first byte's prediction is the byte above.
    try std.testing.expectEqual(@as(u8, 11), row[0]);
}

test "Adam7 passes cover each pixel once" {
    var seen: [5][7]u8 = @splat(@splat(0));
    for (adam7) |pass| {
        const size = pass.size(7, 5);
        for (0..size.height) |y| for (0..size.width) |x| {
            seen[pass.y0 + y * pass.dy][pass.x0 + x * pass.dx] += 1;
        };
    }
    for (seen) |r| for (r) |count| try std.testing.expectEqual(@as(u8, 1), count);
}

test "decodes compressed RGB with paeth" {
    const allocator = std.testing.allocator;
    const encoded = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x05\x00\x00\x00\x04\x08\x02\x00\x00\x00\xc9\x51\x62\x17\x00\x00\x00\x1f\x49\x44\x41\x54\x78\xda\x63\x61\x60\x60\x30\x42\x42\x2c\x0c\x36\x40\x11\x11\x38\x82\xf3\x35\x20\x08\x99\x0f\x64\xd9\x00\x00\x5d\x60\x03\x1d\x2f\x13\x4e\x1e\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
    const image = try decode(allocator, encoded, 100);
    defer allocator.free(image.pixels);
    var want: [5 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..5) |x| {
        want[(y * 5 + x) * 4 ..][0..4].* = .{ @intCast(x * 50 % 256), @intCast(y * 60 % 256), @intCast(x * y * 20 % 256), 255 };
    };
    try std.testing.expectEqualSlices(u8, &want, image.pixels);
}
