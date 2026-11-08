//! On macOS, AVFoundation plays the video: src/video/avfoundation.m keeps
//! the AVPlayer and its video output, which this wraps as an engine. Its
//! pictures are CVPixelBuffers that Metal draws without a copy; the CPU
//! renderer reads their planes, locked as it converts them.
const zio = @import("ziggurat_io");
const ui = @import("ziggurat_ui");
const video = @import("ziggurat_view_video");
const source = @import("source.zig");

extern fn zv_avf_open(url: ?[*:0]const u8, bytes: ?[*]const u8, length: usize, out: *?*anyopaque) c_int;
extern fn zv_avf_set_wake(handle: *anyopaque, wake: ?*const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) void;
extern fn zv_avf_frame(handle: *anyopaque, ahead: u64, picture: *ui.drawing.VideoPicture, changed: *bool) bool;
extern fn zv_avf_lock(buffer: *anyopaque, planes: *[2]?[*]const u8, strides: *[2]u32) bool;
extern fn zv_avf_unlock(buffer: *anyopaque) void;
extern fn zv_avf_interval(handle: *anyopaque) u64;
extern fn zv_avf_state(handle: *anyopaque, failure: ?[*]u8, length: usize) c_int;
extern fn zv_avf_size(handle: *anyopaque, size: *[2]u32) void;
extern fn zv_avf_duration(handle: *anyopaque) u64;
extern fn zv_avf_position(handle: *anyopaque) u64;
extern fn zv_avf_play(handle: *anyopaque) void;
extern fn zv_avf_pause(handle: *anyopaque) void;
extern fn zv_avf_seek(handle: *anyopaque, at: u64) void;
extern fn zv_avf_set_loop(handle: *anyopaque, looping: bool) void;
extern fn zv_avf_set_rate(handle: *anyopaque, rate: f64) void;
extern fn zv_avf_set_volume(handle: *anyopaque, volume: f64) void;
extern fn zv_avf_set_muted(handle: *anyopaque, muted: bool) void;
extern fn zv_avf_close(handle: *anyopaque) void;

pub const Engine = struct {
    handle: *anyopaque,
    mutex: zio.Mutex = .{},
    wake: ?video.Wake = null,

    pub fn open(from: source.Source) !*Engine {
        var owned: ?[:0]u8 = null;
        defer if (owned) |text| zio.heap.free(text);
        var handle: ?*anyopaque = null;
        const result = switch (from) {
            .url => |text| blk: {
                owned = try zio.heap.dupeSentinel(u8, text, 0);
                break :blk zv_avf_open(owned.?.ptr, null, 0, &handle);
            },
            .data => |bytes| zv_avf_open(null, bytes.ptr, bytes.len, &handle),
        };
        switch (result) {
            0 => {},
            1 => return error.Unsupported,
            else => return error.InvalidUrl,
        }
        const self = zio.heap.create(Engine) catch |err| {
            zv_avf_close(handle.?);
            return err;
        };
        self.* = .{ .handle = handle.? };
        return self;
    }

    pub fn engine(self: *Engine) video.Engine {
        return .{ .context = self, .vtable = &vtable };
    }
    const vtable: video.Engine.VTable = .{
        .set_wake = setWake,
        .frame = frame,
        .interval = intervalOf,
        .state = stateOf,
        .failure = failureOf,
        .size = sizeOf,
        .duration = durationOf,
        .position = positionOf,
        .play = play,
        .pause = pause,
        .seek = seek,
        .set_loop = setLoop,
        .set_rate = setRate,
        .set_volume = setVolume,
        .set_muted = setMuted,
        .close = close,
    };
    fn cast(ptr: *anyopaque) *Engine {
        return @ptrCast(@alignCast(ptr));
    }
    fn setWake(ptr: *anyopaque, wake: ?video.Wake) void {
        const self = cast(ptr);
        self.mutex.lock();
        self.wake = wake;
        self.mutex.unlock();
        zv_avf_set_wake(self.handle, if (wake != null) wakes else null, self);
    }
    /// The watching thread's wake.
    fn wakes(ptr: ?*anyopaque) callconv(.c) void {
        const self = cast(ptr.?);
        self.mutex.lock();
        const wake = self.wake;
        self.mutex.unlock();
        if (wake) |w| w.call(w.context);
    }
    fn frame(ptr: *anyopaque, ahead: u64) ?video.Frame {
        const self = cast(ptr);
        var picture: ui.drawing.VideoPicture = .{ .width = 0, .height = 0 };
        var changed = false;
        if (!zv_avf_frame(self.handle, ahead, &picture, &changed)) return null;
        picture.read = read;
        return .{ .picture = picture, .changed = changed };
    }
    /// Converts a pixel buffer's planes, locked in memory, for the CPU
    /// renderer.
    fn read(_: ?*anyopaque, picture: *const ui.drawing.VideoPicture, pixels: [*]u8, stride: u32) callconv(.c) bool {
        const buffer = picture.native orelse return false;
        var planes: [2]?[*]const u8 = .{ null, null };
        var strides: [2]u32 = .{ 0, 0 };
        if (!zv_avf_lock(buffer, &planes, &strides)) return false;
        defer zv_avf_unlock(buffer);
        var mapped = picture.*;
        mapped.planes = planes;
        mapped.strides = strides;
        mapped.native = null;
        mapped.read = null;
        return ui.video_image.toBgra(mapped, pixels[0 .. @as(usize, stride) * picture.height], stride);
    }
    fn intervalOf(ptr: *anyopaque) u64 {
        return zv_avf_interval(cast(ptr).handle);
    }
    fn stateOf(ptr: *anyopaque) video.State {
        return switch (zv_avf_state(cast(ptr).handle, null, 0)) {
            0 => .loading,
            1 => .ready,
            2 => .buffering,
            3 => .ended,
            else => .failed,
        };
    }
    fn failureOf(ptr: *anyopaque) ?anyerror {
        if (zv_avf_state(cast(ptr).handle, null, 0) != 4) return null;
        return error.VideoFailed;
    }
    fn sizeOf(ptr: *anyopaque) [2]u32 {
        var size: [2]u32 = .{ 0, 0 };
        zv_avf_size(cast(ptr).handle, &size);
        return size;
    }
    fn durationOf(ptr: *anyopaque) u64 {
        return zv_avf_duration(cast(ptr).handle);
    }
    fn positionOf(ptr: *anyopaque) u64 {
        return zv_avf_position(cast(ptr).handle);
    }
    fn play(ptr: *anyopaque) void {
        zv_avf_play(cast(ptr).handle);
    }
    fn pause(ptr: *anyopaque) void {
        zv_avf_pause(cast(ptr).handle);
    }
    fn seek(ptr: *anyopaque, at: u64) void {
        zv_avf_seek(cast(ptr).handle, at);
    }
    fn setLoop(ptr: *anyopaque, value: bool) void {
        zv_avf_set_loop(cast(ptr).handle, value);
    }
    fn setRate(ptr: *anyopaque, value: f64) void {
        zv_avf_set_rate(cast(ptr).handle, value);
    }
    fn setVolume(ptr: *anyopaque, value: f64) void {
        zv_avf_set_volume(cast(ptr).handle, value);
    }
    fn setMuted(ptr: *anyopaque, value: bool) void {
        zv_avf_set_muted(cast(ptr).handle, value);
    }
    fn close(ptr: *anyopaque) void {
        const self = cast(ptr);
        zv_avf_close(self.handle);
        zio.heap.destroy(self);
    }
};
