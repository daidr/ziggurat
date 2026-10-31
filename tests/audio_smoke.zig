//! Plays a short tone through the system output, or on time without one,
//! and reports which. Passes either way: a machine with no audio device
//! exercises the failure path, one with a device the real backend.
const std = @import("std");
const zio = @import("ziggurat_io");
const audio = @import("ziggurat_audio");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer if (debug_allocator.deinit() == .leak) @panic("leak");
    const allocator = debug_allocator.allocator();
    const engine = try audio.Engine.init(allocator, .{});
    defer engine.deinit();
    var samples: [audio.sample_rate / 5]f32 = undefined;
    for (&samples, 0..) |*sample, index| {
        const time = @as(f32, @floatFromInt(index)) / audio.sample_rate;
        sample.* = 0.05 * @sin(2 * std.math.pi * 440 * time);
    }
    const tone = try audio.Sound.fromSamples(allocator, audio.sample_rate, 1, &samples);
    defer tone.release();
    const started = zio.nanoTimestamp();
    const player = try engine.play(tone);
    var waited: u32 = 0;
    while (player.isPlaying()) : (waited += 1) {
        if (waited > 10_000) return error.PlayerNeverEnded;
        zio.sleep(std.time.ns_per_ms);
    }
    const elapsed = zio.nanoTimestamp() - started;
    // 200 ms of sound plays for about as long, heard or not.
    if (elapsed < 150 * std.time.ns_per_ms) return error.EndedEarly;
    var buffer: [256]u8 = undefined;
    if (engine.outputError()) |err| {
        std.debug.print("audio smoke: no system output ({s}: {s}); played on time in {d} ms\n", .{ @errorName(err), engine.outputErrorDetail(&buffer), @divFloor(elapsed, std.time.ns_per_ms) });
    } else {
        std.debug.print("audio smoke: played through the system output in {d} ms\n", .{@divFloor(elapsed, std.time.ns_per_ms)});
    }
    // A WAV stream opens and plays a moment, then closes with the engine.
    var wav: [44 + samples.len * 2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav);
    try writer.writeAll("RIFF");
    try writer.writeInt(u32, wav.len - 8, .little);
    try writer.writeAll("WAVEfmt ");
    for ([_]u32{ 16, 1 | 1 << 16, audio.sample_rate, audio.sample_rate * 2, 2 | 16 << 16 }) |field| try writer.writeInt(u32, field, .little);
    try writer.writeAll("data");
    try writer.writeInt(u32, samples.len * 2, .little);
    for (samples) |sample| try writer.writeInt(i16, @intFromFloat(sample * 32767), .little);
    const stream = try engine.openStreamBytes(&wav);
    stream.play();
    zio.sleep(50 * std.time.ns_per_ms);
    if (stream.position() == 0) return error.StreamDidNotAdvance;
}
