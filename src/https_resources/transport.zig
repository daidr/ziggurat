const std = @import("std");
const z = @import("ziggurat");
const policy = @import("transport_policy.zig");
const native = @import("transport_native.zig");
const types = @import("types.zig");
const os = @import("builtin").os.tag;
const linux_available = os == .linux and @import("ziggurat_https_resources_options").enabled;
const windows_available = os == .windows and @import("ziggurat_https_resources_options").enabled;
const available = linux_available or windows_available;
const windows = @import("windows_transport.zig");

pub const Counts = native.Counts;
pub fn nativeCounts() Counts {
    var out: Counts = .{};
    if (linux_available) native.zht_counts(&out);
    if (windows_available) {
        const value = windows.counts();
        out = .{ .owners = value.servers, .servers = value.payloads, .bytes = value.bytes };
    }
    return out;
}

/// Explicit TLS127.0.0.1 listener owner. Linux creates on main; Windows prepares
/// on an explicit worker and adopts on main. No hidden worker or event loop,
/// file I/O, certificate generation or trust change. App outlives every method.
/// Seal/close stop admission; already claimed messages remain their Endpoint's
/// duty. Windows also retires unclaimed handshake/header/rejection connections.
pub const Transport = struct {
    pub const Material = policy.Material;
    pub const Failure = native.Failure;
    pub const Limits = struct {
        /// Linux create: project metadata plus fixed PEM capture reservation;
        /// SDK GLib/TLS/socket allocations are separate. Windows adopt: only the
        /// Zig Transport metadata. Windows C reactor/provider use the independent
        /// WorkerLimits budget; stats sum Zig and native requested bytes.
        bytes: usize = 64 * 1024,
        pub fn validate(self: Limits) !void {
            if (self.bytes == 0 or self.bytes > 1024 * 1024) return error.InvalidTransportLimits;
        }
    };
    pub const ClosedHandler = struct { context: *anyopaque, notify: *const fn (*anyopaque) void };
    pub const Options = struct { material: Material, limits: Limits = .{}, on_closed: ?ClosedHandler = null };
    pub const Stats = struct { requested_bytes: usize, peak_reserved_bytes: usize, accepting: bool, port: u16 };
    pub const WorkerLimits = windows.WorkerLimits;
    pub const Prepared = windows.Prepared;
    pub const Listener = windows.Listener;
    pub const Driver = windows.Driver;
    pub const DriverStats = windows.Stats;
    pub const DriverNativeCounts = windows.Counts;
    pub const AdoptOptions = struct { limits: Limits = .{}, on_closed: ?ClosedHandler = null };

    /// Windows explicit-worker preparation. Move only Listener to main. Driver
    /// stays on its original worker, waits for successful adoption, then runs.
    /// No listener dispatch, thread, App or trust exception is created here.
    pub fn prepareOnWorker(main_thread: std.Thread.Id, material: Material, limits: WorkerLimits, failure: ?*?Failure) !Prepared {
        return windows.prepare(main_thread, material, limits, failure);
    }
    /// Windows main-thread adoption consumes Listener only on success. Host App
    /// outlives Driver.run and all accepted/in-flight posts; join the explicit
    /// driver after App.run returns and before App.deinit, including failures.
    pub fn adopt(allocator: std.mem.Allocator, app: *z.App, listener: *Listener, input: AdoptOptions) !*Transport {
        if (!windows_available) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
        try input.limits.validate();
        if (input.limits.bytes < @sizeOf(Transport)) return error.TransportBudgetExceeded;
        // Aggregate by-value arguments may still borrow caller storage. Pass
        // only scalar handler values through this noinline boundary before a
        // caller allocator can mutate the original Options descriptor.
        const closed_enabled = input.on_closed != null;
        const closed_context = if (input.on_closed) |handler| handler.context else null;
        const closed_notify = if (input.on_closed) |handler| handler.notify else null;
        return adoptCaptured(allocator, app, listener, closed_enabled, closed_context, closed_notify);
    }
    noinline fn adoptCaptured(allocator: std.mem.Allocator, app: *z.App, listener: *Listener, closed_enabled: bool, closed_context: ?*anyopaque, closed_notify: ?*const fn (*anyopaque) void) !*Transport {
        const handle = listener.native orelse return error.TransportListenerMoved;
        const app_scope = app.beginCallback() orelse return error.Closed;
        defer app_scope.end();
        windows.zhtw_ref(handle);
        defer windows.zhtw_unref(handle);
        const self = try allocator.create(Transport);
        self.* = .{ .allocator = allocator, .app = app, .handle = handle, .stop_node = .{ .context = self, .stop = stop }, .on_closed = null };
        errdefer {
            self.phase = .closed;
            self.handle = null;
            self.stop_token = null;
            allocator.destroy(self);
        }
        try checkApp(app);
        if (listener.native != handle) return error.TransportListenerMoved;
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer if (self.stop_token) |token| {
            _ = app.cancelStop(token) catch unreachable;
        };
        try checkApp(app);
        if (listener.native != handle) return error.TransportListenerMoved;
        // Infallible ownership publication follows this native gate. It does
        // no allocation or user callback, and cannot reenter this Zig owner.
        try windows.adopt(handle, app);
        listener.native = null;
        self.on_closed = if (closed_enabled) .{ .context = closed_context.?, .notify = closed_notify.? } else null;
        self.phase = .open;
        return self;
    }
    pub fn driverStats(self: *Transport) !DriverStats {
        if (!windows_available) return error.UnsupportedCapability;
        try self.checkOwner();
        if (self.phase == .closed) return error.Closed;
        const scope = self.beginTeardown();
        defer scope.end();
        var out: DriverStats = undefined;
        try native.check(windows.zhtw_stats(self.handle orelse return error.Closed, &out));
        return out;
    }
    pub fn driverNativeCounts() DriverNativeCounts {
        return windows.counts();
    }

    allocator: std.mem.Allocator,
    app: *z.App,
    handle: ?*anyopaque,
    stop_node: z.StopParticipant,
    stop_token: ?z.StopToken = null,
    on_closed: ?ClosedHandler,
    phase: enum { constructing, open, sealed, closing, closed } = .constructing,
    pins: usize = 0,

    /// Inputs remain stable until return; both PEM blocks are copied before
    /// native/caller allocation. First slice accepts one leaf and unencrypted
    /// PKCS#8 key. Native parsing/listening can return a real GLib failure;
    /// successful creation does not prove a matching pair or TLS handshake.
    pub fn create(allocator: std.mem.Allocator, app: *z.App, options: Options) !*Transport {
        return createWithFailure(allocator, app, options, null);
    }
    pub fn createWithFailure(allocator: std.mem.Allocator, app: *z.App, options: Options, failure: ?*?Failure) !*Transport {
        if (failure) |out| out.* = null;
        if (!linux_available) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
        try options.limits.validate();
        return createCaptured(allocator, app, options, failure);
    }
    noinline fn createCaptured(allocator: std.mem.Allocator, app: *z.App, options: Options, failure: ?*?Failure) !*Transport {
        const captured_limits = options.limits;
        const captured_closed = options.on_closed;
        var captured: policy.Captured = undefined;
        defer captured.deinit();
        try captured.init(options.material);
        const app_scope = app.beginCallback() orelse return error.Closed;
        defer app_scope.end();
        var handle: ?*anyopaque = null;
        var native_failure: Failure = .{};
        const result = native.zht_create(&.{ .bytes = captured_limits.bytes, .zig_bytes = @sizeOf(Transport), .temporary_bytes = @sizeOf(policy.Captured), .pem = &captured.bytes, .length = captured.length }, &handle, &native_failure);
        if (result != 0) {
            if (failure) |out| if (native_failure.domain != 0) {
                out.* = native_failure;
            };
            try native.check(result);
            unreachable;
        }
        errdefer {
            native.zht_close(handle.?);
            native.zht_unref(handle.?);
        }
        try checkApp(app);
        const self = try allocator.create(Transport);
        self.* = .{ .allocator = allocator, .app = app, .handle = handle, .stop_node = .{ .context = self, .stop = stop }, .on_closed = null };
        errdefer {
            self.phase = .closed;
            self.handle = null;
            self.stop_token = null;
            allocator.destroy(self);
        }
        try checkApp(app);
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer if (self.stop_token) |token| {
            _ = app.cancelStop(token) catch unreachable;
        };
        try checkApp(app);
        self.on_closed = captured_closed;
        self.phase = .open;
        return self;
    }
    pub fn stats(self: *Transport) !Stats {
        try self.checkOwner();
        if (self.phase == .closed) return error.Closed;
        const scope = self.beginTeardown();
        defer scope.end();
        if (windows_available) {
            var out: windows.Stats = undefined;
            try native.check(windows.zhtw_stats(self.handle.?, &out));
            return .{ .requested_bytes = @sizeOf(Transport) + out.bytes + out.tls_live, .peak_reserved_bytes = @sizeOf(Transport) + out.peak_bytes, .accepting = self.phase == .open and out.accepting != 0 and appOpen(self.app), .port = @intCast(out.port) };
        }
        if (linux_available) {
            var out: native.Stats = undefined;
            try native.check(native.zht_stats(self.handle.?, &out));
            return .{ .requested_bytes = @sizeOf(Transport) + out.bytes, .peak_reserved_bytes = out.peak_bytes, .accepting = self.phase == .open and out.accepting != 0 and appOpen(self.app), .port = @intCast(out.port) };
        }
        return error.UnsupportedCapability;
    }
    /// This copied origin is metadata, not permission or a borrowed server.
    pub fn origin(self: *Transport, output: *[30]u8) ![]const u8 {
        const value = try self.stats();
        if (!value.accepting) return error.Closed;
        return if (value.port == 443) "https://127.0.0.1" else std.fmt.bufPrint(output, "https://127.0.0.1:{d}", .{value.port});
    }
    /// Stops listening/new admission. Windows also closes unclaimed connections;
    /// already claimed requests remain their Site/Endpoint's duty. Close those
    /// owners independently to cancel them. This is not a native/network drain.
    pub fn seal(self: *Transport) !void {
        try self.checkOwner();
        if (self.phase == .closed or self.phase == .closing) return error.Closed;
        const scope = self.beginTeardown();
        defer scope.end();
        self.phase = .sealed;
        if (linux_available) try native.check(native.zht_seal(self.handle.?));
        if (windows_available) try native.check(windows.zhtw_seal(self.handle.?));
    }
    pub fn close(self: *Transport) !types.CloseResult {
        try self.checkOwner();
        if (self.phase == .closed) return .closed;
        if (self.phase == .constructing) return error.NotReady;
        const scope = self.beginTeardown();
        defer scope.end();
        if (self.phase == .closing) return .deferred;
        if (self.stop_token) |token| _ = try self.app.cancelStop(token);
        self.stop_token = null;
        self.phase = .closing;
        if (linux_available) try native.check(native.zht_seal(self.handle.?));
        if (windows_available) try native.check(windows.zhtw_seal(self.handle.?));
        return if (self.pins == 1) .closed else .deferred;
    }
    fn checkOwner(self: *Transport) !void {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
    }
    fn beginTeardown(self: *Transport) Scope {
        const app_scope = self.app.beginTeardownCallback();
        self.pins += 1;
        return .{ .transport = self, .app_scope = app_scope };
    }
    const Scope = struct {
        transport: *Transport,
        app_scope: z.AppCallbackScope,
        fn end(self: Scope) void {
            const app = self.app_scope.app;
            self.transport.release();
            (z.AppCallbackScope{ .app = app }).end();
        }
    };
    fn release(self: *Transport) void {
        std.debug.assert(self.pins > 0);
        self.pins -= 1;
        if (self.pins != 0 or self.phase != .closing) return;
        self.phase = .closed;
        const handle = self.handle;
        self.handle = null;
        const allocator = self.allocator;
        const closed = self.on_closed;
        self.on_closed = null;
        if (linux_available) if (handle) |owner| {
            native.zht_close(owner);
            native.zht_unref(owner);
        };
        if (windows_available) if (handle) |owner| {
            std.debug.assert(windows.zhtw_seal(owner) == 0);
            windows.zhtw_unref(owner);
        };
        allocator.destroy(self);
        if (closed) |callback| callback.notify(callback.context);
    }
    fn stop(context: *anyopaque) !void {
        const self: *Transport = @ptrCast(@alignCast(context));
        const scope = self.beginTeardown();
        defer scope.end();
        self.stop_token = null;
        if (self.phase == .open) self.phase = .sealed;
        if (linux_available) try native.check(native.zht_seal(self.handle.?));
        // Unlike explicit seal, App Stop must also wake/retire half handshakes
        // that have never acquired an Endpoint and cannot be cancelled there.
        if (windows_available) windows.zhtw_cancel(self.handle.?);
    }
};

fn appOpen(app: *z.App) bool {
    return app.phase != .stopping and app.phase != .stopped;
}
fn checkApp(app: *z.App) !void {
    if (!appOpen(app)) return error.Closed;
}

/// Package-private composition seam, intentionally not a Transport method or
/// root export. Caller holds its App activity through finish and final check.
pub fn beginBinding(self: *Transport, app: *z.App) !Binding {
    if (!available) return error.UnsupportedCapability;
    try self.checkOwner();
    if (self.app != app) return error.ForeignApp;
    try checkApp(app);
    if (self.phase != .open) return error.Closed;
    const scope = self.beginTeardown();
    defer scope.end();
    var lease: native.Lease = .{};
    if (linux_available) try native.check(native.zht_lease_begin(self.handle.?, &lease));
    if (windows_available) {
        var port: u16 = 0;
        try native.check(windows.zhtw_lease_begin(self.handle.?, &lease.server, &port));
        lease.owner = lease.server;
        lease.port = port;
    }
    return .{ .lease = lease };
}
const Binding = struct {
    lease: native.Lease,
    pub fn server(self: *const Binding) *types.NativeServer {
        return @ptrCast(self.lease.server.?);
    }
    pub fn port(self: *const Binding) u16 {
        return @intCast(self.lease.port);
    }
    /// Takes its refs before foreign server unref. Result checks the C-only
    /// owner after that last foreign release; no Zig Transport pointer remains.
    pub fn finish(self: *Binding) !void {
        if (linux_available) try native.check(native.zht_lease_finish(&self.lease)) else if (windows_available) {
            self.lease.owner = null;
            try native.check(windows.zhtw_lease_finish(&self.lease.server));
        } else return error.UnsupportedCapability;
    }
};

test {
    _ = policy;
}
test "disabled transport is cold before App material or allocator" {
    if (available) return;
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const invalid: [*]const u8 = @ptrFromInt(1);
    const app: *z.App = @ptrFromInt(@alignOf(z.App));
    try std.testing.expectError(error.UnsupportedCapability, Transport.create(allocator.allocator(), app, .{ .material = .{ .certificate_pem = invalid[0..1], .private_key_pem = invalid[0..1] }, .limits = .{ .bytes = 0 } }));
    try std.testing.expectEqual(@as(usize, 0), allocator.alloc_index);
    try std.testing.expectEqualDeep(Counts{}, nativeCounts());
}

test "disabled worker preparation and adoption preserve inputs before allocator or App access" {
    if (windows_available) return;
    const invalid: [*]const u8 = @ptrFromInt(1);
    try std.testing.expectError(error.UnsupportedCapability, Transport.prepareOnWorker(0, .{ .certificate_pem = invalid[0..1], .private_key_pem = invalid[0..1] }, .{ .bytes = 0, .connections = 0 }, null));
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const app: *z.App = @ptrFromInt(@alignOf(z.App));
    const handle: *anyopaque = @ptrFromInt(8);
    var listener: Transport.Listener = .{ .native = handle };
    try std.testing.expectError(error.UnsupportedCapability, Transport.adopt(allocator.allocator(), app, &listener, .{ .limits = .{ .bytes = 0 } }));
    try std.testing.expectEqual(handle, listener.native.?);
    try std.testing.expectEqual(@as(usize, 0), allocator.alloc_index);
    try std.testing.expectEqualDeep(Transport.DriverNativeCounts{}, Transport.driverNativeCounts());
}

test "disabled worker driver rejects before accessing or consuming its token" {
    if (windows_available) return;
    const handle: *anyopaque = @ptrFromInt(8);
    var driver: Transport.Driver = .{ .native = handle };
    try std.testing.expectError(error.UnsupportedCapability, driver.run(null));
    try std.testing.expectEqual(handle, driver.native.?);
    try std.testing.expectError(error.UnsupportedCapability, driver.cancel());
    try std.testing.expectEqual(handle, driver.native.?);
    try std.testing.expectError(error.UnsupportedCapability, driver.deinit());
    try std.testing.expectEqual(handle, driver.native.?);
    try std.testing.expectEqualDeep(Transport.DriverNativeCounts{}, Transport.driverNativeCounts());
}
