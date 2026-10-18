const std = @import("std");
const z = @import("ziggurat");
const http = @import("ziggurat_http_response");
const Endpoint = @import("endpoint.zig").Endpoint;
const types = @import("types.zig");
const policy = @import("policy.zig");
const native = @import("native.zig");
const transport_owner = @import("transport.zig");
pub const routes = @import("site_routes.zig");
const available = (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .windows) and @import("ziggurat_https_resources_options").enabled;

/// Explicit resource routing on an already-owned HTTPS transport. This owner
/// neither opens a listener nor creates a View, Profile, worker or PageId.
pub const Site = struct {
    pub const Request = struct {
        method: http.Method,
        /// Relative canonical route, full Endpoint path and query are borrowed
        /// only through this callback. None is a filesystem authorization.
        path: []const u8,
        full_path: []const u8,
        query: ?[]const u8,
        /// Same observed Endpoint rows, including names/values, borrowed only
        /// until this callback returns. An Offer/Ticket cannot extend them.
        headers: []const http.Header = &.{},
        /// Merely a borrowed list. Dynamic/file handlers must actually include
        /// it (or mergePolicyHeaders's result) in their own response.
        policy_headers: []const http.Header = &routes.policy_headers,
    };
    pub const Handler = struct {
        context: *anyopaque,
        call: *const fn (*anyopaque, Request, Endpoint.Offer) void,
    };
    pub const ErrorHandler = struct {
        context: *anyopaque,
        call: *const fn (*anyopaque, Request, anyerror) void,
    };
    pub const Options = struct {
        port: u16,
        mount_prefix: []const u8 = "/",
        bearer: [policy.bearer_bytes]u8,
        /// Independent Endpoint admission opt-in; static routes may still send
        /// complete responses. Dynamic/file handlers own all range selection.
        range_requests: bool = false,
        resources: []const routes.Route = &.{},
        /// Explicit fallback only. Static misses never perform filesystem I/O.
        on_resource: ?Handler = null,
        on_error: ?ErrorHandler = null,
        on_closed: ?Endpoint.ClosedHandler = null,
        /// Shared requested/reserved total: Site, static table, Endpoint and
        /// its candidate/borrowed/queued reservations. Route limits are a subset.
        limits: types.Limits = .{},
        route_limits: routes.Limits = .{},
    };
    /// Same route policy, with network identity obtained in one scoped native
    /// lease from the explicit Transport. No caller-supplied port snapshot.
    pub const OnTransportOptions = struct {
        mount_prefix: []const u8 = "/",
        bearer: [policy.bearer_bytes]u8,
        range_requests: bool = false,
        resources: []const routes.Route = &.{},
        on_resource: ?Handler = null,
        on_error: ?ErrorHandler = null,
        on_closed: ?Endpoint.ClosedHandler = null,
        limits: types.Limits = .{},
        route_limits: routes.Limits = .{},
    };
    pub const Stats = struct {
        requested_bytes: usize,
        peak_reserved_bytes: usize,
        static_bytes: usize,
        static_requests: usize,
        dynamic_requests: usize,
        not_found: usize,
        transport: types.Stats,
    };

    allocator: std.mem.Allocator,
    app: *z.App,
    endpoint: ?*Endpoint,
    table: routes.Owned,
    port: u16,
    handler: ?Handler,
    on_error: ?ErrorHandler,
    on_closed: ?Endpoint.ClosedHandler,
    phase: enum { constructing, open, closing, closed } = .constructing,
    pins: usize = 0,
    static_requests: usize = 0,
    dynamic_requests: usize = 0,
    not_found: usize = 0,

    /// The host owns the immutable TLS-only loopback server/listener contract
    /// described by Endpoint. App outlives Site methods and explicit close.
    /// Input bytes stay stable until return; success owns all static bytes.
    pub fn create(allocator: std.mem.Allocator, app: *z.App, server: *types.NativeServer, options: Options) !*Site {
        if (@import("builtin").os.tag != .linux or !available) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
        try options.limits.validate();
        try options.route_limits.validate();
        if (options.resources.len > options.route_limits.max_routes) return error.TooManySiteRoutes;
        return createCaptured(allocator, app, server, options);
    }
    pub fn createOnTransport(allocator: std.mem.Allocator, app: *z.App, transport: *transport_owner.Transport, options: OnTransportOptions) !*Site {
        if (!available) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
        try options.limits.validate();
        try options.route_limits.validate();
        if (options.resources.len > options.route_limits.max_routes) return error.TooManySiteRoutes;
        return createOnTransportCaptured(allocator, app, transport, options);
    }
    noinline fn createOnTransportCaptured(allocator: std.mem.Allocator, app: *z.App, transport: *transport_owner.Transport, input: OnTransportOptions) !*Site {
        var descriptors: [routes.capacity]routes.Route = undefined;
        @memcpy(descriptors[0..input.resources.len], input.resources);
        var options = input;
        options.resources = descriptors[0..input.resources.len];
        const app_scope = app.beginCallback() orelse return error.Closed;
        defer app_scope.end();
        var binding = try transport_owner.beginBinding(transport, app);
        var owns_binding = true;
        defer if (owns_binding) binding.finish() catch {};
        const result = try createWithDescriptors(allocator, app, binding.server(), .{
            .port = binding.port(),
            .mount_prefix = options.mount_prefix,
            .bearer = options.bearer,
            .range_requests = options.range_requests,
            .resources = options.resources,
            .on_resource = options.on_resource,
            .on_error = options.on_error,
            .on_closed = options.on_closed,
            .limits = options.limits,
            .route_limits = options.route_limits,
        });
        errdefer result.abortConstruction();
        // Endpoint now has its own server pin. The temporary lease's foreign
        // unref can seal/close its Transport; only its independent C pin and
        // the saved App are inspected afterwards, never the Transport pointer.
        owns_binding = false;
        const status = binding.finish();
        if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
        try status;
        return result;
    }
    noinline fn createCaptured(allocator: std.mem.Allocator, app: *z.App, server: *types.NativeServer, input: Options) !*Site {
        // Even native reference operations can run host object callbacks.
        // Capture descriptors before the server lease or any foreign entry;
        // input bytes themselves remain stable through this constructor.
        var descriptors: [routes.capacity]routes.Route = undefined;
        @memcpy(descriptors[0..input.resources.len], input.resources);
        var options = input;
        options.resources = descriptors[0..input.resources.len];
        return createWithDescriptors(allocator, app, server, options);
    }
    fn createWithDescriptors(allocator: std.mem.Allocator, app: *z.App, server: *types.NativeServer, options: Options) !*Site {
        const app_scope = app.beginCallback() orelse return error.Closed;
        defer app_scope.end();
        var security: policy.Policy = undefined;
        try security.captureInto(options.port, options.mount_prefix, options.bearer);
        security.range_requests = options.range_requests;
        defer std.crypto.secureZero(u8, &security.bearer);
        var transport_lease: ?*anyopaque = null;
        try native.check(native.zhr_server_pin(server, &transport_lease));
        defer if (transport_lease) |lease| native.zhr_server_unpin(lease);
        if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
        if (options.limits.bytes <= @sizeOf(Site)) return error.SiteBudgetExceeded;
        var route_limits = options.route_limits;
        route_limits.bytes = @min(route_limits.bytes, options.limits.bytes - @sizeOf(Site));
        var table = try routes.Owned.init(allocator, security.prefix(), options.resources, route_limits);
        var table_owns = true;
        errdefer if (table_owns) table.deinit();
        const fixed_bytes = @sizeOf(Site) + table.storage.?.len;
        if (fixed_bytes >= options.limits.bytes) return error.SiteBudgetExceeded;
        var endpoint_limits = options.limits;
        endpoint_limits.bytes -= fixed_bytes;
        if (endpoint_limits.bytes < 64 * 1024) return error.SiteBudgetExceeded;
        var authority: [22]u8 = undefined;
        const uri_prefix_bytes = "https://".len + security.authority(&authority).len + table.mount.len - 1;
        for (table.routes) |row| {
            if (row.path.len > policy.uri_capacity - uri_prefix_bytes) return error.UriTooLong;
            if (row.bytes.len > endpoint_limits.max_response_bytes) return error.ResourceTooLarge;
        }
        if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
        const self = try allocator.create(Site);
        self.* = .{
            .allocator = allocator,
            .app = app,
            .endpoint = null,
            .table = table,
            .port = security.port,
            .handler = options.on_resource,
            .on_error = options.on_error,
            .on_closed = options.on_closed,
        };
        table_owns = false;
        errdefer self.abortConstruction();
        if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
        self.endpoint = try Endpoint.create(allocator, app, @ptrCast(transport_lease.?), .{
            .port = security.port,
            .mount_prefix = table.mount,
            .bearer = security.bearer,
            .range_requests = security.range_requests,
            .context = self,
            .on_request = dispatch,
            .on_closed = .{ .context = self, .notify = endpointClosed },
            .limits = endpoint_limits,
        });
        // Endpoint now independently owns the server. Withdraw this temporary
        // lease before foreign unref, then recheck the App before publication.
        const lease = transport_lease.?;
        transport_lease = null;
        native.zhr_server_unpin(lease);
        if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
        self.phase = .open;
        return self;
    }
    pub fn origin(self: *Site, output: *[30]u8) ![]const u8 {
        try self.checkOwner();
        if (self.phase != .open) return error.Closed;
        if (self.port == 443) return "https://127.0.0.1";
        return std.fmt.bufPrint(output, "https://127.0.0.1:{d}", .{self.port});
    }
    pub fn stats(self: *Site) !Stats {
        try self.checkOwner();
        if (self.phase != .open) return error.Closed;
        const scope = self.beginTeardown();
        defer scope.end();
        const transport = try self.endpoint.?.stats();
        const fixed = @sizeOf(Site) + self.table.storage.?.len;
        return .{
            .requested_bytes = fixed + transport.requested_bytes,
            .peak_reserved_bytes = fixed + transport.peak_reserved_bytes,
            .static_bytes = fixed,
            .static_requests = self.static_requests,
            .dynamic_requests = self.dynamic_requests,
            .not_found = self.not_found,
            .transport = transport,
        };
    }
    /// Stop seals Endpoint ingress but does not destroy this owner. close is
    /// explicit; on_closed is not a listener/browser/native-quiescence barrier.
    pub fn close(self: *Site) !types.CloseResult {
        try self.checkOwner();
        if (self.phase == .closed) return .closed;
        if (self.phase == .constructing) return error.NotReady;
        const scope = self.beginTeardown();
        defer scope.end();
        if (self.phase == .closing) return .deferred;
        self.phase = .closing;
        _ = self.endpoint.?.close() catch |err| {
            self.phase = .open;
            return err;
        };
        return if (self.endpoint == null and self.pins == 1) .closed else .deferred;
    }
    fn checkOwner(self: *Site) !void {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
    }
    fn abortConstruction(self: *Site) void {
        // Failed construction never notifies the user's closed callback. Pin
        // the composite while closing a successfully built Endpoint; its own
        // closed callback may run synchronously and releases no borrowed stack.
        self.on_closed = null;
        self.phase = .closing;
        self.pins += 1;
        if (self.endpoint) |endpoint| _ = endpoint.close() catch unreachable;
        self.release();
    }
    fn dispatch(context: *anyopaque, _: *Endpoint, request: Endpoint.Request, offer: Endpoint.Offer) void {
        const self: *Site = @ptrCast(@alignCast(context));
        if (self.phase != .open) return;
        const app_scope = self.app.beginCallback() orelse return;
        self.pins += 1;
        const scope: Scope = .{ .site = self, .app_scope = app_scope };
        defer scope.end();
        const relative = self.table.relative(request.path);
        const input: Request = .{ .method = request.method, .path = relative orelse "", .full_path = request.path, .query = request.query, .headers = request.headers };
        // A path outside this literal grammar is a miss with no dynamic
        // fallback. No ambiguous input can be forwarded to a directory lookup.
        if (relative) |path| {
            if (self.table.find(path)) |route| {
                self.static_requests +|= 1;
                self.respondStatic(offer, request.method, 200, route) catch |err| self.report(input, err);
                return;
            }
            if (self.handler) |handler| {
                self.dynamic_requests +|= 1;
                handler.call(handler.context, input, offer);
                return;
            }
        }
        self.not_found +|= 1;
        self.respondStatic(offer, request.method, 404, .{ .path = "/", .mime = "text/plain; charset=utf-8", .bytes = "Not Found" }) catch |err| self.report(input, err);
    }
    fn respondStatic(_: *Site, offer: Endpoint.Offer, method: http.Method, status: u16, route: routes.Route) !void {
        var receipt = if (method == .head)
            try offer.respondHead(.{ .status = status, .mime = route.mime, .headers = &routes.policy_headers, .length = route.bytes.len })
        else
            try offer.respondBorrowed(.{ .status = status, .mime = route.mime, .headers = &routes.policy_headers, .bytes = route.bytes });
        defer receipt.deinit();
    }
    fn report(self: *Site, request: Request, failure: anyerror) void {
        if (self.on_error) |handler| handler.call(handler.context, request, failure);
    }
    fn endpointClosed(context: *anyopaque) void {
        const self: *Site = @ptrCast(@alignCast(context));
        const scope = self.beginTeardown();
        defer scope.end();
        std.debug.assert(self.phase == .closing);
        self.endpoint = null;
    }
    fn beginTeardown(self: *Site) Scope {
        const scope = self.app.beginTeardownCallback();
        self.pins += 1;
        return .{ .site = self, .app_scope = scope };
    }
    const Scope = struct {
        site: *Site,
        app_scope: z.AppCallbackScope,
        fn end(self: Scope) void {
            const app = self.app_scope.app;
            self.site.release();
            (z.AppCallbackScope{ .app = app }).end();
        }
    };
    fn release(self: *Site) void {
        std.debug.assert(self.pins != 0);
        self.pins -= 1;
        if (self.pins != 0 or self.phase != .closing or self.endpoint != null) return;
        self.phase = .closed;
        const allocator = self.allocator;
        var table = self.table;
        self.table.storage = null;
        self.table.mount = "";
        self.table.routes = &.{};
        const closed = self.on_closed;
        self.on_closed = null;
        self.handler = null;
        self.on_error = null;
        table.deinit();
        allocator.destroy(self);
        if (closed) |handler| handler.notify(handler.context);
    }
};

test "unsupported Site is cold before App server descriptors or allocation" {
    if (available) return;
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const app: *z.App = @ptrFromInt(@alignOf(z.App));
    const server: *types.NativeServer = @ptrFromInt(8);
    const invalid: [*]const u8 = @ptrFromInt(1);
    const resources: [*]const routes.Route = @ptrFromInt(@alignOf(routes.Route));
    try std.testing.expectError(error.UnsupportedCapability, Site.create(allocator.allocator(), app, server, .{
        .port = 0,
        .mount_prefix = invalid[0..1],
        .bearer = @splat(0),
        .resources = resources[0..1],
        .limits = .{ .bytes = 0 },
    }));
    const transport: *transport_owner.Transport = @ptrFromInt(@alignOf(transport_owner.Transport));
    try std.testing.expectError(error.UnsupportedCapability, Site.createOnTransport(allocator.allocator(), app, transport, .{
        .mount_prefix = invalid[0..1],
        .bearer = @splat(0),
        .resources = resources[0..1],
        .limits = .{ .bytes = 0 },
    }));
    try std.testing.expectEqual(@as(usize, 0), allocator.alloc_index);
}
