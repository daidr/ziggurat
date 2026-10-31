//! MP3 and Ogg Vorbis through the pinned third-party C decoders in
//! `third_party/`, compiled with the module. MP3 reads its input as it plays;
//! Vorbis decodes from a copy of the whole compressed input in memory.
const std = @import("std");
const zio = @import("ziggurat_io");
const decoding = @import("decoder.zig");
const Error = decoding.Error;
const Input = decoding.Input;
const Decoder = decoding.Decoder;

const Mp3Handle = opaque {};
const VorbisHandle = opaque {};
const ReadCallback = *const fn (buffer: ?*anyopaque, size: usize, context: ?*anyopaque) callconv(.c) usize;
const SeekCallback = *const fn (position: u64, context: ?*anyopaque) callconv(.c) c_int;

extern fn zg_mp3_open(read: ReadCallback, seek: SeekCallback, context: ?*anyopaque, out: *?*Mp3Handle) c_int;
extern fn zg_mp3_info(handle: *Mp3Handle, rate: *c_int, channels: *c_int, samples: *u64) void;
extern fn zg_mp3_read(handle: *Mp3Handle, buffer: [*]f32, samples: usize) usize;
extern fn zg_mp3_error(handle: *Mp3Handle) c_int;
extern fn zg_mp3_seek(handle: *Mp3Handle, sample: u64) c_int;
extern fn zg_mp3_close(handle: *Mp3Handle) void;

extern fn zg_vorbis_open(data: [*]const u8, length: c_int, err: *c_int) ?*VorbisHandle;
extern fn zg_vorbis_info(handle: *VorbisHandle, rate: *c_int, channels: *c_int, frames: *c_uint) void;
extern fn zg_vorbis_read(handle: *VorbisHandle, channels: c_int, buffer: [*]f32, samples: c_int) c_int;
extern fn zg_vorbis_seek(handle: *VorbisHandle, frame: c_uint) c_int;
extern fn zg_vorbis_close(handle: *VorbisHandle) void;

/// An ID3 tag, or the sync word of an MPEG-1 or 2 layer III frame.
pub const mp3_formats = [_]decoding.Format{
    .{ .name = "mp3", .magic = "ID3", .open = openMp3 },
    .{ .name = "mp3", .magic = "\xff\xfb", .open = openMp3 },
    .{ .name = "mp3", .magic = "\xff\xfa", .open = openMp3 },
    .{ .name = "mp3", .magic = "\xff\xf3", .open = openMp3 },
    .{ .name = "mp3", .magic = "\xff\xf2", .open = openMp3 },
    .{ .name = "mp3", .magic = "\xff\xe3", .open = openMp3 },
    .{ .name = "mp3", .magic = "\xff\xe2", .open = openMp3 },
};

pub const vorbis_format: decoding.Format = .{ .name = "vorbis", .magic = "OggS", .open = openVorbis };

const Mp3 = struct {
    allocator: std.mem.Allocator,
    input: Input,
    handle: *Mp3Handle,
    channels: usize,
    frames: ?u64,
    input_failed: bool = false,

    fn readInput(buffer: ?*anyopaque, size: usize, context: ?*anyopaque) callconv(.c) usize {
        const self: *Mp3 = @ptrCast(@alignCast(context.?));
        const bytes: [*]u8 = @ptrCast(buffer.?);
        return self.input.readAll(bytes[0..size]) catch {
            self.input_failed = true;
            return 0;
        };
    }

    fn seekInput(position: u64, context: ?*anyopaque) callconv(.c) c_int {
        const self: *Mp3 = @ptrCast(@alignCast(context.?));
        self.input.seekTo(position) catch return -1;
        return 0;
    }

    fn read(context: *anyopaque, out: []f32) Error!usize {
        const self: *Mp3 = @ptrCast(@alignCast(context));
        const wanted = out.len / self.channels * self.channels;
        if (wanted == 0) return 0;
        const count = zg_mp3_read(self.handle, out.ptr, wanted);
        if (count == 0) {
            if (self.input_failed) return error.ReadFailed;
            if (zg_mp3_error(self.handle) != 0) return error.InvalidData;
        }
        return count - count % self.channels;
    }

    fn setPosition(context: *anyopaque, frame: u64) Error!void {
        const self: *Mp3 = @ptrCast(@alignCast(context));
        if (self.frames) |frames| if (frame > frames) return error.OutOfRange;
        if (zg_mp3_seek(self.handle, frame * self.channels) != 0) return error.SeekFailed;
    }

    fn deinit(context: *anyopaque) void {
        const self: *Mp3 = @ptrCast(@alignCast(context));
        zg_mp3_close(self.handle);
        self.allocator.destroy(self);
    }

    const vtable: Decoder.VTable = .{ .read = read, .setPosition = setPosition, .deinit = deinit };
};

pub fn openMp3(allocator: std.mem.Allocator, input: Input) Error!Decoder {
    const self = try allocator.create(Mp3);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .input = input, .handle = undefined, .channels = 0, .frames = null };
    var handle: ?*Mp3Handle = null;
    const result = zg_mp3_open(Mp3.readInput, Mp3.seekInput, self, &handle);
    if (result != 0) return switch (result) {
        -2 => error.OutOfMemory,
        else => if (self.input_failed) error.ReadFailed else error.InvalidData,
    };
    self.handle = handle.?;
    var rate: c_int = 0;
    var channels: c_int = 0;
    var samples: u64 = 0;
    zg_mp3_info(self.handle, &rate, &channels, &samples);
    self.channels = @intCast(channels);
    self.frames = if (samples > 0) samples / self.channels else null;
    return .{ .context = self, .vtable = &Mp3.vtable, .sample_rate = @intCast(rate), .channels = @intCast(zio.asUnsigned(channels)), .frames = self.frames };
}

const Vorbis = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    handle: *VorbisHandle,
    channels: usize,
    frames: ?u64,

    fn read(context: *anyopaque, out: []f32) Error!usize {
        const self: *Vorbis = @ptrCast(@alignCast(context));
        const wanted = @min(out.len / self.channels * self.channels, std.math.maxInt(c_int));
        if (wanted == 0) return 0;
        const frames = zg_vorbis_read(self.handle, @intCast(self.channels), out.ptr, @intCast(wanted));
        return @as(usize, @intCast(frames)) * self.channels;
    }

    fn setPosition(context: *anyopaque, frame: u64) Error!void {
        const self: *Vorbis = @ptrCast(@alignCast(context));
        if (self.frames) |frames| if (frame > frames) return error.OutOfRange;
        if (frame > std.math.maxInt(c_uint)) return error.OutOfRange;
        if (zg_vorbis_seek(self.handle, @intCast(frame)) == 0) return error.SeekFailed;
    }

    fn deinit(context: *anyopaque) void {
        const self: *Vorbis = @ptrCast(@alignCast(context));
        zg_vorbis_close(self.handle);
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    const vtable: Decoder.VTable = .{ .read = read, .setPosition = setPosition, .deinit = deinit };
};

/// Largest Ogg Vorbis input, which is copied into memory whole.
pub const vorbis_max_bytes = 512 * 1024 * 1024;

pub fn openVorbis(allocator: std.mem.Allocator, input: Input) Error!Decoder {
    const size = try input.size();
    if (size > vorbis_max_bytes) return error.UnsupportedEncoding;
    const data = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(data);
    try input.seekTo(0);
    if (try input.readAll(data) != data.len) return error.InvalidData;
    const self = try allocator.create(Vorbis);
    errdefer allocator.destroy(self);
    var code: c_int = 0;
    const handle = zg_vorbis_open(data.ptr, @intCast(data.len), &code) orelse return if (code == 3) error.OutOfMemory else error.InvalidData;
    var rate: c_int = 0;
    var channels: c_int = 0;
    var frames: c_uint = 0;
    zg_vorbis_info(handle, &rate, &channels, &frames);
    if (rate <= 0 or channels <= 0) {
        zg_vorbis_close(handle);
        return error.InvalidData;
    }
    self.* = .{ .allocator = allocator, .data = data, .handle = handle, .channels = @intCast(channels), .frames = if (frames > 0) frames else null };
    return .{ .context = self, .vtable = &Vorbis.vtable, .sample_rate = @intCast(rate), .channels = @intCast(zio.asUnsigned(channels)), .frames = self.frames };
}

/// The pinned third-party sources, checked against their recorded hashes.
const pinned = [_]struct { name: []const u8, bytes: []const u8, sha256: []const u8 }{
    .{ .name = "minimp3.h", .bytes = @embedFile("third_party/minimp3.h"), .sha256 = "5fb296a790734772b65a5514438cc06d14f24e539c13475ff2a7f737681c82c0" },
    .{ .name = "minimp3_ex.h", .bytes = @embedFile("third_party/minimp3_ex.h"), .sha256 = "bb001301b8666ea7a45ae057b62b17074483213b0d410555d97cc4d076e110df" },
    .{ .name = "stb_vorbis.c", .bytes = @embedFile("third_party/stb_vorbis.c"), .sha256 = "4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636" },
};

test "third-party decoders match their pinned hashes" {
    for (pinned) |file| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file.bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        std.testing.expectEqualStrings(file.sha256, &hex) catch |err| {
            std.debug.print("{s} changed\n", .{file.name});
            return err;
        };
    }
}

/// Reads everything, checking frames, a 440 Hz tone and exact seeks.
fn expectTone(bytes: []const u8, formats: []const decoding.Format, rate: u32, channels: u16, frames: u64) !void {
    const allocator = std.testing.allocator;
    var input = decoding.BytesInput{ .bytes = bytes };
    const opened = try decoding.open(allocator, input.input(), formats);
    const decoder = opened.decoder;
    defer decoder.deinit();
    try std.testing.expectEqual(rate, decoder.sample_rate);
    try std.testing.expectEqual(channels, decoder.channels);
    const total = decoder.frames orelse return error.NoLength;
    // Encoders pad: within a frame or two of the length encoded.
    try std.testing.expect(total >= frames and total <= frames + 2304);
    const all = try allocator.alloc(f32, @intCast(total * channels + 4096));
    defer allocator.free(all);
    var count: usize = 0;
    while (true) {
        const got = try decoder.read(all[count..@min(all.len, count + 1000 * channels + 1)]);
        if (got == 0) break;
        count += got;
    }
    try std.testing.expectEqual(total * channels, count);
    // Rising zero crossings of the first channel over the middle half second.
    var crossings: u32 = 0;
    const start = rate / 4;
    for (start..start + rate / 2) |frame| {
        if (all[(frame - 1) * channels] < 0 and all[frame * channels] >= 0) crossings += 1;
    }
    try std.testing.expect(crossings >= 218 and crossings <= 222);
    var peak: f32 = 0;
    for (all[0..count]) |sample| peak = @max(peak, @abs(sample));
    // The source tone peaks at 1/16; the MP3 one, upmixed from mono, at 1/16 times the square root of a half.
    try std.testing.expect(peak > 0.04 and peak < 0.07);
    for ([_]u64{ rate / 2, 1000, rate / 3, 0 }) |target| {
        try decoder.setPosition(target);
        var buffer: [64]f32 = undefined;
        const got = try decoder.read(&buffer);
        try std.testing.expectEqual(@as(usize, 64 / channels * channels), got);
        for (buffer[0..got], all[@intCast(target * channels)..][0..got]) |seeked, linear| try std.testing.expectApproxEqAbs(linear, seeked, 1e-3);
    }
    try std.testing.expectError(error.OutOfRange, decoder.setPosition(total + 1));
}

test "mp3 decodes a stereo tone, with exact seeks" {
    try expectTone(@embedFile("testdata/tone.mp3"), &mp3_formats, 44100, 2, 44100);
}

test "ogg vorbis decodes a mono tone, with exact seeks" {
    try expectTone(@embedFile("testdata/tone.ogg"), &.{vorbis_format}, 22050, 1, 22050);
}

test "corrupt mp3 and vorbis fail without leaks" {
    const allocator = std.testing.allocator;
    var garbage = decoding.BytesInput{ .bytes = "OggS but nothing after it" };
    try std.testing.expectError(error.InvalidData, openVorbis(allocator, garbage.input()));
    var noise: [4096]u8 = undefined;
    for (&noise, 0..) |*byte, index| byte.* = @truncate(index *% 7919);
    noise[0] = 0xff;
    noise[1] = 0xfb;
    var fake = decoding.BytesInput{ .bytes = &noise };
    if (openMp3(allocator, fake.input())) |decoder| {
        // A scan may find frames in noise; it must still read safely.
        defer decoder.deinit();
        var buffer: [1024]f32 = undefined;
        while ((decoder.read(&buffer) catch 0) != 0) {}
    } else |err| try std.testing.expect(err == error.InvalidData);
}

test "compressed formats open under every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var mp3 = decoding.BytesInput{ .bytes = @embedFile("testdata/tone.mp3") };
            const first = try openMp3(allocator, mp3.input());
            first.deinit();
            var ogg = decoding.BytesInput{ .bytes = @embedFile("testdata/tone.ogg") };
            const second = try openVorbis(allocator, ogg.input());
            second.deinit();
        }
    }.run, .{});
}
