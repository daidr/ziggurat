//! Windows asynchronous message dialogs over the system MessageDialog. The
//! dialog never runs a nested loop: completion only signals a kernel event,
//! and App's one-shot native wait reads the result on the main thread.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const types = @import("types.zig");
const menus = @import("menus.zig");

const Text = extern struct { text: [*]const u16, length: u32 };
extern fn zmd_create(?*anyopaque, Text, Text, [*]const Text, u32, u32, u32, *i32, *?*anyopaque) ?*anyopaque;
extern fn zmd_start(*anyopaque) i32;
extern fn zmd_cancel(*anyopaque) i32;
extern fn zmd_collect(*anyopaque, *u32, *c_int) i32;
extern fn zmd_close(*anyopaque) void;
extern fn zmd_resource_count() u32;

/// Native states may outlive their Owner while the runtime finishes
/// cancellation. They hold no Zig or App pointer.
pub fn resourceCount() u32 {
    if (comptime builtin.os.tag != .windows) return 0;
    return zmd_resource_count();
}

pub const Done = *const fn (*anyopaque, z.Window, types.MessageResult) void;

/// One pending message per Owner. Detach cancels silently and disconnects
/// every future Zig callback; cancel() still delivers `dismissed`.
pub const Message = struct {
    native: ?*anyopaque = null,
    window: ?z.Window = null,
    wait: ?z.NativeWaitToken = null,
    context: ?*anyopaque = null,
    done: ?Done = null,
    request: u64 = 0,
    buttons: [types.max_message_buttons]u64 = @splat(0),
    cancel_id: ?u64 = null,
    in_native: bool = false,
    closing: bool = false,
    last_hresult: i32 = 0,
    generation: u64 = 0,

    pub fn pending(self: *const Message) bool {
        return self.native != null or self.in_native;
    }

    pub fn start(self: *Message, window: z.Window, request: u64, options: types.MessageOptions, context: *anyopaque, done: Done) !void {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedCapability;
        window.app.assertOwner();
        if (self.pending()) return error.MessageAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        try menus.validateMessage(options);
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        var title: [256]u16 = undefined;
        var message: [4097]u16 = undefined;
        var labels: [types.max_message_buttons][65]u16 = undefined;
        var buttons: [types.max_message_buttons]Text = undefined;
        const title_text = try wide(&title, options.title);
        const message_text = try wide(&message, options.message);
        for (options.buttons, 0..) |button, index| buttons[index] = try wide(&labels[index], button.label);
        if (self.generation == std.math.maxInt(u64)) return error.OperationGenerationExhausted;
        self.generation += 1;
        self.closing = false;
        self.in_native = true;
        defer self.leaveNative();
        var event: ?*anyopaque = null;
        const unset = std.math.maxInt(u32);
        const default_index: u32 = if (options.default_button) |index| @intCast(index) else unset;
        const cancel_index: u32 = if (options.cancel_button) |index| @intCast(index) else unset;
        const native = zmd_create(window.nativeHandle(), title_text, message_text, &buttons, @intCast(options.buttons.len), default_index, cancel_index, &self.last_hresult, &event) orelse return error.MessageDialogCreationFailed;
        self.native = native;
        self.window = window;
        self.context = context;
        self.done = done;
        self.request = request;
        self.buttons = @splat(0);
        for (options.buttons, 0..) |button, index| self.buttons[index] = button.id;
        self.cancel_id = if (options.cancel_button) |index| options.buttons[index].id else null;
        errdefer self.detach();
        if (self.closing or window.isClosed()) return error.Closed;
        self.wait = try window.app.watchNative(event.?, .{ .context = self, .call = complete });
        self.last_hresult = zmd_start(native);
        if (self.last_hresult < 0) return error.MessageDialogStartFailed;
        if (self.closing or window.isClosed()) return error.Closed;
    }
    pub fn cancel(self: *Message) !void {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedCapability;
        const native = self.native orelse return;
        const window = self.window orelse return;
        window.app.assertOwner();
        if (self.in_native) return error.MessageBusy;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.in_native = true;
        defer self.leaveNative();
        self.last_hresult = zmd_cancel(native);
        if (self.last_hresult < 0) return error.MessageDialogCancelFailed;
    }
    pub fn detach(self: *Message) void {
        if (self.window) |value| {
            value.app.assertOwner();
            if (self.wait) |token| _ = value.app.unwatchNative(token);
        }
        self.wait = null;
        if (self.in_native) {
            self.closing = true;
            return;
        }
        _ = self.closeNative();
    }
    fn closeNative(self: *Message) bool {
        std.debug.assert(!self.in_native);
        const scope = if (self.window) |window| window.beginCallback() else null;
        defer if (scope) |value| value.end();
        self.in_native = true;
        const native = self.native;
        self.native = null;
        self.window = null;
        self.context = null;
        self.done = null;
        self.closing = false;
        if (comptime builtin.os.tag == .windows) if (native) |value| zmd_close(value);
        const uninterrupted = !self.closing;
        self.in_native = false;
        self.closing = false;
        return uninterrupted;
    }
    fn leaveNative(self: *Message) void {
        self.in_native = false;
        if (self.closing) self.detach();
    }
    fn complete(ptr: *anyopaque) void {
        const self: *Message = @ptrCast(@alignCast(ptr));
        const native = self.native orelse return;
        const generation = self.generation;
        const window = self.window orelse return;
        self.wait = null;
        const scope = window.beginCallback() orelse {
            self.detach();
            return;
        };
        defer scope.end();
        var index: u32 = 0;
        var cancelled: c_int = 0;
        self.in_native = true;
        self.last_hresult = zmd_collect(native, &index, &cancelled);
        self.leaveNative();
        if (self.generation != generation or self.native != native) return;
        const response: types.MessageResponse = if (self.last_hresult < 0)
            .{ .failed = .{ .err = error.MessageDialogResultFailed, .code = self.last_hresult } }
        else if (cancelled != 0)
            .dismissed
        else if (index < self.buttons.len and self.buttons[index] != 0)
            .{ .button = self.buttons[index] }
        else if (self.cancel_id) |id| .{ .button = id } else .dismissed;
        const result: types.MessageResult = .{ .request = self.request, .response = response };
        const done = self.done.?;
        const context = self.context.?;
        if (!self.closeNative() or self.generation != generation or window.isClosed()) return;
        done(context, window, result);
    }
};

fn wide(destination: []u16, source: []const u8) !Text {
    const needed = std.unicode.calcUtf16LeLen(source) catch return error.InvalidUtf8;
    if (needed >= destination.len) return error.TextCapacityExceeded;
    const count = std.unicode.utf8ToUtf16Le(destination, source) catch return error.InvalidUtf8;
    destination[count] = 0;
    return .{ .text = destination.ptr, .length = @intCast(count) };
}
