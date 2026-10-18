const std = @import("std");
const z = @import("ziggurat");
const resources = @import("ziggurat_https_resources");
const Watchdog = @import("watchdog.zig").Watchdog;
const helper_faults = if (@hasDecl(@import("root"), "file_response_faults")) @import("root").file_response_faults else false;

const Mode = enum { memory, head, missing_bearer, wrong_origin, wrong_host, body, deferred, callback_close, final_free_close, final_free_quit, worker_cancel, stop_post_closed, file, file_head, file_stop, post_full, owner_free_close, encoded_prefix, encoded_slash, dot_route, long_uri, encoded_dot, query_opaque, budget_retain, borrowed, borrowed_head, borrowed_budget, range_default, range_valid, range_head, range_duplicate, range_if_duplicate, range_invalid, range_missing_bearer, range_wrong_origin, range_callback_close, prepared_file, prepared_head, prepared_reject, prepared_cancel, prepared_post_closed, prepared_post_full, prepared_oom_http, prepared_oom_file };

fn rangeMode(mode: Mode) bool {
    return switch (mode) {
        .range_default, .range_valid, .range_head, .range_duplicate, .range_if_duplicate, .range_invalid, .range_missing_bearer, .range_wrong_origin, .range_callback_close => true,
        else => false,
    };
}
fn preparedMode(mode: Mode) bool {
    return switch (mode) {
        .prepared_file, .prepared_head, .prepared_reject, .prepared_cancel, .prepared_post_closed, .prepared_post_full, .prepared_oom_http, .prepared_oom_file => true,
        else => false,
    };
}
const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    host: *anyopaque,
    mode: Mode,
    endpoint: ?*resources.Endpoint = null,
    window: z.Window,
    thread: ?std.Thread = null,
    ticket: ?resources.Endpoint.Ticket = null,
    failure: ?anyerror = null,
    worker_failure: std.atomic.Value(u16) = .init(0),
    worker_post_closed: std.atomic.Value(bool) = .init(false),
    closed: bool = false,
    requests: usize = 0,
    deliveries: usize = 0,
    accepted_cancelled: bool = false,
    owned: ?resources.http.OwnedResponse = null,
    free_closed: bool = false,
    source: ?resources.files.PreparedSource = null,
    gate: std.Thread.Semaphore = .{},
    stop_node: z.StopParticipant = undefined,
    pump_cancelled: std.atomic.Value(bool) = .init(false),
    full_posts: usize = 0,
    full_calls: usize = 0,
    full_retained: bool = false,
    file_request: ?resources.FileRequest = null,
    prepared_response: ?resources.PreparedFileResponse = null,
    prepared_retained: bool = false,
    prepared_failures: usize = 0,

    fn fail(self: *State, failure: anyerror) void {
        self.failure = self.failure orelse failure;
        self.app.quit();
    }
    fn request(context: *anyopaque, endpoint: *resources.Endpoint, req: resources.Endpoint.Request, offer: resources.Endpoint.Offer) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.requests += 1;
        if (!std.mem.eql(u8, req.path, "/private/body")) return self.fail(error.WrongRoute);
        if (preparedMode(self.mode)) {
            self.file_request = resources.FileRequest.capture(req.method, req.headers, .{ .etag = "\"fixture-v1\"" }) catch |failure| return self.fail(failure);
            self.ticket = offer.deferRequest() catch |failure| return self.fail(failure);
            self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |failure| return self.fail(failure);
            if (self.mode == .prepared_post_closed) self.app.quit();
            return;
        }
        if (rangeMode(self.mode)) self.checkRangeHeaders(req.headers) catch |failure| return self.fail(failure);
        switch (self.mode) {
            .range_valid, .range_head => {
                // Admission alone must leave the application's complete 200
                // representation intact; the host has not selected a window.
                var receipt = offer.respondBorrowed(.{ .bytes = "0123456789abcdefghijklmnopqrstuvwxyz" }) catch |failure| return self.fail(failure);
                defer receipt.deinit();
                self.checkRangeHeaders(req.headers) catch |failure| return self.fail(failure);
            },
            .range_callback_close => {
                const result = endpoint.close() catch |failure| return self.fail(failure);
                if (result != .deferred or self.closed) return self.fail(error.CloseWasNotPinned);
                // The SDK message and descriptor table remain borrowed through
                // this callback, even after synchronous logical owner close.
                self.checkRangeHeaders(req.headers) catch |failure| return self.fail(failure);
            },
            .borrowed, .borrowed_head => {
                var headers = [_]resources.http.Header{.{ .name = "X-Borrowed", .value = "independently copied" }};
                const response: resources.http.Response = .{ .mime = "text/plain", .bytes = "b" ** (16 * 1024), .headers = &headers };
                var receipt = offer.respondBorrowed(response) catch |failure| return self.fail(failure);
                defer receipt.deinit();
                headers[0] = .{ .name = "X-Replaced", .value = "caller can release descriptors after return" };
                if (response.bytes.len != 16 * 1024 or response.bytes[0] != 'b') return self.fail(error.BorrowedResponseConsumed);
                const stats = endpoint.stats() catch |failure| return self.fail(failure);
                if (stats.borrowed_input_bytes != 0 or stats.peak_reserved_bytes > 65536 or stats.peak_reserved_bytes < response.bytes.len) return self.fail(error.BorrowedBudgetNotAccounted);
                if (self.mode == .borrowed_head and stats.requested_bytes >= 8192) return self.fail(error.HeadCopiedRepresentation);
            },
            .borrowed_budget => {
                self.ticket = offer.deferRequest() catch |failure| return self.fail(failure);
                const response: resources.http.Response = .{ .bytes = "b" ** (24 * 1024) };
                const rejected = self.ticket.?.respondBorrowed(response);
                if (rejected) |receipt_value| {
                    var receipt = receipt_value;
                    receipt.deinit();
                    return self.fail(error.BorrowedCandidateExceededBudget);
                } else |failure| if (failure != error.CapacityExceeded) return self.fail(failure);
                const stats = endpoint.stats() catch |failure| return self.fail(failure);
                if (self.ticket.?.native_ticket == null or response.bytes.len != 24 * 1024 or stats.borrowed_input_bytes != 0 or stats.physical_pending != 1 or stats.peak_reserved_bytes > 65536) return self.fail(error.RejectedBorrowedConsumedTicket);
                var receipt = self.ticket.?.respondBorrowed(.{ .bytes = "small borrowed retry" }) catch |failure| return self.fail(failure);
                defer receipt.deinit();
                if (self.ticket.?.native_ticket != null) return self.fail(error.AcceptedBorrowedKeptTicket);
            },
            .budget_retain => {
                self.owned = resources.http.OwnedResponse.init(self.allocator, .{ .bytes = "b" ** (24 * 1024) }, 32 * 1024) catch |failure| return self.fail(failure);
                _ = offer.respondOwned(&self.owned.?) catch |failure| {
                    if (failure != error.CapacityExceeded) return self.fail(failure);
                    if (self.owned.?.storage == null) return self.fail(error.RejectedBudgetConsumedOwned);
                    const stats = endpoint.stats() catch |err| return self.fail(err);
                    if (stats.borrowed_input_bytes != 0 or stats.physical_pending != 0 or stats.peak_reserved_bytes > 65536) return self.fail(error.CandidateBudgetLeaked);
                    self.owned.?.deinit();
                    self.owned = resources.http.OwnedResponse.init(self.allocator, .{ .bytes = "small retry" }, 100) catch |err| return self.fail(err);
                    var receipt = offer.respondOwned(&self.owned.?) catch |err| return self.fail(err);
                    defer receipt.deinit();
                    return;
                };
                self.fail(error.CandidateExceededBudget);
            },
            .post_full => {
                self.ticket = offer.deferRequest() catch |failure| return self.fail(failure);
                self.owned = resources.http.OwnedResponse.init(self.allocator, .{ .bytes = "retained after Full" }, 100) catch |failure| return self.fail(failure);
                while (self.full_posts < 1024) {
                    self.app.post(.{ .context = self, .call = countPost }) catch |failure| {
                        if (failure != error.Full) self.fail(failure);
                        break;
                    };
                    self.full_posts += 1;
                }
                self.app.post(.{ .context = self, .call = deliver }) catch |failure| {
                    if (failure != error.Full) self.fail(failure);
                    self.full_retained = self.ticket.?.native_ticket != null and self.owned.?.storage != null;
                    self.ticket.?.deinit();
                    self.ticket = null;
                    self.owned.?.deinit();
                    // The deliberately full mailbox cannot also be used as an
                    // assumed-success completion channel. Explicit host shutdown
                    // drains every accepted counter task before Endpoint Stop.
                    self.app.quit();
                    return;
                };
                self.fail(error.FullPostUnexpectedlyAccepted);
            },
            .deferred, .worker_cancel, .stop_post_closed, .file, .file_head, .file_stop => {
                self.ticket = offer.deferRequest() catch |failure| return self.fail(failure);
                if (self.mode == .stop_post_closed) self.app.quit();
                self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |failure| return self.fail(failure);
            },
            .callback_close, .owner_free_close => {
                const result = endpoint.close() catch |failure| return self.fail(failure);
                if (result != .deferred or self.closed) self.fail(error.CloseWasNotPinned);
            },
            .head => {
                var receipt = offer.respondHead(.{ .length = 16 * 1024 * 1024 }) catch |failure| return self.fail(failure);
                defer receipt.deinit();
                if (receipt.state != .accepted) self.fail(error.HeadCancelled);
            },
            .memory, .final_free_close, .final_free_quit, .query_opaque, .encoded_prefix => {
                if (self.mode == .query_opaque and (req.query == null or !std.mem.eql(u8, req.query.?, "q=%2F"))) return self.fail(error.QueryWasDecoded);
                const allocator = if (self.mode == .final_free_close or self.mode == .final_free_quit) self.freeAllocator() else self.allocator;
                self.owned = resources.http.OwnedResponse.init(allocator, .{ .mime = "text/plain", .bytes = "HTTPS resource" }, 100) catch |failure| return self.fail(failure);
                var receipt = offer.respondOwned(&self.owned.?) catch |failure| return self.fail(failure);
                defer receipt.deinit();
                if (self.owned.?.storage != null) self.fail(error.OwnedNotMoved);
                self.accepted_cancelled = receipt.state == .accepted_cancelled;
                if ((self.mode == .final_free_close or self.mode == .final_free_quit) and (!self.accepted_cancelled or !self.free_closed or self.closed)) self.fail(error.FinalFreePublication);
            },
            else => self.fail(error.UnauthorizedOffer),
        }
    }
    fn checkRangeHeaders(self: *State, headers: []const resources.http.Header) !void {
        var ranges: usize = 0;
        var conditions: usize = 0;
        var credentials: usize = 0;
        for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Range")) {
                try std.testing.expectEqualStrings(if (self.mode == .range_head) "malformed" else "bytes=2-5", header.value);
                ranges += 1;
            } else if (std.ascii.eqlIgnoreCase(header.name, "If-Range")) {
                try std.testing.expectEqualStrings("\"fixture-v1\"", header.value);
                conditions += 1;
            } else if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) credentials += 1;
        }
        try std.testing.expectEqual(@as(usize, if (self.mode == .range_head) 2 else 1), ranges);
        try std.testing.expectEqual(@as(usize, 1), conditions);
        try std.testing.expectEqual(@as(usize, 1), credentials);
    }
    fn worker(self: *State) void {
        if (preparedMode(self.mode)) {
            self.preparedWorker() catch |failure| {
                self.worker_failure.store(@intFromError(failure), .release);
                self.app.post(.{ .context = self, .call = finish }) catch {};
            };
            return;
        }
        if (self.mode == .file or self.mode == .file_head or self.mode == .file_stop) {
            self.fileWorker() catch |failure| {
                self.worker_failure.store(@intFromError(failure), .release);
                self.app.post(.{ .context = self, .call = finish }) catch {};
            };
            return;
        }
        if (self.mode == .worker_cancel) {
            self.ticket.?.deinit();
            self.ticket = null;
            return;
        }
        self.app.post(.{ .context = self, .call = deliver }) catch |failure| {
            self.ticket.?.deinit();
            self.ticket = null;
            if (failure == error.Closed and self.mode == .stop_post_closed) self.worker_post_closed.store(true, .release) else self.worker_failure.store(@intFromError(failure), .release);
        };
    }
    fn countPost(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.full_calls += 1;
        if (self.mode == .prepared_post_full and self.full_retained and self.full_calls == self.full_posts) self.commitPrepared();
    }
    fn preparedWorker(self: *State) !void {
        const descriptor = zhr_test_host_file();
        if (descriptor < 0) return error.HostFileFailed;
        const file: std.fs.File = .{ .handle = descriptor };
        defer file.close();
        const reads = zwk_file_pread_count();
        const prepared = try resources.PreparedFileResponse.prepare(self.app.owner, file, 1024 * 1024, self.file_request.?);
        var pump = prepared.pump;
        defer if (pump) |*value| value.deinit();
        self.prepared_response = prepared.response;
        if (self.mode == .prepared_post_closed) self.gate.wait();
        self.app.post(.{ .context = self, .call = deliverPrepared }) catch |failure| {
            const retained = self.prepared_response.?.ready and self.prepared_response.?.source != null and self.ticket.?.native_ticket != null;
            self.prepared_response.?.deinit();
            self.ticket.?.deinit();
            if (failure == error.Closed and self.mode == .prepared_post_closed and retained) {
                self.worker_post_closed.store(true, .release);
                return;
            }
            return failure;
        };
        if (self.mode == .prepared_cancel or self.mode == .prepared_reject) self.gate.wait();
        if (pump) |*value| value.pump() catch |failure| {
            if (failure == error.Cancelled and (self.mode == .prepared_cancel or self.mode == .prepared_reject)) {
                self.pump_cancelled.store(true, .release);
                return;
            }
            return failure;
        };
        if (self.mode == .prepared_cancel or self.mode == .prepared_reject) return error.PumpWasNotCancelled;
        if (self.mode == .prepared_head and zwk_file_pread_count() != reads) return error.HeadCopiedRepresentation;
    }
    fn deliverPrepared(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (self.mode == .prepared_post_full) {
            while (self.full_posts < 1024) {
                self.app.post(.{ .context = self, .call = countPost }) catch |failure| {
                    if (failure != error.Full) return self.fail(failure);
                    break;
                };
                self.full_posts += 1;
            }
            self.app.post(.{ .context = self, .call = commitPreparedPost }) catch |failure| {
                if (failure != error.Full) return self.fail(failure);
                self.full_retained = self.prepared_response.?.ready and self.prepared_response.?.source != null and self.ticket.?.native_ticket != null;
                if (!self.full_retained) self.fail(error.FullConsumedPreparedResponse);
                return;
            };
            return self.fail(error.FullPostUnexpectedlyAccepted);
        }
        self.commitPrepared();
    }
    fn commitPreparedPost(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.commitPrepared();
    }
    fn commitPrepared(self: *State) void {
        self.deliveries += 1;
        if (self.mode == .prepared_reject) {
            const result = self.ticket.?.respondPreparedFile(&self.prepared_response.?, .{});
            if (result) |value| {
                var receipt = value;
                receipt.deinit();
                return self.fail(error.PreparedExceededFileLimit);
            } else |failure| if (failure != error.ResourceTooLarge) return self.fail(failure);
            self.prepared_retained = self.prepared_response.?.ready and self.prepared_response.?.source != null and self.ticket.?.native_ticket != null;
            if (!self.prepared_retained) return self.fail(error.RejectedPreparedWasConsumed);
            self.prepared_response.?.deinit();
            var receipt = self.ticket.?.respondBorrowed(.{ .bytes = "fallback after rejected prepared response" }) catch |failure| return self.fail(failure);
            defer receipt.deinit();
            self.gate.post();
            return;
        }
        var receipt = self.preparedReceipt() catch |failure| {
            self.prepared_response.?.deinit();
            self.gate.post();
            return self.fail(failure);
        };
        defer receipt.deinit();
        if (self.prepared_response.?.ready or self.prepared_response.?.source != null or self.ticket.?.native_ticket != null or receipt.control == null) return self.fail(error.PreparedNotConsumed);
        const repeated = self.ticket.?.respondPreparedFile(&self.prepared_response.?, .{});
        if (repeated) |value| {
            var extra = value;
            extra.deinit();
            return self.fail(error.PreparedAcceptedTwice);
        } else |failure| if (failure != error.ResponseMoved) return self.fail(failure);
        if (self.mode == .prepared_cancel) {
            receipt.control.?.cancel();
            if (resources.files.counts().physical == 0) return self.fail(error.CancelPrematurelyReleasedFile);
            self.gate.post();
            self.app.quit();
        }
    }
    fn preparedReceipt(self: *State) !resources.Receipt {
        if (comptime helper_faults) {
            if (self.mode == .prepared_oom_http or self.mode == .prepared_oom_file) {
                const source = self.prepared_response.?.source.?.native;
                const ticket = self.ticket.?.native_ticket;
                const baseline = try self.endpoint.?.stats();
                for (0..32) |index| {
                    zhr_test_allocation_limit(if (self.mode == .prepared_oom_http) @intCast(index) else -1);
                    zwk_file_test_allocation_limit(if (self.mode == .prepared_oom_file) @intCast(index) else -1);
                    const result = self.ticket.?.respondPreparedFile(&self.prepared_response.?, .{ .file_control = true });
                    zhr_test_allocation_limit(-1);
                    zwk_file_test_allocation_limit(-1);
                    if (result) |value| {
                        if (self.prepared_failures == 0) {
                            var extra = value;
                            extra.deinit();
                            return error.PreparedFaultNotExercised;
                        }
                        return value;
                    } else |failure| {
                        if (failure != error.OutOfMemory) return failure;
                        if (!self.prepared_response.?.ready or self.prepared_response.?.source.?.native != source or self.ticket.?.native_ticket != ticket) return error.PreparedOomConsumedInput;
                        const after = try self.endpoint.?.stats();
                        if (after.requested_bytes != baseline.requested_bytes or after.borrowed_input_bytes != 0 or after.physical_pending != 1 or resources.files.counts().candidates != 0) return error.PreparedOomLeakedCandidate;
                        self.prepared_failures += 1;
                    }
                }
                return error.PreparedFaultNeverSucceeded;
            }
        }
        return self.ticket.?.respondPreparedFile(&self.prepared_response.?, .{ .file_control = true });
    }
    fn fileWorker(self: *State) !void {
        const descriptor = zhr_test_host_file();
        if (descriptor < 0) return error.HostFileFailed;
        const file: std.fs.File = .{ .handle = descriptor };
        defer file.close();
        var prepared = try resources.files.PreparedSource.prepare(self.app.owner, file, 1024 * 1024);
        defer prepared.pump.deinit();
        self.source = prepared.source;
        self.app.post(.{ .context = self, .call = deliverFile }) catch |failure| {
            self.source.?.deinit();
            self.source = null;
            self.ticket.?.deinit();
            self.ticket = null;
            return failure;
        };
        if (self.mode == .file_head) {
            // HEAD needs no body pump. Wait for explicit owner acceptance (or
            // Stop), then return this worker's owning ref without reading.
            self.gate.wait();
            return;
        }
        if (self.mode == .file_stop) self.gate.wait();
        prepared.pump.pump() catch |failure| {
            if (failure == error.Cancelled and self.mode == .file_stop) {
                self.pump_cancelled.store(true, .release);
                return;
            }
            return failure;
        };
        if (self.mode == .file_stop) return error.PumpWasNotCancelled;
    }
    fn stopGate(context: *anyopaque) !void {
        const self: *State = @ptrCast(@alignCast(context));
        self.gate.post();
    }
    fn deliverFile(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.deliveries += 1;
        // Public length is not authority. Both deliberately incorrect hints
        // must leave the prepare-time native representation length unchanged.
        self.source.?.length = 7;
        var receipt = self.ticket.?.respondSource(.{ .length = 9 }, &self.source.?, .{ .file_control = true }) catch |failure| return self.fail(failure);
        defer receipt.deinit();
        if (self.source.?.native != null or self.ticket.?.native_ticket != null or receipt.control == null) self.fail(error.FileResponsibilityNotMoved);
        self.ticket = null;
        if (self.mode == .file_head) self.gate.post();
        if (self.mode == .file_stop) self.app.quit();
    }
    fn deliver(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.deliveries += 1;
        var owned = resources.http.OwnedResponse.init(self.allocator, .{ .bytes = "HTTPS deferred" }, 100) catch |failure| return self.fail(failure);
        defer owned.deinit();
        var receipt = self.ticket.?.respondOwned(&owned) catch |failure| return self.fail(failure);
        defer receipt.deinit();
        if (self.ticket.?.native_ticket != null or owned.storage != null) self.fail(error.DeferredNotMoved);
        self.ticket = null;
    }
    fn closedCallback(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.closed = true;
        self.endpoint = null;
    }
    fn clientDone(context: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(context.?));
        self.app.post(.{ .context = self, .call = finish }) catch |failure| {
            if (failure != error.Closed) self.worker_failure.store(@intFromError(failure), .release);
        };
    }
    fn finish(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.app.quit();
    }
    fn freeAllocator(self: *State) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn ownerAllocator(self: *State) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = ownerFree } };
    }
    fn ownerFree(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const endpoint: *resources.Endpoint = @ptrCast(@alignCast(bytes.ptr));
        if (!std.mem.allEqual(u8, &endpoint.security.bearer, 0)) self.fail(error.CredentialStillPresent);
        const result = endpoint.close() catch |failure| {
            self.fail(failure);
            self.allocator.rawFree(bytes, alignment, ra);
            return;
        };
        self.free_closed = result == .closed;
        self.allocator.rawFree(bytes, alignment, ra);
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *State = @ptrCast(@alignCast(ptr));
        return self.allocator.rawAlloc(length, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!self.free_closed) {
            self.free_closed = true;
            if (self.owned.?.storage != null) self.fail(error.FinalFreeStillOwned);
            if (self.mode == .final_free_quit) self.app.quit() else if (self.endpoint) |endpoint| {
                const result = endpoint.close() catch |failure| {
                    self.fail(failure);
                    self.allocator.rawFree(bytes, alignment, ra);
                    return;
                };
                if (result != .deferred) self.fail(error.FinalFreeCloseNotDeferred);
            }
        }
        self.allocator.rawFree(bytes, alignment, ra);
    }
};

pub fn main() !void {
    if (!resources.available) return error.UnsupportedCapability;
    const allocator = std.heap.page_allocator;
    const environment = try std.process.getEnvVarOwned(allocator, "ZIGGURAT_HTTPS_TEST_ROOT");
    defer allocator.free(environment);
    const cert = try std.fs.path.joinZ(allocator, &.{ environment, "server-cert.pem" });
    defer allocator.free(cert);
    const key = try std.fs.path.joinZ(allocator, &.{ environment, "server-key.pem" });
    defer allocator.free(key);
    if (std.posix.getenv("ZIGGURAT_HTTPS_SITE_CONSTRUCTOR_ONLY") != null) {
        for ([_]usize{ 0, 1, 3 }) |at| {
            try siteTransportConstructor(allocator, cert, key, false, at);
            try siteTransportConstructor(allocator, cert, key, true, at);
        }
        try siteConstructorOom(allocator, cert, key);
        try endpointTransportConstructor(allocator, cert, key, false);
        try endpointTransportConstructor(allocator, cert, key, true);
        return;
    }
    if (comptime helper_faults) {
        try run(allocator, cert, key, .prepared_oom_http);
        try run(allocator, cert, key, .prepared_oom_file);
        return;
    }
    for (std.meta.tags(Mode)) |mode| {
        if (mode == .prepared_oom_http or mode == .prepared_oom_file) continue;
        try run(allocator, cert, key, mode);
    }
    try constructor(allocator, cert, key, false);
    try constructor(allocator, cert, key, true);
    try unsupportedServer(allocator, cert, key);
    try constructorOom(allocator, cert, key);
    try capturedRangeFlag(allocator, cert, key, false);
    try capturedRangeFlag(allocator, cert, key, true);
    for ([_]usize{ 0, 1, 3 }) |at| {
        try siteTransportConstructor(allocator, cert, key, false, at);
        try siteTransportConstructor(allocator, cert, key, true, at);
    }
    try siteConstructorOom(allocator, cert, key);
    try endpointTransportConstructor(allocator, cert, key, false);
    try endpointTransportConstructor(allocator, cert, key, true);
}

const SiteConstruction = struct {
    backing: std.mem.Allocator,
    app: *z.App,
    host: ?*anyopaque,
    watch: *anyopaque,
    destroyed_at_first_allocation: bool = false,
    stop: bool,
    at_allocation: usize,
    allocations: usize = 0,
    armed: bool = true,
    closed: bool = false,
    fn allocator(self: *SiteConstruction) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, count: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *SiteConstruction = @ptrCast(@alignCast(ptr));
        self.allocations += 1;
        if (self.armed and self.allocations == self.at_allocation) {
            self.closeTransport();
        }
        return self.backing.rawAlloc(count, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *SiteConstruction = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(bytes, alignment, ra);
    }
    fn onClosed(context: *anyopaque) void {
        const self: *SiteConstruction = @ptrCast(@alignCast(context));
        self.closed = true;
    }
    fn replaced(context: ?*anyopaque) callconv(.c) void {
        const self: *SiteConstruction = @ptrCast(@alignCast(context.?));
        self.closeTransport();
    }
    fn closeTransport(self: *SiteConstruction) void {
        self.armed = false;
        const host = self.host.?;
        self.host = null;
        zhr_test_host_close(host);
        self.destroyed_at_first_allocation = zhr_test_host_finalized(self.watch) != 0;
        std.debug.print("https transport revoke checkpoint={d} stop={} finalized={}\n", .{ self.at_allocation, self.stop, self.destroyed_at_first_allocation });
        if (self.stop) self.app.quit();
    }
};
fn siteTransportConstructor(allocator: std.mem.Allocator, cert: [:0]const u8, key: [:0]const u8, stop: bool, at_allocation: usize) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var port: c_uint = 0;
    const host = zhr_test_host_create(cert.ptr, key.ptr, &port) orelse return error.HostTlsUnavailable;
    const watch = zhr_test_host_watch(host) orelse return error.OutOfMemory;
    defer zhr_test_host_watch_close(watch);
    var probe: SiteConstruction = .{ .backing = allocator, .app = app, .host = host, .watch = watch, .stop = stop, .at_allocation = at_allocation };
    defer if (probe.host) |remaining| zhr_test_host_close(remaining);
    if (at_allocation == 0) zhr_test_host_replace(host, SiteConstruction.replaced, &probe);
    const result = resources.Site.create(probe.allocator(), app, @ptrCast(zhr_test_host_server(host)), .{
        .port = @intCast(port),
        .mount_prefix = "/private/",
        .bearer = @splat(1),
        .resources = &.{.{ .path = "/body", .bytes = "body" }},
        .on_closed = .{ .context = &probe, .notify = SiteConstruction.onClosed },
    });
    if (result) |site| {
        _ = try site.close();
        return error.UnexpectedSiteConstructionSuccess;
    } else |failure| {
        try std.testing.expectEqual(if (stop) error.Closed else error.InvalidEndpoint, failure);
    }
    try std.testing.expect(!probe.destroyed_at_first_allocation);
    try std.testing.expect(!probe.armed and !probe.closed and probe.host == null);
    app.quit();
    try app.finishShutdown();
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    try std.testing.expect(zhr_test_host_finalized(watch) != 0);
    std.debug.print("https_site construct transport-reentry allocation={d} stop={}: rejected/no-onclosed/weak-final/native0\n", .{ at_allocation, stop });
}
fn owningSiteConstructor(allocator: std.mem.Allocator, app: *z.App, server: *resources.NativeServer, port: u16, range_requests: bool) !void {
    const site = try resources.Site.create(allocator, app, server, .{ .port = port, .mount_prefix = "/private/", .bearer = @splat(1), .range_requests = range_requests, .resources = &.{.{ .path = "/body", .bytes = "body" }} });
    _ = try site.close();
}
fn siteConstructorOom(allocator: std.mem.Allocator, cert: [:0]const u8, key: [:0]const u8) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var port: c_uint = 0;
    const host = zhr_test_host_create(cert.ptr, key.ptr, &port) orelse return error.HostTlsUnavailable;
    defer zhr_test_host_close(host);
    inline for (.{ false, true }) |range_requests| try std.testing.checkAllAllocationFailures(allocator, owningSiteConstructor, .{ app, @as(*resources.NativeServer, @ptrCast(zhr_test_host_server(host))), @as(u16, @intCast(port)), range_requests });
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    const long_path = [_]u8{'/'} ++ [_]u8{'a'} ** (resources.policy.uri_capacity - 2);
    try std.testing.expectError(error.UriTooLong, resources.Site.create(allocator, app, @ptrCast(zhr_test_host_server(host)), .{ .port = @intCast(port), .bearer = @splat(1), .resources = &.{.{ .path = &long_path, .bytes = "" }} }));
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    std.debug.print("https_site constructor_oom: every caller allocation and complete URI preflight/native0\n", .{});
}
fn endpointTransportConstructor(allocator: std.mem.Allocator, cert: [:0]const u8, key: [:0]const u8, at_bind: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var port: c_uint = 0;
    const host = zhr_test_host_create(cert.ptr, key.ptr, &port) orelse return error.HostTlsUnavailable;
    const watch = zhr_test_host_watch(host) orelse return error.OutOfMemory;
    defer zhr_test_host_watch_close(watch);
    var probe: SiteConstruction = .{ .backing = allocator, .app = app, .host = host, .watch = watch, .stop = false, .at_allocation = if (at_bind) 0 else 1 };
    defer if (probe.host) |remaining| zhr_test_host_close(remaining);
    if (at_bind) zhr_test_host_replace(host, SiteConstruction.replaced, &probe);
    const result = resources.Endpoint.create(probe.allocator(), app, @ptrCast(zhr_test_host_server(host)), .{
        .port = @intCast(port),
        .mount_prefix = "/private/",
        .bearer = @splat(1),
        .context = &probe,
        .on_request = Construction.request,
        .on_closed = .{ .context = &probe, .notify = SiteConstruction.onClosed },
    });
    if (result) |endpoint| {
        _ = try endpoint.close();
        return error.UnexpectedEndpointConstructionSuccess;
    } else |failure| try std.testing.expectEqual(error.InvalidEndpoint, failure);
    try std.testing.expect(!probe.armed and !probe.closed and !probe.destroyed_at_first_allocation);
    app.quit();
    try app.finishShutdown();
    try std.testing.expect(zhr_test_host_finalized(watch) != 0);
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    std.debug.print("https_endpoint revoked transport {s}: rejected/weak-final/no-onclosed/native0\n", .{if (at_bind) "foreign-handler" else "allocator"});
}
fn run(allocator: std.mem.Allocator, cert: [:0]const u8, key: [:0]const u8, mode: Mode) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "HTTPS resource lifecycle", .width = 64, .height = 64 });
    var port: c_uint = 0;
    const host = zhr_test_host_create(cert.ptr, key.ptr, &port) orelse return error.HostTlsUnavailable;
    defer zhr_test_host_close(host);
    var state: State = .{ .allocator = allocator, .app = app, .host = host, .mode = mode, .window = window };
    state.stop_node = .{ .context = &state, .stop = State.stopGate };
    _ = try app.registerStop(&state.stop_node);
    state.endpoint = try resources.Endpoint.create(if (mode == .owner_free_close) state.ownerAllocator() else allocator, app, @ptrCast(zhr_test_host_server(host)), .{ .port = @intCast(port), .mount_prefix = "/private/", .bearer = @splat(0xa7), .range_requests = (rangeMode(mode) and mode != .range_default) or preparedMode(mode), .context = &state, .on_request = State.request, .on_closed = .{ .context = &state, .notify = State.closedCallback }, .limits = .{ .bytes = if (mode == .budget_retain or mode == .borrowed or mode == .borrowed_head or mode == .borrowed_budget) 65536 else 64 * 1024 * 1024, .max_file_bytes = if (mode == .prepared_reject) 2 else 256 * 1024 * 1024 } });
    var captured: resources.policy.Policy = undefined;
    try captured.captureInto(@intCast(port), "/private/", @splat(0xa7));
    var authorization: [resources.policy.bearer_header_length + 1]u8 = undefined;
    captured.authorization(authorization[0..resources.policy.bearer_header_length]);
    authorization[resources.policy.bearer_header_length] = 0;
    const native_mode: c_int = switch (mode) {
        .head, .file_head, .range_head, .prepared_head => 1,
        .missing_bearer, .range_missing_bearer => 2,
        .wrong_origin, .range_wrong_origin => 3,
        .wrong_host => 4,
        .body => 5,
        .encoded_prefix => 6,
        .encoded_slash => 7,
        .dot_route => 8,
        .long_uri => 9,
        .encoded_dot => 10,
        .query_opaque => 11,
        .borrowed => 12,
        .borrowed_head => 13,
        else => 0,
    };
    if (rangeMode(mode) or preparedMode(mode)) {
        const range: [:0]const u8 = if (mode == .range_head) "Range: malformed" else if (mode == .range_invalid) "Range: bytes=18446744073709551616-0,bad" else "Range: bytes=2-5";
        if (zhr_test_host_ranges(host, range.ptr, if (mode == .range_duplicate) "rAnGe: bytes=2-5" else if (mode == .range_head) "Range: malformed" else null, "If-Range: \"fixture-v1\"", if (mode == .range_if_duplicate) "iF-rAnGe: \"fixture-v1\"" else null) == 0) return error.ClientHeadersFailed;
    }
    if (zhr_test_host_start(host, @ptrCast(&authorization), native_mode, State.clientDone, &state) == 0) return error.ClientWorkerFailed;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.thread) |thread| thread.join();
    state.thread = null;
    zhr_test_host_join(host);
    if (state.endpoint) |endpoint| _ = try endpoint.close();
    if (state.ticket) |*ticket| ticket.deinit();
    if (state.source) |*source| source.deinit();
    if (state.prepared_response) |*response| response.deinit();
    try std.testing.expect(zhr_test_host_drain() != 0);
    try std.testing.expect(!watchdog.expired);
    if (state.failure) |failure| return failure;
    try std.testing.expectEqual(@as(u16, 0), state.worker_failure.load(.acquire));
    try std.testing.expect(state.closed);
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    var result: c_int = 0;
    var status: c_long = 0;
    var received: usize = 0;
    var body: c_uint = 0;
    zhr_test_host_result(host, &result, &status, &received, &body);
    switch (mode) {
        .memory, .deferred, .head, .file, .file_head, .query_opaque, .encoded_prefix, .budget_retain, .borrowed, .borrowed_head, .borrowed_budget, .range_valid, .range_head => {
            try std.testing.expectEqual(@as(c_int, 0), result);
            try std.testing.expectEqual(@as(c_long, 200), status);
            try std.testing.expectEqual(@as(usize, 1), state.requests);
        },
        .missing_bearer, .wrong_origin, .wrong_host, .body, .range_default, .range_duplicate, .range_if_duplicate, .range_invalid, .range_missing_bearer, .range_wrong_origin => {
            try std.testing.expectEqual(@as(c_long, 403), status);
            try std.testing.expectEqual(@as(usize, 0), state.requests);
            try std.testing.expectEqual(@as(c_uint, 0), body);
        },
        .encoded_slash, .dot_route, .long_uri, .encoded_dot => {
            try std.testing.expect(status == 403 or status == 404);
            try std.testing.expectEqual(@as(usize, 0), state.requests);
            try std.testing.expectEqual(@as(c_uint, 0), body);
        },
        .final_free_close, .final_free_quit => try std.testing.expect(state.accepted_cancelled),
        .owner_free_close => try std.testing.expect(state.free_closed),
        .stop_post_closed => try std.testing.expect(state.worker_post_closed.load(.acquire)),
        .file_stop => try std.testing.expect(state.pump_cancelled.load(.acquire)),
        .prepared_file, .prepared_head, .prepared_post_full, .prepared_oom_http, .prepared_oom_file => {
            try std.testing.expectEqual(@as(c_int, 0), result);
            try std.testing.expectEqual(@as(c_long, if (mode == .prepared_head) 200 else 206), status);
            try std.testing.expectEqual(@as(usize, 1), state.requests);
            try std.testing.expectEqual(@as(usize, if (mode == .prepared_head) 0 else 4), received);
            try std.testing.expectEqual(@as(u64, if (mode == .prepared_head) 4096 * 80 else 4), zhr_test_host_length(host));
            if (mode == .prepared_post_full) try std.testing.expect(state.full_retained and state.full_posts == state.full_calls);
            if (mode == .prepared_oom_http or mode == .prepared_oom_file) {
                try std.testing.expect(state.prepared_failures != 0);
                std.debug.print("prepared OOM {s}: failures={d} same-response/same-ticket retry/native0\n", .{ @tagName(mode), state.prepared_failures });
            }
        },
        .prepared_reject => {
            try std.testing.expectEqual(@as(c_int, 0), result);
            try std.testing.expectEqual(@as(c_long, 200), status);
            try std.testing.expectEqual(@as(usize, "fallback after rejected prepared response".len), received);
            try std.testing.expect(state.prepared_retained and state.pump_cancelled.load(.acquire));
        },
        .prepared_cancel => try std.testing.expect(state.pump_cancelled.load(.acquire)),
        .prepared_post_closed => try std.testing.expect(state.worker_post_closed.load(.acquire)),
        .post_full => {
            try std.testing.expect(state.full_retained);
            try std.testing.expectEqual(state.full_posts, state.full_calls);
            try std.testing.expectEqual(@as(usize, 0), state.deliveries);
        },
        else => {},
    }
    if (mode == .deferred) try std.testing.expectEqual(@as(usize, 1), state.deliveries);
    if (mode == .file) try std.testing.expectEqual(@as(usize, 4096 * 80), received);
    if (mode == .borrowed or mode == .borrowed_head) {
        try std.testing.expect(zhr_test_host_borrowed_good(host) != 0);
        try std.testing.expectEqual(@as(u64, 16 * 1024), zhr_test_host_length(host));
        try std.testing.expectEqual(@as(usize, if (mode == .borrowed) 16 * 1024 else 0), received);
    }
    if (mode == .borrowed_budget) try std.testing.expectEqual(@as(usize, "small borrowed retry".len), received);
    if (mode == .file or mode == .file_head) try std.testing.expectEqual(@as(u64, 4096 * 80), zhr_test_host_length(host));
    if (mode == .head) try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), zhr_test_host_length(host));
    if (mode == .file_head) try std.testing.expectEqual(@as(usize, 0), received);
    if (mode == .range_valid or mode == .range_head) {
        try std.testing.expectEqual(@as(u64, 36), zhr_test_host_length(host));
        try std.testing.expectEqual(@as(usize, if (mode == .range_head) 0 else 36), received);
    }
    if (mode == .range_callback_close) try std.testing.expectEqual(@as(usize, 1), state.requests);
    try std.testing.expectEqualDeep(resources.files.Counts{}, resources.files.counts());
    std.debug.print("https_endpoint {s}: curl={d} status={d} bytes={d} offers={d} closed={} native0\n", .{ @tagName(mode), result, status, received, state.requests, state.closed });
}
extern fn zhr_test_host_create([*:0]const u8, [*:0]const u8, *c_uint) ?*anyopaque;
extern fn zhr_test_host_decoded([*:0]const u8, [*:0]const u8, *c_uint) ?*anyopaque;
extern fn zhr_test_host_server(*anyopaque) *anyopaque;
extern fn zhr_test_host_start(*anyopaque, [*:0]const u8, c_int, *const fn (?*anyopaque) callconv(.c) void, *anyopaque) c_int;
extern fn zhr_test_host_ranges(*anyopaque, [*:0]const u8, ?[*:0]const u8, [*:0]const u8, ?[*:0]const u8) c_int;
extern fn zhr_test_host_join(*anyopaque) void;
extern fn zhr_test_host_result(*anyopaque, *c_int, *c_long, *usize, *c_uint) void;
extern fn zhr_test_host_close(*anyopaque) void;
extern fn zhr_test_context_iteration() c_int;
extern fn zhr_test_host_drain() c_int;
extern fn zhr_test_host_watch(*anyopaque) ?*anyopaque;
extern fn zhr_test_host_finalized(*anyopaque) c_int;
extern fn zhr_test_host_watch_close(*anyopaque) void;
extern fn zhr_test_host_borrowed_good(*anyopaque) c_int;
extern fn zhr_test_host_file() c_int;
extern fn zhr_test_host_length(*anyopaque) u64;
extern fn zhr_test_host_replace(*anyopaque, *const fn (?*anyopaque) callconv(.c) void, *anyopaque) void;
extern fn zhr_check(*anyopaque) c_int;
extern fn zwk_file_pread_count() u64;
extern fn zhr_test_allocation_limit(c_int) void;
extern fn zwk_file_test_allocation_limit(c_int) void;

const Construction = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    at_bind: bool,
    freed: bool = false,
    native_withdrawn: bool = false,
    secret_cleared: bool = false,
    window_closed: bool = false,
    owner_closed: bool = false,
    fn allocatorValue(self: *Construction) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Construction = @ptrCast(@alignCast(ptr));
        if (!self.at_bind) self.app.quit();
        return self.allocator.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Construction = @ptrCast(@alignCast(ptr));
        const candidate: *resources.Endpoint = @ptrCast(@alignCast(bytes.ptr));
        self.secret_cleared = std.mem.allEqual(u8, &candidate.security.bearer, 0);
        // Keep the allocation valid, and diagnose a still-owning candidate
        // without following it into a second native/self destruction. Once
        // withdrawn, the real reentrant public close must be inert.
        if (candidate.native_owner == null) {
            const result = candidate.close() catch unreachable;
            self.native_withdrawn = result == .closed;
        }
        self.freed = true;
        self.allocator.rawFree(bytes, alignment, ra);
    }
    fn replaced(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Construction = @ptrCast(@alignCast(ptr.?));
        self.app.quit();
    }
    fn windowClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *Construction = @ptrCast(@alignCast(ptr));
        self.window_closed = true;
    }
    fn ownerClosed(ptr: *anyopaque) void {
        const self: *Construction = @ptrCast(@alignCast(ptr));
        self.owner_closed = true;
    }
    fn request(_: *anyopaque, _: *resources.Endpoint, _: resources.Endpoint.Request, _: resources.Endpoint.Offer) void {
        unreachable;
    }
};
fn constructor(allocator: std.mem.Allocator, cert: [:0]const u8, key: [:0]const u8, at_bind: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Construction = .{ .allocator = allocator, .app = app, .at_bind = at_bind };
    _ = try app.createWindow(.{ .on_closed = .{ .context = &state, .notify = Construction.windowClosed } });
    var port: c_uint = 0;
    const host = zhr_test_host_create(cert.ptr, key.ptr, &port) orelse return error.HostTlsUnavailable;
    defer zhr_test_host_close(host);
    if (at_bind) zhr_test_host_replace(host, Construction.replaced, &state);
    try std.testing.expectError(error.Closed, resources.Endpoint.create(state.allocatorValue(), app, @ptrCast(zhr_test_host_server(host)), .{ .port = @intCast(port), .mount_prefix = "/private/", .bearer = @splat(1), .context = &state, .on_request = Construction.request, .on_closed = .{ .context = &state, .notify = Construction.ownerClosed } }));
    try std.testing.expect(state.freed and state.native_withdrawn and state.secret_cleared and !state.window_closed and !state.owner_closed);
    try app.finishShutdown();
    try std.testing.expect(state.window_closed and !state.owner_closed);
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    std.debug.print("https_endpoint construct_{s}: Closed/free-withdrawn/no-onclosed/native0\n", .{if (at_bind) "handler_reentry" else "allocator_reentry"});
}
fn unsupportedServer(allocator: std.mem.Allocator, cert: [:0]const u8, key: [:0]const u8) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var port: c_uint = 0;
    const host = zhr_test_host_decoded(cert.ptr, key.ptr, &port) orelse return error.HostTlsUnavailable;
    defer zhr_test_host_close(host);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.InvalidEndpoint, resources.Endpoint.create(failing.allocator(), app, @ptrCast(zhr_test_host_server(host)), .{ .port = @intCast(port), .mount_prefix = "/private/", .bearer = @splat(1), .context = host, .on_request = Construction.request }));
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    std.debug.print("https_endpoint decoded_server: rejected-before-caller-allocation/native0\n", .{});
}
fn owningConstructor(allocator: std.mem.Allocator, app: *z.App, server: *resources.NativeServer, port: u16, range_requests: bool) !void {
    const endpoint = try resources.Endpoint.create(allocator, app, server, .{ .port = port, .mount_prefix = "/private/", .bearer = @splat(1), .range_requests = range_requests, .context = server, .on_request = Construction.request });
    _ = try endpoint.close();
}
fn constructorOom(allocator: std.mem.Allocator, cert: [:0]const u8, key: [:0]const u8) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var port: c_uint = 0;
    const host = zhr_test_host_create(cert.ptr, key.ptr, &port) orelse return error.HostTlsUnavailable;
    defer zhr_test_host_close(host);
    inline for (.{ false, true }) |range_requests| try std.testing.checkAllAllocationFailures(allocator, owningConstructor, .{ app, @as(*resources.NativeServer, @ptrCast(zhr_test_host_server(host))), @as(u16, @intCast(port)), range_requests });
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    std.debug.print("https_endpoint constructor_oom: all-caller-allocations/native0\n", .{});
}

const RangeCapture = struct {
    backing: std.mem.Allocator,
    endpoint_options: ?*resources.Endpoint.Options = null,
    site_options: ?*resources.Site.Options = null,
    allocations: usize = 0,
    fn allocator(self: *RangeCapture) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RangeCapture = @ptrCast(@alignCast(ptr));
        self.allocations += 1;
        if (self.endpoint_options) |options| options.range_requests = false;
        if (self.site_options) |options| options.range_requests = false;
        return self.backing.rawAlloc(length, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *RangeCapture = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(bytes, alignment, ra);
    }
};
fn capturedRangeFlag(allocator: std.mem.Allocator, cert: [:0]const u8, key: [:0]const u8, site_mode: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var port: c_uint = 0;
    const host = zhr_test_host_create(cert.ptr, key.ptr, &port) orelse return error.HostTlsUnavailable;
    defer zhr_test_host_close(host);
    var probe: RangeCapture = .{ .backing = allocator };
    if (site_mode) {
        var options: resources.Site.Options = .{ .port = @intCast(port), .mount_prefix = "/private/", .bearer = @splat(1), .range_requests = true, .resources = &.{.{ .path = "/body", .bytes = "body" }} };
        probe.site_options = &options;
        const site = try resources.Site.create(probe.allocator(), app, @ptrCast(zhr_test_host_server(host)), options);
        try std.testing.expect(!options.range_requests and site.endpoint.?.security.range_requests);
        _ = try site.close();
    } else {
        var options: resources.Endpoint.Options = .{ .port = @intCast(port), .mount_prefix = "/private/", .bearer = @splat(1), .range_requests = true, .context = host, .on_request = Construction.request };
        probe.endpoint_options = &options;
        const endpoint = try resources.Endpoint.create(probe.allocator(), app, @ptrCast(zhr_test_host_server(host)), options);
        try std.testing.expect(!options.range_requests and endpoint.security.range_requests);
        _ = try endpoint.close();
    }
    try std.testing.expect(probe.allocations != 0);
    try std.testing.expectEqualDeep(resources.NativeCounts{}, resources.nativeCounts());
    std.debug.print("https_{s} range_capture: allocator-mutated-option/frozen/native0\n", .{if (site_mode) "site" else "endpoint"});
}
