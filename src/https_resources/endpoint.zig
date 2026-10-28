const std = @import("std");
const available = (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .windows) and @import("ziggurat_https_resources_options").enabled;
const z = @import("ziggurat");
const http = @import("ziggurat_http_response");
const files = @import("ziggurat_file_stream");
const policy = @import("policy.zig");
const types = @import("types.zig");
const native = @import("native.zig");
const file_response = @import("file_response.zig");

/// An explicitly attached resource consumer on the host's existing HTTPS
/// SoupServer. It owns no listener, Window, worker, network timeout or keepalive.
pub const Endpoint = struct {
    pub const Request = struct {
        method: http.Method,
        /// Canonical SDK path/query borrowed only through on_request. There is no
        /// implicit filesystem mapping, percent decoding, Cookie authentication
        /// or relation to a WebView resource ID or Producer acknowledgement.
        path: []const u8,
        query: ?[]const u8,
        /// Observed validated rows, borrowed only through on_request return.
        /// Respond/defer/Ticket do not retain them. Copy only needed values
        /// before posting work; do not log the whole list or credentials.
        headers: []const http.Header = &.{},
    };
    pub const ClosedHandler = struct { context: *anyopaque, notify: *const fn (*anyopaque) void };
    pub const Options = struct {
        port: u16,
        mount_prefix: []const u8 = "/",
        bearer: [policy.bearer_bytes]u8,
        /// Explicitly admit observed Range. Browser permission, authentication
        /// and host response selection remain independent. HEAD ignores its
        /// semantics within existing generic header budgets.
        range_requests: bool = false,
        context: *anyopaque,
        on_request: *const fn (*anyopaque, *Endpoint, Request, Offer) void,
        on_closed: ?ClosedHandler = null,
        limits: types.Limits = .{},
    };
    /// Callback-stack borrow. Do not retain it, or a copy, after on_request.
    pub const Offer = struct {
        endpoint: *Endpoint,
        native_borrow: *anyopaque,
        pub fn deferRequest(self: Offer) !Ticket {
            const owner = self.endpoint;
            try owner.checkOwner();
            const scope = owner.beginBusiness() orelse return error.Closed;
            defer scope.end();
            if (owner.busy) return error.Busy;
            owner.busy = true;
            defer owner.busy = false;
            try owner.checkIngress();
            var out: ?*anyopaque = null;
            if (available) try native.check(native.zhr_defer(self.native_borrow, &out)) else return error.UnsupportedCapability;
            return .{ .native_ticket = out };
        }
        pub fn respondOwned(self: Offer, value: *http.OwnedResponse) !types.Receipt {
            return self.endpoint.respond(.{ .borrow = self.native_borrow }, .{ .owned = value }, .{}, null);
        }
        /// Response bytes stay borrowed and stable until return. Native owns
        /// its copy before acceptance. The response is never consumed, while
        /// the Offer's accepted response duty still transfers exactly once.
        pub fn respondBorrowed(self: Offer, value: http.Response) !types.Receipt {
            if (!available) return error.UnsupportedCapability;
            var captured: BorrowedCapture = undefined;
            try captured.init(value);
            return self.endpoint.respond(.{ .borrow = self.native_borrow }, .{ .borrowed = captured.response }, .{}, null);
        }
        pub fn respondHead(self: Offer, value: types.Head) !types.Receipt {
            return self.endpoint.respond(.{ .borrow = self.native_borrow }, .{ .head = value }, .{}, null);
        }
        pub fn respondSource(self: Offer, metadata: types.Head, source: *files.PreparedSource, options: types.ResponseOptions) !types.Receipt {
            return self.endpoint.respond(.{ .borrow = self.native_borrow }, .{ .file = .{ .head = metadata, .source = source } }, options, null);
        }
        /// Stable, linear helper value until return. Failure retains it;
        /// acceptance consumes it even when close/Stop cancels the send.
        pub noinline fn respondPreparedFile(self: Offer, response: *file_response.PreparedFileResponse, options: types.ResponseOptions) !types.Receipt {
            if (!available) return error.UnsupportedCapability;
            var captured: file_response.Metadata = undefined;
            try captured.init(response);
            return self.endpoint.respond(.{ .borrow = self.native_borrow }, .{ .prepared = .{ .head = captured.head, .response = response } }, options, null);
        }
    };
    /// Independent linear C-only responsibility. Can outlive Endpoint/App.
    /// Passing to App.post does not transfer it unless that post succeeds.
    /// release/cancel are thread-safe; responses run only on process main.
    pub const Ticket = struct {
        native_ticket: ?*anyopaque,
        pub fn deinit(self: *Ticket) void {
            const handle = self.native_ticket;
            self.native_ticket = null;
            if (available) if (handle) |value| native.zhr_ticket_release(value);
        }
        pub fn cancel(self: Ticket) !void {
            const handle = self.native_ticket orelse return error.TicketMoved;
            if (available) try native.check(native.zhr_ticket_cancel(handle)) else return error.UnsupportedCapability;
        }
        fn owner(self: Ticket) !*Endpoint {
            const handle = self.native_ticket orelse return error.TicketMoved;
            if (!available) return error.UnsupportedCapability;
            var out: ?*anyopaque = null;
            try native.check(native.zhr_ticket_owner(handle, &out));
            return @ptrCast(@alignCast(out.?));
        }
        pub fn respondOwned(self: *Ticket, value: *http.OwnedResponse) !types.Receipt {
            const endpoint = try self.owner();
            return endpoint.respond(.{ .ticket = self.native_ticket }, .{ .owned = value }, .{}, self);
        }
        /// Failure preserves the Ticket. Acceptance consumes the Ticket even
        /// when Stop cancels delivery; only the input Response is not consumed.
        pub fn respondBorrowed(self: *Ticket, value: http.Response) !types.Receipt {
            if (!available) return error.UnsupportedCapability;
            var captured: BorrowedCapture = undefined;
            try captured.init(value);
            const endpoint = try self.owner();
            return endpoint.respond(.{ .ticket = self.native_ticket }, .{ .borrowed = captured.response }, .{}, self);
        }
        pub fn respondHead(self: *Ticket, value: types.Head) !types.Receipt {
            const endpoint = try self.owner();
            return endpoint.respond(.{ .ticket = self.native_ticket }, .{ .head = value }, .{}, self);
        }
        pub fn respondSource(self: *Ticket, metadata: types.Head, source: *files.PreparedSource, options: types.ResponseOptions) !types.Receipt {
            const endpoint = try self.owner();
            return endpoint.respond(.{ .ticket = self.native_ticket }, .{ .file = .{ .head = metadata, .source = source } }, options, self);
        }
        pub noinline fn respondPreparedFile(self: *Ticket, response: *file_response.PreparedFileResponse, options: types.ResponseOptions) !types.Receipt {
            if (!available) return error.UnsupportedCapability;
            // Capture descriptors and formatted metadata before native owner
            // lookup. Only stable inline bytes remain borrowed until return.
            var captured: file_response.Metadata = undefined;
            try captured.init(response);
            const endpoint = try self.owner();
            return endpoint.respond(.{ .ticket = self.native_ticket }, .{ .prepared = .{ .head = captured.head, .response = response } }, options, self);
        }
        fn consume(self: *Ticket) void {
            const handle = self.native_ticket;
            self.native_ticket = null;
            if (available) if (handle) |value| native.zhr_ticket_consume(value);
        }
    };

    allocator: std.mem.Allocator,
    app: *z.App,
    native_owner: ?*anyopaque,
    security: policy.Policy,
    limits: types.Limits,
    handler: struct { context: *anyopaque, call: *const fn (*anyopaque, *Endpoint, Request, Offer) void },
    on_closed: ?ClosedHandler,
    stop_node: z.StopParticipant,
    stop_token: ?z.StopToken = null,
    phase: enum { open, stopped, closing, closed } = .open,
    pins: usize = 0,
    busy: bool = false,
    borrowed_input: usize = 0,

    /// The host keeps App alive through explicit close, and the native server's
    /// single canonical IPv4 TLS listener, raw-paths=true and exclusive prefix unchanged until
    /// Endpoint close. The constructor pins native server and captures all
    /// security input before the first caller allocator callback.
    pub fn create(allocator: std.mem.Allocator, app: *z.App, server: *types.NativeServer, options: Options) !*Endpoint {
        if (!available) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
        const app_scope = app.beginCallback() orelse return error.Closed;
        defer app_scope.end();
        try options.limits.validate();
        var captured: policy.Policy = undefined;
        try captured.captureInto(options.port, options.mount_prefix, options.bearer);
        captured.range_requests = options.range_requests;
        defer std.crypto.secureZero(u8, &captured.bearer);
        if (options.limits.bytes <= @sizeOf(Endpoint) + native.zhr_owner_size()) return error.CapacityExceeded;
        var handle: ?*anyopaque = null;
        try native.check(native.zhr_create(server, &.{ .bytes = options.limits.bytes - @sizeOf(Endpoint), .pending = options.limits.max_pending, .port = captured.port, .file_streams = options.limits.max_file_streams, .prefix = native.Slice.from(captured.prefix()) }, &handle));
        errdefer {
            native.zhr_close(handle.?);
            native.zhr_owner_release(handle.?);
        }
        const self = try allocator.create(Endpoint);
        errdefer {
            // Binding can reenter native host cleanup before the constructor's
            // final App check. Withdraw the native callback context before the
            // last caller allocator free can release this candidate address.
            self.phase = .closed;
            self.busy = true;
            self.native_owner = null;
            self.stop_token = null;
            self.on_closed = null;
            native.zhr_seal(handle.?);
            std.crypto.secureZero(u8, &self.security.bearer);
            allocator.destroy(self);
        }
        self.* = .{ .allocator = allocator, .app = app, .native_owner = handle, .security = captured, .limits = options.limits, .handler = .{ .context = options.context, .call = options.on_request }, .on_closed = options.on_closed, .stop_node = .{ .context = self, .stop = stop }, .busy = true };
        try self.checkApp();
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer if (self.stop_token) |token| {
            _ = app.cancelStop(token) catch unreachable;
        };
        const bind_status = native.zhr_bind(handle.?, self, filter, offer);
        // A replaced host handler can request Stop while native binding also
        // discovers revoked transport. Recheck business permission after the
        // foreign return, before publishing or reporting that native status.
        try self.checkApp();
        try native.check(bind_status);
        try self.checkIngress();
        self.busy = false;
        return self;
    }
    pub fn stats(self: *Endpoint) !types.Stats {
        try self.checkOwner();
        var result: native.Stats = undefined;
        if (available) try native.check(native.zhr_stats(self.native_owner orelse return error.Closed, &result)) else return error.UnsupportedCapability;
        return .{ .requested_bytes = @sizeOf(Endpoint) + result.bytes, .peak_reserved_bytes = @sizeOf(Endpoint) + result.peak_bytes, .borrowed_input_bytes = self.borrowed_input, .queued_payload_reservation = result.queued_payload_reservation, .physical_pending = result.physical_pending, .accepting = self.phase == .open and result.accepting != 0 and self.app.phase != .stopping and self.app.phase != .stopped };
    }
    pub fn close(self: *Endpoint) !types.CloseResult {
        try self.checkOwner();
        // The allocator's last free callback still sees valid storage, but all
        // owning fields have already been withdrawn. Do not repin/reopen it.
        if (self.phase == .closed) return .closed;
        const scope = self.beginTeardown();
        defer scope.end();
        if (self.phase == .closing) return .deferred;
        if (self.stop_token) |token| _ = try self.app.cancelStop(token);
        self.stop_token = null;
        self.phase = .closing;
        if (available) native.zhr_seal(self.native_owner.?);
        return if (self.pins == 1) .closed else .deferred;
    }
    const Input = union(enum) {
        owned: *http.OwnedResponse,
        borrowed: http.Response,
        head: types.Head,
        file: struct { head: types.Head, source: *files.PreparedSource },
        prepared: struct { head: types.Head, response: *file_response.PreparedFileResponse },
    };
    fn respond(self: *Endpoint, target: native.Target, input: Input, options: types.ResponseOptions, ticket: ?*Ticket) !types.Receipt {
        if (!available) return error.UnsupportedCapability;
        try self.checkOwner();
        const scope = self.beginBusiness() orelse return error.Closed;
        defer scope.end();
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        try self.checkIngress();
        var response: http.Response = undefined;
        var representation: u64 = 0;
        var borrowed: usize = 0;
        switch (input) {
            .owned => |owned| {
                const storage = owned.storage orelse return error.ResponseMoved;
                response = owned.response;
                try http.validateResponse(response, self.limits.max_response_bytes);
                borrowed = storage.len;
                representation = response.bytes.len;
            },
            .borrowed => |value| {
                response = value;
                try http.validateResponse(response, self.limits.max_response_bytes);
                borrowed = response.bytes.len + response.mime.len + response.headers.len * @sizeOf(http.Header);
                for (response.headers) |row| borrowed += row.name.len + row.value.len;
                representation = response.bytes.len;
            },
            .head, .file, .prepared => {
                var head = switch (input) {
                    .head => input.head,
                    .file => input.file.head,
                    .prepared => input.prepared.head,
                    else => unreachable,
                };
                response = .{ .status = head.status, .mime = head.mime, .headers = head.headers };
                representation = if (input == .file) try input.file.source.authoritativeLength() else if (input == .prepared and input.prepared.response.source != null) try input.prepared.response.source.?.authoritativeLength() else head.length;
                if (input == .prepared and representation != head.length) return error.FileSourceChanged;
                head.length = representation;
                try head.validate(self.limits.max_file_bytes);
                borrowed = head.mime.len + head.headers.len * @sizeOf(http.Header);
                for (head.headers) |row| borrowed += row.name.len + row.value.len;
            },
        }
        const handle = self.native_owner.?;
        try native.check(native.zhr_borrow_input(handle, borrowed));
        self.borrowed_input = borrowed;
        defer {
            native.zhr_return_input(handle);
            self.borrowed_input = 0;
        }
        var headers: [16]native.Header = undefined;
        for (response.headers, 0..) |row, i| headers[i] = .{ .name = native.Slice.from(row.name), .value = native.Slice.from(row.value) };
        const descriptor: native.Response = .{ .status = response.status, .mime = native.Slice.from(response.mime), .headers = &headers, .header_count = response.headers.len, .body = native.Slice.from(response.bytes), .length = representation };
        var candidate: ?*anyopaque = null;
        const status = switch (input) {
            .owned, .borrowed => native.zhr_prepare_memory(target, &descriptor, &candidate),
            .head => native.zhr_prepare_head(target, &descriptor, &candidate),
            .file => |file| native.zhr_prepare_file(target, &descriptor, file.source.native.?, &candidate),
            .prepared => |file| if (file.response.source) |source| native.zhr_prepare_file(target, &descriptor, source.native.?, &candidate) else native.zhr_prepare_memory(target, &descriptor, &candidate),
        };
        try native.check(status);
        var accepted = false;
        defer if (!accepted) native.zhr_candidate_abort(candidate.?);
        // Every project/native candidate allocation and temporary foreign cleanup
        // has returned. The remaining publication step is allocation/callback free.
        try self.checkIngress();
        try native.check(native.zhr_candidate_check(candidate.?, self));
        var control: ?*anyopaque = null;
        const cancelled = native.zhr_candidate_admit(candidate.?, @intFromBool(options.file_control), &control) != 0;
        accepted = true;
        if (input != .prepared) if (ticket) |value| value.consume();
        switch (input) {
            .owned => |owned| owned.deinit(),
            .file => |file| {
                var moved = file.source.*;
                file.source.native = null;
                file.source.length = 0;
                // The neutral source's release cancels unadmitted pumps. Its
                // owning field is withdrawn first, then the accepted stream is
                // activated before releasing the transferred physical ref.
                native.zhr_candidate_admit_source(candidate.?);
                moved.deinit();
            },
            .head, .borrowed => {},
            .prepared => |file| consumePrepared(file.response, candidate.?, ticket),
        }
        // Final caller cleanup can request App shutdown after pure publication.
        // The accepted duty is still consumed, but no new HTTP send is started
        // with revoked business permission. This is never a retryable error.
        if (self.phase != .open or self.app.phase == .stopping or self.app.phase == .stopped) native.zhr_seal(handle);
        const late_cancel = native.zhr_candidate_start(candidate.?) != 0;
        return .{ .state = if (cancelled or late_cancel) .accepted_cancelled else .accepted, .control = if (control) |value| .{ .native = value } else null };
    }
    /// This opt-in helper has no caller-visible tail after foreign cleanup.
    /// Withdraw every helper owning field before ticket/source final releases;
    /// later native work only sees its independently copied candidate.
    noinline fn consumePrepared(response: *file_response.PreparedFileResponse, candidate: *anyopaque, ticket: ?*Ticket) void {
        var source = response.source;
        response.source = null;
        response.ready = false;
        if (ticket) |value| value.consume();
        if (source) |*value| {
            native.zhr_candidate_admit_source(candidate);
            value.deinit();
        }
    }
    fn checkOwner(self: *Endpoint) !void {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
    }
    fn checkApp(self: *Endpoint) !void {
        if (self.phase != .open or self.app.phase == .stopping or self.app.phase == .stopped) return error.Closed;
    }
    fn checkIngress(self: *Endpoint) !void {
        try self.checkApp();
        if (available) try native.check(native.zhr_check(self.native_owner orelse return error.Closed)) else return error.UnsupportedCapability;
    }
    fn beginBusiness(self: *Endpoint) ?Scope {
        if (self.phase != .open) return null;
        const scope = self.app.beginCallback() orelse return null;
        self.pins += 1;
        return .{ .endpoint = self, .app_scope = scope };
    }
    fn beginTeardown(self: *Endpoint) Scope {
        const scope = self.app.beginTeardownCallback();
        self.pins += 1;
        return .{ .endpoint = self, .app_scope = scope };
    }
    const Scope = struct {
        endpoint: *Endpoint,
        app_scope: z.AppCallbackScope,
        fn end(self: Scope) void {
            const app = self.app_scope.app;
            self.endpoint.release();
            (z.AppCallbackScope{ .app = app }).end();
        }
    };
    fn release(self: *Endpoint) void {
        std.debug.assert(self.pins != 0);
        self.pins -= 1;
        if (self.pins != 0 or self.phase != .closing) return;
        self.phase = .closed;
        self.busy = true;
        const handle = self.native_owner;
        self.native_owner = null;
        const allocator = self.allocator;
        const closed = self.on_closed;
        self.on_closed = null;
        // The native ingress is already sealed, and no callback pin remains.
        // Clear the owning credential before native or caller final cleanup.
        std.crypto.secureZero(u8, &self.security.bearer);
        if (available) if (handle) |value| {
            native.zhr_close(value);
            native.zhr_owner_release(value);
        };
        allocator.destroy(self);
        if (closed) |callback| callback.notify(callback.context);
    }
    fn stop(context: *anyopaque) !void {
        const self: *Endpoint = @ptrCast(@alignCast(context));
        const scope = self.beginTeardown();
        defer scope.end();
        self.stop_token = null;
        if (self.phase == .open) self.phase = .stopped;
        if (available) native.zhr_seal(self.native_owner.?);
    }
    fn parsed(input: *const native.Request, headers: *[policy.header_capacity]http.Header) policy.Request {
        for (0..input.header_count) |i| headers[i] = .{ .name = input.headers.?[i].name.bytes(), .value = input.headers.?[i].value.bytes() };
        return .{ .version = if (input.flags & 1 != 0) .http_1_1 else .other, .local = .{ .ip = input.local_ip, .port = input.local_port }, .peer = input.peer_ip, .scheme = input.scheme.bytes(), .host = input.host.bytes(), .port = input.port, .has_userinfo = input.flags & 2 != 0, .has_fragment = input.flags & 4 != 0, .path = input.path.bytes(), .query = if (input.flags & 8 != 0) input.query.bytes() else null, .headers = headers[0..input.header_count], .method = input.method.bytes() };
    }
    fn filter(context: *anyopaque, input: *const native.Request) callconv(.c) c_int {
        const self: *Endpoint = @ptrCast(@alignCast(context));
        self.checkIngress() catch return 0;
        var headers: [policy.header_capacity]http.Header = undefined;
        _ = self.security.validate(parsed(input, &headers)) catch return 0;
        return 1;
    }
    fn offer(context: *anyopaque, input: *const native.Request, borrow: *anyopaque) callconv(.c) void {
        const self: *Endpoint = @ptrCast(@alignCast(context));
        const scope = self.beginBusiness() orelse return;
        defer scope.end();
        self.checkIngress() catch return;
        var headers: [policy.header_capacity]http.Header = undefined;
        const request = parsed(input, &headers);
        const method = self.security.validate(request) catch return;
        self.handler.call(self.handler.context, self, .{ .method = method, .path = request.path, .query = request.query, .headers = request.headers }, .{ .endpoint = self, .native_borrow = borrow });
    }
};

/// Capture the bounded descriptors before any native/foreign call, including
/// Ticket owner lookup. Only immutable byte storage remains borrowed; replacing
/// caller Header descriptors during allocator reentry cannot change this copy.
const BorrowedCapture = struct {
    response: http.Response,
    headers: [16]http.Header,
    fn init(self: *BorrowedCapture, response: http.Response) !void {
        if (response.headers.len > self.headers.len) return error.TooManyResponseHeaders;
        @memcpy(self.headers[0..response.headers.len], response.headers);
        self.response = response;
        self.response.headers = self.headers[0..response.headers.len];
    }
};

test "borrowed response captures descriptors without consuming any response byte" {
    var headers = [_]http.Header{.{ .name = "X-original", .value = "stable" }};
    const original: http.Response = .{ .mime = "text/plain", .bytes = "borrowed", .headers = &headers };
    var captured: BorrowedCapture = undefined;
    try captured.init(original);
    headers[0] = .{ .name = "X-replaced", .value = "changed" };
    try std.testing.expectEqualStrings("X-original", captured.response.headers[0].name);
    try std.testing.expectEqualStrings("stable", captured.response.headers[0].value);
    try std.testing.expect(captured.response.bytes.ptr == original.bytes.ptr);
    const excessive = @as([17]http.Header, @splat(.{ .name = "X", .value = "x" }));
    try std.testing.expectError(error.TooManyResponseHeaders, captured.init(.{ .headers = &excessive }));
}
