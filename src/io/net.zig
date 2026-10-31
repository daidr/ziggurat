//! Socket readiness and raw socket calls on `std.Io.net` handles, for loops
//! that wait on several sockets at once.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Handle = std.Io.net.Socket.Handle;

pub const PollFd = struct {
    handle: Handle,
    /// Set by `pollReadable` when a read would not block: data, end of
    /// stream or a failure is waiting.
    ready: bool = false,
};

pub const PollError = error{ SystemResources, Unexpected };

/// Waits until at least one socket in `fds` is readable or `timeout_ms`
/// passes; `null` waits without limit. Returns how many are readable.
pub fn pollReadable(fds: []PollFd, timeout_ms: ?u32) PollError!usize {
    for (fds) |*fd| fd.ready = false;
    if (builtin.os.tag == .windows) return pollWindows(fds, timeout_ms);
    const posix = std.posix;
    var native: [4]posix.pollfd = undefined;
    std.debug.assert(fds.len <= native.len);
    for (fds, native[0..fds.len]) |fd, *entry| entry.* = .{ .fd = fd.handle, .events = posix.POLL.IN, .revents = 0 };
    const timeout: i32 = if (timeout_ms) |ms| @intCast(@min(ms, std.math.maxInt(i32))) else -1;
    const count = posix.poll(native[0..fds.len], timeout) catch |err| switch (err) {
        error.SystemResources => return error.SystemResources,
        else => return error.Unexpected,
    };
    for (fds, native[0..fds.len]) |*fd, entry| fd.ready = entry.revents != 0;
    return count;
}

// The AFD driver's poll request, as Winsock issues it for `WSAPoll`.
const AfdPollHandleInfo = extern struct {
    handle: std.os.windows.HANDLE,
    events: std.os.windows.ULONG,
    status: std.os.windows.NTSTATUS,
};

fn AfdPollInfo(comptime count: usize) type {
    return extern struct {
        timeout: std.os.windows.LARGE_INTEGER,
        count: std.os.windows.ULONG,
        exclusive: std.os.windows.ULONG,
        handles: [count]AfdPollHandleInfo,
    };
}

const afd_poll_receive = 0x0001;
const afd_poll_disconnect = 0x0008;
const afd_poll_abort = 0x0010;
const afd_poll_local_close = 0x0020;
const afd_poll_accept = 0x0080;
const afd_poll_readable = afd_poll_receive | afd_poll_disconnect | afd_poll_abort | afd_poll_local_close | afd_poll_accept;

fn pollWindows(fds: []PollFd, timeout_ms: ?u32) PollError!usize {
    const windows = std.os.windows;
    var info: AfdPollInfo(4) = undefined;
    std.debug.assert(fds.len > 0 and fds.len <= info.handles.len);
    // A relative timeout is negative, in 100 ns units.
    info.timeout = if (timeout_ms) |ms| -@as(i64, ms) * 10_000 else std.math.maxInt(i64);
    info.count = @intCast(fds.len);
    info.exclusive = 0;
    for (fds, info.handles[0..fds.len]) |fd, *entry| entry.* = .{ .handle = fd.handle, .events = afd_poll_readable, .status = .SUCCESS };
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    // The sockets are opened for asynchronous I/O and no event is given, so
    // the handle the request is issued on is signaled when it completes.
    var status = windows.ntdll.NtDeviceIoControlFile(fds[0].handle, null, null, null, &iosb, windows.IOCTL.AFD.POLL, &info, @sizeOf(@TypeOf(info)), &info, @sizeOf(@TypeOf(info)));
    if (status == .PENDING) {
        switch (windows.ntdll.NtWaitForSingleObject(fds[0].handle, .FALSE, null)) {
            .SUCCESS => {},
            else => return error.Unexpected,
        }
        status = iosb.u.Status;
    }
    switch (status) {
        .SUCCESS => {},
        .TIMEOUT => return 0,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => return error.Unexpected,
    }
    var ready: usize = 0;
    for (info.handles[0..info.count]) |entry| {
        if (entry.events & afd_poll_readable == 0) continue;
        for (fds) |*fd| if (fd.handle == entry.handle and !fd.ready) {
            fd.ready = true;
            ready += 1;
        };
    }
    return ready;
}

/// Ends both directions of a connected socket. A peer and a local waiter in
/// `pollReadable` see the connection close.
pub fn shutdown(handle: Handle) void {
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = handle, .address = undefined } };
    const io = root.io();
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    stream.shutdown(io, .both) catch {};
}

/// Writes some of `bytes` to a connected socket.
pub fn send(handle: Handle, bytes: []const u8) !usize {
    const io = root.io();
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return try (try io.operate(.{ .net_write = .{ .socket_handle = handle, .data = &.{bytes} } })).net_write;
}

/// Reads some bytes from a connected socket; 0 at end of stream.
pub fn receive(handle: Handle, buffer: []u8) !usize {
    const io = root.io();
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var data: [1][]u8 = .{buffer};
    const result = try (try io.operate(.{ .net_read = .{ .socket_handle = handle, .data = &data } })).net_read;
    return result.data_len;
}

/// Writes all of `bytes` to a connected socket.
pub fn sendAll(handle: Handle, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) sent += try send(handle, bytes[sent..]);
}
