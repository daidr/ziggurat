const std = @import("std");

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

test "cancel before attach refuses the socket" {
    var cancel: Cancel = .{};
    cancel.cancel();
    try std.testing.expect(cancel.isCancelled());
    try std.testing.expectError(error.Cancelled, cancel.attach(undefined));
    try std.testing.expect(cancel.socket == null);
}
