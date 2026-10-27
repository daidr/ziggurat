//! PNG reading and writing for the build tools: any standard PNG decodes to
//! 8-bit RGBA, not premultiplied; images encode as 8-bit RGBA with adaptive
//! row filters and a small deflate encoder (fixed Huffman codes over LZ77
//! matches). Only what icons and packaging need; the runtime decodes images
//! through the platform.
const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes, rows top to bottom, RGBA.
    pixels: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
        const pixels = try allocator.alloc(u8, try pixelBytes(width, height));
        @memset(pixels, 0);
        return .{ .width = width, .height = height, .pixels = pixels };
    }
    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
    pub fn at(self: Image, x: u32, y: u32) [4]u8 {
        const i = (@as(usize, y) * self.width + x) * 4;
        return self.pixels[i..][0..4].*;
    }
};

const signature = "\x89PNG\r\n\x1a\n";
/// Larger images are refused: icons and menu art never come close.
pub const max_dimension: u32 = 16384;
const max_pixels: u64 = 64 * 1024 * 1024;

fn pixelBytes(width: u32, height: u32) !usize {
    if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidDimensions;
    if (@as(u64, width) * height > max_pixels) return error.InvalidDimensions;
    return @as(usize, width) * height * 4;
}

pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    interlaced: bool,
};

/// The header alone, without decoding the image.
pub fn readHeader(bytes: []const u8) !Header {
    if (bytes.len < signature.len + 25 or !std.mem.eql(u8, bytes[0..signature.len], signature)) return error.NotPng;
    const ihdr = bytes[signature.len..];
    if (std.mem.readInt(u32, ihdr[0..4], .big) != 13 or !std.mem.eql(u8, ihdr[4..8], "IHDR")) return error.InvalidPng;
    const data = ihdr[8..21];
    const header: Header = .{
        .width = std.mem.readInt(u32, data[0..4], .big),
        .height = std.mem.readInt(u32, data[4..8], .big),
        .bit_depth = data[8],
        .color_type = data[9],
        .interlaced = data[12] == 1,
    };
    if (data[10] != 0 or data[11] != 0 or data[12] > 1) return error.InvalidPng;
    const valid_depth = switch (header.color_type) {
        0 => header.bit_depth == 1 or header.bit_depth == 2 or header.bit_depth == 4 or header.bit_depth == 8 or header.bit_depth == 16,
        3 => header.bit_depth == 1 or header.bit_depth == 2 or header.bit_depth == 4 or header.bit_depth == 8,
        2, 4, 6 => header.bit_depth == 8 or header.bit_depth == 16,
        else => false,
    };
    if (!valid_depth) return error.InvalidPng;
    _ = try pixelBytes(header.width, header.height);
    return header;
}

fn channels(color_type: u8) u8 {
    return switch (color_type) {
        0, 3 => 1,
        4 => 2,
        2 => 3,
        6 => 4,
        else => unreachable,
    };
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    const header = try readHeader(bytes);
    var palette: [256][4]u8 = undefined;
    var palette_len: usize = 0;
    var transparent: ?[3]u16 = null;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    var rest = bytes[signature.len..];
    var ended = false;
    while (!ended) {
        if (rest.len < 12) return error.InvalidPng;
        const length = std.mem.readInt(u32, rest[0..4], .big);
        if (length > rest.len - 12) return error.InvalidPng;
        const kind = rest[4..8];
        const data = rest[8..][0..length];
        if (std.hash.Crc32.hash(rest[4 .. 8 + length]) != std.mem.readInt(u32, rest[8 + length ..][0..4], .big)) return error.ChecksumMismatch;
        rest = rest[12 + length ..];
        if (std.mem.eql(u8, kind, "PLTE")) {
            if (length % 3 != 0 or length / 3 > 256 or length == 0) return error.InvalidPng;
            palette_len = length / 3;
            for (0..palette_len) |i| palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (header.color_type) {
                3 => {
                    if (length > palette_len) return error.InvalidPng;
                    for (data, 0..) |alpha, i| palette[i][3] = alpha;
                },
                0 => {
                    if (length != 2) return error.InvalidPng;
                    const g = std.mem.readInt(u16, data[0..2], .big);
                    transparent = .{ g, g, g };
                },
                2 => {
                    if (length != 6) return error.InvalidPng;
                    transparent = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
                },
                else => return error.InvalidPng,
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try compressed.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            ended = true;
        } else if (kind[0] & 0x20 == 0 and !std.mem.eql(u8, kind, "IHDR")) {
            return error.UnsupportedPng; // an unknown critical chunk
        }
    }
    if (header.color_type == 3 and palette_len == 0) return error.InvalidPng;

    const per_pixel = channels(header.color_type);
    const bits_per_pixel = @as(usize, per_pixel) * header.bit_depth;
    const filter_bpp = @max(1, bits_per_pixel / 8);
    // The size of the filtered data, pass by pass.
    var expected: usize = 0;
    var pass: usize = 0;
    while (pass < passCount(header)) : (pass += 1) {
        const size = passSize(header, pass);
        if (size[0] == 0 or size[1] == 0) continue;
        expected += (1 + (size[0] * bits_per_pixel + 7) / 8) * size[1];
    }
    const raw = try allocator.alloc(u8, expected);
    defer allocator.free(raw);
    {
        var input: std.Io.Reader = .fixed(compressed.items);
        // Without a buffer of its own the decompressor writes straight into
        // the output, which holds the history matches refer to; its
        // buffered path cannot move a full window in Zig 0.15.2.
        var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
        var output: std.Io.Writer = .fixed(raw);
        inflate.reader.streamExact(&output, raw.len) catch return error.InvalidPng;
    }

    var image: Image = try .init(allocator, header.width, header.height);
    errdefer image.deinit(allocator);
    var offset: usize = 0;
    pass = 0;
    while (pass < passCount(header)) : (pass += 1) {
        const size = passSize(header, pass);
        if (size[0] == 0 or size[1] == 0) continue;
        const stride = (size[0] * bits_per_pixel + 7) / 8;
        var previous: []u8 = &.{};
        for (0..size[1]) |row| {
            const filter = raw[offset];
            const line = raw[offset + 1 ..][0..stride];
            offset += 1 + stride;
            try unfilter(filter, line, previous, filter_bpp);
            previous = line;
            for (0..size[0]) |column| {
                const x, const y = if (header.interlaced) adam7(pass, column, row) else .{ column, row };
                image.pixels[(y * header.width + x) * 4 ..][0..4].* = try pixel(header, line, column, &palette, palette_len, transparent);
            }
        }
    }
    return image;
}

fn passCount(header: Header) usize {
    return if (header.interlaced) 7 else 1;
}

const adam7_start = [7][2]usize{ .{ 0, 0 }, .{ 4, 0 }, .{ 0, 4 }, .{ 2, 0 }, .{ 0, 2 }, .{ 1, 0 }, .{ 0, 1 } };
const adam7_step = [7][2]usize{ .{ 8, 8 }, .{ 8, 8 }, .{ 4, 8 }, .{ 4, 4 }, .{ 2, 4 }, .{ 2, 2 }, .{ 1, 2 } };

fn passSize(header: Header, pass: usize) [2]usize {
    if (!header.interlaced) return .{ header.width, header.height };
    const start = adam7_start[pass];
    const step = adam7_step[pass];
    const w = if (header.width > start[0]) (header.width - start[0] + step[0] - 1) / step[0] else 0;
    const h = if (header.height > start[1]) (header.height - start[1] + step[1] - 1) / step[1] else 0;
    return .{ w, h };
}

fn adam7(pass: usize, column: usize, row: usize) [2]usize {
    return .{ adam7_start[pass][0] + column * adam7_step[pass][0], adam7_start[pass][1] + row * adam7_step[pass][1] };
}

fn unfilter(filter: u8, line: []u8, previous: []const u8, bpp: usize) !void {
    for (line, 0..) |*byte, i| {
        const a: u8 = if (i >= bpp) line[i - bpp] else 0;
        const b: u8 = if (previous.len > 0) previous[i] else 0;
        const c: u8 = if (previous.len > 0 and i >= bpp) previous[i - bpp] else 0;
        byte.* +%= switch (filter) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @intCast((@as(u16, a) + b) / 2),
            4 => paeth(a, b, c),
            else => return error.InvalidPng,
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn sample(header: Header, line: []const u8, index: usize) u16 {
    return switch (header.bit_depth) {
        16 => std.mem.readInt(u16, line[index * 2 ..][0..2], .big),
        8 => line[index],
        else => blk: {
            const depth: u3 = @intCast(header.bit_depth);
            const per_byte = 8 / @as(usize, depth);
            const byte = line[index / per_byte];
            const shift: u3 = @intCast(8 - @as(usize, depth) * (index % per_byte + 1));
            break :blk (byte >> shift) & ((@as(u8, 1) << depth) - 1);
        },
    };
}

fn to8(header: Header, value: u16) u8 {
    return switch (header.bit_depth) {
        16 => @intCast(value >> 8),
        8 => @intCast(value),
        else => @intCast(value * 255 / ((@as(u16, 1) << @intCast(header.bit_depth)) - 1)),
    };
}

fn pixel(header: Header, line: []const u8, column: usize, palette: *const [256][4]u8, palette_len: usize, transparent: ?[3]u16) ![4]u8 {
    const n = channels(header.color_type);
    const base = column * n;
    switch (header.color_type) {
        3 => {
            const index = sample(header, line, base);
            if (index >= palette_len) return error.InvalidPng;
            return palette[index];
        },
        0 => {
            const g = sample(header, line, base);
            const alpha: u8 = if (transparent) |key| (if (key[0] == g) 0 else 255) else 255;
            const v = to8(header, g);
            return .{ v, v, v, alpha };
        },
        4 => {
            const v = to8(header, sample(header, line, base));
            return .{ v, v, v, to8(header, sample(header, line, base + 1)) };
        },
        2 => {
            const r = sample(header, line, base);
            const g = sample(header, line, base + 1);
            const b = sample(header, line, base + 2);
            const alpha: u8 = if (transparent) |key| (if (key[0] == r and key[1] == g and key[2] == b) 0 else 255) else 255;
            return .{ to8(header, r), to8(header, g), to8(header, b), alpha };
        },
        6 => return .{ to8(header, sample(header, line, base)), to8(header, sample(header, line, base + 1)), to8(header, sample(header, line, base + 2)), to8(header, sample(header, line, base + 3)) },
        else => unreachable,
    }
}

// ---------------------------------------------------------------- encode

/// Encode RGBA pixels as an 8-bit RGBA PNG. Equal inputs give equal bytes.
pub fn encode(allocator: std.mem.Allocator, image: Image) ![]u8 {
    const stride = @as(usize, image.width) * 4;
    if (image.pixels.len != try pixelBytes(image.width, image.height)) return error.InvalidDimensions;
    const filtered = try allocator.alloc(u8, (stride + 1) * image.height);
    defer allocator.free(filtered);
    const candidate = try allocator.alloc(u8, stride * 5);
    defer allocator.free(candidate);
    for (0..image.height) |y| {
        const line = image.pixels[y * stride ..][0..stride];
        const previous: []const u8 = if (y > 0) image.pixels[(y - 1) * stride ..][0..stride] else &.{};
        // Choose the filter whose output has the smallest sum of absolute
        // differences, the usual heuristic.
        var best: u8 = 0;
        var best_sum: u64 = std.math.maxInt(u64);
        for (0..5) |filter| {
            const out = candidate[filter * stride ..][0..stride];
            var sum: u64 = 0;
            for (line, 0..) |byte, i| {
                const a: u8 = if (i >= 4) line[i - 4] else 0;
                const b: u8 = if (previous.len > 0) previous[i] else 0;
                const c: u8 = if (previous.len > 0 and i >= 4) previous[i - 4] else 0;
                out[i] = byte -% switch (filter) {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => @as(u8, @intCast((@as(u16, a) + b) / 2)),
                    else => paeth(a, b, c),
                };
                sum += @abs(@as(i8, @bitCast(out[i])));
            }
            if (sum < best_sum) {
                best_sum = sum;
                best = @intCast(filter);
            }
        }
        filtered[y * (stride + 1)] = best;
        @memcpy(filtered[y * (stride + 1) + 1 ..][0..stride], candidate[best * stride ..][0..stride]);
    }
    const compressed = try zlib(allocator, filtered);
    defer allocator.free(compressed);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], image.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], image.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(w, "IHDR", &ihdr);
    try chunk(w, "IDAT", compressed);
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

const BitWriter = struct {
    out: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    bits: u64 = 0,
    count: u6 = 0,

    fn write(self: *BitWriter, value: u32, width: u6) !void {
        self.bits |= @as(u64, value) << self.count;
        self.count += width;
        while (self.count >= 8) {
            try self.out.append(self.allocator, @truncate(self.bits));
            self.bits >>= 8;
            self.count -= 8;
        }
    }
    /// Huffman codes go most significant bit first.
    fn code(self: *BitWriter, value: u32, width: u6) !void {
        const reversed = @bitReverse(value) >> @intCast(32 - @as(u32, width));
        try self.write(reversed, width);
    }
    fn flush(self: *BitWriter) !void {
        if (self.count > 0) try self.write(0, 8 - (self.count % 8));
    }
};

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra = [30]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

fn literal(w: *BitWriter, symbol: u16) !void {
    switch (symbol) {
        0...143 => try w.code(0x30 + @as(u32, symbol), 8),
        144...255 => try w.code(0x190 + @as(u32, symbol) - 144, 9),
        256...279 => try w.code(@as(u32, symbol) - 256, 7),
        else => try w.code(0xC0 + @as(u32, symbol) - 280, 8),
    }
}

fn match(w: *BitWriter, length: usize, distance: usize) !void {
    var l: usize = length_base.len - 1;
    while (length_base[l] > length) l -= 1;
    try literal(w, @intCast(257 + l));
    try w.write(@intCast(length - length_base[l]), length_extra[l]);
    var d: usize = distance_base.len - 1;
    while (distance_base[d] > distance) d -= 1;
    try w.code(@intCast(d), 5);
    try w.write(@intCast(distance - distance_base[d]), distance_extra[d]);
}

/// A zlib stream of one fixed-Huffman deflate block with greedy LZ77
/// matches found through hash chains.
pub fn zlib(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const window = 32768;
    const hash_bits = 15;
    const max_chain = 64;
    var w: BitWriter = .{ .allocator = allocator };
    errdefer w.out.deinit(allocator);
    try w.out.appendSlice(allocator, &.{ 0x78, 0x01 });
    try w.write(1, 1); // final block
    try w.write(1, 2); // fixed Huffman codes
    const head = try allocator.alloc(i32, 1 << hash_bits);
    defer allocator.free(head);
    @memset(head, -1);
    const chain = try allocator.alloc(i32, window);
    defer allocator.free(chain);
    const hash = struct {
        fn of(bytes: []const u8) usize {
            const v = @as(u32, bytes[0]) << 16 | @as(u32, bytes[1]) << 8 | bytes[2];
            return (v *% 2654435761) >> (32 - hash_bits);
        }
    }.of;
    var i: usize = 0;
    while (i < data.len) {
        var best_length: usize = 0;
        var best_distance: usize = 0;
        if (i + 3 <= data.len) {
            var candidate = head[hash(data[i..])];
            var steps: usize = 0;
            while (candidate >= 0 and steps < max_chain) : (steps += 1) {
                const start: usize = @intCast(candidate);
                if (i - start > window - 1) break;
                const limit = @min(258, data.len - i);
                var n: usize = 0;
                while (n < limit and data[start + n] == data[i + n]) n += 1;
                if (n > best_length) {
                    best_length = n;
                    best_distance = i - start;
                    if (n == limit) break;
                }
                candidate = chain[start % window];
            }
        }
        const advance = if (best_length >= 3) best_length else 1;
        if (best_length >= 3) try match(&w, best_length, best_distance) else try literal(&w, data[i]);
        for (i..i + advance) |p| if (p + 3 <= data.len) {
            const h = hash(data[p..]);
            chain[p % window] = head[h];
            head[h] = @intCast(p);
        };
        i += advance;
    }
    try literal(&w, 256);
    try w.flush();
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(data), .big);
    try w.out.appendSlice(allocator, &adler);
    return w.out.toOwnedSlice(allocator);
}

test "encoded images decode to the same pixels" {
    const allocator = std.testing.allocator;
    var image: Image = try .init(allocator, 37, 23);
    defer image.deinit(allocator);
    for (0..23) |y| for (0..37) |x| {
        image.pixels[(y * 37 + x) * 4 ..][0..4].* = .{ @intCast(x * 7), @intCast(y * 11), @intCast((x * y) % 256), if ((x + y) % 5 == 0) 0 else 200 };
    };
    const bytes = try encode(allocator, image);
    defer allocator.free(bytes);
    const header = try readHeader(bytes);
    try std.testing.expectEqual(@as(u32, 37), header.width);
    const decoded = try decode(allocator, bytes);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, image.pixels, decoded.pixels);
    const again = try encode(allocator, image);
    defer allocator.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
}

test "repetitive data compresses and inflates" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 100_000);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @intCast((i / 300) % 7);
    const compressed = try zlib(allocator, data);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len < data.len / 20);
    var input: std.Io.Reader = .fixed(compressed);
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    const back = try allocator.alloc(u8, data.len);
    defer allocator.free(back);
    var output: std.Io.Writer = .fixed(back);
    try inflate.reader.streamExact(&output, back.len);
    try std.testing.expectEqualSlices(u8, data, back);
}

test "palette, gray and interlaced images decode" {
    const allocator = std.testing.allocator;
    // 2x2 palette PNG, 1-bit, with tRNS making index 0 transparent.
    var raw: [2 * 2]u8 = .{ 0, 0b0100_0000, 0, 0b1000_0000 };
    const compressed = try zlib(allocator, &raw);
    defer allocator.free(compressed);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(signature);
    try chunk(&out.writer, "IHDR", &.{ 0, 0, 0, 2, 0, 0, 0, 2, 1, 3, 0, 0, 0 });
    try chunk(&out.writer, "PLTE", &.{ 10, 20, 30, 200, 100, 50 });
    try chunk(&out.writer, "tRNS", &.{0});
    try chunk(&out.writer, "IDAT", compressed);
    try chunk(&out.writer, "IEND", "");
    const image = try decode(allocator, out.written());
    defer image.deinit(allocator);
    try std.testing.expectEqual([4]u8{ 10, 20, 30, 0 }, image.at(0, 0));
    try std.testing.expectEqual([4]u8{ 200, 100, 50, 255 }, image.at(1, 0));
    try std.testing.expectEqual([4]u8{ 10, 20, 30, 0 }, image.at(1, 1));

    // A 3x3 interlaced 8-bit gray image: every pass but those that are
    // empty for a 3x3 image carries pixels.
    const header: Header = .{ .width = 3, .height = 3, .bit_depth = 8, .color_type = 0, .interlaced = true };
    var filtered: std.ArrayList(u8) = .empty;
    defer filtered.deinit(allocator);
    for (0..7) |pass| {
        const size = passSize(header, pass);
        if (size[0] == 0 or size[1] == 0) continue;
        for (0..size[1]) |row| {
            try filtered.append(allocator, 0);
            for (0..size[0]) |column| {
                const x, const y = adam7(pass, column, row);
                try filtered.append(allocator, @intCast(y * 3 + x));
            }
        }
    }
    const gray = try zlib(allocator, filtered.items);
    defer allocator.free(gray);
    out.clearRetainingCapacity();
    try out.writer.writeAll(signature);
    try chunk(&out.writer, "IHDR", &.{ 0, 0, 0, 3, 0, 0, 0, 3, 8, 0, 0, 0, 1 });
    try chunk(&out.writer, "IDAT", gray);
    try chunk(&out.writer, "IEND", "");
    const interlaced = try decode(allocator, out.written());
    defer interlaced.deinit(allocator);
    for (0..3) |y| for (0..3) |x| {
        const v: u8 = @intCast(y * 3 + x);
        try std.testing.expectEqual([4]u8{ v, v, v, 255 }, interlaced.at(@intCast(x), @intCast(y)));
    };
}

test "malformed files are refused" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotPng, decode(allocator, "GIF89a"));
    var image: Image = try .init(allocator, 2, 2);
    defer image.deinit(allocator);
    const bytes = try encode(allocator, image);
    defer allocator.free(bytes);
    const broken = try allocator.dupe(u8, bytes);
    defer allocator.free(broken);
    broken[bytes.len - 20] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, decode(allocator, broken));
}
