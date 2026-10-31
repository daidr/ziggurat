const std = @import("std");
const core = @import("../root.zig");
const pointer_press = @import("pointer_press.zig");
pub const AppData = struct { fail_text_cancel: bool = false, emit_text_cancel: bool = false, fail_create: bool = false, fail_destroy: bool = false, fail_update: bool = false, fail_fullscreen_after_event: bool = false, fail_show: bool = false, destroy_countdown: ?usize = null, quit_requests: usize = 0 };
pub const WindowData = struct {
    pointer_operation: pointer_press.Operation = .{},
    alive: bool = false,
    state: core.WindowState = .{ .visible = false, .minimized = false, .maximized = false, .focused = false, .enabled = true },
    bounds: core.ClientBounds = .{ .position = .{ .x = 0, .y = 0 }, .width = 720, .height = 480 },
    saved_bounds: core.ClientBounds = undefined,
    saved_state: core.WindowState = undefined,
    gesture_active: bool = false,
    gesture_used: bool = false,
    interactions: usize = 0,
    last_resize: ?core.ResizeEdge = null,
    damage: ?core.Rect = null,
    backdrop: core.WindowBackdrop = .system,
    fail_damage: bool = false,
    composing: bool = false,
    composition_epoch: u64 = 0,
    caps: core.WindowCapabilities = .{ .client_position = true, .fullscreen = true, .always_on_top = true, .owned_windows = true, .modal_windows = true, .custom_decoration = true, .native_move_resize = true, .system_menu = true, .opacity = true, .ignore_pointer = true, .content_protection = true, .attention = true, .skip_taskbar = true, .window_buttons = true },
    traits: core.WindowTraits = .{},
    opacity: f32 = 1,
    ignore_pointer: bool = false,
    content_protected: bool = false,
    flashing: bool = false,
    skip_taskbar: bool = false,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    pub fn shownTitle(self: *const WindowData) []const u8 {
        return self.title[0..self.title_len];
    }
};
pub fn pointerOperation(record: *const core.WindowRecord) u64 {
    return record.native.pointer_operation.value;
}
pub fn advancePointerOperation(record: *core.WindowRecord) u64 {
    return record.native.pointer_operation.advance();
}
pub fn startMove(record: *core.WindowRecord) !void {
    if (!record.native.gesture_active or record.native.gesture_used) return error.InvalidGesture;
    try update(record);
    record.native.gesture_used = true;
    record.native.interactions += 1;
}
pub fn startResize(record: *core.WindowRecord, edge: core.ResizeEdge) !void {
    try startMove(record);
    record.native.last_resize = edge;
}
pub fn showSystemMenu(record: *core.WindowRecord) !void {
    try update(record);
    record.native.interactions += 1;
}
pub fn init(_: *core.App) !void {}
pub fn deinit(_: *core.App) void {}
pub fn create(record: *core.WindowRecord, options: core.WindowOptions) !void {
    if (record.window.app.native.fail_create) {
        record.window.app.native.fail_create = false;
        return error.CreateWindowFailed;
    }
    record.native.alive = true;
    record.native.bounds.width = options.width;
    record.native.bounds.height = options.height;
    record.native.traits.resizable = options.resizable;
    try setTitle(record, options.title);
    if (options.text_input_mode != .system) record.publishTextInputMode(options.text_input_mode);
}
pub fn run(app: *core.App) !void {
    while (app.phase == .running) {
        try app.dispatch();
        if (app.phase == .running and !app.queue.pending() and app.pending_head == null) return error.NoTestEvents;
    }
}
pub fn wake(_: *core.App) void {}
pub fn quit(app: *core.App) void {
    app.native.quit_requests += 1;
}
pub fn show(_: *core.WindowRecord) void {}
pub fn perform(record: *core.WindowRecord, action: core.WindowAction) !void {
    if (action == .show and record.window.app.native.fail_show) {
        record.window.app.native.fail_show = false;
        record.window.app.captureNativeFailure(.win32, 87);
        return error.WindowUpdateFailed;
    }
    switch (action) {
        .show => record.native.state.visible = true,
        .hide => record.native.state.visible = false,
        .minimize => {
            record.native.state.minimized = true;
            record.native.state.maximized = false;
        },
        .maximize => {
            record.native.state.maximized = true;
            record.native.state.minimized = false;
        },
        .restore => {
            record.native.state.minimized = false;
            record.native.state.maximized = false;
        },
        .focus => {
            var cursor = record.window.app.first;
            while (cursor) |window| : (cursor = window.next) window.native.state.focused = false;
            record.native.state.focused = true;
        },
        .enable => record.native.state.enabled = true,
        .disable => record.native.state.enabled = false,
    }
}
pub fn isActive(record: *core.WindowRecord) bool {
    return record.native.state.focused;
}
pub fn state(record: *core.WindowRecord) core.WindowState {
    return record.native.state;
}
pub fn capabilities(record: *core.WindowRecord) core.WindowCapabilities {
    return record.native.caps;
}
pub fn clientBounds(record: *core.WindowRecord) !core.ClientBounds {
    var result = record.native.bounds;
    if (!record.native.caps.client_position) result.position = null;
    return result;
}
/// An opaque white client area of the window's size; the test backend
/// draws nothing.
pub fn capture(record: *core.WindowRecord, allocator: std.mem.Allocator) !core.Capture {
    const width = record.native.bounds.width;
    const height = record.native.bounds.height;
    const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
    @memset(pixels, 0xff);
    return .{ .width = width, .height = height, .pixels = pixels };
}
pub fn activateMenuItem(_: *core.WindowRecord, _: []const []const u8) !void {
    return error.NoMenu;
}
pub fn contentSize(record: *core.WindowRecord) !core.Size {
    return .{ .width = record.native.bounds.width, .height = record.native.bounds.height, .scale = 1 };
}
fn update(record: *core.WindowRecord) !void {
    if (record.window.app.native.fail_update) {
        record.window.app.native.fail_update = false;
        record.window.app.captureNativeFailure(.win32, 5);
        return error.WindowUpdateFailed;
    }
}
pub fn setClientBounds(record: *core.WindowRecord, bounds: core.ClientBounds) !void {
    if (bounds.position != null and !record.native.caps.client_position) return error.UnsupportedCapability;
    try update(record);
    if (bounds.position) |position| record.native.bounds.position = position;
    record.native.bounds.width = bounds.width;
    record.native.bounds.height = bounds.height;
    record.emit(.{ .resize = .{ .width = bounds.width, .height = bounds.height, .scale = 1 } });
}
pub fn setFullscreen(record: *core.WindowRecord, enabled: bool) !void {
    if (enabled and !record.native.caps.fullscreen) return error.UnsupportedCapability;
    if (record.native.state.fullscreen == enabled) return;
    try update(record);
    const previous_bounds = record.native.bounds;
    const previous_state = record.native.state;
    if (enabled) {
        record.native.saved_bounds = record.native.bounds;
        record.native.saved_state = record.native.state;
        record.native.bounds = .{ .position = .{ .x = 0, .y = 0 }, .width = 1920, .height = 1080 };
        record.native.state.minimized = false;
        record.native.state.maximized = false;
    } else {
        record.native.bounds = record.native.saved_bounds;
        record.native.state.minimized = record.native.saved_state.minimized;
        record.native.state.maximized = record.native.saved_state.maximized;
    }
    record.native.state.fullscreen = enabled;
    record.native.state.fullscreen_requested = enabled;
    record.emit(.{ .resize = .{ .width = record.native.bounds.width, .height = record.native.bounds.height, .scale = 1 } });
    if (enabled and record.window.app.native.fail_fullscreen_after_event) {
        record.window.app.native.fail_fullscreen_after_event = false;
        record.emitState();
        record.native.bounds = previous_bounds;
        record.native.state = previous_state;
        record.window.app.captureNativeFailure(.win32, 5);
        return error.WindowUpdateFailed;
    }
}
pub fn setAlwaysOnTop(record: *core.WindowRecord, enabled: bool) !void {
    if (enabled and !record.native.caps.always_on_top) return error.UnsupportedCapability;
    try update(record);
    record.native.state.always_on_top = enabled;
    record.native.state.always_on_top_requested = enabled;
}
pub fn setBackdrop(record: *core.WindowRecord, material: core.WindowBackdrop) !void {
    if (!record.native.caps.backdrop_material) return error.UnsupportedCapability;
    try update(record);
    record.native.backdrop = material;
}
pub fn setVibrancy(_: *core.WindowRecord, _: core.Vibrancy) void {}
pub fn setTitle(record: *core.WindowRecord, title: []const u8) !void {
    if (title.len > record.native.title.len) return error.TextCapacityExceeded;
    @memcpy(record.native.title[0..title.len], title);
    record.native.title_len = title.len;
}
pub fn setTraits(record: *core.WindowRecord, traits: core.WindowTraits) !void {
    try update(record);
    record.native.traits = traits;
}
pub fn setOpacity(record: *core.WindowRecord, value: f32) !void {
    try update(record);
    record.native.opacity = value;
}
pub fn setIgnorePointer(record: *core.WindowRecord, enabled: bool) !void {
    try update(record);
    record.native.ignore_pointer = enabled;
}
pub fn setContentProtection(record: *core.WindowRecord, enabled: bool) !void {
    try update(record);
    record.native.content_protected = enabled;
}
pub fn flashFrame(record: *core.WindowRecord, enabled: bool) !void {
    try update(record);
    record.native.flashing = enabled;
}
pub fn setSkipTaskbar(record: *core.WindowRecord, enabled: bool) !void {
    try update(record);
    record.native.skip_taskbar = enabled;
}
pub fn setTextCaret(_: *core.WindowRecord, _: core.Rect) !void {}
pub fn cancelTextForMode(record: *core.WindowRecord) !bool {
    const epoch = record.native.composition_epoch;
    record.native.composing = false;
    try cancelTextComposition(record);
    return !record.native.composing and epoch == record.native.composition_epoch;
}
pub fn setTextInputMode(record: *core.WindowRecord, mode: core.TextInputMode) !core.TextInputModeResult {
    try update(record);
    record.publishTextInputMode(mode);
    return .applied;
}
pub fn cancelTextComposition(record: *core.WindowRecord) !void {
    if (record.window.app.native.emit_text_cancel) record.emit(.text_preedit_cancel);
    if (record.window.app.native.fail_text_cancel) {
        record.window.app.native.fail_text_cancel = false;
        return error.CompositionQueryFailed;
    }
}
pub fn resize(record: *core.WindowRecord, width: u32, height: u32) !void {
    try setClientBounds(record, .{ .width = width, .height = height });
}
pub fn invalidate(_: *core.WindowRecord) void {}
pub fn invalidateRect(record: *core.WindowRecord, bounds: core.Rect) !void {
    if (record.native.fail_damage) return error.InvalidateFailed;
    record.native.damage = bounds;
}
pub fn destroy(record: *core.WindowRecord) !void {
    if (record.window.app.native.destroy_countdown) |remaining| {
        if (remaining == 0) {
            record.window.app.native.destroy_countdown = null;
            return error.DestroyWindowFailed;
        }
        record.window.app.native.destroy_countdown = remaining - 1;
    }
    if (record.window.app.native.fail_destroy) {
        record.window.app.native.fail_destroy = false;
        return error.DestroyWindowFailed;
    }
    const scope = record.enter();
    defer scope.end();
    record.nativeDestroying();
    record.native.alive = false;
    record.nativeDestroyed();
}
pub fn handle(record: *core.WindowRecord) ?*anyopaque {
    return if (record.native.alive) record else null;
}
/// The shape is kept on the record, where tests read it.
pub fn setCursor(_: *core.WindowRecord, _: core.Cursor) void {}
