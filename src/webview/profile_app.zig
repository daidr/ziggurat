const std = @import("std");
const native = @import("profile.zig");

/// The optional public owner embeds the private native owner in its one
/// allocation. Ordinary ephemeral Views do not construct either object.
pub fn Type(comptime z: type) type {
    return struct {
        const Self = @This();
        pub const Limits = native.Limits;
        pub const Stats = native.Stats;
        pub const Prepared = native.storage.Prepared;
        pub const CreateOptions = native.CreateOptions;
        pub const LoopbackHttps = native.LoopbackHttps;
        pub const Failure = native.Failure;

        base: native.Profile,
        app: *z.App,
        stop_node: z.StopParticipant,
        stop_token: ?z.StopToken = null,

        /// App outlives all uses of this Profile, including close. Stop seals
        /// new ingress; the host still closes the surviving owner explicitly.
        /// The prepared directory is adopted on this App's main thread first.
        pub fn create(allocator: std.mem.Allocator, app: *z.App, prepared: *Prepared, limits: Limits) !*Self {
            return createWithFailure(allocator, app, prepared, limits, null);
        }
        pub fn createWithFailure(allocator: std.mem.Allocator, app: *z.App, prepared: *Prepared, limits: Limits, system_errno: ?*?i32) !*Self {
            if (system_errno) |output| output.* = null;
            if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
            const scope = app.beginCallback() orelse return error.Closed;
            defer scope.end();
            if (!native.supported) return error.UnsupportedCapability;
            return createCaptured(allocator, app, prepared, limits, null, system_errno, null);
        }
        pub fn createWithOptions(allocator: std.mem.Allocator, app: *z.App, prepared: *Prepared, options: CreateOptions) !*Self {
            return createWithOptionsAndFailure(allocator, app, prepared, options, null);
        }
        /// Real errno, GLib certificate-parser or Windows HRESULT diagnostics only. Validation,
        /// capacity and caller allocator errors leave failure null.
        pub fn createWithOptionsAndFailure(allocator: std.mem.Allocator, app: *z.App, prepared: *Prepared, options: CreateOptions, failure: ?*?Failure) !*Self {
            if (failure) |output| output.* = null;
            if (!native.supported) return error.UnsupportedCapability;
            if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
            const scope = app.beginCallback() orelse return error.Closed;
            defer scope.end();
            if (options.loopback_https) |tls| return createTls(allocator, app, prepared, options.limits, tls, failure);
            return createCaptured(allocator, app, prepared, options.limits, null, null, failure);
        }
        noinline fn createTls(allocator: std.mem.Allocator, app: *z.App, prepared: *Prepared, limits: Limits, tls: LoopbackHttps, failure: ?*?Failure) !*Self {
            var captured: native.tls_policy.Captured = undefined;
            try captured.captureInto(tls);
            return createCaptured(allocator, app, prepared, limits, &captured, null, failure);
        }
        fn createCaptured(allocator: std.mem.Allocator, app: *z.App, prepared: *Prepared, limits: Limits, captured: ?*const native.tls_policy.Captured, system_errno: ?*?i32, failure: ?*?Failure) !*Self {
            var construction = try native.Construction.beginWithTls(prepared, limits, @sizeOf(Self), captured);
            errdefer construction.abort();
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .base = .{ .allocator = allocator, .owner = app.owner, .native = null, .busy = true, .owner_bytes = @sizeOf(Self) },
                .app = app,
                .stop_node = .{ .context = self, .stop = stop },
            };
            try checkApp(app);
            self.stop_token = try app.registerStop(&self.stop_node);
            errdefer {
                if (self.stop_token) |token| _ = app.cancelStop(token) catch unreachable;
                self.stop_token = null;
            }
            self.base.native = try construction.createNativeWithFailure(system_errno, failure);
            errdefer {
                self.base.busy = false;
                self.base.releaseNative() catch unreachable;
            }
            try checkApp(app);
            self.base.busy = false;
            return self;
        }

        pub fn stats(self: *Self) !Stats {
            try self.check();
            return self.base.stats();
        }
        pub fn seal(self: *Self) !void {
            try self.check();
            const scope = self.app.beginTeardownCallback();
            defer scope.end();
            try self.base.seal();
        }
        /// Private View integration. The App identity is checked before any
        /// allocation, and the result retains only C state, never this pointer.
        pub fn retainForApp(self: *Self, app: *z.App) !native.ConfigLease {
            try self.check();
            if (self.app != app) return error.ForeignApp;
            const scope = app.beginCallback() orelse return error.Closed;
            defer scope.end();
            return self.base.retainConfig();
        }
        pub fn close(self: *Self) !void {
            try self.check();
            const app = self.app;
            const scope = app.beginTeardownCallback();
            defer scope.end();
            self.base.busy = true;
            errdefer self.base.busy = false;
            // A taken stop node cannot be freed by another participant. Keep
            // every field live if cancellation reports StopInProgress.
            if (self.stop_token) |token| _ = try app.cancelStop(token);
            self.stop_token = null;
            const allocator = self.base.allocator;
            self.base.busy = false;
            try self.base.releaseNative();
            allocator.destroy(self);
            // Only the captured App scope is touched after the final free.
        }
        fn check(self: *Self) !void {
            if (std.Thread.getCurrentId() != self.base.owner) return error.WrongThread;
            if (self.base.busy) return error.Busy;
            if (self.base.native == null) return error.Closed;
        }
        fn checkApp(app: *z.App) !void {
            if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
        }
        fn stop(context: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.stop_token = null;
            try self.base.seal();
        }
    };
}
