//! Private Windows preparation/driver ownership. Transport's eventual adopt
//! entry consumes only Listener; the host keeps Driver on its original worker.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const policy = @import("transport_policy.zig");
const protocol = @import("windows_protocol.zig");
const base = @import("transport_native.zig");
const enabled = builtin.os.tag == .windows and @import("ziggurat_https_resources_options").enabled;

pub const WorkerLimits = struct {
    /// Includes C server/envelopes, all socket reactor storage and the bounded
    /// provider allocator. Source ring/Endpoint response budgets are separate.
    /// Native socket/kernel memory and the explicit host thread stack are not
    /// allocator requested bytes. No socket credit is a page consumption ACK.
    bytes: usize = 8 * 1024 * 1024,
    connections: u8 = 8,
    pub fn validate(self: WorkerLimits) !void {
        if (self.bytes == 0 or self.bytes > 64 * 1024 * 1024 or self.connections == 0 or self.connections > 8) return error.InvalidTransportLimits;
    }
};
const NativeLimits = extern struct { bytes: usize, connections: u32 };
/// peak_bytes adds the independently exact metadata and TLS peaks. That is a
/// conservative budget envelope, not a simultaneous allocation/RSS measurement.
pub const Stats = extern struct { bytes: usize, peak_bytes: usize, tls_live: usize, tls_peak: usize, connections: u32, accepting: u32, port: u32, running: u32 };
pub const Counts = extern struct { servers: u32 = 0, payloads: u32 = 0, envelopes: u32 = 0, connections: u32 = 0, bytes: usize = 0 };

/// Linear main-thread handoff, independent from Driver. Deinit revokes the
/// prepared/adoptable listener and consumes only this ref; it does not wait or
/// destroy worker TLS/socket payload. The host must still retire Driver there.
pub const Listener = struct {
    native: ?*anyopaque,
    pub fn deinit(self: *Listener) void {
        const handle = self.native;
        self.native = null;
        if (enabled) if (handle) |value| {
            zhtw_cancel(value);
            zhtw_unref(value);
        };
    }
};
/// Stable, linear explicit worker token. Its creator thread executes run and
/// deinit, including prepare-only/adopt-failed/never-run paths. WrongThread
/// retains the token. App must cover run plus every accepted/in-flight post:
/// host returns from App.run, joins these workers, and only then deinits App.
pub const Driver = struct {
    native: ?*anyopaque,
    pub fn run(self: *Driver, failure: ?*?base.Failure) !void {
        if (failure) |out| out.* = null;
        if (!enabled) return error.UnsupportedCapability;
        const handle = self.native orelse return error.TransportDriverMoved;
        var detail: base.Failure = .{};
        const result = zhtw_run(handle, &detail);
        if (failure) |out| if (detail.domain != 0) {
            out.* = detail;
        };
        try base.check(result);
    }
    /// Any thread may revoke admission and wake blocked run; all payload
    /// cleanup remains the original worker's duty. This is not a join.
    pub fn cancel(self: Driver) !void {
        if (!enabled) return error.UnsupportedCapability;
        zhtw_cancel(self.native orelse return error.TransportDriverMoved);
    }
    pub fn deinit(self: *Driver) !void {
        if (!enabled) return error.UnsupportedCapability;
        if (self.native == null) return;
        try base.check(zhtw_release_driver(&self.native));
    }
};
pub const Prepared = struct { listener: Listener, driver: Driver };

pub fn prepare(main_thread: std.Thread.Id, material: policy.Material, limits: WorkerLimits, failure: ?*?base.Failure) !Prepared {
    if (failure) |out| out.* = null;
    if (!enabled) return error.UnsupportedCapability;
    if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
    try limits.validate();
    return prepareCaptured(main_thread, material, limits, failure);
}
noinline fn prepareCaptured(main_thread: std.Thread.Id, material: policy.Material, limits: WorkerLimits, failure: ?*?base.Failure) !Prepared {
    var captured: policy.Captured = undefined;
    defer captured.deinit();
    try captured.init(material);
    var listener: ?*anyopaque = null;
    var driver: ?*anyopaque = null;
    var detail: base.Failure = .{};
    const result = zhtw_prepare(main_thread, &captured.bytes, captured.certificate_length, captured.bytes[captured.certificate_length + 1 ..].ptr, captured.length - captured.certificate_length - 1, &.{ .bytes = limits.bytes, .connections = limits.connections }, &listener, &driver, &detail);
    if (failure) |out| if (detail.domain != 0) {
        out.* = detail;
    };
    try base.check(result);
    return .{ .listener = .{ .native = listener }, .driver = .{ .native = driver } };
}

pub fn adopt(handle: *anyopaque, app: *z.App) !void {
    if (!enabled) return error.UnsupportedCapability;
    try base.check(zhtw_adopt(handle, app, &post, &protocol.format));
}
fn post(context: *anyopaque, envelope: *anyopaque) callconv(.c) c_int {
    const app: *z.App = @ptrCast(@alignCast(context));
    app.post(.{ .context = envelope, .call = deliver }) catch return 1;
    return 0;
}
fn deliver(envelope: *anyopaque) void {
    defer zhtw_envelope_release(envelope);
    protocol.dispatch(envelope);
}
pub fn counts() Counts {
    var out: Counts = .{};
    if (enabled) zhtw_counts(&out);
    return out;
}

pub extern fn zhtw_prepare(u64, [*]const u8, usize, [*]const u8, usize, *const NativeLimits, *?*anyopaque, *?*anyopaque, *base.Failure) c_int;
pub extern fn zhtw_run(*anyopaque, *base.Failure) c_int;
pub extern fn zhtw_release_driver(*?*anyopaque) c_int;
pub extern fn zhtw_adopt(*anyopaque, *anyopaque, *const fn (*anyopaque, *anyopaque) callconv(.c) c_int, @TypeOf(&protocol.format)) c_int;
pub extern fn zhtw_ref(*anyopaque) void;
pub extern fn zhtw_unref(*anyopaque) void;
pub extern fn zhtw_seal(*anyopaque) c_int;
pub extern fn zhtw_cancel(*anyopaque) void;
pub extern fn zhtw_stats(*anyopaque, *Stats) c_int;
pub extern fn zhtw_lease_begin(*anyopaque, *?*anyopaque, *u16) c_int;
pub extern fn zhtw_lease_finish(*?*anyopaque) c_int;
pub extern fn zhtw_counts(*Counts) void;
extern fn zhtw_envelope_release(*anyopaque) void;
