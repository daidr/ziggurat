//! In browsers, a video element of the page's runtime plays the video, not
//! in the page (web/ziggurat.js): it decodes, plays the sound and keeps the
//! clock, and WebGL uploads each picture from it, GPU to GPU. Where the
//! browser has requestVideoFrameCallback each picture the element presents
//! wakes the player; elsewhere the player asks for frames at the display's
//! rate while it plays. A video that may not play its sound before the user
//! interacted with the page plays muted.
const std = @import("std");
const ui = @import("ziggurat_ui");
const video = @import("ziggurat_view_video");
const source = @import("source.zig");

extern "ziggurat" fn zw_video_open(engine: *Engine, url: [*]const u8, url_len: usize, data: [*]const u8, data_len: usize) u32;
extern "ziggurat" fn zw_video_frame(id: u32, out: *[3]u32) u32;
extern "ziggurat" fn zw_video_state(id: u32) u32;
extern "ziggurat" fn zw_video_number(id: u32, what: u32) f64;
extern "ziggurat" fn zw_video_control(id: u32, what: u32, value: f64) void;
extern "ziggurat" fn zw_video_read(id: u32, pixels: [*]u8, stride: u32, width: u32, height: u32) u32;
extern "ziggurat" fn zw_video_close(id: u32) void;

const Control = enum(u32) { play, pause, seek, loop, rate, volume, muted };

pub const Engine = struct {
    id: u32 = 0,
    wake: ?video.Wake = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn open(from: source.Source) !*Engine {
        const self = try std.heap.wasm_allocator.create(Engine);
        self.* = .{};
        const empty: []const u8 = "";
        self.id = switch (from) {
            .url => |url| zw_video_open(self, url.ptr, url.len, empty.ptr, 0),
            .data => |bytes| zw_video_open(self, empty.ptr, 0, bytes.ptr, bytes.len),
        };
        if (self.id == 0) {
            std.heap.wasm_allocator.destroy(self);
            return error.Unsupported;
        }
        return self;
    }

    /// The element's wake: a picture presented, or its state changed.
    fn wakes(self: *Engine) callconv(.c) void {
        if (self.wake) |w| w.call(w.context);
    }
    comptime {
        @export(&wakes, .{ .name = "ziggurat_video_wake" });
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
    fn control(ptr: *anyopaque, what: Control, value: f64) void {
        zw_video_control(cast(ptr).id, @backingInt(what), value);
    }
    fn setWake(ptr: *anyopaque, wake: ?video.Wake) void {
        cast(ptr).wake = wake;
    }
    fn frame(ptr: *anyopaque, _: u64) ?video.Frame {
        const self = cast(ptr);
        var out: [3]u32 = .{ 0, 0, 0 };
        if (zw_video_frame(self.id, &out) == 0 or out[0] == 0 or out[1] == 0) return null;
        self.width = out[0];
        self.height = out[1];
        return .{ .changed = out[2] != 0, .picture = .{
            .width = out[0],
            .height = out[1],
            .format = .bgra,
            .element = self.id,
            .read = read,
            .read_context = self,
        } };
    }
    /// The picture drawn into a canvas and read back, for the software
    /// renderer.
    fn read(context: ?*anyopaque, picture: *const ui.drawing.VideoPicture, pixels: [*]u8, stride: u32) callconv(.c) bool {
        const self = cast(context.?);
        return zw_video_read(self.id, pixels, stride, picture.width, picture.height) != 0;
    }
    fn intervalOf(ptr: *anyopaque) u64 {
        return @intFromFloat(zw_video_number(cast(ptr).id, 2) * std.time.ns_per_s);
    }
    fn stateOf(ptr: *anyopaque) video.State {
        return switch (zw_video_state(cast(ptr).id)) {
            0 => .loading,
            1 => .ready,
            2 => .buffering,
            3 => .ended,
            else => .failed,
        };
    }
    fn failureOf(ptr: *anyopaque) ?anyerror {
        return if (zw_video_state(cast(ptr).id) == 4) error.VideoFailed else null;
    }
    fn sizeOf(ptr: *anyopaque) [2]u32 {
        const self = cast(ptr);
        return .{ self.width, self.height };
    }
    fn seconds(value: f64) u64 {
        if (!(value > 0) or value > 1e9) return 0;
        return @intFromFloat(value * std.time.ns_per_s);
    }
    fn durationOf(ptr: *anyopaque) u64 {
        return seconds(zw_video_number(cast(ptr).id, 0));
    }
    fn positionOf(ptr: *anyopaque) u64 {
        return seconds(zw_video_number(cast(ptr).id, 1));
    }
    fn play(ptr: *anyopaque) void {
        control(ptr, .play, 0);
    }
    fn pause(ptr: *anyopaque) void {
        control(ptr, .pause, 0);
    }
    fn seek(ptr: *anyopaque, at: u64) void {
        control(ptr, .seek, @as(f64, @floatFromInt(at)) / std.time.ns_per_s);
    }
    fn setLoop(ptr: *anyopaque, value: bool) void {
        control(ptr, .loop, @floatFromInt(@intFromBool(value)));
    }
    fn setRate(ptr: *anyopaque, value: f64) void {
        control(ptr, .rate, value);
    }
    fn setVolume(ptr: *anyopaque, value: f64) void {
        control(ptr, .volume, value);
    }
    fn setMuted(ptr: *anyopaque, value: bool) void {
        control(ptr, .muted, @floatFromInt(@intFromBool(value)));
    }
    fn close(ptr: *anyopaque) void {
        const self = cast(ptr);
        zw_video_close(self.id);
        std.heap.wasm_allocator.destroy(self);
    }
};
