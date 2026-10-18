const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");

pub const Token = struct { generation: u64 };
pub const CloseResult = enum { closed, deferred };
pub const Callback = struct { context: *anyopaque, fire: *const fn (*anyopaque, *OneShot, Token) void };
pub const Options = struct { on_closed: ?z.Task = null };
pub const Stats = struct { armed: bool, generation: u64, fires: u64, stopped: bool };
pub const NativeCounts = extern struct { states: u32 = 0, handles: u32 = 0, sources: u32 = 0, dispatches: u32 = 0 };
pub fn nativeCounts() NativeCounts {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return .{};
    return zgwake_counts();
}

/// Stable main-thread one-shot owner, separate from pure animation state.
/// It never keeps App.run alive, posts tasks, invokes a worker or repeats itself.
pub const OneShot = opaque {
    pub fn create(app: *z.App, allocator: std.mem.Allocator, callback: Callback, options: Options) !*OneShot {
        if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
        if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.UnsupportedPlatform;
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        const self = try allocator.create(State);
        errdefer allocator.destroy(self);
        try checkApp(app);
        self.* = .{ .allocator = allocator, .owner = app.owner, .app = app, .callback = callback, .options = options, .stop_node = .{ .context = self, .stop = stop } };
        self.native = zgwake_create(self, firedC) orelse return error.NativeTimerCreationFailed;
        errdefer zgwake_close(self.native.?);
        try checkApp(app);
        self.stop_token = try app.registerStop(&self.stop_node);
        return @ptrCast(self);
    }
    /// Replaces any prior deadline. Nanoseconds are rounded upward to native
    /// resolution, never treated as a periodic timer. On native/watch failure
    /// this owner is disarmed; it never leaves an undeliverable old deadline.
    pub fn armAfter(self: *OneShot, nanoseconds: u64) !Token {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.operation_busy = false;
        if (nanoseconds == 0 or nanoseconds > 3600 * std.time.ns_per_s) return error.InvalidDuration;
        if (state.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        if (builtin.os.tag == .windows and state.wait == null) {
            state.wait = state.app.?.watchNative(zgwake_handle(state.native.?).?, .{ .context = state, .call = fired }) catch |err| {
                state.disarm();
                return err;
            };
        }
        if (zgwake_arm(state.native.?, nanoseconds) == 0) {
            state.disarm();
            return error.NativeTimerArmFailed;
        }
        state.generation += 1;
        state.armed = true;
        return .{ .generation = state.generation };
    }
    pub fn cancel(self: *OneShot, token: Token) !bool {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.operation_busy = false;
        if (!state.armed or token.generation != state.generation) return false;
        state.disarm();
        return true;
    }
    pub fn stats(self: *const OneShot) !Stats {
        const state = cast(@constCast(self));
        try state.checkOwner();
        if (state.closing) return error.Closed;
        if (state.operation_busy) return error.Busy;
        return .{ .armed = state.armed, .generation = state.generation, .fires = state.fires, .stopped = state.app == null };
    }
    /// Closing in fire revokes native callbacks immediately and delays the
    /// allocator/on_closed tail until that callback returns. App stop only
    /// releases native resources; the caller still closes the surviving shell.
    pub fn close(self: *OneShot) !CloseResult {
        const state = cast(self);
        try state.checkOwner();
        if (state.closing) return error.Closed;
        if (state.operation_busy) return error.Busy;
        const scope: ?z.AppCallbackScope = if (state.app) |app| app.beginTeardownCallback() else null;
        defer if (scope) |held| held.end();
        state.operation_busy = true;
        errdefer state.operation_busy = false;
        if (state.stop_token) |token| _ = try state.app.?.cancelStop(token);
        state.stop_token = null;
        state.closing = true;
        state.releaseNative();
        state.operation_busy = false;
        if (state.callbacks != 0) return .deferred;
        state.finalize();
        return .closed;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    app: ?*z.App,
    callback: Callback,
    options: Options,
    native: ?*anyopaque = null,
    wait: ?z.NativeWaitToken = null,
    stop_node: z.StopParticipant,
    stop_token: ?z.StopToken = null,
    generation: u64 = 0,
    fires: u64 = 0,
    callbacks: usize = 0,
    operation_busy: bool = false,
    armed: bool = false,
    closing: bool = false,
    fn checkOwner(self: *const State) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
    }
    fn enter(self: *State) !z.AppCallbackScope {
        try self.checkOwner();
        if (self.closing or self.app == null) return error.Closed;
        if (self.operation_busy) return error.Busy;
        const scope = self.app.?.beginCallback() orelse return error.Closed;
        self.operation_busy = true;
        return scope;
    }
    fn disarm(self: *State) void {
        self.armed = false;
        if (self.wait) |token| {
            self.wait = null;
            _ = self.app.?.unwatchNative(token);
        }
        if (self.native) |native| zgwake_cancel(native);
    }
    fn releaseNative(self: *State) void {
        self.disarm();
        const native = self.native;
        self.native = null;
        self.app = null;
        if (native) |value| zgwake_close(value);
    }
    fn finalize(self: *State) void {
        const allocator = self.allocator;
        const notify = self.options.on_closed;
        allocator.destroy(self);
        if (notify) |task| task.call(task.context);
    }
};
fn cast(self: *OneShot) *State {
    return @ptrCast(@alignCast(self));
}
fn checkApp(app: *z.App) !void {
    if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
}
fn firedC(context: *anyopaque) callconv(.c) void {
    fired(context);
}
fn fired(context: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(context));
    state.checkOwner() catch @panic("one-shot dispatched outside its owner thread");
    state.wait = null;
    if (!state.armed or state.closing) return;
    state.armed = false;
    const app = state.app orelse return;
    const scope = app.beginCallback() orelse return;
    const callback = state.callback;
    const token: Token = .{ .generation = state.generation };
    state.callbacks += 1;
    state.fires +|= 1;
    callback.fire(callback.context, @ptrCast(state), token);
    state.callbacks -= 1;
    if (state.closing and state.callbacks == 0) state.finalize();
    // finalize/on_closed and shutdown may free every borrowed owner. There is
    // no State or callback-context access after this final lifetime boundary.
    scope.end();
}
fn stop(context: *anyopaque) !void {
    const state: *State = @ptrCast(@alignCast(context));
    state.stop_token = null;
    state.releaseNative();
}

extern fn zgwake_create(*anyopaque, *const fn (*anyopaque) callconv(.c) void) ?*anyopaque;
extern fn zgwake_handle(*anyopaque) ?*anyopaque;
extern fn zgwake_arm(*anyopaque, u64) c_int;
extern fn zgwake_cancel(*anyopaque) void;
extern fn zgwake_close(*anyopaque) void;
extern fn zgwake_counts() NativeCounts;
