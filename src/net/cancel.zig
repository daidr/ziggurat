const std = @import("std");
const builtin = @import("builtin");

/// Cancellation shared between the worker running a transfer and any other
/// thread. While a transfer's socket is attached, `cancel` shuts the socket
/// down so a worker blocked in a read or write returns promptly. Name
/// resolution, TCP connect and the TLS handshake run before a socket can be
/// attached; cancellation during them takes effect once they return.
pub const Cancel = struct {
    mutex: std.Thread.Mutex = .{},
    cancelled: bool = false,
    socket: ?std.posix.socket_t = null,

    /// Any thread. Idempotent.
    pub fn cancel(self: *Cancel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = true;
        if (self.socket) |socket| shutdownSocket(socket);
    }

    pub fn isCancelled(self: *Cancel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancelled;
    }

    /// Worker. Binds the transfer's socket until `detach`. Fails without
    /// binding when cancellation already happened.
    pub fn attach(self: *Cancel, socket: std.posix.socket_t) error{Cancelled}!void {
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
};

pub fn shutdownSocket(socket: std.posix.socket_t) void {
    std.posix.shutdown(socket, .both) catch {};
}

/// The standard Windows stream writer treats sending after a shutdown as
/// unreachable, but `Cancel` shuts sockets down while the worker may still be
/// writing. Route the connection's socket writes through a sender that reports
/// that case as an ordinary write failure. Other targets map it to an error
/// already. Call on the worker before the socket can be attached.
pub fn guardSends(connection: *std.http.Client.Connection) void {
    if (builtin.os.tag != .windows) return;
    connection.stream_writer.interface.vtable = &guarded_vtable;
}

const guarded_vtable: std.Io.Writer.VTable = .{ .drain = guardedDrain };

fn guardedDrain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const writer: *std.net.Stream.Writer = @alignCast(@fieldParentPtr("interface", io_w));
    const buffered = io_w.buffered();
    if (buffered.len != 0) return io_w.consume(try sendSome(writer, buffered));
    for (data[0 .. data.len - 1]) |bytes| if (bytes.len != 0) return sendSome(writer, bytes);
    const pattern = data[data.len - 1];
    if (splat == 0 or pattern.len == 0) return 0;
    return sendSome(writer, pattern);
}

fn sendSome(writer: *std.net.Stream.Writer, bytes: []const u8) std.Io.Writer.Error!usize {
    const ws2_32 = std.os.windows.ws2_32;
    const len: i32 = @intCast(@min(bytes.len, std.math.maxInt(i32)));
    const sent = ws2_32.send(writer.stream.handle, bytes.ptr, len, 0);
    if (sent == ws2_32.SOCKET_ERROR) {
        writer.err = switch (ws2_32.WSAGetLastError()) {
            .WSAENOBUFS => error.SystemResources,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            else => error.ConnectionResetByPeer,
        };
        return error.WriteFailed;
    }
    return @intCast(sent);
}

test "cancel before attach refuses the socket" {
    var cancel: Cancel = .{};
    cancel.cancel();
    try std.testing.expect(cancel.isCancelled());
    try std.testing.expectError(error.Cancelled, cancel.attach(undefined));
    try std.testing.expect(cancel.socket == null);
}
