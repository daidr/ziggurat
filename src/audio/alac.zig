//! Apple Lossless (ALAC) packets, as an MP4 holds them: each a frame of up
//! to the configured samples a channel, coded adaptively, Golomb-Rice
//! fashion, then predicted from the samples before. Of more than two
//! channels, the front left and right play.
const std = @import("std");
const decoding = @import("decoder.zig");
const mp4 = @import("mp4.zig");
const Error = decoding.Error;

/// The elements of a packet, as AAC's.
const single = 0;
const pair = 1;
const low_frequency = 3;
const data = 4;
const fill = 6;
const end = 7;

/// The adaptive coder's constants.
const qb_shift = 9;
const qb = 1 << qb_shift;
const m_mul_shift = 2;
const m_den_shift = qb_shift - m_mul_shift - 1;
const m_off = 1 << (m_den_shift - 2);
const bit_off = 24;
const max_prefix = 9;

const Alac = struct {
    allocator: std.mem.Allocator,
    frame_length: u32,
    bit_depth: u8,
    pb: u8,
    mb: u8,
    kb: u8,
    channels: u8,
    rate: u32,
    /// The channels of the front pair, of ALAC's layouts.
    left_channel: u8,
    right_channel: u8,
    scale: f32,
    /// Buffers of `frame_length` each, and of twice it for `shift`.
    predictor: []i32,
    u: []i32,
    v: []i32,
    left: []i32,
    right: []i32,
    shift: []u16,

    fn decode(context: *anyopaque, packet: []const u8, out: []f32) Error!usize {
        const self: *Alac = @ptrCast(@alignCast(context));
        var bits: Bits = .{ .data = packet };
        var channel: usize = 0;
        var samples: ?u32 = null;
        while (true) {
            const tag = try bits.read(3);
            switch (tag) {
                single, low_frequency, pair => {
                    if (channel >= self.channels) return error.InvalidData;
                    const count = try self.element(&bits, tag == pair, channel);
                    if (samples) |known| if (known != count) return error.InvalidData;
                    samples = count;
                    channel += if (tag == pair) 2 else 1;
                },
                data => {
                    _ = try bits.read(4);
                    const aligned = try bits.read(1);
                    var count: usize = try bits.read(8);
                    if (count == 255) count += try bits.read(8);
                    if (aligned != 0) bits.alignToByte();
                    try bits.skip(count * 8);
                },
                fill => {
                    var count: usize = try bits.read(4);
                    if (count == 15) count += @as(usize, try bits.read(8)) - 1;
                    try bits.skip(count * 8);
                },
                end => break,
                else => return error.UnsupportedEncoding,
            }
            // Every channel decoded: an END element follows, but some
            // encoders leave it out.
            if (channel >= self.channels) break;
        }
        const count = samples orelse return error.InvalidData;
        const output: usize = if (self.channels == 1) 1 else 2;
        for (0..count) |index| {
            out[index * output] = @as(f32, @floatFromInt(self.left[index])) * self.scale;
            if (output == 2) out[index * 2 + 1] = @as(f32, @floatFromInt(self.right[index])) * self.scale;
        }
        return count;
    }

    /// Decodes a single channel, or a pair, as channel `channel` on, and
    /// keeps what of it plays. Returns its samples a channel.
    fn element(self: *Alac, bits: *Bits, is_pair: bool, channel: usize) Error!u32 {
        _ = try bits.read(4); // its instance
        if (try bits.read(12) != 0) return error.InvalidData;
        const header = try bits.read(4);
        const partial = header >> 3 != 0;
        var shifted: u32 = header >> 1 & 3;
        const escape = header & 1 != 0;
        if (shifted == 3) return error.InvalidData;
        var count = self.frame_length;
        if (partial) {
            count = try bits.read(32);
            if (count == 0 or count > self.frame_length) return error.InvalidData;
        }
        var channel_bits: u32 = self.bit_depth - shifted * 8;
        if (is_pair) channel_bits += 1;
        if (channel_bits > 32) return error.InvalidData;
        const u = self.u[0..count];
        const v = self.v[0..count];
        var mix_bits: u5 = 0;
        var mix_res: i32 = 0;
        if (!escape) {
            mix_bits = @intCast(@min(try bits.read(8), 31));
            mix_res = @as(i8, @bitCast(@as(u8, @intCast(try bits.read(8)))));
            var coefficients_u: [32]i16 = undefined;
            var coefficients_v: [32]i16 = undefined;
            const predictor_u = try predictorHeader(bits, &coefficients_u);
            const predictor_v = if (is_pair) try predictorHeader(bits, &coefficients_v) else predictor_u;
            var shift_bits: Bits = undefined;
            if (shifted != 0) {
                shift_bits = bits.*;
                try bits.skip(shifted * 8 * @as(usize, if (is_pair) 2 else 1) * count);
            }
            try self.channelSamples(bits, u, predictor_u, coefficients_u[0..predictor_u.count], channel_bits);
            if (is_pair) try self.channelSamples(bits, v, predictor_v, coefficients_v[0..predictor_v.count], channel_bits);
            if (shifted != 0) {
                const width: u6 = @intCast(shifted * 8);
                const ways: usize = if (is_pair) 2 else 1;
                for (0..count * ways) |index| self.shift[index] = @intCast(try shift_bits.read(width));
            }
        } else {
            // Uncompressed, and never shifted.
            shifted = 0;
            channel_bits = self.bit_depth;
            for (0..count) |index| {
                u[index] = try bits.signed(@intCast(channel_bits));
                if (is_pair) v[index] = try bits.signed(@intCast(channel_bits));
            }
        }
        const width: u5 = @intCast(shifted * 8);
        if (!is_pair) {
            if (shifted != 0) for (u, 0..) |*sample, index| {
                sample.* = (sample.* << width) | self.shift[index];
            };
            self.keep(channel, u);
            return count;
        }
        for (u, v, 0..) |*l, *r, index| {
            var left = l.*;
            var right = r.*;
            if (mix_res != 0) {
                left = l.* +% r.* -% ((mix_res *% r.*) >> mix_bits);
                right = left -% r.*;
            }
            if (shifted != 0) {
                left = (left << width) | self.shift[2 * index];
                right = (right << width) | self.shift[2 * index + 1];
            }
            l.* = left;
            r.* = right;
        }
        self.keep(channel, u);
        self.keep(channel + 1, v);
        return count;
    }

    fn keep(self: *Alac, channel: usize, samples: []const i32) void {
        if (channel == self.left_channel) @memcpy(self.left[0..samples.len], samples);
        if (channel == self.right_channel) @memcpy(self.right[0..samples.len], samples);
    }

    /// Decodes a channel's residues, and predicts its samples from them.
    fn channelSamples(self: *Alac, bits: *Bits, out: []i32, predictor: Predictor, coefficients: []i16, channel_bits: u32) Error!void {
        const residues = self.predictor[0..out.len];
        try self.decodeResidues(bits, residues, @as(u32, self.pb) * predictor.factor / 4, channel_bits);
        if (predictor.mode != 0) unpredict(residues, residues, &.{}, 31, channel_bits, 0);
        unpredict(residues, out, coefficients, coefficients.len, channel_bits, predictor.shift);
    }

    /// Decodes residues, adapting the code to their mean as it goes, with
    /// runs of zeros coded apart where it's small.
    fn decodeResidues(self: *Alac, bits: *Bits, out: []i32, pb: u32, max_bits: u32) Error!void {
        var mb: u32 = self.mb;
        const kb: u32 = self.kb;
        const wb: u32 = (@as(u32, 1) << @intCast(kb)) - 1;
        var zmode: u32 = 0;
        var index: usize = 0;
        while (index < out.len) {
            if (bits.left() == 0) return error.InvalidData;
            const mean = mb >> qb_shift;
            const k: u32 = @min(31 - @clz(mean + 3), kb);
            const m = (@as(u32, 1) << @intCast(k)) - 1;
            const n = try bits.golomb(m, k, max_bits);
            const coded = n +% zmode;
            const magnitude: i32 = @bitCast((coded +% 1) >> 1);
            out[index] = if (coded & 1 != 0) -%magnitude else magnitude;
            index += 1;
            mb = pb *% coded +% mb -% ((pb *% mb) >> qb_shift);
            if (n > 0xffff) mb = 0xffff;
            zmode = 0;
            if ((mb << m_mul_shift) < qb and index < out.len) {
                zmode = 1;
                const zk: u32 = @as(u32, @clz(mb)) -% bit_off +% ((mb + m_off) >> m_den_shift);
                if (zk > 31) return error.InvalidData;
                const mz = ((@as(u32, 1) << @intCast(zk)) - 1) & wb;
                const zeros = try bits.golomb(mz, zk, 16);
                if (index + zeros > out.len) return error.InvalidData;
                @memset(out[index..][0..zeros], 0);
                index += zeros;
                if (zeros >= 0xffff) zmode = 0;
                mb = 0;
            }
        }
    }

    fn reset(_: *anyopaque) void {}

    fn deinit(context: *anyopaque) void {
        const self: *Alac = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        allocator.free(self.predictor);
        allocator.free(self.u);
        allocator.free(self.v);
        allocator.free(self.left);
        allocator.free(self.right);
        allocator.free(self.shift);
        allocator.destroy(self);
    }

    const vtable: mp4.Codec.VTable = .{ .decode = decode, .reset = reset, .deinit = deinit };
};

const Predictor = struct { mode: u32, shift: u32, factor: u32, count: usize };

fn predictorHeader(bits: *Bits, coefficients: *[32]i16) Error!Predictor {
    const first = try bits.read(8);
    const second = try bits.read(8);
    const count: usize = second & 31;
    for (coefficients[0..count]) |*coefficient| coefficient.* = @bitCast(@as(u16, @intCast(try bits.read(16))));
    return .{ .mode = first >> 4, .shift = first & 15, .factor = second >> 5, .count = count };
}

fn sign(value: i32) i32 {
    return if (value > 0) 1 else if (value < 0) -1 else 0;
}

/// Undoes the adaptive linear prediction of `active` coefficients on
/// `residues` into `out`, which may be the same: with 31 the first-order
/// one.
fn unpredict(residues: []const i32, out: []i32, coefficients: []i16, active: usize, channel_bits: u32, shift: u32) void {
    const count = out.len;
    if (count == 0) return;
    const extend: u5 = @intCast(32 - channel_bits);
    out[0] = residues[0];
    if (active == 0) {
        @memcpy(out[1..count], residues[1..count]);
        return;
    }
    if (active == 31) {
        var previous = out[0];
        for (1..count) |j| {
            previous = ((residues[j] +% previous) << extend) >> extend;
            out[j] = previous;
        }
        return;
    }
    var j: usize = 1;
    while (j <= active and j < count) : (j += 1) out[j] = ((residues[j] +% out[j - 1]) << extend) >> extend;
    const den: u5 = @intCast(shift);
    const half: i32 = if (shift > 0) @as(i32, 1) << (den - 1) else 0;
    j = active + 1;
    while (j < count) : (j += 1) {
        const top = out[j - active - 1];
        var sum: i32 = 0;
        for (0..active) |k| sum +%= @as(i32, coefficients[k]) *% (out[j - 1 - k] -% top);
        var delta = residues[j];
        var remaining = delta;
        const direction = sign(delta);
        delta +%= top +% ((sum +% half) >> den);
        out[j] = (delta << extend) >> extend;
        if (direction > 0) {
            var k = active;
            while (k > 0) {
                k -= 1;
                const difference = top -% out[j - 1 - k];
                const s = sign(difference);
                coefficients[k] -%= @intCast(s);
                remaining -%= @as(i32, @intCast(active - k)) *% ((s *% difference) >> den);
                if (remaining <= 0) break;
            }
        } else if (direction < 0) {
            var k = active;
            while (k > 0) {
                k -= 1;
                const difference = top -% out[j - 1 - k];
                const s = sign(difference);
                coefficients[k] +%= @intCast(s);
                remaining -%= @as(i32, @intCast(active - k)) *% ((-%s *% difference) >> den);
                if (remaining >= 0) break;
            }
        }
    }
}

/// Bits of a packet, most significant first.
const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    fn left(self: Bits) usize {
        return self.data.len * 8 -| self.pos;
    }

    /// Up to 32 bits at `pos`, zeros past the end.
    fn peek(self: Bits, pos: usize, count: u6) u32 {
        if (count == 0) return 0;
        const byte = pos >> 3;
        var value: u64 = 0;
        for (0..8) |index| {
            value <<= 8;
            if (byte + index < self.data.len) value |= self.data[byte + index];
        }
        const shift: u6 = @intCast(64 - (pos & 7) - count);
        return @intCast((value >> shift) & ((@as(u64, 1) << count) - 1));
    }

    fn read(self: *Bits, count: u6) Error!u32 {
        if (count > self.left()) return error.InvalidData;
        const value = self.peek(self.pos, count);
        self.pos += count;
        return value;
    }

    fn signed(self: *Bits, count: u6) Error!i32 {
        const value = try self.read(count);
        if (count == 0) return 0;
        const extend: u5 = @intCast(32 - @as(u32, count));
        return @as(i32, @bitCast(value << extend)) >> extend;
    }

    fn skip(self: *Bits, count: usize) Error!void {
        if (count > self.left()) return error.InvalidData;
        self.pos += count;
    }

    fn alignToByte(self: *Bits) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }

    /// A unary prefix, then `k` bits, or else, after `max_prefix` ones,
    /// the value in `escape_bits`.
    fn golomb(self: *Bits, m: u32, k: u32, escape_bits: u32) Error!u32 {
        if (self.pos >= self.data.len * 8) return error.InvalidData;
        const word = self.peek(self.pos, 32);
        const prefix: u32 = @clz(~word);
        if (prefix >= max_prefix) {
            const value = self.peek(self.pos + max_prefix, @intCast(escape_bits));
            self.pos += max_prefix + escape_bits;
            if (self.pos > self.data.len * 8) return error.InvalidData;
            return value;
        }
        self.pos += prefix + 1;
        if (k <= 1) return prefix;
        const value = (word << @intCast(prefix + 1)) >> @intCast(32 - k);
        self.pos += k - 1;
        var result = prefix *% m;
        if (value >= 2) {
            result +%= value - 1;
            self.pos += 1;
        }
        if (self.pos > self.data.len * 8) return error.InvalidData;
        return result;
    }
};

/// The codec of ALAC packets configured by `cookie`, its magic cookie: an
/// ALACSpecificConfig, after 'frma' and 'alac' atoms in QuickTime's kind.
pub fn openCodec(allocator: std.mem.Allocator, cookie: []const u8) Error!mp4.Codec {
    var config = cookie;
    while (config.len >= 12 and (std.mem.eql(u8, config[4..8], "frma") or std.mem.eql(u8, config[4..8], "alac"))) config = config[12..];
    if (config.len < 24) return error.InvalidData;
    const frame_length = std.mem.readInt(u32, config[0..4], .big);
    const bit_depth = config[5];
    const channels = config[9];
    if (config[4] != 0) return error.UnsupportedEncoding;
    if (frame_length == 0 or frame_length > 1 << 16) return error.InvalidData;
    if (bit_depth != 16 and bit_depth != 20 and bit_depth != 24 and bit_depth != 32) return error.InvalidData;
    if (channels == 0 or channels > 8 or config[8] == 0 or config[8] > 30) return error.InvalidData;
    const rate = std.mem.readInt(u32, config[20..24], .big);
    if (rate == 0) return error.InvalidData;
    const self = try allocator.create(Alac);
    errdefer allocator.destroy(self);
    var buffers: [5][]i32 = undefined;
    var made: usize = 0;
    errdefer for (buffers[0..made]) |buffer| allocator.free(buffer);
    for (&buffers) |*buffer| {
        buffer.* = try allocator.alloc(i32, frame_length);
        made += 1;
    }
    const shift = try allocator.alloc(u16, 2 * @as(usize, frame_length));
    // The front left and right: C L R first of three to seven channels,
    // and C Lc Rc L R of eight.
    const front: [2]u8 = switch (channels) {
        1 => .{ 0, 0 },
        2 => .{ 0, 1 },
        8 => .{ 3, 4 },
        else => .{ 1, 2 },
    };
    self.* = .{
        .allocator = allocator,
        .frame_length = frame_length,
        .bit_depth = bit_depth,
        .pb = config[6],
        .mb = config[7],
        .kb = config[8],
        .channels = channels,
        .rate = rate,
        .left_channel = front[0],
        .right_channel = front[1],
        .scale = 1.0 / @as(f32, @floatFromInt(@as(u64, 1) << @intCast(bit_depth - 1))),
        .predictor = buffers[0],
        .u = buffers[1],
        .v = buffers[2],
        .left = buffers[3],
        .right = buffers[4],
        .shift = shift,
    };
    return .{ .context = self, .vtable = &Alac.vtable, .sample_rate = rate, .channels = if (channels == 1) 1 else 2, .max_frames = frame_length };
}
