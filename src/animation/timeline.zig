const std = @import("std");
const a = @import("root.zig");

pub const Track = struct { at_ns: u64 = 0, from: f64, to: f64, tween: a.Tween };
pub const Direction = enum { forward, backward };
pub const Repetition = struct { iterations: u32 = 1, alternate: bool = false };
pub const max_tracks = 64;

/// Immutable, copyable preparation value. Overlap and staggering are explicit
/// offsets. The bounded input is copied; sampling never borrows source storage.
pub const Timeline = struct {
    tracks: [max_tracks]Track = undefined,
    count: usize = 0,
    duration_ns: u64 = 0,

    pub fn init(tracks: []const Track) !Timeline {
        if (tracks.len == 0 or tracks.len > max_tracks) return error.InvalidTrackCount;
        var self: Timeline = .{};
        for (tracks) |track| {
            var channel = try a.Channel.init(track.from);
            try channel.retarget(track.at_ns, track.to, .{ .motion = .{ .tween = track.tween } });
            const end = std.math.add(u64, track.at_ns, track.tween.duration_ns) catch return error.ClockExhausted;
            if (end > a.max_duration_ns) return error.InvalidDuration;
            self.duration_ns = @max(self.duration_ns, end);
        }
        @memcpy(self.tracks[0..tracks.len], tracks);
        self.count = tracks.len;
        return self;
    }
    pub fn sample(self: *const Timeline, track_index: usize, position_ns: u64) !a.Sample {
        if (track_index >= self.count) return error.InvalidTrack;
        const track = self.tracks[track_index];
        if (position_ns < track.at_ns) return .{ .value = track.from, .velocity = 0, .active = true };
        var channel = try a.Channel.init(track.from);
        try channel.retarget(track.at_ns, track.to, .{ .motion = .{ .tween = track.tween } });
        return channel.advance(position_ns);
    }
};

/// Separate caller-owned transport for an immutable Timeline. Seek pauses;
/// play resumes from the current position and restart chooses an endpoint.
/// No iteration through skipped frames, callbacks, allocation or timers.
pub const Playhead = struct {
    duration_ns: u64,
    position_ns: u64 = 0,
    direction: Direction = .forward,
    playing: bool = false,
    reduced_motion: bool = false,
    last_now: ?u64 = null,
    repetition: Repetition = .{},
    completed_iterations: u32 = 0,

    pub fn init(duration_ns: u64) !Playhead {
        if (duration_ns == 0 or duration_ns > a.max_duration_ns) return error.InvalidDuration;
        return .{ .duration_ns = duration_ns };
    }
    pub fn advance(self: *Playhead, now: u64) !u64 {
        try self.checkTime(now);
        if (self.playing) {
            const elapsed = now - self.last_now.?;
            self.step(elapsed);
        }
        self.last_now = now;
        return self.position_ns;
    }
    /// Configure a finite sequence while paused. The current position starts
    /// its first (possibly partial) leg; seek/restart reset the iteration count.
    pub fn configureRepeat(self: *Playhead, repetition: Repetition) !void {
        if (self.playing) return error.Playing;
        if (repetition.iterations == 0 or repetition.iterations > 1_000_000) return error.InvalidRepetition;
        const duration = std.math.mul(u64, self.duration_ns, repetition.iterations) catch return error.InvalidRepetition;
        if (duration > a.max_duration_ns) return error.InvalidRepetition;
        self.repetition = repetition;
        self.completed_iterations = 0;
    }
    pub fn play(self: *Playhead, now: u64, direction: Direction) !void {
        var next = self.*;
        _ = try next.advance(now);
        next.direction = direction;
        if (next.reduced_motion) next.finish() else {
            _ = std.math.add(u64, now, next.remaining()) catch return error.ClockExhausted;
            next.playing = next.remaining() != 0;
        }
        self.* = next;
    }
    pub fn restart(self: *Playhead, now: u64, direction: Direction) !void {
        try self.checkTime(now);
        var next = self.*;
        next.playing = false;
        next.completed_iterations = 0;
        next.position_ns = if (direction == .forward) 0 else next.duration_ns;
        next.last_now = now;
        try next.play(now, direction);
        self.* = next;
    }
    pub fn pause(self: *Playhead, now: u64) !void {
        _ = try self.advance(now);
        self.playing = false;
    }
    pub fn seek(self: *Playhead, now: u64, position_ns: u64) !void {
        try self.checkTime(now);
        if (position_ns > self.duration_ns) return error.InvalidPosition;
        self.last_now = now;
        self.position_ns = position_ns;
        self.completed_iterations = 0;
        self.playing = false;
    }
    pub fn setReducedMotion(self: *Playhead, now: u64, enabled: bool) !void {
        _ = try self.advance(now);
        self.reduced_motion = enabled;
        if (enabled and self.playing) self.finish();
    }
    pub fn nextWake(self: *const Playhead, now: u64, cadence_ns: u64) !?u64 {
        try self.checkTime(now);
        if (cadence_ns == 0 or cadence_ns > std.time.ns_per_s) return error.InvalidCadence;
        if (!self.playing) return null;
        const end = self.last_now.? + self.legRemaining();
        return @max(now, @min(now +| cadence_ns, end));
    }
    fn checkTime(self: *const Playhead, now: u64) !void {
        if (self.last_now) |last| if (now < last) return error.ClockMovedBackwards;
    }
    fn remaining(self: *const Playhead) u64 {
        if (self.completed_iterations == self.repetition.iterations) return 0;
        return self.legRemaining() + @as(u64, self.repetition.iterations - self.completed_iterations - 1) * self.duration_ns;
    }
    fn legRemaining(self: *const Playhead) u64 {
        return if (self.direction == .forward) self.duration_ns - self.position_ns else self.position_ns;
    }
    fn reverse(self: *Playhead) void {
        self.direction = if (self.direction == .forward) .backward else .forward;
    }
    fn step(self: *Playhead, elapsed: u64) void {
        const first = self.legRemaining();
        if (elapsed < first) {
            self.position_ns = if (self.direction == .forward) self.position_ns + elapsed else self.position_ns - elapsed;
            return;
        }
        const after = elapsed - first;
        const left = self.repetition.iterations - self.completed_iterations;
        const skipped = after / self.duration_ns;
        if (skipped >= left - 1) {
            self.finish();
            return;
        }
        const completed: u32 = @intCast(skipped + 1);
        self.completed_iterations += completed;
        if (self.repetition.alternate and completed % 2 == 1) self.reverse();
        const local = after % self.duration_ns;
        self.position_ns = if (self.direction == .forward) local else self.duration_ns - local;
    }
    fn finish(self: *Playhead) void {
        const left = self.repetition.iterations - self.completed_iterations;
        if (self.repetition.alternate and left > 0 and (left - 1) % 2 == 1) self.reverse();
        self.completed_iterations = self.repetition.iterations;
        self.position_ns = if (self.direction == .forward) self.duration_ns else 0;
        self.playing = false;
    }
};
