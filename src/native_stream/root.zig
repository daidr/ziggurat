const std = @import("std");
const builtin = @import("builtin");
const files = @import("ziggurat_file_stream");

/// The shared byte-consumer protocol. It grants neither file/path authority
/// nor HTTP permission. A prepared source is linear regardless of its producer.
pub const Source = files.PreparedSource;
pub const hard_max_bytes = files.hard_max_bytes;
pub const chunk_bytes = files.chunk_bytes;
pub const Prepared = struct { source: Source, writer: Writer };
pub const Disposition = enum { body, head };

/// Explicit worker preparation. Known-length private bytes use the same
/// physical channel, consumer quota and C-only late lifetime as file sources.
/// No App, allocator or worker is created or retained. Move source through an
/// explicit post; a failed post or failed response still leaves both refs owned.
pub fn prepare(main_thread: std.Thread.Id, length: u64, maximum: u64) !Prepared {
    return prepareWithFailure(main_thread, length, maximum, null);
}
pub fn prepareWithFailure(main_thread: std.Thread.Id, length: u64, maximum: u64, native_failure: ?*?i32) !Prepared {
    if (native_failure) |failure| failure.* = null;
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.UnsupportedCapability;
    if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
    if (maximum == 0 or maximum > hard_max_bytes) return error.InvalidNativeStreamLimit;
    if (length > maximum) return error.ProducerTooLarge;
    var source: ?*anyopaque = null;
    var writer: ?*anyopaque = null;
    var code: c_int = 0;
    const result = if (builtin.os.tag == .windows) zws_channel_prepare(@intCast(main_thread), length, maximum, 1, &source, &writer, &code) else zwk_stream_prepare(@intCast(main_thread), length, maximum, &source, &writer, &code);
    try check(result, code, native_failure);
    return .{ .source = .{ .native = source, .length = length }, .writer = .{ .native = writer } };
}

/// Linear explicit producer. The first operation fixes one non-UI thread.
/// Waiting/writing may block that worker on acceptance or bounded channel
/// capacity. Cancellation wakes it. No operation joins or calls Zig/App.
pub const Writer = struct {
    native: ?*anyopaque,

    pub fn take(self: *Writer) !Writer {
        const value = self.native orelse return error.WriterMoved;
        self.native = null;
        return .{ .native = value };
    }
    pub fn waitAccepted(self: *Writer) !Disposition {
        return self.waitAcceptedWithFailure(null);
    }
    pub fn waitAcceptedWithFailure(self: *Writer, native_failure: ?*?i32) !Disposition {
        if (native_failure) |failure| failure.* = null;
        if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.UnsupportedCapability;
        const value = self.native orelse return error.WriterMoved;
        var head: c_int = 0;
        var code: c_int = 0;
        const result = if (builtin.os.tag == .windows) zws_writer_begin(value, &head, &code) else zwk_stream_writer_begin(value, &head, &code);
        try check(result, code, native_failure);
        return if (head != 0) .head else .body;
    }
    /// Borrows one nonempty <=16KiB chunk until return. Success accepts all its
    /// bytes. Production/length/IO failure is terminal, possibly after a partial
    /// OS write; never replay this input. Thread/kind authority refusals do not
    /// mutate the stream. Socket credit is not a page-consumption ACK.
    pub fn writeAll(self: *Writer, bytes: []const u8) !void {
        return self.writeAllWithFailure(bytes, null);
    }
    pub fn writeAllWithFailure(self: *Writer, bytes: []const u8, native_failure: ?*?i32) !void {
        if (native_failure) |failure| failure.* = null;
        if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.UnsupportedCapability;
        const value = self.native orelse return error.WriterMoved;
        var code: c_int = 0;
        const result = if (builtin.os.tag == .windows) zws_writer_write(value, bytes.ptr, bytes.len, &code) else zwk_stream_writer_write(value, bytes.ptr, bytes.len, &code);
        try check(result, code, native_failure);
    }
    /// EOF is successful only after exactly length bytes, or after accepted
    /// HEAD with no generated body. It does not release the writer's owning ref.
    pub fn finish(self: *Writer) !void {
        return self.finishWithFailure(null);
    }
    pub fn finishWithFailure(self: *Writer, native_failure: ?*?i32) !void {
        if (native_failure) |failure| failure.* = null;
        if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.UnsupportedCapability;
        const value = self.native orelse return error.WriterMoved;
        var code: c_int = 0;
        const result = if (builtin.os.tag == .windows) zws_writer_finish(value, &code) else zwk_stream_writer_finish(value, &code);
        try check(result, code, native_failure);
    }
    /// May run on a worker after a failed post. Withdraws before releasing the
    /// physical ref; abandoning unfinished work cancels the reader. Never joins.
    pub fn deinit(self: *Writer) void {
        const value = self.native;
        self.native = null;
        if (builtin.os.tag == .linux) if (value) |handle| zwk_file_pump_release(handle);
        if (builtin.os.tag == .windows) if (value) |handle| zws_producer_release(handle);
    }
};

fn check(result: c_int, code: c_int, native_failure: ?*?i32) !void {
    if (result == 0) return;
    if (native_failure) |failure| if (code != 0) {
        failure.* = code;
    };
    return switch (result) {
        1 => error.Closed,
        2 => error.Full,
        3 => error.OutOfMemory,
        4 => error.InvalidNativeStream,
        5 => error.NativeStreamFailed,
        6 => error.Cancelled,
        7 => error.ProducerTooLarge,
        9 => error.UiThreadForbidden,
        10 => error.Busy,
        11 => error.ResponseMoved,
        14 => error.LengthMismatch,
        15 => error.InvalidChunk,
        16 => error.WrongProducerThread,
        17 => error.SourceKindMismatch,
        18 => error.Finished,
        19 => error.UnexpectedBody,
        else => error.NativeStreamFailed,
    };
}

extern fn zwk_stream_prepare(u64, u64, u64, *?*anyopaque, *?*anyopaque, *c_int) c_int;
extern fn zwk_stream_writer_begin(*anyopaque, *c_int, *c_int) c_int;
extern fn zwk_stream_writer_write(*anyopaque, [*]const u8, usize, *c_int) c_int;
extern fn zwk_stream_writer_finish(*anyopaque, *c_int) c_int;
extern fn zwk_file_pump_release(*anyopaque) void;
extern fn zws_channel_prepare(u64, u64, u64, c_uint, *?*anyopaque, *?*anyopaque, *c_int) c_int;
extern fn zws_writer_begin(*anyopaque, *c_int, *c_int) c_int;
extern fn zws_writer_write(*anyopaque, [*]const u8, usize, *c_int) c_int;
extern fn zws_writer_finish(*anyopaque, *c_int) c_int;
extern fn zws_producer_release(*anyopaque) void;

test "native stream owner and bounds fail before native preparation" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    const current = std.Thread.getCurrentId();
    const other: std.Thread.Id = if (current == 1) 2 else 1;
    var code: ?i32 = 19;
    try std.testing.expectError(error.UiThreadForbidden, prepareWithFailure(current, 0, hard_max_bytes, &code));
    try std.testing.expect(code == null);
    try std.testing.expectError(error.InvalidNativeStreamLimit, prepare(other, 0, 0));
    try std.testing.expectError(error.InvalidNativeStreamLimit, prepare(other, 0, hard_max_bytes + 1));
    try std.testing.expectError(error.ProducerTooLarge, prepare(other, 2, 1));
}
test "native stream unsupported platform is cold before a writer borrow" {
    if (builtin.os.tag == .linux or builtin.os.tag == .windows) return;
    var code: ?i32 = 19;
    try std.testing.expectError(error.UnsupportedCapability, prepareWithFailure(std.Thread.getCurrentId(), 0, 0, &code));
    try std.testing.expect(code == null);
    var writer: Writer = undefined;
    try std.testing.expectError(error.UnsupportedCapability, writer.waitAccepted());
    try std.testing.expectError(error.UnsupportedCapability, writer.writeAll("bytes"));
    try std.testing.expectError(error.UnsupportedCapability, writer.finish());
}
test "native writer take withdraws its only linear value" {
    var writer: Writer = .{ .native = @ptrFromInt(1) };
    var moved = try writer.take();
    try std.testing.expect(writer.native == null and moved.native != null);
    try std.testing.expectError(error.WriterMoved, writer.take());
    // No native resource was constructed by this value-only ownership check.
    moved.native = null;
}
