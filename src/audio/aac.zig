//! AAC-LC, the AAC of nearly every .m4a and .aac: raw packets as an MP4
//! holds them, through `mp4`, and ADTS frames as an .aac file is. Each
//! packet decodes to 1024 frames, from its spectrum and the half of the one
//! before that overlaps it. HE-AAC (SBR) and its parametric stereo are not
//! decoded: a stream signalling them fails to open with
//! `error.UnsupportedEncoding`. Of more than two channels, the front left
//! and right play.
const std = @import("std");
const zio = @import("ziggurat_io");
const decoding = @import("decoder.zig");
const tables = @import("aac_tables.zig");
const Error = decoding.Error;
const Input = decoding.Input;
const Decoder = decoding.Decoder;

/// Frames each packet decodes to.
pub const frame_length = 1024;

/// An .aac file: ADTS frames, after an ID3 tag if one is first. Its sync
/// word, of MPEG-4 or MPEG-2, with a CRC or without; MP3's differ in their
/// layer.
pub const adts_formats = [_]decoding.Format{
    .{ .name = "aac", .magic = "\xff\xf1", .open = openAdts },
    .{ .name = "aac", .magic = "\xff\xf0", .open = openAdts },
    .{ .name = "aac", .magic = "\xff\xf9", .open = openAdts },
    .{ .name = "aac", .magic = "\xff\xf8", .open = openAdts },
};

pub const sample_rates = [_]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };

/// What an AudioSpecificConfig says of a stream.
pub const Config = struct {
    sample_rate: u32,
    /// Index of the rate in `sample_rates`, or of the nearest rate's bands.
    rate_index: u4,
    /// 1 to 7, as the channel configurations of ISO/IEC 14496-3.
    channel_config: u4,

    /// Reads an AudioSpecificConfig: AAC-LC's, or another object type's
    /// with `error.UnsupportedEncoding`, as HE-AAC's.
    pub fn parse(bytes: []const u8) Error!Config {
        var bits: Bits = .{ .data = bytes };
        const object = try objectType(&bits);
        var config = try rateAndChannels(&bits);
        // HE-AAC signalled hierarchically: SBR, then the core's type.
        if (object == 5 or object == 29) return error.UnsupportedEncoding;
        if (object != 2) return error.UnsupportedEncoding;
        // GASpecificConfig: 960-frame packets, and a core coder, are of
        // other profiles.
        if (try bits.read(1) != 0) return error.UnsupportedEncoding;
        if (try bits.read(1) != 0) return error.UnsupportedEncoding;
        _ = try bits.read(1); // extension flag: none for AAC-LC
        if (config.channel_config == 0) return error.UnsupportedEncoding;
        // SBR signalled backward compatibly, after the config.
        if (bits.left() >= 16 and try bits.read(11) == 0x2b7) {
            if (try objectType(&bits) == 5 and try bits.read(1) != 0) return error.UnsupportedEncoding;
        }
        config.rate_index = bandsIndex(config.sample_rate);
        return config;
    }

    fn objectType(bits: *Bits) Error!u32 {
        const object = try bits.read(5);
        return if (object == 31) 32 + try bits.read(6) else object;
    }

    fn rateAndChannels(bits: *Bits) Error!Config {
        const index = try bits.read(4);
        const rate = if (index == 15) try bits.read(24) else if (index < sample_rates.len) sample_rates[index] else return error.InvalidData;
        if (rate == 0) return error.InvalidData;
        const layout: u4 = @intCast(try bits.read(4));
        if (layout > 7) return error.UnsupportedEncoding;
        return .{ .sample_rate = rate, .rate_index = 0, .channel_config = layout };
    }

    /// Channels decoded: 1 of a mono stream, else the front pair.
    pub fn channels(self: Config) u16 {
        return if (self.channel_config == 1) 1 else 2;
    }
};

/// The index of the bands a rate uses: of the nearest standard rate below.
fn bandsIndex(rate: u32) u4 {
    const least = [_]u32{ 92017, 75132, 55426, 46009, 37566, 27713, 23004, 18783, 13856, 11502, 9391, 0 };
    for (least, 0..) |at, index| if (rate >= at) return @intCast(index);
    return 11;
}

/// Bits of a packet, most significant first.
const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    fn left(self: Bits) usize {
        return self.data.len * 8 - self.pos;
    }

    fn read(self: *Bits, count: u6) Error!u32 {
        if (count == 0) return 0;
        if (count > self.left()) return error.InvalidData;
        const byte = self.pos >> 3;
        var value: u64 = 0;
        for (0..8) |index| {
            value <<= 8;
            if (byte + index < self.data.len) value |= self.data[byte + index];
        }
        const shift: u6 = @intCast(64 - (self.pos & 7) - count);
        self.pos += count;
        return @intCast((value >> shift) & ((@as(u64, 1) << count) - 1));
    }

    fn bit(self: *Bits) Error!u1 {
        return @intCast(try self.read(1));
    }

    fn skip(self: *Bits, count: usize) Error!void {
        if (count > self.left()) return error.InvalidData;
        self.pos += count;
    }

    fn alignToByte(self: *Bits) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }
};

/// A Huffman code as a tree: a node's children are other nodes, by index,
/// or symbols, as -(symbol + 1).
fn Tree(comptime count: usize) type {
    return [count][2]i16;
}

fn tree(comptime codes: []const u32, comptime lengths: []const u8) Tree(codes.len) {
    @setEvalBranchQuota(200000);
    var nodes: Tree(codes.len) = @splat(.{ 0, 0 });
    var used: usize = 1;
    for (codes, lengths, 0..) |code, length, symbol| {
        var at: usize = 0;
        var bit: u5 = @intCast(length - 1);
        while (bit > 0) : (bit -= 1) {
            const side = (code >> bit) & 1;
            if (nodes[at][side] == 0) {
                nodes[at][side] = @intCast(used);
                used += 1;
            }
            at = @intCast(nodes[at][side]);
        }
        nodes[at][code & 1] = -@as(i16, @intCast(symbol + 1));
    }
    return nodes;
}

fn decodeSymbol(nodes: []const [2]i16, bits: *Bits) Error!u16 {
    var at: usize = 0;
    while (true) {
        const next = nodes[at][try bits.bit()];
        if (next < 0) return zio.asUnsigned(-next - 1);
        if (next == 0) return error.InvalidData;
        at = zio.asUnsigned(next);
    }
}

const scale_factor_tree = tree(&tables.scale_factor_codes, &tables.scale_factor_lengths);

/// A spectral codebook: its code, how many values each codeword holds,
/// whether they carry signs apart, and the values' base.
const Book = struct {
    nodes: []const [2]i16,
    quads: bool,
    unsigned: bool,
    modulo: u8,
};

const books = blk: {
    const codes = .{ tables.spectrum1_codes, tables.spectrum2_codes, tables.spectrum3_codes, tables.spectrum4_codes, tables.spectrum5_codes, tables.spectrum6_codes, tables.spectrum7_codes, tables.spectrum8_codes, tables.spectrum9_codes, tables.spectrum10_codes, tables.spectrum11_codes };
    const lengths = .{ tables.spectrum1_lengths, tables.spectrum2_lengths, tables.spectrum3_lengths, tables.spectrum4_lengths, tables.spectrum5_lengths, tables.spectrum6_lengths, tables.spectrum7_lengths, tables.spectrum8_lengths, tables.spectrum9_lengths, tables.spectrum10_lengths, tables.spectrum11_lengths };
    const moduli = [_]u8{ 3, 3, 3, 3, 9, 9, 8, 8, 13, 13, 17 };
    var result: [11]Book = undefined;
    for (0..11) |index| {
        const nodes = tree(&codes[index], &lengths[index]);
        const stored = nodes;
        result[index] = .{ .nodes = &stored, .quads = index < 4, .unsigned = index == 2 or index == 3 or index >= 6, .modulo = moduli[index] };
    }
    break :blk result;
};

const zero_book = 0;
const noise_book = 13;
const intensity_out_of_phase = 14;
const intensity_in_phase = 15;

const only_long = 0;
const long_start = 1;
const eight_short = 2;
const long_stop = 3;

const swb_long_96 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 156, 172, 188, 212, 240, 276, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960, 1024 };
const swb_long_64 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 100, 112, 124, 140, 156, 172, 192, 216, 240, 268, 304, 344, 384, 424, 464, 504, 544, 584, 624, 664, 704, 744, 784, 824, 864, 904, 944, 984, 1024 };
const swb_long_48 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024 };
const swb_long_32 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 960, 992, 1024 };
const swb_long_24 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220, 240, 260, 284, 308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704, 768, 832, 896, 960, 1024 };
const swb_long_16 = [_]u16{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344, 368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024 };
const swb_long_8 = [_]u16{ 0, 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172, 188, 204, 220, 236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448, 476, 508, 544, 580, 620, 664, 712, 764, 820, 880, 944, 1024 };
const swb_short_64 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128 };
const swb_short_48 = [_]u16{ 0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128 };
const swb_short_24 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128 };
const swb_short_16 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128 };
const swb_short_8 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128 };

/// The scale factor bands of each rate's index, of long and short windows.
const swb_long = [12][]const u16{ &swb_long_96, &swb_long_96, &swb_long_64, &swb_long_48, &swb_long_48, &swb_long_32, &swb_long_24, &swb_long_24, &swb_long_16, &swb_long_16, &swb_long_16, &swb_long_8 };
const swb_short = [12][]const u16{ &swb_short_64, &swb_short_64, &swb_short_64, &swb_short_48, &swb_short_48, &swb_short_48, &swb_short_24, &swb_short_24, &swb_short_16, &swb_short_16, &swb_short_16, &swb_short_8 };
/// The bands temporal noise shaping reaches, at most, of AAC-LC.
const tns_max_long = [12]u8{ 31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39 };
const tns_max_short = [12]u8{ 9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14 };
const tns_max_order_long = 12;
const tns_max_order_short = 7;

const Tns = struct {
    filters: [8]u2 = @splat(0),
    resolution: [8]u1 = @splat(0),
    length: [8][4]u8 = undefined,
    order: [8][4]u8 = undefined,
    down: [8][4]bool = undefined,
    compress: [8][4]u1 = undefined,
    coefficients: [8][4][tns_max_order_long]u8 = undefined,
};

/// The information of a channel's packet, and its spectrum.
const Stream = struct {
    sequence: u2 = only_long,
    shape: u1 = 0,
    max_sfb: u8 = 0,
    groups: u8 = 1,
    group_length: [8]u8 = @splat(1),
    /// Codebook of each band, by group: `[group * 64 + band]`.
    book: [8 * 64]u8 = undefined,
    /// Its scale factor, intensity position or noise energy.
    scale: [8 * 64]i16 = undefined,
    tns_present: bool = false,
    tns: Tns = .{},
    spectrum: [1024]f32 = undefined,

    fn windows(self: *const Stream) usize {
        return if (self.sequence == eight_short) 8 else 1;
    }

    fn offsets(self: *const Stream, rate_index: u4) []const u16 {
        return if (self.sequence == eight_short) swb_short[rate_index] else swb_long[rate_index];
    }

    fn bands(self: *const Stream, rate_index: u4) usize {
        return self.offsets(rate_index).len - 1;
    }
};

/// What a channel keeps from packet to packet: the second half of its
/// last window, to overlap the next, and the shape it ended with.
const History = struct {
    overlap: [frame_length]f32 = @splat(0),
    shape: u1 = 0,
};

/// Decodes AAC-LC packets, raw, one at a time.
pub const Codec = struct {
    config: Config,
    windows: *const Windows,
    history: [2]History = .{ .{}, .{} },
    streams: [2]Stream = .{ .{}, .{} },
    /// Of an element not played: a center or an LFE channel.
    spare: [2]Stream = .{ .{}, .{} },
    random: u32 = 0x1f2e3d4c,
    transform: Transform,
    output: [2][frame_length]f32 = undefined,

    pub fn init(config: Config) Codec {
        return .{ .config = config, .windows = &windows_table, .transform = .{} };
    }

    /// Forgets the packets before, as after a seek.
    pub fn reset(self: *Codec) void {
        self.history = .{ .{}, .{} };
    }

    /// Decodes a packet into `out`, `frame_length` frames of the codec's
    /// channels interleaved, and returns the frames it wrote.
    pub fn decode(self: *Codec, packet: []const u8, out: []f32) Error!usize {
        const channels = self.config.channels();
        std.debug.assert(out.len >= frame_length * channels);
        var bits: Bits = .{ .data = packet };
        var played = false;
        while (true) {
            const kind = try bits.read(3);
            switch (kind) {
                0, 3 => { // a single channel, or a low-frequency one
                    _ = try bits.read(4);
                    const play = !played and kind == 0 and channels == 1;
                    const stream = if (play) &self.streams[0] else &self.spare[0];
                    try self.individual(&bits, stream, false);
                    if (play) {
                        self.synthesize(0, stream);
                        played = true;
                    }
                },
                1 => { // a channel pair
                    _ = try bits.read(4);
                    const play = !played and channels == 2;
                    try self.pair(&bits, if (play) &self.streams else &self.spare);
                    if (play) {
                        self.synthesize(0, &self.streams[0]);
                        self.synthesize(1, &self.streams[1]);
                        played = true;
                    }
                },
                2 => return error.UnsupportedEncoding, // coupling channels
                4 => { // data
                    _ = try bits.read(4);
                    const aligned = try bits.bit();
                    var count: usize = try bits.read(8);
                    if (count == 255) count += try bits.read(8);
                    if (aligned != 0) bits.alignToByte();
                    try bits.skip(count * 8);
                },
                5 => return error.UnsupportedEncoding, // a program config
                6 => { // fill
                    var count: usize = try bits.read(4);
                    if (count == 15) count += @as(usize, try bits.read(8)) - 1;
                    try bits.skip(count * 8);
                },
                else => break,
            }
        }
        if (!played) return error.InvalidData;
        for (0..frame_length) |frame| {
            for (0..channels) |channel| out[frame * channels + channel] = self.output[channel][frame];
        }
        return frame_length;
    }

    fn info(self: *Codec, bits: *Bits, stream: *Stream) Error!void {
        if (try bits.bit() != 0) return error.InvalidData;
        stream.sequence = @intCast(try bits.read(2));
        stream.shape = try bits.bit();
        if (stream.sequence == eight_short) {
            stream.max_sfb = @intCast(try bits.read(4));
            const grouping = try bits.read(7);
            stream.groups = 0;
            for (0..8) |window| {
                if (window == 0 or (grouping >> @intCast(7 - window)) & 1 == 0) {
                    stream.group_length[stream.groups] = 1;
                    stream.groups += 1;
                } else stream.group_length[stream.groups - 1] += 1;
            }
        } else {
            stream.max_sfb = @intCast(try bits.read(6));
            stream.groups = 1;
            stream.group_length[0] = 1;
            // Prediction is of AAC Main.
            if (try bits.bit() != 0) return error.UnsupportedEncoding;
        }
        if (stream.max_sfb > stream.bands(self.config.rate_index)) return error.InvalidData;
    }

    fn pair(self: *Codec, bits: *Bits, streams: *[2]Stream) Error!void {
        const common = try bits.bit() != 0;
        var ms: [8 * 64]bool = @splat(false);
        if (common) {
            try self.info(bits, &streams[0]);
            const right = &streams[1];
            right.sequence = streams[0].sequence;
            right.shape = streams[0].shape;
            right.max_sfb = streams[0].max_sfb;
            right.groups = streams[0].groups;
            right.group_length = streams[0].group_length;
            switch (try bits.read(2)) {
                0 => {},
                1 => for (0..streams[0].groups) |group| {
                    for (0..streams[0].max_sfb) |band| ms[group * 64 + band] = try bits.bit() != 0;
                },
                2 => @memset(&ms, true),
                else => return error.InvalidData,
            }
        }
        try self.individual(bits, &streams[0], common);
        try self.individual(bits, &streams[1], common);
        if (!common) return;
        const left = &streams[0];
        const right = &streams[1];
        const offsets = left.offsets(self.config.rate_index);
        var window: usize = 0;
        for (0..left.groups) |group| {
            const length = left.group_length[group];
            for (0..left.max_sfb) |band| {
                const index = group * 64 + band;
                const start = offsets[band];
                const end = offsets[band + 1];
                const right_book = right.book[index];
                if (right_book == intensity_in_phase or right_book == intensity_out_of_phase) {
                    // The right is the left's, scaled.
                    var scale = std.math.pow(f32, 0.5, @as(f32, @floatFromInt(right.scale[index])) / 4);
                    if ((right_book == intensity_out_of_phase) != ms[index]) scale = -scale;
                    for (window..window + length) |w| {
                        for (start..end) |k| right.spectrum[w * 128 + k] = left.spectrum[w * 128 + k] * scale;
                    }
                } else if (ms[index] and left.book[index] != noise_book and right_book != noise_book) {
                    for (window..window + length) |w| {
                        for (start..end) |k| {
                            const mid = left.spectrum[w * 128 + k];
                            const side = right.spectrum[w * 128 + k];
                            left.spectrum[w * 128 + k] = mid + side;
                            right.spectrum[w * 128 + k] = mid - side;
                        }
                    }
                }
            }
            window += length;
        }
        if (left.tns_present) self.shapeNoise(left);
        if (right.tns_present) self.shapeNoise(right);
    }

    /// Reads a channel's stream into `stream`, whose information a pair
    /// has read when `common`.
    fn individual(self: *Codec, bits: *Bits, stream: *Stream, common: bool) Error!void {
        const global_gain: i16 = @intCast(try bits.read(8));
        if (!common) try self.info(bits, stream);
        try self.sections(bits, stream);
        try self.scaleFactors(bits, stream, global_gain);
        const pulses = try bits.bit() != 0;
        var pulse_start: usize = 0;
        var pulse_count: usize = 0;
        var pulse_offset: [4]u8 = undefined;
        var pulse_amplitude: [4]u8 = undefined;
        if (pulses) {
            if (stream.sequence == eight_short) return error.InvalidData;
            pulse_count = try bits.read(2) + 1;
            pulse_start = try bits.read(6);
            if (pulse_start >= stream.bands(self.config.rate_index)) return error.InvalidData;
            for (0..pulse_count) |index| {
                pulse_offset[index] = @intCast(try bits.read(5));
                pulse_amplitude[index] = @intCast(try bits.read(4));
            }
        }
        stream.tns_present = try bits.bit() != 0;
        if (stream.tns_present) try tnsData(bits, stream);
        // Gain control is of AAC SSR.
        if (try bits.bit() != 0) return error.UnsupportedEncoding;
        var quantized: [1024]i32 = @splat(0);
        try self.spectralData(bits, stream, &quantized);
        if (pulses) {
            var at: usize = stream.offsets(self.config.rate_index)[pulse_start];
            for (0..pulse_count) |index| {
                at += pulse_offset[index];
                if (at >= 1024) return error.InvalidData;
                const amplitude: i32 = pulse_amplitude[index];
                quantized[at] += if (quantized[at] > 0) amplitude else -amplitude;
            }
        }
        self.dequantize(stream, &quantized);
        if (!common and stream.tns_present) self.shapeNoise(stream);
    }

    fn sections(self: *Codec, bits: *Bits, stream: *Stream) Error!void {
        const short = stream.sequence == eight_short;
        const length_bits: u6 = if (short) 3 else 5;
        const escape: u32 = if (short) 7 else 31;
        _ = self;
        for (0..stream.groups) |group| {
            var band: usize = 0;
            while (band < stream.max_sfb) {
                const book: u8 = @intCast(try bits.read(4));
                if (book == 12) return error.InvalidData;
                var length: usize = 0;
                while (true) {
                    const part = try bits.read(length_bits);
                    length += part;
                    if (part != escape) break;
                }
                if (band + length > stream.max_sfb) return error.InvalidData;
                @memset(stream.book[group * 64 + band ..][0..length], book);
                band += length;
            }
        }
    }

    fn scaleFactors(self: *Codec, bits: *Bits, stream: *Stream, global_gain: i16) Error!void {
        _ = self;
        var scale = global_gain;
        var position: i16 = 0;
        var noise = global_gain - 90;
        var first_noise = true;
        for (0..stream.groups) |group| {
            for (0..stream.max_sfb) |band| {
                const index = group * 64 + band;
                switch (stream.book[index]) {
                    zero_book => stream.scale[index] = 0,
                    intensity_in_phase, intensity_out_of_phase => {
                        position += @as(i16, @intCast(try decodeSymbol(&scale_factor_tree, bits))) - 60;
                        stream.scale[index] = position;
                    },
                    noise_book => {
                        if (first_noise) {
                            noise += @as(i16, @intCast(try bits.read(9))) - 256;
                            first_noise = false;
                        } else noise += @as(i16, @intCast(try decodeSymbol(&scale_factor_tree, bits))) - 60;
                        stream.scale[index] = noise;
                    },
                    else => {
                        scale += @as(i16, @intCast(try decodeSymbol(&scale_factor_tree, bits))) - 60;
                        if (scale < 0 or scale > 255) return error.InvalidData;
                        stream.scale[index] = scale;
                    },
                }
            }
        }
    }

    /// Reads the quantized spectrum, in windows of 128 for short ones.
    fn spectralData(self: *Codec, bits: *Bits, stream: *Stream, quantized: *[1024]i32) Error!void {
        const offsets = stream.offsets(self.config.rate_index);
        var window: usize = 0;
        for (0..stream.groups) |group| {
            const length = stream.group_length[group];
            for (0..stream.max_sfb) |band| {
                const book_index = stream.book[group * 64 + band];
                if (book_index == zero_book or book_index > 11) continue;
                const book = books[book_index - 1];
                const step: usize = if (book.quads) 4 else 2;
                for (window..window + length) |w| {
                    var k: usize = offsets[band];
                    while (k < offsets[band + 1]) : (k += step) {
                        try readCodeword(bits, book, quantized[w * 128 + k ..][0..step]);
                    }
                }
            }
            window += length;
        }
    }

    fn dequantize(self: *Codec, stream: *Stream, quantized: *const [1024]i32) void {
        @memset(&stream.spectrum, 0);
        const offsets = stream.offsets(self.config.rate_index);
        var window: usize = 0;
        for (0..stream.groups) |group| {
            const length = stream.group_length[group];
            for (0..stream.max_sfb) |band| {
                const index = group * 64 + band;
                const start = offsets[band];
                const end = offsets[band + 1];
                switch (stream.book[index]) {
                    zero_book, intensity_in_phase, intensity_out_of_phase => {},
                    noise_book => for (window..window + length) |w| {
                        const values = stream.spectrum[w * 128 + start .. w * 128 + end];
                        var energy: f32 = 0;
                        for (values) |*value| {
                            self.random = self.random *% 1664525 +% 1013904223;
                            value.* = @floatFromInt(@as(i32, @bitCast(self.random)));
                            energy += value.* * value.*;
                        }
                        const gain = std.math.pow(f32, 2, @as(f32, @floatFromInt(stream.scale[index])) / 4) / @sqrt(energy);
                        for (values) |*value| value.* *= gain;
                    },
                    else => {
                        const gain = std.math.pow(f32, 2, @as(f32, @floatFromInt(stream.scale[index] - 100)) / 4);
                        for (window..window + length) |w| {
                            for (start..end) |k| {
                                const q = quantized[w * 128 + k];
                                const magnitude: f32 = @floatFromInt(@abs(q));
                                const value = std.math.pow(f32, magnitude, 4.0 / 3.0) * gain;
                                stream.spectrum[w * 128 + k] = if (q < 0) -value else value;
                            }
                        }
                    },
                }
            }
            window += length;
        }
    }

    /// Undoes temporal noise shaping: filters the spectrum over each
    /// filter's bands.
    fn shapeNoise(self: *Codec, stream: *Stream) void {
        const short = stream.sequence == eight_short;
        const offsets = stream.offsets(self.config.rate_index);
        const bands = stream.bands(self.config.rate_index);
        const max_bands = @min(if (short) tns_max_short[self.config.rate_index] else tns_max_long[self.config.rate_index], stream.max_sfb);
        const max_order: usize = if (short) tns_max_order_short else tns_max_order_long;
        for (0..stream.windows()) |window| {
            var top: usize = bands;
            for (0..stream.tns.filters[window]) |filter| {
                const bottom = top -| stream.tns.length[window][filter];
                const order = @min(stream.tns.order[window][filter], max_order);
                defer top = bottom;
                if (order == 0) continue;
                var lpc: [tns_max_order_long + 1]f32 = undefined;
                tnsCoefficients(stream.tns.coefficients[window][filter][0..order], stream.tns.resolution[window], stream.tns.compress[window][filter], lpc[0 .. order + 1]);
                const start: usize = offsets[@min(bottom, max_bands)];
                const end: usize = offsets[@min(top, max_bands)];
                if (end <= start) continue;
                const values = stream.spectrum[window * 128 ..][0 .. 1024 / stream.windows()];
                var state: [tns_max_order_long]f32 = @splat(0);
                for (0..end - start) |step| {
                    const k = if (stream.tns.down[window][filter]) end - 1 - step else start + step;
                    var y = values[k];
                    for (0..order) |j| y -= lpc[j + 1] * state[j];
                    var j = order - 1;
                    while (j > 0) : (j -= 1) state[j] = state[j - 1];
                    state[0] = y;
                    values[k] = y;
                }
            }
        }
    }

    /// The spectrum of a played channel to its 1024 frames, overlapping the
    /// packet before.
    fn synthesize(self: *Codec, channel: usize, stream: *const Stream) void {
        const history = &self.history[channel];
        const previous = self.windows.get(history.shape);
        const current = self.windows.get(stream.shape);
        var buffer: [2048]f32 = undefined;
        if (stream.sequence == eight_short) {
            @memset(&buffer, 0);
            var short: [256]f32 = undefined;
            for (0..8) |window| {
                self.transform.inverseShort(stream.spectrum[window * 128 ..][0..128], &short);
                const rising = if (window == 0) previous.short else current.short;
                for (0..128) |n| {
                    short[n] *= rising[n];
                    short[255 - n] *= current.short[n];
                }
                for (short, 0..) |value, n| buffer[448 + window * 128 + n] += value;
            }
        } else {
            self.transform.inverseLong(&stream.spectrum, &buffer);
            if (stream.sequence == long_stop) {
                @memset(buffer[0..448], 0);
                for (0..128) |n| buffer[448 + n] *= previous.short[n];
            } else for (0..1024) |n| {
                buffer[n] *= previous.long[n];
            }
            if (stream.sequence == long_start) {
                for (0..128) |n| buffer[1472 + n] *= current.short[127 - n];
                @memset(buffer[1600..], 0);
            } else for (0..1024) |n| {
                buffer[2047 - n] *= current.long[n];
            }
        }
        for (0..frame_length) |n| self.output[channel][n] = (buffer[n] + history.overlap[n]) / 32768;
        @memcpy(&history.overlap, buffer[1024..]);
        history.shape = stream.shape;
    }
};

/// Reads a codeword of `book` into `values`, two or four, with their signs
/// and escapes.
fn readCodeword(bits: *Bits, book: Book, values: []i32) Error!void {
    var index: u32 = try decodeSymbol(book.nodes, bits);
    const modulo = book.modulo;
    var at = values.len;
    while (at > 0) {
        at -= 1;
        const digit: i32 = @intCast(index % modulo);
        index /= modulo;
        values[at] = if (book.unsigned) digit else digit - @as(i32, modulo / 2);
    }
    if (!book.unsigned) return;
    for (values) |*value| {
        if (value.* != 0 and try bits.bit() != 0) value.* = -value.*;
    }
    if (book.modulo != 17) return;
    for (values) |*value| {
        if (@abs(value.*) != 16) continue;
        var count: u6 = 0;
        while (try bits.bit() != 0) {
            count += 1;
            if (count > 8) return error.InvalidData;
        }
        const magnitude: i32 = @intCast((@as(u32, 1) << @intCast(count + 4)) + try bits.read(count + 4));
        value.* = if (value.* < 0) -magnitude else magnitude;
    }
}

fn tnsData(bits: *Bits, stream: *Stream) Error!void {
    const short = stream.sequence == eight_short;
    for (0..stream.windows()) |window| {
        stream.tns.filters[window] = @intCast(try bits.read(if (short) 1 else 2));
        if (stream.tns.filters[window] == 0) continue;
        stream.tns.resolution[window] = try bits.bit();
        for (0..stream.tns.filters[window]) |filter| {
            stream.tns.length[window][filter] = @intCast(try bits.read(if (short) 4 else 6));
            const order: u8 = @intCast(try bits.read(if (short) 3 else 5));
            if (order > tns_max_order_long) return error.InvalidData;
            stream.tns.order[window][filter] = order;
            if (order == 0) continue;
            stream.tns.down[window][filter] = try bits.bit() != 0;
            stream.tns.compress[window][filter] = try bits.bit();
            const coefficient_bits: u6 = 3 + @as(u6, stream.tns.resolution[window]) - stream.tns.compress[window][filter];
            for (0..order) |index| stream.tns.coefficients[window][filter][index] = @intCast(try bits.read(coefficient_bits));
        }
    }
}

/// A filter's quantized reflection coefficients to its LPC coefficients,
/// `lpc[0]` being 1.
fn tnsCoefficients(coded: []const u8, resolution: u1, compress: u1, lpc: []f32) void {
    const coefficient_bits: u5 = 3 + @as(u5, resolution) - compress;
    const levels: f32 = @floatFromInt(@as(u32, 1) << (2 + @as(u5, resolution)));
    const positive = (levels - 0.5) / (std.math.pi / 2.0);
    const negative = (levels + 0.5) / (std.math.pi / 2.0);
    var reflection: [tns_max_order_long]f32 = undefined;
    for (coded, 0..) |value, index| {
        // Sign-extended from its bits.
        const shift: u5 = @intCast(32 - @as(u6, coefficient_bits));
        const signed: i32 = @as(i32, @bitCast(@as(u32, value) << shift)) >> shift;
        const scaled: f32 = @floatFromInt(signed);
        reflection[index] = @sin(scaled / (if (signed >= 0) positive else negative));
    }
    lpc[0] = 1;
    var previous: [tns_max_order_long + 1]f32 = undefined;
    for (1..coded.len + 1) |m| {
        for (1..m) |i| previous[i] = lpc[i] + reflection[m - 1] * lpc[m - i];
        for (1..m) |i| lpc[i] = previous[i];
        lpc[m] = reflection[m - 1];
    }
}

/// The rising halves of the windows: sine and Kaiser-Bessel derived, long
/// and short. A falling half is a rising one backwards.
const Shape = struct { long: [1024]f32, short: [128]f32 };
const Windows = struct {
    sine: Shape,
    kbd: Shape,

    fn get(self: *const Windows, shape: u1) *const Shape {
        return if (shape == 0) &self.sine else &self.kbd;
    }
};

const windows_table: Windows = blk: {
    @setEvalBranchQuota(10_000_000);
    var result: Windows = undefined;
    sineWindow(&result.sine.long);
    sineWindow(&result.sine.short);
    kbdWindow(&result.kbd.long, 4);
    kbdWindow(&result.kbd.short, 6);
    break :blk result;
};

fn sineWindow(half: []f32) void {
    const n: f64 = @floatFromInt(half.len * 2);
    for (half, 0..) |*value, index| value.* = @floatCast(@sin(std.math.pi / n * (@as(f64, @floatFromInt(index)) + 0.5)));
}

fn besselI0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (k < 64) : (k += 1) {
        term *= (x / 2) / k;
        sum += term * term;
        if (term * term < sum * 1e-12) break;
    }
    return sum;
}

fn kbdWindow(half: []f32, alpha: f64) void {
    const quarter: f64 = @floatFromInt(half.len / 2);
    var kaiser: [1025]f64 = undefined;
    var total: f64 = 0;
    for (0..half.len + 1) |index| {
        const ratio = (@as(f64, @floatFromInt(index)) - quarter) / quarter;
        kaiser[index] = besselI0(std.math.pi * alpha * @sqrt(@max(0, 1 - ratio * ratio)));
        total += kaiser[index];
    }
    var sum: f64 = 0;
    for (half, 0..) |*value, index| {
        sum += kaiser[index];
        value.* = @floatCast(@sqrt(sum / total));
    }
}

const Complex = std.math.Complex(f32);

/// The inverse modified discrete cosine transforms of 1024 and 128
/// coefficients, through a DCT-IV of an FFT of a quarter their outputs.
const Transform = struct {
    fn inverseLong(self: *Transform, spectrum: *const [1024]f32, out: *[2048]f32) void {
        _ = self;
        imdct(1024, spectrum, out);
    }

    fn inverseShort(self: *Transform, spectrum: *const [128]f32, out: *[256]f32) void {
        _ = self;
        imdct(128, spectrum, out);
    }
};

fn Twiddles(comptime m: usize) type {
    return struct {
        /// Before and after the FFT, and the FFT's own.
        const pre: [m / 2]Complex = blk: {
            @setEvalBranchQuota(1_000_000);
            var values: [m / 2]Complex = undefined;
            for (&values, 0..) |*value, n| value.* = expi(-std.math.pi * (4.0 * @as(f64, @floatFromInt(n)) + 1.0) / (4.0 * @as(f64, m)));
            break :blk values;
        };
        const post: [m / 2]Complex = blk: {
            @setEvalBranchQuota(1_000_000);
            var values: [m / 2]Complex = undefined;
            for (&values, 0..) |*value, k| value.* = expi(-std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, m));
            break :blk values;
        };
        const fft: [m / 4]Complex = blk: {
            @setEvalBranchQuota(1_000_000);
            var values: [m / 4]Complex = undefined;
            for (&values, 0..) |*value, k| value.* = expi(-2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, m / 2));
            break :blk values;
        };
    };
}

fn expi(angle: f64) Complex {
    return .{ .re = @floatCast(@cos(angle)), .im = @floatCast(@sin(angle)) };
}

/// x[n] = 2/N Σ X[k] cos(2π/N (n + n0)(k + 1/2)), of N = 2m outputs.
fn imdct(comptime m: usize, spectrum: *const [m]f32, out: *[2 * m]f32) void {
    var y: [m]f32 = undefined;
    dct4(m, spectrum, &y);
    const scale = 2.0 / @as(f32, 2 * m);
    const half = m / 2;
    for (0..2 * m) |n| {
        const at = n + half;
        const value = if (at < m) y[at] else if (at < 2 * m) -y[2 * m - 1 - at] else -y[at - 2 * m];
        out[n] = value * scale;
    }
}

/// y[k] = Σ x[n] cos(π/m (n + 1/2)(k + 1/2)).
fn dct4(comptime m: usize, x: *const [m]f32, y: *[m]f32) void {
    const twiddles = Twiddles(m);
    var values: [m / 2]Complex = undefined;
    for (&values, 0..) |*value, n| value.* = (Complex{ .re = x[2 * n], .im = x[m - 1 - 2 * n] }).mul(twiddles.pre[n]);
    fft(m / 2, &values, &twiddles.fft);
    for (values, 0..) |value, k| {
        const turned = value.mul(twiddles.post[k]);
        y[2 * k] = turned.re;
        y[m - 1 - 2 * k] = -turned.im;
    }
}

/// An in-place radix-2 FFT of `size` points, by `roots[k] = e^(-2πik/size)`.
fn fft(comptime size: usize, values: *[size]Complex, roots: *const [size / 2]Complex) void {
    const levels = std.math.log2_int(usize, size);
    for (0..size) |index| {
        const reversed = @bitReverse(@as(u16, @intCast(index))) >> @intCast(16 - levels);
        if (reversed > index) std.mem.swap(Complex, &values[index], &values[reversed]);
    }
    var length: usize = 2;
    while (length <= size) : (length *= 2) {
        const stride = size / length;
        var start: usize = 0;
        while (start < size) : (start += length) {
            for (0..length / 2) |k| {
                const odd = values[start + k + length / 2].mul(roots[k * stride]);
                const even = values[start + k];
                values[start + k] = even.add(odd);
                values[start + k + length / 2] = even.sub(odd);
            }
        }
    }
}

const mp4 = @import("mp4.zig");

/// A codec of an MP4's AAC track, from its AudioSpecificConfig.
const Packets = struct {
    allocator: std.mem.Allocator,
    codec: Codec,

    fn decode(context: *anyopaque, packet: []const u8, out: []f32) Error!usize {
        const self: *Packets = @ptrCast(@alignCast(context));
        return self.codec.decode(packet, out);
    }

    fn reset(context: *anyopaque) void {
        const self: *Packets = @ptrCast(@alignCast(context));
        self.codec.reset();
    }

    fn deinit(context: *anyopaque) void {
        const self: *Packets = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }

    const vtable: mp4.Codec.VTable = .{ .decode = decode, .reset = reset, .deinit = deinit };
};

fn wrap(allocator: std.mem.Allocator, config: Config) Error!mp4.Codec {
    const self = try allocator.create(Packets);
    self.allocator = allocator;
    self.codec = Codec.init(config);
    return .{
        .context = self,
        .vtable = &Packets.vtable,
        .sample_rate = config.sample_rate,
        .channels = config.channels(),
        .max_frames = frame_length,
        .preroll = 1,
        .packet_frames = frame_length,
    };
}

/// The codec of AAC packets configured by `config`, an AudioSpecificConfig,
/// as an MP4's track holds them.
pub fn openCodec(allocator: std.mem.Allocator, config: []const u8) Error!mp4.Codec {
    return wrap(allocator, try Config.parse(config));
}

const AdtsHeader = struct { length: u32, header: u32, config: Config, blocks: u8 };

fn adtsHeader(bytes: *const [7]u8) ?AdtsHeader {
    if (bytes[0] != 0xff or bytes[1] & 0xf6 != 0xf0) return null;
    const index = bytes[2] >> 2 & 15;
    const length = @as(u32, bytes[3] & 3) << 11 | @as(u32, bytes[4]) << 3 | bytes[5] >> 5;
    const header: u32 = if (bytes[1] & 1 != 0) 7 else 9;
    if (index >= sample_rates.len or length <= header) return null;
    return .{
        .length = length,
        .header = header,
        .config = .{
            .sample_rate = sample_rates[index],
            .rate_index = bandsIndex(sample_rates[index]),
            .channel_config = @intCast((bytes[2] & 1) << 2 | bytes[3] >> 6),
        },
        .blocks = (bytes[6] & 3) + 1,
    };
}

/// Where the audio after an ID3 tag starts, if `input` starts with one.
pub fn skipId3(input: Input) Error!u64 {
    var head: [10]u8 = undefined;
    try input.seekTo(0);
    if (try input.readAll(&head) != 10 or !std.mem.eql(u8, head[0..3], "ID3")) return 0;
    return 10 + (@as(u64, head[6] & 0x7f) << 21 | @as(u64, head[7] & 0x7f) << 14 | @as(u64, head[8] & 0x7f) << 7 | head[9] & 0x7f);
}

/// AAC in ADTS frames, as an .aac file holds them, after an ID3 tag if one
/// is first. It finds every frame as it opens, for the length and to seek.
pub fn openAdts(allocator: std.mem.Allocator, input: Input) Error!Decoder {
    const size = try input.size();
    var offset = try skipId3(input);
    var head: [7]u8 = undefined;
    input.seekTo(offset) catch return error.InvalidData;
    if (try input.readAll(&head) != 7) return error.InvalidData;
    const first = adtsHeader(&head) orelse return error.InvalidData;
    // Its profile, as an object type less one: AAC-LC's is 1.
    if (head[2] >> 6 != 1 or first.config.channel_config == 0 or first.blocks != 1) return error.UnsupportedEncoding;
    const codec = try wrap(allocator, first.config);
    errdefer codec.deinit();
    const self = try mp4.Packets.create(allocator, input, codec);
    errdefer self.destroy();
    while (offset + 7 <= size) {
        input.seekTo(offset) catch break;
        if (try input.readAll(&head) != 7) break;
        const frame = adtsHeader(&head) orelse break;
        if (offset + frame.length > size) break;
        try self.add(offset + frame.header, frame.length - frame.header, (self.ends.items.len + 1) * frame_length);
        offset += frame.length;
    }
    self.frames = self.ends.items.len * frame_length;
    self.exact = true;
    return self.decoder();
}

/// The short inverse transform, for tests.
pub fn testImdct(spectrum: *const [128]f32, out: *[256]f32) void {
    imdct(128, spectrum, out);
}
