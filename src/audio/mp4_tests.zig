//! MP4, AAC and Apple Lossless, of half a second of 440 Hz at half scale
//! on the left and 660 Hz at 0.4 on the right, at 44.1 kHz, in every
//! container and codec the engine reads it in.
const std = @import("std");
const decoding = @import("decoder.zig");
const engine = @import("engine.zig");
const mp4 = @import("mp4.zig");
const aac = @import("aac.zig");

const rate = 44100;
const length = 22050;

/// Pull request checks set ZIGGURAT_QUICK_TESTS (zig build -Dquick-tests):
/// the corruption test then damages each file 10 times instead of 40.
fn quick() bool {
    return std.testing.environ.containsConstant("ZIGGURAT_QUICK_TESTS");
}

fn tone(frame: usize, channel: usize) f32 {
    const t = @as(f64, @floatFromInt(frame)) / rate;
    const value = if (channel == 0) 0.5 * @sin(2 * std.math.pi * 440 * t) else 0.4 * @sin(2 * std.math.pi * 660 * t);
    return @floatCast(value);
}

const Decoded = struct {
    decoder: decoding.Decoder,
    samples: []f32,
    format: []const u8,

    fn deinit(self: Decoded) void {
        self.decoder.deinit();
        std.testing.allocator.free(self.samples);
    }
};

fn decodeAll(bytes: []const u8, input: *decoding.BytesInput) !Decoded {
    const allocator = std.testing.allocator;
    input.* = .{ .bytes = bytes };
    const opened = try decoding.open(allocator, input.input(), &engine.default_formats);
    errdefer opened.decoder.deinit();
    var samples: std.ArrayList(f32) = .empty;
    errdefer samples.deinit(allocator);
    var buffer: [1000]f32 = undefined;
    while (true) {
        const count = try opened.decoder.read(&buffer);
        if (count == 0) break;
        try samples.appendSlice(allocator, buffer[0..count]);
    }
    return .{ .decoder = opened.decoder, .samples = try samples.toOwnedSlice(allocator), .format = opened.format };
}

/// The signal to noise ratio of `samples` to the tone `delay` frames
/// later, over frames `from` to `to` of the tone, in decibels.
fn snr(samples: []const f32, delay: usize, from: usize, to: usize) f64 {
    var signal: f64 = 0;
    var noise: f64 = 0;
    for (from..to) |frame| {
        for (0..2) |channel| {
            const want = tone(frame, channel);
            const got = samples[(frame + delay) * 2 + channel];
            signal += want * want;
            noise += (got - want) * (got - want);
        }
    }
    return 10 * std.math.log10(signal / @max(noise, 1e-30));
}

/// Seeks return what decoding straight through does: of AAC, but for the
/// noise its noise substitution draws.
fn expectSeeks(decoded: Decoded, tolerance: f32) !void {
    const decoder = decoded.decoder;
    const total = decoded.samples.len / 2;
    for ([_]usize{ 10000, 1, 5000, 1023, 1024, 20000, 0 }) |target| {
        try decoder.setPosition(target);
        var buffer: [256]f32 = undefined;
        const count = try decoder.read(&buffer);
        const want = @min(buffer.len, (total - target) * 2);
        try std.testing.expect(count > 0 and count <= want);
        for (buffer[0..count], decoded.samples[target * 2 ..][0..count]) |seeked, straight| try std.testing.expectApproxEqAbs(straight, seeked, tolerance);
    }
    try decoder.setPosition(total);
    var buffer: [16]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try decoder.read(&buffer));
}

test "AAC in MP4 drops the priming and the padding, and seeks" {
    var input: decoding.BytesInput = undefined;
    const decoded = try decodeAll(@embedFile("testdata/tone.m4a"), &input);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("mp4", decoded.format);
    try std.testing.expectEqual(@as(u32, rate), decoded.decoder.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), decoded.decoder.channels);
    try std.testing.expectEqual(@as(?u64, length), decoded.decoder.frames);
    try std.testing.expectEqual(@as(usize, length * 2), decoded.samples.len);
    const ratio = snr(decoded.samples, 0, 1024, length - 1024);
    std.testing.expect(ratio > 25) catch |err| {
        std.debug.print("AAC in MP4: {d:.1} dB\n", .{ratio});
        return err;
    };
    try expectSeeks(decoded, 2e-3);
}

test "AAC in ADTS frames plays every frame, the priming too" {
    var input: decoding.BytesInput = undefined;
    const decoded = try decodeAll(@embedFile("testdata/tone.aac"), &input);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("aac", decoded.format);
    try std.testing.expectEqual(@as(u16, 2), decoded.decoder.channels);
    const frames = decoded.decoder.frames.?;
    try std.testing.expect(frames % aac.frame_length == 0 and frames >= length + 1024);
    try std.testing.expectEqual(frames * 2, decoded.samples.len);
    const ratio = snr(decoded.samples, 1024, 1024, length - 1024);
    std.testing.expect(ratio > 25) catch |err| {
        std.debug.print("ADTS: {d:.1} dB\n", .{ratio});
        return err;
    };
    try expectSeeks(decoded, 2e-3);
}

test "fragmented MP4 finds its fragments as it plays, its length from the index" {
    var input: decoding.BytesInput = undefined;
    const decoded = try decodeAll(@embedFile("testdata/fragmented.m4a"), &input);
    defer decoded.deinit();
    const frames = decoded.decoder.frames.?;
    try std.testing.expect(frames >= length and frames <= length + 2048);
    const delay = decoded.samples.len / 2 - length;
    const ratio = snr(decoded.samples, delay, 1024, length - 1024);
    std.testing.expect(ratio > 25) catch |err| {
        std.debug.print("fragmented: {d:.1} dB, {d} frames\n", .{ ratio, decoded.samples.len / 2 });
        return err;
    };
    try expectSeeks(decoded, 2e-3);
}

test "Apple Lossless and FLAC in MP4 decode exactly" {
    for ([_][]const u8{ @embedFile("testdata/alac.m4a"), @embedFile("testdata/flac.m4a") }) |bytes| {
        var input: decoding.BytesInput = undefined;
        const decoded = try decodeAll(bytes, &input);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(usize, length * 2), decoded.samples.len);
        for (0..length) |frame| {
            for (0..2) |channel| try std.testing.expectApproxEqAbs(tone(frame, channel), decoded.samples[frame * 2 + channel], 1.5 / 32768.0);
        }
        try expectSeeks(decoded, 0);
    }
}

test "the track of an MP4 reads without decoding it" {
    const allocator = std.testing.allocator;
    var input: decoding.BytesInput = .{ .bytes = @embedFile("testdata/tone.m4a") };
    const track = try mp4.readTrack(allocator, input.input());
    defer track.deinit(allocator);
    try std.testing.expectEqualStrings("mp4a", &track.codec);
    try std.testing.expect(!track.fragmented);
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), track.duration);
    try std.testing.expect(track.decodable(allocator, &mp4.default_codecs));
    try std.testing.expect(!track.decodable(allocator, &.{}));
    var fragmented: decoding.BytesInput = .{ .bytes = @embedFile("testdata/fragmented.m4a") };
    const other = try mp4.readTrack(allocator, fragmented.input());
    defer other.deinit(allocator);
    try std.testing.expect(other.fragmented);
    try std.testing.expect(other.duration > 0);
}

test "HE-AAC fails to open, and an ID3 tag hides no format" {
    // AAC-LC at 44.1 kHz in stereo, and HE-AAC: SBR's object type, and
    // AAC-LC with SBR signalled after it.
    _ = try aac.Config.parse(&.{ 0x12, 0x10 });
    try std.testing.expectError(error.UnsupportedEncoding, aac.Config.parse(&.{ 0x2b, 0x92, 0x08, 0x00 }));
    try std.testing.expectError(error.UnsupportedEncoding, aac.Config.parse(&.{ 0x13, 0x90, 0x56, 0xe5, 0xa0 }));
    // An ID3 tag before ADTS frames, and before FLAC.
    const allocator = std.testing.allocator;
    const tag = "ID3\x04\x00\x00\x00\x00\x00\x05abcde";
    for ([_][]const u8{ @embedFile("testdata/tone.aac"), @embedFile("testdata/stereo16.flac") }, [_][]const u8{ "aac", "flac" }) |bytes, name| {
        const tagged = try std.mem.concat(allocator, u8, &.{ tag, bytes });
        defer allocator.free(tagged);
        var input: decoding.BytesInput = .{ .bytes = tagged };
        const opened = try decoding.open(allocator, input.input(), &engine.default_formats);
        defer opened.decoder.deinit();
        try std.testing.expectEqualStrings(name, opened.format);
        var buffer: [64]f32 = undefined;
        try std.testing.expect(try opened.decoder.read(&buffer) > 0);
    }
}

test "MP4 and ADTS open under every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            for ([_][]const u8{ @embedFile("testdata/tone.m4a"), @embedFile("testdata/fragmented.m4a"), @embedFile("testdata/alac.m4a"), @embedFile("testdata/flac.m4a"), @embedFile("testdata/tone.aac") }) |bytes| {
                var input: decoding.BytesInput = .{ .bytes = bytes };
                const opened = try decoding.open(allocator, input.input(), &engine.default_formats);
                defer opened.decoder.deinit();
                var buffer: [4096]f32 = undefined;
                _ = try opened.decoder.read(&buffer);
            }
        }
    }.run, .{});
}

test "the inverse transform is the sum it stands for" {
    var spectrum: [128]f32 = undefined;
    var prng: std.Random.DefaultPrng = .init(5);
    for (&spectrum) |*value| value.* = prng.random().float(f32) * 2 - 1;
    var fast: [256]f32 = undefined;
    aac.testImdct(&spectrum, &fast);
    for (0..256) |n| {
        var sum: f64 = 0;
        for (spectrum, 0..) |value, k| sum += value * @cos(2 * std.math.pi / 256.0 * (@as(f64, @floatFromInt(n)) + 64.5) * (@as(f64, @floatFromInt(k)) + 0.5));
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(sum * 2 / 256)), fast[n], 1e-4);
    }
}

test "corrupt MP4 and ADTS fail to open or skip packets, without leaks" {
    const allocator = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(11);
    for ([_][]const u8{ @embedFile("testdata/tone.m4a"), @embedFile("testdata/fragmented.m4a"), @embedFile("testdata/alac.m4a"), @embedFile("testdata/tone.aac") }) |bytes| {
        for (0..if (quick()) @as(usize, 10) else 40) |_| {
            const copy = try allocator.dupe(u8, bytes);
            defer allocator.free(copy);
            for (0..8) |_| copy[prng.random().uintLessThan(usize, copy.len)] = prng.random().int(u8);
            var input: decoding.BytesInput = .{ .bytes = copy };
            const opened = decoding.open(allocator, input.input(), &engine.default_formats) catch continue;
            defer opened.decoder.deinit();
            var buffer: [2048]f32 = undefined;
            while ((opened.decoder.read(&buffer) catch 0) != 0) {}
        }
    }
}
