const std = @import("std");
const core = @import("../root.zig");
const keys = @cImport({
    @cInclude("gdk/gdkkeysyms.h");
});
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
const NativeTextContext = extern struct { text: [*]u8, capacity: usize, length: usize, cursor: usize };
const NativeBounds = extern struct { x: i32, y: i32, width: u32, height: u32, positioned: c_int };
// Shared with linux_pointer.h; kind24 borrows facts only for this synchronous
// call. The smaller kind3/4 ticket has no receipt/history copy to trust.
const PointerFacts = extern struct {
    operation: u64,
    sequence: u64,
    phase: u32,
    button: u32,
    modifiers: u32,
    qualified: u32,
    tick_ms: u32,
    interval_ms: u32,
    edges: u32,
    disposition: u32,
    sample_x: f64,
    sample_y: f64,
    min_x: f64,
    max_x: f64,
    min_y: f64,
    max_y: f64,
};
const PointerTicket = extern struct { operation: u64, sequence: u64, button: u32, modifiers: u32 };
comptime {
    if (@sizeOf(PointerFacts) != 96 or @alignOf(PointerFacts) != 8 or @offsetOf(PointerFacts, "sequence") != 8 or
        @offsetOf(PointerFacts, "phase") != 16 or @offsetOf(PointerFacts, "tick_ms") != 32 or @offsetOf(PointerFacts, "sample_x") != 48 or
        @sizeOf(PointerTicket) != 24 or @alignOf(PointerTicket) != 8) @compileError("GTK pointer wire ABI mismatch");
}
extern fn zlg_app_create(*anyopaque, *const fn (*anyopaque) callconv(.c) void, *c_int) ?*anyopaque;
extern fn zlg_app_run(*anyopaque) void;
extern fn zlg_app_quit(*anyopaque) void;
extern fn zlg_app_wake(*anyopaque) void;
extern fn zlg_app_destroy(*anyopaque) void;
extern fn zlg_window_create(*anyopaque, *const fn (*anyopaque, *const NativeEvent) callconv(.c) c_int, [*:0]const u8, u32, u32, u32, u32, ?*anyopaque, c_int, c_int, c_int, *c_int) ?*anyopaque;
extern fn zlg_window_create_mode(*anyopaque, *const fn (*anyopaque, *const NativeEvent) callconv(.c) c_int, [*:0]const u8, u32, u32, u32, u32, ?*anyopaque, c_int, c_int, c_int, c_int, *c_int) ?*anyopaque;
extern fn zlg_window_create_mode_host(*anyopaque, *const fn (*anyopaque, *const NativeEvent) callconv(.c) c_int, [*:0]const u8, u32, u32, u32, u32, ?*anyopaque, c_int, c_int, c_int, c_int, c_int, *c_int) ?*anyopaque;
extern fn zlg_window_create_mode_host_pointer(*anyopaque, *const fn (*anyopaque, *const NativeEvent) callconv(.c) c_int, [*:0]const u8, u32, u32, u32, u32, ?*anyopaque, c_int, c_int, c_int, c_int, c_int, c_int, *c_int) ?*anyopaque;
extern fn zlg_window_pointer_operation(*anyopaque) u64;
extern fn zlg_window_advance_pointer_operation(*anyopaque) u64;
extern fn zlg_window_interaction(*anyopaque, c_int) c_int;
extern fn zlg_window_destroy(*anyopaque) c_int;
extern fn zlg_window_handle(*anyopaque) ?*anyopaque;
extern fn zlg_window_action(*anyopaque, c_int) void;
extern fn zlg_window_state(*anyopaque) u32;
extern fn zlg_window_capabilities(*anyopaque) u32;
extern fn zlg_window_bounds(*anyopaque, *NativeBounds) void;
extern fn zlg_window_size(*anyopaque, *u32, *u32, *u32) void;
extern fn zlg_window_set_bounds(*anyopaque, *const NativeBounds) c_int;
extern fn zlg_window_fullscreen(*anyopaque, c_int) c_int;
extern fn zlg_window_topmost(*anyopaque, c_int) c_int;
extern fn zlg_window_title(*anyopaque, [*:0]const u8) void;
extern fn zlg_window_resize(*anyopaque, u32, u32) void;
extern fn zlg_window_invalidate(*anyopaque) void;
extern fn zlg_window_invalidate_rect(*anyopaque, c_int, c_int, c_int, c_int) void;
extern fn zlg_window_caret(*anyopaque, c_int, c_int, c_int, c_int) void;
extern fn zlg_window_cancel_composition(*anyopaque) void;
extern fn zlg_window_cancel_text_for_mode(*anyopaque) c_int;
extern fn zlg_window_text_mode(*anyopaque, c_int, *anyopaque, *const fn (*anyopaque) callconv(.c) c_int) c_int;

pub fn init(app: *core.App) !void {
    if (app.icon_policy == .required) return error.UnsupportedCapability;
    var code: c_int = 0;
    app.native.native = zlg_app_create(app, dispatch, &code) orelse return switch (code) {
        1 => error.AppAlreadyExists,
        2 => error.DisplayUnavailable,
        else => error.OutOfMemory,
    };
}
pub fn deinit(app: *core.App) void {
    zlg_app_destroy(app.native.native.?);
    app.native.native = null;
}
pub fn run(app: *core.App) !void {
    zlg_app_run(app.native.native.?);
}
pub fn wake(app: *core.App) void {
    zlg_app_wake(app.native.native.?);
}
pub fn quit(app: *core.App) void {
    zlg_app_quit(app.native.native.?);
}
fn dispatch(ptr: *anyopaque) callconv(.c) void {
    const app: *core.App = @ptrCast(@alignCast(ptr));
    app.dispatch() catch |err| std.log.err("window destruction: {s}", .{@errorName(err)});
}
pub fn create(record: *core.WindowRecord, options: core.WindowOptions) !void {
    const allocator = record.window.app.allocator;
    const title = try allocator.dupeZ(u8, options.title);
    defer allocator.free(title);
    var code: c_int = 0;
    record.native.native = zlg_window_create_mode_host_pointer(record, event, title, options.width, options.height, options.min_width, options.min_height, if (record.owner_record) |owner| owner.native.native else null, @intFromBool(options.modal), @intFromEnum(options.decoration), @intFromBool(options.resizable), @intFromBool(options.text_input_mode == .keyboard_compose), @intFromBool(options.accessibility_host == .children), @intFromBool(options.native_pointer_clicks), &code) orelse return if (code == 1) error.UnsupportedCapability else error.OutOfMemory;
    if (options.text_input_mode != .system) record.publishTextInputMode(options.text_input_mode);
}
pub fn show(record: *core.WindowRecord) void {
    zlg_window_action(record.native.native.?, 0);
}
pub fn perform(record: *core.WindowRecord, action: core.WindowAction) !void {
    zlg_window_action(record.native.native.?, @intFromEnum(action));
}
pub fn state(record: *core.WindowRecord) core.WindowState {
    const flags = zlg_window_state(record.native.native.?);
    return .{ .visible = flags & 1 != 0, .minimized = flags & 2 != 0, .maximized = flags & 4 != 0, .focused = flags & 8 != 0, .enabled = flags & 16 != 0, .fullscreen = flags & 32 != 0, .fullscreen_requested = flags & 64 != 0, .always_on_top = flags & 128 != 0, .always_on_top_requested = flags & 256 != 0 };
}
pub fn capabilities(record: *core.WindowRecord) core.WindowCapabilities {
    const flags = zlg_window_capabilities(record.native.native.?);
    return .{ .client_position = flags & 1 != 0, .fullscreen = flags & 2 != 0, .always_on_top = flags & 4 != 0, .owned_windows = true, .modal_windows = true, .custom_decoration = flags & 8 != 0, .native_move_resize = flags & 16 != 0, .system_menu = flags & 32 != 0 };
}
pub fn startMove(record: *core.WindowRecord) !void {
    try checkUpdate(zlg_window_interaction(record.native.native.?, -1));
}
pub fn startResize(record: *core.WindowRecord, edge: core.ResizeEdge) !void {
    try checkUpdate(zlg_window_interaction(record.native.native.?, @intFromEnum(edge)));
}
pub fn showSystemMenu(record: *core.WindowRecord) !void {
    try checkUpdate(zlg_window_interaction(record.native.native.?, 8));
}
pub fn isActive(record: *core.WindowRecord) bool {
    return state(record).focused;
}
pub fn clientBounds(record: *core.WindowRecord) !core.ClientBounds {
    var bounds: NativeBounds = undefined;
    zlg_window_bounds(record.native.native.?, &bounds);
    return .{ .position = if (bounds.positioned != 0) .{ .x = bounds.x, .y = bounds.y } else null, .width = bounds.width, .height = bounds.height };
}
pub fn contentSize(record: *core.WindowRecord) !core.Size {
    var width: u32 = 0;
    var height: u32 = 0;
    var scale: u32 = 1;
    zlg_window_size(record.native.native.?, &width, &height, &scale);
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
    try checkUpdate(zlg_window_set_bounds(record.native.native.?, &native));
}
pub fn setFullscreen(record: *core.WindowRecord, enabled: bool) !void {
    try checkUpdate(zlg_window_fullscreen(record.native.native.?, @intFromBool(enabled)));
}
pub fn setAlwaysOnTop(record: *core.WindowRecord, enabled: bool) !void {
    try checkUpdate(zlg_window_topmost(record.native.native.?, @intFromBool(enabled)));
}
pub fn setTitle(record: *core.WindowRecord, title: []const u8) !void {
    const allocator = record.window.app.allocator;
    const terminated = try allocator.dupeZ(u8, title);
    defer allocator.free(terminated);
    zlg_window_title(record.native.native.?, terminated);
}
pub fn resize(record: *core.WindowRecord, width: u32, height: u32) !void {
    zlg_window_resize(record.native.native.?, width, height);
}
pub fn setTextCaret(record: *core.WindowRecord, rect: core.Rect) !void {
    const limit: f32 = @floatFromInt(@divTrunc(std.math.maxInt(c_int), 2));
    if (@abs(rect.x) > limit or @abs(rect.y) > limit or rect.width > limit or rect.height > limit) return error.InvalidGeometry;
    zlg_window_caret(record.native.native.?, @intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(@max(1, rect.width)), @intFromFloat(@max(1, rect.height)));
}
pub fn cancelTextComposition(record: *core.WindowRecord) !void {
    zlg_window_cancel_composition(record.native.native.?);
}
pub fn cancelTextForMode(record: *core.WindowRecord) !bool {
    return zlg_window_cancel_text_for_mode(record.native.native.?) != 0;
}
pub fn setTextInputMode(record: *core.WindowRecord, mode: core.TextInputMode) !core.TextInputModeResult {
    const Guard = struct {
        record: *core.WindowRecord,
        generation: u64,
        allowed: bool,
        fn current(ptr: *anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return @intFromBool(self.record.phase == .open and self.record.window.app.phase != .stopping and self.record.window.app.phase != .stopped and self.record.text_generation == self.generation and self.record.inputAllowed() == self.allowed);
        }
    };
    var guard: Guard = .{ .record = record, .generation = record.text_generation, .allowed = record.inputAllowed() };
    return switch (zlg_window_text_mode(record.native.native.?, @intFromBool(mode == .keyboard_compose), &guard, Guard.current)) {
        0 => .applied,
        2 => .superseded,
        6 => error.IdExhausted,
        else => error.InputAssociationFailed,
    };
}
pub fn invalidate(record: *core.WindowRecord) void {
    zlg_window_invalidate(record.native.native.?);
}
pub fn invalidateRect(record: *core.WindowRecord, bounds: core.Rect) !void {
    const left = @floor(@max(0, bounds.x));
    const top = @floor(@max(0, bounds.y));
    const right = @ceil(@as(f64, bounds.x) + bounds.width);
    const bottom = @ceil(@as(f64, bounds.y) + bounds.height);
    if (right <= left or bottom <= top) return;
    zlg_window_invalidate_rect(record.native.native.?, @intFromFloat(left), @intFromFloat(top), @intFromFloat(right), @intFromFloat(bottom));
}
pub fn destroy(record: *core.WindowRecord) !void {
    if (zlg_window_destroy(record.native.native.?) == 0) return error.DestroyWindowFailed;
}
pub fn handle(record: *core.WindowRecord) ?*anyopaque {
    return zlg_window_handle(record.native.native.?);
}
pub fn pointerOperation(record: *const core.WindowRecord) u64 {
    return zlg_window_pointer_operation(record.native.native orelse return std.math.maxInt(u64));
}
pub fn advancePointerOperation(record: *core.WindowRecord) u64 {
    return zlg_window_advance_pointer_operation(record.native.native orelse return std.math.maxInt(u64));
}
fn event(ptr: *anyopaque, native: *const NativeEvent) callconv(.c) c_int {
    const record: *core.WindowRecord = @ptrCast(@alignCast(ptr));
    const scope = record.enterNative();
    defer scope.end();
    const point: core.Point = .{ .x = @floatCast(native.x), .y = @floatCast(native.y) };
    switch (native.kind) {
        1 => record.emit(.{ .paint = .{ .native_context = native.context.?, .native_window = native.window, .size = .{ .width = native.width, .height = native.height, .scale = @floatFromInt(native.scale) } } }),
        2 => pointerLifecycle(record, native, .{ .resize = .{ .width = native.width, .height = native.height, .scale = @floatFromInt(native.scale) } }),
        22 => pointerLifecycle(record, native, .window_position),
        // C has installed its new active context and retired old callbacks.
        // Publish before its final native reference releases can reenter.
        23 => record.publishTextInputMode(if (native.flags == 0) .system else .keyboard_compose),
        3, 4 => {
            const phase: core.PointerPhase = if (native.kind == 3) .down else .up;
            const input: core.PointerButtonInput = .{ .position = point, .modifiers = pointerModifiers(@intCast(native.flags)) };
            if (record.pointerEnabled()) {
                if (native.context) |context| {
                    const ticket: *const PointerTicket = @ptrCast(@alignCast(context));
                    if (ticket.button > 4 or ticket.modifiers & ~@as(u32, 15) != 0) return 0;
                    var captured = input;
                    captured.button = @enumFromInt(ticket.button);
                    captured.modifiers = pointerModifiers(ticket.modifiers);
                    record.emitPointer(ticket.operation, ticket.sequence, phase, captured);
                }
            } else if (phase == .down) record.emit(.{ .pointer_down = input }) else record.emit(.{ .pointer_up = input });
        },
        5 => record.emit(.{ .pointer_move = point }),
        6 => record.emit(.{ .wheel = .{ .position = point, .delta = .{ .x = @floatCast(native.dx), .y = @floatCast(native.dy) } } }),
        7 => pointerLifecycle(record, native, .{ .focus = native.flags & 1 != 0 }),
        8 => {
            if (native.flags & 0x100 != 0) {
                pointerLifecycle(record, native, .cancel_input);
            } else if (native.context) |context| {
                const ticket: *const PointerTicket = @ptrCast(@alignCast(context));
                if (ticket.button <= 4 and ticket.sequence != 0) record.emitPointerCancel(ticket.operation, ticket.sequence, @enumFromInt(ticket.button));
            } else record.emit(.cancel_input);
        },
        9 => record.emit(.{ .edit_key = .{ .key = @enumFromInt(native.key), .shift = native.flags & 1 != 0, .control = native.flags & 2 != 0 } }),
        10 => _ = record.window.requestCloseFrom(.user) catch |err| {
            record.window.report(.{ .domain = .core, .operation = .window_destroy, .err = err });
        },
        11 => {
            record.native.native = null;
            record.nativeDestroying();
            record.nativeDestroyed();
        },
        12 => record.emit(.{ .text_input = .{ .text = native.text.?[0..native.length], .producer = if (native.flags == 1) .gtk_keyval_fallback else .gtk_text_service_commit } }),
        13 => record.emit(.{ .text_preedit = .{ .text = native.text.?[0..native.length], .selection_start = native.selection, .selection_end = native.selection } }),
        14 => record.emit(.text_preedit_cancel),
        15 => record.emit(.{ .key = if (native.key == 0) .tab else .activate }),
        16 => {
            if (native.flags & 0x100 != 0) {
                const operation: *const u64 = @ptrCast(@alignCast(native.context orelse return 0));
                record.emitPointerState(operation.*);
            } else record.emitState();
        },
        17 => return @intFromBool(record.inputAllowed()),
        18 => return @intFromBool(record.keyInput(.{ .key = keyCode(@intCast(native.key)), .modifiers = .{ .shift = native.flags & 1 != 0, .control = native.flags & 2 != 0, .alt = native.flags & 4 != 0, .super = native.flags & 8 != 0 }, .repeat = native.flags & 16 != 0 })),
        19 => return @intFromEnum(record.hitTest(point, @floatFromInt(native.width), @floatFromInt(native.height))),
        20, 21 => return textContext(record, native) catch |err| {
            if (err != error.StaleTextClient and err != error.CompositionActive) record.window.report(.{ .domain = .core, .operation = .text_input, .err = err });
            return 0;
        },
        24 => return pointerFacts(record, native.context orelse return 0),
        else => unreachable,
    }
    return 0;
}
fn pointerLifecycle(record: *core.WindowRecord, native: *const NativeEvent, value: core.Event) void {
    if (native.flags & 0x100 != 0) {
        const operation: *const u64 = @ptrCast(@alignCast(native.context orelse return));
        record.emitPointerLifecycle(operation.*, value);
    } else record.emit(value);
}
fn pointerModifiers(bits: u32) core.KeyModifiers {
    return .{ .shift = bits & 1 != 0, .control = bits & 2 != 0, .alt = bits & 4 != 0, .super = bits & 8 != 0 };
}
noinline fn pointerFacts(record: *core.WindowRecord, context: *anyopaque) c_int {
    const facts: *PointerFacts = @ptrCast(@alignCast(context));
    if (facts.phase > 6 or facts.modifiers & ~@as(u32, 15) != 0 or facts.qualified > 1 or
        facts.edges & ~@as(u32, 31) != 0 or facts.disposition > 2) return 0;
    const button: ?core.PointerButton = if (facts.button == std.math.maxInt(u32)) null else if (facts.button <= 4) @enumFromInt(facts.button) else return 0;
    if (pointerOperation(record) != facts.operation) return 0;
    if (facts.phase == 5 or facts.phase == 6) {
        record.pointerRevoke(facts.operation, facts.phase == 6);
        return 1;
    }
    if (!record.pointerCurrent(facts.operation)) return 0;
    switch (facts.phase) {
        0 => {
            const timing: ?core.PointerClickTiming = if (facts.qualified == 0) null else .{
                .tick_ms = facts.tick_ms,
                .position = .{ .x = facts.sample_x, .y = facts.sample_y, .domain = record.pointerDomain() },
                .policy = .{
                    .interval_ms = facts.interval_ms,
                    .min_x = facts.min_x,
                    .max_x = facts.max_x,
                    .min_y = facts.min_y,
                    .max_y = facts.max_y,
                    .edges = @bitCast(@as(u8, @intCast(facts.edges))),
                },
            };
            const transition = record.pointerBeginDown(facts.operation, button, timing) orelse return 0;
            facts.sequence = transition.press.sequence;
            return 1;
        },
        2 => {
            const transition = record.pointerBeginUp(facts.operation, button) orelse return 0;
            facts.sequence = transition.press.sequence;
            return 1;
        },
        1, 3 => return @intFromBool(record.pointerFinish(facts.operation, facts.sequence, button, if (facts.phase == 1) .down else .up, @enumFromInt(facts.disposition))),
        4 => {
            record.pointerMotion(facts.operation, if (facts.qualified == 0) null else .{ .x = facts.sample_x, .y = facts.sample_y, .domain = record.pointerDomain() });
            return 1;
        },
        else => unreachable,
    }
}
noinline fn textContext(record: *core.WindowRecord, native: *const NativeEvent) !c_int {
    const window = record.window;
    const token = window.textClientToken() orelse return 0;
    var scratch: [12288]u8 = undefined;
    const storage = if (native.kind == 20) storage: {
        const output: *NativeTextContext = @ptrCast(@alignCast(native.context.?));
        break :storage output.text[0..@min(output.capacity, scratch.len)];
    } else &scratch;
    const value = try window.readTextClient(token, storage);
    // Surrounding is committed context. Do not mutate or expose a virtual
    // replacement as if it were an ordinary committed insertion point.
    if (value.composition != null) return error.CompositionActive;
    const text_value = storage[0..value.bytes];
    const cursor = try core.text.byteOffset(text_value, value.selection.caret - value.range.start);
    if (native.kind == 20) {
        const output: *NativeTextContext = @ptrCast(@alignCast(native.context.?));
        output.length = value.bytes;
        output.cursor = cursor;
        return 1;
    }
    if (native.flags < 0) return error.InvalidRange;
    if (native.flags == 0) return 1;
    const start = try scalarOffset(text_value, cursor, native.key);
    const end = try scalarOffset(text_value, start, native.flags);
    const result = try window.changeTextClient(token, .{ .replace = .{ .range = .{ .start = value.range.start + try core.text.utf16Length(text_value[0..start]), .end = value.range.start + try core.text.utf16Length(text_value[0..end]) }, .text = "" } });
    return @intFromBool(result == .applied);
}
fn scalarOffset(text_value: []const u8, cursor: usize, delta: i32) !usize {
    var position = cursor;
    var remaining: i64 = delta;
    while (remaining < 0) : (remaining += 1) {
        if (position == 0) return error.InvalidRange;
        position -= 1;
        while (text_value[position] & 0xc0 == 0x80) position -= 1;
    }
    while (remaining > 0) : (remaining -= 1) {
        if (position == text_value.len) return error.InvalidRange;
        position += try std.unicode.utf8ByteSequenceLength(text_value[position]);
    }
    return position;
}
fn keyCode(code: u32) core.KeyCode {
    if (code >= 'a' and code <= 'z') return @enumFromInt(@intFromEnum(core.KeyCode.a) + code - 'a');
    if (code >= '0' and code <= '9') return @enumFromInt(@intFromEnum(core.KeyCode.digit0) + code - '0');
    if (code >= keys.GDK_KEY_F1 and code <= keys.GDK_KEY_F24) return @enumFromInt(@intFromEnum(core.KeyCode.f1) + code - keys.GDK_KEY_F1);
    if (code >= keys.GDK_KEY_KP_0 and code <= keys.GDK_KEY_KP_9) return @enumFromInt(@intFromEnum(core.KeyCode.numpad0) + code - keys.GDK_KEY_KP_0);
    return switch (code) {
        keys.GDK_KEY_Tab, keys.GDK_KEY_ISO_Left_Tab, keys.GDK_KEY_KP_Tab => .tab,
        keys.GDK_KEY_Return, keys.GDK_KEY_KP_Enter => .enter,
        keys.GDK_KEY_space, keys.GDK_KEY_KP_Space => .space,
        keys.GDK_KEY_Escape => .escape,
        keys.GDK_KEY_Left, keys.GDK_KEY_KP_Left => .left,
        keys.GDK_KEY_Right, keys.GDK_KEY_KP_Right => .right,
        keys.GDK_KEY_Up, keys.GDK_KEY_KP_Up => .up,
        keys.GDK_KEY_Down, keys.GDK_KEY_KP_Down => .down,
        keys.GDK_KEY_Home, keys.GDK_KEY_KP_Home => .home,
        keys.GDK_KEY_End, keys.GDK_KEY_KP_End => .end,
        keys.GDK_KEY_Page_Up, keys.GDK_KEY_KP_Page_Up => .page_up,
        keys.GDK_KEY_Page_Down, keys.GDK_KEY_KP_Page_Down => .page_down,
        keys.GDK_KEY_Insert, keys.GDK_KEY_KP_Insert => .insert,
        keys.GDK_KEY_Delete, keys.GDK_KEY_KP_Delete => .delete,
        keys.GDK_KEY_BackSpace => .backspace,
        keys.GDK_KEY_Caps_Lock => .caps_lock,
        keys.GDK_KEY_Num_Lock => .num_lock,
        keys.GDK_KEY_Scroll_Lock => .scroll_lock,
        keys.GDK_KEY_Print => .print_screen,
        keys.GDK_KEY_Pause => .pause,
        keys.GDK_KEY_Shift_L, keys.GDK_KEY_Shift_R => .shift,
        keys.GDK_KEY_Control_L, keys.GDK_KEY_Control_R => .control,
        keys.GDK_KEY_Alt_L, keys.GDK_KEY_Alt_R => .alt,
        keys.GDK_KEY_Super_L, keys.GDK_KEY_Super_R, keys.GDK_KEY_Meta_L, keys.GDK_KEY_Meta_R => .super,
        keys.GDK_KEY_Menu => .context_menu,
        '-' => .minus,
        '=' => .equal,
        '[' => .left_bracket,
        ']' => .right_bracket,
        '\\' => .backslash,
        ';' => .semicolon,
        '\'' => .apostrophe,
        '`' => .grave,
        ',' => .comma,
        '.' => .period,
        '/' => .slash,
        keys.GDK_KEY_KP_Decimal => .decimal,
        keys.GDK_KEY_KP_Add => .add,
        keys.GDK_KEY_KP_Subtract => .subtract,
        keys.GDK_KEY_KP_Multiply => .multiply,
        keys.GDK_KEY_KP_Divide => .divide,
        keys.GDK_KEY_AudioPlay, keys.GDK_KEY_AudioPause => .media_play_pause,
        keys.GDK_KEY_AudioStop => .media_stop,
        keys.GDK_KEY_AudioNext => .media_next,
        keys.GDK_KEY_AudioPrev => .media_previous,
        keys.GDK_KEY_AudioMute => .volume_mute,
        keys.GDK_KEY_AudioLowerVolume => .volume_down,
        keys.GDK_KEY_AudioRaiseVolume => .volume_up,
        keys.GDK_KEY_Back => .browser_back,
        keys.GDK_KEY_Forward => .browser_forward,
        keys.GDK_KEY_Refresh => .browser_refresh,
        keys.GDK_KEY_Stop => .browser_stop,
        keys.GDK_KEY_Search => .browser_search,
        keys.GDK_KEY_Favorites => .browser_favorites,
        keys.GDK_KEY_HomePage => .browser_home,
        else => .unknown,
    };
}
