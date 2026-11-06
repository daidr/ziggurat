//! The browser backend: WebAssembly in a page. Each window is an element
//! filling the page's element with the ID "ziggurat", or else the page,
//! holding the canvas its frames are shown on and a textarea out of sight
//! that has the keyboard while the window has: input methods compose in it,
//! at the content's caret, and its clipboard events carry the clipboard.
//! Windows opened later cover the earlier ones. The page sets a window's
//! size: sizes, positions and title bar options do nothing, and the title of
//! the window opened last is the page's.
//!
//! `ziggurat.js` (web/ziggurat.js) loads the module and owns the page's
//! side. The browser's event loop is the app's: `run` hands the main thread
//! to it by unwinding the WebAssembly stack without returning (the frames of
//! `main` and the App stay where they are), and the page then calls the
//! exported functions below for each event, each frame and each posted
//! task, as the desktop backends' native loops do.
//!
//! Events reach the content on the same wire the other backends use; the
//! script sends the browser's events already translated: pointer positions
//! in CSS pixels (DIPs), frames in device pixels at the device pixel ratio,
//! and Command as Control on a Mac.
const std = @import("std");
const zio = @import("ziggurat_io");
const core = @import("../root.zig");

pub const AppData = struct { started: bool = false };
pub const WindowData = struct { id: u32 = 0 };

extern "ziggurat" fn zw_app_init(app: *anyopaque) c_int;
extern "ziggurat" fn zw_app_run() void;
extern "ziggurat" fn zw_app_wake() void;
extern "ziggurat" fn zw_app_quit() void;
extern "ziggurat" fn zw_window_create(record: *anyopaque, title: [*]const u8, title_len: usize, flags: u32) u32;
extern "ziggurat" fn zw_window_destroy(id: u32) void;
extern "ziggurat" fn zw_window_action(id: u32, action: u32) void;
extern "ziggurat" fn zw_window_state(id: u32) u32;
extern "ziggurat" fn zw_window_size(id: u32, out: *[3]f64) void;
extern "ziggurat" fn zw_window_bounds(id: u32, out: *[4]f64) void;
extern "ziggurat" fn zw_window_title(id: u32, title: [*]const u8, len: usize) void;
extern "ziggurat" fn zw_window_invalidate(id: u32) void;
extern "ziggurat" fn zw_window_caret(id: u32, x: f64, y: f64, width: f64, height: f64) void;
extern "ziggurat" fn zw_window_cancel_composition(id: u32) void;
extern "ziggurat" fn zw_window_text_mode(id: u32, keyboard: u32) void;
extern "ziggurat" fn zw_window_cursor(id: u32, name: [*]const u8, len: usize) void;
extern "ziggurat" fn zw_window_fullscreen(id: u32, enabled: u32) void;
extern "ziggurat" fn zw_window_background(id: u32, rgba: u32) void;
extern "ziggurat" fn zw_window_capture(id: u32, out: *[3]u32) ?[*]u8;

/// The event wire, filled by the script in place: `event_buffer` is where
/// it writes an event before calling `ziggurat_window_event`.
pub const NativeEvent = extern struct {
    kind: i32 = 0,
    key: i32 = 0,
    flags: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    reserved0: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,
    dx: f64 = 0,
    dy: f64 = 0,
    scale: f64 = 1,
    text: u32 = 0,
    length: u32 = 0,
    selection: u32 = 0,
    reserved: u32 = 0,
};
comptime {
    if (@sizeOf(NativeEvent) != 80 or @offsetOf(NativeEvent, "x") != 24 or @offsetOf(NativeEvent, "text") != 64) @compileError("web event wire ABI mismatch");
}

var app_pointer: ?*core.App = null;
var event_buffer: NativeEvent = .{};
/// Bytes the script hands over (event text, clipboard text, file bytes):
/// it asks for room with `ziggurat_scratch`, writes there and points the
/// event at it.
var scratch: []u8 = &.{};

export fn ziggurat_event_buffer() *NativeEvent {
    return &event_buffer;
}
export fn ziggurat_scratch(length: usize) ?[*]u8 {
    if (scratch.len < length) {
        const grown = zio.heap.alloc(u8, @max(length, 2 * scratch.len, 4096)) catch return null;
        if (scratch.len != 0) zio.heap.free(scratch);
        scratch = grown;
    }
    return scratch.ptr;
}
export fn ziggurat_alloc(length: usize) ?[*]u8 {
    const memory = zio.heap.alloc(u8, @max(length, 1)) catch return null;
    return memory.ptr;
}
export fn ziggurat_free(ptr: [*]u8, length: usize) void {
    zio.heap.free(ptr[0..@max(length, 1)]);
}
/// Runs the App's posted tasks and safe-point work; the script calls it after
/// `zw_app_wake`, in a task of its own.
export fn ziggurat_dispatch() void {
    const app = app_pointer orelse return;
    app.dispatch() catch |err| std.log.err("window destruction: {s}", .{@errorName(err)});
}
/// The page asks the app to quit, as a tab closing: the windows may refuse.
export fn ziggurat_request_quit() void {
    const app = app_pointer orelse return;
    _ = app.requestQuit();
}
export fn ziggurat_window_event(ptr: *anyopaque) i32 {
    return event(@ptrCast(@alignCast(ptr)), &event_buffer);
}

pub fn init(app: *core.App) !void {
    if (app.icon_policy == .required) return error.UnsupportedCapability;
    if (app_pointer != null) return error.AppAlreadyExists;
    return switch (zw_app_init(app)) {
        0 => app_pointer = app,
        1 => error.AppAlreadyExists,
        else => error.DisplayUnavailable,
    };
}
pub fn deinit(app: *core.App) void {
    if (app_pointer == app) app_pointer = null;
}
/// Hands the main thread to the browser: the script unwinds the stack back
/// to the page and never returns here. `main`'s frames, and so the App and
/// everything it owns, stay valid while the page runs the app.
pub fn run(app: *core.App) !void {
    app.native.started = true;
    zw_app_run();
    unreachable;
}
pub fn wake(_: *core.App) void {
    zw_app_wake();
}
pub fn quit(_: *core.App) void {
    zw_app_quit();
}

pub fn create(record: *core.WindowRecord, options: core.WindowOptions) !void {
    if (options.accessibility_host == .children) return error.UnsupportedCapability;
    if (options.popup != null) return error.UnsupportedCapability;
    const flags: u32 = @as(u32, @intFromBool(options.transparent)) | @as(u32, @intFromBool(options.focus_on_show)) << 2;
    const id = zw_window_create(record, options.title.ptr, options.title.len, flags);
    if (id == 0) return error.OutOfMemory;
    record.native.id = id;
    if (options.text_input_mode != .system) {
        zw_window_text_mode(id, 1);
        record.publishTextInputMode(options.text_input_mode);
    }
}
pub fn show(record: *core.WindowRecord) void {
    zw_window_action(record.native.id, 0);
}
pub fn perform(record: *core.WindowRecord, action: core.WindowAction) !void {
    zw_window_action(record.native.id, @backingInt(action));
}
pub fn state(record: *core.WindowRecord) core.WindowState {
    const flags = zw_window_state(record.native.id);
    return .{ .visible = flags & 1 != 0, .minimized = flags & 2 != 0, .maximized = false, .focused = flags & 8 != 0, .enabled = flags & 16 != 0, .fullscreen = flags & 32 != 0, .fullscreen_requested = flags & 64 != 0 };
}
/// The page places and sizes windows: none of the desktop's window
/// operations stand for anything but full screen, which browsers allow
/// while the user acts.
pub fn capabilities(_: *core.WindowRecord) core.WindowCapabilities {
    return .{ .client_position = false, .fullscreen = true, .always_on_top = false, .owned_windows = true, .modal_windows = true };
}
pub fn isActive(record: *core.WindowRecord) bool {
    return state(record).focused;
}
pub fn setVibrancy(_: *core.WindowRecord, _: core.Vibrancy) void {}
pub fn setActiveAppearance(_: *core.WindowRecord, _: bool) void {}
pub fn setTraits(_: *core.WindowRecord, _: core.WindowTraits) !void {}
pub fn setOpacity(_: *core.WindowRecord, _: f32) !void {
    return error.UnsupportedCapability;
}
pub fn setIgnorePointer(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedCapability;
}
pub fn setContentProtection(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedCapability;
}
pub fn flashFrame(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedCapability;
}
pub fn setSkipTaskbar(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedCapability;
}
pub fn setBackdrop(_: *core.WindowRecord, _: core.WindowBackdrop) !void {
    return error.UnsupportedCapability;
}
pub fn setBackground(record: *core.WindowRecord, color: ?u32) void {
    zw_window_background(record.native.id, if (color) |rgb| rgb << 8 | 0xff else 0);
}
pub fn startMove(_: *core.WindowRecord) !void {
    return error.UnsupportedCapability;
}
pub fn startResize(_: *core.WindowRecord, _: core.ResizeEdge) !void {
    return error.UnsupportedCapability;
}
pub fn showSystemMenu(_: *core.WindowRecord) !void {
    return error.UnsupportedCapability;
}
/// The window's element in the page, in CSS pixels.
pub fn clientBounds(record: *core.WindowRecord) !core.ClientBounds {
    var bounds: [4]f64 = undefined;
    zw_window_bounds(record.native.id, &bounds);
    return .{ .position = .{ .x = @intFromFloat(@round(bounds[0])), .y = @intFromFloat(@round(bounds[1])) }, .width = @intFromFloat(@max(0, @round(bounds[2]))), .height = @intFromFloat(@max(0, @round(bounds[3]))) };
}
/// The canvas's size in device pixels, at the device pixel ratio.
pub fn contentSize(record: *core.WindowRecord) !core.Size {
    var size: [3]f64 = undefined;
    zw_window_size(record.native.id, &size);
    return .{ .width = @intFromFloat(size[0]), .height = @intFromFloat(size[1]), .scale = @floatCast(size[2]) };
}
pub fn setClientBounds(_: *core.WindowRecord, _: core.ClientBounds) !void {}
pub fn setFullscreen(record: *core.WindowRecord, enabled: bool) !void {
    zw_window_fullscreen(record.native.id, @intFromBool(enabled));
}
pub fn setAlwaysOnTop(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedCapability;
}
pub fn setTitle(record: *core.WindowRecord, title: []const u8) !void {
    zw_window_title(record.native.id, title.ptr, title.len);
}
pub fn resize(_: *core.WindowRecord, _: u32, _: u32) !void {}
/// Moves the textarea out of sight to the caret, where input methods show
/// what they compose and their candidates.
pub fn setTextCaret(record: *core.WindowRecord, rect: core.Rect) !void {
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height)) return error.InvalidGeometry;
    zw_window_caret(record.native.id, rect.x, rect.y, @max(1, rect.width), @max(1, rect.height));
}
pub fn cancelTextComposition(record: *core.WindowRecord) !void {
    zw_window_cancel_composition(record.native.id);
}
pub fn cancelTextForMode(record: *core.WindowRecord) !bool {
    zw_window_cancel_composition(record.native.id);
    return record.phase == .open;
}
/// Keyboard/compose mode: keys type the characters the layout gives them,
/// without an input method.
pub fn setTextInputMode(record: *core.WindowRecord, mode: core.TextInputMode) !core.TextInputModeResult {
    zw_window_text_mode(record.native.id, @intFromBool(mode == .keyboard_compose));
    record.publishTextInputMode(mode);
    return .applied;
}
/// Asks for a browser frame, which draws the whole canvas: the renderer's
/// damage tracking redraws only what changed within it.
pub fn invalidate(record: *core.WindowRecord) void {
    zw_window_invalidate(record.native.id);
}
pub fn invalidateRect(record: *core.WindowRecord, bounds: core.Rect) !void {
    if (!(bounds.width > 0 and bounds.height > 0)) return;
    zw_window_invalidate(record.native.id);
}
/// Removes the window's element; the script reports it destroyed in a task
/// of its own, as native windows report it after their destruction.
/// The page drops the window's element at once, so the window is
/// destroyed before this returns, as a destroyed GTK widget is.
pub fn destroy(record: *core.WindowRecord) !void {
    zw_window_destroy(record.native.id);
    record.native.id = 0;
    record.nativeDestroying();
    record.nativeDestroyed();
}
pub fn handle(record: *core.WindowRecord) ?*anyopaque {
    return if (record.native.id == 0) null else @ptrFromInt(record.native.id);
}
pub fn pointerOperation(_: *const core.WindowRecord) u64 {
    return std.math.maxInt(u64);
}
pub fn advancePointerOperation(_: *core.WindowRecord) u64 {
    return std.math.maxInt(u64);
}
/// The canvas's pixels, read back as premultiplied BGRA.
pub fn capture(record: *core.WindowRecord, allocator: std.mem.Allocator) !core.Capture {
    var size: [3]u32 = undefined;
    const source = zw_window_capture(record.native.id, &size) orelse return error.CaptureFailed;
    const width = size[0];
    const height = size[1];
    const length = @as(usize, width) * height * 4;
    defer ziggurat_free(source, length);
    if (width == 0 or height == 0) return error.CaptureFailed;
    const pixels = try allocator.alloc(u8, length);
    var index: usize = 0;
    while (index < length) : (index += 4) {
        // Straight RGBA to premultiplied BGRA.
        const at = source[index..][0..4];
        const alpha: u32 = at[3];
        pixels[index..][0..4].* = .{ premultiply(at[2], alpha), premultiply(at[1], alpha), premultiply(at[0], alpha), at[3] };
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}
fn premultiply(value: u8, alpha: u32) u8 {
    return @intCast((@as(u32, value) * alpha + 127) / 255);
}
/// Browsers show no application menus.
pub fn activateMenuItem(_: *core.WindowRecord, _: []const []const u8) !void {
    return error.NoMenu;
}
pub fn setCursor(record: *core.WindowRecord, cursor: core.Cursor) void {
    const name: []const u8 = switch (cursor) {
        .default => "default",
        .pointer => "pointer",
        .text => "text",
        .move => "move",
        .resize_ew => "ew-resize",
        .resize_ns => "ns-resize",
        .resize_nwse => "nwse-resize",
        .resize_nesw => "nesw-resize",
        .not_allowed => "not-allowed",
        .crosshair => "crosshair",
        .grab => "grab",
        .grabbing => "grabbing",
        .resize_n => "n-resize",
        .resize_e => "e-resize",
        .resize_s => "s-resize",
        .resize_w => "w-resize",
        .resize_column => "col-resize",
        .resize_row => "row-resize",
        .vertical_text => "vertical-text",
        .copy => "copy",
        .alias => "alias",
        .context_menu => "context-menu",
        .none => "none",
        .progress => "progress",
        .wait => "wait",
        .help => "help",
        .cell => "cell",
        .zoom_in => "zoom-in",
        .zoom_out => "zoom-out",
        .all_scroll => "all-scroll",
        .no_drop => "no-drop",
    };
    zw_window_cursor(record.native.id, name.ptr, name.len);
}

/// Event kinds on the wire: 1 paint, 2 resize, 3/4 pointer down/up, 5 move,
/// 6 wheel, 7 focus, 8 cancel, 9 edit key, 10 close request, 11 destroyed,
/// 12 text, 13 preedit, 14 preedit cancel, 15 tab/activate, 16 state,
/// 17 input gate, 18 key down, 19 hit test, 22 moved, 26 key release and
/// 27 command enabled.
fn event(record: *core.WindowRecord, native: *const NativeEvent) i32 {
    const scope = record.enterNative();
    defer scope.end();
    const point: core.Point = .{ .x = @floatCast(native.x), .y = @floatCast(native.y) };
    const modifiers: core.KeyModifiers = .{ .shift = native.flags & 1 != 0, .control = native.flags & 2 != 0, .alt = native.flags & 4 != 0, .super = native.flags & 8 != 0 };
    const text: []const u8 = if (native.length == 0) "" else @as([*]const u8, @ptrFromInt(native.text))[0..native.length];
    switch (native.kind) {
        1 => record.emit(.{ .paint = .{ .native_context = @ptrFromInt(record.native.id), .native_window = @ptrFromInt(record.native.id), .size = .{ .width = native.width, .height = native.height, .scale = @floatCast(native.scale) }, .transparent = native.flags & 1 != 0 } }),
        2 => record.emit(.{ .resize = .{ .width = native.width, .height = native.height, .scale = @floatCast(native.scale) } }),
        22 => record.emit(.window_position),
        // `key` is the button: 0 primary, 1 secondary, 2 middle, 3 back,
        // 4 forward.
        3, 4 => {
            if (native.key < 0 or native.key > 4) return 0;
            const input: core.PointerButtonInput = .{ .position = point, .modifiers = modifiers, .button = @fromBackingInt(@intCast(zio.asUnsigned(native.key))) };
            record.notePointerWire(native.width, native.dx, if (native.kind == 3) .down else .up, input.button);
            if (native.kind == 3) record.emit(.{ .pointer_down = input }) else record.emit(.{ .pointer_up = input });
        },
        5 => {
            record.notePointerWire(native.width, native.dx, null, .primary);
            record.emit(.{ .pointer_move = point });
        },
        6 => record.emit(.{ .wheel = .{ .position = point, .delta = .{ .x = @floatCast(native.dx), .y = @floatCast(native.dy) } } }),
        7 => record.emit(.{ .focus = native.flags & 1 != 0 }),
        8 => record.emit(.cancel_input),
        9 => {
            if (native.key < 0 or native.key > @backingInt(core.EditKeyCode.y)) return 0;
            record.emit(.{ .edit_key = .{ .key = @fromBackingInt(@intCast(zio.asUnsigned(native.key))), .shift = native.flags & 1 != 0, .control = native.flags & 2 != 0 } });
        },
        10 => _ = record.window.requestCloseFrom(.user) catch |err| {
            record.window.report(.{ .domain = .core, .operation = .window_destroy, .err = err });
        },
        12 => record.emit(.{ .text_input = .{ .text = text, .producer = .browser_text_input } }),
        13 => record.emit(.{ .text_preedit = .{ .text = text, .selection_start = native.selection, .selection_end = native.selection } }),
        14 => record.emit(.text_preedit_cancel),
        15 => record.emit(.{ .key = if (native.key == 0) .tab else .activate }),
        16 => record.emitState(),
        17 => return @intFromBool(record.inputAllowed()),
        18 => {
            const key = domKey(text);
            return @intFromBool(record.keyInput(.{ .key = key.key, .modifiers = modifiers, .repeat = native.flags & 16 != 0, .physical = key.physical, .code = key.code }));
        },
        26 => {
            const key = domKey(text);
            record.keyRelease(.{ .key = key.key, .modifiers = modifiers, .physical = key.physical, .code = key.code });
        },
        27 => {
            if (native.key < 0 or native.key > @backingInt(core.EditCommand.select_all)) return 0;
            return @intFromBool(record.commandEnabled(@fromBackingInt(@intCast(zio.asUnsigned(native.key)))));
        },
        else => return 0,
    }
    return 0;
}
/// A key event's text is the browser's `key` and `code`, separated by a
/// zero byte.
fn domKey(text: []const u8) struct { key: core.KeyCode, physical: core.KeyCode, code: core.KeyPosition } {
    const split = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    const code = if (split < text.len) text[split + 1 ..] else "";
    return .{ .key = core.physical_keys.fromDomKey(text[0..split], code), .physical = core.physical_keys.fromDomCode(code), .code = core.key_codes.fromDom(code) };
}
