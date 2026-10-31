const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");

/// How plugin workers reach the main thread: `App.post`, or a test queue.
pub const Post = struct {
    context: *anyopaque,
    post: *const fn (*anyopaque, z.Task) error{ Full, Closed }!void,

    pub fn app(target: *z.App) Post {
        return .{ .context = target, .post = postApp };
    }

    fn postApp(context: *anyopaque, task: z.Task) error{ Full, Closed }!void {
        const target: *z.App = @ptrCast(@alignCast(context));
        target.post(task) catch |err| return switch (err) {
            error.Full => error.Full,
            else => error.Closed,
        };
    }
};

/// Wakes the main thread to collect what workers produced. At most one drain
/// task is posted at a time, so a plugin holds one mailbox slot however much
/// work completes; the drain itself reads the plugin's own state.
pub const Outbox = struct {
    post: Post,
    drain: z.Task,
    mutex: zio.Mutex = .{},
    scheduled: bool = false,
    stopped: bool = false,

    /// Worker. Ensures a drain runs after the caller's last change. A full
    /// mailbox is retried on the worker; a closed one ends the outbox.
    pub fn notify(self: *Outbox) void {
        self.mutex.lock();
        if (self.scheduled or self.stopped) {
            self.mutex.unlock();
            return;
        }
        self.scheduled = true;
        self.mutex.unlock();
        while (true) {
            self.post.post(self.post.context, self.drain) catch |err| switch (err) {
                error.Full => {
                    zio.sleep(std.time.ns_per_ms);
                    self.mutex.lock();
                    const stopped = self.stopped;
                    self.mutex.unlock();
                    if (!stopped) continue;
                    return;
                },
                error.Closed => {
                    self.stop();
                    return;
                },
            };
            return;
        }
    }

    /// Main thread, first thing in the drain: changes from now on schedule
    /// another drain.
    pub fn begin(self: *Outbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scheduled = false;
    }

    /// Any thread. No drain is posted afterwards.
    pub fn stop(self: *Outbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopped = true;
    }
};

test "an outbox posts once until the drain begins and stops on a closed mailbox" {
    const Counter = struct {
        runs: usize = 0,
        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.runs += 1;
        }
    };
    var queue: @import("testing.zig").Queue = .{};
    var counter: Counter = .{};
    var outbox: Outbox = .{ .post = queue.poster(), .drain = .{ .context = &counter, .call = Counter.run } };
    outbox.notify();
    outbox.notify();
    try std.testing.expectEqual(1, queue.len);
    outbox.begin();
    outbox.notify();
    try std.testing.expectEqual(2, queue.len);
    queue.closed = true;
    outbox.begin();
    outbox.notify();
    try std.testing.expect(outbox.stopped);
    outbox.begin();
    outbox.notify();
    try std.testing.expectEqual(2, queue.len);
}
