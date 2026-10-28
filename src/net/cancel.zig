const std = @import("std");
const zio = @import("ziggurat_io");

/// Cancellation shared between the worker running a transfer and any other
/// thread. A transfer started with `run` executes as a task of the
/// process-wide `std.Io`; `cancel` cancels that task, which ends a blocked
/// resolve, connect, TLS handshake, read or write with `error.Canceled`.
/// A connected socket may also be attached so `cancel` shuts it down, which
/// wakes a worker waiting for it in `poll`.
pub const Cancel = struct {
    mutex: zio.Mutex = .{},
    cancelled: bool = false,
    socket: ?std.Io.net.Socket.Handle = null,
    /// Set while a worker waits in `run` for its task.
    waiter: ?*zio.ResetEvent = null,

    /// Any thread. Idempotent.
    pub fn cancel(self: *Cancel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = true;
        if (self.socket) |socket| shutdownSocket(socket);
        if (self.waiter) |waiter| waiter.set();
    }

    pub fn isCancelled(self: *Cancel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancelled;
    }

    /// Worker. Binds a connected socket until `detach`. Fails without
    /// binding when cancellation already happened.
    pub fn attach(self: *Cancel, socket: std.Io.net.Socket.Handle) error{Cancelled}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.socket == null);
        if (self.cancelled) return error.Cancelled;
        self.socket = socket;
    }

    /// Worker. Must run before the attached socket is closed so a late
    /// `cancel` never touches a released descriptor.
    pub fn detach(self: *Cancel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.socket = null;
    }

    /// Worker. Calls `function` as a task and waits for it, cancelling the
    /// task when `cancel` is called first. `function` must report
    /// cancellation itself, for example by checking `isCancelled` when an
    /// operation fails. Without concurrency the call runs inline and only
    /// the checks inside it observe `cancel`.
    pub fn run(self: *Cancel, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
        const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
        const Task = struct {
            fn call(done: *zio.ResetEvent, inner: @TypeOf(args)) Result {
                defer done.set();
                return @call(.auto, function, inner);
            }
        };
        var done: zio.ResetEvent = .{};
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(self.waiter == null);
            self.waiter = &done;
        }
        defer {
            self.mutex.lock();
            self.waiter = null;
            self.mutex.unlock();
        }
        const io = zio.io();
        var future = io.concurrent(Task.call, .{ &done, args }) catch return @call(.auto, function, args);
        done.wait();
        return if (self.isCancelled()) future.cancel(io) else future.await(io);
    }
};

/// Ends both directions of a connected socket so a peer or a worker waiting
/// in `poll` sees the connection close.
pub fn shutdownSocket(socket: std.Io.net.Socket.Handle) void {
    zio.net.shutdown(socket);
}

test "cancel before attach refuses the socket" {
    var cancel: Cancel = .{};
    cancel.cancel();
    try std.testing.expect(cancel.isCancelled());
    try std.testing.expectError(error.Cancelled, cancel.attach(undefined));
    try std.testing.expect(cancel.socket == null);
}

test "cancel interrupts a task blocked in run" {
    const Blocked = struct {
        fn wait(token: *Cancel) error{ Canceled, Cancelled }!void {
            zio.io().sleep(.fromSeconds(60), .awake) catch |err| {
                if (token.isCancelled()) return error.Cancelled;
                return err;
            };
        }
        fn worker(token: *Cancel, result: *error{ Canceled, Cancelled }!void) void {
            result.* = token.run(wait, .{token});
        }
    };
    var cancel: Cancel = .{};
    var result: error{ Canceled, Cancelled }!void = {};
    const thread = try std.Thread.spawn(.{}, Blocked.worker, .{ &cancel, &result });
    while (true) {
        cancel.mutex.lock();
        const waiting = cancel.waiter != null;
        cancel.mutex.unlock();
        if (waiting) break;
        std.Thread.yield() catch {};
    }
    cancel.cancel();
    thread.join();
    try std.testing.expectError(error.Cancelled, result);
}
