const std = @import("std");
const http = @import("ziggurat_http_response");
const files = @import("ziggurat_file_stream");

pub const capacity: u8 = 8;
pub const process_capacity: u32 = 32;
pub const chunk_bytes = files.chunk_bytes;
pub const maximum_memory_bytes = 16 * 1024 * 1024;
pub const maximum_owned_bytes = 256 * 1024 * 1024;
pub const NativeServer = opaque {};

pub const Limits = struct {
    max_pending: u8 = capacity,
    /// Project allocations, candidate and borrowed-input reservations. Native
    /// HTTP/TLS parser, GObject, and header internals are separately disclosed.
    bytes: usize = 64 * 1024 * 1024,
    max_response_bytes: u32 = maximum_memory_bytes,
    max_file_bytes: u64 = files.hard_max_bytes,
    max_file_streams: u8 = files.consumer_capacity,
    pub fn validate(self: Limits) !void {
        if (self.max_pending == 0 or self.max_pending > capacity or self.bytes < 64 * 1024 or self.bytes > maximum_owned_bytes or
            self.max_response_bytes == 0 or self.max_response_bytes > maximum_memory_bytes or self.max_file_bytes == 0 or
            self.max_file_bytes > files.hard_max_bytes or self.max_file_streams == 0 or self.max_file_streams > files.consumer_capacity) return error.InvalidEndpointLimits;
    }
};

pub const Head = struct {
    status: u16 = 200,
    mime: []const u8 = "application/octet-stream",
    headers: []const http.Header = &.{},
    /// Memory HEAD responses may state their representation length without
    /// allocating that representation. File responses always use native length.
    length: u64 = 0,
    pub fn validate(self: Head, maximum: u64) !void {
        try http.validateResponse(.{ .status = self.status, .mime = self.mime, .headers = self.headers }, 0);
        if (self.length > maximum) return error.ResourceTooLarge;
        if (self.length != 0 and (self.status == 204 or self.status == 205 or self.status == 304)) return error.UnexpectedResponseBody;
    }
};

/// Acceptance consumes the submitted value, including when a concurrent cancel
/// or callback closes the endpoint. It does not prove delivery to the peer.
pub const Acceptance = enum { accepted, accepted_cancelled };
pub const Receipt = struct {
    state: Acceptance,
    /// Optional owning reference to the existing file cancellation authority.
    /// This retains neither the HTTP endpoint nor an HTTP/file physical slot.
    control: ?files.Control = null,
    pub fn deinit(self: *Receipt) void {
        var control = self.control;
        self.control = null;
        if (control) |*value| value.deinit();
    }
};
pub const ResponseOptions = struct { file_control: bool = false };
pub const CloseResult = enum { closed, deferred };

pub const NativeCounts = struct {
    owners: u32 = 0,
    gates: u32 = 0,
    operations: u32 = 0,
    tickets: u32 = 0,
    requested_bytes: usize = 0,
    /// One bounded chunk potentially copied by libsoup per active body. This
    /// is a conservative known payload reservation, not a total SDK RSS bound.
    queued_payload_reservation: usize = 0,
};
pub const Stats = struct {
    requested_bytes: usize,
    peak_reserved_bytes: usize,
    borrowed_input_bytes: usize,
    queued_payload_reservation: usize,
    physical_pending: u32,
    accepting: bool,
};

test "endpoint limits stay distinct from the shared file physical authority" {
    try (Limits{}).validate();
    try std.testing.expectEqual(@as(u32, 32), files.process_capacity);
    try std.testing.expectEqual(@as(u32, 32), process_capacity);
    try std.testing.expectError(error.InvalidEndpointLimits, (Limits{ .max_pending = capacity + 1 }).validate());
    try std.testing.expectError(error.InvalidEndpointLimits, (Limits{ .bytes = 65535 }).validate());
    try std.testing.expectError(error.InvalidEndpointLimits, (Limits{ .bytes = maximum_owned_bytes + 1 }).validate());
    try std.testing.expectError(error.InvalidEndpointLimits, (Limits{ .max_file_bytes = files.hard_max_bytes + 1 }).validate());
    try std.testing.expectError(error.InvalidEndpointLimits, (Limits{ .max_file_streams = files.consumer_capacity + 1 }).validate());
}

test "HEAD metadata validates without a representation allocation" {
    try (Head{ .length = files.hard_max_bytes }).validate(files.hard_max_bytes);
    try std.testing.expectError(error.ResourceTooLarge, (Head{ .length = files.hard_max_bytes + 1 }).validate(files.hard_max_bytes));
    try std.testing.expectError(error.UnexpectedResponseBody, (Head{ .status = 204, .length = 1 }).validate(files.hard_max_bytes));
    try std.testing.expectError(error.ReservedResponseHeader, (Head{ .headers = &.{.{ .name = "Content-Length", .value = "wrong" }} }).validate(files.hard_max_bytes));
}
