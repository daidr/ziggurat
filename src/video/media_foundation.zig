//! On Windows, Media Foundation plays the video: src/video/media_foundation.c
//! keeps the media engine, which this wraps as an engine. Its pictures are
//! BGRA textures it shares, which Direct3D 11 samples where they are and
//! the CPU renderer has read back, or, where the device shares none, BGRA
//! in memory, read back as each comes.
const std = @import("std");
const zio = @import("ziggurat_io");
const ui = @import("ziggurat_ui");
const video = @import("ziggurat_view_video");
const source = @import("source.zig");

extern fn zv_mf_open(url: ?[*:0]const u16, bytes: ?[*]const u8, length: usize, out: *?*anyopaque) c_int;
extern fn zv_mf_set_wake(handle: *anyopaque, wake: ?*const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) void;
extern fn zv_mf_frame(handle: *anyopaque, pixels: *?[*]const u8, width: *u32, height: *u32, changed: *c_int, shared: *?*anyopaque, id: *u32) c_int;
extern fn zv_mf_read(handle: *anyopaque, id: u32, pixels: [*]u8, stride: u32) c_int;
extern fn zv_mf_state(handle: *anyopaque, code: ?*i32) c_int;
extern fn zv_mf_size(handle: *anyopaque, size: *[2]u32) void;
extern fn zv_mf_duration(handle: *anyopaque) u64;
extern fn zv_mf_position(handle: *anyopaque) u64;
extern fn zv_mf_play(handle: *anyopaque) void;
extern fn zv_mf_pause(handle: *anyopaque) void;
extern fn zv_mf_seek(handle: *anyopaque, at: u64) void;
extern fn zv_mf_set_loop(handle: *anyopaque, looping: c_int) void;
extern fn zv_mf_set_rate(handle: *anyopaque, rate: f64) void;
extern fn zv_mf_set_volume(handle: *anyopaque, volume: f64) void;
extern fn zv_mf_set_muted(handle: *anyopaque, muted: c_int) void;
extern fn zv_mf_close(handle: *anyopaque) void;

pub const Engine = struct {
    handle: *anyopaque,
    mutex: zio.Mutex = .{},
    wake: ?video.Wake = null,

    pub fn open(from: source.Source) !*Engine {
        var owned: ?[:0]u16 = null;
        defer if (owned) |text| zio.heap.free(text);
        var handle: ?*anyopaque = null;
        const result = switch (from) {
            .url => |text| blk: {
                owned = try std.unicode.utf8ToUtf16LeAllocZ(zio.heap, text);
                break :blk zv_mf_open(owned.?.ptr, null, 0, &handle);
            },
            .data => |bytes| zv_mf_open(null, bytes.ptr, bytes.len, &handle),
        };
        switch (result) {
            0 => {},
            1 => return error.Unsupported,
            else => return error.InvalidUrl,
        }
        const self = zio.heap.create(Engine) catch |err| {
            zv_mf_close(handle.?);
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
        zv_mf_set_wake(self.handle, if (wake != null) wakes else null, self);
    }
    /// A wake from one of Media Foundation's threads.
    fn wakes(ptr: ?*anyopaque) callconv(.c) void {
        const self = cast(ptr.?);
        self.mutex.lock();
        const wake = self.wake;
        self.mutex.unlock();
        if (wake) |w| w.call(w.context);
    }
    fn frame(ptr: *anyopaque, _: u64) ?video.Frame {
        const self = cast(ptr);
        var pixels: ?[*]const u8 = null;
        var width: u32 = 0;
        var height: u32 = 0;
        var changed: c_int = 0;
        var shared: ?*anyopaque = null;
        var id: u32 = 0;
        if (zv_mf_frame(self.handle, &pixels, &width, &height, &changed, &shared, &id) == 0) return null;
        if (shared != null) return .{ .changed = changed != 0, .picture = .{
            .width = width,
            .height = height,
            .format = .bgra,
            .native = shared,
            .native_id = id,
            .read = read,
            .read_context = self,
        } };
        return .{ .changed = changed != 0, .picture = .{
            .width = width,
            .height = height,
            .format = .bgra,
            .planes = .{ pixels, null },
            .strides = .{ width * 4, 0 },
        } };
    }
    /// Reads a shared picture back for the CPU renderer.
    fn read(context: ?*anyopaque, picture: *const ui.drawing.VideoPicture, pixels: [*]u8, stride: u32) callconv(.c) bool {
        const self = cast(context.?);
        return zv_mf_read(self.handle, picture.native_id, pixels, stride) != 0;
    }
    /// A frame of the window asks for the picture due at the display's
    /// rate: the engine converts it then.
    fn intervalOf(_: *anyopaque) u64 {
        return std.time.ns_per_s / 60;
    }
    fn stateOf(ptr: *anyopaque) video.State {
        return switch (zv_mf_state(cast(ptr).handle, null)) {
            0 => .loading,
            1 => .ready,
            2 => .buffering,
            3 => .ended,
            else => .failed,
        };
    }
    fn failureOf(ptr: *anyopaque) ?anyerror {
        if (zv_mf_state(cast(ptr).handle, null) != 4) return null;
        return error.VideoFailed;
    }
    fn sizeOf(ptr: *anyopaque) [2]u32 {
        var size: [2]u32 = .{ 0, 0 };
        zv_mf_size(cast(ptr).handle, &size);
        return size;
    }
    fn durationOf(ptr: *anyopaque) u64 {
        return zv_mf_duration(cast(ptr).handle);
    }
    fn positionOf(ptr: *anyopaque) u64 {
        return zv_mf_position(cast(ptr).handle);
    }
    fn play(ptr: *anyopaque) void {
        zv_mf_play(cast(ptr).handle);
    }
    fn pause(ptr: *anyopaque) void {
        zv_mf_pause(cast(ptr).handle);
    }
    fn seek(ptr: *anyopaque, at: u64) void {
        zv_mf_seek(cast(ptr).handle, at);
    }
    fn setLoop(ptr: *anyopaque, value: bool) void {
        zv_mf_set_loop(cast(ptr).handle, @intFromBool(value));
    }
    fn setRate(ptr: *anyopaque, value: f64) void {
        zv_mf_set_rate(cast(ptr).handle, value);
    }
    fn setVolume(ptr: *anyopaque, value: f64) void {
        zv_mf_set_volume(cast(ptr).handle, value);
    }
    fn setMuted(ptr: *anyopaque, value: bool) void {
        zv_mf_set_muted(cast(ptr).handle, @intFromBool(value));
    }
    fn close(ptr: *anyopaque) void {
        const self = cast(ptr);
        zv_mf_close(self.handle);
        zio.heap.destroy(self);
    }
};
