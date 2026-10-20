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
    // A Windows shutdown does not end a receive already waiting for data;
    // aborting the socket's pending I/O does.
    if (builtin.os.tag == .windows) _ = std.os.windows.kernel32.CancelIoEx(@ptrCast(socket), null);
}

/// The standard Windows stream writer treats sending after a shutdown as
/// unreachable, and its reader treats an aborted receive the same way, but
/// `Cancel` shuts sockets down and aborts their I/O while the worker may be
/// writing or reading. Route the connection's socket I/O through functions
/// that report those cases as ordinary failures. Other targets map them to
/// errors already. Call on the worker before the socket can be attached.
pub fn guard(connection: *std.http.Client.Connection) void {
    if (builtin.os.tag != .windows) return;
    connection.stream_writer.interface.vtable = &guarded_vtable;
    connection.stream_reader.interface_state.vtable = &guarded_reader_vtable;
}

const guarded_reader_vtable: std.Io.Reader.VTable = .{ .stream = guardedStream, .readVec = guardedReadVec };

fn guardedStream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const dest = limit.slice(try io_w.writableSliceGreedy(1));
    var bufs: [1][]u8 = .{dest};
    const n = try guardedReadVec(io_r, &bufs);
    io_w.advance(n);
    return n;
}

fn guardedReadVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
    const ws2_32 = std.os.windows.ws2_32;
    const reader: *std.net.Stream.Reader = @alignCast(@fieldParentPtr("interface_state", io_r));
    var iovecs: [8]ws2_32.WSABUF = undefined;
    const bufs_n, const data_size = try io_r.writableVectorWsa(&iovecs, data);
    const n = receiveSome(reader, iovecs[0..bufs_n]) catch |err| {
        reader.error_state = err;
        return error.ReadFailed;
    };
    if (n == 0) return error.EndOfStream;
    if (n > data_size) {
        io_r.end += n - data_size;
        return data_size;
    }
    return n;
}

fn receiveSome(reader: *std.net.Stream.Reader, bufs: []std.os.windows.ws2_32.WSABUF) std.net.Stream.ReadError!u32 {
    const windows = std.os.windows;
    const ws2_32 = windows.ws2_32;
    const handle = reader.net_stream.handle;
    var flags: u32 = 0;
    var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
    var n: u32 = 0;
    if (ws2_32.WSARecv(handle, bufs.ptr, @intCast(bufs.len), &n, &flags, &overlapped, null) == ws2_32.SOCKET_ERROR) {
        var failure = ws2_32.WSAGetLastError();
        if (failure == .WSA_IO_PENDING) {
            var result_flags: u32 = undefined;
            if (ws2_32.WSAGetOverlappedResult(handle, &overlapped, &n, windows.TRUE, &result_flags) != windows.FALSE) return n;
            failure = ws2_32.WSAGetLastError();
        }
        return switch (failure) {
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENOTCONN => error.SocketNotConnected,
            // Aborted, shut down, reset or timed out.
            else => error.ConnectionResetByPeer,
        };
    }
    return n;
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
