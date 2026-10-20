//! Windows plays through WASAPI in shared mode on the default output,
//! opened again when the default changes or the device goes. Every call
//! runs on the engine's output thread, in COM's multithreaded apartment.
const std = @import("std");
const output = @import("output.zig");
const Detail = output.Detail;
const OpenError = output.OpenError;

const GUID = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };
const HRESULT = i32;
const HANDLE = *anyopaque;

const clsid_device_enumerator = GUID{ .data1 = 0xbcde0395, .data2 = 0xe52f, .data3 = 0x467c, .data4 = .{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e } };
const iid_device_enumerator = GUID{ .data1 = 0xa95664d2, .data2 = 0x9614, .data3 = 0x4f35, .data4 = .{ 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6 } };
const iid_audio_client = GUID{ .data1 = 0x1cb9ad4c, .data2 = 0xdbfa, .data3 = 0x4c32, .data4 = .{ 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2 } };
const iid_render_client = GUID{ .data1 = 0xf294acfc, .data2 = 0x3146, .data3 = 0x4483, .data4 = .{ 0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2 } };
const subtype_float = GUID{ .data1 = 0x00000003, .data2 = 0x0000, .data3 = 0x0010, .data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

const WaveFormatExtensible = extern struct {
    format_tag: u16 align(1),
    channels: u16 align(1),
    samples_per_second: u32 align(1),
    bytes_per_second: u32 align(1),
    block_align: u16 align(1),
    bits_per_sample: u16 align(1),
    size: u16 align(1),
    valid_bits: u16 align(1),
    channel_mask: u32 align(1),
    sub_format: GUID align(1),
};

const clsctx_all = 0x17;
const e_render = 0;
const e_console = 0;
const e_notfound: u32 = 0x80070490;
const share_mode_shared = 0;
const stream_flags_event_callback = 0x00040000;
const stream_flags_no_persist = 0x00080000;
const stream_flags_src_default_quality = 0x08000000;
const stream_flags_auto_convert = 0x80000000;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, context: u32, iid: *const GUID, object: *?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: i32, initial_state: i32, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) i32;

/// Method `index` of COM interface `object`, IUnknown's three first.
fn method(object: *anyopaque, comptime index: usize, comptime Function: type) Function {
    const table: *const [*]const *const anyopaque = @ptrCast(@alignCast(object));
    return @ptrCast(table.*[index]);
}

fn release(object: ?*anyopaque) void {
    const value = object orelse return;
    _ = method(value, 2, *const fn (*anyopaque) callconv(.winapi) u32)(value);
}

fn failed(result: HRESULT) bool {
    return result < 0;
}

threadlocal var com_initialized = false;

pub fn threadInit() void {
    // S_FALSE, already initialized on this thread, succeeds as well.
    com_initialized = !failed(CoInitializeEx(null, 0));
}

pub fn threadDeinit() void {
    if (com_initialized) CoUninitialize();
    com_initialized = false;
}

pub const Storage = struct {
    enumerator: ?*anyopaque = null,
    client: ?*anyopaque = null,
    render: ?*anyopaque = null,
    event: ?HANDLE = null,
    frames: u32 = 0,
    id: [256]u16 = undefined,
    id_len: usize = 0,
    checked: i128 = 0,
};

const IdResult = union(enum) { id: []const u16, missing, failed: HRESULT };

/// The default output's id, copied into `buffer`.
fn defaultId(enumerator: *anyopaque, buffer: *[256]u16) IdResult {
    var device: ?*anyopaque = null;
    const get_default = method(enumerator, 4, *const fn (*anyopaque, i32, i32, *?*anyopaque) callconv(.winapi) HRESULT);
    const result = get_default(enumerator, e_render, e_console, &device);
    if (failed(result)) return if (@as(u32, @bitCast(result)) == e_notfound) .missing else .{ .failed = result };
    defer release(device);
    var text: ?[*:0]u16 = null;
    const get_id = method(device.?, 5, *const fn (*anyopaque, *?[*:0]u16) callconv(.winapi) HRESULT);
    const id_result = get_id(device.?, &text);
    if (failed(id_result)) return .{ .failed = id_result };
    defer CoTaskMemFree(text);
    const value = std.mem.span(text.?);
    const count = @min(value.len, buffer.len);
    @memcpy(buffer[0..count], value[0..count]);
    return .{ .id = buffer[0..count] };
}

fn fail(storage: *Storage, detail: *Detail, err: OpenError, call: []const u8, result: HRESULT) OpenError {
    closeStorage(storage);
    detail.set("WASAPI: {s} failed (HRESULT 0x{x:0>8})", .{ call, @as(u32, @bitCast(result)) });
    return err;
}

pub fn open(storage: *Storage, detail: *Detail) OpenError!output.Device {
    storage.* = .{};
    var result = CoCreateInstance(&clsid_device_enumerator, null, clsctx_all, &iid_device_enumerator, &storage.enumerator);
    if (failed(result)) return fail(storage, detail, error.BackendUnavailable, "CoCreateInstance(MMDeviceEnumerator)", result);
    const enumerator = storage.enumerator.?;
    switch (defaultId(enumerator, &storage.id)) {
        .id => |id| storage.id_len = id.len,
        .missing => {
            closeStorage(storage);
            detail.set("WASAPI: no audio output", .{});
            return error.NoDevice;
        },
        .failed => |code| return fail(storage, detail, error.DeviceFailed, "GetDefaultAudioEndpoint", code),
    }
    var device: ?*anyopaque = null;
    const get_default = method(enumerator, 4, *const fn (*anyopaque, i32, i32, *?*anyopaque) callconv(.winapi) HRESULT);
    result = get_default(enumerator, e_render, e_console, &device);
    if (failed(result)) return fail(storage, detail, if (@as(u32, @bitCast(result)) == e_notfound) error.NoDevice else error.DeviceFailed, "GetDefaultAudioEndpoint", result);
    defer release(device);
    const activate = method(device.?, 3, *const fn (*anyopaque, *const GUID, u32, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
    result = activate(device.?, &iid_audio_client, clsctx_all, null, &storage.client);
    if (failed(result)) return fail(storage, detail, error.DeviceFailed, "IMMDevice.Activate", result);
    const client = storage.client.?;
    const format = WaveFormatExtensible{
        .format_tag = 0xfffe,
        .channels = output.channels,
        .samples_per_second = output.sample_rate,
        .bytes_per_second = output.sample_rate * output.channels * 4,
        .block_align = output.channels * 4,
        .bits_per_sample = 32,
        .size = 22,
        .valid_bits = 32,
        .channel_mask = 0x1 | 0x2,
        .sub_format = subtype_float,
    };
    // 40 ms, converted to the device's own format by WASAPI's resampler.
    const duration: i64 = 40 * 10_000;
    const flags: u32 = stream_flags_event_callback | stream_flags_no_persist | stream_flags_auto_convert | stream_flags_src_default_quality;
    const initialize = method(client, 3, *const fn (*anyopaque, i32, u32, i64, i64, *const WaveFormatExtensible, ?*const GUID) callconv(.winapi) HRESULT);
    result = initialize(client, share_mode_shared, flags, duration, 0, &format, null);
    if (failed(result)) return fail(storage, detail, error.DeviceFailed, "IAudioClient.Initialize", result);
    const get_buffer_size = method(client, 4, *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT);
    result = get_buffer_size(client, &storage.frames);
    if (failed(result)) return fail(storage, detail, error.DeviceFailed, "IAudioClient.GetBufferSize", result);
    const get_service = method(client, 14, *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT);
    result = get_service(client, &iid_render_client, &storage.render);
    if (failed(result)) return fail(storage, detail, error.DeviceFailed, "IAudioClient.GetService", result);
    storage.event = CreateEventW(null, 0, 0, null) orelse return fail(storage, detail, error.DeviceFailed, "CreateEvent", 0);
    const set_event = method(client, 13, *const fn (*anyopaque, HANDLE) callconv(.winapi) HRESULT);
    result = set_event(client, storage.event.?);
    if (failed(result)) return fail(storage, detail, error.DeviceFailed, "IAudioClient.SetEventHandle", result);
    const start = method(client, 10, *const fn (*anyopaque) callconv(.winapi) HRESULT);
    result = start(client);
    if (failed(result)) return fail(storage, detail, error.DeviceFailed, "IAudioClient.Start", result);
    storage.checked = std.time.nanoTimestamp();
    return .{ .context = storage, .vtable = &vtable };
}

const vtable: output.Device.VTable = .{ .write = write, .close = close };

fn write(context: *anyopaque, samples: []const f32) output.WriteError!void {
    const storage: *Storage = @ptrCast(@alignCast(context));
    const client = storage.client.?;
    const frames: u32 = @intCast(samples.len / output.channels);
    const deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    const get_padding = method(client, 6, *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT);
    while (true) {
        var padding: u32 = 0;
        if (failed(get_padding(client, &padding))) return error.DeviceLost;
        if (padding <= storage.frames and storage.frames - padding >= frames) break;
        if (std.time.nanoTimestamp() > deadline) return error.Unresponsive;
        _ = WaitForSingleObject(storage.event.?, 100);
    }
    const render = storage.render.?;
    var data: ?[*]f32 = null;
    const get_buffer = method(render, 3, *const fn (*anyopaque, u32, *?[*]f32) callconv(.winapi) HRESULT);
    if (failed(get_buffer(render, frames, &data))) return error.DeviceLost;
    @memcpy(data.?[0..samples.len], samples);
    const release_buffer = method(render, 4, *const fn (*anyopaque, u32, u32) callconv(.winapi) HRESULT);
    if (failed(release_buffer(render, frames, 0))) return error.DeviceLost;
    // The default output changing (headphones plugged in, a choice in
    // Settings) moves a shared stream nowhere: open the new one.
    const now = std.time.nanoTimestamp();
    if (now - storage.checked > 500 * std.time.ns_per_ms) {
        storage.checked = now;
        var buffer: [256]u16 = undefined;
        switch (defaultId(storage.enumerator.?, &buffer)) {
            .id => |id| if (!std.mem.eql(u16, id, storage.id[0..storage.id_len])) return error.DefaultChanged,
            else => return error.DefaultChanged,
        }
    }
}

fn close(context: *anyopaque) void {
    closeStorage(@ptrCast(@alignCast(context)));
}

fn closeStorage(storage: *Storage) void {
    if (storage.client) |client| _ = method(client, 11, *const fn (*anyopaque) callconv(.winapi) HRESULT)(client);
    release(storage.render);
    release(storage.client);
    release(storage.enumerator);
    if (storage.event) |event| _ = CloseHandle(event);
    storage.* = .{};
}
