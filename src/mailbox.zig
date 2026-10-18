const std = @import("std");

pub const Task = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque) void,
};

/// Bounded MPSC queue. Successful posts transfer execution to the UI thread.
/// Closing is atomic with posting; every accepted task is drained at shutdown.
pub fn Mailbox(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        mutex: std.Thread.Mutex = .{},
        items: [capacity]Task = undefined,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,
        nonempty: std.atomic.Value(bool) = .init(false),

        pub fn post(self: *Self, task: Task) error{ Closed, Full }!bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;
            if (self.len == capacity) return error.Full;
            const needs_wake = self.len == 0;
            self.items[(self.head + self.len) % capacity] = task;
            self.len += 1;
            if (needs_wake) self.nonempty.store(true, .release);
            return needs_wake;
        }

        pub fn pop(self: *Self) ?Task {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == 0) return null;
            const task = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            if (self.len == 0) self.nonempty.store(false, .release);
            return task;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
        }

        pub fn pending(self: *const Self) bool {
            return self.nonempty.load(.acquire);
        }
    };
}

test "bounded FIFO wraps and reports backpressure without dropping accepted work" {
    var queue: Mailbox(2) = .{};
    var values = [_]usize{ 1, 2, 3 };
    const noop = struct {
        fn call(_: *anyopaque) void {}
    }.call;
    try std.testing.expect(try queue.post(.{ .context = &values[0], .call = noop }));
    try std.testing.expect(!try queue.post(.{ .context = &values[1], .call = noop }));
    try std.testing.expectError(error.Full, queue.post(.{ .context = &values[2], .call = noop }));
    try std.testing.expect(queue.pop().?.context == @as(*anyopaque, &values[0]));
    _ = try queue.post(.{ .context = &values[2], .call = noop });
    queue.close();
    try std.testing.expectError(error.Closed, queue.post(.{ .context = &values[0], .call = noop }));
    try std.testing.expect(queue.pop().?.context == @as(*anyopaque, &values[1]));
    try std.testing.expect(queue.pop().?.context == @as(*anyopaque, &values[2]));
    try std.testing.expect(queue.pop() == null);
}

test "concurrent producers execute each accepted task once" {
    const Counter = struct {
        count: usize = 0,
        fn call(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
        fn produce(queue: *Mailbox(256), counter: *@This()) void {
            for (0..64) |_| _ = queue.post(.{ .context = counter, .call = call }) catch unreachable;
        }
    };
    var queue: Mailbox(256) = .{};
    var counter: Counter = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Counter.produce, .{ &queue, &counter });
    for (threads) |thread| thread.join();
    queue.close();
    while (queue.pop()) |task| task.call(task.context);
    try std.testing.expectEqual(256, counter.count);
}

test "closing races active producers and executes only accepted tasks once" {
    const Item = struct {
        accepted: bool = false,
        calls: usize = 0,
        fn call(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
        }
    };
    const Producer = struct {
        queue: *Mailbox(64),
        start: *std.Thread.ResetEvent,
        race: *std.Thread.ResetEvent,
        ready: *std.atomic.Value(usize),
        closed: *std.atomic.Value(usize),
        items: [512]Item = @splat(.{}),
        fn run(self: *@This()) void {
            self.start.wait();
            _ = self.queue.post(.{ .context = &self.items[0], .call = Item.call }) catch return;
            self.items[0].accepted = true;
            _ = self.ready.fetchAdd(1, .release);
            self.race.wait();
            var index: usize = 1;
            while (index < self.items.len) {
                _ = self.queue.post(.{ .context = &self.items[index], .call = Item.call }) catch |err| switch (err) {
                    error.Full => {
                        std.Thread.yield() catch {};
                        continue;
                    },
                    error.Closed => {
                        _ = self.closed.fetchAdd(1, .release);
                        return;
                    },
                };
                self.items[index].accepted = true;
                index += 1;
            }
        }
    };
    var queue: Mailbox(64) = .{};
    var start: std.Thread.ResetEvent = .{};
    var race: std.Thread.ResetEvent = .{};
    var ready: std.atomic.Value(usize) = .init(0);
    var closed: std.atomic.Value(usize) = .init(0);
    var producers: [4]Producer = undefined;
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        queue.close();
        start.set();
        race.set();
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&producers, &threads) |*producer, *thread| {
        producer.* = .{ .queue = &queue, .start = &start, .race = &race, .ready = &ready, .closed = &closed };
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
        spawned += 1;
    }
    start.set();
    while (ready.load(.acquire) != threads.len) std.Thread.yield() catch {};
    race.set();
    var executed: usize = 0;
    while (executed < 256) {
        if (queue.pop()) |task| {
            task.call(task.context);
            executed += 1;
        } else std.Thread.yield() catch {};
    }
    queue.close();
    for (threads) |thread| thread.join();
    spawned = 0;
    while (queue.pop()) |task| {
        task.call(task.context);
        executed += 1;
    }
    var accepted: usize = 0;
    for (producers) |producer| for (producer.items) |item| {
        try std.testing.expectEqual(@as(usize, @intFromBool(item.accepted)), item.calls);
        accepted += @intFromBool(item.accepted);
    };
    try std.testing.expectEqual(threads.len, closed.load(.acquire));
    try std.testing.expectEqual(accepted, executed);
    try std.testing.expect(!queue.pending());
}
