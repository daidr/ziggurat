const std = @import("std");

pub const Info = struct {
    width: u32,
    height: u32,
    left: u32,
    top: u32,
    frame_width: u32,
    frame_height: u32,
    interlaced: bool,
    palette: []const u8,
    transparent: ?u8,
    minimum: u4,
    data: []const u8,
};
fn word(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}
fn table(bytes: []const u8, offset: *usize, flags: u8) ![]const u8 {
    if (flags & 0x80 == 0) return &.{};
    const size = @as(usize, 3) << @as(u4, @intCast((flags & 7) + 1));
    if (size > bytes.len - offset.*) return error.InvalidImage;
    const result = bytes[offset.*..][0..size];
    offset.* += size;
    return result;
}
fn blocks(bytes: []const u8, offset: *usize) !void {
    while (offset.* < bytes.len) {
        const size = bytes[offset.*];
        offset.* += 1;
        if (size > bytes.len - offset.*) return error.InvalidImage;
        offset.* += size;
        if (size == 0) return;
    }
    return error.InvalidImage;
}

/// Inspect the first raster graphic only. Later animation frames are neither
/// decoded nor used to size allocations. Plain-text rendering is unsupported.
pub fn inspect(bytes: []const u8) !Info {
    if (bytes.len < 13 or (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a"))) return error.InvalidImage;
    const width = word(bytes, 6);
    const height = word(bytes, 8);
    if (width == 0 or height == 0) return error.InvalidImage;
    if (width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.CapacityExceeded;
    var offset: usize = 13;
    const global = try table(bytes, &offset, bytes[10]);
    var transparent: ?u8 = null;
    while (offset < bytes.len) {
        const tag = bytes[offset];
        offset += 1;
        switch (tag) {
            0x21 => {
                if (offset == bytes.len) return error.InvalidImage;
                const label = bytes[offset];
                offset += 1;
                if (label == 0xf9) {
                    if (bytes.len - offset < 6 or bytes[offset] != 4 or bytes[offset + 5] != 0 or bytes[offset + 1] & 0xe0 != 0 or (bytes[offset + 1] >> 2) & 7 > 3) return error.InvalidImage;
                    transparent = if (bytes[offset + 1] & 1 != 0) bytes[offset + 4] else null;
                    offset += 6;
                } else if (label == 0x01) {
                    return error.UnsupportedGifGraphic;
                } else if (label == 0xfe or label == 0xff) {
                    if (label == 0xff and (offset == bytes.len or bytes[offset] != 11)) return error.InvalidImage;
                    try blocks(bytes, &offset);
                } else return error.UnsupportedGifExtension;
            },
            0x2c => {
                if (bytes.len - offset < 9) return error.InvalidImage;
                const left = word(bytes, offset);
                const top = word(bytes, offset + 2);
                const frame_width = word(bytes, offset + 4);
                const frame_height = word(bytes, offset + 6);
                const flags = bytes[offset + 8];
                if (frame_width == 0 or frame_height == 0 or @as(u32, left) + frame_width > width or @as(u32, top) + frame_height > height or flags & 0x18 != 0) return error.InvalidImage;
                offset += 9;
                const local = try table(bytes, &offset, flags);
                const palette = if (local.len == 0) global else local;
                if (palette.len == 0 or (transparent != null and transparent.? >= palette.len / 3)) return error.InvalidImage;
                if (offset == bytes.len or bytes[offset] < 2 or bytes[offset] > 8) return error.InvalidImage;
                const minimum: u4 = @intCast(bytes[offset]);
                offset += 1;
                const start = offset;
                try blocks(bytes, &offset);
                return .{ .width = width, .height = height, .left = left, .top = top, .frame_width = frame_width, .frame_height = frame_height, .interlaced = flags & 0x40 != 0, .palette = palette, .transparent = transparent, .minimum = minimum, .data = bytes[start..offset] };
            },
            else => return error.InvalidImage,
        }
    }
    return error.InvalidImage;
}

const Codes = struct {
    data: []const u8,
    offset: usize = 0,
    remaining: u8 = 0,
    ended: bool = false,
    bits: u32 = 0,
    count: u8 = 0,
    fn next(self: *Codes, width: u4) !?u16 {
        while (self.count < width) {
            if (self.ended) return null;
            if (self.remaining == 0) {
                if (self.offset == self.data.len) return error.InvalidImage;
                self.remaining = self.data[self.offset];
                self.offset += 1;
                if (self.remaining == 0) {
                    self.ended = true;
                    return null;
                }
                if (self.remaining > self.data.len - self.offset) return error.InvalidImage;
            }
            self.bits |= @as(u32, self.data[self.offset]) << @as(u5, @intCast(self.count));
            self.offset += 1;
            self.remaining -= 1;
            self.count += 8;
        }
        const result: u16 = @intCast(self.bits & ((@as(u32, 1) << width) - 1));
        self.bits >>= width;
        self.count -= width;
        return result;
    }
};
const Output = struct {
    info: Info,
    pixels: []u8,
    x: u32 = 0,
    y: u32 = 0,
    pass: usize = 0,
    count: usize = 0,
    fn write(self: *Output, index: u8) !void {
        const info = self.info;
        if (self.count >= @as(usize, info.frame_width) * info.frame_height or index >= info.palette.len / 3) return error.InvalidImage;
        if (info.transparent == null or info.transparent.? != index) {
            const at = ((info.top + self.y) * @as(usize, info.width) + info.left + self.x) * 4;
            @memcpy(self.pixels[at..][0..3], info.palette[@as(usize, index) * 3 ..][0..3]);
            self.pixels[at + 3] = 255;
        }
        self.count += 1;
        self.x += 1;
        if (self.x == info.frame_width) {
            self.x = 0;
            if (!info.interlaced) {
                self.y += 1;
            } else {
                const steps = [_]u32{ 8, 8, 4, 2 };
                const starts = [_]u32{ 0, 4, 2, 1 };
                self.y += steps[self.pass];
                while (self.y >= info.frame_height and self.pass < 3) {
                    self.pass += 1;
                    self.y = starts[self.pass];
                }
            }
        }
    }
};

/// Bounded LZW: fixed 4096-entry dictionary and at most 4096-byte expansion
/// stack. The caller owns the single RGBA canvas, cleared to transparent.
pub fn decode(info: Info, pixels: []u8, cancellation: ?*const std.atomic.Value(bool)) !void {
    if (pixels.len != @as(usize, info.width) * info.height * 4) return error.InvalidImage;
    @memset(pixels, 0);
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;
    const clear: u16 = @as(u16, 1) << info.minimum;
    const end = clear + 1;
    var next = end + 1;
    var width: u4 = info.minimum + 1;
    var previous: ?u16 = null;
    var codes: Codes = .{ .data = info.data };
    var output: Output = .{ .info = info, .pixels = pixels };
    if ((try codes.next(width)) != clear) return error.InvalidImage;
    while (try codes.next(width)) |raw| {
        if (cancellation) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
        if (raw == clear) {
            next = end + 1;
            width = info.minimum + 1;
            previous = null;
            continue;
        }
        if (raw == end) {
            if (output.count != @as(usize, info.frame_width) * info.frame_height) return error.InvalidImage;
            return;
        }
        if (raw > next or (raw == next and previous == null)) return error.InvalidImage;
        const special = raw == next;
        var code = if (special) previous.? else raw;
        var count: usize = 0;
        while (code >= clear) {
            if (code >= next or code <= end or count == stack.len) return error.InvalidImage;
            stack[count] = suffix[code];
            count += 1;
            const before = code;
            code = prefix[code];
            if (code >= before) return error.InvalidImage;
        }
        if (count == stack.len) return error.InvalidImage;
        const first: u8 = @intCast(code);
        stack[count] = first;
        count += 1;
        while (count != 0) {
            count -= 1;
            try output.write(stack[count]);
        }
        if (special) try output.write(first);
        if (previous) |old| if (next < 4096) {
            prefix[next] = old;
            suffix[next] = first;
            next += 1;
            if (next == @as(u16, 1) << width and width < 12) width += 1;
        };
        previous = raw;
    }
    return error.InvalidImage;
}

test "first GIF graphic validates dimensions, tables, bounded blocks and LZW termination" {
    const bytes = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\x00\x00\x00\xff\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00;";
    const info = try inspect(bytes);
    var pixels: [4]u8 = undefined;
    try decode(info, &pixels, null);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &pixels);
    for (0..bytes.len - 1) |length| try std.testing.expectError(error.InvalidImage, inspect(bytes[0..length]));
    var bad = bytes[0..bytes.len].*;
    bad[31] = 0xff;
    try std.testing.expectError(error.InvalidImage, decode(try inspect(&bad), &pixels, null));
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, decode(info, &pixels, &cancel));
}

test "GIF malformed dimensions, graphic control, codes and mutated streams stay bounded" {
    const source = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\x00\x00\x00\xff\x00\x21\xf9\x04\x01\x00\x00\x01\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00;";
    var pixels: [4]u8 = undefined;
    const info = try inspect(source);
    try decode(info, &pixels, null);
    const mutations = .{ .{ 6, 0 }, .{ 22, 0x10 }, .{ 25, 2 }, .{ 26, 1 }, .{ 28, 1 }, .{ 32, 0 }, .{ 36, 8 }, .{ 37, 1 }, .{ 38, 255 } };
    inline for (mutations) |entry| {
        var bytes = source[0..source.len].*;
        bytes[entry[0]] = entry[1];
        try std.testing.expectError(error.InvalidImage, inspect(&bytes));
    }
    var missing_end = info;
    missing_end.data = &.{ 1, 0x04, 0 }; // clear + one literal, no end code.
    try std.testing.expectError(error.InvalidImage, decode(missing_end, &pixels, null));
    missing_end.data = &.{ 2, 0x04, 0x00, 0 }; // Too many decoded pixels.
    try std.testing.expectError(error.InvalidImage, decode(missing_end, &pixels, null));
    var random = std.Random.DefaultPrng.init(0x61f9);
    for (0..4000) |_| {
        var bytes = source[0..source.len].*;
        for (0..3) |_| bytes[random.random().uintLessThan(usize, bytes.len)] = random.random().int(u8);
        const current = inspect(&bytes) catch continue;
        if (current.width > 16 or current.height > 16) continue;
        var storage: [16 * 16 * 4]u8 = undefined;
        decode(current, storage[0 .. current.width * current.height * 4], null) catch continue;
    }
}
