//! Time-stretches a voice's source for `Player.setPreservesPitch`, by WSOLA
//! (waveform similarity overlap-add): it plays segments of the source, two
//! hops long, half overlapping, crossfaded with a Hann window, one hop of
//! the output each. Where the speed puts the next segment, it looks within
//! a tolerance for the start most like the natural continuation of the
//! last, so that the waveform goes on without a seam, skipping or
//! repeating whole periods of it; the pitch stays. The voice then
//! resamples what it gives at its rate alone, without its speed.
//!
//! A voice gets one the first time its player preserves pitch and keeps
//! it: with it off, it passes the source through as it is, which a voice
//! without one reads itself. Stretching never allocates or blocks.
const std = @import("std");
const Source = @import("mixer.zig").Source;
const Read = @import("stream.zig").Stream.Read;

pub const Stretcher = struct {
    allocator: std.mem.Allocator,
    /// Channels of the source: 1 or 2.
    channels: usize,
    /// A hop: half a segment, about 16 ms.
    hop: usize,
    /// How far a segment may move to match, about 10 ms.
    delta: i64,
    /// The stride of the coarse search: about 16 kHz.
    stride: usize,
    window: []f32,

    /// Frames of the source from frame `base`, `count` of them. `read_at`
    /// is the frame read next: base + count, or before base while skipping
    /// up to it.
    buffer: []f32,
    base: i64 = 0,
    count: usize = 0,
    read_at: i64 = 0,
    /// The frame after the source's last, once it ended, or -1.
    end: i64 = -1,
    /// Frames of `buffer` a pass-through read gave, dropped at the next.
    held: usize = 0,

    /// The frames searched, mixed to mono.
    mono: []f32,
    /// `tail`, mixed to mono.
    tail_mono: []f32,
    /// A hop of the natural continuation of the last segment.
    tail: []f32,
    /// The frame `tail` starts at.
    natural: i64 = 0,
    /// A hop: what a step gives.
    out: []f32,
    /// The source's frames, passed through.
    own: []f32,

    /// Stretching, rather than passing the source through.
    on: bool = false,
    /// No segment yet since it started stretching.
    first: bool = true,
    /// Nothing more to give.
    done: bool = false,
    /// The frame the speed puts the next segment at.
    analysis: f64 = 0,

    /// The source frames, counted on past its loop's end, that the frames
    /// of the voice's history are at; those of what it read last, from
    /// `tag0` by `tag_step`; and where the frames after them are.
    tags: [4]f64 = @splat(0),
    tag0: f64 = 0,
    tag_step: f64 = 1,
    next: f64 = 0,
    /// What the last read gave the voice, interleaved.
    current: []const f32 = &.{},

    pub fn create(allocator: std.mem.Allocator, rate: u32, channels: usize) !*Stretcher {
        const rate_frames: usize = rate;
        const hop = @max(rate_frames / 64, 16);
        const delta = @max(rate_frames / 96, 8);
        // The frames a step reads at most, and what a voice hands over.
        const size = @max(2 * delta + 2 * hop + 1, 256);
        const self = try allocator.create(Stretcher);
        errdefer allocator.destroy(self);
        const window = try allocator.alloc(f32, hop);
        errdefer allocator.free(window);
        const buffer = try allocator.alloc(f32, size * channels);
        errdefer allocator.free(buffer);
        const mono = try allocator.alloc(f32, 2 * delta + hop + 1);
        errdefer allocator.free(mono);
        const tail_mono = try allocator.alloc(f32, hop);
        errdefer allocator.free(tail_mono);
        const tail = try allocator.alloc(f32, hop * channels);
        errdefer allocator.free(tail);
        const out = try allocator.alloc(f32, hop * channels);
        errdefer allocator.free(out);
        const own = try allocator.alloc(f32, 256 * channels);
        self.* = .{ .allocator = allocator, .channels = channels, .hop = hop, .delta = @intCast(delta), .stride = @max(rate_frames / 16000, 1), .window = window, .buffer = buffer, .mono = mono, .tail_mono = tail_mono, .tail = tail, .out = out, .own = own };
        for (window, 0..) |*weight, index| {
            const s = @sin(std.math.pi / 2.0 * (@as(f64, @floatFromInt(index)) + 0.5) / @as(f64, @floatFromInt(hop)));
            weight.* = @floatCast(s * s);
        }
        @memset(tail, 0);
        return self;
    }

    pub fn destroy(self: *Stretcher) void {
        const allocator = self.allocator;
        for ([_][]f32{ self.window, self.buffer, self.mono, self.tail_mono, self.tail, self.out, self.own }) |slice| allocator.free(slice);
        allocator.destroy(self);
    }

    /// Starts over at frame `frame`, from which the source reads next, and
    /// sets the voice's frames before it, which it has not read yet, at the
    /// frames before it.
    pub fn reset(self: *Stretcher, frame: i64, on: bool) void {
        self.base = frame;
        self.read_at = frame;
        self.count = 0;
        self.held = 0;
        self.end = -1;
        self.on = on;
        self.first = true;
        self.done = false;
        self.analysis = @floatFromInt(frame);
        self.next = @floatFromInt(frame);
        // The voice's second frame of history is at its index: frame - 3
        // after a reset.
        for (&self.tags, 0..) |*tag, k| tag.* = @floatFromInt(frame - 4 + @as(i64, @intCast(k)));
    }

    /// Notes the frame that comes into the voice's history at `tag`.
    pub fn push(self: *Stretcher, tag: f64) void {
        self.tags[0] = self.tags[1];
        self.tags[1] = self.tags[2];
        self.tags[2] = self.tags[3];
        self.tags[3] = tag;
    }

    /// Forgets the frames before `to`; those not read yet are skipped.
    fn drop(self: *Stretcher, to: i64) void {
        if (to <= self.base) return;
        const k = to - self.base;
        if (k < @as(i64, @intCast(self.count))) {
            const skip: usize = @intCast(k);
            self.count -= skip;
            std.mem.copyForwards(f32, self.buffer[0 .. self.count * self.channels], self.buffer[skip * self.channels ..][0 .. self.count * self.channels]);
        } else self.count = 0;
        self.base = to;
    }

    /// Reads the source up to frame `upto`, or its end; false while a
    /// stream has not decoded that far.
    fn fill(self: *Stretcher, source: *Source, upto: i64) bool {
        const channels = self.channels;
        const capacity = self.buffer.len / channels;
        while (self.end < 0 and self.read_at < upto) {
            const skip = self.read_at < self.base;
            const destination = if (skip)
                self.buffer[0 .. @as(usize, @intCast(@min(self.base - self.read_at, @as(i64, @intCast(capacity))))) * channels]
            else
                self.buffer[self.count * channels .. (self.count + @as(usize, @intCast(@min(upto - self.read_at, @as(i64, @intCast(capacity - self.count)))))) * channels];
            const result = source.read(destination);
            if (!skip) self.count += result.frames;
            self.read_at += @intCast(result.frames);
            if (result.ended) {
                self.end = self.read_at;
            } else if (result.frames == 0) return false;
        }
        if (self.end >= 0 and self.base + @as(i64, @intCast(self.count)) < upto) {
            // Silence after the end.
            const k: usize = @intCast(upto - self.base);
            @memset(self.buffer[self.count * channels .. k * channels], 0);
            self.count = k;
        }
        return true;
    }

    /// Gives the voice its next frames in `current`, as a source does:
    /// time-stretched while `pitch` holds, else as the source has them.
    pub fn read(self: *Stretcher, source: *Source, pitch: bool, speed: f64) Read {
        if (self.held > 0) {
            self.drop(self.base + @as(i64, @intCast(self.held)));
            self.held = 0;
        }
        if (self.done) return .{ .frames = 0, .ended = true };
        if (pitch != self.on) {
            // From what is held, which goes on from the last segment.
            if (pitch) {
                self.first = true;
                self.analysis = @floatFromInt(self.base);
            } else if (!self.first and self.natural >= self.base) self.drop(self.natural);
            if (self.end >= 0) {
                // Not the silence after the end.
                self.count = @intCast(@max(@min(@as(i64, @intCast(self.count)), self.end - self.base), 0));
            }
            self.on = pitch;
        }
        if (self.on) {
            const result = self.stretch(source, speed);
            self.current = self.out;
            return result;
        }
        self.tag_step = 1;
        if (self.count > 0) {
            self.tag0 = @floatFromInt(self.base);
            self.held = self.count;
            self.next = @floatFromInt(self.base + @as(i64, @intCast(self.count)));
            self.current = self.buffer;
            return .{ .frames = self.count, .ended = false };
        }
        const result = source.read(self.own);
        self.tag0 = @floatFromInt(self.read_at);
        self.read_at += @intCast(result.frames);
        self.base = self.read_at;
        self.next = @floatFromInt(self.read_at);
        self.current = self.own;
        return result;
    }

    /// Puts the next frames into `out` and says how many, ended once there
    /// are none, and none while a stream is late.
    fn stretch(self: *Stretcher, source: *Source, speed: f64) Read {
        const hop = self.hop;
        const channels = self.channels;
        const a: i64 = @intFromFloat(@round(self.analysis));
        var lo = a;
        var hi = a;
        if (!self.first) {
            lo = @max(a - self.delta, self.base);
            hi = @max(a + self.delta, lo);
        }
        self.drop(lo);
        if (!self.fill(source, hi + @as(i64, @intCast(2 * hop)))) return .{ .frames = 0, .ended = false };
        if (self.end >= 0 and a >= self.end) {
            // The speed is past the end: what was playing fades out.
            self.done = true;
            self.next = @floatFromInt(self.end);
            if (self.first) return .{ .frames = 0, .ended = true };
            for (0..hop) |j| {
                const weight = 1 - self.window[j];
                for (j * channels..(j + 1) * channels) |k| self.out[k] = self.tail[k] * weight;
            }
            self.tag0 = @floatFromInt(self.end);
            self.tag_step = 0;
            return .{ .frames = hop, .ended = false };
        }
        const start = if (self.first) lo else self.best(lo, hi);
        const input = self.buffer[@as(usize, @intCast(start - self.base)) * channels ..];
        const out = self.out[0 .. hop * channels];
        if (self.first or start == self.natural) {
            // No seam: the source as it is.
            @memcpy(out, input[0 .. hop * channels]);
        } else {
            for (0..hop) |j| {
                const weight = self.window[j];
                for (j * channels..(j + 1) * channels) |k| out[k] = self.tail[k] + (input[k] - self.tail[k]) * weight;
            }
        }
        @memcpy(self.tail, input[hop * channels .. 2 * hop * channels]);
        self.first = false;
        self.natural = start + @as(i64, @intCast(hop));
        self.tag0 = self.analysis;
        self.tag_step = speed;
        self.analysis += @as(f64, @floatFromInt(hop)) * speed;
        self.next = self.analysis;
        if (self.end >= 0 and self.next > @as(f64, @floatFromInt(self.end))) {
            // Where the source ends, the frames after are at its end.
            const end: f64 = @floatFromInt(self.end);
            self.tag_step = @max(end - self.tag0, 0) / @as(f64, @floatFromInt(hop));
            self.next = end;
        }
        return .{ .frames = hop, .ended = false };
    }

    /// The start between `lo` and `hi` of the segment whose first hop is
    /// most like `tail`, by normalized cross-correlation in mono: every
    /// `stride` frames, then each frame around the best.
    fn best(self: *Stretcher, lo: i64, hi: i64) i64 {
        // The natural continuation itself: a perfect match.
        if (self.natural >= lo and self.natural <= hi) return self.natural;
        const hop = self.hop;
        const span: usize = @intCast(hi - lo);
        const offset: usize = @intCast(lo - self.base);
        const m = self.mono[0 .. span + hop];
        const t = self.tail_mono;
        if (self.channels == 1) {
            @memcpy(m, self.buffer[offset..][0..m.len]);
            @memcpy(t, self.tail[0..hop]);
        } else {
            for (m, 0..) |*value, i| value.* = self.buffer[2 * (offset + i)] + self.buffer[2 * (offset + i) + 1];
            for (t, 0..) |*value, i| value.* = self.tail[2 * i] + self.tail[2 * i + 1];
        }
        const Score = struct {
            fn of(mono: []const f32, tail: []const f32, length: usize, s: usize, stride: usize) f32 {
                var xy: f32 = 0;
                var yy: f32 = 0;
                const y = mono[s..][0..length];
                var j: usize = 0;
                while (j < length) : (j += stride) {
                    xy += tail[j] * y[j];
                    yy += y[j] * y[j];
                }
                if (yy == 0) return 0;
                return xy / @sqrt(yy);
            }
        };
        const stride = self.stride;
        var found: usize = 0;
        var found_score = -std.math.inf(f32);
        var s: usize = 0;
        while (s <= span) : (s += stride) {
            const x = Score.of(m, t, hop, s, stride);
            if (x > found_score) {
                found = s;
                found_score = x;
            }
        }
        if (stride > 1) {
            const coarse = found;
            found_score = -std.math.inf(f32);
            var fine = if (coarse + 1 > stride) coarse + 1 - stride else 0;
            while (fine <= @min(coarse + stride - 1, span)) : (fine += 1) {
                const x = Score.of(m, t, hop, fine, 1);
                if (x > found_score) {
                    found = fine;
                    found_score = x;
                }
            }
        }
        return lo + @as(i64, @intCast(found));
    }
};
