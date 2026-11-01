//! macOS plays through an Audio Queue on the default output, which follows
//! the default when it changes. The queue's own thread hands back each
//! buffer it is done with; a write waits for one, so the queue holds about
//! `ahead` before frames are heard.
const std = @import("std");
const output = @import("output.zig");
const Detail = output.Detail;
const OpenError = output.OpenError;

const OSStatus = i32;
const AudioQueueRef = *opaque {};

const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32 = 0,
};

const AudioQueueBuffer = extern struct {
    capacity: u32,
    data: *anyopaque,
    size: u32,
    user_data: ?*anyopaque,
    packet_description_capacity: u32,
    packet_descriptions: ?*anyopaque,
    packet_description_count: u32,
};

const OutputCallback = *const fn (user: ?*anyopaque, queue: AudioQueueRef, buffer: *AudioQueueBuffer) callconv(.c) void;

extern "c" fn AudioQueueNewOutput(format: *const AudioStreamBasicDescription, callback: OutputCallback, user: ?*anyopaque, run_loop: ?*anyopaque, run_loop_mode: ?*anyopaque, flags: u32, queue: *?AudioQueueRef) OSStatus;
extern "c" fn AudioQueueAllocateBuffer(queue: AudioQueueRef, size: u32, buffer: *?*AudioQueueBuffer) OSStatus;
extern "c" fn AudioQueueEnqueueBuffer(queue: AudioQueueRef, buffer: *AudioQueueBuffer, descriptions: u32, packet_descriptions: ?*const anyopaque) OSStatus;
extern "c" fn AudioQueueStart(queue: AudioQueueRef, at: ?*const anyopaque) OSStatus;
extern "c" fn AudioQueueStop(queue: AudioQueueRef, immediate: u8) OSStatus;
extern "c" fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) OSStatus;
extern "c" fn pthread_cond_timedwait_relative_np(cond: *std.c.pthread_cond_t, mutex: *std.c.pthread_mutex_t, relative: *const std.c.timespec) c_int;

const format_linear_pcm: u32 = 0x6C70636D; // 'lpcm'
const format_flag_float: u32 = 1;
const format_flag_packed: u32 = 8;

/// Frames in each buffer: one engine write.
const buffer_frames = output.period_frames;
const max_buffers = 64;

pub fn threadInit() void {}
pub fn threadDeinit() void {}

pub const Storage = struct {
    queue: ?AudioQueueRef = null,
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    /// Buffers the queue is done with, ready to fill.
    free: [max_buffers]*AudioQueueBuffer = undefined,
    free_count: usize = 0,
    buffers: usize = 0,
    /// Buffers enqueued before the queue started.
    queued: usize = 0,
    started: bool = false,
};

/// The queue's thread gives a played buffer back.
fn played(user: ?*anyopaque, queue: AudioQueueRef, buffer: *AudioQueueBuffer) callconv(.c) void {
    const storage: *Storage = @ptrCast(@alignCast(user.?));
    _ = std.c.pthread_mutex_lock(&storage.mutex);
    defer _ = std.c.pthread_mutex_unlock(&storage.mutex);
    if (storage.queue != queue or storage.free_count == storage.free.len) return;
    storage.free[storage.free_count] = buffer;
    storage.free_count += 1;
    _ = std.c.pthread_cond_signal(&storage.cond);
}

/// Buffers holding `ahead` nanoseconds, two at least.
fn bufferCount(ahead: u64) usize {
    const frames = ahead * output.sample_rate / std.time.ns_per_s;
    return @min(max_buffers, @max(2, (frames + buffer_frames - 1) / buffer_frames));
}

fn fail(storage: *Storage, detail: *Detail, err: OpenError, call: []const u8, status: OSStatus) OpenError {
    closeStorage(storage);
    detail.set("Audio Queue: {s} failed (OSStatus {d})", .{ call, status });
    return err;
}

pub fn open(storage: *Storage, ahead: u64, detail: *Detail) OpenError!output.Device {
    storage.* = .{};
    const format: AudioStreamBasicDescription = .{
        .sample_rate = output.sample_rate,
        .format_id = format_linear_pcm,
        .format_flags = format_flag_float | format_flag_packed,
        .bytes_per_packet = output.channels * 4,
        .frames_per_packet = 1,
        .bytes_per_frame = output.channels * 4,
        .channels_per_frame = output.channels,
        .bits_per_channel = 32,
    };
    var queue: ?AudioQueueRef = null;
    // Not on a run loop: the queue calls back on a thread of its own.
    var status = AudioQueueNewOutput(&format, played, storage, null, null, 0, &queue);
    if (status != 0) return fail(storage, detail, error.DeviceFailed, "AudioQueueNewOutput", status);
    storage.queue = queue;
    const count = bufferCount(ahead);
    for (0..count) |_| {
        var buffer: ?*AudioQueueBuffer = null;
        status = AudioQueueAllocateBuffer(queue.?, buffer_frames * output.channels * 4, &buffer);
        if (status != 0) return fail(storage, detail, error.DeviceFailed, "AudioQueueAllocateBuffer", status);
        storage.free[storage.free_count] = buffer.?;
        storage.free_count += 1;
    }
    storage.buffers = count;
    return .{ .context = storage, .vtable = &vtable };
}

const vtable: output.Device.VTable = .{ .write = write, .close = close };

/// A buffer the queue is done with, waiting at most a second for one.
fn take(storage: *Storage) ?*AudioQueueBuffer {
    _ = std.c.pthread_mutex_lock(&storage.mutex);
    defer _ = std.c.pthread_mutex_unlock(&storage.mutex);
    var waited: u64 = 0;
    while (storage.free_count == 0) {
        // The queue stopped taking buffers, as when its device went.
        if (waited >= std.time.ns_per_s) return null;
        const step = 100 * std.time.ns_per_ms;
        const relative: std.c.timespec = .{ .sec = 0, .nsec = step };
        _ = pthread_cond_timedwait_relative_np(&storage.cond, &storage.mutex, &relative);
        waited += step;
    }
    storage.free_count -= 1;
    return storage.free[storage.free_count];
}

fn write(context: *anyopaque, samples: []const f32) output.WriteError!void {
    const storage: *Storage = @ptrCast(@alignCast(context));
    var rest = samples;
    while (rest.len > 0) {
        const buffer = take(storage) orelse return error.Unresponsive;
        const count = @min(rest.len, buffer.capacity / 4);
        const destination: [*]f32 = @ptrCast(@alignCast(buffer.data));
        @memcpy(destination[0..count], rest[0..count]);
        buffer.size = @intCast(count * 4);
        rest = rest[count..];
        if (AudioQueueEnqueueBuffer(storage.queue.?, buffer, 0, null) != 0) return error.DeviceLost;
        if (!storage.started) {
            // Start once every buffer holds something, not to begin with
            // an underrun.
            storage.queued += 1;
            if (storage.queued == storage.buffers) {
                if (AudioQueueStart(storage.queue.?, null) != 0) return error.DeviceLost;
                storage.started = true;
            }
        }
    }
}

fn close(context: *anyopaque) void {
    closeStorage(@ptrCast(@alignCast(context)));
}

fn closeStorage(storage: *Storage) void {
    if (storage.queue) |queue| {
        _ = AudioQueueStop(queue, 1);
        // Disposing frees the buffers; it returns once no callback runs.
        _ = AudioQueueDispose(queue, 1);
    }
    _ = std.c.pthread_mutex_lock(&storage.mutex);
    storage.queue = null;
    storage.free_count = 0;
    _ = std.c.pthread_mutex_unlock(&storage.mutex);
}

test "an Audio Queue holds enough buffers for the latency asked" {
    try std.testing.expectEqual(@as(usize, 2), bufferCount(0));
    try std.testing.expectEqual(@as(usize, 2), bufferCount(15 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 5), bufferCount(50 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 6), bufferCount(51 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, max_buffers), bufferCount(10 * std.time.ns_per_s));
}
