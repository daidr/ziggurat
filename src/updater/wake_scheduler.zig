//! Times an Updater's automatic checks with a native one-shot wake. Waits
//! longer than one wake allows are served in steps, each re-armed when the
//! previous one fires, so nothing polls in between.
const std = @import("std");
const z = @import("ziggurat");
const wake = @import("ziggurat_wake");
const root = @import("root.zig");

/// Longest single step a one-shot wake accepts, in seconds.
const max_step = 3600;

/// Keep at a stable address from init() until deinit(). Main thread only.
pub const WakeScheduler = struct {
    updater: *root.Updater,
    timer: *wake.OneShot,
    token: ?wake.Token = null,
    /// Seconds still to wait after the armed step fires.
    remaining: u64 = 0,
    last_error: ?anyerror = null,

    pub fn init(self: *WakeScheduler, app: *z.App, allocator: std.mem.Allocator, updater: *root.Updater) !void {
        self.* = .{ .updater = updater, .timer = undefined };
        self.timer = try wake.OneShot.create(app, allocator, .{ .context = self, .fire = fired }, .{});
    }
    pub fn deinit(self: *WakeScheduler) void {
        _ = self.timer.close() catch {};
        self.token = null;
    }
    pub fn scheduler(self: *WakeScheduler) root.Scheduler {
        return .{ .context = self, .arm = arm, .cancel = cancel };
    }

    fn arm(ptr: *anyopaque, seconds: u64) anyerror!void {
        const self: *WakeScheduler = @ptrCast(@alignCast(ptr));
        try self.step(@max(seconds, 1));
    }
    fn step(self: *WakeScheduler, seconds: u64) !void {
        const now = @min(seconds, max_step);
        self.remaining = seconds - now;
        self.token = try self.timer.armAfter(now * std.time.ns_per_s);
    }
    fn cancel(ptr: *anyopaque) void {
        const self: *WakeScheduler = @ptrCast(@alignCast(ptr));
        if (self.token) |token| _ = self.timer.cancel(token) catch {};
        self.token = null;
        self.remaining = 0;
    }
    fn fired(ptr: *anyopaque, _: *wake.OneShot, token: wake.Token) void {
        const self: *WakeScheduler = @ptrCast(@alignCast(ptr));
        if (self.token == null or self.token.?.generation != token.generation) return;
        self.token = null;
        if (self.remaining != 0) {
            self.step(self.remaining) catch |err| {
                self.last_error = err;
            };
            return;
        }
        self.updater.timerFired();
    }
};
