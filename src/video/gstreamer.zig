//! On Linux, GStreamer plays the video: a playbin, which demuxes, decodes
//! (in hardware through VA-API where its plugins are installed), plays the
//! sound and keeps the clock, with an appsink as its video sink taking
//! NV12. The appsink hands each frame over as its time comes, on the clock
//! the sound plays by; a thread of the engine's takes it, copies its planes
//! into memory of its own, 1.5 bytes a pixel, and wakes the player, whose
//! renderer uploads them as they are and converts them in its shader. The
//! same thread reads the pipeline's messages. No GLib callback is made, so
//! nothing of ziggurat runs on GStreamer's threads.
//!
//! libgstreamer, libgstapp and libgstvideo are loaded with the first video
//! opened; apps that open none load nothing of them.
const std = @import("std");
const zio = @import("ziggurat_io");
const ui = @import("ziggurat_ui");
const video = @import("ziggurat_view_video");
const source = @import("source.zig");

const drawing = ui.drawing;
const linux = std.os.linux;

const GValue = extern struct { g_type: usize = 0, data: [2]u64 = .{ 0, 0 } };
const MapInfo = extern struct {
    memory: ?*anyopaque = null,
    flags: c_int = 0,
    data: ?[*]u8 = null,
    size: usize = 0,
    maxsize: usize = 0,
    user_data: [4]?*anyopaque = .{ null, null, null, null },
    reserved: [4]?*anyopaque = .{ null, null, null, null },
};
const Ptr = ?*anyopaque;

const Api = struct {
    init: *const fn (argc: ?*c_int, argv: ?*anyopaque) callconv(.c) void,
    element_factory_make: *const fn (factory: [*:0]const u8, name: ?[*:0]const u8) callconv(.c) Ptr,
    element_set_state: *const fn (element: Ptr, state: c_int) callconv(.c) c_int,
    element_get_bus: *const fn (element: Ptr) callconv(.c) Ptr,
    bus_timed_pop_filtered: *const fn (bus: Ptr, timeout: u64, types: c_uint) callconv(.c) Ptr,
    message_parse_error: *const fn (message: Ptr, err: *Ptr, debug: *?[*:0]u8) callconv(.c) void,
    message_parse_buffering: *const fn (message: Ptr, percent: *c_int) callconv(.c) void,
    mini_object_unref: *const fn (object: Ptr) callconv(.c) void,
    object_unref: *const fn (object: Ptr) callconv(.c) void,
    element_seek: *const fn (element: Ptr, rate: f64, format: c_int, flags: c_int, start_type: c_int, start: i64, stop_type: c_int, stop: i64) callconv(.c) c_int,
    element_query_position: *const fn (element: Ptr, format: c_int, current: *i64) callconv(.c) c_int,
    element_query_duration: *const fn (element: Ptr, format: c_int, duration: *i64) callconv(.c) c_int,
    caps_from_string: *const fn (string: [*:0]const u8) callconv(.c) Ptr,
    sample_get_buffer: *const fn (sample: Ptr) callconv(.c) Ptr,
    sample_get_caps: *const fn (sample: Ptr) callconv(.c) Ptr,
    sample_get_type: *const fn () callconv(.c) usize,
    buffer_map: *const fn (buffer: Ptr, info: *MapInfo, flags: c_int) callconv(.c) c_int,
    buffer_unmap: *const fn (buffer: Ptr, info: *MapInfo) callconv(.c) void,
    app_sink_set_caps: *const fn (sink: Ptr, caps: Ptr) callconv(.c) void,
    app_sink_set_max_buffers: *const fn (sink: Ptr, count: c_uint) callconv(.c) void,
    app_sink_set_drop: *const fn (sink: Ptr, drop: c_int) callconv(.c) void,
    app_sink_try_pull_sample: *const fn (sink: Ptr, timeout: u64) callconv(.c) Ptr,
    app_sink_is_eos: *const fn (sink: Ptr) callconv(.c) c_int,
    buffer_get_video_meta: *const fn (buffer: Ptr) callconv(.c) Ptr,
    video_info_new: *const fn () callconv(.c) Ptr,
    video_info_from_caps: *const fn (info: Ptr, caps: Ptr) callconv(.c) c_int,
    video_info_free: *const fn (info: Ptr) callconv(.c) void,
    object_get_property: *const fn (object: Ptr, name: [*:0]const u8, value: *GValue) callconv(.c) void,
    object_set_property: *const fn (object: Ptr, name: [*:0]const u8, value: *const GValue) callconv(.c) void,
    value_init: *const fn (value: *GValue, g_type: usize) callconv(.c) *GValue,
    value_unset: *const fn (value: *GValue) callconv(.c) void,
    value_dup_boxed: *const fn (value: *const GValue) callconv(.c) Ptr,
    value_set_string: *const fn (value: *GValue, string: [*:0]const u8) callconv(.c) void,
    value_set_object: *const fn (value: *GValue, object: Ptr) callconv(.c) void,
    value_set_double: *const fn (value: *GValue, number: f64) callconv(.c) void,
    value_set_boolean: *const fn (value: *GValue, flag: c_int) callconv(.c) void,
    error_free: *const fn (err: Ptr) callconv(.c) void,
    free: *const fn (memory: ?*anyopaque) callconv(.c) void,
};

const state_null = 1;
const state_paused = 3;
const state_playing = 4;
const format_time = 3;
const seek_flush = 1;
const seek_accurate = 2;
const seek_none = 0;
const seek_set = 1;
const message_eos = 1 << 0;
const message_error = 1 << 1;
const message_buffering = 1 << 5;
const message_duration_changed = 1 << 18;
const message_async_done = 1 << 21;
const type_boolean = 5 << 2;
const type_double = 15 << 2;
const type_string = 16 << 2;
const type_object = 20 << 2;
const map_read = 1;
/// Where a GstMessage keeps its type, after its GstMiniObject
/// (GST_MESSAGE_TYPE), and a GstBuffer its PTS, after its GstMiniObject
/// and pool (GST_BUFFER_PTS), on 64-bit systems.
const message_type_offset = 64;
const buffer_pts_offset = 72;

var once = zio.once(load);
var api: ?Api = null;

fn load() void {
    const names = [_][*:0]const u8{ "libgstreamer-1.0.so.0", "libgstapp-1.0.so.0", "libgstvideo-1.0.so.0", "libgobject-2.0.so.0", "libglib-2.0.so.0" };
    var libraries: [names.len]*anyopaque = undefined;
    for (names, 0..) |name, index| libraries[index] = std.c.dlopen(name, .{ .NOW = true, .GLOBAL = true }) orelse return;
    var loaded: Api = undefined;
    inline for (comptime zio.fields(Api)) |field| {
        const symbol = comptime symbolOf(field.name);
        var found: ?*anyopaque = null;
        for (libraries) |library| {
            found = std.c.dlsym(library, symbol);
            if (found != null) break;
        }
        @field(loaded, field.name) = @ptrCast(@alignCast(found orelse return));
    }
    loaded.init(null, null);
    api = loaded;
}
/// The C name of an Api field: gst_ for GStreamer's, g_ for GLib's.
fn symbolOf(comptime field: []const u8) [:0]const u8 {
    @setEvalBranchQuota(20000);
    const glib = [_][]const u8{ "object_get_property", "object_set_property", "value_init", "value_unset", "value_dup_boxed", "value_set_string", "value_set_object", "value_set_double", "value_set_boolean", "error_free", "free" };
    inline for (glib) |name| if (comptime std.mem.eql(u8, name, field)) return "g_" ++ field;
    return "gst_" ++ field;
}

/// GStreamer and its base plugins are installed.
pub fn available() bool {
    once.call();
    return api != null;
}

const Ring = struct {
    planes: [2][]u8 = .{ &.{}, &.{} },
    width: u32 = 0,
    height: u32 = 0,
    matrix: drawing.VideoMatrix = .bt709,
};

pub const Engine = struct {
    pipe: Ptr,
    sink: Ptr,
    bus: Ptr,
    memfd: i32 = -1,
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),

    mutex: zio.Mutex = .{},
    /// The frames copied out of the samples: shown is the one `frame` last
    /// returned, latest the newest, which the next `frame` returns; the
    /// thread copies into neither.
    ring: [3]Ring = .{ .{}, .{}, .{} },
    shown: ?u2 = null,
    latest: ?u2 = null,
    changed: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    interval: u64 = 0,
    state: video.State = .loading,
    failure: ?anyerror = null,
    wake: ?video.Wake = null,
    want_play: bool = false,
    looping: bool = false,
    buffering: bool = false,
    /// A seek, and a rate, asked for before the pipeline could take them,
    /// once it prerolled.
    prerolled: bool = false,
    seek_to: u64 = 0,
    seek_set: bool = false,
    rate: f64 = 1,
    closed: bool = false,
    last_position: u64 = 0,
    duration_ns: u64 = 0,

    pub fn open(from: source.Source) !*Engine {
        if (!available()) return error.Unsupported;
        const gst = api.?;
        const self = try zio.heap.create(Engine);
        errdefer zio.heap.destroy(self);
        self.* = .{ .pipe = null, .sink = null, .bus = null };
        var uri_buffer: [64]u8 = undefined;
        var owned_uri: ?[:0]u8 = null;
        defer if (owned_uri) |text| zio.heap.free(text);
        const uri: [*:0]const u8 = switch (from) {
            .url => |text| blk: {
                owned_uri = try zio.heap.dupeSentinel(u8, text, 0);
                break :blk owned_uri.?.ptr;
            },
            .data => |bytes| blk: {
                self.memfd = try memoryFile(bytes);
                break :blk (std.fmt.bufPrintSentinel(&uri_buffer, "file:///proc/{d}/fd/{d}", .{ linux.getpid(), self.memfd }, 0) catch unreachable).ptr;
            },
        };
        errdefer self.free();
        self.pipe = gst.element_factory_make("playbin", null);
        self.sink = gst.element_factory_make("appsink", null);
        if (self.pipe == null or self.sink == null) return error.Unsupported;
        const caps = gst.caps_from_string("video/x-raw,format=NV12");
        gst.app_sink_set_caps(self.sink, caps);
        gst.mini_object_unref(caps);
        gst.app_sink_set_max_buffers(self.sink, 1);
        gst.app_sink_set_drop(self.sink, 1);
        setObject(self.pipe, "video-sink", self.sink);
        // The sound at another rate keeps its pitch.
        if (gst.element_factory_make("scaletempo", null)) |tempo| setObject(self.pipe, "audio-filter", tempo);
        var value: GValue = .{};
        _ = gst.value_init(&value, type_string);
        gst.value_set_string(&value, uri);
        gst.object_set_property(self.pipe, "uri", &value);
        gst.value_unset(&value);
        self.bus = gst.element_get_bus(self.pipe);
        _ = gst.element_set_state(self.pipe, state_paused);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn setObject(object: Ptr, name: [*:0]const u8, value_object: Ptr) void {
        const gst = api.?;
        var value: GValue = .{};
        _ = gst.value_init(&value, type_object);
        gst.value_set_object(&value, value_object);
        gst.object_set_property(object, name, &value);
        gst.value_unset(&value);
    }

    /// A file in memory holding the bytes, which the playbin reads as a
    /// file of /proc/self/fd, without one on disk.
    fn memoryFile(bytes: []const u8) !i32 {
        const result = linux.memfd_create("ziggurat-video", linux.MFD.CLOEXEC);
        if (linux.errno(result) != .SUCCESS) return error.Unsupported;
        const fd: i32 = @intCast(result);
        errdefer _ = linux.close(fd);
        var written: usize = 0;
        while (written < bytes.len) {
            const n = linux.write(fd, bytes[written..].ptr, bytes.len - written);
            switch (linux.errno(n)) {
                .SUCCESS => written += n,
                .INTR => {},
                else => return error.WriteFailed,
            }
        }
        return fd;
    }

    /// The engine's thread: the frames the appsink hands over as their
    /// times come and, while none comes, the frame the sink holds last,
    /// which a paused pipeline prerolled after loading or a seek, taken
    /// once each; then what the pipeline reports.
    fn run(self: *Engine) void {
        const gst = api.?;
        var last_buffer: Ptr = null;
        var last_pts: u64 = std.math.maxInt(u64);
        while (!self.quit.load(.acquire)) {
            var sample = gst.app_sink_try_pull_sample(self.sink, 20 * std.time.ns_per_ms);
            if (sample == null and gst.app_sink_is_eos(self.sink) != 0) {
                // Which returns at once: nothing comes until a seek.
                zio.sleep(20 * std.time.ns_per_ms);
            }
            if (sample == null) sample = lastSample(self.sink);
            if (sample) |taken| {
                if (gst.sample_get_buffer(taken)) |buffer| {
                    const pts = @as(*align(1) const u64, @ptrFromInt(@intFromPtr(buffer) + buffer_pts_offset)).*;
                    if (buffer != last_buffer or pts != last_pts) {
                        last_buffer = buffer;
                        last_pts = pts;
                        self.take(taken);
                    }
                }
                gst.mini_object_unref(taken);
            }
            const types = message_eos | message_error | message_buffering | message_duration_changed | message_async_done;
            while (gst.bus_timed_pop_filtered(self.bus, 0, types)) |message| {
                const kind = @as(*align(1) const u32, @ptrFromInt(@intFromPtr(message) + message_type_offset)).*;
                self.handle(message, kind);
                gst.mini_object_unref(message);
            }
        }
    }

    fn lastSample(sink: Ptr) Ptr {
        const gst = api.?;
        var value: GValue = .{};
        _ = gst.value_init(&value, gst.sample_get_type());
        gst.object_get_property(sink, "last-sample", &value);
        const sample = gst.value_dup_boxed(&value);
        gst.value_unset(&value);
        return sample;
    }

    fn read32(bytes: [*]const u8, at: usize) u32 {
        return std.mem.readInt(u32, bytes[at..][0..4], .little);
    }
    fn read64(bytes: [*]const u8, at: usize) u64 {
        return std.mem.readInt(u64, bytes[at..][0..8], .little);
    }

    /// Copy a sample's planes into a frame of the ring, which becomes the
    /// latest, and wake the player.
    fn take(self: *Engine, sample: *anyopaque) void {
        const gst = api.?;
        const buffer = gst.sample_get_buffer(sample) orelse return;
        const caps = gst.sample_get_caps(sample) orelse return;
        const info = gst.video_info_new() orelse return;
        defer gst.video_info_free(info);
        if (gst.video_info_from_caps(info, caps) == 0) return;
        const vi: [*]const u8 = @ptrCast(info);
        const width_signed: i32 = @bitCast(read32(vi, 16));
        const height_signed: i32 = @bitCast(read32(vi, 20));
        const range = read32(vi, 40);
        const matrix = read32(vi, 44);
        const fps_n: i32 = @bitCast(read32(vi, 64));
        const fps_d: i32 = @bitCast(read32(vi, 68));
        var offsets = [2]u64{ read64(vi, 72), read64(vi, 80) };
        var strides = [2]i32{ @bitCast(read32(vi, 104)), @bitCast(read32(vi, 108)) };
        if (gst.buffer_get_video_meta(buffer)) |meta| {
            const m: [*]const u8 = @ptrCast(meta);
            offsets = .{ read64(m, 48), read64(m, 56) };
            strides = .{ @bitCast(read32(m, 80)), @bitCast(read32(m, 84)) };
        }
        if (width_signed <= 0 or height_signed <= 0 or strides[0] <= 0 or strides[1] <= 0) return;
        const w: u32 = @intCast(width_signed);
        const h: u32 = @intCast(height_signed);
        const cw = (w + 1) / 2;
        const ch = (h + 1) / 2;
        var map: MapInfo = .{};
        if (gst.buffer_map(buffer, &map, map_read) == 0) return;
        defer gst.buffer_unmap(buffer, &map);
        const data = map.data orelse return;
        const s0: u64 = @intCast(strides[0]);
        const s1: u64 = @intCast(strides[1]);
        if (offsets[0] + s0 * (h - 1) + w > map.size or offsets[1] + s1 * (ch - 1) + 2 * cw > map.size) return;

        self.mutex.lock();
        var index: u2 = 0;
        while (index == self.shown or index == self.latest) index += 1;
        self.mutex.unlock();
        const ring = &self.ring[index];
        const rows = [2]u32{ h, ch };
        const row_bytes = [2]u32{ w, 2 * cw };
        for (0..2) |p| {
            const bytes = @as(usize, row_bytes[p]) * rows[p];
            if (ring.planes[p].len != bytes) {
                if (ring.planes[p].len != 0) zio.heap.free(ring.planes[p]);
                ring.planes[p] = zio.heap.alloc(u8, bytes) catch {
                    ring.planes[p] = &.{};
                    return;
                };
            }
            const stride: usize = @intCast(strides[p]);
            for (0..rows[p]) |y| @memcpy(ring.planes[p][y * row_bytes[p] ..][0..row_bytes[p]], data[offsets[p] + y * stride ..][0..row_bytes[p]]);
        }
        ring.width = w;
        ring.height = h;
        ring.matrix = matrixOf(matrix, h, range == 1);

        self.mutex.lock();
        self.latest = index;
        self.changed = true;
        self.width = w;
        self.height = h;
        if (fps_n > 0 and fps_d > 0) self.interval = @intCast(@divTrunc(@as(i64, std.time.ns_per_s) * fps_d, fps_n));
        if (self.state == .loading) self.state = .ready;
        const wake = self.wake;
        self.mutex.unlock();
        if (wake) |w_| w_.call(w_.context);
    }

    /// The YUV matrix of a GstVideoColorMatrix, or for an unknown one that
    /// of the video's size, as players guess it.
    fn matrixOf(matrix: u32, height: u32, full: bool) drawing.VideoMatrix {
        return switch (matrix) {
            3 => .of(1, full),
            4 => .of(0, full),
            6 => .of(2, full),
            else => .guess(height, full),
        };
    }

    fn handle(self: *Engine, message: *anyopaque, kind: u32) void {
        const gst = api.?;
        self.mutex.lock();
        switch (kind) {
            message_async_done => {
                // Prerolled, after loading or a seek: a seek the pipeline
                // did not take yet goes now.
                const first = !self.prerolled;
                self.prerolled = true;
                if (self.seek_set or (first and self.rate != 1)) self.seekLocked(self.seek_to);
            },
            message_eos => {
                if (self.looping) self.seekLocked(0) else self.state = .ended;
            },
            message_error => {
                var err: Ptr = null;
                var debug: ?[*:0]u8 = null;
                gst.message_parse_error(message, &err, &debug);
                if (err != null) gst.error_free(err);
                if (debug) |text| gst.free(text);
                self.state = .failed;
                self.failure = error.VideoFailed;
            },
            message_buffering => {
                var percent: c_int = 100;
                gst.message_parse_buffering(message, &percent);
                self.buffering = percent < 100;
                if (self.buffering and self.state == .ready) self.state = .buffering;
                if (!self.buffering and self.state == .buffering) self.state = .ready;
                self.applyState();
            },
            message_duration_changed => self.duration_ns = 0,
            else => {},
        }
        const wake = self.wake;
        self.mutex.unlock();
        if (wake) |w| w.call(w.context);
    }

    /// Play the pipeline when the player plays it, unless a stream fills
    /// its buffer; under the mutex.
    fn applyState(self: *Engine) void {
        if (self.closed) return;
        const gst = api.?;
        _ = gst.element_set_state(self.pipe, if (self.want_play and !self.buffering and self.state != .ended) state_playing else state_paused);
    }
    /// Seek the pipeline at the rate, or keep the time for once it
    /// prerolled; under the mutex.
    fn seekLocked(self: *Engine, at: u64) void {
        if (self.closed) return;
        self.seek_to = at;
        self.seek_set = true;
        self.last_position = at;
        if (!self.prerolled) return;
        const gst = api.?;
        if (gst.element_seek(self.pipe, self.rate, format_time, seek_flush | seek_accurate, seek_set, @intCast(@min(at, std.math.maxInt(i64))), seek_none, -1) != 0) self.seek_set = false;
    }

    fn free(self: *Engine) void {
        const gst = api.?;
        if (self.bus) |bus| gst.object_unref(bus);
        self.bus = null;
        if (self.pipe) |pipe| {
            gst.object_unref(pipe); // and the sink it took
        } else if (self.sink) |sink| gst.object_unref(sink);
        self.pipe = null;
        self.sink = null;
        if (self.memfd >= 0) _ = linux.close(self.memfd);
        self.memfd = -1;
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
        defer self.mutex.unlock();
        self.wake = wake;
    }
    fn frame(ptr: *anyopaque, _: u64) ?video.Frame {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        const latest = self.latest orelse return null;
        const changed = self.changed;
        self.shown = latest;
        self.changed = false;
        const ring = &self.ring[latest];
        return .{ .changed = changed, .picture = .{
            .width = ring.width,
            .height = ring.height,
            .format = .nv12,
            .matrix = ring.matrix,
            .planes = .{ ring.planes[0].ptr, ring.planes[1].ptr },
            .strides = .{ ring.width, 2 * ((ring.width + 1) / 2) },
        } };
    }
    /// The appsink wakes the player as each picture comes.
    fn intervalOf(_: *anyopaque) u64 {
        return 0;
    }
    fn stateOf(ptr: *anyopaque) video.State {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }
    fn failureOf(ptr: *anyopaque) ?anyerror {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure;
    }
    fn sizeOf(ptr: *anyopaque) [2]u32 {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ self.width, self.height };
    }
    fn durationOf(ptr: *anyopaque) u64 {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.duration_ns == 0 and !self.closed) {
            var value: i64 = 0;
            if (api.?.element_query_duration(self.pipe, format_time, &value) != 0 and value > 0) self.duration_ns = @intCast(value);
        }
        return self.duration_ns;
    }
    fn positionOf(ptr: *anyopaque) u64 {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return self.last_position;
        if (!self.prerolled and self.seek_set) return self.seek_to;
        var value: i64 = 0;
        if (api.?.element_query_position(self.pipe, format_time, &value) != 0 and value >= 0) self.last_position = @intCast(value);
        return self.last_position;
    }
    fn play(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.want_play = true;
        if (self.state == .ended) {
            self.state = .ready;
            self.seekLocked(0);
        }
        self.applyState();
    }
    fn pause(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.want_play = false;
        self.applyState();
    }
    fn seek(ptr: *anyopaque, at: u64) void {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state == .ended) self.state = .ready;
        self.seekLocked(at);
        self.applyState();
    }
    fn setLoop(ptr: *anyopaque, value: bool) void {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.looping = value;
    }
    fn setRate(ptr: *anyopaque, value: f64) void {
        const self = cast(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (value == self.rate) return;
        self.rate = value;
        if (self.prerolled) {
            var at: i64 = 0;
            _ = api.?.element_query_position(self.pipe, format_time, &at);
            self.seekLocked(@intCast(@max(at, 0)));
        }
    }
    fn setVolume(ptr: *anyopaque, value: f64) void {
        const self = cast(ptr);
        const gst = api.?;
        var g: GValue = .{};
        _ = gst.value_init(&g, type_double);
        gst.value_set_double(&g, value);
        gst.object_set_property(self.pipe, "volume", &g);
        gst.value_unset(&g);
    }
    fn setMuted(ptr: *anyopaque, value: bool) void {
        const self = cast(ptr);
        const gst = api.?;
        var g: GValue = .{};
        _ = gst.value_init(&g, type_boolean);
        gst.value_set_boolean(&g, @intFromBool(value));
        gst.object_set_property(self.pipe, "mute", &g);
        gst.value_unset(&g);
    }
    /// Stops the thread, then the pipeline, which may take a moment.
    fn close(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return;
        }
        self.closed = true;
        self.wake = null;
        self.mutex.unlock();
        self.quit.store(true, .release);
        if (self.thread) |thread| thread.join();
        _ = api.?.element_set_state(self.pipe, state_null);
        self.free();
        for (&self.ring) |*ring| for (ring.planes) |plane| if (plane.len != 0) zio.heap.free(plane);
        zio.heap.destroy(self);
    }
};
