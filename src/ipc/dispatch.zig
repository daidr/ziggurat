const std = @import("std");
const schema = @import("schema.zig");
const protocol = @import("protocol.zig");
const Router = @import("router.zig").Router;

/// Result data is borrowed until PendingReply.encode/deinit. It may refer to
/// request strings (whose arena is retained) or explicitly stable caller state.
pub fn Reply(comptime Service: type, comptime method: []const u8) type {
    return ReplyFor(Service, methodTag(Service, method));
}
fn methodTag(comptime Service: type, comptime method: []const u8) std.meta.FieldEnum(@TypeOf(Service.methods)) {
    return std.meta.stringToEnum(std.meta.FieldEnum(@TypeOf(Service.methods)), method) orelse @compileError("Unknown IPC method: " ++ method);
}
fn ReplyFor(comptime Service: type, comptime method: std.meta.FieldEnum(@TypeOf(Service.methods))) type {
    const M = @field(Service.methods, @tagName(method));
    return union(enum) {
        result: M.Result,
        failure: struct { code: M.ErrorCode, message: []const u8 },
    };
}

/// A method explicitly accepting Work takes the parsed request's entire arena.
/// Noncopyable ownership: move with take; deinit each owner exactly once. The
/// token is borrowed protocol identity, not a retained Router or application.
pub fn Work(comptime Service: type, comptime limits: protocol.Limits, comptime method: []const u8) type {
    return WorkFor(Service, limits, methodTag(Service, method));
}
fn WorkFor(comptime Service: type, comptime limits: protocol.Limits, comptime method: std.meta.FieldEnum(@TypeOf(Service.methods))) type {
    return struct {
        const Self = @This();
        storage: ?Router(Service, limits).Received,
        token: protocol.Token,
        params: @field(Service.methods, @tagName(method)).Params,

        pub fn take(self: *Self) !Self {
            if (self.storage == null) return error.Released;
            const result = self.*;
            self.storage = null;
            self.params = undefined;
            return result;
        }
        /// Frees request data only. Complete/fail the token, or cancel/close the
        /// Router separately; discarding data does not silently abandon a call.
        pub fn deinit(self: *Self) void {
            const storage = self.storage orelse return;
            self.storage = null;
            self.params = undefined;
            storage.deinit();
        }
    };
}

fn Replies(comptime Service: type) type {
    const methods = schema.methods(Service);
    @setEvalBranchQuota(20000 + methods.len * 10000);
    var fields: [methods.len]std.builtin.Type.UnionField = undefined;
    for (methods, 0..) |field, index| {
        const T = Reply(Service, field.name);
        fields[index] = .{ .name = field.name, .type = T, .alignment = @alignOf(T) };
    }
    return @Type(.{ .@"union" = .{ .layout = .auto, .tag_type = schema.MethodTag(Service), .fields = &fields, .decls = &.{} } });
}

/// An executed synchronous result, retaining request storage until encoding.
/// Allocator failure leaves this object and pending protocol state unchanged.
pub fn PendingReply(comptime Service: type, comptime limits: protocol.Limits) type {
    @setEvalBranchQuota(20000 + schema.methods(Service).len * 10000);
    return struct {
        const Self = @This();
        storage: ?Router(Service, limits).Received,
        token: protocol.Token,
        reply: Replies(Service),
        encoded: bool = false,

        pub fn take(self: *Self) !Self {
            if (self.storage == null) return error.Released;
            const result = self.*;
            self.storage = null;
            self.reply = undefined;
            return result;
        }
        pub fn encode(self: *Self, router: *Router(Service, limits), allocator: std.mem.Allocator) ![]u8 {
            if (self.storage == null) return error.Released;
            if (self.encoded) return error.AlreadyEncoded;
            switch (self.reply) {
                inline else => |reply, method| {
                    const bytes = switch (reply) {
                        .result => |value| try router.complete(@tagName(method), allocator, self.token, value),
                        .failure => |failure| try router.fail(@tagName(method), allocator, self.token, failure.code, failure.message),
                    };
                    self.encoded = true;
                    return bytes;
                },
            }
        }
        /// Does not release a still-pending token. The caller must encode a
        /// terminal reply, process cancellation, or close/reset its Router.
        pub fn deinit(self: *Self) void {
            const storage = self.storage orelse return;
            self.storage = null;
            self.reply = undefined;
            storage.deinit();
        }
    };
}

/// Compile-time checked service dispatch with caller-owned implementation and
/// context. Sync: fn(*Impl,*Context,Params) Reply. Takeover:
/// fn(*Impl,*Context,Work(Service,limits,method)) void. Neither invokes transport.
pub fn Dispatcher(comptime Service: type, comptime Impl: type, comptime Context: type, comptime limits: protocol.Limits) type {
    const methods = schema.methods(Service);
    @setEvalBranchQuota(20000 + methods.len * 10000);
    if (methods.len == 0) @compileError("An IPC dispatcher requires service methods");
    inline for (methods) |field| validateHandler(Service, Impl, Context, limits, field.name);
    return struct {
        const Self = @This();
        pub const Pending = PendingReply(Service, limits);
        pub const Action = union(enum) {
            reply: Pending,
            taken: protocol.Token,
            cancel: protocol.Token,
            ack: struct { token: protocol.Token, sequence: u32 },
            rejected: protocol.Rejected,
        };
        router: Router(Service, limits),

        pub fn init(session: protocol.Session) Self {
            return .{ .router = .init(session) };
        }

        /// On reply, the caller owns Pending; on taken, the handler owns Work.
        /// Controls retain no parsed data. An addressed invalid call returns
        /// rejection metadata; malformed/foreign/OOM input has no hidden reply.
        pub fn dispatch(self: *Self, allocator: std.mem.Allocator, implementation: *Impl, context: *Context, bytes: []const u8) !Action {
            var rejected: ?protocol.Rejected = null;
            const received = self.router.receiveWithRejection(allocator, bytes, &rejected) catch |err| {
                if (rejected) |value| return .{ .rejected = value };
                return err;
            };
            switch (received.action) {
                .cancel => |token| {
                    received.deinit();
                    return .{ .cancel = token };
                },
                .ack => |token| {
                    const sequence: u32 = @intCast(received.parsed.value.object.get("sequence").?.integer);
                    received.deinit();
                    return .{ .ack = .{ .token = token, .sequence = sequence } };
                },
                .call => |call| {
                    switch (call.params) {
                        inline else => |params, method| {
                            const name = @tagName(method);
                            const handler = @field(Impl, name);
                            const arg = @typeInfo(@TypeOf(handler)).@"fn".params[2].type.?;
                            if (arg == Work(Service, limits, name)) {
                                handler(implementation, context, .{ .storage = received, .token = call.token, .params = params });
                                return .{ .taken = call.token };
                            } else {
                                const reply = handler(implementation, context, params);
                                return .{ .reply = .{ .storage = received, .token = call.token, .reply = @unionInit(Replies(Service), name, reply) } };
                            }
                        },
                    }
                },
            }
        }
    };
}

fn validateHandler(comptime Service: type, comptime Impl: type, comptime Context: type, comptime limits: protocol.Limits, comptime method: []const u8) void {
    if (!@hasDecl(Impl, method)) @compileError("Missing IPC implementation method: " ++ method);
    const info = @typeInfo(@TypeOf(@field(Impl, method)));
    if (info != .@"fn") @compileError("IPC implementation must be a function: " ++ method);
    const function = info.@"fn";
    if (function.is_generic or function.is_var_args or function.params.len != 3 or function.return_type == null) @compileError("IPC handler requires exactly Impl, Context and typed Params/Work: " ++ method);
    if (function.params[0].type != *Impl or function.params[1].type != *Context) @compileError("IPC handler Impl/Context pointer mismatch: " ++ method);
    const arg = function.params[2].type.?;
    if (arg == Work(Service, limits, method)) {
        if (function.return_type.? != void) @compileError("IPC Work handler transfers ownership and must return void: " ++ method);
    } else {
        if (arg != @field(Service.methods, method).Params) @compileError("IPC handler Params mismatch: " ++ method);
        if (function.return_type.? != Reply(Service, method)) @compileError("IPC handler must return the declared typed Reply: " ++ method);
    }
}
