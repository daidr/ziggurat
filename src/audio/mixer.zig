//! A voice is a player's state: its source, where it is, and how it
//! resamples, pans and ramps to the output. Mixing never allocates or
//! blocks; the engine's mutex guards every voice.
const std = @import("std");
const output = @import("output.zig");
const Sound = @import("sound.zig").Sound;
const Stream = @import("stream.zig").Stream;

/// How long volume changes, fades in and fades out take: 5 ms.
pub const ramp_frames = output.sample_rate / 200;

/// A sound's samples, read in place.
pub const MemorySource = struct {
    sound: *Sound,
    /// Sample index.
    position: usize = 0,
    loop: bool = false,
    loop_start: i64 = 0,
    loop_end: i64 = 0,

    fn read(self: *MemorySource, out: []f32) Stream.Read {
        const samples = self.sound.samples;
        const channels: usize = self.sound.channels;
        var count: usize = 0;
        while (count < out.len) {
            var limit = samples.len;
            if (self.loop and self.loop_end > 0) limit = @min(limit, @as(usize, @intCast(self.loop_end)) * channels);
            if (self.position >= limit) {
                if (!self.loop or limit == 0) return .{ .frames = count / channels, .ended = true };
                self.position = @as(usize, @intCast(self.loop_start)) * channels;
                if (self.position >= limit) self.position = 0;
            }
            var copied = @min(out.len - count, limit - self.position);
            copied -= copied % channels;
            if (copied == 0) break;
            @memcpy(out[count..][0..copied], samples[self.position..][0..copied]);
            count += copied;
            self.position += copied;
        }
        return .{ .frames = count / channels, .ended = false };
    }
};

pub const Source = union(enum) {
    memory: MemorySource,
    stream: *Stream,

    /// Reads frames into `out`, interleaved: fewer than fit only at the end,
    /// where `ended` is true, or while a stream decodes, where it is false.
    /// Goes on from the loop's start when looping.
    pub fn read(self: *Source, out: []f32) Stream.Read {
        return switch (self.*) {
            .memory => |*memory| memory.read(out),
            .stream => |stream| stream.read(out),
        };
    }

    pub fn seek(self: *Source, frame: i64) void {
        switch (self.*) {
            .memory => |*memory| memory.position = @intCast(@min(frame * memory.sound.channels, @as(i64, @intCast(memory.sound.samples.len)))),
            .stream => |stream| stream.seek(frame),
        }
    }

    pub fn setLoop(self: *Source, loop: bool, loop_start: i64, loop_end: i64) void {
        switch (self.*) {
            .memory => |*memory| {
                memory.loop = loop;
                memory.loop_start = loop_start;
                memory.loop_end = loop_end;
            },
            .stream => |stream| stream.setLoop(loop, loop_start, loop_end),
        }
    }
};

pub const Outcome = enum {
    /// Still sounding, or a stream waiting on its decoder.
    playing,
    /// Played to the end of its source.
    ended,
    /// Paused and faded out.
    faded,
};

/// The voice at output frame `out`: at frame `at` of its source, counted on
/// past its loop's end. Between two marks the voice moved evenly, or stood
/// still where both are at the same frame.
pub const Mark = struct {
    out: i64,
    at: f64,
};

/// Marks a voice keeps: a mix call adds at most two, and the output holds
/// about 25 of its periods at the playback latency.
const max_marks = 128;

pub const Voice = struct {
    source: Source,
    /// The source's frames per second.
    rate: f64,
    mono: bool,
    /// Frames, or -1 when unknown.
    length: i64,

    /// As the API sees it.
    playing: bool = false,
    /// In the engine's mixing list, which it stays in while fading out.
    active: bool = false,
    /// Starts at its start: no fade in.
    snap: bool = false,
    /// Resumes in the middle: fades in from silence.
    fade_in: bool = false,
    closed: bool = false,

    volume: f64 = 1,
    pan: f64 = 0,
    speed: f64 = 1,
    loop: bool = false,
    /// Frames, `loop_end` 0 for the end.
    loop_start: i64 = 0,
    loop_end: i64 = 0,

    /// The four source frames the output is interpolated between, the
    /// second at `index`, and how far the output is past it.
    history: [4][2]f32 = undefined,
    index: i64 = 0,
    phase: f64 = 0,
    /// The frame after the last, once the source ended, or -1.
    end: i64 = -1,

    /// Where the voice was in its source as the output mixed its frames,
    /// oldest first, for `heardAt` to say where it is heard.
    marks: [max_marks]Mark = undefined,
    mark_count: usize = 0,

    /// Frames read from the source and not yet used.
    input: [256 * 2]f32 = undefined,
    input_position: usize = 0,
    input_len: usize = 0,

    /// The gains applied, a 2×2 matrix from the source's channels to the
    /// output's (ll, rl, lr, rr), ramping to `target`.
    gain: [4]f32 = @splat(0),
    target: [4]f32 = @splat(0),
    step: [4]f32 = @splat(0),
    ramp_left: u32 = 0,

    // The engine's bookkeeping, under its mutex.
    slot: u32 = 0,
    /// Retire at the end, as a sound played and forgotten.
    free_at_end: bool = false,
    /// Released by its owner: retire once it stops sounding.
    released: bool = false,
    retired: bool = false,
    on_ended: ?@import("engine.zig").EndedCallback = null,
    /// Queued for its `on_ended` call on the main thread.
    notify_queued: bool = false,
    retire_after_notify: bool = false,
    next_pending: ?*Voice = null,
    previous_pending: ?*Voice = null,
    next_finished: ?*Voice = null,

    pub fn init(source: Source, rate: u32, channels: usize, length: ?u64) Voice {
        var voice = Voice{ .source = source, .rate = @floatFromInt(rate), .mono = channels == 1, .length = if (length) |frames| @intCast(@min(frames, std.math.maxInt(i63))) else -1 };
        voice.reset(0);
        return voice;
    }

    /// Starts over at frame `frame` of the source, which the caller moved
    /// there.
    pub fn reset(self: *Voice, frame: i64) void {
        self.history = @splat(.{ 0, 0 });
        // Three frames come in before the first output: the second is `frame`.
        self.index = frame - 3;
        self.phase = 3;
        self.end = -1;
        self.input_position = 0;
        self.input_len = 0;
        // What it mixed before is not where it is any more, even while heard.
        self.mark_count = 0;
    }

    pub fn ended(self: *const Voice) bool {
        return self.end >= 0 and self.index >= self.end;
    }

    /// The source frame the voice mixes next, counted on past its loop's
    /// end.
    pub fn at(self: *const Voice) f64 {
        return @as(f64, @floatFromInt(self.index)) + self.phase;
    }

    /// Notes that the output mixes frame `out` with the voice where it is,
    /// and forgets the marks before the frame heard.
    fn mark(self: *Voice, out: i64, heard: i64) void {
        const new = Mark{ .out = out, .at = self.at() };
        const marks = self.marks[0..self.mark_count];
        if (marks.len > 0 and std.meta.eql(marks[marks.len - 1], new)) return;
        var first: usize = 0;
        while (first + 1 < marks.len and marks[first + 1].out <= heard) first += 1;
        // Full, as when mixed in many small pieces: the oldest goes.
        if (marks.len - first == max_marks) first += 1;
        std.mem.copyForwards(Mark, self.marks[0 .. marks.len - first], marks[first..]);
        self.mark_count = marks.len - first;
        self.marks[self.mark_count] = new;
        self.mark_count += 1;
    }

    /// The source frame the voice was at when the output mixed frame
    /// `heard`, counted on past its loop's end. Until the output plays what
    /// it mixed since a seek, that is where it seeked to.
    pub fn heardAt(self: *const Voice, heard: i64) f64 {
        const marks = self.marks[0..self.mark_count];
        for (marks, 0..) |later, index| {
            if (later.out <= heard) continue;
            if (index == 0) return later.at;
            const earlier = marks[index - 1];
            const through = @as(f64, @floatFromInt(heard - earlier.out)) / @as(f64, @floatFromInt(later.out - earlier.out));
            return earlier.at + (later.at - earlier.at) * through;
        }
        return self.at();
    }

    /// Source frame `frame`, counted on past the loop's end, as a frame of
    /// the source.
    pub fn position(self: *const Voice, frame: f64) f64 {
        var at_frame = @max(frame, 0);
        if (self.length == 0) return 0;
        if (self.loop) {
            var end: f64 = @floatFromInt(self.loop_end);
            if (end <= 0) end = @floatFromInt(self.length);
            const start: f64 = @floatFromInt(self.loop_start);
            if (end > start and at_frame >= end) at_frame = start + @mod(at_frame - start, end - start);
            return at_frame;
        }
        if (self.length > 0) at_frame = @min(at_frame, @as(f64, @floatFromInt(self.length)));
        return at_frame;
    }

    fn channelCount(self: *const Voice) usize {
        return if (self.mono) 1 else 2;
    }

    /// Shifts in the source's next frame; false while a stream has none
    /// decoded yet.
    fn next(self: *Voice) bool {
        const channels = self.channelCount();
        if (self.input_position >= self.input_len) {
            if (self.end >= 0) {
                // Past the end, silence.
                self.shift(0, 0);
                return true;
            }
            const result = self.source.read(self.input[0 .. 256 * channels]);
            self.input_position = 0;
            self.input_len = result.frames * channels;
            if (result.frames == 0) {
                if (!result.ended) return false;
                // The frame coming in would be at index + 3.
                self.end = self.index + 3;
                self.shift(0, 0);
                return true;
            }
        }
        const left = self.input[self.input_position];
        const right = if (self.mono) left else self.input[self.input_position + 1];
        self.input_position += channels;
        self.shift(left, right);
        return true;
    }

    fn shift(self: *Voice, left: f32, right: f32) void {
        self.history[0] = self.history[1];
        self.history[1] = self.history[2];
        self.history[2] = self.history[3];
        self.history[3] = .{ left, right };
        self.index += 1;
    }

    /// The matrix of the voice's volume and pan, and the master volume.
    fn gains(self: *const Voice, master: f64) [4]f32 {
        var g = self.volume * master;
        if (!self.playing) g = 0;
        if (self.mono) {
            // Equal power, the middle as decoded.
            const x = (self.pan + 1) / 2 * std.math.pi / 2;
            return .{ @floatCast(g * std.math.sqrt2 * @cos(x)), 0, 0, @floatCast(g * std.math.sqrt2 * @sin(x)) };
        }
        // A stereo panner: one side folds into the other.
        if (self.pan <= 0) {
            const x = (self.pan + 1) * std.math.pi / 2;
            return .{ @floatCast(g), 0, @floatCast(g * @cos(x)), @floatCast(g * @sin(x)) };
        }
        const x = self.pan * std.math.pi / 2;
        return .{ @floatCast(g * @cos(x)), @floatCast(g * @sin(x)), 0, @floatCast(g) };
    }

    /// Ramps the gains to `target` from now.
    fn retarget(self: *Voice, target: [4]f32) void {
        if (self.snap) {
            self.snap = false;
            self.fade_in = false;
            self.gain = target;
            self.target = target;
            self.ramp_left = 0;
            return;
        }
        if (self.fade_in) {
            self.fade_in = false;
            self.gain = @splat(0);
        } else if (std.mem.eql(f32, &target, &self.target)) return;
        self.target = target;
        for (&self.step, target, self.gain) |*step, want, have| step.* = (want - have) / ramp_frames;
        self.ramp_left = ramp_frames;
    }

    /// Adds the voice's next frames to `out`, interleaved stereo, which the
    /// output mixes from its frame `out_at`; the output's frame `heard` is
    /// heard now.
    pub fn mix(self: *Voice, out: []f32, master: f64, out_at: i64, heard: i64) Outcome {
        self.mark(out_at, heard);
        const played = self.play(out, master);
        self.mark(out_at + @as(i64, @intCast(played.frames)), heard);
        return played.outcome;
    }

    /// Adds the voice's next frames to `out`, and says for how many output
    /// frames it moved through its source.
    fn play(self: *Voice, out: []f32, master: f64) struct { outcome: Outcome, frames: usize } {
        self.retarget(self.gains(master));
        const step = self.rate / output.sample_rate * self.speed;
        var index: usize = 0;
        while (index < out.len) : (index += 2) {
            while (self.phase >= 1) {
                // The stream is late: silence until it catches up.
                if (!self.next()) return .{ .outcome = .playing, .frames = index / 2 };
                self.phase -= 1;
            }
            if (self.ended()) {
                self.playing = false;
                return .{ .outcome = .ended, .frames = index / 2 };
            }
            if (self.ramp_left > 0) {
                for (&self.gain, self.step) |*gain, step_by| gain.* += step_by;
                self.ramp_left -= 1;
                if (self.ramp_left == 0) self.gain = self.target;
            } else if (!self.playing) return .{ .outcome = .faded, .frames = index / 2 };
            const left, const right = self.sample();
            out[index] += left * self.gain[0] + right * self.gain[2];
            out[index + 1] += left * self.gain[1] + right * self.gain[3];
            self.phase += step;
        }
        return .{ .outcome = .playing, .frames = out.len / 2 };
    }

    /// Interpolates between the second and third frames with a
    /// Catmull-Rom spline.
    fn sample(self: *const Voice) struct { f32, f32 } {
        const t: f32 = @floatCast(self.phase);
        const h = &self.history;
        const spline = struct {
            fn at(time: f32, p0: f32, p1: f32, p2: f32, p3: f32) f32 {
                return p1 + 0.5 * time * (p2 - p0 + time * (2 * p0 - 5 * p1 + 4 * p2 - p3 + time * (3 * (p1 - p2) + p3 - p0)));
            }
        };
        return .{ spline.at(t, h[0][0], h[1][0], h[2][0], h[3][0]), spline.at(t, h[0][1], h[1][1], h[2][1], h[3][1]) };
    }
};
