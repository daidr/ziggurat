//! The sound of MP4 files: .m4a and .mp4, whole or cut into fragments as
//! a stream for DASH is (.m4s). The container gives where each packet of
//! the first sound track is, from the movie header's sample table or, of a
//! fragmented file, from each fragment's header as playing reaches it; a
//! `Codec` decodes the packets. AAC-LC, Apple Lossless and FLAC decode out
//! of the box; `openWith` takes other codecs. The encoder's priming that an
//! edit list names is dropped, and the padding of the last packet.
const std = @import("std");
const zio = @import("ziggurat_io");
const decoding = @import("decoder.zig");
const Error = decoding.Error;
const Input = decoding.Input;
const Decoder = decoding.Decoder;

/// MP4's `ftyp` box first.
pub const format: decoding.Format = .{ .name = "mp4", .magic = "????ftyp", .open = open };

/// Decodes a track's packets, one at a time.
pub const Codec = struct {
    context: *anyopaque,
    vtable: *const VTable,
    sample_rate: u32,
    /// Samples a frame of what it decodes: 1 mono, 2 stereo.
    channels: u16,
    /// The most frames a packet decodes to.
    max_frames: u32,
    /// Packets before the one holding a frame sought to that are decoded
    /// first, as AAC's 1, whose packets overlap the sound of the one before;
    /// 0 when packets stand alone.
    preroll: u32 = 0,
    /// Frames every packet decodes to, when all do, as AAC's 1024: packets
    /// are then placed in time by counting them, whatever the file says
    /// they last. 0 places them as the file says.
    packet_frames: u32 = 0,

    pub const VTable = struct {
        /// Decodes a packet into `out`, interleaved, and returns its frames.
        decode: *const fn (context: *anyopaque, packet: []const u8, out: []f32) Error!usize,
        /// Forgets the packets decoded before, as after a seek.
        reset: *const fn (context: *anyopaque) void,
        deinit: *const fn (context: *anyopaque) void,
    };

    pub fn decode(self: Codec, packet: []const u8, out: []f32) Error!usize {
        return self.vtable.decode(self.context, packet, out);
    }

    pub fn reset(self: Codec) void {
        self.vtable.reset(self.context);
    }

    pub fn deinit(self: Codec) void {
        self.vtable.deinit(self.context);
    }
};

/// A codec of the tracks whose sample entry is of type `fourcc`, as
/// "mp4a": `open` returns a decoder of their packets from the track's
/// configuration (see `Track.config`), or `error.UnsupportedEncoding` for
/// a configuration it does not decode, as HE-AAC's.
pub const CodecFormat = struct {
    fourcc: [4]u8,
    open: *const fn (allocator: std.mem.Allocator, config: []const u8) Error!Codec,
};

pub const default_codecs = [_]CodecFormat{
    .{ .fourcc = "mp4a".*, .open = @import("aac.zig").openCodec },
    .{ .fourcc = "alac".*, .open = @import("alac.zig").openCodec },
    .{ .fourcc = "fLaC".*, .open = @import("flac.zig").openPacketCodec },
};

/// An MP4's sound track, as its movie header says, for an app to know of
/// a file without decoding it, as a music library scanning files does.
pub const Track = struct {
    /// The type of the track's sample entry: "mp4a" (AAC), "alac",
    /// "fLaC", "Opus", ...
    codec: [4]u8,
    /// What configures the codec: AAC's AudioSpecificConfig, ALAC's magic
    /// cookie, FLAC's metadata blocks, or another codec's boxes within the
    /// sample entry. Owned by the track.
    config: []u8,
    /// How long it plays, in nanoseconds, without the encoder's priming;
    /// 0 for a fragmented file whose header doesn't say.
    duration: u64,
    /// Whether its packets are in fragments after the movie header.
    fragmented: bool,

    pub fn deinit(self: Track, allocator: std.mem.Allocator) void {
        allocator.free(self.config);
    }

    /// Whether one of `codecs` decodes the track: HE-AAC's, for one, the
    /// default codecs do not.
    pub fn decodable(self: Track, allocator: std.mem.Allocator, codecs: []const CodecFormat) bool {
        const codec = openCodec(allocator, self.codec, self.config, codecs) catch return false;
        codec.deinit();
        return true;
    }
};

/// Reads the first sound track of the MP4 `input` holds, from its movie
/// header.
pub fn readTrack(allocator: std.mem.Allocator, input: Input) Error!Track {
    var movie = try Movie.read(allocator, input, false);
    defer movie.deinit();
    const config = try allocator.dupe(u8, movie.config);
    const playing = movie.duration -| movie.prime;
    return .{
        .codec = movie.codec,
        .config = config,
        .duration = @intCast(@as(u128, playing) * std.time.ns_per_s / movie.timescale),
        .fragmented = movie.fragmented,
    };
}

fn openCodec(allocator: std.mem.Allocator, fourcc: [4]u8, config: []const u8, codecs: []const CodecFormat) Error!Codec {
    for (codecs) |codec| if (std.mem.eql(u8, &codec.fourcc, &fourcc)) return codec.open(allocator, config);
    return error.UnsupportedEncoding;
}

pub fn open(allocator: std.mem.Allocator, input: Input) Error!Decoder {
    return openWith(allocator, input, &default_codecs);
}

/// A decoder of the first sound track of the MP4 `input` holds, by the
/// first of `codecs` of its type. It reads the movie header, and the
/// packets as they play: a fragmented file a fragment at a time, with its
/// length from its segment index; one with no index is read through for
/// its length as it opens.
pub fn openWith(allocator: std.mem.Allocator, input: Input, codecs: []const CodecFormat) Error!Decoder {
    var movie = try Movie.read(allocator, input, true);
    errdefer movie.deinit();
    const codec = try openCodec(allocator, movie.codec, movie.config, codecs);
    errdefer codec.deinit();
    const self = try Packets.create(allocator, input, codec);
    errdefer self.destroy();
    const rate = codec.sample_rate;
    const timescale = movie.timescale;
    self.prime = scale(movie.prime, rate, timescale);
    self.skip = self.prime;
    if (!movie.fragmented) {
        for (movie.offsets.items, movie.sizes.items, movie.ends.items) |offset, size, end| try self.add(offset, size, scale(end, rate, timescale));
        movie.deinit();
        if (self.ends.items.len == 0) return error.InvalidData;
        self.frames = self.length() -| self.prime;
        self.exact = true;
    } else {
        self.movie = movie;
        movie = .{ .allocator = allocator };
        if (self.movie.?.duration > 0) {
            // From the segment index: the fragments are found as they play.
            self.frames = scale(self.movie.?.duration, rate, timescale) -| self.prime;
        } else while (try self.findMore()) {}
        if (!try self.have(0)) return error.InvalidData;
    }
    return self.decoder();
}

fn scale(value: u64, rate: u32, timescale: u64) u64 {
    return @intCast(@as(u128, value) * rate / timescale);
}

/// The most bytes of a movie header read, and of a fragment's.
const max_movie = 256 << 20;
const max_fragment = 16 << 20;
/// Bounds the packets a track lists, against a file that claims more than
/// it could hold: a day of AAC at 48 kHz.
const max_packets = 1 << 22;

fn readAt(input: Input, offset: u64, buffer: []u8) Error!usize {
    input.seekTo(offset) catch return 0;
    return input.readAll(buffer);
}

fn be16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}
fn be32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}
fn be64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

/// The boxes of a box's body, one after another.
const Boxes = struct {
    rest: []const u8,

    const Box = struct { kind: [4]u8, body: []const u8 };

    fn next(self: *Boxes) ?Box {
        if (self.rest.len < 8) return null;
        var size: u64 = be32(self.rest);
        var head: u64 = 8;
        if (size == 0) size = self.rest.len else if (size == 1) {
            if (self.rest.len < 16) return null;
            size = be64(self.rest[8..]);
            head = 16;
        }
        if (size < head or size > self.rest.len) return null;
        const box: Box = .{ .kind = self.rest[4..8].*, .body = self.rest[@intCast(head)..@intCast(size)] };
        self.rest = self.rest[@intCast(size)..];
        return box;
    }
};

/// The body of the box of type `path[0]` in `bytes`, following the types
/// after it into the boxes within.
fn child(bytes: []const u8, path: []const *const [4]u8) ?[]const u8 {
    var body = bytes;
    for (path) |kind| {
        var boxes: Boxes = .{ .rest = body };
        body = while (boxes.next()) |box| {
            if (std.mem.eql(u8, &box.kind, kind)) break box.body;
        } else return null;
    }
    return body;
}

/// An MP4's first sound track, from its movie header.
const Movie = struct {
    allocator: std.mem.Allocator,
    header: []u8 = &.{},
    codec: [4]u8 = undefined,
    config: []const u8 = &.{},
    /// The units of its times, a second's.
    timescale: u64 = 0,
    /// How long it is, in the timescale, as its header says.
    duration: u64 = 0,
    /// Where the edit list starts it: the encoder's priming, to drop.
    prime: u64 = 0,
    /// Where each packet is, how long, and where it ends in the timescale.
    offsets: std.ArrayList(u64) = .empty,
    sizes: std.ArrayList(u32) = .empty,
    ends: std.ArrayList(u64) = .empty,
    /// The packets are in fragments after the movie header, which start
    /// at `next`, of the track `id`.
    fragmented: bool = false,
    next: u64 = 0,
    id: u32 = 0,
    default_duration: u32 = 0,
    default_size: u32 = 0,

    fn deinit(self: *Movie) void {
        self.allocator.free(self.header);
        self.offsets.deinit(self.allocator);
        self.sizes.deinit(self.allocator);
        self.ends.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    /// Reads the movie header, which is often after the media data, and
    /// with `tables` where each packet is.
    fn read(allocator: std.mem.Allocator, input: Input, with_tables: bool) Error!Movie {
        const size = try input.size();
        var head: [16]u8 = undefined;
        var offset: u64 = 0;
        while (offset + 8 <= size) {
            if (try readAt(input, offset, head[0..8]) != 8) return error.InvalidData;
            var length: u64 = be32(&head);
            var header: u64 = 8;
            if (length == 0) length = size - offset else if (length == 1) {
                if (try readAt(input, offset + 8, head[8..16]) != 8) return error.InvalidData;
                length = be64(head[8..]);
                header = 16;
            }
            if (length < header or length > size - offset) return error.InvalidData;
            if (std.mem.eql(u8, head[4..8], "moov")) {
                if (length > max_movie) return error.InvalidData;
                var movie: Movie = .{ .allocator = allocator };
                errdefer movie.deinit();
                movie.header = try allocator.alloc(u8, @intCast(length - header));
                if (try readAt(input, offset + header, movie.header) != movie.header.len) return error.InvalidData;
                try movie.parse(with_tables);
                if (movie.fragmented) {
                    movie.next = offset + length;
                    try movie.readIndex(input, size);
                }
                return movie;
            }
            offset += length;
        }
        return error.InvalidData;
    }

    fn parse(self: *Movie, with_tables: bool) Error!void {
        const mvex = child(self.header, &.{"mvex"});
        var boxes: Boxes = .{ .rest = self.header };
        while (boxes.next()) |box| {
            if (!std.mem.eql(u8, &box.kind, "trak")) continue;
            const mdia = child(box.body, &.{"mdia"}) orelse continue;
            const hdlr = child(mdia, &.{"hdlr"}) orelse continue;
            if (hdlr.len < 12 or !std.mem.eql(u8, hdlr[8..12], "soun")) continue;
            return self.track(box.body, mdia, mvex, with_tables);
        }
        return error.InvalidData;
    }

    fn track(self: *Movie, trak: []const u8, mdia: []const u8, mvex: ?[]const u8, with_tables: bool) Error!void {
        const mdhd = child(mdia, &.{"mdhd"}) orelse &.{};
        if (mdhd.len >= 32 and mdhd[0] == 1) {
            self.timescale = be32(mdhd[20..]);
            self.duration = be64(mdhd[24..]);
        } else if (mdhd.len >= 20) {
            self.timescale = be32(mdhd[12..]);
            self.duration = be32(mdhd[16..]);
        }
        if (self.timescale == 0) return error.InvalidData;
        const stbl = child(mdia, &.{ "minf", "stbl" }) orelse return error.InvalidData;
        try self.entry(child(stbl, &.{"stsd"}) orelse return error.InvalidData);
        if (mvex != null and !hasPackets(stbl)) {
            self.fragmented = true;
            if (child(trak, &.{"tkhd"})) |tkhd| if (tkhd.len >= 16) {
                const at: usize = if (tkhd[0] == 1) 20 else 12;
                if (tkhd.len >= at + 4) self.id = be32(tkhd[at..]);
            };
            var boxes: Boxes = .{ .rest = mvex.? };
            while (boxes.next()) |box| {
                if (std.mem.eql(u8, &box.kind, "trex") and box.body.len >= 24 and be32(box.body[4..]) == self.id) {
                    self.default_duration = be32(box.body[12..]);
                    self.default_size = be32(box.body[16..]);
                }
            }
            // The header says nothing of a fragmented track's length: the
            // segment index may.
            self.duration = 0;
        } else if (with_tables) {
            try self.tables(stbl);
            self.duration = self.ends.items[self.ends.items.len - 1];
        }
        if (child(trak, &.{ "edts", "elst" })) |elst| if (elst.len >= 8) {
            const count = be32(elst[4..]);
            var rest = elst[8..];
            for (0..count) |_| {
                var time: i64 = undefined;
                if (elst[0] == 1) {
                    if (rest.len < 20) break;
                    time = @bitCast(be64(rest[8..]));
                    rest = rest[20..];
                } else {
                    if (rest.len < 12) break;
                    time = @as(i32, @bitCast(be32(rest[4..])));
                    rest = rest[12..];
                }
                // Past an empty edit, which plays nothing.
                if (time >= 0) {
                    self.prime = zio.asUnsigned(time);
                    if (self.duration > 0) self.prime = @min(self.prime, self.duration);
                    break;
                }
            }
        };
    }

    /// The codec and its configuration, in a box within the sample entry,
    /// or within a 'wave' box there in QuickTime's own kind.
    fn entry(self: *Movie, stsd: []const u8) Error!void {
        if (stsd.len < 8 + 36) return error.InvalidData;
        const first = stsd[8..];
        const size = be32(first);
        if (size < 36 or size > first.len) return error.InvalidData;
        self.codec = first[4..8].*;
        var inner = first[36..size];
        switch (be16(first[16..])) { // the sound description's version
            1 => inner = inner[@min(16, inner.len)..],
            2 => inner = inner[@min(36, inner.len)..],
            else => {},
        }
        if (child(inner, &.{"wave"})) |wave| inner = wave;
        if (std.mem.eql(u8, &self.codec, "alac")) {
            const cookie = child(inner, &.{"alac"}) orelse return error.InvalidData;
            if (cookie.len < 4) return error.InvalidData;
            self.config = cookie[4..];
        } else if (std.mem.eql(u8, &self.codec, "fLaC")) {
            const dfla = child(inner, &.{"dfLa"}) orelse return error.InvalidData;
            if (dfla.len < 4 + 4 + 34) return error.InvalidData;
            self.config = dfla[4..];
        } else if (std.mem.eql(u8, &self.codec, "mp4a")) {
            const esds = child(inner, &.{"esds"}) orelse return error.InvalidData;
            if (esds.len < 4) return error.InvalidData;
            // MP3 in MP4 has none: not of a codec here.
            self.config = decoderConfig(esds[4..]) orelse return error.UnsupportedEncoding;
        } else self.config = inner;
    }

    fn tables(self: *Movie, stbl: []const u8) Error!void {
        const allocator = self.allocator;
        // Sizes.
        if (child(stbl, &.{"stsz"})) |stsz| {
            if (stsz.len < 12) return error.InvalidData;
            const fixed = be32(stsz[4..]);
            const count = be32(stsz[8..]);
            if (count > max_packets or (fixed == 0 and stsz.len < 12 + 4 * @as(usize, count))) return error.InvalidData;
            try self.sizes.ensureTotalCapacity(allocator, count);
            for (0..count) |index| self.sizes.appendAssumeCapacity(if (fixed != 0) fixed else be32(stsz[12 + 4 * index ..]));
        } else if (child(stbl, &.{"stz2"})) |stz2| {
            if (stz2.len < 12) return error.InvalidData;
            const field = stz2[7];
            const count = be32(stz2[8..]);
            if (count > max_packets or (field != 4 and field != 8 and field != 16) or stz2.len < 12 + (@as(usize, count) * field + 7) / 8) return error.InvalidData;
            try self.sizes.ensureTotalCapacity(allocator, count);
            const data = stz2[12..];
            for (0..count) |index| self.sizes.appendAssumeCapacity(switch (field) {
                4 => (data[index / 2] >> @intCast(4 * (1 - index % 2))) & 15,
                8 => data[index],
                else => be16(data[2 * index ..]),
            });
        } else return error.InvalidData;
        if (self.sizes.items.len == 0) return error.InvalidData;

        // Where the chunks are.
        var chunks: std.ArrayList(u64) = .empty;
        defer chunks.deinit(allocator);
        if (child(stbl, &.{"stco"})) |stco| {
            if (stco.len < 8) return error.InvalidData;
            const count = be32(stco[4..]);
            if (count > max_packets or stco.len < 8 + 4 * @as(usize, count)) return error.InvalidData;
            try chunks.ensureTotalCapacity(allocator, count);
            for (0..count) |index| chunks.appendAssumeCapacity(be32(stco[8 + 4 * index ..]));
        } else if (child(stbl, &.{"co64"})) |co64| {
            if (co64.len < 8) return error.InvalidData;
            const count = be32(co64[4..]);
            if (count > max_packets or co64.len < 8 + 8 * @as(usize, count)) return error.InvalidData;
            try chunks.ensureTotalCapacity(allocator, count);
            for (0..count) |index| chunks.appendAssumeCapacity(be64(co64[8 + 8 * index ..]));
        } else return error.InvalidData;

        // Which packets each chunk holds, in runs of chunks alike.
        const stsc = child(stbl, &.{"stsc"}) orelse return error.InvalidData;
        if (stsc.len < 8) return error.InvalidData;
        const runs = be32(stsc[4..]);
        if (runs == 0 or runs > max_packets or stsc.len < 8 + 12 * @as(usize, runs)) return error.InvalidData;
        const total = self.sizes.items.len;
        try self.offsets.ensureTotalCapacity(allocator, total);
        var packet: usize = 0;
        for (0..runs) |index| {
            if (packet == total) break;
            const record = stsc[8 + 12 * index ..];
            const first = @as(i64, be32(record)) - 1;
            const per = be32(record[4..]);
            const last: i64 = if (index + 1 < runs) @as(i64, be32(stsc[8 + 12 * (index + 1) ..])) - 1 else @intCast(chunks.items.len);
            if (first < 0 or last > chunks.items.len or per == 0) return error.InvalidData;
            var chunk: usize = @intCast(zio.asUnsigned(first));
            while (chunk < last and packet < total) : (chunk += 1) {
                var offset = chunks.items[chunk];
                for (0..per) |_| {
                    if (packet == total) break;
                    self.offsets.appendAssumeCapacity(offset);
                    offset += self.sizes.items[packet];
                    packet += 1;
                }
            }
        }
        self.sizes.shrinkRetainingCapacity(packet);

        // How long each lasts.
        const stts = child(stbl, &.{"stts"}) orelse return error.InvalidData;
        if (stts.len < 8) return error.InvalidData;
        const entries = be32(stts[4..]);
        if (stts.len < 8 + 8 * @as(usize, entries)) return error.InvalidData;
        try self.ends.ensureTotalCapacity(allocator, packet);
        var time: u64 = 0;
        for (0..entries) |index| {
            const count = be32(stts[8 + 8 * index ..]);
            const delta = be32(stts[12 + 8 * index ..]);
            for (0..@min(count, packet - self.ends.items.len)) |_| {
                time += delta;
                self.ends.appendAssumeCapacity(time);
            }
        }
        if (self.ends.items.len == 0) return error.InvalidData;
        self.sizes.shrinkRetainingCapacity(self.ends.items.len);
        self.offsets.shrinkRetainingCapacity(self.ends.items.len);
    }

    /// How long a fragmented track is, from the segment index before its
    /// first fragment, if there's one.
    fn readIndex(self: *Movie, input: Input, size: u64) Error!void {
        var head: [8]u8 = undefined;
        var offset = self.next;
        while (offset + 8 <= size) {
            if (try readAt(input, offset, &head) != 8) return;
            const length: u64 = be32(&head);
            if (std.mem.eql(u8, head[4..], "sidx")) {
                if (length < 8 + 24 or length > 1 << 20 or length > size - offset) return;
                const sidx = try self.allocator.alloc(u8, @intCast(length - 8));
                defer self.allocator.free(sidx);
                if (try readAt(input, offset + 8, sidx) != sidx.len) return;
                if (indexDuration(sidx)) |found| self.duration = @intCast(@as(u128, found.duration) * self.timescale / found.timescale);
                return;
            }
            if (std.mem.eql(u8, head[4..], "moof") or std.mem.eql(u8, head[4..], "mdat") or length < 8) return;
            offset += length;
        }
    }

    /// Reads a fragment's header, the body of the moof box at `offset`,
    /// adding where the track's packets are in it to the tables.
    fn fragment(self: *Movie, moof: []const u8, offset: u64) Error!void {
        var boxes: Boxes = .{ .rest = moof };
        while (boxes.next()) |box| {
            if (!std.mem.eql(u8, &box.kind, "traf")) continue;
            const tfhd = child(box.body, &.{"tfhd"}) orelse continue;
            if (tfhd.len < 8 or be32(tfhd[4..]) != self.id) continue;
            const flags = be32(tfhd) & 0xffffff;
            // Where the moof starts, unless it says.
            var base = offset;
            var duration = self.default_duration;
            var size = self.default_size;
            var rest = tfhd[8..];
            if (flags & 0x01 != 0) {
                if (rest.len < 8) return error.InvalidData;
                base = be64(rest);
                rest = rest[8..];
            }
            if (flags & 0x02 != 0) rest = rest[@min(4, rest.len)..]; // the sample description
            if (flags & 0x08 != 0) {
                if (rest.len < 4) return error.InvalidData;
                duration = be32(rest);
                rest = rest[4..];
            }
            if (flags & 0x10 != 0) {
                if (rest.len < 4) return error.InvalidData;
                size = be32(rest);
            }
            var at = base;
            var runs: Boxes = .{ .rest = box.body };
            while (runs.next()) |found| {
                if (std.mem.eql(u8, &found.kind, "trun")) at = try self.run(found.body, base, at, duration, size);
            }
        }
    }

    /// Reads a track run: packets one after another, from `at` unless it
    /// says where from `base`. Returns where the next run starts.
    fn run(self: *Movie, trun: []const u8, base: u64, from: u64, default_duration: u32, default_size: u32) Error!u64 {
        if (trun.len < 8) return error.InvalidData;
        const flags = be32(trun) & 0xffffff;
        const count = be32(trun[4..]);
        var rest = trun[8..];
        var at = from;
        if (flags & 0x01 != 0) {
            if (rest.len < 4) return error.InvalidData;
            const moved = @as(i64, @intCast(base)) + @as(i32, @bitCast(be32(rest)));
            if (moved < 0) return error.InvalidData;
            at = zio.asUnsigned(moved);
            rest = rest[4..];
        }
        if (flags & 0x04 != 0) { // the first packet's flags
            if (rest.len < 4) return error.InvalidData;
            rest = rest[4..];
        }
        var per: usize = 0;
        for ([_]u32{ 0x100, 0x200, 0x400, 0x800 }) |flag| {
            if (flags & flag != 0) per += 4;
        }
        if (count > max_packets or rest.len < @as(usize, count) * per or self.sizes.items.len + count > max_packets) return error.InvalidData;
        var time: u64 = if (self.ends.items.len > 0) self.ends.items[self.ends.items.len - 1] else 0;
        try self.offsets.ensureUnusedCapacity(self.allocator, count);
        try self.sizes.ensureUnusedCapacity(self.allocator, count);
        try self.ends.ensureUnusedCapacity(self.allocator, count);
        for (0..count) |index| {
            var fields = rest[index * per ..];
            var duration = default_duration;
            var size = default_size;
            if (flags & 0x100 != 0) {
                duration = be32(fields);
                fields = fields[4..];
            }
            if (flags & 0x200 != 0) size = be32(fields);
            time += duration;
            self.offsets.appendAssumeCapacity(at);
            self.sizes.appendAssumeCapacity(size);
            self.ends.appendAssumeCapacity(time);
            at += size;
        }
        return at;
    }
};

/// Whether a sample table lists any packets: a fragmented file's lists
/// none, its packets being in the fragments.
fn hasPackets(stbl: []const u8) bool {
    if (child(stbl, &.{"stsz"})) |stsz| return stsz.len >= 12 and be32(stsz[8..]) > 0;
    if (child(stbl, &.{"stz2"})) |stz2| return stz2.len >= 12 and be32(stz2[8..]) > 0;
    return false;
}

/// The durations of the segments a segment index lists, added up, and the
/// timescale they're in.
fn indexDuration(sidx: []const u8) ?struct { duration: u64, timescale: u64 } {
    const at: usize = if (sidx.len > 0 and sidx[0] == 1) 28 else 20;
    if (sidx.len < at + 4) return null;
    const timescale = be32(sidx[8..]);
    if (timescale == 0) return null;
    const count = be16(sidx[at + 2 ..]);
    const references = sidx[at + 4 ..];
    if (references.len < 12 * @as(usize, count)) return null;
    var duration: u64 = 0;
    for (0..count) |index| duration += be32(references[12 * index + 4 ..]);
    if (duration == 0) return null;
    return .{ .duration = duration, .timescale = timescale };
}

/// AAC's AudioSpecificConfig, from an elementary stream's descriptors: the
/// DecoderSpecificInfo of MPEG-4 audio, or of MPEG-2 AAC's profiles.
fn decoderConfig(bytes: []const u8) ?[]const u8 {
    const es = descriptor(bytes, 3) orelse return null;
    if (es.len < 3) return null;
    const flags = es[2];
    var rest = es[3..];
    if (flags & 0x80 != 0) rest = rest[@min(2, rest.len)..]; // depends on a stream
    if (flags & 0x40 != 0 and rest.len > 0) rest = rest[@min(1 + @as(usize, rest[0]), rest.len)..]; // a URL
    if (flags & 0x20 != 0) rest = rest[@min(2, rest.len)..]; // an OCR stream
    const config = descriptor(rest, 4) orelse return null;
    if (config.len < 13) return null;
    switch (config[0]) {
        0x40, 0x66, 0x67, 0x68 => {},
        else => return null,
    }
    const info = descriptor(config[13..], 5) orelse return null;
    return if (info.len >= 2) info else null;
}

fn descriptor(bytes: []const u8, tag: u8) ?[]const u8 {
    if (bytes.len < 2 or bytes[0] != tag) return null;
    var rest = bytes[1..];
    var length: usize = 0;
    for (0..4) |_| {
        if (rest.len == 0) break;
        const byte = rest[0];
        rest = rest[1..];
        length = length << 7 | (byte & 0x7f);
        if (byte & 0x80 == 0) break;
    }
    return if (length <= rest.len) rest[0..length] else null;
}

/// Decodes packets, from where the container says they are: the movie's
/// tables, its fragments as they're reached, or ADTS frames. A seek goes to
/// the packet holding the frame asked for.
pub const Packets = struct {
    allocator: std.mem.Allocator,
    input: Input,
    codec: Codec,
    offsets: std.ArrayList(u64) = .empty,
    sizes: std.ArrayList(u32) = .empty,
    /// Where each packet ends, in frames.
    ends: std.ArrayList(u64) = .empty,
    /// Where the last packet found ends, in frames, as the file says, when
    /// `ends` places packets by the codec's `packet_frames` instead.
    last: u64 = 0,
    /// Of a fragmented file: its fragments still to find.
    movie: ?Movie = null,
    /// The encoder's priming, in frames, to drop.
    prime: u64 = 0,
    /// The length, if known; exact once every packet is found, when what's
    /// past it is padding, dropped.
    frames: ?u64 = null,
    exact: bool = false,
    /// The packet decoded next, the frame `read` gives next, and the frames
    /// to drop before it.
    next: usize = 0,
    position: u64 = 0,
    skip: u64 = 0,
    packet: std.ArrayList(u8) = .empty,
    out: []f32,
    pending: []f32 = &.{},

    pub fn create(allocator: std.mem.Allocator, input: Input, codec: Codec) Error!*Packets {
        const self = try allocator.create(Packets);
        errdefer allocator.destroy(self);
        const out = try allocator.alloc(f32, @as(usize, codec.max_frames) * codec.channels);
        self.* = .{ .allocator = allocator, .input = input, .codec = codec, .out = out };
        return self;
    }

    /// Frees the packets' tables, but not the codec.
    pub fn destroy(self: *Packets) void {
        self.offsets.deinit(self.allocator);
        self.sizes.deinit(self.allocator);
        self.ends.deinit(self.allocator);
        self.packet.deinit(self.allocator);
        if (self.movie) |*movie| movie.deinit();
        self.allocator.free(self.out);
        self.allocator.destroy(self);
    }

    pub fn decoder(self: *Packets) Decoder {
        return .{ .context = self, .vtable = &vtable, .sample_rate = self.codec.sample_rate, .channels = self.codec.channels, .frames = self.frames };
    }

    /// Adds a packet of `size` bytes at `offset`, ending at `end` frames
    /// as the file says.
    pub fn add(self: *Packets, offset: u64, size: u32, end: u64) Error!void {
        var placed = end;
        if (self.codec.packet_frames > 0) {
            self.last = end;
            placed = (self.ends.items.len + 1) * @as(u64, self.codec.packet_frames);
        }
        try self.offsets.append(self.allocator, offset);
        try self.sizes.append(self.allocator, size);
        try self.ends.append(self.allocator, placed);
    }

    /// Where the packets found end, in frames, as the file says.
    pub fn length(self: *const Packets) u64 {
        if (self.last > 0) return self.last;
        return if (self.ends.items.len > 0) self.ends.items[self.ends.items.len - 1] else 0;
    }

    fn packetStart(self: *const Packets, index: usize) u64 {
        return if (index == 0) 0 else self.ends.items[index - 1];
    }

    /// Whether packet `index` is known, finding more if need be.
    fn have(self: *Packets, index: usize) Error!bool {
        while (index >= self.offsets.items.len) {
            if (!try self.findMore()) return false;
        }
        return true;
    }

    /// Finds the next fragment's packets, if any are left to find. Once all
    /// are, the length is known.
    fn findMore(self: *Packets) Error!bool {
        const movie = if (self.movie) |*movie| movie else return false;
        if (try self.nextFragment(movie)) return true;
        movie.deinit();
        self.movie = null;
        if (self.ends.items.len > 0) {
            self.frames = self.length() -| self.prime;
            self.exact = true;
        }
        return false;
    }

    fn nextFragment(self: *Packets, movie: *Movie) Error!bool {
        const size = try self.input.size();
        var head: [16]u8 = undefined;
        while (movie.next + 8 <= size) {
            if (try readAt(self.input, movie.next, head[0..8]) != 8) return false;
            var box_length: u64 = be32(&head);
            var header: u64 = 8;
            if (box_length == 1) {
                if (try readAt(self.input, movie.next + 8, head[8..16]) != 8) return false;
                box_length = be64(head[8..]);
                header = 16;
            }
            // To the end, or broken: no more fragments.
            if (box_length < header) return false;
            const at = movie.next;
            movie.next += box_length;
            if (!std.mem.eql(u8, head[4..8], "moof")) continue;
            if (box_length > max_fragment) return false;
            const moof = try self.allocator.alloc(u8, @intCast(box_length - header));
            defer self.allocator.free(moof);
            if (try readAt(self.input, at + header, moof) != moof.len) return false;
            const found = movie.sizes.items.len;
            movie.fragment(moof, at) catch |err| switch (err) {
                error.InvalidData => return false,
                else => |other| return other,
            };
            const rate = self.codec.sample_rate;
            for (movie.offsets.items[found..], movie.sizes.items[found..], movie.ends.items[found..]) |offset, packet_size, end| {
                try self.add(offset, packet_size, scale(end, rate, movie.timescale));
            }
            if (movie.sizes.items.len > found) return true;
        }
        return false;
    }

    fn read(context: *anyopaque, buffer: []f32) Error!usize {
        const self: *Packets = @ptrCast(@alignCast(context));
        const channels: usize = self.codec.channels;
        while (self.pending.len == 0) {
            if (!try self.have(self.next)) return 0;
            // Whether this is the last packet, whose padding is dropped:
            // the next fragment's are found, if any.
            if (!self.exact) _ = try self.have(self.next + 1);
            const size = self.sizes.items[self.next];
            try self.packet.resize(self.allocator, size);
            // Cut short: the end.
            if (try readAt(self.input, self.offsets.items[self.next], self.packet.items) != size) return 0;
            self.next += 1;
            const frames = self.codec.decode(self.packet.items, self.out) catch |err| switch (err) {
                // A packet gone bad: on to the next.
                error.InvalidData, error.UnsupportedEncoding => continue,
                else => |other| return other,
            };
            const drop = @min(self.skip, frames);
            self.skip -= drop;
            self.pending = self.out[@intCast(drop * channels) .. frames * channels];
        }
        var count = @min(buffer.len / channels, self.pending.len / channels);
        if (self.exact) {
            // What the encoder padded the last packet with.
            const left = self.frames.? -| self.position;
            if (left == 0) {
                self.pending = &.{};
                return 0;
            }
            count = @intCast(@min(count, left));
        }
        @memcpy(buffer[0 .. count * channels], self.pending[0 .. count * channels]);
        self.pending = self.pending[count * channels ..];
        self.position += count;
        return count * channels;
    }

    fn setPosition(context: *anyopaque, frame: u64) Error!void {
        const self: *Packets = @ptrCast(@alignCast(context));
        if (self.frames) |frames| if (frame > frames) return error.OutOfRange;
        const at = frame + self.prime;
        while (self.ends.items.len == 0 or self.ends.items[self.ends.items.len - 1] <= at) {
            if (!try self.findMore()) break;
        }
        // The first packet ending after `at`.
        var low: usize = 0;
        var high = self.ends.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.ends.items[middle] > at) high = middle else low = middle + 1;
        }
        const start = low -| self.codec.preroll;
        self.codec.reset();
        self.next = start;
        self.position = frame;
        self.skip = at -| self.packetStart(start);
        self.pending = &.{};
    }

    fn deinit(context: *anyopaque) void {
        const self: *Packets = @ptrCast(@alignCast(context));
        self.codec.deinit();
        self.destroy();
    }

    const vtable: Decoder.VTable = .{ .read = read, .setPosition = setPosition, .deinit = deinit };
};
