const std = @import("std");
const decoding = @import("decoder.zig");

/// Frames a decode step reads at a time.
pub const chunk_frames = 2048;

/// What a stream decodes from, kept with it at a stable address.
pub const Storage = union(enum) {
    none,
    bytes: decoding.BytesInput,
    file: decoding.FileInput,
};

/// A decoder read ahead of its voice by the engine's decoding thread, into
/// a ring the voice reads without waiting. Its storage is the engine's; the
/// decoding thread destroys it once closed.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    decoder: decoding.Decoder,
    /// The decoder's channels, and those kept: 1 or 2.
    channels: usize,
    keep: usize,
    storage: Storage,
    /// Owned by the stream once opened.
    file: ?std.fs.File = null,
    wake: Wake,

    mutex: std.Thread.Mutex = .{},
    /// Frames of `keep` channels.
    ring: []f32,
    /// Where the next sample is read, and how many there are.
    read_index: usize = 0,
    count: usize = 0,
    loop: bool = false,
    /// The frames looped, `loop_end` 0 for all.
    loop_start: i64 = 0,
    loop_end: i64 = 0,
    /// The frame the decoder decodes next.
    position: i64 = 0,
    /// Decoded to the loop's end: it goes on from its start.
    wrap: bool = false,
    at_eof: bool = false,
    /// Where to seek next, or -1.
    seek_to: i64 = -1,
    /// Counts seeks, to drop what was decoded before one.
    generation: u64 = 0,
    /// Looped back with nothing decoded since: an empty loop stops looping.
    fresh: bool = false,
    closed: bool = false,
    buffer: []f32,
    kept: []f32,
    /// The engine's list of streams to decode.
    next: ?*Stream = null,
    previous: ?*Stream = null,

    pub const Wake = struct {
        context: ?*anyopaque,
        call: *const fn (?*anyopaque) void,

        fn signal(self: Wake) void {
            self.call(self.context);
        }
    };

    /// Allocates a stream whose storage the caller fills before `start`.
    pub fn create(allocator: std.mem.Allocator, wake: Wake) error{OutOfMemory}!*Stream {
        const self = try allocator.create(Stream);
        self.* = .{ .allocator = allocator, .decoder = undefined, .channels = 0, .keep = 0, .storage = .none, .wake = wake, .ring = &.{}, .buffer = &.{}, .kept = &.{} };
        return self;
    }

    /// Takes the decoder: it is deinitialized with the stream.
    pub fn start(self: *Stream, decoder: decoding.Decoder) error{ OutOfMemory, InvalidData }!void {
        const channels: usize = decoder.channels;
        if (channels < 1 or decoder.sample_rate == 0) return error.InvalidData;
        const keep: usize = @min(channels, 2);
        // About a second ahead.
        const frames = @max(decoder.sample_rate, 4096);
        const ring = try self.allocator.alloc(f32, @as(usize, frames) * keep);
        errdefer self.allocator.free(ring);
        const buffer = try self.allocator.alloc(f32, chunk_frames * channels);
        errdefer self.allocator.free(buffer);
        const kept = if (keep == channels) buffer else try self.allocator.alloc(f32, chunk_frames * keep);
        self.decoder = decoder;
        self.channels = channels;
        self.keep = keep;
        self.ring = ring;
        self.buffer = buffer;
        self.kept = kept;
    }

    /// Undoes `start`, leaving the decoder the caller's.
    pub fn unstart(self: *Stream) void {
        if (self.kept.ptr != self.buffer.ptr) self.allocator.free(self.kept);
        self.allocator.free(self.buffer);
        self.allocator.free(self.ring);
        self.ring = &.{};
        self.buffer = &.{};
        self.kept = &.{};
    }

    /// Frees a stream `start` did not take a decoder for.
    pub fn abandon(self: *Stream) void {
        self.allocator.destroy(self);
    }

    /// Deinitializes the decoder and closes an owned file. Decoding thread,
    /// once closed, or the engine's teardown.
    pub fn destroy(self: *Stream) void {
        self.decoder.deinit();
        if (self.file) |file| file.close();
        if (self.kept.ptr != self.buffer.ptr) self.allocator.free(self.kept);
        self.allocator.free(self.buffer);
        self.allocator.free(self.ring);
        self.allocator.destroy(self);
    }

    pub const Step = enum { idle, worked, closed };

    /// One decode step without waiting: a seek, or a chunk into the ring.
    pub fn step(self: *Stream) Step {
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return .closed;
        }
        const space = self.ring.len - self.count;
        if (self.seek_to < 0 and !self.wrap and (self.at_eof and !self.loop or space < chunk_frames * self.keep)) {
            self.mutex.unlock();
            return .idle;
        }
        if (self.seek_to >= 0 or self.wrap or self.at_eof) {
            // A seek, or a loop back to its start.
            const looping_back = self.seek_to < 0;
            const target = if (looping_back) self.loop_start else self.seek_to;
            self.seek_to = -1;
            self.wrap = false;
            const generation = self.generation;
            self.mutex.unlock();
            const failed = if (self.decoder.setPosition(@intCast(target))) false else |_| true;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (generation == self.generation) {
                // Where it cannot go, the stream ends.
                self.at_eof = failed;
                self.loop = self.loop and !failed;
                self.position = target;
                self.fresh = looping_back;
            }
            return .worked;
        }
        const generation = self.generation;
        self.mutex.unlock();
        var failed = false;
        var samples_read = self.decoder.read(self.buffer) catch blk: {
            failed = true;
            break :blk 0;
        };
        samples_read -= samples_read % self.channels;
        const frames = samples_read / self.channels;
        if (self.keep != self.channels) {
            for (0..frames) |frame| @memcpy(self.kept[frame * self.keep ..][0..self.keep], self.buffer[frame * self.channels ..][0..self.keep]);
        }
        var samples = self.kept[0 .. frames * self.keep];
        self.mutex.lock();
        defer self.mutex.unlock();
        if (generation != self.generation) return .worked; // Seeked meanwhile.
        if (self.loop and self.loop_end > 0 and self.position + @as(i64, @intCast(frames)) >= self.loop_end) {
            // Past the loop's end: what is before it, then its start.
            samples = samples[0..@intCast(@max(self.loop_end - self.position, 0) * @as(i64, @intCast(self.keep)))];
            self.wrap = true;
        }
        self.position += @intCast(frames);
        while (samples.len > 0) {
            const write = (self.read_index + self.count) % self.ring.len;
            const copied = @min(samples.len, self.ring.len - write, self.ring.len - self.count);
            @memcpy(self.ring[write..][0..copied], samples[0..copied]);
            self.count += copied;
            samples = samples[copied..];
        }
        if (failed or frames == 0) {
            // The end, or a failure, which ends the stream as well.
            self.at_eof = true;
            // A decoder that fails, or loops over nothing, loops no more.
            if (failed or self.fresh) self.loop = false;
        } else self.fresh = false;
        return .worked;
    }

    pub const Read = struct { frames: usize, ended: bool };

    /// Mixing thread: reads decoded frames without waiting.
    pub fn read(self: *Stream, out: []f32) Read {
        self.mutex.lock();
        var wanted = @min(out.len, self.count);
        wanted -= wanted % self.keep;
        var got: usize = 0;
        while (got < wanted) {
            const copied = @min(wanted - got, self.ring.len - self.read_index);
            @memcpy(out[got..][0..copied], self.ring[self.read_index..][0..copied]);
            got += copied;
            self.read_index = (self.read_index + copied) % self.ring.len;
            self.count -= copied;
        }
        const ended = got < out.len / self.keep * self.keep and self.count == 0 and self.at_eof and !self.loop and self.seek_to < 0;
        const hungry = got > 0 and self.ring.len - self.count >= chunk_frames * self.keep;
        self.mutex.unlock();
        if (hungry) self.wake.signal();
        return .{ .frames = got / self.keep, .ended = ended };
    }

    pub fn seek(self: *Stream, frame: i64) void {
        self.mutex.lock();
        self.seek_to = frame;
        self.at_eof = false;
        self.wrap = false;
        self.read_index = 0;
        self.count = 0;
        self.generation += 1;
        self.mutex.unlock();
        self.wake.signal();
    }

    pub fn setLoop(self: *Stream, loop: bool, loop_start: i64, loop_end: i64) void {
        self.mutex.lock();
        if (self.wrap and !loop) {
            // Looping no more at its end: from there, where it decoded past.
            self.wrap = false;
            self.seek_to = self.loop_end;
        }
        self.loop = loop;
        self.loop_start = loop_start;
        self.loop_end = loop_end;
        self.mutex.unlock();
        self.wake.signal();
    }

    /// Hands the stream to the decoding thread to destroy.
    pub fn close(self: *Stream) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
        self.wake.signal();
    }

    /// Decoded frames waiting in the ring.
    pub fn buffered(self: *Stream) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count / self.keep;
    }
};
