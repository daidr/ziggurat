const std = @import("std");
const builtin = @import("builtin");
const resources = @import("resources.zig");
const file_stream = @import("ziggurat_file_stream");

pub const hard_max_file_bytes: u64 = 256 * 1024 * 1024;
pub const capacity = 8;
pub const process_capacity = 32;
pub const Limits = struct {
    max_live: u8 = capacity,
    max_file_bytes: u64 = hard_max_file_bytes,
    pub fn validate(self: Limits) !void {
        if (self.max_live == 0 or self.max_live > capacity or self.max_file_bytes == 0 or self.max_file_bytes > hard_max_file_bytes) return error.InvalidFileStreamLimits;
    }
};
pub const Head = struct {
    status: u16 = 200,
    mime: []const u8 = "application/octet-stream",
    headers: []const resources.Header = &.{},
};
pub const CommitOptions = struct { ticket: bool = false };

/// Complete private file, opened on the explicit worker. Owns one native file
/// reference and one metadata allocation; do not copy after preparation. The
/// source handle is borrowed and its logical position is unchanged. The host
/// must exclude writable mappings and other mutations for the whole transfer.
pub const OwnedFileResponse = struct {
    native: ?*anyopaque,
    length: u64,
    metadata: resources.OwnedResponse,

    pub fn prepare(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, file: std.fs.File, head: Head, max_bytes: u64) !OwnedFileResponse {
        return prepareWithFailure(allocator, process_main_thread_id, file, head, max_bytes, null);
    }
    /// Optional HRESULT output, cleared on entry and populated only when the
    /// native preparation operation fails. Validation/allocation errors have no
    /// fabricated platform code. Caller storage is used only during this call.
    pub fn prepareWithFailure(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, file: std.fs.File, head: Head, max_bytes: u64, native_failure: ?*?i32) !OwnedFileResponse {
        if (native_failure) |failure| failure.* = null;
        if (std.Thread.getCurrentId() == process_main_thread_id) return error.UiThreadForbidden;
        if (max_bytes == 0 or max_bytes > hard_max_file_bytes) return error.InvalidFileStreamLimit;
        try resources.validateResponse(.{ .status = head.status, .mime = head.mime, .headers = head.headers }, 0);
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        var handle: ?*anyopaque = null;
        var length: u64 = 0;
        const hr = zwv_file_prepare(file.handle, max_bytes, &handle, &length);
        if (hr < 0) {
            if (native_failure) |failure| failure.* = hr;
            return switch (@as(u32, @bitCast(hr))) {
                0x8007000e => error.OutOfMemory,
                0x800700df => error.FileTooLarge,
                0x80070032 => error.RegularFileRequired,
                else => error.FilePrepareFailed,
            };
        }
        errdefer zwv_file_close(handle.?);
        if (length != 0 and (head.status == 204 or head.status == 205 or head.status == 304)) return error.UnexpectedResponseBody;
        const metadata = try resources.OwnedResponse.init(allocator, .{ .status = head.status, .mime = head.mime, .headers = head.headers }, 1);
        return .{ .native = handle, .length = length, .metadata = metadata };
    }
    /// Linux preparation for a socket-backed response and an explicit worker
    /// pump. There is no implicit file-reading thread. The host posts response
    /// to the owner and then calls pump.pump() on its own worker. A failed post
    /// must deinit both values. Successful native acceptance consumes response;
    /// the pump waits for acceptance or cancellation before reading any bytes.
    /// Linux duplicates the fd but cannot enforce exclusion of other writers.
    /// Besides allocator-owned HTTP metadata, bounded native control/socket/GIO
    /// objects use system allocation. No representation-sized body is copied.
    pub fn preparePumped(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, file: std.fs.File, head: Head, max_bytes: u64) !PreparedPumped {
        return preparePumpedWithFailure(allocator, process_main_thread_id, file, head, max_bytes, null);
    }
    /// Optional errno, cleared on entry and set only after a real failed Linux
    /// syscall. Logical validation, capacity and allocator errors have no code.
    pub fn preparePumpedWithFailure(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, file: std.fs.File, head: Head, max_bytes: u64, native_failure: ?*?i32) !PreparedPumped {
        if (native_failure) |failure| failure.* = null;
        if (std.Thread.getCurrentId() == process_main_thread_id) return error.UiThreadForbidden;
        if (max_bytes == 0 or max_bytes > hard_max_file_bytes) return error.InvalidFileStreamLimit;
        try resources.validateResponse(.{ .status = head.status, .mime = head.mime, .headers = head.headers }, 0);
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        var prepared = try file_stream.PreparedSource.prepareWithFailure(process_main_thread_id, file, max_bytes, native_failure);
        errdefer {
            prepared.source.deinit();
            prepared.pump.deinit();
        }
        const length = prepared.source.length;
        if (length != 0 and (head.status == 204 or head.status == 205 or head.status == 304)) return error.UnexpectedResponseBody;
        const metadata = try resources.OwnedResponse.init(allocator, .{ .status = head.status, .mime = head.mime, .headers = head.headers }, 1);
        return .{ .response = .{ .native = prepared.source.native, .length = length, .metadata = metadata }, .pump = .{ .native = prepared.pump.native } };
    }
    /// Can run on the preparing worker after App.post fails. No COM is touched.
    pub fn deinit(self: *OwnedFileResponse) void {
        const native = self.native;
        var metadata = self.metadata;
        self.native = null;
        self.length = 0;
        self.metadata.storage = null;
        self.metadata.response = .{};
        if (native) |handle| switch (builtin.os.tag) {
            .windows => zwv_file_close(handle),
            .linux => {
                var source: file_stream.PreparedSource = .{ .native = handle, .length = 0 };
                source.deinit();
            },
            else => {},
        };
        metadata.deinit();
    }
    pub fn validate(self: *const OwnedFileResponse, max_bytes: u64) !void {
        if (self.native == null or self.metadata.storage == null) return error.ResponseMoved;
        if (self.length > max_bytes or self.length > hard_max_file_bytes) return error.FileTooLarge;
        try resources.validateResponse(self.metadata.response, 0);
        if (self.length != 0 and (self.metadata.response.status == 204 or self.metadata.response.status == 205 or self.metadata.response.status == 304)) return error.UnexpectedResponseBody;
    }
};

pub const PreparedPumped = struct { response: OwnedFileResponse, pump: FilePump };

/// Linear worker-owned operation. pump() may block this explicit worker on
/// acceptance or bounded socket backpressure. Never call it on the UI thread.
/// Cancellation wakes poll immediately, but cannot interrupt a regular-file
/// pread already in progress. deinit cancels unfinished work and releases the
/// pump reference; it does not join another thread. Do not copy this value.
pub const FilePump = struct {
    native: ?*anyopaque,
    pub fn pump(self: *FilePump) !void {
        return self.pumpWithFailure(null);
    }
    pub fn pumpWithFailure(self: *FilePump, native_failure: ?*?i32) !void {
        var operation: file_stream.Pump = .{ .native = self.native };
        return operation.pumpWithFailure(native_failure);
    }
    pub fn deinit(self: *FilePump) void {
        const native = self.native;
        self.native = null;
        var operation: file_stream.Pump = .{ .native = native };
        operation.deinit();
    }
};

/// Optional owning cancellation reference, independent of View/App/COM. Do not
/// copy; clone explicitly. It does not retain the physical stream or its slot.
pub const StreamTicket = struct {
    native: ?*anyopaque,
    pub fn cancel(self: StreamTicket) void {
        if (self.native) |control| switch (builtin.os.tag) {
            .windows => zwv_file_control_cancel(control),
            .linux => (file_stream.Control{ .native = control }).cancel(),
            else => {},
        };
    }
    pub fn clone(self: StreamTicket) !StreamTicket {
        const control = self.native orelse return error.TicketMoved;
        switch (builtin.os.tag) {
            .windows => zwv_file_control_add(control),
            .linux => return .{ .native = (try (file_stream.Control{ .native = control }).clone()).native },
            else => return error.UnsupportedCapability,
        }
        return .{ .native = control };
    }
    pub fn deinit(self: *StreamTicket) void {
        const native = self.native;
        self.native = null;
        if (native) |control| switch (builtin.os.tag) {
            .windows => zwv_file_control_release(control),
            .linux => {
                var ticket: file_stream.Control = .{ .native = control };
                ticket.deinit();
            },
            else => {},
        };
    }
};
extern fn zwv_file_prepare(*anyopaque, u64, *?*anyopaque, *u64) i32;
extern fn zwv_file_close(*anyopaque) void;
extern fn zwv_file_control_cancel(*anyopaque) void;
extern fn zwv_file_control_add(*anyopaque) void;
extern fn zwv_file_control_release(*anyopaque) void;

test "file preparation rejects the main thread before file access or allocation" {
    const file: std.fs.File = undefined;
    try std.testing.expectError(error.UiThreadForbidden, OwnedFileResponse.prepare(std.testing.failing_allocator, std.Thread.getCurrentId(), file, .{}, hard_max_file_bytes));
    try std.testing.expectError(error.UiThreadForbidden, OwnedFileResponse.preparePumped(std.testing.failing_allocator, std.Thread.getCurrentId(), file, .{}, hard_max_file_bytes));
    try std.testing.expectError(error.InvalidFileStreamLimits, (Limits{ .max_live = 0 }).validate());
    try std.testing.expectError(error.InvalidFileStreamLimits, (Limits{ .max_file_bytes = hard_max_file_bytes + 1 }).validate());
}
