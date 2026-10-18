const std = @import("std");
const builtin = @import("builtin");
const bitmap = @import("bitmap.zig");
const gif = @import("gif.zig");
const webp = @import("webp.zig");
const image_options = @import("ziggurat_image_options");
pub const drawing = @import("ziggurat_drawing_resources");

pub const Format = enum(c_int) { png = 1, jpeg = 2, bmp = 3, gif = 4, webp = 5 };
pub const Limits = struct {
    encoded_bytes: usize = 32 * 1024 * 1024,
    dimension: u32 = 16384,
    pixels: u64 = 16 * 1024 * 1024,
    decoded_bytes: usize = 64 * 1024 * 1024,
};
pub const Metadata = struct { format: Format, width: u32, height: u32, orientation: u4 = 1 };
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    fn check(self: *const Cancellation) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};
pub const DecodeOptions = struct { limits: Limits = .{}, cancellation: ?*const Cancellation = null };
pub const NativeFailure = union(enum) { hresult: u32, gdk_pixbuf: struct { domain: u32, code: i32 }, webp: c_int };
const NativeError = extern struct { domain: u32 = 0, code: i32 = 0, native_domain: u32 = 0 };
pub const capabilities = .{ .png = builtin.os.tag == .windows or builtin.os.tag == .linux, .jpeg = builtin.os.tag == .windows or builtin.os.tag == .linux, .bmp = builtin.os.tag == .windows or builtin.os.tag == .linux, .gif = builtin.os.tag == .windows or builtin.os.tag == .linux, .webp = image_options.webp and (builtin.os.tag == .windows or builtin.os.tag == .linux) };
/// References owned by the codec adapter, including its worker context.
pub fn nativeReferences() u32 {
    return if (capabilities.png) zi_native_references() else 0;
}

fn be16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}
fn be32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}
fn validateSize(width: u32, height: u32, limits: Limits) !void {
    if (width == 0 or height == 0) return error.InvalidImage;
    const pixels = @as(u64, width) * height;
    if (width > limits.dimension or height > limits.dimension or pixels > limits.pixels or pixels > std.math.maxInt(usize) / 4) return error.CapacityExceeded;
    if (pixels * 4 > limits.decoded_bytes) return error.CapacityExceeded;
}

/// Header inspection is bounded by encoded_bytes. Native decode still validates
/// the complete stream and must report the same dimensions and container.
pub fn inspect(bytes: []const u8, limits: Limits) !Metadata {
    if (limits.encoded_bytes == 0 or limits.encoded_bytes > 32 * 1024 * 1024 or limits.dimension == 0 or limits.dimension > 16384 or limits.pixels == 0 or limits.pixels > 16 * 1024 * 1024 or limits.decoded_bytes == 0 or limits.decoded_bytes > 64 * 1024 * 1024) return error.InvalidLimits;
    if (bytes.len > limits.encoded_bytes or bytes.len > std.math.maxInt(u32)) return error.CapacityExceeded;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        const info = try webp.inspect(bytes);
        try validateSize(info.width, info.height, limits);
        return .{ .format = .webp, .width = info.width, .height = info.height };
    }
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        const info = try gif.inspect(bytes);
        try validateSize(info.width, info.height, limits);
        return .{ .format = .gif, .width = info.width, .height = info.height };
    }
    if (bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], "BM")) {
        const info = try bitmap.inspect(bytes);
        try validateSize(info.width, info.height, limits);
        return .{ .format = .bmp, .width = info.width, .height = info.height };
    }
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
        if (be32(bytes[8..12]) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidImage;
        const result: Metadata = .{ .format = .png, .width = be32(bytes[16..20]), .height = be32(bytes[20..24]) };
        try validateSize(result.width, result.height, limits);
        return result;
    }
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..2], "\xff\xd8")) return error.UnsupportedFormat;
    var offset: usize = 2;
    var dimensions: ?Metadata = null;
    var orientation: u4 = 1;
    while (offset < bytes.len) {
        if (bytes[offset] != 0xff) return error.InvalidImage;
        while (offset < bytes.len and bytes[offset] == 0xff) : (offset += 1) {}
        if (offset == bytes.len) return error.InvalidImage;
        const marker = bytes[offset];
        offset += 1;
        if (marker == 0xda or marker == 0xd9) break;
        if (marker == 0 or marker == 0xd8 or (marker >= 0xd0 and marker <= 0xd7)) return error.InvalidImage;
        if (marker == 0x01) continue;
        if (bytes.len - offset < 2) return error.InvalidImage;
        const length: usize = be16(bytes[offset..]);
        if (length < 2 or length > bytes.len - offset) return error.InvalidImage;
        const segment = bytes[offset + 2 .. offset + length];
        if (marker == 0xe1 and segment.len >= 6 and std.mem.eql(u8, segment[0..6], "Exif\x00\x00")) orientation = exifOrientation(segment[6..]);
        if ((marker >= 0xc0 and marker <= 0xc3) or (marker >= 0xc5 and marker <= 0xc7) or (marker >= 0xc9 and marker <= 0xcb) or (marker >= 0xcd and marker <= 0xcf)) {
            if (segment.len < 6 or dimensions != null) return error.InvalidImage;
            const result: Metadata = .{ .format = .jpeg, .width = be16(segment[3..]), .height = be16(segment[1..]) };
            try validateSize(result.width, result.height, limits);
            dimensions = result;
        }
        offset += length;
    }
    var result = dimensions orelse return error.InvalidImage;
    result.orientation = orientation;
    return result;
}

fn exifOrientation(bytes: []const u8) u4 {
    if (bytes.len < 8) return 1;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, bytes[0..2], "II")) .little else if (std.mem.eql(u8, bytes[0..2], "MM")) .big else return 1;
    if (std.mem.readInt(u16, bytes[2..4], endian) != 42) return 1;
    const first: usize = std.mem.readInt(u32, bytes[4..8], endian);
    if (first < 8 or first > bytes.len or bytes.len - first < 2) return 1;
    const count: usize = std.mem.readInt(u16, bytes[first..][0..2], endian);
    const entries = first + 2;
    if (count > (bytes.len - entries) / 12) return 1;
    for (0..count) |i| {
        const entry = bytes[entries + i * 12 ..][0..12];
        if (std.mem.readInt(u16, entry[0..2], endian) == 0x0112 and std.mem.readInt(u16, entry[2..4], endian) == 3 and std.mem.readInt(u32, entry[4..8], endian) == 1) {
            const value = std.mem.readInt(u16, entry[8..10], endian);
            return if (value >= 1 and value <= 8) @intCast(value) else 1;
        }
    }
    return 1;
}

/// Immutable top-down straight RGBA8 pixels. Keep this owning object at its
/// stable address; only the owner may query or close it. No native handles live
/// past decode. The allocator must support the adopted owner and outlive Image.
pub const Image = struct {
    allocator: std.mem.Allocator,
    lease: drawing.Lease,
    main_thread: std.Thread.Id,
    adopted: bool = false,
    closing: bool = false,
    width: u32,
    height: u32,
    storage: []u8,

    /// Explicit exclusive handoff after the producer stops accessing Image.
    /// App.post success transfers this responsibility; failure does not.
    pub fn adopt(self: *Image) !void {
        if (std.Thread.getCurrentId() != self.main_thread) return error.WrongThread;
        if (self.closing) return error.Closed;
        if (self.adopted) return error.AlreadyAdopted;
        if (self.lease.pins != 0) return error.ResourceInUse;
        self.lease.owner = self.main_thread;
        self.adopted = true;
    }
    pub fn pixels(self: *const Image) ![]const u8 {
        try self.lease.checkOwner();
        if (self.closing) return error.Closed;
        return self.storage;
    }
    pub fn close(self: *Image) !void {
        try self.lease.checkOwner();
        if (self.closing) return error.Closed;
        try self.lease.ensureUnused();
        self.closing = true;
        const allocator = self.allocator;
        allocator.free(self.storage);
        allocator.destroy(self);
    }
};

/// Synchronous decoding on an application-owned background thread. This type
/// does not create threads, read files, post tasks, or retain encoded input.
pub const Worker = struct {
    owner: std.Thread.Id,
    main_thread: std.Thread.Id,
    native: *anyopaque,
    closed: bool = false,
    /// Captured at a native failure before cleanup. Input/budget/cancellation
    /// errors leave this null, never carrying a code from an earlier decode.
    last_failure: ?NativeFailure = null,

    pub fn init(main_thread: std.Thread.Id) !Worker {
        const owner = std.Thread.getCurrentId();
        if (owner == main_thread) return error.UiThreadForbidden;
        if (!capabilities.png) return error.UnsupportedPlatform;
        return .{ .owner = owner, .main_thread = main_thread, .native = zi_create() orelse return error.DecoderUnavailable };
    }
    pub fn deinit(self: *Worker) void {
        std.debug.assert(std.Thread.getCurrentId() == self.owner);
        if (self.closed) return;
        zi_destroy(self.native);
        self.closed = true;
    }
    pub fn decode(self: *Worker, allocator: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) !*Image {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.closed) return error.Closed;
        self.last_failure = null;
        if (options.cancellation) |cancel| try cancel.check();
        const meta = try inspect(bytes, options.limits);
        var storage = try allocator.alloc(u8, @as(usize, meta.width) * meta.height * 4);
        errdefer allocator.free(storage);
        var failure: NativeError = .{};
        const result = if (meta.format == .gif) result: {
            try gif.decode(try gif.inspect(bytes), storage, if (options.cancellation) |cancel| &cancel.requested else null);
            break :result 0;
        } else if (meta.format == .webp) result: {
            const status = webp.decode(bytes, meta.width, meta.height, storage);
            if (status != 0) {
                self.last_failure = .{ .webp = status };
                return if (status == 1) error.OutOfMemory else error.InvalidImage;
            }
            break :result 0;
        } else zi_decode(self.native, bytes.ptr, @intCast(bytes.len), @intFromEnum(meta.format), meta.width, meta.height, storage.ptr, &failure);
        if (result != 0) {
            self.last_failure = switch (failure.domain) {
                1 => .{ .hresult = @bitCast(failure.code) },
                2 => .{ .gdk_pixbuf = .{ .domain = failure.native_domain, .code = failure.code } },
                else => null,
            };
            return if (result == 2) error.OutOfMemory else error.InvalidImage;
        }
        if (options.cancellation) |cancel| try cancel.check();
        if (meta.format == .bmp) {
            // BI_RGB's unused bytes are not alpha. Explicit channel masks are
            // normalized independently of system codec alpha preferences.
            const info = try bitmap.inspect(bytes);
            for (0..meta.height) |y| {
                if (y % 32 == 0) if (options.cancellation) |cancel| try cancel.check();
                for (0..meta.width) |x| storage[(y * meta.width + x) * 4 + 3] = info.alpha(bytes, x, y);
            }
        }
        const swapped = meta.orientation >= 5;
        const width = if (swapped) meta.height else meta.width;
        const height = if (swapped) meta.width else meta.height;
        if (meta.orientation != 1) {
            const rotated = try allocator.alloc(u8, storage.len);
            for (0..meta.height) |y| for (0..meta.width) |x| {
                const dx = switch (meta.orientation) {
                    2, 3 => meta.width - 1 - x,
                    5, 8 => y,
                    6, 7 => meta.height - 1 - y,
                    else => x,
                };
                const dy = switch (meta.orientation) {
                    3, 4 => meta.height - 1 - y,
                    5, 6 => x,
                    7, 8 => meta.width - 1 - x,
                    else => y,
                };
                @memcpy(rotated[(dy * width + dx) * 4 ..][0..4], storage[(y * meta.width + x) * 4 ..][0..4]);
            };
            allocator.free(storage);
            storage = rotated;
        }
        if (options.cancellation) |cancel| try cancel.check();
        const image = try allocator.create(Image);
        image.* = .{ .allocator = allocator, .lease = drawing.Lease.init(self.owner), .main_thread = self.main_thread, .width = width, .height = height, .storage = storage };
        return image;
    }
};

extern fn zi_create() ?*anyopaque;
extern fn zi_destroy(*anyopaque) void;
extern fn zi_decode(*anyopaque, [*]const u8, u32, c_int, u32, u32, [*]u8, *NativeError) c_int;
extern fn zi_native_references() u32;

test "image headers reject dimensions and malformed marker lengths before native decode" {
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x02\x00\x00\x00\x03";
    const metadata = try inspect(png, .{});
    try std.testing.expectEqual(2, metadata.width);
    try std.testing.expectEqual(3, metadata.height);
    try std.testing.expectError(error.CapacityExceeded, inspect(png, .{ .pixels = 5 }));
    try std.testing.expectError(error.CapacityExceeded, inspect(png, .{ .decoded_bytes = 23 }));
    try std.testing.expectError(error.CapacityExceeded, inspect(png, .{ .encoded_bytes = 23 }));
    try std.testing.expectError(error.InvalidImage, inspect("\xff\xd8\xff\xe1\xff\xff", .{}));
    try std.testing.expectError(error.UnsupportedFormat, inspect("unknown", .{}));
    const jpeg = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x03\x00\x02\x01\x01\x11\x00\xff\xda";
    const size = try inspect(jpeg, .{});
    try std.testing.expectEqual(Format.jpeg, size.format);
    try std.testing.expectEqual(2, size.width);
    try std.testing.expectEqual(3, size.height);
    for (0..jpeg.len) |length| _ = inspect(jpeg[0..length], .{}) catch continue;
}

test "EXIF orientation parser validates entry offsets and both byte orders" {
    try std.testing.expectEqual(6, exifOrientation("II\x2a\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00"));
    try std.testing.expectEqual(8, exifOrientation("MM\x00\x2a\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x08\x00\x00"));
    try std.testing.expectEqual(1, exifOrientation("II\x2a\x00\xff\xff\xff\xff\x00\x00"));
    try std.testing.expectError(error.UiThreadForbidden, Worker.init(std.Thread.getCurrentId()));
}
