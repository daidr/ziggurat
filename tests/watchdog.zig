const std = @import("std");
const z = @import("ziggurat");

/// Cancels promptly on completion. The worker never touches a window.
pub const Watchdog = struct {
    app: *z.App,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    done: bool = false,
    expired: bool = false,
    thread: ?std.Thread = null,

    pub fn start(self: *Watchdog) !void {
        self.thread = try std.Thread.spawn(.{}, wait, .{self});
    }
    pub fn stop(self: *Watchdog) void {
        self.mutex.lock();
        self.done = true;
        self.condition.signal();
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    fn wait(self: *Watchdog) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var timer = std.time.Timer.start() catch unreachable;
        const deadline = 15 * std.time.ns_per_s;
        while (!self.done) {
            const elapsed = timer.read();
            if (elapsed >= deadline) break;
            self.condition.timedWait(&self.mutex, deadline - elapsed) catch {};
        }
        if (!self.done) self.app.post(.{ .context = self, .call = timeout }) catch {};
    }
    fn timeout(ptr: *anyopaque) void {
        const self: *Watchdog = @ptrCast(@alignCast(ptr));
        self.expired = true;
        self.app.quit();
    }
};
