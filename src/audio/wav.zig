const std = @import("std");
const zio = @import("ziggurat_io");
const decoding = @import("decoder.zig");
const Error = decoding.Error;
const Input = decoding.Input;
const Decoder = decoding.Decoder;

pub const format: decoding.Format = .{ .name = "wav", .magic = "RIFF????WAVE", .open = open };

/// Decodes WAV files of integer PCM of 8 to 32 bits, or of 32 or 64 bit
/// floats, including WAVE_FORMAT_EXTENSIBLE headers.
const Wav = struct {
    allocator: std.mem.Allocator,
    input: Input,
    channels: u16,
    bytes_per_sample: u8,
    float: bool,
    /// The data's offset.
    start: u64,
    frames: ?u64,
    /// The frame read next.
    position: u64 = 0,
    scratch: [4096]u8 = undefined,

    fn frameBytes(self: *const Wav) usize {
        return @as(usize, self.channels) * self.bytes_per_sample;
    }

    fn read(context: *anyopaque, out: []f32) Error!usize {
        const self: *Wav = @ptrCast(@alignCast(context));
        const frame_bytes = self.frameBytes();
        var wanted = out.len / self.channels;
        if (self.frames) |frames| wanted = @intCast(@min(@as(u64, wanted), frames - @min(frames, self.position)));
        var written: usize = 0;
        while (wanted > 0) {
            const chunk_frames = @min(wanted, self.scratch.len / frame_bytes);
            const bytes = self.scratch[0 .. chunk_frames * frame_bytes];
            const got = try self.input.readAll(bytes);
            const frames = got / frame_bytes;
            self.convert(bytes[0 .. frames * frame_bytes], out[written..][0 .. frames * self.channels]);
            written += frames * self.channels;
            self.position += frames;
            wanted -= frames;
            if (frames < chunk_frames) {
                // Cut short: the end is where the bytes end.
                if (self.frames != null) self.frames = self.position;
                break;
            }
        }
        return written;
    }

    fn convert(self: *const Wav, bytes: []const u8, out: []f32) void {
        const size = self.bytes_per_sample;
        for (out, 0..) |*sample, index| {
            const s = bytes[index * size ..][0..size];
            sample.* = if (self.float) switch (size) {
                4 => @bitCast(std.mem.readInt(u32, s[0..4], .little)),
                else => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, s[0..8], .little)))),
            } else switch (size) {
                1 => (@as(f32, @floatFromInt(s[0])) - 128) / 128,
                2 => @as(f32, @floatFromInt(std.mem.readInt(i16, s[0..2], .little))) / (1 << 15),
                3 => @as(f32, @floatFromInt(std.mem.readInt(i24, s[0..3], .little))) / (1 << 23),
                else => @as(f32, @floatFromInt(std.mem.readInt(i32, s[0..4], .little))) / (1 << 31),
            };
        }
    }

    fn setPosition(context: *anyopaque, frame: u64) Error!void {
        const self: *Wav = @ptrCast(@alignCast(context));
        if (self.frames) |frames| if (frame > frames) return error.OutOfRange;
        try self.input.seekTo(self.start + frame * self.frameBytes());
        self.position = frame;
    }

    fn deinit(context: *anyopaque) void {
        const self: *Wav = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }

    const vtable: Decoder.VTable = .{ .read = read, .setPosition = setPosition, .deinit = deinit };
};

pub fn open(allocator: std.mem.Allocator, input: Input) Error!Decoder {
    var riff: [12]u8 = undefined;
    if (try input.readAll(&riff) != riff.len) return error.InvalidData;
    var offset: u64 = 12;
    var fmt: ?struct { channels: u16, rate: u32, bytes: u8, float: bool } = null;
    while (true) {
        var header: [8]u8 = undefined;
        if (try input.readAll(&header) != header.len) return error.InvalidData;
        var size: u64 = std.mem.readInt(u32, header[4..8], .little);
        offset += 8;
        if (std.mem.eql(u8, header[0..4], "fmt ")) {
            if (size < 16 or size > 1 << 16) return error.InvalidData;
            var body: [64]u8 = undefined;
            const kept: usize = @intCast(@min(size, body.len));
            if (try input.readAll(body[0..kept]) != kept) return error.InvalidData;
            var tag = std.mem.readInt(u16, body[0..2], .little);
            const channels = std.mem.readInt(u16, body[2..4], .little);
            const rate = std.mem.readInt(u32, body[4..8], .little);
            const bits = std.mem.readInt(u16, body[14..16], .little);
            // WAVE_FORMAT_EXTENSIBLE: the tag starts the sub-format GUID.
            if (tag == 0xfffe and size >= 40) tag = std.mem.readInt(u16, body[24..26], .little);
            const float = switch (tag) {
                1 => if (bits >= 8 and bits <= 32 and bits % 8 == 0) false else return error.UnsupportedEncoding,
                3 => if (bits == 32 or bits == 64) true else return error.UnsupportedEncoding,
                else => return error.UnsupportedEncoding,
            };
            if (channels < 1 or rate < 1) return error.InvalidData;
            fmt = .{ .channels = channels, .rate = rate, .bytes = @intCast(bits / 8), .float = float };
        } else if (std.mem.eql(u8, header[0..4], "data")) {
            const found = fmt orelse return error.InvalidData;
            const frame_bytes = @as(u64, found.channels) * found.bytes;
            const self = try allocator.create(Wav);
            self.* = .{
                .allocator = allocator,
                .input = input,
                .channels = found.channels,
                .bytes_per_sample = found.bytes,
                .float = found.float,
                .start = offset,
                // Zero or all ones: written as it streamed, of no known length.
                .frames = if (size != 0 and size != 0xffff_ffff) size / frame_bytes else null,
            };
            try input.seekTo(offset);
            return .{ .context = self, .vtable = &Wav.vtable, .sample_rate = found.rate, .channels = found.channels, .frames = self.frames };
        }
        // Chunks are padded to even sizes.
        size += size & 1;
        offset += size;
        input.seekTo(offset) catch return error.InvalidData;
    }
}

fn wavBytes(buffer: []u8, tag: u16, bits: u16, channels: u16, data: []const u8) []u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const w = struct {
        fn int(out: *std.Io.Writer, comptime T: type, value: T) void {
            out.writeInt(T, value, .little) catch unreachable;
        }
    };
    writer.writeAll("RIFF") catch unreachable;
    w.int(&writer, u32, @intCast(36 + data.len + 10));
    writer.writeAll("WAVE") catch unreachable;
    // An odd chunk, padded, before the format.
    writer.writeAll("LIST") catch unreachable;
    w.int(&writer, u32, 1);
    writer.writeAll(&.{ 0, 0 }) catch unreachable;
    writer.writeAll("fmt ") catch unreachable;
    w.int(&writer, u32, 16);
    w.int(&writer, u16, tag);
    w.int(&writer, u16, channels);
    w.int(&writer, u32, 22050);
    w.int(&writer, u32, 22050 * @as(u32, channels) * bits / 8);
    w.int(&writer, u16, channels * bits / 8);
    w.int(&writer, u16, bits);
    writer.writeAll("data") catch unreachable;
    w.int(&writer, u32, @intCast(data.len));
    writer.writeAll(data) catch unreachable;
    return writer.buffered();
}

fn decodeAll(input: *decoding.BytesInput, out: []f32) !struct { decoder: Decoder, count: usize } {
    const decoder = try open(std.testing.allocator, input.input());
    errdefer decoder.deinit();
    const count = try decoder.read(out);
    return .{ .decoder = decoder, .count = count };
}

test "wav decodes every integer and float encoding" {
    var buffer: [256]u8 = undefined;
    var out: [8]f32 = undefined;
    const cases = [_]struct { tag: u16, bits: u16, data: []const u8, want: []const f32 }{
        .{ .tag = 1, .bits = 8, .data = &.{ 0, 128, 192 }, .want = &.{ -1, 0, 0.5 } },
        .{ .tag = 1, .bits = 16, .data = &.{ 0x00, 0x80, 0x00, 0x40 }, .want = &.{ -1, 0.5 } },
        .{ .tag = 1, .bits = 24, .data = &.{ 0x00, 0x00, 0xc0, 0x00, 0x00, 0x40 }, .want = &.{ -0.5, 0.5 } },
        .{ .tag = 1, .bits = 32, .data = &.{ 0x00, 0x00, 0x00, 0x40 }, .want = &.{0.5} },
        .{ .tag = 3, .bits = 32, .data = &.{ 0x00, 0x00, 0x80, 0xbe }, .want = &.{-0.25} },
        .{ .tag = 3, .bits = 64, .data = &.{ 0, 0, 0, 0, 0, 0, 0xd0, 0x3f }, .want = &.{0.25} },
    };
    for (cases) |case| {
        var input = decoding.BytesInput{ .bytes = wavBytes(&buffer, case.tag, case.bits, 1, case.data) };
        const result = try decodeAll(&input, &out);
        defer result.decoder.deinit();
        try std.testing.expectEqual(@as(u32, 22050), result.decoder.sample_rate);
        try std.testing.expectEqual(case.want.len, result.count);
        try std.testing.expectEqual(@as(?u64, case.want.len), result.decoder.frames);
        for (case.want, out[0..case.want.len]) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-6);
        try std.testing.expectEqual(@as(usize, 0), try result.decoder.read(&out));
    }
}

test "wav seeks by frame and reads stereo" {
    var buffer: [256]u8 = undefined;
    var data: [16]u8 = undefined;
    for (0..8) |index| std.mem.writeInt(i16, data[index * 2 ..][0..2], @intCast(@as(i32, @intCast(index)) * 1000), .little);
    var input = decoding.BytesInput{ .bytes = wavBytes(&buffer, 1, 16, 2, &data) };
    const decoder = try open(std.testing.allocator, input.input());
    defer decoder.deinit();
    try std.testing.expectEqual(@as(?u64, 4), decoder.frames);
    try decoder.setPosition(2);
    var out: [3]f32 = undefined;
    // A whole number of frames only.
    try std.testing.expectEqual(@as(usize, 2), try decoder.read(&out));
    try std.testing.expectApproxEqAbs(@as(f32, 4000.0 / 32768.0), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5000.0 / 32768.0), out[1], 1e-6);
    try std.testing.expectError(error.OutOfRange, decoder.setPosition(5));
    try decoder.setPosition(4);
    try std.testing.expectEqual(@as(usize, 0), try decoder.read(&out));
}

test "wav rejects other encodings and cut headers" {
    var buffer: [256]u8 = undefined;
    var out: [4]f32 = undefined;
    var adpcm = decoding.BytesInput{ .bytes = wavBytes(&buffer, 2, 4, 1, &.{ 1, 2 }) };
    try std.testing.expectError(error.UnsupportedEncoding, decodeAll(&adpcm, &out));
    var odd_bits = decoding.BytesInput{ .bytes = wavBytes(&buffer, 1, 12, 1, &.{ 1, 2 }) };
    try std.testing.expectError(error.UnsupportedEncoding, decodeAll(&odd_bits, &out));
    var cut = decoding.BytesInput{ .bytes = wavBytes(&buffer, 1, 16, 1, &.{ 1, 2 })[0..30] };
    try std.testing.expectError(error.InvalidData, decodeAll(&cut, &out));
}

test "wav of a cut data chunk ends where its bytes end" {
    var buffer: [256]u8 = undefined;
    const whole = wavBytes(&buffer, 1, 16, 1, &.{ 0, 0x40, 0, 0x40, 0, 0x40 });
    var out: [8]f32 = undefined;
    var input = decoding.BytesInput{ .bytes = whole[0 .. whole.len - 3] };
    const result = try decodeAll(&input, &out);
    defer result.decoder.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.count);
}
