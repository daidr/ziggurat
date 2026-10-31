//! Mixer, player, stream and notification behavior on a manual engine, and
//! the output thread on a test backend.
const std = @import("std");
const zio = @import("ziggurat_io");
const ziggurat = @import("ziggurat");
const audio = @import("root.zig");
const mixer = @import("mixer.zig");
const Engine = audio.Engine;
const Sound = audio.Sound;
const Player = audio.Player;
const rate = audio.sample_rate;
const ramp_frames = mixer.ramp_frames;
const testing = std.testing;
const allocator = testing.allocator;

fn manual() !*Engine {
    return Engine.init(allocator, .{ .output = .manual });
}

/// Mixes `count` frames, 256 at a time.
fn render(engine: *Engine, count: usize) ![]f32 {
    const out = try allocator.alloc(f32, count * 2);
    var frame: usize = 0;
    while (frame < count) : (frame += 256) {
        const end = @min(count, frame + 256);
        _ = engine.render(out[frame * 2 .. end * 2]);
    }
    return out;
}

fn expectNear(want: f32, got: f32) !void {
    try testing.expectApproxEqAbs(want, got, 1e-4);
}

fn ramp(comptime count: usize) [count]f32 {
    var samples: [count]f32 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = @as(f32, @floatFromInt(index % 100)) / 200;
    return samples;
}

fn sound(channels: u8, samples: []const f32) !*Sound {
    return Sound.fromSamples(allocator, rate, channels, samples);
}

fn nanoseconds(frames: u64) u64 {
    return @import("sound.zig").framesToNanoseconds(frames, rate);
}

fn expectPosition(player: Player, frames: u64) !void {
    const got: i64 = @intCast(player.position());
    const want: i64 = @intCast(nanoseconds(frames));
    try testing.expect(@abs(got - want) <= 1);
}

test "a sound plays as decoded, then silence, and ends" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(1000);
    const click = try sound(1, &samples);
    defer click.release();
    const player = try engine.createPlayer(click);
    defer player.close();
    player.play();
    const out = try render(engine, 1200);
    defer allocator.free(out);
    for (samples, 0..) |sample, index| {
        try expectNear(sample, out[2 * index]);
        try expectNear(sample, out[2 * index + 1]);
    }
    for (1000..1200) |index| try testing.expectEqual(@as(f32, 0), out[2 * index]);
    try testing.expect(!player.isPlaying());
    try testing.expectEqual(player.duration().?, player.position());
    try testing.expectEqual(@as(usize, 0), engine.voices.items.len);
}

test "stereo keeps its channels, overlapping sounds add and clip" {
    const engine = try manual();
    defer engine.deinit();
    const stereo = try sound(2, &.{ 0.1, 0.2, 0.3, 0.4 });
    defer stereo.release();
    _ = try engine.play(stereo);
    var out: [8]f32 = undefined;
    _ = engine.render(out[0..4]);
    for ([_]f32{ 0.1, 0.2, 0.3, 0.4 }, out[0..4]) |want, got| try expectNear(want, got);
    _ = engine.render(&out);
    const quarter = try sound(1, &.{ 0.25, 0.25, 0.25, 0.25 });
    defer quarter.release();
    _ = try engine.play(quarter);
    _ = try engine.play(quarter);
    _ = engine.render(out[0..4]);
    try expectNear(0.5, out[0]);
    const loud = try sound(1, &.{ 0.8, 0.8 });
    defer loud.release();
    _ = try engine.play(loud);
    _ = try engine.play(loud);
    _ = engine.render(out[0..2]);
    try testing.expectEqual(@as(f32, 1), out[0]);
}

test "a played sound frees itself at its end and its handle goes stale" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(100);
    const click = try sound(1, &samples);
    const player = try engine.play(click);
    click.release();
    try testing.expect(player.isValid());
    const out = try render(engine, 200);
    allocator.free(out);
    try testing.expect(!player.isValid());
    player.play();
    try testing.expect(!player.isPlaying());
    // The slot is reused under a new generation.
    const again = try sound(1, &samples);
    defer again.release();
    const next = try engine.createPlayer(again);
    defer next.close();
    try testing.expectEqual(player.index, next.index);
    try testing.expect(!player.isValid());
    try testing.expect(next.isValid());
}

test "playing again after the end starts over" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(100);
    const click = try sound(1, &samples);
    defer click.release();
    const player = try engine.createPlayer(click);
    defer player.close();
    player.play();
    allocator.free(try render(engine, 200));
    player.play();
    try testing.expect(player.isPlaying());
    const out = try render(engine, 100);
    defer allocator.free(out);
    try expectNear(0.25, out[2 * 50]);
}

test "a loop plays again without a gap" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(100);
    const click = try sound(1, &samples);
    defer click.release();
    const player = try engine.createPlayer(click);
    defer player.close();
    player.setLoop(true);
    player.play();
    const out = try render(engine, 350);
    defer allocator.free(out);
    for (0..350) |index| try expectNear(samples[index % 100], out[2 * index]);
    try testing.expect(player.isPlaying());
    try expectPosition(player, 50);
}

test "pause fades out, holds its place, and resumes fading in" {
    const engine = try manual();
    defer engine.deinit();
    const samples = @as([10000]f32, @splat(0.5));
    const tone = try sound(1, &samples);
    defer tone.release();
    const player = try engine.createPlayer(tone);
    defer player.close();
    player.play();
    allocator.free(try render(engine, 1000));
    player.pause();
    try testing.expect(!player.isPlaying());
    var out = try render(engine, ramp_frames + 10);
    try testing.expect(out[0] > 0.45);
    try testing.expect(out[2 * (ramp_frames / 2)] < 0.3 and out[2 * (ramp_frames / 2)] > 0.2);
    try testing.expectEqual(@as(f32, 0), out[2 * (ramp_frames + 5)]);
    try testing.expectEqual(@as(usize, 0), engine.voices.items.len);
    allocator.free(out);
    const at = player.position();
    allocator.free(try render(engine, 500));
    try testing.expectEqual(at, player.position());
    player.play();
    out = try render(engine, ramp_frames + 10);
    defer allocator.free(out);
    try testing.expect(out[0] < 0.05);
    try expectNear(0.5, out[2 * (ramp_frames + 5)]);
}

test "volume changes ramp, and the master volume silences" {
    const engine = try manual();
    defer engine.deinit();
    const samples = @as([10000]f32, @splat(0.5));
    const tone = try sound(1, &samples);
    defer tone.release();
    const player = try engine.play(tone);
    allocator.free(try render(engine, 10));
    player.setVolume(0.5);
    try testing.expectEqual(@as(f64, 0.5), player.volume());
    var out = try render(engine, ramp_frames * 2);
    try testing.expect(out[0] > 0.45);
    try expectNear(0.25, out[2 * (ramp_frames + 10)]);
    allocator.free(out);
    engine.setVolume(0);
    try testing.expectEqual(@as(f64, 0), engine.volume());
    out = try render(engine, ramp_frames * 2);
    defer allocator.free(out);
    try testing.expectEqual(@as(f32, 0), out[2 * (ramp_frames + 10)]);
    player.close();
}

test "mono pans keeping its power; stereo folds one side into the other" {
    const engine = try manual();
    defer engine.deinit();
    const mono = try sound(1, &.{ 0.5, 0.5, 0.5 });
    defer mono.release();
    const left = try engine.createPlayer(mono);
    left.setPan(-1);
    left.play();
    var out: [4]f32 = undefined;
    _ = engine.render(&out);
    try expectNear(0.5 * std.math.sqrt2, out[0]);
    try expectNear(0, out[1]);
    left.close();
    const stereo = try sound(2, &.{ 0.2, 0.4, 0.2, 0.4 });
    defer stereo.release();
    const right = try engine.createPlayer(stereo);
    right.setPan(2);
    try testing.expectEqual(@as(f64, 1), right.pan());
    right.play();
    _ = engine.render(out[0..2]);
    try expectNear(0, out[0]);
    try expectNear(0.6, out[1]);
    right.close();
}

test "speed changes pitch and position; other rates resample" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(1000);
    const click = try sound(1, &samples);
    defer click.release();
    const fast = try engine.createPlayer(click);
    fast.setSpeed(2);
    fast.setSpeed(-1);
    try testing.expectEqual(@as(f64, 2), fast.speed());
    fast.play();
    var out = try render(engine, 100);
    try expectNear(samples[20], out[2 * 10]);
    try expectPosition(fast, 200);
    allocator.free(out);
    fast.close();
    // A 1 kHz sine at 24 kHz plays at 1 kHz.
    var sine: [2400]f32 = undefined;
    for (&sine, 0..) |*sample, index| sample.* = @floatCast(@sin(2 * std.math.pi * 1000 * @as(f64, @floatFromInt(index)) / 24000));
    const low = try Sound.fromSamples(allocator, 24000, 1, &sine);
    defer low.release();
    const player = try engine.createPlayer(low);
    defer player.close();
    player.play();
    out = try render(engine, rate / 20);
    defer allocator.free(out);
    for (100..rate / 20) |index| {
        const want: f32 = @floatCast(@sin(2 * std.math.pi * 1000 * @as(f64, @floatFromInt(index)) / rate));
        try testing.expectApproxEqAbs(want, out[2 * index], 0.01);
    }
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), player.position());
}

test "seek moves the player; stop returns to the start" {
    const engine = try manual();
    defer engine.deinit();
    const samples = try allocator.alloc(f32, rate);
    defer allocator.free(samples);
    for (samples, 0..) |*sample, index| sample.* = @as(f32, @floatFromInt(index % 100)) / 200;
    const long = try sound(1, samples);
    defer long.release();
    const player = try engine.createPlayer(long);
    defer player.close();
    player.seek(500 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), player.position());
    player.play();
    const out = try render(engine, ramp_frames + 20);
    defer allocator.free(out);
    const index = ramp_frames + 10;
    try expectNear(samples[24000 + index], out[2 * index]);
    player.stop();
    try testing.expectEqual(@as(u64, 0), player.position());
    try testing.expect(!player.isPlaying());
    player.seek(std.time.ns_per_s * 10);
    try testing.expectEqual(player.duration().?, player.position());
}

test "a closed player does nothing and leaves the mix" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(1000);
    const click = try sound(1, &samples);
    defer click.release();
    const player = try engine.play(click);
    player.close();
    player.play();
    try testing.expect(!player.isPlaying());
    try testing.expect(!player.isValid());
    allocator.free(try render(engine, 10));
    try testing.expectEqual(@as(usize, 0), engine.voices.items.len);
    // The mixing thread never frees: the next player does.
    const next = try engine.createPlayer(click);
    defer next.close();
    try testing.expectEqual(@as(usize, 1), engine.live);
}

test "a released player plays to its end, or closes at once when paused" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(500);
    const click = try sound(1, &samples);
    defer click.release();
    const playing = try engine.createPlayer(click);
    playing.play();
    playing.release();
    try testing.expect(playing.isPlaying());
    const paused = try engine.createPlayer(click);
    paused.release();
    try testing.expect(!paused.isValid());
    allocator.free(try render(engine, 600));
    try testing.expect(!playing.isValid());
    const next = try engine.createPlayer(click);
    defer next.close();
    try testing.expectEqual(@as(usize, 1), engine.live);
}

test "loop ranges play the intro once, then the range, then on to the end" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(100);
    const click = try sound(1, &samples);
    defer click.release();
    const player = try engine.createPlayer(click);
    defer player.close();
    player.setLoopRange(nanoseconds(30), nanoseconds(60));
    player.play();
    var out = try render(engine, 200);
    for (0..200) |index| {
        const want = if (index >= 60) 30 + (index - 60) % 30 else index;
        try expectNear(samples[want], out[2 * index]);
    }
    try expectPosition(player, 50);
    allocator.free(out);
    player.setLoop(false);
    out = try render(engine, 1000);
    defer allocator.free(out);
    var last: ?usize = null;
    for (0..1000) |index| if (out[2 * index] != 0) {
        last = index;
    };
    try testing.expect(last != null);
    try expectNear(samples[99], out[2 * last.?]);
    try expectNear(samples[60], out[2 * (last.? - 39)]);
    try testing.expect(!player.isPlaying());
}

test "loop ranges out of range loop all of it, or clamp to the end" {
    const engine = try manual();
    defer engine.deinit();
    const samples = ramp(100);
    const click = try sound(1, &samples);
    defer click.release();
    const player = try engine.createPlayer(click);
    defer player.close();
    player.setLoopRange(nanoseconds(60), nanoseconds(30));
    const voice = engine.slots.items[player.index].voice.?;
    try testing.expectEqual(@as(i64, 0), voice.loop_start);
    try testing.expectEqual(@as(i64, 0), voice.loop_end);
    try testing.expect(player.isLooping());
    player.setLoopRange(nanoseconds(10), std.time.ns_per_s * 3600);
    try testing.expectEqual(@as(i64, 10), voice.loop_start);
    try testing.expectEqual(@as(i64, 100), voice.loop_end);
}

/// Generates frames `(i % 1000) / 1000 + channel` of a known length, and
/// counts its deinit.
const Generator = struct {
    channels: u16,
    length: u64,
    position: u64 = 0,
    deinits: *std.atomic.Value(u32),

    fn decoder(self: *Generator) audio.Decoder {
        return .{ .context = self, .vtable = &vtable, .sample_rate = rate, .channels = self.channels, .frames = self.length };
    }

    const vtable: audio.Decoder.VTable = .{ .read = read, .setPosition = setPosition, .deinit = deinit };

    fn read(context: *anyopaque, out: []f32) audio.Error!usize {
        const self: *Generator = @ptrCast(@alignCast(context));
        var count: usize = 0;
        while (count + self.channels <= out.len and self.position < self.length) : (count += self.channels) {
            for (0..self.channels) |channel| out[count + channel] = @as(f32, @floatFromInt(self.position % 1000)) / 1000 + @as(f32, @floatFromInt(channel));
            self.position += 1;
        }
        return count;
    }

    fn setPosition(context: *anyopaque, frame: u64) audio.Error!void {
        const self: *Generator = @ptrCast(@alignCast(context));
        if (frame > self.length) return error.OutOfRange;
        self.position = frame;
    }

    fn deinit(context: *anyopaque) void {
        const self: *Generator = @ptrCast(@alignCast(context));
        _ = self.deinits.fetchAdd(1, .monotonic);
        allocator.destroy(self);
    }
};

fn generator(channels: u16, length: u64, deinits: *std.atomic.Value(u32)) !audio.Decoder {
    const self = try allocator.create(Generator);
    self.* = .{ .channels = channels, .length = length, .deinits = deinits };
    return self.decoder();
}

test "a stream plays as decoded, keeps two channels, and closes its decoder" {
    const engine = try manual();
    defer engine.deinit();
    var deinits: std.atomic.Value(u32) = .init(0);
    const player = try engine.newPlayer(try generator(3, 5000, &deinits));
    try testing.expectEqual(nanoseconds(5000), player.duration().?);
    engine.decode();
    player.play();
    const out = try render(engine, 1000);
    defer allocator.free(out);
    for (0..1000) |index| {
        try expectNear(@as(f32, @floatFromInt(index)) / 1000, out[2 * index]);
        // The second channel exceeds 1 and clips.
        try expectNear(@min(@as(f32, @floatFromInt(index)) / 1000 + 1, 1), out[2 * index + 1]);
    }
    player.close();
    try testing.expectEqual(@as(u32, 0), deinits.load(.monotonic));
    engine.decode();
    try testing.expectEqual(@as(u32, 1), deinits.load(.monotonic));
}

/// Mixes `count` frames 64 at a time, decoding ahead as the thread would.
fn renderStream(engine: *Engine, count: usize) ![]f32 {
    const out = try allocator.alloc(f32, count * 2);
    var frame: usize = 0;
    while (frame < count) : (frame += 64) {
        engine.decode();
        _ = engine.render(out[frame * 2 .. @min(count, frame + 64) * 2]);
    }
    return out;
}

test "a stream loops without a gap, over its range too" {
    const engine = try manual();
    defer engine.deinit();
    var deinits: std.atomic.Value(u32) = .init(0);
    const whole = try engine.newPlayer(try generator(1, 300, &deinits));
    whole.setLoop(true);
    whole.play();
    var out = try renderStream(engine, 2000);
    for (0..2000) |index| try expectNear(@as(f32, @floatFromInt(index % 300)) / 1000, out[2 * index]);
    allocator.free(out);
    whole.close();
    const ranged = try engine.newPlayer(try generator(1, 5000, &deinits));
    defer ranged.close();
    ranged.setLoopRange(nanoseconds(1000), nanoseconds(3000));
    ranged.play();
    out = try renderStream(engine, 9000);
    defer allocator.free(out);
    for (0..9000) |index| {
        const frame = if (index >= 3000) 1000 + (index - 3000) % 2000 else index;
        try expectNear(@as(f32, @floatFromInt(frame % 1000)) / 1000, out[2 * index]);
    }
}

test "a stream seeks; one released plays to its end and closes" {
    const engine = try manual();
    defer engine.deinit();
    var deinits: std.atomic.Value(u32) = .init(0);
    const player = try engine.newPlayer(try generator(1, rate, &deinits));
    player.seek(nanoseconds(700));
    engine.decode();
    player.play();
    const out = try render(engine, ramp_frames + 20);
    defer allocator.free(out);
    const index = ramp_frames + 10;
    try expectNear(@as(f32, @floatFromInt((700 + index) % 1000)) / 1000, out[2 * index]);
    player.close();
    const short = try engine.newPlayer(try generator(1, 500, &deinits));
    engine.decode();
    short.play();
    short.release();
    allocator.free(try renderStream(engine, 600));
    try testing.expect(!short.isValid());
    engine.decode();
    try testing.expectEqual(@as(u32, 2), deinits.load(.monotonic));
    try testing.expectEqual(@as(?*@import("stream.zig").Stream, null), engine.streams);
}

test "a looping stream over nothing stops looping" {
    const engine = try manual();
    defer engine.deinit();
    var deinits: std.atomic.Value(u32) = .init(0);
    const player = try engine.newPlayer(try generator(1, 0, &deinits));
    defer player.close();
    player.setLoop(true);
    player.play();
    allocator.free(try renderStream(engine, 300));
    try testing.expect(!player.isPlaying());
}

test "streams open files and bytes of every default format" {
    const engine = try manual();
    defer engine.deinit();
    const flac_bytes = @embedFile("testdata/stereo16.flac");
    const from_bytes = try engine.openStreamBytes(flac_bytes);
    defer from_bytes.close();
    try testing.expectEqual(@as(?u64, @import("sound.zig").framesToNanoseconds(12000, 44100)), from_bytes.duration());
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(zio.io(), .{ .sub_path = "music.flac", .data = flac_bytes });
    const from_file = try engine.openStreamFile(try dir.dir.openFile(zio.io(), "music.flac", .{}));
    from_file.play();
    // Silence leads the file: play past it to its noise.
    const out = try renderStream(engine, 9000);
    defer allocator.free(out);
    var heard = false;
    for (out) |sample| heard = heard or sample != 0;
    try testing.expect(heard);
    from_file.close();
    engine.decode();
    try testing.expectError(error.UnknownFormat, engine.openStreamBytes("nothing to hear"));
    const effect = try engine.decodeSound(flac_bytes);
    defer effect.release();
    try testing.expectEqual(@as(u64, 12000), effect.frames());
}

test "players and streams fail cleanly under every allocation failure" {
    try testing.checkAllAllocationFailures(allocator, struct {
        fn run(failing: std.mem.Allocator) !void {
            const engine = try Engine.init(failing, .{ .output = .manual });
            defer engine.deinit();
            const samples = ramp(100);
            const click = try Sound.fromSamples(failing, rate, 1, &samples);
            defer click.release();
            const first = try engine.play(click);
            const second = try engine.createPlayer(click);
            second.close();
            const stream = try engine.openStreamBytes(@embedFile("testdata/mono24.flac"));
            stream.release();
            _ = first;
            engine.decode();
        }
    }.run, .{});
}

const Recorder = struct {
    app: *ziggurat.App,
    ended: u32 = 0,
    last: ?Player = null,

    fn onEnded(context: *anyopaque, player: Player) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.ended += 1;
        self.last = player;
    }
};

test "players ending reach the main thread through App.post" {
    const app = try ziggurat.App.init(allocator);
    defer app.deinit();
    const engine = try Engine.init(allocator, .{ .output = .manual, .app = app });
    defer engine.deinit();
    var recorder = Recorder{ .app = app };
    const samples = ramp(100);
    const click = try sound(1, &samples);
    defer click.release();
    const kept = try engine.createPlayer(click);
    defer kept.close();
    try kept.onEnded(.{ .context = &recorder, .call = Recorder.onEnded });
    const forgotten = try engine.play(click);
    try forgotten.onEnded(.{ .context = &recorder, .call = Recorder.onEnded });
    kept.play();
    allocator.free(try render(engine, 200));
    try testing.expectEqual(@as(u32, 0), recorder.ended);
    // A played sound waits for its callback before it frees itself.
    try testing.expect(forgotten.isValid());
    try app.dispatch();
    try testing.expectEqual(@as(u32, 2), recorder.ended);
    try testing.expect(!forgotten.isValid());
    try testing.expect(kept.isValid());
    // Once the App stops, nothing more is posted or kept waiting.
    kept.play();
    app.quit();
    app.run() catch {};
    allocator.free(try render(engine, 200));
    try testing.expect(engine.app_closed);
    try testing.expectEqual(@as(u32, 2), recorder.ended);
}

test "callbacks need an App" {
    const engine = try manual();
    defer engine.deinit();
    const click = try sound(1, &.{0.5});
    defer click.release();
    const player = try engine.createPlayer(click);
    defer player.close();
    var recorder: Recorder = undefined;
    try testing.expectError(error.NoApp, player.onEnded(.{ .context = &recorder, .call = Recorder.onEnded }));
}

test "an engine torn down with a notification queued leaves it harmless" {
    const app = try ziggurat.App.init(allocator);
    defer app.deinit();
    const engine = try Engine.init(allocator, .{ .output = .manual, .app = app });
    var recorder = Recorder{ .app = app };
    const click = try sound(1, &.{0.5});
    defer click.release();
    const player = try engine.play(click);
    try player.onEnded(.{ .context = &recorder, .call = Recorder.onEnded });
    allocator.free(try render(engine, 10));
    try testing.expect(engine.posted);
    engine.deinit();
    try app.dispatch();
    try testing.expectEqual(@as(u32, 0), recorder.ended);
}

/// A test backend: counts opens, captures what it plays, and fails as told.
const TestBackend = struct {
    mutex: zio.Mutex = .{},
    opens: u32 = 0,
    closes: u32 = 0,
    fail_open: ?audio.OpenError = null,
    fail_writes_after: ?u32 = null,
    writes: u32 = 0,
    heard: f32 = 0,
    ahead: u64 = 0,

    fn opener(self: *TestBackend) audio.Opener {
        return .{ .context = self, .open = open };
    }

    fn open(context: *anyopaque, ahead: u64, detail: *audio.Detail) audio.OpenError!audio.Device {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.opens += 1;
        self.ahead = ahead;
        if (self.fail_open) |err| {
            detail.set("test backend: {s}", .{@errorName(err)});
            return err;
        }
        self.writes = 0;
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: audio.Device.VTable = .{ .write = write, .close = close };

    fn write(context: *anyopaque, samples: []const f32) audio.WriteError!void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.mutex.lock();
        self.writes += 1;
        for (samples) |sample| self.heard = @max(self.heard, sample);
        const lost = if (self.fail_writes_after) |limit| self.writes > limit else false;
        if (lost) self.fail_writes_after = null;
        self.mutex.unlock();
        if (lost) return error.DeviceLost;
        zio.sleep(std.time.ns_per_ms);
    }

    fn close(context: *anyopaque) void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closes += 1;
    }
};

fn waitUntilStopped(player: Player) !void {
    var waited: u32 = 0;
    while (player.isPlaying()) : (waited += 1) {
        if (waited > 10_000) return error.Timeout;
        zio.sleep(std.time.ns_per_ms);
    }
}

test "the output thread plays into a device and opens it again when lost" {
    var backend = TestBackend{ .fail_writes_after = 3 };
    const engine = try Engine.init(allocator, .{ .output = .{ .custom = backend.opener() } });
    defer engine.deinit();
    const samples = @as([rate / 10]f32, @splat(0.5));
    const tone = try sound(1, &samples);
    defer tone.release();
    const player = try engine.play(tone);
    try waitUntilStopped(player);
    backend.mutex.lock();
    defer backend.mutex.unlock();
    try testing.expectEqual(@as(u32, 2), backend.opens);
    try testing.expectEqual(@as(u32, 1), backend.closes);
    try testing.expectApproxEqAbs(@as(f32, 0.5), backend.heard, 1e-4);
    try testing.expectEqual(@as(?audio.OpenError, null), engine.outputError());
}

test "without a device players play on time, unheard, and say why" {
    var backend = TestBackend{ .fail_open = error.NoDevice };
    const engine = try Engine.init(allocator, .{ .output = .{ .custom = backend.opener() } });
    defer engine.deinit();
    const samples = @as([rate / 10]f32, @splat(0.5));
    const tone = try sound(1, &samples);
    defer tone.release();
    const started = zio.nanoTimestamp();
    const player = try engine.play(tone);
    try waitUntilStopped(player);
    // 100 ms of sound takes about as long on the null device.
    try testing.expect(zio.nanoTimestamp() - started >= 80 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?audio.OpenError, error.NoDevice), engine.outputError());
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("test backend: NoDevice", engine.outputErrorDetail(&buffer));
}

test "a silent engine plays on time without a device or an error" {
    const engine = try Engine.init(allocator, .{ .output = .silent });
    defer engine.deinit();
    const samples = @as([rate / 20]f32, @splat(0.5));
    const tone = try sound(1, &samples);
    defer tone.release();
    const player = try engine.play(tone);
    try waitUntilStopped(player);
    try testing.expectEqual(@as(?audio.OpenError, null), engine.outputError());
}

test "threads decode streams ahead on their own" {
    const engine = try Engine.init(allocator, .{ .output = .silent });
    defer engine.deinit();
    var deinits: std.atomic.Value(u32) = .init(0);
    const player = try engine.newPlayer(try generator(2, rate / 20, &deinits));
    player.play();
    try waitUntilStopped(player);
    try testing.expectEqual(player.duration().?, player.position());
    player.close();
    var waited: u32 = 0;
    while (deinits.load(.monotonic) == 0) : (waited += 1) {
        if (waited > 10_000) return error.Timeout;
        zio.sleep(std.time.ns_per_ms);
    }
}

test "the output opens again to hold as far ahead as the latency asks" {
    var backend = TestBackend{};
    const engine = try Engine.init(allocator, .{ .output = .{ .custom = backend.opener() }, .latency = .playback });
    defer engine.deinit();
    const samples = try allocator.alloc(f32, rate);
    defer allocator.free(samples);
    @memset(samples, 0.25);
    const tone = try sound(1, samples);
    defer tone.release();
    const player = try engine.play(tone);
    try waitForOpens(&backend, 1);
    backend.mutex.lock();
    try testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), backend.ahead);
    backend.mutex.unlock();
    engine.setLatency(.interactive);
    try testing.expectEqual(audio.Latency.interactive, engine.latency());
    try waitForOpens(&backend, 2);
    player.stop();
    backend.mutex.lock();
    defer backend.mutex.unlock();
    try testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), backend.ahead);
    try testing.expectEqual(@as(u32, 1), backend.closes);
}

fn waitForOpens(backend: *TestBackend, count: u32) !void {
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        backend.mutex.lock();
        const opens = backend.opens;
        backend.mutex.unlock();
        if (opens >= count) return;
        if (waited > 10_000) return error.Timeout;
        zio.sleep(std.time.ns_per_ms);
    }
}

/// What the output holds ahead in the position tests: 100 ms.
const held_frames = rate / 10;

/// Makes a manual engine's output hold `frames` ahead of what is heard, as
/// a device that just opened.
fn hold(engine: *Engine, frames: i64) void {
    engine.mutex.lock();
    defer engine.mutex.unlock();
    engine.held = frames;
    engine.unheard = 0;
}

fn mix(engine: *Engine, count: usize) !void {
    allocator.free(try render(engine, count));
}

fn expectHeardAt(player: Player, frame: u64) !void {
    const got: i64 = @intCast(player.position());
    const want: i64 = @intCast(nanoseconds(frame));
    if (@abs(got - want) > std.time.ns_per_us) {
        std.debug.print("position {d} ns, want {d} ns (frame {d})\n", .{ got, want, frame });
        return error.TestUnexpectedResult;
    }
}

fn longSound() !*Sound {
    const samples = try allocator.alloc(f32, 10 * rate);
    defer allocator.free(samples);
    @memset(samples, 0);
    return sound(1, samples);
}

test "a player's position is what is heard, behind what was mixed" {
    const engine = try manual();
    defer engine.deinit();
    hold(engine, held_frames);
    const long = try longSound();
    defer long.release();
    const player = try engine.play(long);
    try mix(engine, held_frames / 2);
    try expectHeardAt(player, 0);
    try mix(engine, held_frames / 2);
    try expectHeardAt(player, 0);
    try mix(engine, 3000);
    try expectHeardAt(player, 3000);
    // A device opening again holds nothing of what was mixed before, which
    // it dropped: the position goes on from what was mixed.
    hold(engine, held_frames);
    try expectHeardAt(player, held_frames + 3000);
}

test "right after a seek the position is where it moved to" {
    const engine = try manual();
    defer engine.deinit();
    hold(engine, held_frames);
    const long = try longSound();
    defer long.release();
    const player = try engine.play(long);
    try mix(engine, 2 * held_frames);
    player.seek(2 * std.time.ns_per_s);
    try expectHeardAt(player, 2 * rate);
    try mix(engine, held_frames - 100);
    try expectHeardAt(player, 2 * rate);
    try mix(engine, 600);
    try expectHeardAt(player, 2 * rate + 500);
    player.stop();
    try expectHeardAt(player, 0);
}

test "paused, a player goes on for as long as the output holds" {
    const engine = try manual();
    defer engine.deinit();
    hold(engine, held_frames);
    const long = try longSound();
    defer long.release();
    const player = try engine.play(long);
    try mix(engine, 10000);
    player.pause();
    try expectHeardAt(player, 10000 - held_frames);
    try mix(engine, 2000);
    try expectHeardAt(player, 12000 - held_frames);
    // It faded out over ramp_frames after the pause.
    try mix(engine, 2 * held_frames);
    try expectHeardAt(player, 10000 + ramp_frames);
    try mix(engine, 1000);
    try expectHeardAt(player, 10000 + ramp_frames);
    player.play();
    try mix(engine, held_frames - 100);
    try expectHeardAt(player, 10000 + ramp_frames);
    try mix(engine, 600);
    try expectHeardAt(player, 10000 + ramp_frames + 500);
}

test "at a speed, what the output holds is that much more of the source" {
    const engine = try manual();
    defer engine.deinit();
    hold(engine, held_frames);
    const long = try longSound();
    defer long.release();
    const player = try engine.createPlayer(long);
    player.setSpeed(2);
    player.play();
    try mix(engine, 3 * held_frames);
    try expectHeardAt(player, 4 * held_frames);
    player.setSpeed(0.5);
    try mix(engine, held_frames * 3 / 2);
    // Of the 150 ms heard since, 100 ms were mixed at 2, 50 ms at 0.5.
    try expectHeardAt(player, 4 * held_frames + 2 * held_frames + held_frames / 4);
}

test "a looping player's position heard comes back to the loop's start" {
    const engine = try manual();
    defer engine.deinit();
    hold(engine, 50);
    const samples = ramp(100);
    const looped = try sound(1, &samples);
    defer looped.release();
    const player = try engine.createPlayer(looped);
    player.setLoopRange(nanoseconds(30), nanoseconds(60));
    player.play();
    try mix(engine, 160);
    try expectHeardAt(player, 50);
    try mix(engine, 10);
    // 120 heard: 60, then two loops of 30.
    try expectHeardAt(player, 30);
}
