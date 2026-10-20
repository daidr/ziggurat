//! A program running on a pseudo-terminal, read and written by workers of
//! its own so the main thread never waits on it. Output collects in a
//! bounded buffer and reaches the main thread through `App.post` in bounded
//! chunks; while the buffer is full the reader stops reading, so a program
//! writing faster than the screen keeps up blocks on its own writes.
//! Input queues in another bounded buffer: `write` takes all of the bytes
//! or returns `Full` without taking any.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const pty = @import("pty.zig");

pub const Size = pty.Size;
pub const Command = pty.Command;
pub const Exit = pty.Exit;

/// Receives the session's output and its end on the App's main thread.
pub const Sink = struct {
    context: *anyopaque,
    /// Output from the program, borrowed for the call.
    output: *const fn (*anyopaque, []const u8) void,
    /// The program ended and all its output was delivered. Called once,
    /// unless the session is closed first.
    exited: *const fn (*anyopaque, Exit) void,
};

pub const Options = struct {
    /// Output waiting for the main thread.
    output_bytes: usize = 256 * 1024,
    /// Input waiting for the program.
    input_bytes: usize = 64 * 1024,
    /// Most output handed to the sink per posted task, so input and paint
    /// interleave with a flood of output.
    chunk_bytes: usize = 32 * 1024,
};

/// Sessions whose workers or memory are still alive, closed or not.
var live = std.atomic.Value(usize).init(0);
pub fn liveSessions() usize {
    return live.load(.acquire);
}

const Ring = struct {
    bytes: []u8,
    head: usize = 0,
    len: usize = 0,

    fn free(self: *const Ring) usize {
        return self.bytes.len - self.len;
    }
    /// The contiguous free space after the data.
    fn tail(self: *Ring) []u8 {
        const at = (self.head + self.len) % self.bytes.len;
        const end = if (at >= self.head and self.len < self.bytes.len) self.bytes.len else self.head;
        return self.bytes[at..end];
    }
    fn commit(self: *Ring, n: usize) void {
        self.len += n;
    }
    fn push(self: *Ring, data: []const u8) void {
        var rest = data;
        while (rest.len > 0) {
            const space = self.tail();
            const n = @min(space.len, rest.len);
            @memcpy(space[0..n], rest[0..n]);
            self.len += n;
            rest = rest[n..];
        }
    }
    fn take(self: *Ring, out: []u8) usize {
        var n: usize = 0;
        while (n < out.len and self.len > 0) {
            const run = @min(self.len, self.bytes.len - self.head, out.len - n);
            @memcpy(out[n..][0..run], self.bytes[self.head..][0..run]);
            self.head = (self.head + run) % self.bytes.len;
            self.len -= run;
            n += run;
        }
        if (self.len == 0) self.head = 0;
        return n;
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    sink: Sink,
    pty: pty.Pty,
    options: Options,
    refs: std.atomic.Value(usize),

    mutex: std.Thread.Mutex = .{},
    /// Signaled when output space frees, input arrives or the session closes.
    changed: std.Thread.Condition = .{},
    output: Ring,
    input: Ring,
    /// Main-thread copy of a chunk while the sink reads it.
    scratch: []u8,
    closed: bool = false,
    posted: bool = false,
    app_closed: bool = false,
    /// The reader saw the end of output.
    eof: bool = false,
    exit: ?Exit = null,
    exit_delivered: bool = false,
    writer_done: bool = false,
    stop_signal: StopSignal,
    /// Reader-only: when closing began, and whether the program ended
    /// before its output did.
    closing_since: i64 = 0,
    exited_early: bool = false,

    /// Start `command` on a new pseudo-terminal. Call on the App's main
    /// thread; `allocator` must be safe to use from any thread, since the
    /// last worker to finish frees the session.
    pub fn spawn(allocator: std.mem.Allocator, app: *z.App, command: Command, sink: Sink, options: Options) !*Session {
        app.assertOwner();
        const self = try create(allocator, app, command, sink, options);
        _ = live.fetchAdd(1, .acq_rel);
        // From here the workers own their references; a failed start closes
        // the session and lets those that started finish.
        inline for (.{ readMain, writeMain } ++ if (builtin.os.tag == .windows) .{waitMain} else .{}) |entry| {
            self.retain();
            const thread = std.Thread.spawn(.{}, entry, .{self}) catch |err| {
                self.release();
                self.close();
                return err;
            };
            thread.detach();
        }
        return self;
    }

    fn create(allocator: std.mem.Allocator, app: *z.App, command: Command, sink: Sink, options: Options) !*Session {
        if (options.output_bytes == 0 or options.input_bytes == 0 or options.chunk_bytes == 0) return error.InvalidOptions;
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        const output = try allocator.alloc(u8, options.output_bytes);
        errdefer allocator.free(output);
        const input = try allocator.alloc(u8, options.input_bytes);
        errdefer allocator.free(input);
        const scratch = try allocator.alloc(u8, options.chunk_bytes);
        errdefer allocator.free(scratch);
        var stop = try StopSignal.init();
        errdefer stop.deinit();
        self.* = .{
            .allocator = allocator,
            .app = app,
            .sink = sink,
            .pty = try pty.Pty.spawn(allocator, command),
            .options = options,
            .refs = .init(1),
            .output = .{ .bytes = output },
            .input = .{ .bytes = input },
            .scratch = scratch,
            .stop_signal = stop,
        };
        return self;
    }

    /// Queue `bytes` for the program, all or nothing. Main thread.
    pub fn write(self: *Session, bytes: []const u8) error{ Full, Closed }!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed or self.writer_done) return error.Closed;
        if (bytes.len > self.input.free()) return error.Full;
        self.input.push(bytes);
        self.changed.broadcast();
    }

    /// Room for input right now.
    pub fn writable(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.input.free();
    }

    /// Tell the program the terminal's new size. Main thread.
    pub fn resize(self: *Session, size: Size) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed or self.exit != null) return;
        self.pty.resize(size);
    }

    /// Whether the program is still running, as far as the workers know.
    pub fn running(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exit == null;
    }

    /// The program's process id.
    pub fn processId(self: *const Session) u32 {
        return @intCast(self.pty.pid);
    }

    /// Stop the program and let go of the session without waiting for it.
    /// The sink is not called again; workers end the program, first asking
    /// on Linux (SIGHUP) and then forcing it, and free the session when they
    /// finish. Call on the main thread before the App is deinitialized.
    pub fn close(self: *Session) void {
        self.mutex.lock();
        const was_closed = self.closed;
        self.closed = true;
        self.changed.broadcast();
        self.mutex.unlock();
        if (!was_closed) {
            self.stop_signal.raise();
            self.release();
        }
    }

    fn retain(self: *Session) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }
    fn release(self: *Session) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        self.pty.close();
        self.stop_signal.deinit();
        allocator.free(self.output.bytes);
        allocator.free(self.input.bytes);
        allocator.free(self.scratch);
        allocator.destroy(self);
        _ = live.fetchSub(1, .acq_rel);
    }

    /// Post delivery unless one is queued. Mutex held, so a session closed
    /// on the main thread never posts again.
    fn schedule(self: *Session) void {
        if (self.posted or self.closed or self.app_closed) return;
        self.retain();
        self.app.post(.{ .context = self, .call = deliver }) catch |err| {
            // Full is retried by the reader; Closed means nothing runs on
            // the main thread any more.
            if (err == error.Closed) self.app_closed = true;
            _ = self.refs.fetchSub(1, .acq_rel);
            return;
        };
        self.posted = true;
    }

    fn deliver(context: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        defer self.release();
        self.mutex.lock();
        self.posted = false;
        if (self.closed) {
            self.mutex.unlock();
            return;
        }
        const n = self.output.take(self.scratch);
        const finished = self.eof and self.exit != null and self.output.len == 0 and !self.exit_delivered;
        if (finished) self.exit_delivered = true;
        const exit = self.exit;
        self.changed.broadcast();
        self.mutex.unlock();
        if (n > 0) self.sink.output(self.sink.context, self.scratch[0..n]);
        // The sink may have closed the session; the posted reference keeps
        // it alive until this returns.
        self.mutex.lock();
        const closed = self.closed;
        if (!closed and !finished and (self.output.len > 0 or (self.eof and self.exit != null))) self.schedule();
        self.mutex.unlock();
        if (finished and !closed) self.sink.exited(self.sink.context, exit.?);
    }

    // ---- Workers -----------------------------------------------------------

    fn readMain(self: *Session) void {
        defer self.release();
        self.readLoop();
        // Stay until the main thread took everything and the exit, retrying
        // posts the queue had no room for.
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.closed and !self.app_closed and !self.exit_delivered) {
            if (self.exit != null and !self.posted) self.schedule();
            self.changed.timedWait(&self.mutex, 50 * std.time.ns_per_ms) catch {};
        }
    }

    fn readLoop(self: *Session) void {
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            // Wait for room unless closing, when output is dropped.
            self.mutex.lock();
            while (!self.closed and !self.app_closed and self.output.free() == 0) {
                if (!self.posted) self.schedule();
                self.changed.timedWait(&self.mutex, 50 * std.time.ns_per_ms) catch {};
            }
            const discard = self.closed or self.app_closed;
            const killing = self.closed;
            const room = if (discard) buffer.len else @min(buffer.len, self.output.free());
            self.mutex.unlock();

            const n = self.readSome(buffer[0..room], killing) orelse continue;
            if (n == 0) break;
            self.mutex.lock();
            if (!self.closed and !self.app_closed) {
                self.output.push(buffer[0..n]);
                self.schedule();
            }
            self.mutex.unlock();
        }
        const exit = self.finish();
        self.mutex.lock();
        self.eof = true;
        if (self.exit == null) self.exit = exit;
        self.changed.broadcast();
        self.mutex.unlock();
    }

    fn writeMain(self: *Session) void {
        defer self.release();
        var buffer: [4096]u8 = undefined;
        while (true) {
            self.mutex.lock();
            while (!self.closed and self.input.len == 0 and self.exit == null) self.changed.wait(&self.mutex);
            if (self.closed or self.exit != null) {
                self.writer_done = true;
                self.mutex.unlock();
                return;
            }
            const n = self.input.take(&buffer);
            self.changed.broadcast();
            self.mutex.unlock();
            if (!self.writeAll(buffer[0..n])) {
                self.mutex.lock();
                self.writer_done = true;
                self.mutex.unlock();
                return;
            }
        }
    }

    // ---- Platform parts ----------------------------------------------------

    const StopSignal = if (builtin.os.tag == .windows) WindowsStop else PipeStop;

    /// Read what is there; null to look again, 0 at the end of output.
    /// `killing` once the owner closed the session.
    fn readSome(self: *Session, buffer: []u8, killing: bool) ?usize {
        if (builtin.os.tag == .windows) {
            return self.pty.read(buffer) catch 0;
        } else {
            const posix = std.posix;
            if (killing and self.closing_since == 0) {
                // Ask the program to hang up, then keep draining.
                self.closing_since = std.time.milliTimestamp();
                self.pty.signal(posix.SIG.HUP);
            }
            // The program ended while something else keeps the terminal open:
            // take what is left without waiting for more.
            if (self.exited_early) return self.pty.read(buffer) catch 0;
            var fds = [_]posix.pollfd{
                .{ .fd = self.pty.master, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_signal.fds[0], .events = posix.POLL.IN, .revents = 0 },
            };
            // Once closing the stop signal stays raised; only the PTY matters.
            const watched: []posix.pollfd = if (killing) fds[0..1] else &fds;
            const ready = posix.poll(watched, if (killing) 100 else 250) catch return 0;
            if (killing) {
                if (ready == 0) return self.escalate();
            } else if (fds[1].revents != 0) {
                return null;
            } else if (ready == 0) {
                if (self.pty.wait(false)) |exit| {
                    self.mutex.lock();
                    self.exit = exit;
                    self.mutex.unlock();
                    self.exited_early = true;
                }
                return null;
            }
            return self.pty.read(buffer) catch |err| switch (err) {
                error.WouldBlock => null,
                else => 0,
            };
        }
    }

    /// A closed program that has not hung up after a while is killed; the
    /// read ends once it is gone or a while later regardless.
    fn escalate(self: *Session) ?usize {
        const waited = std.time.milliTimestamp() - self.closing_since;
        if (self.pty.wait(false)) |exit| {
            self.mutex.lock();
            self.exit = exit;
            self.mutex.unlock();
            return 0;
        }
        if (waited > 500) self.pty.signal(std.posix.SIG.KILL);
        if (waited > 2000) return 0;
        return null;
    }

    /// The program's exit, once its output ended.
    fn finish(self: *Session) ?Exit {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (builtin.os.tag == .windows) {
            // The waiter reports the exit.
            while (self.exit == null) self.changed.wait(&self.mutex);
            return self.exit;
        } else {
            if (self.exit) |known| return known;
            // The secondary side closed, so the program has ended or is
            // about to; one closed by the owner may need forcing.
            if (self.pty.wait(false)) |exit| return exit;
            if (self.closed) self.pty.signal(std.posix.SIG.KILL);
            self.mutex.unlock();
            defer self.mutex.lock();
            return self.pty.wait(true);
        }
    }

    fn writeAll(self: *Session, bytes: []const u8) bool {
        var rest = bytes;
        while (rest.len > 0) {
            if (builtin.os.tag == .windows) {
                const n = self.pty.write(rest) catch return false;
                rest = rest[n..];
            } else {
                const posix = std.posix;
                const n = self.pty.write(rest) catch |err| switch (err) {
                    error.WouldBlock => {
                        var fds = [_]posix.pollfd{
                            .{ .fd = self.pty.master, .events = posix.POLL.OUT, .revents = 0 },
                            .{ .fd = self.stop_signal.fds[0], .events = posix.POLL.IN, .revents = 0 },
                        };
                        _ = posix.poll(&fds, 250) catch return false;
                        if (fds[1].revents != 0) return false;
                        self.mutex.lock();
                        const ended = self.exit != null;
                        self.mutex.unlock();
                        if (ended) return false;
                        continue;
                    },
                    else => return false,
                };
                rest = rest[n..];
            }
        }
        return true;
    }

    /// Windows: wait for the program to end or the session to close, then
    /// close the console so the reader sees the end of its output.
    fn waitMain(self: *Session) void {
        defer self.release();
        const stopped = self.stop_signal.wait(self.pty.process);
        if (stopped) self.pty.terminate();
        const exit = self.pty.wait(true) orelse Exit{ .code = 1 };
        self.mutex.lock();
        self.exit = exit;
        self.changed.broadcast();
        self.mutex.unlock();
        self.pty.closeConsole();
    }
};

/// A pipe whose read end becomes readable for good once raised.
const PipeStop = struct {
    fds: [2]std.posix.fd_t,
    fn init() !PipeStop {
        return .{ .fds = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) };
    }
    fn raise(self: *PipeStop) void {
        _ = std.posix.write(self.fds[1], "x") catch {};
    }
    fn deinit(self: *PipeStop) void {
        std.posix.close(self.fds[0]);
        std.posix.close(self.fds[1]);
    }
};

const WindowsStop = struct {
    event: std.os.windows.HANDLE,
    extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual: std.os.windows.BOOL, initial: std.os.windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
    extern "kernel32" fn SetEvent(event: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn CloseHandle(handle: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const std.os.windows.HANDLE, all: std.os.windows.BOOL, milliseconds: u32) callconv(.winapi) u32;
    fn init() !WindowsStop {
        return .{ .event = CreateEventW(null, 1, 0, null) orelse return error.SystemResources };
    }
    fn raise(self: *WindowsStop) void {
        _ = SetEvent(self.event);
    }
    /// True when the stop was raised before the process ended.
    fn wait(self: *WindowsStop, process: std.os.windows.HANDLE) bool {
        const handles = [_]std.os.windows.HANDLE{ process, self.event };
        return WaitForMultipleObjects(2, &handles, 0, 0xffffffff) == 1;
    }
    fn deinit(self: *WindowsStop) void {
        _ = CloseHandle(self.event);
    }
};

test "the ring wraps around" {
    var storage: [8]u8 = undefined;
    var ring: Ring = .{ .bytes = &storage };
    ring.push("abcdef");
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), ring.take(out[0..4]));
    ring.push("ghijkl");
    try std.testing.expectEqual(@as(usize, 0), ring.free());
    try std.testing.expectEqual(@as(usize, 8), ring.take(&out));
    try std.testing.expectEqualStrings("efghijkl", &out);
    try std.testing.expectEqual(@as(usize, 8), ring.tail().len);
}

const Collector = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    exit: ?Exit = null,
    exits: usize = 0,
    fn output(context: *anyopaque, bytes: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        const n = @min(bytes.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }
    fn exited(context: *anyopaque, exit: Exit) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        self.exit = exit;
        self.exits += 1;
    }
    fn sink(self: *Collector) Sink {
        return .{ .context = self, .output = output, .exited = exited };
    }
};

fn settle(app: *z.App, done: anytype) !void {
    var waited: usize = 0;
    while (!done.check()) : (waited += 1) {
        if (waited > 1000) return error.Timeout;
        try app.dispatch();
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

test "a session echoes input, delivers all output in order and reports the exit once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var collector: Collector = .{};
    // A small output buffer and chunk exercise backpressure and reposting.
    const session = try Session.spawn(std.testing.allocator, app, .{ .argv = &.{ "/bin/sh", "-c", "read line; i=0; while [ $i -lt 300 ]; do printf '%03d\\n' $i; i=$((i+1)); done; printf \"got:$line\"; exit 7" } }, collector.sink(), .{ .output_bytes = 64, .chunk_bytes = 16 });
    try session.write("hello\n");
    const Done = struct {
        c: *Collector,
        fn check(self: @This()) bool {
            return self.c.exits > 0;
        }
    };
    try settle(app, Done{ .c = &collector });
    try std.testing.expectEqual(Exit{ .code = 7 }, collector.exit.?);
    try std.testing.expectEqual(@as(usize, 1), collector.exits);
    // The terminal echoes the input line before the program answers it.
    const text = collector.bytes[0..collector.len];
    try std.testing.expect(std.mem.startsWith(u8, text, "hello\r\n000\r\n001\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, text, "299\r\ngot:hello"));
    try std.testing.expectEqual(@as(usize, 7 + 300 * 5 + 9), text.len);
    try std.testing.expectError(error.Closed, session.write("x"));
    session.close();
    const Gone = struct {
        fn check(_: @This()) bool {
            return liveSessions() == 0;
        }
    };
    try settle(app, Gone{});
}

test "closing a session ends a program that keeps running" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var collector: Collector = .{};
    // The program ignores the hangup, so closing has to force it.
    const session = try Session.spawn(std.testing.allocator, app, .{ .argv = &.{ "/bin/sh", "-c", "trap '' HUP; echo ready; while :; do sleep 1; done" } }, collector.sink(), .{});
    const Ready = struct {
        c: *Collector,
        fn check(self: @This()) bool {
            return std.mem.indexOf(u8, self.c.bytes[0..self.c.len], "ready") != null;
        }
    };
    try settle(app, Ready{ .c = &collector });
    try session.write("ignored\n");
    session.close();
    const Gone = struct {
        fn check(_: @This()) bool {
            return liveSessions() == 0;
        }
    };
    try settle(app, Gone{});
    try std.testing.expectEqual(@as(usize, 0), collector.exits);
}
