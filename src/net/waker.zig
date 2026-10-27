const std = @import("std");
const zio = @import("ziggurat_io");

/// Wakes a worker blocked in `zio.net.pollReadable` from any thread. A
/// connected loopback TCP pair can be polled with the transfer's own socket;
/// the accepted peer is checked so another local process cannot take its
/// place.
pub const Waker = struct {
    rx: std.Io.net.Stream,
    tx: std.Io.net.Stream,
    signaled: std.atomic.Value(bool) = .init(false),

    pub fn init() !Waker {
        const io = zio.io();
        const loopback = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try loopback.listen(io, .{});
        defer server.deinit(io);
        const tx = try server.socket.address.connect(io, .{ .mode = .stream });
        errdefer tx.close(io);
        const rx = try server.accept(io);
        errdefer rx.close(io);
        // The connected side reports its local address, the accepted side
        // its peer's.
        if (!tx.socket.address.eql(&rx.socket.address)) return error.WakerPeerMismatch;
        return .{ .rx = rx, .tx = tx };
    }

    pub fn deinit(self: *Waker) void {
        self.rx.close(zio.io());
        self.tx.close(zio.io());
        self.* = undefined;
    }

    /// Any thread. Coalesces until the worker drains.
    pub fn wake(self: *Waker) void {
        if (self.signaled.swap(true, .acq_rel)) return;
        _ = zio.net.send(self.tx.socket.handle, &.{1}) catch {};
    }

    /// Worker, after `poll` reported `rx` readable.
    pub fn drain(self: *Waker) void {
        self.signaled.store(false, .release);
        var byte: [1]u8 = undefined;
        _ = zio.net.receive(self.rx.socket.handle, &byte) catch {};
    }

    pub fn handle(self: *const Waker) std.Io.net.Socket.Handle {
        return self.rx.socket.handle;
    }
};

test "waker coalesces and wakes poll" {
    var waker = try Waker.init();
    defer waker.deinit();
    waker.wake();
    waker.wake();
    var fds = [_]zio.net.PollFd{.{ .handle = waker.handle() }};
    try std.testing.expectEqual(@as(usize, 1), try zio.net.pollReadable(&fds, 1000));
    waker.drain();
    try std.testing.expectEqual(@as(usize, 0), try zio.net.pollReadable(&fds, 0));
}
