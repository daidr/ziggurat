//! FLAC decoder in plain Zig: every subframe type, stereo decorrelation,
//! 4 to 32 bits per sample, header CRC-8 and frame CRC-16 checks, and
//! seeking by bisection over frame headers, so no seek table is needed.
const std = @import("std");
const zio = @import("ziggurat_io");
const decoding = @import("decoder.zig");
const Error = decoding.Error;
const Input = decoding.Input;
const Decoder = decoding.Decoder;
/// Internal: the input ending inside a frame is invalid data outside.
const ReadError = Error || error{EndOfStream};

pub const format: decoding.Format = .{ .name = "flac", .magic = "fLaC", .open = open };

const crc8_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, index| {
        var crc: u8 = @intCast(index);
        for (0..8) |_| crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
        entry.* = crc;
    }
    break :blk table;
};

const crc16_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u16 = undefined;
    for (&table, 0..) |*entry, index| {
        var crc: u16 = @as(u16, @intCast(index)) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
        entry.* = crc;
    }
    break :blk table;
};

/// Bits of an Input, most significant first, pulling bytes only as they are
/// needed so that CRCs cover exactly the bytes consumed.
const BitReader = struct {
    input: Input,
    buffer: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// Input offset of `buffer[end]`.
    offset: u64 = 0,
    bits: u64 = 0,
    count: u7 = 0,
    crc8: u8 = 0,
    crc16: u16 = 0,

    fn reset(self: *BitReader, offset: u64) ReadError!void {
        try self.input.seekTo(offset);
        self.start = 0;
        self.end = 0;
        self.offset = offset;
        self.bits = 0;
        self.count = 0;
    }

    /// Input offset of the next whole byte.
    fn byteOffset(self: *const BitReader) u64 {
        return self.offset - (self.end - self.start) - self.count / 8;
    }

    fn byte(self: *BitReader) ReadError!u8 {
        if (self.start == self.end) {
            const count = try self.input.read(&self.buffer);
            if (count == 0) return error.EndOfStream;
            self.offset += count;
            self.start = 0;
            self.end = count;
        }
        const value = self.buffer[self.start];
        self.start += 1;
        self.crc8 = crc8_table[self.crc8 ^ value];
        self.crc16 = (self.crc16 << 8) ^ crc16_table[@as(u8, @truncate(self.crc16 >> 8)) ^ value];
        return value;
    }

    fn beginCrc(self: *BitReader) void {
        std.debug.assert(self.count % 8 == 0);
        self.crc8 = 0;
        self.crc16 = 0;
    }

    fn fill(self: *BitReader, wanted: u7) ReadError!void {
        while (self.count < wanted) {
            self.bits = (self.bits << 8) | try self.byte();
            self.count += 8;
        }
    }

    /// Up to 32 bits, unsigned.
    fn read(self: *BitReader, n: u6) ReadError!u32 {
        if (n == 0) return 0;
        try self.fill(n);
        self.count -= n;
        const shifted = self.bits >> @intCast(self.count);
        return @truncate(shifted & ((@as(u64, 1) << n) - 1));
    }

    /// Up to 33 bits, two's complement.
    fn signed(self: *BitReader, n: u6) ReadError!i64 {
        if (n == 0) return 0;
        var value: u64 = undefined;
        if (n > 32) {
            value = (@as(u64, try self.read(n - 32)) << 32) | try self.read(32);
        } else value = try self.read(n);
        const shift: u6 = @intCast(64 - @as(u7, n));
        return @as(i64, @bitCast(value << shift)) >> shift;
    }

    /// Zeros before the next one bit, which is consumed.
    fn unary(self: *BitReader) ReadError!u32 {
        var zeros: u32 = 0;
        while (true) {
            if (self.count == 0) try self.fill(8);
            const live = self.bits & ((@as(u64, 1) << @intCast(self.count)) - 1);
            if (live == 0) {
                zeros += self.count;
                self.count = 0;
                if (zeros > 1 << 24) return error.InvalidData;
                continue;
            }
            const width: u7 = @intCast(64 - @clz(live));
            zeros += self.count - width;
            self.count = width - 1;
            return zeros;
        }
    }

    fn alignToByte(self: *BitReader) void {
        self.count -= self.count % 8;
    }
};

const Header = struct {
    block_size: u32,
    channels: u8,
    assignment: u4,
    bits: u6,
    first_sample: u64,
};

const Flac = struct {
    allocator: std.mem.Allocator,
    reader: BitReader,
    sample_rate: u32,
    channels: u8,
    bits: u6,
    total: ?u64,
    max_block: u32,
    first_frame: u64,
    /// Planar decoded samples of the current frame: channel c at
    /// `block[c * max_block ..]`.
    block: []i64,
    block_len: u32 = 0,
    block_pos: u32 = 0,
    /// The frame read next.
    position: u64 = 0,
    scale: f32,

    fn parseHeader(self: *Flac) ReadError!?Header {
        self.reader.beginCrc();
        const first = self.reader.byte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        const second = try self.reader.byte();
        if (first != 0xff or second & 0xfe != 0xf8) return error.InvalidData;
        const variable = second & 1 != 0;
        const sizes = try self.reader.byte();
        const layout = try self.reader.byte();
        var number: u64 = try self.reader.byte();
        // UTF-8 style coded number of up to 36 bits.
        const extra: u3 = switch (number) {
            0x00...0x7f => 0,
            0xc0...0xdf => 1,
            0xe0...0xef => 2,
            0xf0...0xf7 => 3,
            0xf8...0xfb => 4,
            0xfc...0xfd => 5,
            0xfe => 6,
            else => return error.InvalidData,
        };
        if (extra > 0) number &= (@as(u64, 0x7f) >> extra);
        for (0..extra) |_| {
            const next = try self.reader.byte();
            if (next & 0xc0 != 0x80) return error.InvalidData;
            number = (number << 6) | (next & 0x3f);
        }
        const block_size: u32 = switch (sizes >> 4) {
            0 => return error.InvalidData,
            1 => 192,
            2...5 => |code| @as(u32, 576) << @intCast(code - 2),
            6 => @as(u32, try self.reader.byte()) + 1,
            7 => (@as(u32, try self.reader.byte()) << 8 | try self.reader.byte()) + 1,
            else => |code| @as(u32, 256) << @intCast(code - 8),
        };
        const rate: u32 = switch (sizes & 0xf) {
            0 => self.sample_rate,
            1 => 88200,
            2 => 176400,
            3 => 192000,
            4 => 8000,
            5 => 16000,
            6 => 22050,
            7 => 24000,
            8 => 32000,
            9 => 44100,
            10 => 48000,
            11 => 96000,
            12 => @as(u32, try self.reader.byte()) * 1000,
            13 => @as(u32, try self.reader.byte()) << 8 | try self.reader.byte(),
            14 => (@as(u32, try self.reader.byte()) << 8 | try self.reader.byte()) * 10,
            else => return error.InvalidData,
        };
        const assignment: u4 = @intCast(layout >> 4);
        const channels: u8 = switch (assignment) {
            0...7 => @as(u8, assignment) + 1,
            8...10 => 2,
            else => return error.InvalidData,
        };
        const bits: u6 = switch ((layout >> 1) & 7) {
            0 => self.bits,
            1 => 8,
            2 => 12,
            4 => 16,
            5 => 20,
            6 => 24,
            7 => 32,
            else => return error.InvalidData,
        };
        if (layout & 1 != 0) return error.InvalidData;
        const crc = self.reader.crc8;
        if (try self.reader.byte() != crc) return error.InvalidData;
        // A stream keeps its format; a header changing it is no frame of it.
        if (rate != self.sample_rate or channels != self.channels or bits != self.bits or block_size > self.max_block) return error.InvalidData;
        return .{
            .block_size = block_size,
            .channels = channels,
            .assignment = assignment,
            .bits = bits,
            .first_sample = if (variable) number else number * self.max_block,
        };
    }

    /// Decodes the frame at the reader into `block`, or returns null at the
    /// end of the input.
    fn decodeFrame(self: *Flac) ReadError!?Header {
        const header = try self.parseHeader() orelse return null;
        const size = header.block_size;
        for (0..header.channels) |channel| {
            var bits = header.bits;
            switch (header.assignment) {
                8 => if (channel == 1) {
                    bits += 1;
                },
                9 => if (channel == 0) {
                    bits += 1;
                },
                10 => if (channel == 1) {
                    bits += 1;
                },
                else => {},
            }
            try self.decodeSubframe(self.block[channel * self.max_block ..][0..size], bits);
        }
        self.reader.alignToByte();
        const crc = self.reader.crc16;
        if (try self.reader.read(16) != crc) return error.InvalidData;
        const left = self.block[0..size];
        const right = if (header.channels > 1) self.block[self.max_block..][0..size] else left;
        switch (header.assignment) {
            8 => for (left, right) |l, *r| {
                r.* = l -% r.*;
            },
            9 => for (left, right) |*l, r| {
                l.* +%= r;
            },
            10 => for (left, right) |*l, *r| {
                const mid = (l.* *% 2) | (r.* & 1);
                const side = r.*;
                l.* = (mid +% side) >> 1;
                r.* = (mid -% side) >> 1;
            },
            else => {},
        }
        return header;
    }

    fn decodeSubframe(self: *Flac, out: []i64, sample_bits: u7) ReadError!void {
        if (try self.reader.read(1) != 0) return error.InvalidData;
        const kind = try self.reader.read(6);
        var wasted: u7 = 0;
        if (try self.reader.read(1) != 0) {
            const zeros = try self.reader.unary();
            if (zeros + 1 >= sample_bits) return error.InvalidData;
            wasted = @intCast(zeros + 1);
        }
        if (sample_bits > 33) return error.InvalidData;
        const bits: u6 = @intCast(sample_bits - wasted);
        switch (kind) {
            0 => @memset(out, try self.reader.signed(bits)),
            1 => for (out) |*sample| {
                sample.* = try self.reader.signed(bits);
            },
            8...12 => {
                const order = kind - 8;
                if (order > out.len) return error.InvalidData;
                for (out[0..order]) |*sample| sample.* = try self.reader.signed(bits);
                try self.residual(out, order);
                fixedPredict(out, order);
            },
            32...63 => {
                const order = kind - 31;
                if (order > out.len) return error.InvalidData;
                for (out[0..order]) |*sample| sample.* = try self.reader.signed(bits);
                const precision = try self.reader.read(4) + 1;
                if (precision == 16) return error.InvalidData;
                const shift_bits = try self.reader.signed(5);
                if (shift_bits < 0) return error.InvalidData;
                var coefficients: [32]i64 = undefined;
                for (coefficients[0..order]) |*coefficient| coefficient.* = try self.reader.signed(@intCast(precision));
                try self.residual(out, order);
                lpcPredict(out, coefficients[0..order], @intCast(shift_bits));
            },
            else => return error.InvalidData,
        }
        if (wasted > 0) for (out) |*sample| {
            sample.* *%= @as(i64, 1) << @intCast(wasted);
        };
    }

    fn residual(self: *Flac, out: []i64, order: usize) ReadError!void {
        const method = try self.reader.read(2);
        if (method > 1) return error.InvalidData;
        const parameter_bits: u6 = if (method == 0) 4 else 5;
        const escape: u32 = if (method == 0) 15 else 31;
        const partition_order: u5 = @intCast(try self.reader.read(4));
        const partitions = @as(usize, 1) << partition_order;
        if (out.len % partitions != 0) return error.InvalidData;
        const per = out.len >> partition_order;
        if (per < order) return error.InvalidData;
        var index: usize = order;
        for (0..partitions) |partition| {
            const end = (partition + 1) * per;
            const parameter = try self.reader.read(parameter_bits);
            if (parameter == escape) {
                const raw: u6 = @intCast(try self.reader.read(5));
                while (index < end) : (index += 1) out[index] = try self.reader.signed(raw);
                continue;
            }
            const k: u6 = @intCast(parameter);
            while (index < end) : (index += 1) {
                const high: u64 = try self.reader.unary();
                const value = (high << k) | try self.reader.read(k);
                out[index] = @as(i64, @intCast(value >> 1)) ^ -@as(i64, @intCast(value & 1));
            }
        }
    }

    fn fixedPredict(out: []i64, order: usize) void {
        var index = order;
        while (index < out.len) : (index += 1) {
            const s = out;
            const i = index;
            s[i] +%= switch (order) {
                0 => 0,
                1 => s[i - 1],
                2 => 2 *% s[i - 1] -% s[i - 2],
                3 => 3 *% s[i - 1] -% 3 *% s[i - 2] +% s[i - 3],
                else => 4 *% s[i - 1] -% 6 *% s[i - 2] +% 4 *% s[i - 3] -% s[i - 4],
            };
        }
    }

    fn lpcPredict(out: []i64, coefficients: []const i64, shift: u6) void {
        var index = coefficients.len;
        while (index < out.len) : (index += 1) {
            var sum: i64 = 0;
            for (coefficients, 1..) |coefficient, back| sum +%= coefficient *% out[index - back];
            out[index] +%= sum >> shift;
        }
    }

    fn read(context: *anyopaque, out: []f32) Error!usize {
        const self: *Flac = @ptrCast(@alignCast(context));
        return self.readFrames(out) catch |err| switch (err) {
            error.EndOfStream => error.InvalidData,
            else => |other| other,
        };
    }

    fn readFrames(self: *Flac, out: []f32) ReadError!usize {
        const frames = out.len / self.channels;
        var written: usize = 0;
        while (written < frames) {
            if (self.block_pos == self.block_len) {
                if (self.total) |total| if (self.position >= total) break;
                const header = try self.decodeFrame() orelse break;
                self.block_len = header.block_size;
                self.block_pos = 0;
            }
            const count = @min(frames - written, self.block_len - self.block_pos);
            for (0..count) |frame| {
                for (0..self.channels) |channel| {
                    const sample = self.block[channel * self.max_block + self.block_pos + frame];
                    out[(written + frame) * self.channels + channel] = @as(f32, @floatFromInt(sample)) * self.scale;
                }
            }
            self.block_pos += @intCast(count);
            written += count;
            self.position += count;
        }
        if (self.total) |total| if (self.position > total) {
            // A last frame longer than the stream says: drop the rest.
            const over: usize = @intCast(@min(self.position - total, written));
            written -= over;
            self.position = total;
        };
        return written * self.channels;
    }

    /// The next valid frame at or after `offset`, verified by both CRCs,
    /// decoded into `block`.
    fn findFrame(self: *Flac, offset: u64, limit: u64) ReadError!?struct { offset: u64, header: Header } {
        var at = offset;
        while (at < limit) {
            try self.reader.reset(at);
            // Scan for a sync code.
            const start = while (true) {
                const here = self.reader.byteOffset();
                if (here >= limit) return null;
                const value = self.reader.byte() catch |err| switch (err) {
                    error.EndOfStream => return null,
                    else => return err,
                };
                if (value == 0xff) break here;
            };
            try self.reader.reset(start);
            if (self.decodeFrame()) |found| {
                if (found) |header| return .{ .offset = start, .header = header };
                return null;
            } else |err| switch (err) {
                error.InvalidData, error.EndOfStream => {},
                else => return err,
            }
            at = start + 1;
        }
        return null;
    }

    fn setPosition(context: *anyopaque, target: u64) Error!void {
        const self: *Flac = @ptrCast(@alignCast(context));
        self.block_len = 0;
        self.block_pos = 0;
        if (self.total) |total| {
            if (target > total) return error.OutOfRange;
            if (target == total) {
                self.position = total;
                return;
            }
        }
        self.seek(target) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidData,
            else => |other| return other,
        };
    }

    fn seek(self: *Flac, target: u64) ReadError!void {
        const size = try self.reader.input.size();
        var best_offset = self.first_frame;
        var low = self.first_frame;
        var high = size;
        while (high - low > 4096) {
            const middle = low + (high - low) / 2;
            const found = try self.findFrame(middle, high) orelse {
                high = middle;
                continue;
            };
            if (found.header.first_sample > target) {
                high = middle;
            } else {
                best_offset = found.offset;
                low = found.offset + 1;
            }
        }
        try self.reader.reset(best_offset);
        while (true) {
            const header = try self.decodeFrame() orelse {
                // Past the end of a stream of no known length.
                self.position = target;
                return;
            };
            if (target < header.first_sample) return error.InvalidData;
            if (target - header.first_sample < header.block_size) {
                self.block_len = header.block_size;
                self.block_pos = @intCast(target - header.first_sample);
                self.position = target;
                return;
            }
        }
    }

    fn deinit(context: *anyopaque) void {
        const self: *Flac = @ptrCast(@alignCast(context));
        self.allocator.free(self.block);
        self.allocator.destroy(self);
    }

    const vtable: Decoder.VTable = .{ .read = read, .setPosition = setPosition, .deinit = deinit };
};

pub fn open(allocator: std.mem.Allocator, input: Input) Error!Decoder {
    var head: [4]u8 = undefined;
    if (try input.readAll(&head) != 4 or !std.mem.eql(u8, &head, "fLaC")) return error.InvalidData;
    var offset: u64 = 4;
    var info: ?[34]u8 = null;
    while (true) {
        var block_header: [4]u8 = undefined;
        if (try input.readAll(&block_header) != 4) return error.InvalidData;
        const last = block_header[0] & 0x80 != 0;
        const kind = block_header[0] & 0x7f;
        const size = std.mem.readInt(u24, block_header[1..4], .big);
        offset += 4;
        if (kind == 0) {
            if (size != 34 or info != null) return error.InvalidData;
            var bytes: [34]u8 = undefined;
            if (try input.readAll(&bytes) != 34) return error.InvalidData;
            info = bytes;
        } else if (kind == 127) return error.InvalidData;
        offset += size;
        input.seekTo(offset) catch return error.InvalidData;
        if (last) break;
    }
    const bytes = info orelse return error.InvalidData;
    const max_block = std.mem.readInt(u16, bytes[2..4], .big);
    const packed_format = std.mem.readInt(u64, bytes[10..18], .big);
    const rate: u32 = @intCast(packed_format >> 44);
    const channels: u8 = @intCast((packed_format >> 41 & 7) + 1);
    const bits: u6 = @intCast((packed_format >> 36 & 31) + 1);
    const total = packed_format & 0xf_ffff_ffff;
    if (rate == 0 or max_block < 16 or bits < 4) return error.InvalidData;
    const self = try allocator.create(Flac);
    errdefer allocator.destroy(self);
    const block = try allocator.alloc(i64, @as(usize, channels) * max_block);
    self.* = .{
        .allocator = allocator,
        .reader = .{ .input = input, .offset = offset },
        .sample_rate = rate,
        .channels = channels,
        .bits = bits,
        .total = if (total == 0) null else total,
        .max_block = max_block,
        .first_frame = offset,
        .block = block,
        .scale = 1.0 / @as(f32, @floatFromInt(@as(u64, 1) << (bits - 1))),
    };
    return .{ .context = self, .vtable = &Flac.vtable, .sample_rate = rate, .channels = channels, .frames = self.total };
}

/// The integer signal the test files were encoded from: silence, a
/// correlated sawtooth with noise, white noise, then samples with wasted bits.
fn expectedFrame(index: usize, bits: u6, state: *u64) [2]i64 {
    const full = @as(i64, 1) << (bits - 1);
    const i: i64 = @intCast(index);
    state.* = lcg(state.*);
    const noise = @mod(@as(i64, @intCast(state.* >> 16)), 64) - 32;
    if (index < 3000) return .{ 0, 0 };
    if (index < 8000) {
        const left = (@mod(i * 37, 2000) - 1000) * @divFloor(full, 2048) + noise;
        return .{ left, @divFloor(left * 3, 4) + noise };
    }
    if (index < 10000) {
        const left = @mod(@as(i64, @intCast(state.* >> 8)), 2 * full) - full;
        state.* = lcg(state.*);
        return .{ left, @mod(@as(i64, @intCast(state.* >> 8)), 2 * full) - full };
    }
    const left = @divFloor((@mod(i * 13, 1000) - 500) * @divFloor(full, 1024), 8) * 8;
    return .{ left, -left };
}

fn lcg(value: u64) u64 {
    return (value *% 1103515245 +% 12345) % (1 << 31);
}

fn expectFile(bytes: []const u8, rate: u32, channels: u16, bits: u6) !void {
    var input = decoding.BytesInput{ .bytes = bytes };
    const decoder = try open(std.testing.allocator, input.input());
    defer decoder.deinit();
    try std.testing.expectEqual(rate, decoder.sample_rate);
    try std.testing.expectEqual(channels, decoder.channels);
    try std.testing.expectEqual(@as(?u64, 12000), decoder.frames);
    const scale = 1.0 / @as(f32, @floatFromInt(@as(u64, 1) << (bits - 1)));
    var expected: [12000][2]f32 = undefined;
    var state: u64 = 1;
    for (&expected, 0..) |*frame, index| {
        const ints = expectedFrame(index, bits, &state);
        frame.* = .{ @as(f32, @floatFromInt(ints[0])) * scale, @as(f32, @floatFromInt(ints[1])) * scale };
    }
    // Reads of odd sizes cross frame boundaries.
    var buffer: [1234]f32 = undefined;
    var frame: usize = 0;
    while (true) {
        const count = try decoder.read(&buffer);
        if (count == 0) break;
        try std.testing.expect(count % channels == 0);
        for (0..count / channels) |offset| {
            for (0..channels) |channel| try std.testing.expectEqual(expected[frame + offset][channel], buffer[offset * channels + channel]);
        }
        frame += count / channels;
    }
    try std.testing.expectEqual(@as(usize, 12000), frame);
    // Seeks land on the frame asked for, backwards and forwards.
    for ([_]u64{ 11999, 0, 4607, 4608, 9000, 3001, 12000, 7777 }) |target| {
        try decoder.setPosition(target);
        const count = try decoder.read(buffer[0 .. 10 * channels]);
        const want = @min(10, 12000 - target);
        try std.testing.expectEqual(want * channels, count);
        for (0..want) |offset| {
            for (0..channels) |channel| try std.testing.expectEqual(expected[target + offset][channel], buffer[offset * channels + channel]);
        }
    }
    try std.testing.expectError(error.OutOfRange, decoder.setPosition(12001));
}

test "flac decodes stereo 16-bit and mono 24-bit files exactly and seeks" {
    try expectFile(@embedFile("testdata/stereo16.flac"), 44100, 2, 16);
    try expectFile(@embedFile("testdata/mono24.flac"), 48000, 1, 24);
}

test "flac rejects corrupt frames and headers" {
    const original = @embedFile("testdata/stereo16.flac");
    var copy: [original.len]u8 = original.*;
    copy[copy.len / 2] ^= 0x10;
    var input = decoding.BytesInput{ .bytes = &copy };
    const decoder = try open(std.testing.allocator, input.input());
    defer decoder.deinit();
    var buffer: [4096]f32 = undefined;
    const failed = while (true) {
        const count = decoder.read(&buffer) catch |err| break err;
        if (count == 0) break error.NoError;
    };
    try std.testing.expectEqual(error.InvalidData, failed);
    var cut = decoding.BytesInput{ .bytes = original[0..20] };
    try std.testing.expectError(error.InvalidData, open(std.testing.allocator, cut.input()));
    var truncated = decoding.BytesInput{ .bytes = original[0 .. original.len - 100] };
    const short = try open(std.testing.allocator, truncated.input());
    defer short.deinit();
    const ended = while (true) {
        const count = short.read(&buffer) catch |err| break err;
        if (count == 0) break error.NoError;
    };
    try std.testing.expectEqual(error.InvalidData, ended);
}

test "flac decodes under every allocation failure without leaks" {
    const bytes = @embedFile("testdata/mono24.flac");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, data: []const u8) !void {
            var input = decoding.BytesInput{ .bytes = data };
            const decoder = try open(allocator, input.input());
            defer decoder.deinit();
            var buffer: [256]f32 = undefined;
            _ = try decoder.read(&buffer);
        }
    }.run, .{bytes});
}
