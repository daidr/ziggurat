const std = @import("std");
const schema = @import("schema.zig");
const protocol = @import("protocol.zig");

/// Single-owner protocol state; the caller executes work and sends owned packets.
/// No transport callbacks, threads or allocation occur in the pending table.
/// After an outbound transport failure, close/reset the session or retry the same
/// owned packet before sending more messages; do not silently discard packets.
pub fn Router(comptime Service: type, comptime limits: protocol.Limits) type {
    if (limits.max_pending == 0 or limits.max_in_flight == 0 or limits.max_message_bytes == 0) @compileError("IPC limits must be positive");
    const Tag = schema.MethodTag(Service);
    const Params = schema.ParamsUnion(Service);
    return struct {
        const Self = @This();
        const Pending = struct { id: u32, method: Tag, sent: u32 = 0, acknowledged: u32 = 0 };
        pub const Call = struct { token: protocol.Token, params: Params };
        pub const Action = union(enum) { call: Call, cancel: protocol.Token, ack: protocol.Token };
        pub const Received = struct {
            parsed: std.json.Parsed(std.json.Value),
            action: Action,
            /// Params and strings are borrowed from this value until deinit.
            pub fn deinit(self: Received) void {
                self.parsed.deinit();
            }
        };
        session: protocol.Session,
        slots: [limits.max_pending]?Pending = @splat(null),
        active: usize = 0,
        last_id: u32 = 0,
        closed: bool = false,

        pub fn init(session: protocol.Session) Self {
            return .{ .session = session };
        }

        /// Owner-thread, allocation-free membership check after a foreign call.
        /// This is a current token check; it does not retain request storage.
        pub fn contains(self: *const Self, token: protocol.Token) bool {
            if (self.closed or !self.session.eql(token.session) or token.slot >= limits.max_pending) return false;
            const entry = self.slots[token.slot] orelse return false;
            return entry.id == token.id;
        }

        /// Rejects malformed/duplicate/foreign calls before taking pending state.
        /// A successful call owns a slot until complete/fail/cancel/reset/close.
        pub fn receive(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !Received {
            return self.receiveImpl(allocator, bytes, null);
        }

        /// Valid addressed calls that fail validation/backpressure expose a
        /// terminal rejection for the caller to send, so page promises can end.
        /// Malformed/foreign envelopes and allocation failure have no reply.
        pub fn receiveWithRejection(self: *Self, allocator: std.mem.Allocator, bytes: []const u8, rejected: *?protocol.Rejected) !Received {
            return self.receiveImpl(allocator, bytes, rejected);
        }

        fn receiveImpl(self: *Self, allocator: std.mem.Allocator, bytes: []const u8, rejected: ?*?protocol.Rejected) !Received {
            if (rejected) |out| out.* = null;
            if (self.closed) return error.Closed;
            if (bytes.len > limits.max_message_bytes) return error.MessageTooLarge;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return error.InvalidRequest;
            };
            errdefer parsed.deinit();
            if (self.closed) return error.Closed;
            try protocol.validateEnvelope(parsed.value);
            const envelope = std.json.parseFromValueLeaky(protocol.Envelope, parsed.arena.allocator(), parsed.value, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return error.InvalidRequest;
            };
            if (envelope.v != protocol.version) return error.UnsupportedVersion;
            if (!std.mem.eql(u8, envelope.session, &self.session.bytes)) return error.StaleSession;
            if (envelope.slot >= limits.max_pending or envelope.id == 0) return error.InvalidRequest;
            const token: protocol.Token = .{ .session = self.session, .slot = envelope.slot, .id = envelope.id };
            errdefer |err| if (rejected) |out| {
                // Replying to a replay of an active ID would reject the original
                // page promise while its original work is still running.
                if (envelope.kind == .call and err != error.OutOfMemory and err != error.DuplicateRequest) out.* = .{ .token = token, .code = switch (@as(anyerror, err)) {
                    error.Full => .full,
                    error.UnknownMethod => .unknown_method,
                    error.InvalidParams => .invalid_params,
                    else => .invalid_request,
                } };
            };
            switch (envelope.kind) {
                .call => {
                    if (envelope.sequence != null or envelope.method == null) return error.InvalidRequest;
                    if (envelope.id <= self.last_id) return error.DuplicateRequest;
                    if (self.slots[envelope.slot] != null) return error.Full;
                    const method = std.meta.stringToEnum(Tag, envelope.method.?) orelse return error.UnknownMethod;
                    var params: Params = undefined;
                    inline for (schema.methods(Service)) |field| {
                        if (method == @field(Tag, field.name)) {
                            const M = @field(Service.methods, field.name);
                            const source: std.json.Value = envelope.params orelse .null;
                            try schema.validateJson(M.Params, source);
                            const typed = if (M.Params == void) {} else std.json.parseFromValueLeaky(M.Params, parsed.arena.allocator(), source, .{}) catch |err| {
                                if (err == error.OutOfMemory) return error.OutOfMemory;
                                return error.InvalidParams;
                            };
                            schema.validateValue(typed) catch return error.InvalidParams;
                            params = @unionInit(Params, field.name, typed);
                        }
                    }
                    // Parsing typed params can call the caller's allocator.
                    // A callback may cancel, close, reset, or install a newer
                    // request; no earlier pending-table observation is a lease.
                    if (self.closed) return error.Closed;
                    if (!self.session.eql(token.session)) return error.StaleSession;
                    if (envelope.id <= self.last_id) return error.DuplicateRequest;
                    if (self.slots[envelope.slot] != null) return error.Full;
                    self.slots[envelope.slot] = .{ .id = envelope.id, .method = method };
                    self.active += 1;
                    self.last_id = envelope.id;
                    return .{ .parsed = parsed, .action = .{ .call = .{ .token = token, .params = params } } };
                },
                .cancel => {
                    if (envelope.method != null or envelope.params != null or envelope.sequence != null) return error.InvalidRequest;
                    _ = try self.pending(token);
                    self.release(token.slot);
                    return .{ .parsed = parsed, .action = .{ .cancel = token } };
                },
                .ack => {
                    if (envelope.method != null or envelope.params != null or envelope.sequence == null) return error.InvalidRequest;
                    const entry = try self.pending(token);
                    var streaming = false;
                    inline for (schema.methods(Service)) |field| {
                        if (entry.method == @field(Tag, field.name)) streaming = @field(Service.methods, field.name).Item != void;
                    }
                    if (!streaming) return error.NotStreaming;
                    const sequence = envelope.sequence.?;
                    if (sequence < entry.acknowledged or sequence > entry.sent) return error.InvalidAck;
                    entry.acknowledged = sequence;
                    return .{ .parsed = parsed, .action = .{ .ack = token } };
                },
            }
        }

        fn pending(self: *Self, token: protocol.Token) !*Pending {
            if (!self.session.eql(token.session)) return error.StaleSession;
            if (self.closed) return error.Closed;
            if (token.slot >= limits.max_pending) return error.StaleRequest;
            if (self.slots[token.slot]) |*entry| {
                if (entry.id == token.id) return entry;
            }
            return error.StaleRequest;
        }

        fn methodPending(self: *Self, comptime method: []const u8, token: protocol.Token) !*Pending {
            const entry = try self.pending(token);
            if (entry.method != @field(Tag, method)) return error.WrongMethod;
            return entry;
        }

        fn release(self: *Self, slot: u16) void {
            self.slots[slot] = null;
            self.active -= 1;
        }

        pub fn complete(self: *Self, comptime method: []const u8, allocator: std.mem.Allocator, token: protocol.Token, result: @field(Service.methods, method).Result) ![]u8 {
            _ = try self.methodPending(method, token);
            try schema.validateValue(result);
            const bytes = try protocol.encode(allocator, .{ .v = protocol.version, .session = &self.session.bytes, .kind = "result", .slot = token.slot, .id = token.id, .value = result }, limits.max_message_bytes);
            errdefer allocator.free(bytes);
            _ = try self.methodPending(method, token);
            self.release(token.slot);
            return bytes;
        }

        pub fn fail(self: *Self, comptime method: []const u8, allocator: std.mem.Allocator, token: protocol.Token, code: @field(Service.methods, method).ErrorCode, message: []const u8) ![]u8 {
            _ = try self.methodPending(method, token);
            if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
            const bytes = try protocol.encode(allocator, .{ .v = protocol.version, .session = &self.session.bytes, .kind = "error", .slot = token.slot, .id = token.id, .@"error" = .{ .code = code, .message = message } }, limits.max_message_bytes);
            errdefer allocator.free(bytes);
            _ = try self.methodPending(method, token);
            self.release(token.slot);
            return bytes;
        }

        /// Error.Backpressure leaves state unchanged. Credits are returned only
        /// by valid cumulative acknowledgements of already encoded chunks.
        pub fn chunk(self: *Self, comptime method: []const u8, allocator: std.mem.Allocator, token: protocol.Token, value: @field(Service.methods, method).Item) ![]u8 {
            if (@field(Service.methods, method).Item == void) @compileError("Unary IPC methods do not have chunks");
            const entry = try self.methodPending(method, token);
            if (entry.sent - entry.acknowledged >= limits.max_in_flight) return error.Backpressure;
            if (entry.sent == std.math.maxInt(u32)) return error.SequenceExhausted;
            const sequence = entry.sent + 1;
            try schema.validateValue(value);
            const bytes = try protocol.encode(allocator, .{ .v = protocol.version, .session = &self.session.bytes, .kind = "chunk", .slot = token.slot, .id = token.id, .sequence = sequence, .value = value }, limits.max_message_bytes);
            errdefer allocator.free(bytes);
            const current = try self.methodPending(method, token);
            // ACK advances are compatible with encoding. Another successful
            // nested chunk owns its sequence; never publish the duplicate.
            if (current.sent != sequence - 1) return error.StreamChanged;
            current.sent = sequence;
            return bytes;
        }

        /// The caller receives every canceled work token before recycling state.
        /// A short buffer fails atomically; no pending request is silently lost.
        pub fn close(self: *Self, canceled: []protocol.Token) !usize {
            if (canceled.len < self.active) return error.BufferTooSmall;
            var count: usize = 0;
            for (&self.slots, 0..) |*slot, index| if (slot.*) |entry| {
                canceled[count] = .{ .session = self.session, .slot = @intCast(index), .id = entry.id };
                count += 1;
                slot.* = null;
            };
            self.active = 0;
            self.closed = true;
            return count;
        }

        /// The host must supply a globally fresh document session, never an older
        /// session reused after navigation. No history of closed sessions is kept.
        pub fn reset(self: *Self, session: protocol.Session, canceled: []protocol.Token) !usize {
            if (self.session.eql(session)) return error.SessionReused;
            const count = try self.close(canceled);
            self.* = init(session);
            return count;
        }
    };
}
