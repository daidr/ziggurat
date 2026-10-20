const std = @import("std");
const decoding = @import("decoder.zig");
const Error = decoding.Error;

/// Audio decoded into memory, for effects that play often and over
/// themselves: every play is a player of its own over the same samples.
/// Reference counted, so that players keep what they play alive: whoever
/// creates or retains one releases it once.
pub const Sound = struct {
    allocator: std.mem.Allocator,
    /// Interleaved frames of `channels` samples.
    samples: []f32,
    /// 1 (mono) or 2 (stereo).
    channels: u8,
    sample_rate: u32,
    references: std.atomic.Value(u32) = .init(1),

    /// Decodes data of one of `formats` into memory.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, formats: []const decoding.Format) Error!*Sound {
        var input = decoding.BytesInput{ .bytes = bytes };
        const opened = try decoding.open(allocator, input.input(), formats);
        defer opened.decoder.deinit();
        return fromDecoder(allocator, opened.decoder);
    }

    /// Decodes everything `decoder` has into memory, keeping at most two
    /// channels. The decoder stays the caller's.
    pub fn fromDecoder(allocator: std.mem.Allocator, decoder: decoding.Decoder) Error!*Sound {
        const channels: usize = decoder.channels;
        if (channels < 1 or decoder.sample_rate == 0) return error.InvalidData;
        const keep: usize = @min(channels, 2);
        var samples: std.ArrayList(f32) = .empty;
        defer samples.deinit(allocator);
        if (decoder.frames) |count| try samples.ensureTotalCapacity(allocator, @intCast(@min(count, 1 << 28) * keep));
        var buffer: [4096]f32 = undefined;
        const chunk = buffer[0 .. buffer.len / channels * channels];
        while (true) {
            var count = try decoder.read(chunk);
            if (count == 0) break;
            count -= count % channels;
            var index: usize = 0;
            while (index < count) : (index += channels) try samples.appendSlice(allocator, chunk[index..][0..keep]);
        }
        const self = try allocator.create(Sound);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .samples = try samples.toOwnedSlice(allocator), .channels = @intCast(keep), .sample_rate = decoder.sample_rate };
        return self;
    }

    /// A sound of a copy of `samples`, interleaved frames of 1 (mono) or 2
    /// (stereo) channels at `sample_rate` frames per second, as an app
    /// generates them.
    pub fn fromSamples(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, samples: []const f32) error{ OutOfMemory, InvalidData }!*Sound {
        if (channels != 1 and channels != 2 or sample_rate == 0) return error.InvalidData;
        const self = try allocator.create(Sound);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .samples = try allocator.dupe(f32, samples[0 .. samples.len / channels * channels]), .channels = channels, .sample_rate = sample_rate };
        return self;
    }

    pub fn retain(self: *Sound) *Sound {
        _ = self.references.fetchAdd(1, .monotonic);
        return self;
    }

    /// Frees the sound once nothing holds it.
    pub fn release(self: *Sound) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        allocator.free(self.samples);
        allocator.destroy(self);
    }

    pub fn frames(self: *const Sound) u64 {
        return self.samples.len / self.channels;
    }

    /// How long the sound plays, in nanoseconds.
    pub fn duration(self: *const Sound) u64 {
        return framesToNanoseconds(self.frames(), self.sample_rate);
    }
};

pub fn framesToNanoseconds(count: u64, rate: u32) u64 {
    return @intFromFloat(@as(f64, @floatFromInt(count)) * std.time.ns_per_s / @as(f64, @floatFromInt(rate)));
}

test "sounds of samples copy and keep whole frames" {
    var samples = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    const sound = try Sound.fromSamples(std.testing.allocator, 1000, 2, &samples);
    samples[0] = 1;
    try std.testing.expectEqual(@as(u64, 2), sound.frames());
    try std.testing.expectEqual(@as(f32, 0.1), sound.samples[0]);
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_ms), sound.duration());
    _ = sound.retain();
    sound.release();
    sound.release();
    try std.testing.expectError(error.InvalidData, Sound.fromSamples(std.testing.allocator, 1000, 3, &samples));
}

test "sounds decode under every allocation failure without leaks" {
    const flac = @import("flac.zig");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const sound = try Sound.decode(allocator, @embedFile("testdata/mono24.flac"), &.{flac.format});
            defer sound.release();
            try std.testing.expectEqual(@as(u64, 12000), sound.frames());
        }
    }.run, .{});
}

test "unknown data is no sound" {
    const wav = @import("wav.zig");
    try std.testing.expectError(error.UnknownFormat, Sound.decode(std.testing.allocator, "not audio at all", &.{wav.format}));
}
