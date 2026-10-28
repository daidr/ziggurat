const std = @import("std");
const zio = @import("ziggurat_io");
const ziggurat = @import("ziggurat");
const decoding = @import("decoder.zig");
const output = @import("output.zig");
const mixer = @import("mixer.zig");
const Sound = @import("sound.zig").Sound;
const framesToNanoseconds = @import("sound.zig").framesToNanoseconds;
const streaming = @import("stream.zig");
const Stream = streaming.Stream;
const Voice = mixer.Voice;

const compressed = @import("compressed.zig");

/// WAV, FLAC, Ogg Vorbis and MP3, detected by their first bytes.
pub const default_formats = [_]decoding.Format{ @import("wav.zig").format, @import("flac.zig").format, compressed.vorbis_format } ++ compressed.mp3_formats;

/// Main thread, once each time a player plays to its end.
pub const EndedCallback = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, player: Player) void,
};

/// Main thread, when `Engine.outputError` changes.
pub const OutputCallback = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, engine: *Engine) void,
};

pub const Output = union(enum) {
    /// WASAPI on Windows, PulseAudio (or PipeWire's) and then ALSA on Linux.
    /// Where none opens, players play on time, unheard, and the engine
    /// tries the device again every few seconds.
    system,
    /// No device: players play on time, unheard.
    silent,
    /// No threads: the caller mixes with `render` and decodes streams with
    /// `decode`, as tests and offline rendering do.
    manual,
    /// An app's own device, or a test backend, opened on the output thread.
    custom: output.Opener,
};

pub const Options = struct {
    output: Output = .system,
    /// Formats `openStream*` and `decodeSound` detect, in order.
    formats: []const decoding.Format = &default_formats,
    /// Where `EndedCallback`s and `on_output` run, through `App.post`.
    /// Without one they are never called.
    app: ?*ziggurat.App = null,
    on_output: ?OutputCallback = null,
    /// The clock a silent output keeps.
    clock: output.Clock = .{},
};

const no_slot = std.math.maxInt(u32);

const Slot = struct {
    voice: ?*Voice = null,
    generation: u32 = 0,
    next_free: u32 = no_slot,
};

/// The task posted to the App. It outlives an engine torn down while it is
/// queued, and then frees itself.
const Notifier = struct {
    allocator: std.mem.Allocator,
    engine: ?*Engine,
};

/// Mixes every player into the output on a thread of its own and decodes
/// streams ahead on another; both start with the engine and wait without
/// work. Every method is safe from any thread. The allocator must be too:
/// streams are freed on the decoding thread.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    formats: []const decoding.Format,
    app: ?*ziggurat.App,
    on_output: ?OutputCallback,
    mode: Output,
    clock: output.Clock,

    /// Guards voices, slots and notifications.
    mutex: zio.Mutex = .{},
    /// Playing or fading out. Capacity covers every voice alive, so that
    /// starting one never allocates.
    voices: std.ArrayList(*Voice) = .empty,
    slots: std.ArrayList(Slot) = .empty,
    free_slot: u32 = no_slot,
    live: usize = 0,
    /// Retired and out of the mix: freed on the next call that allocates.
    finished: ?*Voice = null,
    pending_head: ?*Voice = null,
    pending_tail: ?*Voice = null,
    output_changed: bool = false,
    posted: bool = false,
    app_closed: bool = false,
    master: f64 = 1,
    notifier: ?*Notifier = null,

    error_mutex: zio.Mutex = .{},
    output_error: ?output.OpenError = null,
    detail: output.Detail = .{},

    quit: std.atomic.Value(bool) = .init(false),
    output_wake: std.atomic.Value(u32) = .init(0),
    decode_wake: std.atomic.Value(u32) = .init(0),
    output_thread: ?std.Thread = null,
    decode_thread: ?std.Thread = null,
    decode_mutex: zio.Mutex = .{},
    streams: ?*Stream = null,
    mix_buffer: [output.period_frames * output.channels]f32 = undefined,
    system_storage: output.system.Storage = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options) !*Engine {
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .formats = options.formats, .app = options.app, .on_output = options.on_output, .mode = options.output, .clock = options.clock };
        if (options.app != null) {
            const notifier = try allocator.create(Notifier);
            notifier.* = .{ .allocator = allocator, .engine = self };
            self.notifier = notifier;
        }
        errdefer if (self.notifier) |notifier| allocator.destroy(notifier);
        if (self.mode != .manual) {
            self.decode_thread = try std.Thread.spawn(.{}, decodeMain, .{self});
            errdefer {
                self.stopThreads();
            }
            self.output_thread = try std.Thread.spawn(.{}, outputMain, .{self});
        }
        return self;
    }

    /// Stops the threads, closes the output and frees every player, stream
    /// and handle. With an App, call it on the App's main thread; a queued
    /// notification then finds the engine gone and does nothing.
    pub fn deinit(self: *Engine) void {
        self.stopThreads();
        const allocator = self.allocator;
        for (self.voices.items) |voice| if (voice.retired) self.freeVoice(voice);
        for (self.slots.items) |slot| if (slot.voice) |voice| self.freeVoice(voice);
        self.reclaim();
        while (self.streams) |stream| {
            self.streams = stream.next;
            stream.destroy();
        }
        self.voices.deinit(allocator);
        self.slots.deinit(allocator);
        if (self.notifier) |notifier| {
            if (self.posted) notifier.engine = null else allocator.destroy(notifier);
        }
        allocator.destroy(self);
    }

    fn stopThreads(self: *Engine) void {
        self.quit.store(true, .release);
        wakeFutex(&self.output_wake);
        wakeFutex(&self.decode_wake);
        if (self.output_thread) |thread| thread.join();
        if (self.decode_thread) |thread| thread.join();
        self.output_thread = null;
        self.decode_thread = null;
    }

    fn wakeFutex(word: *std.atomic.Value(u32)) void {
        _ = word.fetchAdd(1, .release);
        zio.Futex.wake(word, 1);
    }

    fn wakeDecoder(context: ?*anyopaque) void {
        const self: *Engine = @ptrCast(@alignCast(context.?));
        wakeFutex(&self.decode_wake);
    }

    // Players.

    /// A paused player of `sound`, which it retains. Close or release it.
    pub fn createPlayer(self: *Engine, sound: *Sound) error{OutOfMemory}!Player {
        self.mutex.lock();
        defer self.mutex.unlock();
        const player = try self.createVoice(Voice.init(.{ .memory = .{ .sound = sound } }, sound.sample_rate, sound.channels, sound.frames()));
        _ = sound.retain();
        return player;
    }

    /// Plays `sound` from its start, over any other of its players. The
    /// player frees itself at the end, so it needs no closing; its handle
    /// then goes stale and does nothing.
    pub fn play(self: *Engine, sound: *Sound) error{OutOfMemory}!Player {
        self.mutex.lock();
        defer self.mutex.unlock();
        const player = try self.createVoice(Voice.init(.{ .memory = .{ .sound = sound } }, sound.sample_rate, sound.channels, sound.frames()));
        _ = sound.retain();
        const voice = self.slots.items[player.index].voice.?;
        voice.free_at_end = true;
        self.start(voice);
        return player;
    }

    /// Decodes data of one of the engine's formats into memory.
    pub fn decodeSound(self: *Engine, bytes: []const u8) decoding.Error!*Sound {
        return Sound.decode(self.allocator, bytes, self.formats);
    }

    /// A paused player decoding `file` as it plays, about a second ahead,
    /// for music and other long audio. The player owns the file once this
    /// succeeds and closes it with itself.
    pub fn openStreamFile(self: *Engine, file: std.Io.File) decoding.Error!Player {
        return self.openStream(.{ .file = .init(file) }, file);
    }

    /// As `openStreamFile`, decoding borrowed bytes that outlive the engine,
    /// such as embedded files.
    pub fn openStreamBytes(self: *Engine, bytes: []const u8) decoding.Error!Player {
        return self.openStream(.{ .bytes = .{ .bytes = bytes } }, null);
    }

    /// A paused player decoding `decoder` as it plays, on the decoding
    /// thread, as an app generating sound does. The player owns the decoder
    /// once this succeeds and deinitializes it after closing.
    pub fn newPlayer(self: *Engine, decoder: decoding.Decoder) error{ OutOfMemory, InvalidData }!Player {
        const stream = try Stream.create(self.allocator, .{ .context = self, .call = wakeDecoder });
        return self.adopt(stream, decoder, null) catch |err| {
            stream.abandon();
            return err;
        };
    }

    fn openStream(self: *Engine, storage: streaming.Storage, file: ?std.Io.File) decoding.Error!Player {
        const stream = try Stream.create(self.allocator, .{ .context = self, .call = wakeDecoder });
        stream.storage = storage;
        const input = switch (stream.storage) {
            .bytes => |*bytes| bytes.input(),
            .file => |*file_input| file_input.input(),
            .none => unreachable,
        };
        const opened = decoding.open(self.allocator, input, self.formats) catch |err| {
            stream.abandon();
            return err;
        };
        return self.adopt(stream, opened.decoder, file) catch |err| {
            opened.decoder.deinit();
            stream.abandon();
            return err;
        };
    }

    fn adopt(self: *Engine, stream: *Stream, decoder: decoding.Decoder, file: ?std.Io.File) error{ OutOfMemory, InvalidData }!Player {
        try stream.start(decoder);
        const player = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.createVoice(Voice.init(.{ .stream = stream }, decoder.sample_rate, stream.keep, decoder.frames)) catch |err| {
                stream.unstart();
                return err;
            };
        };
        stream.file = file;
        self.decode_mutex.lock();
        stream.next = self.streams;
        if (self.streams) |first| first.previous = stream;
        self.streams = stream;
        self.decode_mutex.unlock();
        wakeFutex(&self.decode_wake);
        return player;
    }

    /// Mutex held.
    fn createVoice(self: *Engine, init_voice: Voice) error{OutOfMemory}!Player {
        self.reclaim();
        try self.voices.ensureTotalCapacity(self.allocator, self.live + 1);
        if (self.free_slot == no_slot) try self.slots.ensureUnusedCapacity(self.allocator, 1);
        const voice = try self.allocator.create(Voice);
        voice.* = init_voice;
        const index = if (self.free_slot != no_slot) blk: {
            const index = self.free_slot;
            self.free_slot = self.slots.items[index].next_free;
            break :blk index;
        } else blk: {
            self.slots.appendAssumeCapacity(.{});
            break :blk @as(u32, @intCast(self.slots.items.len - 1));
        };
        const slot = &self.slots.items[index];
        slot.voice = voice;
        slot.next_free = no_slot;
        voice.slot = index;
        self.live += 1;
        return .{ .engine = self, .index = index, .generation = slot.generation };
    }

    /// Mutex held.
    fn resolve(self: *Engine, player: Player) ?*Voice {
        if (player.index >= self.slots.items.len) return null;
        const slot = self.slots.items[player.index];
        if (slot.generation != player.generation) return null;
        return slot.voice;
    }

    /// Mutex held: plays from where the voice is, or from the start if it
    /// ended.
    fn start(self: *Engine, voice: *Voice) void {
        if (voice.closed or voice.playing) return;
        if (voice.ended()) {
            voice.source.seek(0);
            voice.reset(0);
        }
        voice.playing = true;
        if (!voice.active) {
            // A sound starting at its start starts at once; one resuming in
            // the middle fades in, as one pausing fades out, without a click.
            // One still fading out ramps back from where it is.
            voice.snap = voice.index + 3 <= 0;
            voice.fade_in = !voice.snap;
            voice.active = true;
            self.voices.appendAssumeCapacity(voice);
            wakeFutex(&self.output_wake);
        }
    }

    /// Mutex held: closes the voice for good and frees its slot. The voice
    /// itself is freed once out of the mix.
    fn retire(self: *Engine, voice: *Voice) void {
        if (voice.retired) return;
        voice.retired = true;
        voice.closed = true;
        voice.playing = false;
        if (voice.source == .stream) voice.source.stream.close();
        self.unqueue(voice);
        const slot = &self.slots.items[voice.slot];
        slot.voice = null;
        slot.generation +%= 1;
        slot.next_free = self.free_slot;
        self.free_slot = voice.slot;
        if (!voice.active) {
            voice.next_finished = self.finished;
            self.finished = voice;
        }
    }

    /// Mutex held: frees retired voices out of the mix.
    fn reclaim(self: *Engine) void {
        while (self.finished) |voice| {
            self.finished = voice.next_finished;
            self.freeVoice(voice);
        }
    }

    fn freeVoice(self: *Engine, voice: *Voice) void {
        if (voice.source == .memory) voice.source.memory.sound.release();
        self.allocator.destroy(voice);
        self.live -= 1;
    }

    fn queue(self: *Engine, voice: *Voice) void {
        if (voice.notify_queued) return;
        voice.notify_queued = true;
        voice.next_pending = null;
        voice.previous_pending = self.pending_tail;
        if (self.pending_tail) |tail| tail.next_pending = voice else self.pending_head = voice;
        self.pending_tail = voice;
    }

    fn unqueue(self: *Engine, voice: *Voice) void {
        if (!voice.notify_queued) return;
        voice.notify_queued = false;
        if (voice.previous_pending) |previous| previous.next_pending = voice.next_pending else self.pending_head = voice.next_pending;
        if (voice.next_pending) |next| next.previous_pending = voice.previous_pending else self.pending_tail = voice.previous_pending;
        voice.next_pending = null;
        voice.previous_pending = null;
    }

    // Mixing.

    /// Mixes the next frames of every player into `out`, interleaved
    /// stereo at `sample_rate`, and reports whether any plays. Only for a
    /// manual engine, from one thread at a time.
    pub fn render(self: *Engine, out: []f32) bool {
        std.debug.assert(self.mode == .manual);
        return self.mixOutput(out);
    }

    fn mixOutput(self: *Engine, out: []f32) bool {
        self.mutex.lock();
        @memset(out, 0);
        var kept: usize = 0;
        for (self.voices.items) |voice| {
            const outcome: mixer.Outcome = if (voice.closed) .faded else voice.mix(out, self.master);
            if (outcome == .playing) {
                self.voices.items[kept] = voice;
                kept += 1;
                continue;
            }
            voice.active = false;
            if (voice.retired) {
                voice.next_finished = self.finished;
                self.finished = voice;
                continue;
            }
            const done = outcome == .ended and (voice.free_at_end or voice.released) or outcome == .faded and voice.released;
            if (outcome == .ended and voice.on_ended != null and self.notifier != null and !self.app_closed) {
                self.queue(voice);
                voice.retire_after_notify = done;
            } else if (done) self.retire(voice);
        }
        self.voices.items.len = kept;
        for (out) |*sample| sample.* = std.math.clamp(sample.*, -1, 1);
        const post = self.wantPost();
        self.mutex.unlock();
        if (post) self.postNotify();
        return kept > 0;
    }

    /// Mutex held.
    fn wantPost(self: *Engine) bool {
        if (self.posted or self.notifier == null or self.app_closed) return false;
        if (self.pending_head == null and !self.output_changed) return false;
        self.posted = true;
        return true;
    }

    fn postNotify(self: *Engine) void {
        self.app.?.post(.{ .context = self.notifier.?, .call = deliver }) catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.posted = false;
            if (err == error.Closed) {
                // Nothing more runs on the main thread: drop what waits.
                self.app_closed = true;
                self.output_changed = false;
                while (self.pending_head) |voice| {
                    self.unqueue(voice);
                    if (voice.retire_after_notify and !voice.active) self.retire(voice);
                }
            }
            // Full: posted again after the next mix.
        };
    }

    fn deliver(context: *anyopaque) void {
        const notifier: *Notifier = @ptrCast(@alignCast(context));
        const self = notifier.engine orelse {
            notifier.allocator.destroy(notifier);
            return;
        };
        while (true) {
            self.mutex.lock();
            if (self.output_changed) {
                self.output_changed = false;
                const callback = self.on_output;
                self.mutex.unlock();
                if (callback) |handler| handler.call(handler.context, self);
                continue;
            }
            const voice = self.pending_head orelse {
                self.posted = false;
                self.reclaim();
                self.mutex.unlock();
                return;
            };
            self.unqueue(voice);
            const callback = voice.on_ended.?;
            const player = Player{ .engine = self, .index = voice.slot, .generation = self.slots.items[voice.slot].generation };
            if (voice.retire_after_notify and !voice.active) self.retire(voice);
            self.mutex.unlock();
            callback.call(callback.context, player);
        }
    }

    fn requestOutputNotify(self: *Engine) void {
        if (self.on_output == null) return;
        self.mutex.lock();
        self.output_changed = true;
        const post = self.wantPost();
        self.mutex.unlock();
        if (post) self.postNotify();
    }

    // Decoding.

    /// Decodes every stream ahead until each is full or ended. Only for a
    /// manual engine, from one thread at a time.
    pub fn decode(self: *Engine) void {
        std.debug.assert(self.mode == .manual);
        while (self.decodePass()) {}
    }

    /// Reports whether any stream had work.
    fn decodePass(self: *Engine) bool {
        var worked = false;
        self.decode_mutex.lock();
        var cursor = self.streams;
        self.decode_mutex.unlock();
        while (cursor) |stream| {
            var closed = false;
            for (0..64) |_| switch (stream.step()) {
                .idle => break,
                .worked => worked = true,
                .closed => {
                    closed = true;
                    break;
                },
            };
            self.decode_mutex.lock();
            cursor = stream.next;
            if (closed) {
                if (stream.previous) |previous| previous.next = stream.next else self.streams = stream.next;
                if (stream.next) |next| next.previous = stream.previous;
            }
            self.decode_mutex.unlock();
            if (closed) {
                stream.destroy();
                worked = true;
            }
        }
        return worked;
    }

    fn decodeMain(self: *Engine) void {
        while (true) {
            const seen = self.decode_wake.load(.acquire);
            if (self.quit.load(.acquire)) return;
            if (!self.decodePass()) zio.Futex.wait(&self.decode_wake, seen);
        }
    }

    // Output.

    /// How long the output stays open with nothing playing.
    pub const idle_close = 5 * std.time.ns_per_s;

    fn outputMain(self: *Engine) void {
        if (self.mode == .system) output.system.threadInit();
        defer if (self.mode == .system) output.system.threadDeinit();
        var null_device: output.NullDevice = undefined;
        while (true) {
            while (true) {
                const seen = self.output_wake.load(.acquire);
                if (self.quit.load(.acquire)) return;
                self.mutex.lock();
                const busy = self.voices.items.len > 0;
                self.mutex.unlock();
                if (busy) break;
                zio.Futex.wait(&self.output_wake, seen);
            }
            var detail: output.Detail = .{};
            const opened: output.OpenError!output.Device = switch (self.mode) {
                .system => output.system.open(&self.system_storage, &detail),
                .custom => |opener| opener.open(opener.context, &detail),
                .silent, .manual => null_blk: {
                    null_device = .init(self.clock, false);
                    break :null_blk null_device.device();
                },
            };
            const device = opened catch |err| blk: {
                null_device = .init(self.clock, err != error.Unsupported);
                self.setError(err, detail.slice());
                break :blk null_device.device();
            };
            if (opened) |_| self.setError(null, "") else |_| {}
            var idle: u64 = 0;
            while (!self.quit.load(.acquire)) {
                const busy = self.mixOutput(&self.mix_buffer);
                device.write(&self.mix_buffer) catch break;
                if (busy) {
                    idle = 0;
                } else {
                    idle += std.time.ns_per_s / 100;
                    if (idle >= idle_close) break;
                }
            }
            device.close();
        }
    }

    fn setError(self: *Engine, err: ?output.OpenError, detail: []const u8) void {
        self.error_mutex.lock();
        const changed = self.output_error != err or !std.mem.eql(u8, self.detail.slice(), detail);
        self.output_error = err;
        self.detail.set("{s}", .{detail});
        self.error_mutex.unlock();
        if (changed) self.requestOutputNotify();
    }

    /// Why the output last opened is not the system's audio output, as on a
    /// machine with none, or null.
    pub fn outputError(self: *Engine) ?output.OpenError {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        return self.output_error;
    }

    /// The audio system's own words for `outputError`, copied into `buffer`.
    pub fn outputErrorDetail(self: *Engine, buffer: []u8) []u8 {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        const text = self.detail.slice();
        const count = @min(buffer.len, text.len);
        @memcpy(buffer[0..count], text[0..count]);
        return buffer[0..count];
    }

    /// Sets the volume of everything played, a gain: 1 (the default) as
    /// decoded, 0 silent.
    pub fn setVolume(self: *Engine, gain: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.master = @max(gain, 0);
    }

    pub fn volume(self: *Engine) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.master;
    }
};

/// A player plays a sound or a stream: its position, volume, pan, speed and
/// looping are its own. A value handle: once closed, released and done, or
/// torn down with the engine, it goes stale and every method does nothing.
pub const Player = struct {
    engine: *Engine,
    index: u32,
    generation: u32,

    fn lock(self: Player) ?*Voice {
        self.engine.mutex.lock();
        return self.engine.resolve(self) orelse {
            self.engine.mutex.unlock();
            return null;
        };
    }

    fn unlock(self: Player) void {
        self.engine.mutex.unlock();
    }

    /// Plays from where the player is, or from the start if it ended.
    pub fn play(self: Player) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        self.engine.start(voice);
    }

    /// Pauses where the player is, fading out without a click.
    pub fn pause(self: Player) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        voice.playing = false;
    }

    /// Pauses and moves to the start.
    pub fn stop(self: Player) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        voice.playing = false;
        voice.source.seek(0);
        voice.reset(0);
    }

    /// False once paused, stopped, closed, or at its end.
    pub fn isPlaying(self: Player) bool {
        const voice = self.lock() orelse return false;
        defer self.unlock();
        return voice.playing;
    }

    fn toFrame(voice: *const Voice, nanoseconds: u64) i64 {
        var frame: i64 = @intFromFloat(@round(@as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s * voice.rate));
        if (voice.length >= 0) frame = @min(frame, voice.length);
        return frame;
    }

    /// Moves to `nanoseconds` from the start.
    pub fn seek(self: Player, nanoseconds: u64) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        const frame = toFrame(voice, nanoseconds);
        voice.source.seek(frame);
        voice.reset(frame);
    }

    /// Nanoseconds from the start.
    pub fn position(self: Player) u64 {
        const voice = self.lock() orelse return 0;
        defer self.unlock();
        return @intFromFloat(voice.position() / voice.rate * std.time.ns_per_s);
    }

    /// How long the audio is in nanoseconds, or null when unknown.
    pub fn duration(self: Player) ?u64 {
        const voice = self.lock() orelse return null;
        defer self.unlock();
        if (voice.length < 0) return null;
        return framesToNanoseconds(@intCast(voice.length), @intFromFloat(voice.rate));
    }

    /// A gain: 1 (the default) as decoded, 0 silent. Changes ramp over a
    /// few milliseconds, without a click.
    pub fn setVolume(self: Player, volume_value: f64) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        voice.volume = @max(volume_value, 0);
    }

    pub fn volume(self: Player) f64 {
        const voice = self.lock() orelse return 0;
        defer self.unlock();
        return voice.volume;
    }

    /// Places the player between the left speaker (-1) and the right (1);
    /// 0, the default, is the middle. A mono sound pans keeping its power;
    /// a stereo one keeps both channels, folding one side into the other.
    pub fn setPan(self: Player, pan_value: f64) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        voice.pan = std.math.clamp(pan_value, -1, 1);
    }

    pub fn pan(self: Player) f64 {
        const voice = self.lock() orelse return 0;
        defer self.unlock();
        return voice.pan;
    }

    /// How fast the player plays, which changes its pitch with it: 1 (the
    /// default) as decoded, 2 twice as fast and an octave higher, at most 16.
    pub fn setSpeed(self: Player, speed_value: f64) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        if (speed_value > 0 and !std.math.isInf(speed_value)) voice.speed = @min(speed_value, 16);
    }

    pub fn speed(self: Player) f64 {
        const voice = self.lock() orelse return 0;
        defer self.unlock();
        return voice.speed;
    }

    /// Whether the player starts again from the start, or its loop's start
    /// (`setLoopRange`), at its end, without a gap. A change is heard after
    /// what the player decoded ahead: a few milliseconds of a sound, up to
    /// a second of a stream.
    pub fn setLoop(self: Player, loop: bool) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        voice.loop = loop;
        voice.source.setLoop(loop, voice.loop_start, voice.loop_end);
    }

    /// Loops between `start` and `end` nanoseconds without a gap, `end` 0
    /// being the end of the audio: what is before `start`, as a tune's
    /// intro, plays once. It sets the player looping; `setLoop(false)` plays
    /// on past `end`.
    pub fn setLoopRange(self: Player, start: u64, end: u64) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        var first = toFrame(voice, start);
        var last = toFrame(voice, end);
        // Nothing to loop: all of it.
        if (last != 0 and last <= first) {
            first = 0;
            last = 0;
        }
        voice.loop_start = first;
        voice.loop_end = last;
        voice.loop = true;
        voice.source.setLoop(true, first, last);
    }

    pub fn isLooping(self: Player) bool {
        const voice = self.lock() orelse return false;
        defer self.unlock();
        return voice.loop;
    }

    /// Calls `callback` on the App's main thread each time the player plays
    /// to its end; null stops. Needs an engine with an App.
    pub fn onEnded(self: Player, callback: ?EndedCallback) error{NoApp}!void {
        if (self.engine.app == null) return error.NoApp;
        const voice = self.lock() orelse return;
        defer self.unlock();
        voice.on_ended = callback;
        if (callback == null) self.engine.unqueue(voice);
    }

    /// Stops the player for good and frees what it plays with.
    pub fn close(self: Player) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        self.engine.retire(voice);
        self.engine.reclaim();
    }

    /// Lets go of the player: it plays on to its end, or its fade, and then
    /// closes itself; a paused one closes now.
    pub fn release(self: Player) void {
        const voice = self.lock() orelse return;
        defer self.unlock();
        voice.released = true;
        if (!voice.active) {
            self.engine.retire(voice);
            self.engine.reclaim();
        }
    }

    pub fn isValid(self: Player) bool {
        const voice = self.lock() orelse return false;
        _ = voice;
        self.unlock();
        return true;
    }
};
