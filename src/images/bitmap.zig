const std = @import("std");

pub const Info = struct {
    width: u32,
    height: u32,
    pixels: usize,
    stride: usize,
    bits: u16,
    top_down: bool,
    alpha_mask: u32,
    pub fn alpha(self: Info, bytes: []const u8, x: usize, y: usize) u8 {
        if (self.alpha_mask == 0) return 255;
        const row = if (self.top_down) y else self.height - 1 - y;
        const at = self.pixels + row * self.stride + x * (self.bits / 8);
        const value: u32 = if (self.bits == 16) le(u16, bytes, at) else le(u32, bytes, at);
        const shift: u5 = @intCast(@ctz(self.alpha_mask));
        const maximum = self.alpha_mask >> shift;
        return @intCast((@as(u64, (value & self.alpha_mask) >> shift) * 255 + maximum / 2) / maximum);
    }
};
fn le(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn validMask(mask: u32, bits: u16, required: bool) bool {
    if (mask == 0) return !required;
    if (bits == 16 and mask > 0xffff) return false;
    const value = mask >> @as(u5, @intCast(@ctz(mask)));
    return value & (value +% 1) == 0;
}

/// Validate a standalone BM container before allowing a system decoder to
/// allocate pixels. Embedded JPEG/PNG and unknown DIB dialects are rejected.
pub fn inspect(bytes: []const u8) !Info {
    if (bytes.len < 26 or !std.mem.eql(u8, bytes[0..2], "BM")) return error.InvalidImage;
    if (le(u32, bytes, 2) != bytes.len or le(u32, bytes, 6) != 0) return error.InvalidImage;
    const header: usize = le(u32, bytes, 14);
    const pixels: usize = le(u32, bytes, 10);
    if (header > bytes.len - 14 or pixels > bytes.len or pixels < 14 + header) return error.InvalidImage;
    var width: u32 = undefined;
    var height: u32 = undefined;
    var bits: u16 = undefined;
    var compression: u32 = 0;
    var palette: u32 = 0;
    var palette_stride: u32 = 4;
    var metadata_end: usize = 14 + header;
    var declared_size: u32 = 0;
    var top_down = false;
    var alpha_mask: u32 = 0;
    if (header == 12) {
        width = le(u16, bytes, 18);
        height = le(u16, bytes, 20);
        if (le(u16, bytes, 22) != 1) return error.InvalidImage;
        bits = le(u16, bytes, 24);
        if (bits != 1 and bits != 4 and bits != 8 and bits != 24) return error.UnsupportedBitmapEncoding;
        palette_stride = 3;
    } else {
        if (header != 40 and header != 52 and header != 56 and header != 108 and header != 124) return error.UnsupportedBitmapHeader;
        const signed_width = le(i32, bytes, 18);
        const signed_height = le(i32, bytes, 22);
        if (signed_width <= 0 or signed_height == 0 or signed_height == std.math.minInt(i32) or le(u16, bytes, 26) != 1) return error.InvalidImage;
        width = @intCast(signed_width);
        height = @intCast(if (signed_height < 0) -signed_height else signed_height);
        top_down = signed_height < 0;
        bits = le(u16, bytes, 28);
        compression = le(u32, bytes, 30);
        declared_size = le(u32, bytes, 34);
        palette = le(u32, bytes, 46);
        const supported = switch (bits) {
            1, 24 => compression == 0,
            4 => compression == 0 or compression == 2,
            8 => compression == 0 or compression == 1,
            16, 32 => compression == 0 or compression == 3 or compression == 6,
            else => false,
        };
        if (!supported) return error.UnsupportedBitmapEncoding;
        if (signed_height < 0 and (compression == 1 or compression == 2)) return error.InvalidImage;
        if (compression == 3 or compression == 6) {
            const count: usize = if (compression == 6) 4 else 3;
            if (header == 40) metadata_end += count * 4 else if (header < 40 + count * 4) return error.InvalidImage;
            if (metadata_end > pixels) return error.InvalidImage;
            var used: u32 = 0;
            for (0..count) |i| {
                const mask = le(u32, bytes, 54 + i * 4);
                if (!validMask(mask, bits, true) or used & mask != 0) return error.InvalidImage;
                used |= mask;
                if (i == 3) alpha_mask = mask;
            }
            if (count == 3 and header >= 56) {
                const alpha = le(u32, bytes, 66);
                if (!validMask(alpha, bits, false) or used & alpha != 0) return error.InvalidImage;
                alpha_mask = alpha;
            }
        }
    }
    if (width == 0 or height == 0) return error.InvalidImage;
    // Apply hard decode ceilings before arithmetic on attacker-sized surfaces.
    if (width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.CapacityExceeded;
    if (bits <= 8) {
        const colors: u32 = @as(u32, 1) << @as(u5, @intCast(bits));
        if (palette > colors) return error.InvalidImage;
        if (palette == 0) palette = colors;
    }
    if (@as(u64, palette) * palette_stride > pixels - metadata_end) return error.InvalidImage;
    var stride: u64 = 0;
    if (compression == 1 or compression == 2) {
        if (declared_size == 0 or declared_size > bytes.len - pixels) return error.InvalidImage;
    } else {
        stride = ((@as(u64, width) * bits + 31) / 32) * 4;
        const count = stride * height;
        if (count > bytes.len - pixels or (declared_size != 0 and declared_size != count)) return error.InvalidImage;
    }
    return .{ .width = width, .height = height, .pixels = pixels, .stride = @intCast(stride), .bits = bits, .top_down = top_down, .alpha_mask = alpha_mask };
}

test "bitmap masks reject overlaps, gaps, out-of-range and required empty channels" {
    try std.testing.expect(validMask(0x7c00, 16, true));
    try std.testing.expect(validMask(0xff000000, 32, true));
    try std.testing.expect(validMask(0, 32, false));
    try std.testing.expect(!validMask(0, 32, true));
    try std.testing.expect(!validMask(0x55, 16, true));
    try std.testing.expect(!validMask(0xff0000, 16, true));
}

fn fixture() [70]u8 {
    var bytes = @as([70]u8, @splat(0));
    @memcpy(bytes[0..2], "BM");
    put(u32, &bytes, 2, bytes.len);
    put(u32, &bytes, 10, 54);
    put(u32, &bytes, 14, 40);
    put(i32, &bytes, 18, 2);
    put(i32, &bytes, 22, 2);
    put(u16, &bytes, 26, 1);
    put(u16, &bytes, 28, 24);
    return bytes;
}
fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

test "bitmap preflight validates file boundaries, palettes and dimensions before decode" {
    const good = fixture();
    const info = try inspect(&good);
    try std.testing.expectEqual(@as(usize, 8), info.stride);
    try std.testing.expectEqual(@as(u8, 255), info.alpha(&good, 1, 1));
    for (0..good.len) |end| try std.testing.expectError(error.InvalidImage, inspect(good[0..end]));
    const mutations = .{
        .{ 2, 69 }, .{ 6, 1 },  .{ 10, 53 }, .{ 10, 71 }, .{ 14, 80 },
        .{ 18, 0 }, .{ 22, 0 }, .{ 26, 2 },  .{ 34, 1 },  .{ 46, 255 },
    };
    inline for (mutations) |entry| {
        var bytes = good;
        put(u32, &bytes, entry[0], entry[1]);
        try std.testing.expectError(error.InvalidImage, inspect(&bytes));
    }
    var bytes = good;
    put(u32, &bytes, 14, 16);
    try std.testing.expectError(error.UnsupportedBitmapHeader, inspect(&bytes));
    bytes = good;
    put(u16, &bytes, 28, 8);
    try std.testing.expectError(error.InvalidImage, inspect(&bytes)); // Missing color table.
    put(u32, &bytes, 46, 257);
    try std.testing.expectError(error.InvalidImage, inspect(&bytes));
    bytes = good;
    put(i32, &bytes, 22, std.math.minInt(i32));
    try std.testing.expectError(error.InvalidImage, inspect(&bytes));
    put(i32, &bytes, 22, 16385);
    try std.testing.expectError(error.CapacityExceeded, inspect(&bytes));
    bytes = good;
    put(u16, &bytes, 28, 32);
    put(u32, &bytes, 30, 5); // Embedded PNG is outside this container policy.
    try std.testing.expectError(error.UnsupportedBitmapEncoding, inspect(&bytes));
    var random = std.Random.DefaultPrng.init(0x5cb12);
    for (0..4000) |_| {
        bytes = good;
        for (0..4) |_| bytes[random.random().uintLessThan(usize, bytes.len)] = random.random().int(u8);
        _ = inspect(&bytes) catch continue;
    }
}
