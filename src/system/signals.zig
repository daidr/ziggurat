//! Quit on SIGINT and SIGTERM. The first signal asks the App to quit through
//! `requestQuit`, on the main thread from the event loop, so close handlers
//! run and can cancel; a second signal exits the process at once with status
//! 128 + signal. Signals ignored when the process started stay ignored. Only
//! one QuitOnSignals is active per process. Windows has no such signals; its
//! console control events are not handled here.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");

const enabled = builtin.os.tag == .linux and !builtin.is_test;
pub const capabilities = .{ .quit_on_signals = builtin.os.tag == .linux };

extern fn zsg_signals_start(*const fn (?*anyopaque, c_int) callconv(.c) void, ?*anyopaque, *c_int) c_int;
extern fn zsg_signals_stop() void;

/// Keep at a stable address from start until stop, or until App shutdown
/// stops it.
pub const QuitOnSignals = struct {
    app: ?*z.App = null,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    /// The last signal number that asked to quit, 0 before any.
    last_signal: c_int = 0,
    last_result: ?z.App.QuitResult = null,
    /// errno of a failed start.
    native_failure: c_int = 0,

    pub fn start(self: *QuitOnSignals, app: *z.App) !void {
        app.assertOwner();
        if (self.app != null) return error.AlreadyActive;
        if (!capabilities.quit_on_signals) return error.UnsupportedCapability;
        self.stop_node = .{ .context = self, .stop = stopFromApp };
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer {
            _ = app.cancelStop(self.stop_token.?) catch {};
            self.stop_token = null;
        }
        if (comptime enabled) {
            switch (zsg_signals_start(requested, self, &self.native_failure)) {
                0 => {},
                1 => return error.AlreadyActive,
                else => return error.SignalSetupFailed,
            }
        }
        self.app = app;
    }
    pub fn stop(self: *QuitOnSignals) void {
        const app = self.app orelse return;
        app.assertOwner();
        if (self.stop_token) |token| _ = app.cancelStop(token) catch {};
        self.stop_token = null;
        self.release();
    }
    pub fn active(self: *const QuitOnSignals) bool {
        return self.app != null;
    }
    fn release(self: *QuitOnSignals) void {
        if (comptime enabled) zsg_signals_stop();
        self.app = null;
    }
    fn stopFromApp(ptr: *anyopaque) anyerror!void {
        const self: *QuitOnSignals = @ptrCast(@alignCast(ptr));
        self.stop_token = null;
        self.release();
    }
    fn requested(ptr: ?*anyopaque, signal: c_int) callconv(.c) void {
        const self: *QuitOnSignals = @ptrCast(@alignCast(ptr.?));
        self.deliver(signal);
    }
    /// The main-thread half of a signal; tests call it directly.
    pub fn deliver(self: *QuitOnSignals, signal: c_int) void {
        const app = self.app orelse return;
        self.last_signal = signal;
        self.last_result = app.requestQuit();
    }
};

test "a signal asks the app to quit and close handlers can cancel" {
    if (!capabilities.quit_on_signals) return error.SkipZigTest;
    const Veto = struct {
        fn request(_: *anyopaque, _: z.Window, reason: z.CloseReason) z.CloseDecision {
            return if (reason == .quit) .cancel else .allow;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: u8 = 0;
    _ = try app.createWindow(.{ .on_close = .{ .context = &context, .request = Veto.request } });
    var quit: QuitOnSignals = .{};
    try quit.start(app);
    try std.testing.expectError(error.AlreadyActive, quit.start(app));
    quit.deliver(15);
    try std.testing.expectEqual(z.App.QuitResult.cancelled, quit.last_result.?);
    try std.testing.expectEqual(@as(c_int, 15), quit.last_signal);
    quit.stop();
    try std.testing.expect(!quit.active());
    try quit.start(app);
    // Shutdown stops it without an explicit stop.
}
