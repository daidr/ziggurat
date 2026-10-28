//! The SystemMediaTransportControls of a never-shown top-level window,
//! through ISystemMediaTransportControlsInterop as desktop apps get them: the
//! media controls of the volume flyout and the lock screen, which the media
//! keys drive. The controls call their handlers on threads of their own;
//! the handlers only post a message to the window, whose procedure delivers
//! the command on the owner thread. The window, the controls and the
//! handlers are made on first use and kept for the process.
const std = @import("std");
const now_playing = @import("now_playing.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const HRESULT = i32;
const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

fn guid(comptime text: []const u8) GUID {
    @setEvalBranchQuota(10_000);
    const hex = struct {
        fn parse(comptime T: type, comptime part: []const u8) T {
            return std.fmt.parseInt(T, part, 16) catch unreachable;
        }
    };
    var d: [8]u8 = undefined;
    d[0] = hex.parse(u8, text[19..21]);
    d[1] = hex.parse(u8, text[21..23]);
    for (0..6) |i| d[2 + i] = hex.parse(u8, text[24 + 2 * i ..][0..2]);
    return .{ .a = hex.parse(u32, text[0..8]), .b = hex.parse(u16, text[9..13]), .c = hex.parse(u16, text[14..18]), .d = d };
}

const iid_unknown = guid("00000000-0000-0000-c000-000000000046");
const iid_agile = guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
const iid_button_handler = guid("0557e996-7b23-5bae-aa81-ea0d671143a4");
const iid_position_handler = guid("44e34f15-bdc0-50a7-ace4-39e91fb753f1");
const iid_interop = guid("ddb0472d-c911-4a1f-86d9-dc3d71a95f5a");
const iid_controls = guid("99fa3ff4-1742-42a6-902e-087d41f965ec");
const iid_controls2 = guid("ea98d2f6-7f3c-4af2-a586-72889808efb1");
const iid_music2 = guid("00368462-97d3-44b9-b00f-008afcefaf18");
const iid_timeline = guid("5125316a-c3a2-475b-8507-93534dc88f15");
const iid_stream = guid("905a0fe1-bc53-11df-8c49-001e4fc686da");
const iid_stream_reference_statics = guid("857309dc-3fbf-4e7d-986f-ef3b1a07a964");

// Vtable indices (windows.media.h); IInspectable takes the first six.
const interop_get_for_window = 6;
const controls_put_playback_status = 7;
const controls_get_display_updater = 8;
const controls_put_is_enabled = 11;
const controls_put_is_play_enabled = 13;
const controls_put_is_stop_enabled = 15;
const controls_put_is_pause_enabled = 17;
const controls_put_is_previous_enabled = 25;
const controls_put_is_next_enabled = 27;
const controls_add_button_pressed = 32;
const controls2_put_playback_rate = 11;
const controls2_update_timeline = 12;
const controls2_add_position_change_requested = 13;
const updater_put_type = 7;
const updater_put_thumbnail = 11;
const updater_get_music_properties = 12;
const updater_clear_all = 16;
const updater_update = 17;
const music_put_title = 7;
const music_put_artist = 11;
const music2_put_album_title = 7;
const timeline_put_end_time = 9;
const timeline_put_max_seek_time = 13;
const timeline_put_position = 15;
const stream_reference_create_from_stream = 8;
const button_args_get_button = 6;
const position_args_get_requested = 6;

const status_closed = 0;
const status_stopped = 2;
const status_playing = 3;
const status_paused = 4;
const playback_type_music = 1;

const Object = *anyopaque;

fn method(object: Object, index: usize, comptime F: type) F {
    const vtable: *const [*]const *const anyopaque = @ptrCast(@alignCast(object));
    return @ptrCast(vtable.*[index]);
}

fn call(object: Object, index: usize, args: anytype) HRESULT {
    return @call(.auto, method(object, index, *const MethodType(@TypeOf(args))), .{object} ++ args);
}

/// `HRESULT (this, args...)`, as the Windows Runtime's methods are.
fn MethodType(comptime Args: type) type {
    const fields = std.meta.fields(Args);
    comptime var params: [fields.len + 1]std.builtin.Type.Fn.Param = undefined;
    params[0] = .{ .is_generic = false, .is_noalias = false, .type = Object };
    inline for (fields, 1..) |field, i| params[i] = .{ .is_generic = false, .is_noalias = false, .type = field.type };
    const final = params;
    return @Type(.{ .@"fn" = .{ .calling_convention = .winapi, .is_generic = false, .is_var_args = false, .return_type = HRESULT, .params = &final } });
}

fn release(object: ?Object) void {
    const value = object orelse return;
    _ = method(value, 2, *const fn (Object) callconv(.winapi) u32)(value);
}

fn queryInterface(object: Object, iid: *const GUID) ?Object {
    var out: ?Object = null;
    if (call(object, 0, .{ iid, &out }) < 0) return null;
    return out;
}

const Api = struct {
    get_activation_factory: *const fn (?*anyopaque, *const GUID, *?Object) callconv(.winapi) HRESULT,
    activate_instance: *const fn (?*anyopaque, *?Object) callconv(.winapi) HRESULT,
    create_string: *const fn ([*]const u16, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    delete_string: *const fn (?*anyopaque) callconv(.winapi) HRESULT,
    stream_over_stream: ?*const fn (Object, u32, *const GUID, *?Object) callconv(.winapi) HRESULT,
    mem_stream: ?*const fn ([*]const u8, u32) callconv(.winapi) ?Object,
};

const load_library_search_system32 = 0x800;
extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) c.HMODULE;
extern "kernel32" fn GetProcAddress(module: c.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

fn loadApi() ?Api {
    const combase = LoadLibraryExW(L("combase.dll"), null, load_library_search_system32) orelse return null;
    const shcore = LoadLibraryExW(L("shcore.dll"), null, load_library_search_system32);
    const shlwapi = LoadLibraryExW(L("shlwapi.dll"), null, load_library_search_system32);
    return .{
        .get_activation_factory = @ptrCast(GetProcAddress(combase, "RoGetActivationFactory") orelse return null),
        .activate_instance = @ptrCast(GetProcAddress(combase, "RoActivateInstance") orelse return null),
        .create_string = @ptrCast(GetProcAddress(combase, "WindowsCreateString") orelse return null),
        .delete_string = @ptrCast(GetProcAddress(combase, "WindowsDeleteString") orelse return null),
        .stream_over_stream = if (shcore) |module| @ptrCast(GetProcAddress(module, "CreateRandomAccessStreamOverStream")) else null,
        .mem_stream = if (shlwapi) |module| @ptrCast(GetProcAddress(module, "SHCreateMemStream")) else null,
    };
}

/// A temporary HSTRING; null for an empty or unconvertible text.
const HString = struct {
    handle: ?*anyopaque = null,

    fn init(winrt: *const Api, text: []const u8) HString {
        var wide: [now_playing.max_text_bytes + 1]u16 = undefined;
        const length = std.unicode.utf8ToUtf16Le(&wide, text) catch return .{};
        if (length == 0) return .{};
        var handle: ?*anyopaque = null;
        if (winrt.create_string(&wide, @intCast(length), &handle) < 0) return .{};
        return .{ .handle = handle };
    }

    fn deinit(self: HString, winrt: *const Api) void {
        if (self.handle) |handle| _ = winrt.delete_string(handle);
    }
};

fn activationFactory(winrt: *const Api, comptime class: []const u8, iid: *const GUID) ?Object {
    const name = HString.init(winrt, class);
    defer name.deinit(winrt);
    var factory: ?Object = null;
    if (winrt.get_activation_factory(name.handle, iid, &factory) < 0) return null;
    return factory;
}

fn activate(winrt: *const Api, comptime class: []const u8) ?Object {
    const name = HString.init(winrt, class);
    defer name.deinit(winrt);
    var object: ?Object = null;
    if (winrt.activate_instance(name.handle, &object) < 0) return null;
    return object;
}

// The handlers: static agile delegates that post to the window. Only
// IUnknown, IAgileObject and their delegate interface; a source asking for
// more, as IWeakReferenceSource, does not get them.

const Handler = extern struct {
    vtable: *const VTable,
    iid: *const GUID,

    const VTable = extern struct {
        query_interface: *const fn (*Handler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*Handler) callconv(.winapi) u32,
        release: *const fn (*Handler) callconv(.winapi) u32,
        invoke: *const fn (*Handler, ?Object, ?Object) callconv(.winapi) HRESULT,
    };

    fn queryInterface(self: *Handler, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        for ([_]*const GUID{ &iid_unknown, &iid_agile, self.iid }) |known| if (std.meta.eql(iid.*, known.*)) {
            out.* = self;
            return 0;
        };
        out.* = null;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    // Static: never freed.
    fn addRef(_: *Handler) callconv(.winapi) u32 {
        return 1;
    }
    fn releaseHandler(_: *Handler) callconv(.winapi) u32 {
        return 1;
    }

    fn buttonPressed(_: *Handler, _: ?Object, args: ?Object) callconv(.winapi) HRESULT {
        const value = args orelse return 0;
        var button: i32 = -1;
        if (call(value, button_args_get_button, .{&button}) < 0) return 0;
        const command: u32 = switch (button) {
            0 => 1, // play
            1 => 2, // pause
            2 => 8, // stop
            6 => 16, // next
            7 => 32, // previous
            else => return 0,
        };
        post(command, 0);
        return 0;
    }

    fn positionRequested(_: *Handler, _: ?Object, args: ?Object) callconv(.winapi) HRESULT {
        const value = args orelse return 0;
        var time: i64 = 0; // a TimeSpan, in 100 ns
        if (call(value, position_args_get_requested, .{&time}) < 0) return 0;
        post(64, @max(time, 0));
        return 0;
    }
};

const button_vtable: Handler.VTable = .{ .query_interface = Handler.queryInterface, .add_ref = Handler.addRef, .release = Handler.releaseHandler, .invoke = Handler.buttonPressed };
const position_vtable: Handler.VTable = .{ .query_interface = Handler.queryInterface, .add_ref = Handler.addRef, .release = Handler.releaseHandler, .invoke = Handler.positionRequested };
var button_handler: Handler = .{ .vtable = &button_vtable, .iid = &iid_button_handler };
var position_handler: Handler = .{ .vtable = &position_vtable, .iid = &iid_position_handler };

/// The window the handlers post to, from any thread.
var window: std.atomic.Value(usize) = .init(0);
var command_message: c.UINT = 0;

pub fn post(command: u32, time: i64) void {
    const hwnd = window.load(.acquire);
    if (hwnd == 0) return;
    _ = c.PostMessageW(@ptrFromInt(hwnd), command_message, command, @intCast(time));
}

fn procedure(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == command_message and command_message != 0) {
        now_playing.deliver(@intCast(wp), @as(u64, @intCast(@max(lp, 0))) * 100);
        return 0;
    }
    return c.DefWindowProcW(hwnd, message, wp, lp);
}

// The controls, owner thread only.
var tried = false;
var api: ?Api = null;
var controls: ?Object = null;
var controls2: ?Object = null;

fn ensureControls() ?Object {
    if (tried) return controls;
    tried = true;
    api = loadApi();
    const winrt = &(api orelse return null);
    command_message = c.RegisterWindowMessageW(L("Ziggurat.NowPlaying.Command"));
    if (command_message == 0) return null;
    var class = std.mem.zeroes(c.WNDCLASSEXW);
    class.cbSize = @sizeOf(c.WNDCLASSEXW);
    class.lpfnWndProc = procedure;
    class.hInstance = c.GetModuleHandleW(null);
    class.lpszClassName = L("ZigguratNowPlaying");
    if (c.RegisterClassExW(&class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) return null;
    // The controls belong to a top-level window; this one is never shown.
    const hwnd = c.CreateWindowExW(c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE, L("ZigguratNowPlaying"), L(""), c.WS_OVERLAPPED, 0, 0, 0, 0, null, null, c.GetModuleHandleW(null), null) orelse return null;
    // Commands reach the owner thread through this window even where the
    // session has no media controls (a service session, for one).
    window.store(@intFromPtr(hwnd), .release);
    const interop = activationFactory(winrt, "Windows.Media.SystemMediaTransportControls", &iid_interop) orelse return null;
    defer release(interop);
    var object: ?Object = null;
    if (call(interop, interop_get_for_window, .{ hwnd, &iid_controls, &object }) < 0) return null;
    const value = object orelse return null;
    var token: i64 = 0;
    _ = call(value, controls_add_button_pressed, .{ &button_handler, &token });
    if (queryInterface(value, &iid_controls2)) |second| {
        _ = call(second, controls2_add_position_change_requested, .{ &position_handler, &token });
        controls2 = second;
    }
    controls = value;
    return value;
}

pub fn set(info: ?*const now_playing.NativeInfo) void {
    const value = ensureControls() orelse return;
    const winrt = &api.?;
    var updater: ?Object = null;
    _ = call(value, controls_get_display_updater, .{&updater});
    defer release(updater);
    const shown = info orelse {
        if (updater) |display| {
            _ = call(display, updater_clear_all, .{});
            _ = call(display, updater_update, .{});
        }
        _ = call(value, controls_put_playback_status, .{@as(i32, status_closed)});
        _ = call(value, controls_put_is_enabled, .{@as(u8, 0)});
        return;
    };
    _ = call(value, controls_put_is_enabled, .{@as(u8, 1)});
    const status: i32 = switch (shown.state) {
        .playing => status_playing,
        .paused => status_paused,
        .stopped => status_stopped,
    };
    _ = call(value, controls_put_playback_status, .{status});
    const enables = [_]struct { usize, u32 }{
        .{ controls_put_is_play_enabled, 1 },  .{ controls_put_is_pause_enabled, 2 },     .{ controls_put_is_stop_enabled, 8 },
        .{ controls_put_is_next_enabled, 16 }, .{ controls_put_is_previous_enabled, 32 },
    };
    for (enables) |entry| _ = call(value, entry[0], .{@as(u8, @intFromBool(shown.commands & entry[1] != 0))});
    if (updater) |display| {
        _ = call(display, updater_put_type, .{@as(i32, playback_type_music)});
        var music: ?Object = null;
        if (call(display, updater_get_music_properties, .{&music}) >= 0) if (music) |properties| {
            defer release(properties);
            const title = HString.init(winrt, shown.title);
            defer title.deinit(winrt);
            _ = call(properties, music_put_title, .{title.handle});
            const artist = HString.init(winrt, shown.artist);
            defer artist.deinit(winrt);
            _ = call(properties, music_put_artist, .{artist.handle});
            if (queryInterface(properties, &iid_music2)) |second| {
                defer release(second);
                const album = HString.init(winrt, shown.album);
                defer album.deinit(winrt);
                _ = call(second, music2_put_album_title, .{album.handle});
            }
        };
        const thumb = thumbnail(winrt, shown.artwork);
        defer release(thumb);
        _ = call(display, updater_put_thumbnail, .{thumb});
        _ = call(display, updater_update, .{});
    }
    if (controls2) |second| {
        if (activate(winrt, "Windows.Media.SystemMediaTransportControlsTimelineProperties")) |inspectable| {
            defer release(inspectable);
            if (queryInterface(inspectable, &iid_timeline)) |timeline| {
                defer release(timeline);
                // TimeSpans, in 100 ns, from a start of 0.
                const end: i64 = @intCast(shown.duration_ns / 100);
                _ = call(timeline, timeline_put_end_time, .{end});
                if (shown.commands & 64 != 0) _ = call(timeline, timeline_put_max_seek_time, .{end});
                _ = call(timeline, timeline_put_position, .{@as(i64, @intCast(shown.position_ns / 100))});
                _ = call(second, controls2_update_timeline, .{timeline});
            }
        }
        _ = call(second, controls2_put_playback_rate, .{shown.rate});
    }
}

/// A RandomAccessStreamReference of an image, or null.
fn thumbnail(winrt: *const Api, image: []const u8) ?Object {
    if (image.len == 0) return null;
    const mem_stream = winrt.mem_stream orelse return null;
    const over = winrt.stream_over_stream orelse return null;
    const stream = mem_stream(image.ptr, @intCast(image.len)) orelse return null;
    defer release(stream);
    var random: ?Object = null;
    if (over(stream, 0, &iid_stream, &random) < 0) return null;
    const random_stream = random orelse return null;
    defer release(random_stream);
    const statics = activationFactory(winrt, "Windows.Storage.Streams.RandomAccessStreamReference", &iid_stream_reference_statics) orelse return null;
    defer release(statics);
    var reference: ?Object = null;
    if (call(statics, stream_reference_create_from_stream, .{ random_stream, &reference }) < 0) return null;
    return reference;
}
