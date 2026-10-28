const std = @import("std");
const builtin = @import("builtin");

pub const hard_max_bytes: u64 = 256 * 1024 * 1024;
pub const process_capacity = 32;
pub const consumer_capacity = 8;
pub const chunk_bytes = 16384;
pub const NativeInputStream = opaque {};

/// Explicit byte window of a private file. This value grants no path or HTTP
/// authority. Both bounds are checked against the native prepare-time size;
/// zero length means an empty representation, never "the remaining bytes".
pub const FileWindow = struct { offset: u64, length: u64 };

/// Independent linear references to one private regular file and its explicit
/// worker pump. Neither preparation nor this module owns a thread or an App.
pub const Prepared = struct { source: PreparedSource, pump: Pump };
/// Linear physical source reference. Do not copy after preparation or adoption.
pub const PreparedSource = struct {
    native: ?*anyopaque,
    length: u64,

    /// Worker-only setup. Takes no ownership of the caller's file, preserves its
    /// seek position and duplicates its descriptor. The host must keep all bytes
    /// private and immutable until the pump finishes. No body-sized copy occurs.
    pub fn prepare(main_thread: std.Thread.Id, file: std.Io.File, maximum: u64) !Prepared {
        return prepareWithFailure(main_thread, file, maximum, null);
    }
    pub fn prepareWithFailure(main_thread: std.Thread.Id, file: std.Io.File, maximum: u64, native_failure: ?*?i32) !Prepared {
        if (native_failure) |failure| failure.* = null;
        if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
        if (maximum == 0 or maximum > hard_max_bytes) return error.InvalidFileStreamLimit;
        if (builtin.os.tag == .windows) return prepareWindows(main_thread, file, maximum, null, native_failure);
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        var source: ?*anyopaque = null;
        var pump: ?*anyopaque = null;
        var length: u64 = 0;
        var code: c_int = 0;
        const result = zwk_file_prepare(file.handle, @intCast(main_thread), maximum, &source, &pump, &length, &code);
        if (result != 0) {
            if (native_failure) |failure| if (code != 0) {
                failure.* = code;
            };
            return nativeError(result);
        }
        return .{ .source = .{ .native = source, .length = length }, .pump = .{ .native = pump } };
    }
    /// Worker-only setup for exactly [offset, offset+length). The complete
    /// source file must still fit maximum. Duplicates the fd without changing
    /// its seek position. The same privacy/immutability contract as prepare
    /// applies to the source until the explicit pump has finished.
    pub fn prepareWindow(main_thread: std.Thread.Id, file: std.Io.File, window: FileWindow, maximum: u64) !Prepared {
        return prepareWindowWithFailure(main_thread, file, window, maximum, null);
    }
    pub fn prepareWindowWithFailure(main_thread: std.Thread.Id, file: std.Io.File, window: FileWindow, maximum: u64, native_failure: ?*?i32) !Prepared {
        if (native_failure) |failure| failure.* = null;
        if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
        if (maximum == 0 or maximum > hard_max_bytes) return error.InvalidFileStreamLimit;
        if (builtin.os.tag == .windows) return prepareWindows(main_thread, file, maximum, window, native_failure);
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        var source: ?*anyopaque = null;
        var pump: ?*anyopaque = null;
        var length: u64 = 0;
        var code: c_int = 0;
        const result = zwk_file_prepare_window(file.handle, @intCast(main_thread), maximum, window.offset, window.length, &source, &pump, &length, &code);
        if (result != 0) {
            if (native_failure) |failure| if (code != 0) {
                failure.* = code;
            };
            return nativeError(result);
        }
        return .{ .source = .{ .native = source, .length = length }, .pump = .{ .native = pump } };
    }
    fn prepareWindows(main_thread: std.Thread.Id, file: std.Io.File, maximum: u64, window: ?FileWindow, native_failure: ?*?i32) !Prepared {
        var source: ?*anyopaque = null;
        var pump: ?*anyopaque = null;
        var code: u32 = 0;
        const result = zws_file_prepare(@intCast(main_thread), file.handle, maximum, @intFromBool(window != null), if (window) |value| value.offset else 0, if (window) |value| value.length else 0, &source, &pump, &code);
        if (result != 0) {
            if (native_failure) |failure| if (code != 0) {
                failure.* = @bitCast(code);
            };
            return nativeError(result);
        }
        return .{ .source = .{ .native = source, .length = zws_channel_length(source.?) }, .pump = .{ .native = pump } };
    }
    /// Authoritative prepare-time length. No stat or file IO.
    pub fn authoritativeLength(self: PreparedSource) !u64 {
        const handle = self.native orelse return error.ResponseMoved;
        if (builtin.os.tag == .windows) return zws_channel_length(handle);
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        return zwk_file_length(handle);
    }
    /// Owner setup transaction. The budget's explicit owner is the main thread
    /// on which the consumer will use GIO. Abort retains this source and pump.
    pub fn prepareConsumer(self: PreparedSource, budget: Budget, head: bool, native_failure: ?*?i32) !ConsumerCandidate {
        if (native_failure) |failure| failure.* = null;
        const source = self.native orelse return error.ResponseMoved;
        const ledger = try budget.checked();
        if (builtin.os.tag == .windows) {
            var candidate: ?*anyopaque = null;
            const result = zws_candidate_prepare(source, ledger, @intFromBool(head), &candidate);
            if (result != 0) return nativeError(result);
            return .{ .native = candidate, .owner = budget.owner };
        }
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        var candidate: ?*anyopaque = null;
        var code: c_int = 0;
        const result = zwk_file_prepare_stream(source, ledger, @intFromBool(head), &candidate, &code);
        if (result != 0) {
            if (native_failure) |failure| if (code != 0) {
                failure.* = code;
            };
            return nativeError(result);
        }
        return .{ .native = candidate, .owner = budget.owner };
    }
    /// Can run on the preparing worker after a failed post. Revokes the value
    /// before releasing its physical reference. No caller allocator is retained.
    pub fn deinit(self: *PreparedSource) void {
        const handle = self.native;
        self.native = null;
        self.length = 0;
        if (builtin.os.tag == .linux) if (handle) |value| zwk_file_response_release(value);
        if (builtin.os.tag == .windows) if (handle) |value| zws_source_release(value);
    }
};

/// Linear worker operation; may block only its explicitly managed worker on
/// acceptance or bounded socket backpressure. Cancellation cannot interrupt an
/// in-progress regular-file pread. deinit cancels unfinished work, never joins.
pub const Pump = struct {
    native: ?*anyopaque,
    pub fn pump(self: *Pump) !void {
        return self.pumpWithFailure(null);
    }
    pub fn pumpWithFailure(self: *Pump, native_failure: ?*?i32) !void {
        if (native_failure) |failure| failure.* = null;
        const handle = self.native orelse return error.PumpMoved;
        if (builtin.os.tag == .windows) {
            var code: u32 = 0;
            const result = zws_file_pump(handle, &code);
            if (result != 0) {
                if (native_failure) |failure| if (code != 0) {
                    failure.* = @bitCast(code);
                };
                return nativeError(result);
            }
            return;
        }
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        var code: c_int = 0;
        const result = zwk_file_pump(handle, &code);
        if (result != 0) {
            if (native_failure) |failure| if (code != 0) {
                failure.* = code;
            };
            return nativeError(result);
        }
    }
    pub fn deinit(self: *Pump) void {
        const handle = self.native;
        self.native = null;
        if (builtin.os.tag == .linux) if (handle) |value| zwk_file_pump_release(value);
        if (builtin.os.tag == .windows) if (handle) |value| zws_file_pump_release(value);
    }
};

/// Independent cancellation reference, usable from any thread. It retains no
/// source, stream, physical slot, consumer, allocator or App. Clone explicitly.
pub const Control = struct {
    native: ?*anyopaque,
    pub fn cancel(self: Control) void {
        if (builtin.os.tag == .linux) if (self.native) |handle| zwk_file_control_cancel(handle);
        if (builtin.os.tag == .windows) if (self.native) |handle| zws_control_cancel(handle);
    }
    pub fn clone(self: Control) !Control {
        const handle = self.native orelse return error.TicketMoved;
        if (builtin.os.tag == .windows) {
            zws_control_add(handle);
            return .{ .native = handle };
        }
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        zwk_file_control_add(handle);
        return .{ .native = handle };
    }
    pub fn alive(self: Control) bool {
        if (builtin.os.tag == .windows) return if (self.native) |handle| zws_control_alive(handle) != 0 else false;
        if (builtin.os.tag != .linux) return false;
        return if (self.native) |handle| zwk_file_control_alive(handle) != 0 else false;
    }
    pub fn deinit(self: *Control) void {
        const handle = self.native;
        self.native = null;
        if (builtin.os.tag == .linux) if (handle) |value| zwk_file_control_release(value);
        if (builtin.os.tag == .windows) if (handle) |value| zws_control_release(value);
    }
};

/// Linear owner-thread admission policy; do not copy. Closing its logical reference does not return
/// reservations held by actual streams; physical final release does that.
pub const Budget = struct {
    native: ?*anyopaque,
    owner: std.Thread.Id,
    pub fn create(owner: std.Thread.Id, limit: u8) !Budget {
        if (std.Thread.getCurrentId() != owner) return error.WrongThread;
        if (limit == 0 or limit > consumer_capacity) return error.InvalidFileStreamLimits;
        if (builtin.os.tag == .windows) return .{ .native = zws_budget_create(limit) orelse return error.OutOfMemory, .owner = owner };
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        return .{ .native = zwk_file_budget_create(limit) orelse return error.OutOfMemory, .owner = owner };
    }
    fn checked(self: Budget) !*anyopaque {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        return self.native orelse error.BudgetMoved;
    }
    pub fn live(self: Budget) !u32 {
        const handle = try self.checked();
        if (builtin.os.tag == .windows) return zws_budget_live(handle);
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        return zwk_file_budget_live(handle);
    }
    pub fn setLimit(self: Budget, limit: u8) !void {
        const handle = try self.checked();
        if (limit == 0 or limit > consumer_capacity) return error.InvalidFileStreamLimits;
        if (builtin.os.tag == .windows) {
            const result = zws_budget_limit(handle, limit);
            if (result != 0) return nativeError(result);
            return;
        }
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        zwk_file_budget_limit(handle, limit);
    }
    pub fn deinit(self: *Budget) void {
        const handle = self.native;
        self.native = null;
        if (builtin.os.tag == .linux) if (handle) |value| zwk_file_budget_release(value);
        if (builtin.os.tag == .windows) if (handle) |value| zws_budget_release(value);
    }
};

/// Linear owner candidate. stream() is Linux native GIO interop, borrowed only
/// until abort/admit; retain a GObject reference if it must survive admission.
/// Windows transport consumers use the private pollable channel protocol.
pub const ConsumerCandidate = struct {
    native: ?*anyopaque,
    owner: std.Thread.Id,
    fn checked(self: ConsumerCandidate) !*anyopaque {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        return self.native orelse error.CandidateMoved;
    }
    pub fn stream(self: ConsumerCandidate) !*NativeInputStream {
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        const handle = try self.checked();
        return @ptrCast(zwk_file_candidate_stream(handle));
    }
    pub fn retainControl(self: ConsumerCandidate) !Control {
        const handle = try self.checked();
        if (builtin.os.tag == .windows) {
            const control = zws_candidate_control(handle);
            zws_control_add(control);
            return .{ .native = control };
        }
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        const control = zwk_file_candidate_control(handle);
        zwk_file_control_add(control);
        return .{ .native = control };
    }
    pub fn abort(self: *ConsumerCandidate) !void {
        const handle = try self.checked();
        if (builtin.os.tag == .windows) {
            self.native = null;
            zws_candidate_abort(handle);
            return;
        }
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        self.native = null;
        zwk_file_candidate_abort(handle);
    }
    /// The caller must already irrevocably own one consumer response duty.
    /// There is no failing native step after taking this candidate. A concurrent
    /// close means accepted_cancelled, not retry and not a peer-consumption ACK.
    pub fn admit(self: *ConsumerCandidate, accepted_cancelled: bool, want_control: bool) !?Control {
        const handle = try self.checked();
        if (builtin.os.tag == .windows) {
            self.native = null;
            var control: ?*anyopaque = null;
            zws_candidate_admit(handle, @intFromBool(accepted_cancelled), if (want_control) &control else null);
            return if (control) |value| .{ .native = value } else null;
        }
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        self.native = null;
        var control: ?*anyopaque = null;
        zwk_file_candidate_admit(handle, @intFromBool(accepted_cancelled), @intFromBool(want_control), &control);
        return if (control) |value| .{ .native = value } else null;
    }
};

pub const Counts = struct { physical: u32 = 0, controls: u32 = 0, budgets: u32 = 0, candidates: u32 = 0 };
pub fn counts() Counts {
    var value: Counts = .{};
    if (builtin.os.tag == .linux) zwk_file_counts(&value.physical, &value.controls, &value.budgets, &value.candidates);
    if (builtin.os.tag == .windows) {
        var native: WindowsCounts = undefined;
        zws_counts(&native);
        value = .{ .physical = native.physical, .controls = native.controls, .budgets = native.budgets, .candidates = native.candidates };
    }
    return value;
}
fn nativeError(result: c_int) anyerror {
    if (builtin.os.tag == .windows) switch (result) {
        14 => return error.LengthMismatch,
        15 => return error.InvalidChunk,
        16 => return error.WrongProducerThread,
        17 => return error.SourceKindMismatch,
        18 => return error.Finished,
        19 => return error.UnexpectedBody,
        else => {},
    };
    return switch (result) {
        1 => error.Closed,
        2 => error.Full,
        3 => error.OutOfMemory,
        4 => error.InvalidFileStream,
        5 => error.FileStreamFailed,
        6 => error.Cancelled,
        7 => error.FileTooLarge,
        8 => error.RegularFileRequired,
        9 => error.UiThreadForbidden,
        10 => error.Busy,
        11 => error.ResponseMoved,
        12 => error.FileSourceChanged,
        13 => error.InvalidFileWindow,
        else => error.FileStreamFailed,
    };
}
extern fn zwk_file_prepare(c_int, u64, u64, *?*anyopaque, *?*anyopaque, *u64, *c_int) c_int;
extern fn zwk_file_prepare_window(c_int, u64, u64, u64, u64, *?*anyopaque, *?*anyopaque, *u64, *c_int) c_int;
extern fn zwk_file_response_release(*anyopaque) void;
extern fn zwk_file_length(*anyopaque) u64;
extern fn zwk_file_pump(*anyopaque, *c_int) c_int;
extern fn zwk_file_pump_release(*anyopaque) void;
extern fn zwk_file_control_cancel(*anyopaque) void;
extern fn zwk_file_control_add(*anyopaque) void;
extern fn zwk_file_control_release(*anyopaque) void;
extern fn zwk_file_control_alive(*anyopaque) c_int;
extern fn zwk_file_budget_create(u32) ?*anyopaque;
extern fn zwk_file_budget_limit(*anyopaque, u32) void;
extern fn zwk_file_budget_release(*anyopaque) void;
extern fn zwk_file_budget_live(*anyopaque) u32;
extern fn zwk_file_prepare_stream(*anyopaque, *anyopaque, c_int, *?*anyopaque, *c_int) c_int;
extern fn zwk_file_candidate_stream(*anyopaque) *anyopaque;
extern fn zwk_file_candidate_control(*anyopaque) *anyopaque;
extern fn zwk_file_candidate_abort(*anyopaque) void;
extern fn zwk_file_candidate_admit(*anyopaque, c_int, c_int, *?*anyopaque) void;
extern fn zwk_file_counts(*u32, *u32, *u32, *u32) void;
const WindowsCounts = extern struct { physical: u32, controls: u32, budgets: u32, readers: u32, candidates: u32, rings: u32 };
extern fn zws_file_prepare(u64, std.Io.File.Handle, u64, c_int, u64, u64, *?*anyopaque, *?*anyopaque, *u32) c_int;
extern fn zws_file_pump(*anyopaque, *u32) c_int;
extern fn zws_file_pump_release(*anyopaque) void;
extern fn zws_source_release(*anyopaque) void;
extern fn zws_channel_length(*anyopaque) u64;
extern fn zws_control_cancel(*anyopaque) void;
extern fn zws_control_add(*anyopaque) void;
extern fn zws_control_release(*anyopaque) void;
extern fn zws_control_alive(*anyopaque) c_int;
extern fn zws_budget_create(u32) ?*anyopaque;
extern fn zws_budget_limit(*anyopaque, u32) c_int;
extern fn zws_budget_release(*anyopaque) void;
extern fn zws_budget_live(*anyopaque) u32;
extern fn zws_candidate_prepare(*anyopaque, *anyopaque, c_int, *?*anyopaque) c_int;
extern fn zws_candidate_reader(*anyopaque) *anyopaque;
extern fn zws_candidate_control(*anyopaque) *anyopaque;
extern fn zws_candidate_abort(*anyopaque) void;
extern fn zws_candidate_admit(*anyopaque, c_int, ?*?*anyopaque) void;
extern fn zws_counts(*WindowsCounts) void;

test "owner preparation rejects UI thread before borrowing a file" {
    const file: std.Io.File = undefined;
    var code: ?i32 = 19;
    try std.testing.expectError(error.UiThreadForbidden, PreparedSource.prepareWithFailure(std.Thread.getCurrentId(), file, hard_max_bytes, &code));
    try std.testing.expect(code == null);
    try std.testing.expectError(error.UiThreadForbidden, PreparedSource.prepareWindowWithFailure(std.Thread.getCurrentId(), file, .{ .offset = std.math.maxInt(u64), .length = 1 }, hard_max_bytes, &code));
    try std.testing.expect(code == null);
    try std.testing.expectError(error.InvalidFileStreamLimits, Budget.create(std.Thread.getCurrentId(), 0));
    try std.testing.expectError(error.InvalidFileStreamLimits, Budget.create(std.Thread.getCurrentId(), consumer_capacity + 1));
}

test "file window unsupported platform is cold before file access" {
    if (builtin.os.tag == .linux or builtin.os.tag == .windows) return;
    const current = std.Thread.getCurrentId();
    const other: std.Thread.Id = if (current == 1) 2 else 1;
    const file: std.Io.File = undefined;
    var code: ?i32 = 19;
    try std.testing.expectError(error.UnsupportedCapability, PreparedSource.prepareWindowWithFailure(other, file, .{ .offset = std.math.maxInt(u64), .length = 1 }, hard_max_bytes, &code));
    try std.testing.expect(code == null);
    try std.testing.expectEqualDeep(Counts{}, counts());
}
