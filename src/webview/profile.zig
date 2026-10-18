const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
pub const supported = builtin.os.tag == .linux or is_windows;
pub const storage = @import("profile_storage.zig");
pub const tls_policy = @import("profile_tls_policy.zig");
pub const LoopbackHttps = tls_policy.LoopbackHttps;
pub const CreateOptions = struct { limits: Limits = .{}, loopback_https: ?LoopbackHttps = null };
pub const GlibFailure = extern struct { domain: u32 = 0, code: i32 = 0 };
pub const Failure = union(enum) { system_errno: i32, glib: GlibFailure, hresult: i32 };

pub const Limits = struct {
    /// Actual Context tokens remain charged until their native GObjects are
    /// finalized, including references retained after logical token closure.
    contexts: u16 = 16,
    /// Simultaneously owned C-only configuration references, including an old
    /// configuration and its replacement candidate. No slot array is allocated.
    leases: u16 = 32,
    /// Requested native owner/path/token bytes plus the Zig Profile value.
    /// TLS construction also reserves its one fixed Captured stack object;
    /// current usage excludes that object after construction returns.
    /// GLib/WebKit internals are system allocation, outside this metadata cap;
    /// their allocation failure can terminate the process.
    bytes: usize = 64 * 1024,

    pub fn validate(self: Limits) !void {
        if (self.contexts == 0 or self.contexts > 64 or self.leases == 0 or self.leases > 256 or self.bytes <= @sizeOf(Profile) or self.bytes > 1024 * 1024) return error.InvalidProfileLimits;
    }
};
pub const Stats = struct {
    owned_bytes: usize,
    /// Includes the opt-in constructor's fixed Captured stack reservation.
    peak_bytes: usize,
    contexts: u32,
    context_capacity: u32,
    accepting: bool,
    leases: u32,
    lease_capacity: u32,
};
pub const NativeCounts = struct { profiles: u32 = 0, contexts: u32 = 0, bytes: usize = 0 };

/// Independent private native owner. Creation and
/// all operations run on the process main thread; disk preparation is the
/// explicit worker-owned Prepared operation. This object owns no App, Window
/// or worker and registers no implicit stop participant.
///
/// seal withdraws new Context creation/attachment without waiting for existing
/// Contexts. close releases this Zig owner even if native references remain;
/// those references own C-only storage and the duplicated lock, never this
/// object, its allocator or a caller callback. Keep the supplied allocator
/// alive through close. The Profile pointer is invalid after close returns.
/// Every retained WebKit GObject reference is still owner-thread, including
/// its last unref. Native-only finalization does not provide worker access.
/// Successful construction permanently consumes Prepared's native claim.
/// To construct a later owner, close Prepared and prepare a fresh epoch on the
/// explicit worker; another epoch fails its lock while native refs remain.
pub const Profile = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    native: ?*anyopaque,
    busy: bool = false,
    owner_bytes: usize = @sizeOf(Profile),

    pub fn create(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, prepared: *storage.Prepared, limits: Limits) !*Profile {
        return createWithFailure(allocator, process_main_thread_id, prepared, limits, null);
    }
    /// Optional real syscall errno, cleared on entry. Validation, capacity and
    /// allocation failures do not manufacture a native code.
    pub fn createWithFailure(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, prepared: *storage.Prepared, limits: Limits, system_errno: ?*?i32) !*Profile {
        if (system_errno) |output| output.* = null;
        if (!supported) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != process_main_thread_id) return error.WrongThread;
        return createCaptured(allocator, process_main_thread_id, prepared, limits, null, system_errno, null);
    }
    pub fn createWithOptions(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, prepared: *storage.Prepared, options: CreateOptions) !*Profile {
        return createWithOptionsAndFailure(allocator, process_main_thread_id, prepared, options, null);
    }
    pub fn createWithOptionsAndFailure(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, prepared: *storage.Prepared, options: CreateOptions, failure: ?*?Failure) !*Profile {
        if (failure) |output| output.* = null;
        if (!supported) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != process_main_thread_id) return error.WrongThread;
        if (options.loopback_https) |tls| return createTls(allocator, process_main_thread_id, prepared, options.limits, tls, failure);
        return createCaptured(allocator, process_main_thread_id, prepared, options.limits, null, null, failure);
    }
    noinline fn createTls(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, prepared: *storage.Prepared, limits: Limits, tls: LoopbackHttps, failure: ?*?Failure) !*Profile {
        var captured: tls_policy.Captured = undefined;
        try captured.captureInto(tls);
        return createCaptured(allocator, process_main_thread_id, prepared, limits, &captured, null, failure);
    }
    fn createCaptured(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, prepared: *storage.Prepared, limits: Limits, captured: ?*const tls_policy.Captured, system_errno: ?*?i32, failure: ?*?Failure) !*Profile {
        // Both input capture and claim precede the first caller allocator.
        var construction = try Construction.beginWithTls(prepared, limits, @sizeOf(Profile), captured);
        errdefer construction.abort();
        const result = try allocator.create(Profile);
        errdefer allocator.destroy(result);
        result.* = .{ .allocator = allocator, .owner = process_main_thread_id, .native = try construction.createNativeWithFailure(system_errno, failure) };
        return result;
    }

    /// New business ingress is sealed; existing native objects remain usable
    /// by their own owners until they close. No UI wait or engine flush occurs.
    pub fn seal(self: *Profile) !void {
        if (!supported) return error.UnsupportedCapability;
        try self.check();
        self.busy = true;
        defer self.busy = false;
        try nativeError(if (is_windows) zwpw_profile_seal(self.native.?) else zwk_profile_seal(self.native.?));
    }
    pub fn borrowContext(self: *Profile) !Context {
        if (!supported) return error.UnsupportedCapability;
        try self.check();
        self.busy = true;
        defer self.busy = false;
        var native: ?*anyopaque = null;
        try nativeError(if (is_windows) zwpw_profile_context_create(self.native.?, &native) else zwk_profile_context_create(self.native.?, &native));
        return .{ .owner = self.owner, .native = native.? };
    }
    pub fn retainConfig(self: *Profile) !ConfigLease {
        if (!supported) return error.UnsupportedCapability;
        try self.check();
        try nativeError(if (is_windows) zwpw_profile_lease_retain(self.native.?) else zwk_profile_lease_retain(self.native.?));
        return .{ .owner = self.owner, .native = self.native.? };
    }
    pub fn stats(self: *Profile) !Stats {
        if (!supported) return error.UnsupportedCapability;
        try self.check();
        var value: NativeStats = undefined;
        try nativeError(if (is_windows) zwpw_profile_stats(self.native.?, &value) else zwk_profile_stats(self.native.?, &value));
        return .{ .owned_bytes = value.owned_bytes + self.owner_bytes, .peak_bytes = value.peak_bytes + self.owner_bytes, .contexts = value.contexts, .context_capacity = value.context_capacity, .accepting = value.accepting != 0, .leases = value.leases, .lease_capacity = value.lease_capacity };
    }
    /// No ContextsAlive error: stopping an App must be able to seal/release this
    /// owner before ordinary windows dispose their Context references. The lock
    /// can remain held after return and is not permission to reuse directories.
    pub fn close(self: *Profile) !void {
        const allocator = self.allocator;
        try self.releaseNative();
        // No self read after the final caller allocator callback.
        allocator.destroy(self);
    }
    /// For an embedding owner that supplies the one actual allocation and its
    /// lifecycle scope. Leaves this inline value withdrawn and busy forever.
    pub fn releaseNative(self: *Profile) !void {
        if (!supported) return error.UnsupportedCapability;
        try self.check();
        self.busy = true;
        const native = self.native.?;
        self.native = null;
        const status = if (is_windows) zwpw_profile_close(native) else zwk_profile_close(native);
        std.debug.assert(status == 0);
    }
    fn check(self: *Profile) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
        if (self.native == null) return error.Closed;
    }
};

/// Shared private constructor for a standalone owner or an inline App owner.
/// Holds the prepared claim across the embedding owner's first allocation.
pub const Construction = struct {
    claim: storage.NativeClaim,
    limits: Limits,
    owner_bytes: usize,
    native_created: bool = false,
    tls: ?*const tls_policy.Captured = null,

    pub fn begin(prepared: *storage.Prepared, limits: Limits, owner_bytes: usize) !Construction {
        return beginWithTls(prepared, limits, owner_bytes, null);
    }
    /// captured is borrowed from an outer noinline TLS constructor until all
    /// native construction and caller allocator cleanup has returned.
    pub fn beginWithTls(prepared: *storage.Prepared, limits: Limits, owner_bytes: usize, captured: ?*const tls_policy.Captured) !Construction {
        if (!supported) return error.UnsupportedCapability;
        try limits.validate();
        if (owner_bytes >= limits.bytes) return error.CapacityExceeded;
        const claim = try prepared.claimNativeOwner();
        errdefer claim.abort() catch unreachable;
        var native_bytes: usize = 0;
        if (is_windows) {
            var diagnostic: i32 = 0;
            var tls: NativeTls = undefined;
            if (captured) |value| tls = .{ .certificate_pem = value.pem().ptr, .certificate_length = value.len, .temporary_bytes = @sizeOf(tls_policy.Captured) };
            try nativeError(zwpw_profile_measure(try claim.dataWide(), if (captured != null) &tls else null, &native_bytes, &diagnostic));
        } else {
            const paths = try claim.paths();
            if (captured) |value| {
                const tls: NativeTls = .{ .certificate_pem = value.pem().ptr, .certificate_length = value.len, .temporary_bytes = @sizeOf(tls_policy.Captured) };
                try nativeError(zwk_profile_measure_tls(paths.data, paths.cache, paths.cookies, &tls, &native_bytes));
            } else try nativeError(zwk_profile_measure(paths.data, paths.cache, paths.cookies, &native_bytes));
        }
        const temporary: usize = if (captured != null) @sizeOf(tls_policy.Captured) else 0;
        if (native_bytes > limits.bytes - owner_bytes or temporary > limits.bytes - owner_bytes - native_bytes) return error.CapacityExceeded;
        return .{ .claim = claim, .limits = limits, .owner_bytes = owner_bytes, .tls = captured };
    }
    pub fn createNative(self: *Construction, system_errno: ?*?i32) !*anyopaque {
        return self.createNativeWithFailure(system_errno, null);
    }
    pub fn createNativeWithFailure(self: *Construction, system_errno: ?*?i32, failure: ?*?Failure) !*anyopaque {
        if (!supported) return error.UnsupportedCapability;
        if (self.native_created) return error.ProfileStorageAlreadyClaimed;
        var native: ?*anyopaque = null;
        var code: c_int = 0;
        var hresult: i32 = 0;
        var glib: GlibFailure = .{};
        const options: NativeOptions = .{ .contexts = self.limits.contexts, .bytes = self.limits.bytes - self.owner_bytes, .leases = self.limits.leases };
        const status = if (is_windows) blk: {
            var tls: NativeTls = undefined;
            if (self.tls) |value| tls = .{ .certificate_pem = value.pem().ptr, .certificate_length = value.len, .temporary_bytes = @sizeOf(tls_policy.Captured) };
            break :blk zwpw_profile_create(try self.claim.borrowDomain(), try self.claim.dataWide(), &options, if (self.tls != null) &tls else null, &native, &hresult);
        } else blk: {
            const paths = try self.claim.paths();
            const fd = try self.claim.borrowLockDescriptor();
            if (self.tls) |value| {
                const tls: NativeTls = .{ .certificate_pem = value.pem().ptr, .certificate_length = value.len, .temporary_bytes = @sizeOf(tls_policy.Captured) };
                break :blk zwk_profile_create_tls(fd, paths.data, paths.cache, paths.cookies, &options, &tls, &native, &code, &glib);
            }
            break :blk zwk_profile_create(fd, paths.data, paths.cache, paths.cookies, &options, &native, &code);
        };
        if (status != 0) {
            if (system_errno) |output| if (code != 0) {
                output.* = code;
            };
            if (failure) |output| {
                if (hresult < 0) output.* = .{ .hresult = hresult } else if (code != 0) output.* = .{ .system_errno = code } else if (glib.domain != 0) output.* = .{ .glib = glib };
            }
            nativeError(status) catch |err| return err;
            unreachable;
        }
        // Manager construction is the irreversible one-writer boundary,
        // independently of whether the enclosing public owner is published.
        // A later failure may release native refs but cannot undo this epoch.
        self.claim.commit() catch unreachable;
        self.native_created = true;
        return native.?;
    }
    pub fn abort(self: *Construction) void {
        if (!self.native_created) self.claim.abort() catch unreachable;
    }
};

/// Linear C-only reference, owned by an immutable configuration. It does not
/// retain a Zig Profile/App or allocate another metadata object. Clear/move
/// this value before any foreign teardown; after release old copies are invalid.
pub const ConfigLease = struct {
    owner: std.Thread.Id,
    native: ?*anyopaque,

    pub fn check(self: ConfigLease) !void {
        if (!supported) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        try nativeError(if (is_windows) zwpw_profile_lease_check(self.native orelse return error.Closed) else zwk_profile_lease_check(self.native orelse return error.Closed));
    }
    pub fn context(self: ConfigLease) !Context {
        if (!supported) return error.UnsupportedCapability;
        try self.check();
        var native: ?*anyopaque = null;
        try nativeError(if (is_windows) zwpw_profile_context_create(self.native.?, &native) else zwk_profile_context_create(self.native.?, &native));
        return .{ .owner = self.owner, .native = native.? };
    }
    pub fn release(self: *ConfigLease) !void {
        if (!supported) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        const native = self.native orelse return;
        self.native = null;
        const status = if (is_windows) zwpw_profile_lease_release(native) else zwk_profile_lease_release(native);
        std.debug.assert(status == 0);
    }
};

/// Linear native Context reference with no pointer back to a Zig Profile.
/// close is owner-thread and allocation-free. It releases the token, not every
/// WebKit reference: late finalizers only release native storage. Never copy;
/// after close this value can be queried/closed again but old copies cannot.
pub const Context = struct {
    owner: std.Thread.Id,
    native: ?*anyopaque,
    busy: bool = false,

    /// Internal one-shot authorization before a configuration/restart accepts
    /// ownership. Post failure still closes this candidate. Linux admission
    /// survives later sealing. Windows only reserves: native activation after
    /// process publication and handler installation commits an existing View;
    /// sealing before that point revokes pending initialization exactly once.
    pub fn admit(self: *Context) !void {
        if (!supported) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
        try nativeError(if (is_windows) zwpw_profile_context_admit(self.native orelse return error.Closed) else zwk_profile_context_admit(self.native orelse return error.Closed));
    }

    /// Private integration borrow. Retain the GObject before any foreign call
    /// can close this token; do not unref this borrowed pointer itself.
    pub fn webContext(self: *Context) !*anyopaque {
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
        const native = self.native orelse return error.Closed;
        var result: ?*anyopaque = null;
        try nativeError(zwk_profile_context_get(native, &result));
        return result.?;
    }
    /// Private Windows adapter borrow. The adapter retains the C Context before
    /// foreign calls; this pointer is neither a GObject nor a COM interface.
    pub fn windowsContext(self: *Context) !*anyopaque {
        if (!is_windows) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
        return self.native orelse error.Closed;
    }
    pub fn close(self: *Context) !void {
        if (!supported) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
        const native = self.native orelse return;
        self.busy = true;
        defer self.busy = false;
        self.native = null;
        const status = if (is_windows) zwpw_profile_context_close(native) else zwk_profile_context_close(native);
        std.debug.assert(status == 0);
    }
};

/// Adapter-only metadata, not all allocations owned by the browser engine.
pub fn nativeCounts() NativeCounts {
    var value: NativeCounts = .{};
    if (builtin.os.tag == .linux) zwk_profile_counts(&value.profiles, &value.contexts, &value.bytes) else if (is_windows) zwpw_profile_counts(&value.profiles, &value.contexts, &value.bytes);
    return value;
}
const NativeOptions = extern struct { contexts: u32, bytes: usize, leases: u32 };
const NativeTls = extern struct { certificate_pem: [*:0]const u8, certificate_length: usize, temporary_bytes: usize };
const NativeStats = extern struct { owned_bytes: usize, peak_bytes: usize, contexts: u32, context_capacity: u32, accepting: c_int, leases: u32, lease_capacity: u32 };
fn nativeError(result: c_int) !void {
    return switch (result) {
        0 => {},
        1 => error.Closed,
        2 => error.Full,
        3 => error.OutOfMemory,
        4 => error.InvalidProfile,
        5 => error.WrongThread,
        6 => error.ProfileNativeFailed,
        7 => error.ProfileSystemFailure,
        8 => error.CapacityExceeded,
        9 => error.InvalidTlsCertificate,
        10 => error.TlsBackendUnavailable,
        else => error.ProfileNativeFailed,
    };
}
extern fn zwk_profile_measure([*:0]const u8, [*:0]const u8, [*:0]const u8, *usize) c_int;
extern fn zwk_profile_create(c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8, *const NativeOptions, *?*anyopaque, *c_int) c_int;
extern fn zwk_profile_measure_tls([*:0]const u8, [*:0]const u8, [*:0]const u8, *const NativeTls, *usize) c_int;
extern fn zwk_profile_create_tls(c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8, *const NativeOptions, *const NativeTls, *?*anyopaque, *c_int, *GlibFailure) c_int;
extern fn zwk_profile_seal(*anyopaque) c_int;
extern fn zwk_profile_stats(*anyopaque, *NativeStats) c_int;
extern fn zwk_profile_close(*anyopaque) c_int;
extern fn zwk_profile_lease_retain(*anyopaque) c_int;
extern fn zwk_profile_lease_check(*anyopaque) c_int;
extern fn zwk_profile_lease_release(*anyopaque) c_int;
extern fn zwk_profile_context_create(*anyopaque, *?*anyopaque) c_int;
extern fn zwk_profile_context_admit(*anyopaque) c_int;
extern fn zwk_profile_context_get(*anyopaque, *?*anyopaque) c_int;
extern fn zwk_profile_context_close(*anyopaque) c_int;
extern fn zwk_profile_counts(*u32, *u32, *usize) void;

test "private profile metadata limits and native status remain explicit" {
    try (Limits{}).validate();
    try std.testing.expectError(error.InvalidProfileLimits, (Limits{ .contexts = 0 }).validate());
    try std.testing.expectError(error.InvalidProfileLimits, (Limits{ .contexts = 65 }).validate());
    try std.testing.expectError(error.InvalidProfileLimits, (Limits{ .leases = 0 }).validate());
    try std.testing.expectError(error.InvalidProfileLimits, (Limits{ .leases = 257 }).validate());
    try std.testing.expectError(error.InvalidProfileLimits, (Limits{ .bytes = @sizeOf(Profile) }).validate());
    try std.testing.expectError(error.InvalidProfileLimits, (Limits{ .bytes = 1024 * 1024 + 1 }).validate());
    try std.testing.expectError(error.CapacityExceeded, nativeError(8));
    try std.testing.expectError(error.Full, nativeError(2));
    try std.testing.expectError(error.Closed, nativeError(1));
    if (!supported) {
        var prepared: storage.Prepared = undefined;
        try std.testing.expectError(error.UnsupportedCapability, Profile.create(std.testing.allocator, std.Thread.getCurrentId(), &prepared, .{}));
        try std.testing.expectEqual(@as(u32, 0), nativeCounts().profiles);
    }
}

test {
    _ = tls_policy;
}

extern fn zwpw_profile_measure([*:0]const u16, ?*const NativeTls, *usize, *i32) c_int;
extern fn zwpw_profile_create(*anyopaque, [*:0]const u16, *const NativeOptions, ?*const NativeTls, *?*anyopaque, *i32) c_int;
extern fn zwpw_profile_seal(*anyopaque) c_int;
extern fn zwpw_profile_stats(*anyopaque, *NativeStats) c_int;
extern fn zwpw_profile_close(*anyopaque) c_int;
extern fn zwpw_profile_lease_retain(*anyopaque) c_int;
extern fn zwpw_profile_lease_check(*anyopaque) c_int;
extern fn zwpw_profile_lease_release(*anyopaque) c_int;
extern fn zwpw_profile_context_create(*anyopaque, *?*anyopaque) c_int;
extern fn zwpw_profile_context_admit(*anyopaque) c_int;
extern fn zwpw_profile_context_close(*anyopaque) c_int;
extern fn zwpw_profile_counts(*u32, *u32, *usize) void;
