//! Linux plays through PulseAudio's simple API, which PipeWire serves as
//! well, or else ALSA's default device. Both libraries load at run time, so
//! a program runs where neither is installed; both block while the device
//! holds enough, on the engine's output thread.
const std = @import("std");
const zio = @import("ziggurat_io");
const output = @import("output.zig");
const Detail = output.Detail;
const OpenError = output.OpenError;

const SampleSpec = extern struct { format: c_int, rate: u32, channels: u8 };
const BufferAttr = extern struct { maxlength: u32, tlength: u32, prebuf: u32, minreq: u32, fragsize: u32 };

const pa_stream_playback = 1;
const pa_sample_float32le = 5;
const snd_pcm_stream_playback = 0;
const snd_pcm_format_float_le = 14;
const snd_pcm_access_rw_interleaved = 3;

const Pulse = struct {
    pa_simple_new: *const fn (server: ?[*:0]const u8, name: [*:0]const u8, direction: c_int, device: ?[*:0]const u8, stream: [*:0]const u8, spec: *const SampleSpec, map: ?*const anyopaque, attributes: ?*const BufferAttr, err: *c_int) callconv(.c) ?*anyopaque,
    pa_simple_write: *const fn (simple: *anyopaque, data: *const anyopaque, bytes: usize, err: *c_int) callconv(.c) c_int,
    pa_simple_free: *const fn (simple: *anyopaque) callconv(.c) void,
    pa_strerror: *const fn (err: c_int) callconv(.c) ?[*:0]const u8,
};

const Alsa = struct {
    snd_pcm_open: *const fn (pcm: *?*anyopaque, name: [*:0]const u8, stream: c_int, mode: c_int) callconv(.c) c_int,
    snd_pcm_set_params: *const fn (pcm: *anyopaque, format: c_int, access: c_int, channels: c_uint, rate: c_uint, soft_resample: c_int, latency: c_uint) callconv(.c) c_int,
    snd_pcm_writei: *const fn (pcm: *anyopaque, buffer: *const anyopaque, frames: c_ulong) callconv(.c) c_long,
    snd_pcm_recover: *const fn (pcm: *anyopaque, err: c_int, silent: c_int) callconv(.c) c_int,
    snd_pcm_close: *const fn (pcm: *anyopaque) callconv(.c) c_int,
    snd_strerror: *const fn (err: c_int) callconv(.c) ?[*:0]const u8,
};

/// Libraries load once per process and stay loaded: unloading audio
/// libraries is not safe while any of their state may remain.
var load_mutex: zio.Mutex = .{};
var pulse_state: ?union(enum) { loaded: Pulse, missing } = null;
var alsa_state: ?union(enum) { loaded: Alsa, missing } = null;

/// Every field of `T` is the library's function of that name.
fn lookup(library: *std.DynLib, comptime T: type) ?T {
    var table: T = undefined;
    inline for (zio.fields(T)) |field| {
        @field(table, field.name) = library.lookup(field.type, field.name) orelse return null;
    }
    return table;
}

fn loadPulse() ?Pulse {
    load_mutex.lock();
    defer load_mutex.unlock();
    if (pulse_state == null) {
        pulse_state = .missing;
        var library = std.DynLib.open("libpulse-simple.so.0") catch return null;
        if (lookup(&library, Pulse)) |table| pulse_state = .{ .loaded = table } else library.close();
    }
    return switch (pulse_state.?) {
        .loaded => |table| table,
        .missing => null,
    };
}

fn loadAlsa() ?Alsa {
    load_mutex.lock();
    defer load_mutex.unlock();
    if (alsa_state == null) {
        alsa_state = .missing;
        var library = std.DynLib.open("libasound.so.2") catch return null;
        if (lookup(&library, Alsa)) |table| alsa_state = .{ .loaded = table } else library.close();
    }
    return switch (alsa_state.?) {
        .loaded => |table| table,
        .missing => null,
    };
}

pub const Storage = struct {
    pulse: ?*anyopaque = null,
    alsa: ?*anyopaque = null,
};

pub fn threadInit() void {}
pub fn threadDeinit() void {}

fn applicationName(buffer: *[128]u8) [*:0]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = zio.selfExePath(&path_buffer) catch "ziggurat";
    const name = std.fs.path.basename(path);
    const count = @min(name.len, buffer.len - 1);
    @memcpy(buffer[0..count], name[0..count]);
    buffer[count] = 0;
    return buffer[0..count :0];
}

fn text(message: ?[*:0]const u8) []const u8 {
    return if (message) |value| std.mem.span(value) else "unknown error";
}

pub fn open(storage: *Storage, ahead: u64, detail: *Detail) OpenError!output.Device {
    var name_buffer: [128]u8 = undefined;
    const name = applicationName(&name_buffer);
    var result: OpenError = error.BackendUnavailable;
    if (loadPulse()) |pulse| {
        const spec = SampleSpec{ .format = pa_sample_float32le, .rate = output.sample_rate, .channels = output.channels };
        // `ahead`, asking for more every 10 ms.
        const frame_bytes = output.channels * @sizeOf(f32);
        const attributes = BufferAttr{
            .maxlength = std.math.maxInt(u32),
            .tlength = @intCast(ahead * output.sample_rate / std.time.ns_per_s * frame_bytes),
            .prebuf = std.math.maxInt(u32),
            .minreq = output.period_frames * frame_bytes,
            .fragsize = std.math.maxInt(u32),
        };
        var code: c_int = 0;
        if (pulse.pa_simple_new(null, name, pa_stream_playback, null, name, &spec, null, &attributes, &code)) |simple| {
            storage.pulse = simple;
            return .{ .context = storage, .vtable = &pulse_vtable };
        }
        detail.set("PulseAudio: {s}", .{text(pulse.pa_strerror(code))});
    } else detail.set("PulseAudio: libpulse-simple.so.0 not loaded", .{});
    if (loadAlsa()) |alsa| {
        var pcm: ?*anyopaque = null;
        var code = alsa.snd_pcm_open(&pcm, "default", snd_pcm_stream_playback, 0);
        if (code >= 0) {
            code = alsa.snd_pcm_set_params(pcm.?, snd_pcm_format_float_le, snd_pcm_access_rw_interleaved, output.channels, output.sample_rate, 1, @intCast(ahead / std.time.ns_per_us));
            if (code >= 0) {
                storage.alsa = pcm;
                detail.len = 0;
                return .{ .context = storage, .vtable = &alsa_vtable };
            }
            _ = alsa.snd_pcm_close(pcm.?);
            result = error.DeviceFailed;
        } else {
            const errno: std.posix.E = @fromBackingInt(@intCast(zio.asUnsigned(-code)));
            result = switch (errno) {
                .NOENT, .NODEV, .NXIO => error.NoDevice,
                else => error.DeviceFailed,
            };
        }
        detail.append("; ALSA: {s}", .{text(alsa.snd_strerror(code))});
    } else detail.append("; ALSA: libasound.so.2 not loaded", .{});
    return result;
}

const pulse_vtable: output.Device.VTable = .{ .write = pulseWrite, .close = pulseClose };
const alsa_vtable: output.Device.VTable = .{ .write = alsaWrite, .close = alsaClose };

fn pulseWrite(context: *anyopaque, samples: []const f32) output.WriteError!void {
    const storage: *Storage = @ptrCast(@alignCast(context));
    const pulse = loadPulse().?;
    var code: c_int = 0;
    if (pulse.pa_simple_write(storage.pulse.?, samples.ptr, samples.len * @sizeOf(f32), &code) < 0) return error.DeviceLost;
}

fn pulseClose(context: *anyopaque) void {
    const storage: *Storage = @ptrCast(@alignCast(context));
    loadPulse().?.pa_simple_free(storage.pulse.?);
    storage.pulse = null;
}

fn alsaWrite(context: *anyopaque, samples: []const f32) output.WriteError!void {
    const storage: *Storage = @ptrCast(@alignCast(context));
    const alsa = loadAlsa().?;
    var rest = samples;
    while (rest.len > 0) {
        const written = alsa.snd_pcm_writei(storage.alsa.?, rest.ptr, rest.len / output.channels);
        if (written < 0) {
            // An underrun or a suspend, recovered from by preparing the
            // device again.
            if (alsa.snd_pcm_recover(storage.alsa.?, @intCast(written), 1) < 0) return error.DeviceLost;
            continue;
        }
        rest = rest[@as(usize, @intCast(written)) * output.channels ..];
    }
}

fn alsaClose(context: *anyopaque) void {
    const storage: *Storage = @ptrCast(@alignCast(context));
    _ = loadAlsa().?.snd_pcm_close(storage.alsa.?);
    storage.alsa = null;
}
