//! The AppKit backend. macos.m owns the NSApplication, windows and views and
//! sends events on the wire the GTK backend uses; the kinds it sends are a
//! subset: 1 paint, 2 resize, 3/4 pointer down/up, 5 move, 6 wheel, 7 focus,
//! 8 cancel, 9 edit key, 10 close request, 11 destroyed, 12 text, 13 preedit,
//! 14 preedit cancel, 15 tab/activate, 16 state, 17 input gate, 18 key down,
//! 19 hit test, 22 moved, 25 popup dismissed and 26 key release.
const std = @import("std");
const zio = @import("ziggurat_io");
const core = @import("../root.zig");
pub const AppData = struct { native: ?*anyopaque = null };
pub const WindowData = struct { native: ?*anyopaque = null };
const NativeEvent = extern struct {
    kind: c_int,
    key: c_int,
    flags: c_int,
    context: ?*anyopaque,
    window: ?*anyopaque,
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
    width: u32,
    height: u32,
    scale: u32,
    text: ?[*]const u8,
    length: usize,
    selection: usize,
};
const NativeBounds = extern struct { x: i32, y: i32, width: u32, height: u32, positioned: c_int };
extern fn zlm_app_create(*anyopaque, *const fn (*anyopaque) callconv(.c) void, *c_int) ?*anyopaque;
extern fn zlm_app_run(*anyopaque) void;
extern fn zlm_app_quit(*anyopaque) void;
extern fn zlm_app_wake(*anyopaque) void;
extern fn zlm_app_destroy(*anyopaque) void;
extern fn zlm_window_create(*anyopaque, *const fn (*anyopaque, *const NativeEvent) callconv(.c) c_int, [*:0]const u8, u32, u32, u32, u32, ?*anyopaque, c_int, c_int, c_int, c_int, *c_int) ?*anyopaque;
extern fn zlm_window_interaction(*anyopaque, c_int) c_int;
extern fn zlm_window_destroy(*anyopaque) c_int;
extern fn zlm_window_handle(*anyopaque) ?*anyopaque;
extern fn zlm_window_action(*anyopaque, c_int) void;
extern fn zlm_window_state(*anyopaque) u32;
extern fn zlm_window_capabilities(*anyopaque) u32;
extern fn zlm_window_bounds(*anyopaque, *NativeBounds) void;
extern fn zlm_window_size(*anyopaque, *u32, *u32, *u32) void;
extern fn zlm_window_set_bounds(*anyopaque, *const NativeBounds) c_int;
extern fn zlm_window_fullscreen(*anyopaque, c_int) c_int;
extern fn zlm_window_topmost(*anyopaque, c_int) c_int;
extern fn zlm_window_title(*anyopaque, [*:0]const u8) void;
extern fn zlm_window_resize(*anyopaque, u32, u32) void;
extern fn zlm_window_invalidate(*anyopaque) void;
extern fn zlm_window_invalidate_rect(*anyopaque, c_int, c_int, c_int, c_int) void;
extern fn zlm_window_caret(*anyopaque, c_int, c_int, c_int, c_int) void;
extern fn zlm_window_cancel_composition(*anyopaque) void;
extern fn zlm_window_text_mode(*anyopaque, c_int) void;
extern fn zlm_window_cursor(*anyopaque, c_int) void;
extern fn zlm_window_traits(*anyopaque, c_int, c_int, c_int, c_int, c_int) c_int;
extern fn zlm_window_opacity(*anyopaque, f32) void;
extern fn zlm_window_ignore_pointer(*anyopaque, c_int) void;
extern fn zlm_window_content_protection(*anyopaque, c_int) void;
extern fn zlm_window_attention(*anyopaque, c_int) void;
extern fn zlm_window_capture(*anyopaque, *c_int, *c_int, *c_int, *?[*]const u8) ?*anyopaque;
extern fn zlm_capture_free(*anyopaque) void;

pub fn init(app: *core.App) !void {
    if (app.icon_policy == .required) return error.UnsupportedCapability;
    var code: c_int = 0;
    app.native.native = zlm_app_create(app, dispatch, &code) orelse return switch (code) {
        1 => error.AppAlreadyExists,
        2 => error.DisplayUnavailable,
        else => error.OutOfMemory,
    };
}
pub fn deinit(app: *core.App) void {
    zlm_app_destroy(app.native.native.?);
    app.native.native = null;
}
pub fn run(app: *core.App) !void {
    zlm_app_run(app.native.native.?);
}
pub fn wake(app: *core.App) void {
    zlm_app_wake(app.native.native.?);
}
pub fn quit(app: *core.App) void {
    zlm_app_quit(app.native.native.?);
}
fn dispatch(ptr: *anyopaque) callconv(.c) void {
    const app: *core.App = @ptrCast(@alignCast(ptr));
    app.dispatch() catch |err| std.log.err("window destruction: {s}", .{@errorName(err)});
}
pub fn create(record: *core.WindowRecord, options: core.WindowOptions) !void {
    if (options.accessibility_host == .children) return error.UnsupportedCapability;
    const allocator = record.window.app.allocator;
    const title = try allocator.dupeSentinel(u8, options.title, 0);
    defer allocator.free(title);
    var code: c_int = 0;
    const popup: c_int = if (options.popup) |role| 1 | @as(c_int, if (role.focusable) 2 else 0) | @as(c_int, if (role.topmost) 4 else 0) else 0;
    record.native.native = zlm_window_create(record, event, title, options.width, options.height, options.min_width, options.min_height, if (record.owner_record) |owner| owner.native.native else null, @intFromBool(options.modal), @backingInt(options.decoration), @intFromBool(options.resizable), popup, &code) orelse return if (code == 1) error.UnsupportedCapability else error.OutOfMemory;
    if (options.text_input_mode != .system) {
        zlm_window_text_mode(record.native.native.?, 1);
        record.publishTextInputMode(options.text_input_mode);
    }
}
pub fn show(record: *core.WindowRecord) void {
    zlm_window_action(record.native.native.?, 0);
}
pub fn perform(record: *core.WindowRecord, action: core.WindowAction) !void {
    zlm_window_action(record.native.native.?, @backingInt(action));
}
pub fn state(record: *core.WindowRecord) core.WindowState {
    const flags = zlm_window_state(record.native.native.?);
    return .{ .visible = flags & 1 != 0, .minimized = flags & 2 != 0, .maximized = flags & 4 != 0, .focused = flags & 8 != 0, .enabled = flags & 16 != 0, .fullscreen = flags & 32 != 0, .fullscreen_requested = flags & 64 != 0, .always_on_top = flags & 128 != 0, .always_on_top_requested = flags & 256 != 0 };
}
pub fn capabilities(record: *core.WindowRecord) core.WindowCapabilities {
    const flags = zlm_window_capabilities(record.native.native.?);
    return .{ .client_position = flags & 1 != 0, .fullscreen = flags & 2 != 0, .always_on_top = flags & 4 != 0, .owned_windows = true, .modal_windows = true, .custom_decoration = flags & 8 != 0, .native_move_resize = flags & 16 != 0, .system_menu = flags & 32 != 0, .opacity = flags & 64 != 0, .ignore_pointer = flags & 128 != 0, .attention = flags & 256 != 0, .skip_taskbar = flags & 512 != 0, .window_buttons = flags & 1024 != 0, .content_protection = flags & 2048 != 0 };
}
pub fn setTraits(record: *core.WindowRecord, traits: core.WindowTraits) !void {
    try checkUpdate(zlm_window_traits(record.native.native.?, @intFromBool(traits.resizable), @intFromBool(traits.movable), @intFromBool(traits.minimizable), @intFromBool(traits.maximizable), @intFromBool(traits.closable)));
}
pub fn setOpacity(record: *core.WindowRecord, value: f32) !void {
    zlm_window_opacity(record.native.native.?, value);
}
pub fn setIgnorePointer(record: *core.WindowRecord, enabled: bool) !void {
    zlm_window_ignore_pointer(record.native.native.?, @intFromBool(enabled));
}
pub fn setContentProtection(record: *core.WindowRecord, enabled: bool) !void {
    zlm_window_content_protection(record.native.native.?, @intFromBool(enabled));
}
pub fn flashFrame(record: *core.WindowRecord, enabled: bool) !void {
    zlm_window_attention(record.native.native.?, @intFromBool(enabled));
}
/// macOS lists apps, not windows, in the Dock.
pub fn setSkipTaskbar(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedCapability;
}
pub fn setBackdrop(_: *core.WindowRecord, _: core.WindowBackdrop) !void {
    return error.UnsupportedCapability;
}
pub fn startMove(record: *core.WindowRecord) !void {
    try checkUpdate(zlm_window_interaction(record.native.native.?, -1));
}
pub fn startResize(record: *core.WindowRecord, edge: core.ResizeEdge) !void {
    try checkUpdate(zlm_window_interaction(record.native.native.?, @backingInt(edge)));
}
pub fn showSystemMenu(record: *core.WindowRecord) !void {
    try checkUpdate(zlm_window_interaction(record.native.native.?, 8));
}
pub fn isActive(record: *core.WindowRecord) bool {
    return state(record).focused;
}
pub fn clientBounds(record: *core.WindowRecord) !core.ClientBounds {
    var bounds: NativeBounds = undefined;
    zlm_window_bounds(record.native.native.?, &bounds);
    return .{ .position = if (bounds.positioned != 0) .{ .x = bounds.x, .y = bounds.y } else null, .width = bounds.width, .height = bounds.height };
}
pub fn contentSize(record: *core.WindowRecord) !core.Size {
    var width: u32 = 0;
    var height: u32 = 0;
    var scale: u32 = 1;
    zlm_window_size(record.native.native.?, &width, &height, &scale);
    return .{ .width = width, .height = height, .scale = @floatFromInt(scale) };
}
fn checkUpdate(result: c_int) !void {
    return switch (result) {
        0 => {},
        1 => error.UnsupportedCapability,
        2 => error.Closed,
        3 => error.Busy,
        4 => error.InvalidGesture,
        else => error.WindowUpdateFailed,
    };
}
pub fn setClientBounds(record: *core.WindowRecord, bounds: core.ClientBounds) !void {
    const native: NativeBounds = .{ .x = if (bounds.position) |p| p.x else 0, .y = if (bounds.position) |p| p.y else 0, .width = bounds.width, .height = bounds.height, .positioned = @intFromBool(bounds.position != null) };
    try checkUpdate(zlm_window_set_bounds(record.native.native.?, &native));
}
pub fn setFullscreen(record: *core.WindowRecord, enabled: bool) !void {
    try checkUpdate(zlm_window_fullscreen(record.native.native.?, @intFromBool(enabled)));
}
pub fn setAlwaysOnTop(record: *core.WindowRecord, enabled: bool) !void {
    try checkUpdate(zlm_window_topmost(record.native.native.?, @intFromBool(enabled)));
}
pub fn setTitle(record: *core.WindowRecord, title: []const u8) !void {
    const allocator = record.window.app.allocator;
    const terminated = try allocator.dupeSentinel(u8, title, 0);
    defer allocator.free(terminated);
    zlm_window_title(record.native.native.?, terminated);
}
pub fn resize(record: *core.WindowRecord, width: u32, height: u32) !void {
    zlm_window_resize(record.native.native.?, width, height);
}
pub fn setTextCaret(record: *core.WindowRecord, rect: core.Rect) !void {
    const limit: f32 = @floatFromInt(@divTrunc(std.math.maxInt(c_int), 2));
    if (@abs(rect.x) > limit or @abs(rect.y) > limit or rect.width > limit or rect.height > limit) return error.InvalidGeometry;
    zlm_window_caret(record.native.native.?, @intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(@max(1, rect.width)), @intFromFloat(@max(1, rect.height)));
}
pub fn cancelTextComposition(record: *core.WindowRecord) !void {
    zlm_window_cancel_composition(record.native.native.?);
}
pub fn cancelTextForMode(record: *core.WindowRecord) !bool {
    zlm_window_cancel_composition(record.native.native.?);
    return record.phase == .open;
}
/// Keyboard/compose mode bypasses the input method: keys insert the
/// characters the layout gives them, dead keys included.
pub fn setTextInputMode(record: *core.WindowRecord, mode: core.TextInputMode) !core.TextInputModeResult {
    zlm_window_text_mode(record.native.native.?, @intFromBool(mode == .keyboard_compose));
    record.publishTextInputMode(mode);
    return .applied;
}
pub fn invalidate(record: *core.WindowRecord) void {
    zlm_window_invalidate(record.native.native.?);
}
pub fn invalidateRect(record: *core.WindowRecord, bounds: core.Rect) !void {
    const left = @floor(@max(0, bounds.x));
    const top = @floor(@max(0, bounds.y));
    const right = @ceil(@as(f64, bounds.x) + bounds.width);
    const bottom = @ceil(@as(f64, bounds.y) + bounds.height);
    if (right <= left or bottom <= top) return;
    zlm_window_invalidate_rect(record.native.native.?, @intFromFloat(left), @intFromFloat(top), @intFromFloat(right), @intFromFloat(bottom));
}
pub fn destroy(record: *core.WindowRecord) !void {
    if (zlm_window_destroy(record.native.native.?) == 0) return error.DestroyWindowFailed;
}
pub fn handle(record: *core.WindowRecord) ?*anyopaque {
    return zlm_window_handle(record.native.native.?);
}
pub fn pointerOperation(_: *const core.WindowRecord) u64 {
    return std.math.maxInt(u64);
}
pub fn advancePointerOperation(_: *core.WindowRecord) u64 {
    return std.math.maxInt(u64);
}
pub fn capture(record: *core.WindowRecord, allocator: std.mem.Allocator) !core.Capture {
    var width: c_int = 0;
    var height: c_int = 0;
    var stride: c_int = 0;
    var source: ?[*]const u8 = null;
    const image = zlm_window_capture(record.native.native orelse return error.Closed, &width, &height, &stride, &source) orelse return error.CaptureFailed;
    defer zlm_capture_free(image);
    if (width <= 0 or height <= 0 or stride < width * 4) return error.CaptureFailed;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels = try allocator.alloc(u8, w * h * 4);
    for (0..h) |row| {
        const line = source.?[row * @as(usize, @intCast(stride)) ..];
        for (0..w) |column| {
            const at = line[column * 4 ..][0..4];
            // Premultiplied RGBA to premultiplied BGRA.
            pixels[(row * w + column) * 4 ..][0..4].* = .{ at[2], at[1], at[0], at[3] };
        }
    }
    return .{ .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
}
/// The application menu comes with the macOS menu bar; until then there
/// is none to choose from.
pub fn activateMenuItem(_: *core.WindowRecord, _: []const []const u8) !void {
    return error.NoMenu;
}
pub fn setCursor(record: *core.WindowRecord, cursor: core.Cursor) void {
    zlm_window_cursor(record.native.native orelse return, @backingInt(cursor));
}
fn event(ptr: *anyopaque, native: *const NativeEvent) callconv(.c) c_int {
    const record: *core.WindowRecord = @ptrCast(@alignCast(ptr));
    const scope = record.enterNative();
    defer scope.end();
    const point: core.Point = .{ .x = @floatCast(native.x), .y = @floatCast(native.y) };
    const modifiers: core.KeyModifiers = .{ .shift = native.flags & 1 != 0, .control = native.flags & 2 != 0, .alt = native.flags & 4 != 0, .super = native.flags & 8 != 0 };
    switch (native.kind) {
        1 => record.emit(.{ .paint = .{ .native_context = native.context.?, .native_window = native.window, .size = .{ .width = native.width, .height = native.height, .scale = @floatFromInt(native.scale) } } }),
        2 => record.emit(.{ .resize = .{ .width = native.width, .height = native.height, .scale = @floatFromInt(native.scale) } }),
        22 => record.emit(.window_position),
        25 => record.popupDismissed(),
        3 => record.emit(.{ .pointer_down = .{ .position = point, .modifiers = modifiers } }),
        4 => record.emit(.{ .pointer_up = .{ .position = point, .modifiers = modifiers } }),
        5 => record.emit(.{ .pointer_move = point }),
        6 => record.emit(.{ .wheel = .{ .position = point, .delta = .{ .x = @floatCast(native.dx), .y = @floatCast(native.dy) } } }),
        7 => record.emit(.{ .focus = native.flags & 1 != 0 }),
        8 => record.emit(.cancel_input),
        9 => record.emit(.{ .edit_key = .{ .key = @fromBackingInt(@intCast(zio.asUnsigned(native.key))), .shift = native.flags & 1 != 0, .control = native.flags & 2 != 0 } }),
        10 => _ = record.window.requestCloseFrom(.user) catch |err| {
            record.window.report(.{ .domain = .core, .operation = .window_destroy, .err = err });
        },
        11 => {
            record.native.native = null;
            record.nativeDestroying();
            record.nativeDestroyed();
        },
        12 => record.emit(.{ .text_input = .{ .text = native.text.?[0..native.length], .producer = .appkit_text_input } }),
        13 => record.emit(.{ .text_preedit = .{ .text = native.text.?[0..native.length], .selection_start = native.selection, .selection_end = native.selection } }),
        14 => record.emit(.text_preedit_cancel),
        15 => record.emit(.{ .key = if (native.key == 0) .tab else .activate }),
        16 => record.emitState(),
        17 => return @intFromBool(record.inputAllowed()),
        18 => return @intFromBool(record.keyInput(.{ .key = keyCode(@intCast(native.key), native.width), .modifiers = modifiers, .repeat = native.flags & 16 != 0, .physical = core.physical_keys.fromMacVirtualKey(native.width) })),
        26 => record.keyRelease(.{ .key = keyCode(@intCast(native.key), native.width), .modifiers = modifiers, .physical = core.physical_keys.fromMacVirtualKey(native.width) }),
        19 => return @backingInt(record.hitTest(point, @floatFromInt(native.width), @floatFromInt(native.height))),
        else => unreachable,
    }
    return 0;
}
/// The layout's character names letter, digit and punctuation keys, as the
/// GTK keyval does; every other key is named by its position.
fn keyCode(character: u32, virtual: u32) core.KeyCode {
    if (character >= 'a' and character <= 'z') return @fromBackingInt(@intCast(@backingInt(core.KeyCode.a) + character - 'a'));
    if (character >= '0' and character <= '9' and !isKeypad(virtual)) return @fromBackingInt(@intCast(@backingInt(core.KeyCode.digit0) + character - '0'));
    return switch (character) {
        '-' => if (isKeypad(virtual)) .subtract else .minus,
        '=' => .equal,
        '[' => .left_bracket,
        ']' => .right_bracket,
        '\\' => .backslash,
        ';' => .semicolon,
        '\'' => .apostrophe,
        '`' => .grave,
        ',' => .comma,
        '.' => if (isKeypad(virtual)) .decimal else .period,
        '/' => if (isKeypad(virtual)) .divide else .slash,
        else => core.physical_keys.fromMacVirtualKey(virtual),
    };
}
fn isKeypad(virtual: u32) bool {
    return switch (virtual) {
        0x41, 0x43, 0x45, 0x47, 0x4b, 0x4c, 0x4e, 0x51...0x59, 0x5b, 0x5c => true,
        else => false,
    };
}

test "the layout names character keys and position names the rest" {
    try std.testing.expectEqual(core.KeyCode.z, keyCode('z', 0x10));
    try std.testing.expectEqual(core.KeyCode.digit1, keyCode('1', 0x12));
    try std.testing.expectEqual(core.KeyCode.numpad1, keyCode('1', 0x53));
    try std.testing.expectEqual(core.KeyCode.escape, keyCode(0x1b, 0x35));
    try std.testing.expectEqual(core.KeyCode.left, keyCode(0, 0x7b));
}
