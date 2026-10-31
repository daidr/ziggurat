//! Cross-thread wakes through the std.Io the framework uses, with a panic
//! handler that prints the message and a libc backtrace without taking any
//! lock, so a panic in the wake path reports where it happened.
const std = @import("std");

extern "c" fn backtrace(buffer: [*]?*anyopaque, size: c_int) c_int;
extern "c" fn backtrace_symbols_fd(buffer: [*]const ?*anyopaque, size: c_int, fd: c_int) void;

pub const panic = std.debug.FullPanic(report);

fn report(message: []const u8, _: ?usize) noreturn {
    _ = std.c.write(2, "probe panic: ", 13);
    _ = std.c.write(2, message.ptr, message.len);
    _ = std.c.write(2, "\n", 1);
    var frames: [64]?*anyopaque = undefined;
    const count = backtrace(&frames, frames.len);
    backtrace_symbols_fd(&frames, count, 2);
    std.c.abort();
}

fn say(comptime text: []const u8) void {
    _ = std.c.write(2, text ++ "\n", text.len + 1);
}

var threaded: std.Io.Threaded = undefined;
var word: std.atomic.Value(u32) = .init(0);
var event: std.Io.Event = .unset;

fn waiter(io: std.Io) void {
    while (word.load(.acquire) == 0) io.futexWaitUncancelable(u32, &word.raw, 0);
    say("worker: futex woke");
    event.set(io);
    say("worker: event set");
}

pub fn main() !void {
    threaded = .init(std.heap.smp_allocator, .{});
    const io = threaded.io();
    say("wake with no waiter");
    io.futexWake(u32, &word.raw, 1);
    say("spawn worker");
    const thread = try std.Thread.spawn(.{}, waiter, .{io});
    var pause: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&pause, null);
    word.store(1, .release);
    say("main: wake worker");
    io.futexWake(u32, &word.raw, 1);
    event.waitUncancelable(io);
    say("main: event seen");
    thread.join();
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(io);
    mutex.unlock(io);
    say("probe passed");
}
