//! Wakes a declarative view when a tooltip delay or a toast duration ends.
//! The Host asks for its earliest deadline after paint, in a posted task;
//! this module arms one `ziggurat_wake.OneShot` for it and invalidates the
//! window when it fires. Nothing repeats: with no deadline the timer is
//! disarmed and the idle window does no work.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const wake = @import("ziggurat_wake");

/// Keep Timer at a stable address from `attach` until `close` returns.
pub const Timer = struct {
    host: *view.Host,
    one_shot: ?*wake.OneShot = null,
    token: ?wake.Token = null,
    /// The first error from arming or cancelling, for diagnostics.
    last_error: ?anyerror = null,

    pub fn init(host: *view.Host) Timer {
        return .{ .host = host };
    }

    /// Create the native timer on the main thread and give the Host its
    /// scheduler. The allocator holds the timer until `close`.
    pub fn attach(self: *Timer, app: *z.App, allocator: std.mem.Allocator) !void {
        if (self.one_shot != null) return error.AlreadyAttached;
        self.one_shot = try wake.OneShot.create(app, allocator, .{ .context = self, .fire = fire }, .{});
        self.host.setScheduler(.{ .context = self, .schedule = schedule });
    }

    /// Detach from the Host and release the native timer. Call before the
    /// window or App closes.
    pub fn close(self: *Timer) !void {
        self.host.setScheduler(null);
        const timer = self.one_shot orelse return;
        self.one_shot = null;
        self.token = null;
        _ = try timer.close();
    }

    fn schedule(ptr: *anyopaque, deadline: ?u64, now: u64) void {
        const self: *Timer = @ptrCast(@alignCast(ptr));
        const timer = self.one_shot orelse return;
        if (self.token) |token| {
            _ = timer.cancel(token) catch |err| {
                self.last_error = self.last_error orelse err;
            };
            self.token = null;
        }
        const at = deadline orelse return;
        const delay = std.math.clamp(at -| now, 1, std.time.ns_per_hour);
        self.token = timer.armAfter(delay) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
    }

    fn fire(ptr: *anyopaque, _: *wake.OneShot, token: wake.Token) void {
        const self: *Timer = @ptrCast(@alignCast(ptr));
        if (self.token) |current| if (current.generation != token.generation) return;
        self.token = null;
        self.host.wakeFired();
    }
};
