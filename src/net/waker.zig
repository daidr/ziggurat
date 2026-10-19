const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const ws2_32 = std.os.windows.ws2_32;

/// Wakes a worker blocked in `poll` from any thread. A connected loopback TCP
/// pair works with `poll` on both POSIX and Windows sockets; the accepted
/// peer is checked so another local process cannot take its place.
pub const Waker = struct {
    rx: std.net.Stream,
    tx: std.net.Stream,
    signaled: std.atomic.Value(bool) = .init(false),

    pub fn init() !Waker {
        const loopback = try std.net.Address.parseIp4("127.0.0.1", 0);
        var server = try loopback.listen(.{});
        defer server.deinit();
        const tx = try std.net.tcpConnectToAddress(server.listen_address);
        errdefer tx.close();
        var local: posix.sockaddr.in = undefined;
        var length: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(tx.handle, @ptrCast(&local), &length);
        const connection = try server.accept();
        errdefer connection.stream.close();
        if (connection.address.in.sa.port != local.port or connection.address.in.sa.addr != local.addr) return error.WakerPeerMismatch;
        return .{ .rx = connection.stream, .tx = tx };
    }

    pub fn deinit(self: *Waker) void {
        self.rx.close();
        self.tx.close();
        self.* = undefined;
    }

    /// Any thread. Coalesces until the worker drains.
    pub fn wake(self: *Waker) void {
        if (self.signaled.swap(true, .acq_rel)) return;
        const byte = [1]u8{1};
        if (builtin.os.tag == .windows) {
            _ = ws2_32.send(self.tx.handle, &byte, 1, 0);
        } else {
            _ = posix.send(self.tx.handle, &byte, posix.MSG.NOSIGNAL) catch {};
        }
    }

    /// Worker, after `poll` reported `rx` readable.
    pub fn drain(self: *Waker) void {
        self.signaled.store(false, .release);
        var byte: [1]u8 = undefined;
        if (builtin.os.tag == .windows) {
            _ = ws2_32.recv(self.rx.handle, &byte, 1, 0);
        } else {
            _ = posix.recv(self.rx.handle, &byte, 0) catch {};
        }
    }

    pub fn handle(self: *const Waker) posix.socket_t {
        return self.rx.handle;
    }
};

test "waker coalesces and wakes poll" {
    var waker = try Waker.init();
    defer waker.deinit();
    waker.wake();
    waker.wake();
    var fds = [_]posix.pollfd{.{ .fd = waker.handle(), .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&fds, 1000));
    waker.drain();
    fds[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));
}
