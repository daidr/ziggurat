const std = @import("std");
const zio = @import("ziggurat_io");
const schema = @import("schema.zig");
const protocol = @import("protocol.zig");

pub const Limits = struct { max_subscriptions: u16 = 32, max_message_bytes: usize = 64 * 1024, max_broadcast_targets: u16 = 64 };

/// Explicit, single-owner document subscriptions. No callbacks, hidden queue,
/// timers or transport are stored. Keep this state separate from RPC/stream slots.
pub fn EventSession(comptime Schema: type, comptime limits: Limits) type {
    const fields = schema.events(Schema);
    if (fields.len == 0) @compileError("An event session requires at least one event");
    if (limits.max_subscriptions == 0 or limits.max_message_bytes == 0 or limits.max_broadcast_targets == 0) @compileError("IPC event limits must be positive");
    return struct {
        const Self = @This();
        pub const Token = struct { session: protocol.Session, event_index: u16, subscription: u32 };
        pub const Change = enum { subscribed, unsubscribed, unchanged };
        pub const Target = struct {
            events: *Self,
            token: Token,
            context: *anyopaque,
            /// Borrows bytes only during this call. Error means no acceptance.
            send: *const fn (*anyopaque, []const u8) anyerror!void,
        };
        pub const Delivery = union(enum) { sent, not_subscribed, failed: anyerror };
        pub const Broadcast = struct { sent: usize = 0, not_subscribed: usize = 0, failed: usize = 0 };

        session: protocol.Session,
        subscriptions: [fields.len]?u32 = @splat(null),
        active: usize = 0,
        last_subscription: u32 = 0,
        closed: bool = false,

        pub fn init(session: protocol.Session) Self {
            return .{ .session = session };
        }

        /// Parses event controls only. Route kind=subscribe/unsubscribe here;
        /// call/cancel/ack still go to Router. Parsing has explicit allocation.
        pub fn receive(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !Change {
            if (self.closed) return error.Closed;
            if (bytes.len > limits.max_message_bytes) return error.MessageTooLarge;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return error.InvalidRequest;
            };
            defer parsed.deinit();
            return self.receiveValue(parsed.value);
        }

        /// Hosts that already parsed transport JSON may avoid another parse.
        /// The caller enforces the raw message byte limit before parsing.
        pub fn receiveValue(self: *Self, value: std.json.Value) !Change {
            if (self.closed) return error.Closed;
            if (value != .object or value.object.count() != 5) return error.InvalidRequest;
            const v = value.object.get("v") orelse return error.InvalidRequest;
            const session = value.object.get("session") orelse return error.InvalidRequest;
            const kind = value.object.get("kind") orelse return error.InvalidRequest;
            const event = value.object.get("event") orelse return error.InvalidRequest;
            const subscription = value.object.get("subscription") orelse return error.InvalidRequest;
            if (v != .integer or session != .string or kind != .string or event != .string or subscription != .integer) return error.InvalidRequest;
            if (v.integer != protocol.version) return error.UnsupportedVersion;
            if (!std.mem.eql(u8, session.string, &self.session.bytes)) return error.StaleSession;
            if (subscription.integer < 1 or subscription.integer > std.math.maxInt(u32)) return error.InvalidRequest;
            const id: u32 = @intCast(zio.asUnsigned(subscription.integer));
            const subscribe = std.mem.eql(u8, kind.string, "subscribe");
            if (!subscribe and !std.mem.eql(u8, kind.string, "unsubscribe")) return error.InvalidRequest;
            inline for (fields, 0..) |field, index| {
                if (std.mem.eql(u8, event.string, field.name)) {
                    const current = self.subscriptions[index];
                    if (!subscribe) {
                        if (current == null or current.? != id) return .unchanged;
                        self.subscriptions[index] = null;
                        self.active -= 1;
                        return .unsubscribed;
                    }
                    if (current != null and current.? == id) return .unchanged;
                    if (id <= self.last_subscription) return error.StaleSubscription;
                    if (current == null and self.active >= limits.max_subscriptions) return error.Full;
                    if (current == null) self.active += 1;
                    self.subscriptions[index] = id;
                    self.last_subscription = id;
                    return .subscribed;
                }
            }
            return error.UnknownEvent;
        }

        /// Capture before asynchronous work. Tokens never follow reset or a
        /// replacement subscription. Zero records an unsubscribed destination.
        pub fn token(self: *const Self, comptime event: []const u8) Token {
            const index = comptime eventIndex(event);
            return .{ .session = self.session, .event_index = index, .subscription = self.subscriptions[index] orelse 0 };
        }

        fn eventIndex(comptime event: []const u8) u16 {
            inline for (fields, 0..) |field, index| if (std.mem.eql(u8, event, field.name)) return @intCast(index);
            @compileError("Unknown IPC event: " ++ event);
        }

        fn validateToken(self: *const Self, comptime event: []const u8, captured: Token) !void {
            if (!self.session.eql(captured.session)) return error.StaleSession;
            if (self.closed) return error.Closed;
            const index = comptime eventIndex(event);
            if (captured.event_index != index) return error.WrongEvent;
            if (captured.subscription == 0) return error.NotSubscribed;
            if (self.subscriptions[index] == null or self.subscriptions[index].? != captured.subscription) return error.StaleSubscription;
        }

        /// Returns an owned packet; encoding is pure and has no send side effect.
        /// Retrying the same unaccepted payload/token produces the same packet.
        pub fn emit(self: *const Self, comptime event: []const u8, allocator: std.mem.Allocator, captured: Token, value: @field(Schema.events, event).Payload) ![]u8 {
            try self.validateToken(event, captured);
            try schema.validateValue(value);
            // Encode the captured identity even if an allocator callback resets
            // this session, then reject any invalidation before publication.
            const bytes = try protocol.encode(allocator, .{ .v = protocol.version, .session = &captured.session.bytes, .kind = "event", .event = event, .subscription = captured.subscription, .value = value }, limits.max_message_bytes);
            errdefer allocator.free(bytes);
            try self.validateToken(event, captured);
            return bytes;
        }

        /// Destinations are supplied explicitly, in delivery order. Preflight
        /// rejects duplicate documents or short output before any send. Each
        /// result belongs to the same input index; a failure does not undo sends
        /// already accepted by other documents. Retry that destination or close it.
        pub fn broadcast(comptime event: []const u8, allocator: std.mem.Allocator, targets: []const Target, value: @field(Schema.events, event).Payload, outcomes: []Delivery) !Broadcast {
            if (targets.len > limits.max_broadcast_targets) return error.TooManyTargets;
            if (outcomes.len < targets.len) return error.BufferTooSmall;
            try schema.validateValue(value);
            for (targets, 0..) |target, index| for (targets[0..index]) |previous| {
                if (target.events == previous.events or target.token.session.eql(previous.token.session)) return error.DuplicateSession;
            };
            var result: Broadcast = .{};
            for (targets, 0..) |target, index| {
                const bytes = target.events.emit(event, allocator, target.token, value) catch |err| {
                    if (err == error.NotSubscribed) {
                        outcomes[index] = .not_subscribed;
                        result.not_subscribed += 1;
                    } else {
                        outcomes[index] = .{ .failed = err };
                        result.failed += 1;
                    }
                    continue;
                };
                defer allocator.free(bytes);
                target.send(target.context, bytes) catch |err| {
                    outcomes[index] = .{ .failed = err };
                    result.failed += 1;
                    continue;
                };
                outcomes[index] = .sent;
                result.sent += 1;
            }
            return result;
        }

        pub fn close(self: *Self) void {
            self.closed = true;
            self.subscriptions = @splat(null);
            self.active = 0;
        }

        /// As with Router.reset, the host supplies a globally fresh document ID.
        pub fn reset(self: *Self, session: protocol.Session) !void {
            if (self.session.eql(session)) return error.SessionReused;
            self.* = init(session);
        }
    };
}
