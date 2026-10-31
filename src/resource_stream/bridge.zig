const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ipc = @import("ziggurat_ipc");
const bytes = @import("ziggurat_resource_stream");
const wire = bytes.wire;
const max_streams = 8;
const protocol_limits: ipc.Limits = .{ .max_pending = max_streams, .max_in_flight = 16, .max_message_bytes = 65536 };

pub const Options = struct {
    max_streams: u8 = 8,
    in_flight: u8 = 4,
    chunk_bytes: u16 = 16 * 1024,
    max_chunks: u32 = 1_000_000,
    max_total_bytes: u53 = 256 * 1024 * 1024,
    max_header_bytes: u16 = 8192,
    max_memory_bytes: u32 = 2 * 1024 * 1024,
    pub fn validate(self: Options) !void {
        try (bytes.ControlLimits{ .slots = self.in_flight, .chunk_bytes = self.chunk_bytes, .max_chunks = self.max_chunks, .max_total_bytes = self.max_total_bytes }).validate();
        if (self.max_streams == 0 or self.max_streams > max_streams or self.max_header_bytes == 0 or self.max_header_bytes > 8192 or self.max_memory_bytes < 65536 or self.max_memory_bytes > 16 * 1024 * 1024) return error.InvalidLimits;
    }
};
pub fn Service(comptime Params: type) type {
    return struct {
        pub const methods = .{ .open = ipc.Method(Params, wire.Summary, wire.Failure, wire.Frame) };
    };
}

pub fn Type(comptime Params: type, comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const Schema = Service(Params);
        const Router = ipc.Router(Schema, protocol_limits);
        pub const CloseResult = enum { closed, deferred };
        pub const DrainResult = struct { sent: usize, ready: bool };
        pub const Stats = struct { used_bytes: usize, peak_bytes: usize, physical_streams: usize, offers: usize, wakers: usize };
        const PacketKind = enum { head, body, terminal };
        const Immediate = union(enum) { packet: []u8, full: Router.Received, rejected: ipc.protocol.Rejected };
        const Flow = struct {
            token: ipc.Token,
            control: *bytes.Control,
            head: wire.OwnedHead,
            sequence: bytes.Sequence = .{},
            packet: ?[]u8 = null,
            packet_kind: PacketKind = .head,
            delivery: ?bytes.Delivery = null,
            done: bool = false,
            head_only: bool = false,
        };

        app: *z.App,
        budget: *bytes.Budget,
        allocator: std.mem.Allocator,
        options: Options,
        scratch: []u8,
        router: Router,
        session: ?ipc.Session = null,
        binding: ?Backend.Id = null,
        generation: u64 = 0,
        closed: bool = true,
        flushed: bool = true,
        callbacks: usize = 0,
        offers: usize = 0,
        draining: bool = false,
        router_busy: bool = false,
        cleaning: bool = false,
        cursor: usize = 0,
        flows: [max_streams]?Flow = @splat(null),
        immediate: [max_streams]?Immediate = @splat(null),
        immediate_reserved: [max_streams]bool = @splat(false),
        immediate_cursor: usize = 0,
        terminals_first: bool = true,
        wake_closed: std.atomic.Value(bool) = .init(true),
        wake_refs: std.atomic.Value(usize) = .init(0),
        stop_node: z.StopParticipant = undefined,
        stop_token: ?z.StopToken = null,

        pub fn create(allocator: std.mem.Allocator, app: *z.App, options: Options) !*Self {
            app.assertOwner();
            const app_scope = app.beginCallback() orelse return error.Closed;
            defer app_scope.end();
            try options.validate();
            const budget = try bytes.Budget.create(allocator, options.max_memory_bytes);
            errdefer budget.deinit();
            const owned_allocator = budget.allocator();
            const self = try owned_allocator.create(Self);
            errdefer owned_allocator.destroy(self);
            const scratch = try owned_allocator.alloc(u8, try wire.base64Bytes(options.chunk_bytes));
            errdefer owned_allocator.free(scratch);
            self.* = .{ .app = app, .budget = budget, .allocator = owned_allocator, .options = options, .scratch = scratch, .router = undefined };
            self.stop_node = .{ .context = self, .stop = stop };
            self.stop_token = try app.registerStop(&self.stop_node);
            return self;
        }
        pub fn bind(self: *Self, id: Backend.Id, session: ipc.Session) !void {
            const scope = try self.enter(false);
            defer scope.end();
            if (self.callbacks != 1) return error.Busy;
            self.cleanup();
            if (!self.closed or !self.physicalIdle()) return error.Busy;
            if (self.session) |last| if (last.eql(session)) return error.SessionReused;
            if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
            const pin = try Backend.pin(id);
            defer pin.end();
            if (Backend.owner(pin) != self.app) return error.ForeignApp;
            if (!Backend.live(id)) return error.StalePage;
            self.router = .init(session);
            self.session = session;
            self.binding = id;
            self.generation += 1;
            self.closed = false;
            self.flushed = false;
            self.wake_closed.store(false, .release);
        }
        const Scope = struct {
            bridge: *Self,
            app_scope: z.AppCallbackScope,
            page_scope: ?Backend.Scope,
            generation: u64,
            fn live(self: Scope) bool {
                const bridge = self.bridge;
                if (bridge.closed or bridge.generation != self.generation or bridge.app.phase == .stopping or bridge.app.phase == .stopped) return false;
                return Backend.live(bridge.binding orelse return false);
            }
            fn check(self: Scope) !void {
                if (!self.live()) {
                    self.invalidate();
                    return error.Closed;
                }
            }
            fn invalidate(self: Scope) void {
                const phase = self.bridge.app.phase;
                self.bridge.closeInternal(if (phase == .stopping or phase == .stopped) .closed else .page_changed);
            }
            fn end(self: Scope) void {
                const app = self.app_scope.app;
                self.bridge.leave();
                if (self.page_scope) |page_scope| page_scope.end();
                (z.AppCallbackScope{ .app = app }).end();
            }
        };
        fn enter(self: *Self, bound: bool) !Scope {
            self.app.assertOwner();
            if (self.cleaning) return error.Busy;
            const app_scope = self.app.beginCallback() orelse return error.Closed;
            errdefer app_scope.end();
            self.callbacks += 1;
            errdefer self.leave();
            var page_scope: ?Backend.Scope = null;
            if (bound) {
                if (self.closed) return error.Closed;
                page_scope = Backend.pin(self.binding orelse return error.Closed) catch |err| {
                    self.closeInternal(.page_changed);
                    return err;
                };
                if (Backend.owner(page_scope.?) != self.app) {
                    page_scope.?.end();
                    return error.ForeignApp;
                }
            }
            return .{ .bridge = self, .app_scope = app_scope, .page_scope = page_scope, .generation = self.generation };
        }
        fn leave(self: *Self) void {
            std.debug.assert(self.callbacks != 0);
            if (self.callbacks == 1) self.cleanup();
            self.callbacks -= 1;
        }
        fn closeInternal(self: *Self, reason: bytes.Reason) void {
            self.closed = true;
            self.binding = null;
            self.wake_closed.store(true, .release);
            for (&self.flows) |*entry| if (entry.*) |*flow| {
                flow.done = true;
                flow.sequence.close();
                flow.control.cancel(reason);
            };
        }
        fn disposePacket(self: *Self, flow: *Flow) void {
            if (flow.packet) |packet| {
                flow.packet = null;
                self.allocator.free(packet);
            }
            if (flow.delivery) |*delivery| {
                delivery.deinit();
                flow.delivery = null;
            }
        }
        fn cleanup(self: *Self) void {
            std.debug.assert(!self.cleaning and !self.router_busy);
            self.cleaning = true;
            defer self.cleaning = false;
            // Router operations may be inside external allocator callbacks.
            // The outermost bridge scope alone may clear its old slot storage.
            if (self.closed and !self.flushed) {
                self.flushed = true;
                var cancelled: [max_streams]ipc.Token = undefined;
                _ = self.router.close(&cancelled) catch unreachable;
            }
            if (self.closed) for (&self.immediate) |*entry| if (entry.*) |owned| {
                entry.* = null;
                switch (owned) {
                    .packet => |packet| self.allocator.free(packet),
                    .full => |received| received.deinit(),
                    .rejected => {},
                }
            };
            for (&self.flows) |*entry| if (entry.*) |*flow| {
                if (!flow.done) continue;
                self.disposePacket(flow);
                if (!flow.control.endpointsReleased()) continue;
                var owned = flow.head;
                const control = flow.control;
                entry.* = null;
                owned.deinit();
                control.deinit();
            };
        }
        fn physicalIdle(self: *Self) bool {
            if (self.offers != 0 or self.wake_refs.load(.acquire) != 0) return false;
            for (self.immediate) |packet| if (packet != null) return false;
            for (self.flows) |entry| if (entry != null) return false;
            return true;
        }
        pub fn close(self: *Self) CloseResult {
            self.app.assertOwner();
            const app_scope = self.app.beginTeardownCallback();
            defer app_scope.end();
            self.callbacks += 1;
            defer self.leave();
            self.closeInternal(.closed);
            if (self.callbacks == 1) self.cleanup();
            return if (self.callbacks == 1 and self.physicalIdle()) .closed else .deferred;
        }
        /// Close is logical; deinit refuses to free a binding while an Offer,
        /// Writer, DeliveryTask or outgoing callback still owns responsibility.
        /// Join explicit workers and release their tasks before retrying.
        pub fn deinit(self: *Self) !void {
            const app = self.app;
            app.assertOwner();
            const app_scope = app.beginTeardownCallback();
            defer app_scope.end();
            if (self.callbacks != 0) return error.Busy;
            self.callbacks = 1;
            self.closeInternal(.closed);
            self.cleanup();
            if (!self.physicalIdle()) {
                self.callbacks = 0;
                return error.Busy;
            }
            if (self.stop_token) |token| {
                _ = app.cancelStop(token) catch |err| {
                    self.callbacks = 0;
                    return err;
                };
                self.stop_token = null;
            }
            const allocator = self.allocator;
            const budget = self.budget;
            allocator.free(self.scratch);
            allocator.destroy(self);
            budget.deinit();
        }
        fn stop(context: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.stop_token = null;
            _ = self.close();
        }
        pub fn stats(self: *Self) Stats {
            self.app.assertOwner();
            var count: usize = 0;
            for (self.flows) |entry| if (entry != null) {
                count += 1;
            };
            return .{ .used_bytes = self.budget.used.load(.acquire), .peak_bytes = self.budget.peak.load(.acquire), .physical_streams = count, .offers = self.offers, .wakers = self.wake_refs.load(.acquire) };
        }

        /// Stable, explicitly owned wake context. The worker calls preparePost,
        /// then App.post itself. Failure must call notAccepted; success transfers
        /// that one task reference. deinit drops only the worker's owner.
        pub const DeliveryTask = struct {
            bridge: *Self,
            allocator: std.mem.Allocator,
            generation: u64,
            context: *anyopaque,
            on_ready: *const fn (*anyopaque, *Self) void,
            refs: std.atomic.Value(u32) = .init(1),
            queued: std.atomic.Value(bool) = .init(false),
            pub fn preparePost(self: *DeliveryTask) !?z.Task {
                if (self.bridge.wake_closed.load(.acquire)) return error.Closed;
                if (self.queued.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return null;
                _ = self.refs.fetchAdd(1, .monotonic);
                return .{ .context = self, .call = run };
            }
            pub fn notAccepted(self: *DeliveryTask) void {
                std.debug.assert(self.queued.swap(false, .acq_rel));
                self.release();
            }
            pub fn deinit(self: *DeliveryTask) void {
                self.release();
            }
            fn release(self: *DeliveryTask) void {
                if (self.refs.fetchSub(1, .acq_rel) != 1) return;
                const allocator = self.allocator;
                const bridge = self.bridge;
                _ = bridge.wake_refs.fetchSub(1, .release);
                // A backing free callback may now deinit the bridge. Only
                // independent allocator state is used after surrendering it.
                allocator.destroy(self);
            }
            fn run(context: *anyopaque) void {
                const self: *DeliveryTask = @ptrCast(@alignCast(context));
                const bridge = self.bridge;
                self.queued.store(false, .release);
                defer self.release();
                const scope = bridge.enter(true) catch return;
                defer scope.end();
                if (self.generation != bridge.generation or !scope.live()) return;
                self.on_ready(self.context, bridge);
            }
        };
        pub fn createDeliveryTask(self: *Self, context: *anyopaque, on_ready: *const fn (*anyopaque, *Self) void) !*DeliveryTask {
            const scope = try self.enter(true);
            defer scope.end();
            if (self.wake_refs.load(.acquire) >= self.options.max_streams) return error.Full;
            _ = self.wake_refs.fetchAdd(1, .monotonic);
            errdefer _ = self.wake_refs.fetchSub(1, .release);
            const task = try self.allocator.create(DeliveryTask);
            errdefer self.allocator.destroy(task);
            try scope.check();
            task.* = .{ .bridge = self, .allocator = self.allocator, .generation = self.generation, .context = context, .on_ready = on_ready };
            return task;
        }

        pub const Offer = struct {
            owner: ?*Self,
            generation: u64,
            received: Router.Received,
            token: ipc.Token,
            params: Params,
            answered: bool = false,
            busy: bool = false,
            /// Params remain borrowed until deinit. Discarding this storage
            /// alone does not reply to the pending page request.
            pub fn deinit(self: *Offer) !void {
                const owner = self.owner orelse return;
                if (self.busy) return error.Busy;
                const received = self.received;
                self.owner = null;
                const app_scope = owner.app.beginTeardownCallback();
                defer app_scope.end();
                owner.callbacks += 1;
                defer owner.leave();
                owner.offers -= 1;
                received.deinit();
            }
        };
        pub const Action = union(enum) { offer: Offer, control, rejected };
        pub fn receive(self: *Self, message: []const u8) !Action {
            const scope = try self.enter(true);
            defer scope.end();
            if (self.router_busy) return error.Busy;
            // Reserve terminal storage before receive can take a new token.
            // Full consumes neither the borrowed message nor protocol state;
            // the host must retry that message after drain, or close transport.
            const output = try self.reserveImmediate();
            defer self.immediate_reserved[output] = false;
            var rejection: ?ipc.protocol.Rejected = null;
            const received = self.receiveOwned(message, &rejection) catch |err| {
                try scope.check();
                if (rejection) |value| {
                    self.immediate[output] = .{ .rejected = value };
                    return .rejected;
                }
                return err;
            };
            if (!scope.live()) {
                received.deinit();
                scope.invalidate();
                return error.Closed;
            }
            switch (received.action) {
                .call => |call| {
                    if (call.token.slot >= self.options.max_streams or self.flows[call.token.slot] != null) {
                        // Keep the parsed owner/token until encoding succeeds.
                        // An OOM must not orphan a newly admitted page request.
                        self.immediate[output] = .{ .full = received };
                        return .rejected;
                    }
                    self.offers += 1;
                    return .{ .offer = .{ .owner = self, .generation = self.generation, .received = received, .token = call.token, .params = call.params.open } };
                },
                .cancel => |token| {
                    defer received.deinit();
                    for (&self.immediate) |*entry| if (entry.*) |queued| {
                        if (queued == .full) {
                            const pending = queued.full;
                            const queued_token = pending.action.call.token;
                            if (queued_token.slot == token.slot and queued_token.id == token.id and queued_token.session.eql(token.session)) {
                                entry.* = null;
                                pending.deinit();
                                try scope.check();
                            }
                        }
                    };
                    if (self.findFlow(token)) |flow| {
                        flow.done = true;
                        flow.sequence.close();
                        flow.control.cancel(.cancelled);
                    }
                    return .control;
                },
                .ack => |token| {
                    defer received.deinit();
                    const flow = self.findFlow(token) orelse return error.StaleRequest;
                    const wire_ack: u32 = @intCast(zio.asUnsigned(received.parsed.value.object.get("sequence").?.integer));
                    const body_ack = flow.sequence.acknowledge(wire_ack) catch |err| {
                        self.closeInternal(.transport_failed);
                        return err;
                    };
                    if (body_ack) |body| _ = try flow.control.acknowledge(body);
                    return .control;
                },
            }
        }
        fn receiveOwned(self: *Self, message: []const u8, rejected: *?ipc.protocol.Rejected) !Router.Received {
            std.debug.assert(!self.router_busy);
            self.router_busy = true;
            defer self.router_busy = false;
            return self.router.receiveWithRejection(self.allocator, message, rejected);
        }
        fn encodeFailure(self: *Self, token: ipc.Token, code: wire.Failure, message: []const u8) ![]u8 {
            if (self.router_busy) return error.Busy;
            self.router_busy = true;
            defer self.router_busy = false;
            return self.router.fail("open", self.allocator, token, code, message);
        }
        fn encodeChunk(self: *Self, token: ipc.Token, frame: wire.Frame) ![]u8 {
            if (self.router_busy) return error.Busy;
            self.router_busy = true;
            defer self.router_busy = false;
            return self.router.chunk("open", self.allocator, token, frame);
        }
        fn encodeResult(self: *Self, token: ipc.Token, result: wire.Summary) ![]u8 {
            if (self.router_busy) return error.Busy;
            self.router_busy = true;
            defer self.router_busy = false;
            return self.router.complete("open", self.allocator, token, result);
        }
        fn findFlow(self: *Self, token: ipc.Token) ?*Flow {
            if (token.slot >= max_streams) return null;
            const current = if (self.flows[token.slot]) |*entry| entry else return null;
            if (current.done or current.token.id != token.id or !current.token.session.eql(token.session)) return null;
            return current;
        }
        pub fn accept(self: *Self, offer: *Offer, head: wire.Head, options: struct { head_only: bool = false }) !bytes.Writer {
            const scope = try self.enter(true);
            defer scope.end();
            if (self.router_busy or offer.busy) return error.Busy;
            try self.checkOffer(offer);
            offer.busy = true;
            defer offer.busy = false;
            var owned = try wire.OwnedHead.init(self.allocator, head, self.options.max_total_bytes, self.options.max_header_bytes);
            errdefer owned.deinit();
            try scope.check();
            try self.checkOffer(offer);
            const head_only = options.head_only or head.status == 204 or head.status == 205 or head.status == 304 or head.length == 0;
            const control = try bytes.Control.create(self.allocator, .{ .slots = self.options.in_flight, .chunk_bytes = self.options.chunk_bytes, .max_chunks = self.options.max_chunks, .max_total_bytes = if (!head_only and head.length != null) head.length.? else self.options.max_total_bytes, .allow_body = !head_only });
            errdefer control.deinit();
            var writer = try control.writer();
            errdefer writer.deinit();
            try scope.check();
            try self.checkOffer(offer);
            self.flows[offer.token.slot] = .{ .token = offer.token, .control = control, .head = owned, .head_only = head_only };
            offer.answered = true;
            return writer;
        }
        pub fn reject(self: *Self, offer: *Offer, code: wire.Failure, message: []const u8) !void {
            const scope = try self.enter(true);
            defer scope.end();
            if (self.router_busy or offer.busy) return error.Busy;
            try self.checkOffer(offer);
            const output = try self.reserveImmediate();
            defer self.immediate_reserved[output] = false;
            offer.busy = true;
            defer offer.busy = false;
            const packet = try self.encodeFailure(offer.token, code, message);
            self.immediate[output] = .{ .packet = packet };
            offer.answered = true;
            try scope.check();
        }
        fn checkOffer(self: *Self, offer: *Offer) !void {
            if (offer.owner != self or offer.answered or offer.generation != self.generation or !self.router.contains(offer.token)) return error.StaleOffer;
            if (self.flows[offer.token.slot] != null) return error.Full;
        }
        fn reserveImmediate(self: *Self) !usize {
            for (self.immediate, 0..) |entry, index| if (entry == null and !self.immediate_reserved[index]) {
                self.immediate_reserved[index] = true;
                return index;
            };
            return error.Full;
        }
        fn drainImmediate(self: *Self, scope: Scope, max_packets: usize) !usize {
            var sent: usize = 0;
            var outputs: usize = 0;
            while (outputs < max_streams and sent < max_packets) : (outputs += 1) {
                const index = self.immediate_cursor;
                self.immediate_cursor = (index + 1) % max_streams;
                const owned = self.immediate[index] orelse continue;
                const packet = switch (owned) {
                    .packet => |packet| packet,
                    .full => |received| try self.encodeFailure(received.action.call.token, .full, "Physical stream capacity is full"),
                    .rejected => |value| try ipc.protocol.reject(self.allocator, value.token, value.code, protocol_limits.max_message_bytes),
                };
                if (owned != .packet) {
                    self.immediate[index] = .{ .packet = packet };
                    if (owned == .full) owned.full.deinit();
                }
                try scope.check();
                var utf16 = try self.budget.hold((packet.len + 1) * 2);
                defer utf16.deinit();
                Backend.send(self.binding.?, packet) catch |err| {
                    try scope.check();
                    return err;
                };
                try scope.check();
                self.immediate[index] = null;
                self.allocator.free(packet);
                try scope.check();
                sent += 1;
            }
            return sent;
        }
        pub fn drain(self: *Self, max_packets: u8) !DrainResult {
            if (max_packets == 0 or max_packets > 128) return error.InvalidBatch;
            const scope = try self.enter(true);
            defer scope.end();
            if (self.draining) return error.Busy;
            self.draining = true;
            defer self.draining = false;
            var sent: usize = 0;
            // Alternate the two bounded classes, including max_packets=1.
            // A flood of terminal rejections cannot monopolize every batch.
            const terminals_first = self.terminals_first;
            self.terminals_first = !terminals_first;
            if (terminals_first) sent += try self.drainImmediate(scope, max_packets);
            var visited: usize = 0;
            while (visited < max_streams and sent < max_packets) : (visited += 1) {
                const index = self.cursor;
                self.cursor = (self.cursor + 1) % max_streams;
                const current = if (self.flows[index]) |*entry| entry else continue;
                while (!current.done and sent < max_packets) {
                    if (current.control.reason() != .none) try self.encodeCancelled(scope, current);
                    if (current.packet == null and !try self.encode(scope, current)) break;
                    if (!scope.live()) {
                        scope.invalidate();
                        return error.Closed;
                    }
                    const packet = current.packet.?;
                    var utf16 = try self.budget.hold((packet.len + 1) * 2);
                    defer utf16.deinit();
                    if (current.packet_kind != .terminal) _ = try current.sequence.beginSend();
                    Backend.send(self.binding.?, packet) catch |err| {
                        if (!scope.live()) {
                            scope.invalidate();
                            return error.Closed;
                        }
                        if (!current.done and current.packet_kind != .terminal) _ = current.sequence.endSend(false) catch |failure| {
                            self.closeInternal(.transport_failed);
                            return failure;
                        };
                        return err;
                    };
                    if (!scope.live()) {
                        scope.invalidate();
                        return error.Closed;
                    }
                    if (current.done) break;
                    if (current.packet_kind == .terminal) {
                        current.done = true;
                        current.sequence.close();
                        current.control.cancel(.closed);
                    } else {
                        if (current.delivery) |*delivery| {
                            try delivery.commit();
                            current.delivery = null;
                        }
                        if (try current.sequence.endSend(true)) |ack| _ = try current.control.acknowledge(ack);
                    }
                    current.packet = null;
                    self.allocator.free(packet);
                    try scope.check();
                    sent += 1;
                }
            }
            if (!terminals_first and sent < max_packets) sent += try self.drainImmediate(scope, max_packets - sent);
            return .{ .sent = sent, .ready = sent == max_packets };
        }
        fn encodeCancelled(self: *Self, scope: Scope, current: *Flow) !void {
            if (current.packet != null and current.packet_kind == .terminal) return;
            const packet = try self.encodeFailure(current.token, .cancelled, "Producer cancelled");
            errdefer self.allocator.free(packet);
            try scope.check();
            const previous = current.packet;
            current.packet = packet;
            current.packet_kind = .terminal;
            current.sequence.close();
            if (current.delivery) |*delivery| {
                delivery.deinit();
                current.delivery = null;
            }
            if (previous) |old| self.allocator.free(old);
            // Packet ownership has moved into Flow before the foreign free.
            // Its scope cleanup owns it if that callback closed the bridge.
            if (!scope.live()) scope.invalidate();
        }
        fn encode(self: *Self, scope: Scope, current: *Flow) !bool {
            if (current.sequence.sent - current.sequence.acknowledged >= self.options.in_flight) return false;
            if (current.sequence.sent == 0) {
                _ = try current.sequence.nextWire(null);
                const packet = try self.encodeChunk(current.token, .{ .head = current.head.value });
                current.packet = packet;
                current.packet_kind = .head;
                try scope.check();
                _ = try current.sequence.encoded(null);
                return true;
            }
            if (current.delivery == null) current.delivery = try current.control.take();
            if (current.delivery) |*delivery| {
                if (current.head_only) return error.UnexpectedBody;
                _ = try current.sequence.nextWire(delivery.sequence);
                const body = try wire.encodeBody(self.scratch, delivery.bytes);
                const packet = try self.encodeChunk(current.token, .{ .body = body });
                current.packet = packet;
                current.packet_kind = .body;
                try scope.check();
                _ = try current.sequence.encoded(delivery.sequence);
                return true;
            }
            if (!current.sequence.terminalAllowed(current.control.drained())) return false;
            const total = current.control.total_bytes.load(.acquire);
            const chunks = current.control.produced.load(.acquire);
            const packet = if (!current.head_only and current.head.value.length != null and current.head.value.length.? != total)
                try self.encodeFailure(current.token, .failed, "Representation length mismatch")
            else
                try self.encodeResult(current.token, .{ .bytes = @intCast(total), .chunks = chunks });
            current.packet = packet;
            current.packet_kind = .terminal;
            try scope.check();
            return true;
        }
    };
}

const TestBridge = Type(struct { path: []const u8 }, TestBackend);
const test_session = ipc.Session.init("11111111111111111111111111111111") catch unreachable;
const TestPage = struct {
    app: *z.App,
    bridge: ?*TestBridge = null,
    generation: u64 = 1,
    pins: usize = 0,
    auto_ack: bool = false,
    action: enum { none, fail_before, fail_after_ack, close, navigate, quit } = .none,
    writer: ?*bytes.Writer = null,
    deferred_credit_checked: bool = false,
    packets: std.ArrayList([]u8) = .empty,
    last_pointer: ?[*]const u8 = null,
    fn deinit(self: *TestPage) void {
        for (self.packets.items) |packet| std.testing.allocator.free(packet);
        self.packets.deinit(std.testing.allocator);
    }
    fn id(self: *TestPage) TestBackend.Id {
        return .{ .page = self, .generation = self.generation };
    }
};
const TestBackend = struct {
    pub const Id = struct { page: *TestPage, generation: u64 };
    pub const Scope = struct {
        page: *TestPage,
        pub fn end(self: Scope) void {
            self.page.pins -= 1;
        }
    };
    pub fn pin(id: Id) !Scope {
        if (!live(id)) return error.StalePage;
        id.page.pins += 1;
        return .{ .page = id.page };
    }
    pub fn owner(scope: Scope) *z.App {
        return scope.page.app;
    }
    pub fn live(id: Id) bool {
        return id.page.generation == id.generation;
    }
    pub fn send(id: Id, packet: []const u8) anyerror!void {
        const page = id.page;
        page.last_pointer = packet.ptr;
        if (page.action == .fail_before) return error.InjectedSend;
        try page.packets.append(std.testing.allocator, try std.testing.allocator.dupe(u8, packet));
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, packet, .{});
        defer parsed.deinit();
        if (page.auto_ack and std.mem.eql(u8, parsed.value.object.get("kind").?.string, "chunk")) {
            const sequence: u32 = @intCast(zio.asUnsigned(parsed.value.object.get("sequence").?.integer));
            try testAck(page.bridge.?, sequence);
            if (sequence > 1) if (page.writer) |writer| {
                if (!writer.finished) {
                    try std.testing.expectError(error.Full, writer.tryWrite("x"));
                    page.deferred_credit_checked = true;
                }
            };
        }
        switch (page.action) {
            .fail_after_ack => return error.InjectedSend,
            .close => _ = page.bridge.?.close(),
            .navigate => page.generation += 1,
            .quit => page.app.quit(),
            else => {},
        }
    }
};
fn testOffer(bridge: *TestBridge, id: u32) !TestBridge.Offer {
    const message = try ipc.protocol.encode(std.testing.allocator, .{ .v = 1, .session = &test_session.bytes, .slot = 0, .id = id, .kind = "call", .method = "open", .params = .{ .path = "/private" } }, 65536);
    defer std.testing.allocator.free(message);
    return switch (try bridge.receive(message)) {
        .offer => |offer| offer,
        else => error.ExpectedOffer,
    };
}
fn testAck(bridge: *TestBridge, sequence: u32) !void {
    const message = try ipc.protocol.encode(std.testing.allocator, .{ .v = 1, .session = &test_session.bytes, .slot = 0, .id = 1, .kind = "ack", .sequence = sequence }, 65536);
    defer std.testing.allocator.free(message);
    switch (try bridge.receive(message)) {
        .control => {},
        else => return error.ExpectedControl,
    }
}

test "empty and HEAD resources wait for metadata ACK without returning a body slab" {
    for (0..2) |index| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var page: TestPage = .{ .app = app };
        defer page.deinit();
        const bridge = try TestBridge.create(std.testing.allocator, app, .{});
        defer bridge.deinit() catch unreachable;
        page.bridge = bridge;
        try bridge.bind(page.id(), test_session);
        var offer = try testOffer(bridge, 1);
        defer offer.deinit() catch unreachable;
        var writer = try bridge.accept(&offer, .{ .length = if (index == 0) 0 else 100 }, .{ .head_only = index != 0 });
        try offer.deinit();
        try std.testing.expectError(error.UnexpectedBody, writer.tryWrite("x"));
        try writer.finish();
        writer.deinit();
        try std.testing.expectEqual(1, (try bridge.drain(16)).sent);
        try std.testing.expectEqual(1, page.packets.items.len);
        try std.testing.expectEqual(0, (try bridge.drain(16)).sent);
        try testAck(bridge, 1);
        try std.testing.expectEqual(1, (try bridge.drain(16)).sent);
        try std.testing.expectEqual(0, bridge.stats().physical_streams);
        try std.testing.expectEqual(0, page.pins);
    }
}

test "reentrant ACK frees credit after send commit and physical capacity waits for writer release" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var page: TestPage = .{ .app = app, .auto_ack = true };
    defer page.deinit();
    const bridge = try TestBridge.create(std.testing.allocator, app, .{ .in_flight = 1 });
    defer bridge.deinit() catch unreachable;
    page.bridge = bridge;
    try bridge.bind(page.id(), test_session);
    var offer = try testOffer(bridge, 1);
    var writer = try bridge.accept(&offer, .{ .length = 2 }, .{});
    defer writer.deinit();
    try offer.deinit();
    page.writer = &writer;
    _ = try writer.tryWrite("a");
    try std.testing.expectEqual(2, (try bridge.drain(16)).sent);
    try std.testing.expect(page.deferred_credit_checked);
    _ = try writer.tryWrite("b");
    try writer.finish();
    try std.testing.expectEqual(2, (try bridge.drain(16)).sent);
    try std.testing.expectEqual(1, bridge.stats().physical_streams);
    try std.testing.expectError(error.Busy, bridge.deinit());
    writer.deinit();
    try std.testing.expectEqual(TestBridge.CloseResult.closed, bridge.close());
    try std.testing.expectEqual(0, bridge.stats().physical_streams);
}

test "transport rejection retains exact packet while close or navigation cannot revive it" {
    for (0..4) |index| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var page: TestPage = .{ .app = app, .auto_ack = index == 1, .action = switch (index) {
            0 => .fail_before,
            1 => .fail_after_ack,
            2 => .close,
            else => .navigate,
        } };
        defer page.deinit();
        const bridge = try TestBridge.create(std.testing.allocator, app, .{});
        defer bridge.deinit() catch unreachable;
        page.bridge = bridge;
        try bridge.bind(page.id(), test_session);
        var offer = try testOffer(bridge, 1);
        var writer = try bridge.accept(&offer, .{ .length = 0 }, .{});
        try offer.deinit();
        try writer.finish();
        if (index == 0) {
            try std.testing.expectError(error.InjectedSend, bridge.drain(16));
            const pointer = page.last_pointer;
            const before = bridge.stats().used_bytes;
            try std.testing.expectError(error.InjectedSend, bridge.drain(16));
            try std.testing.expectEqual(pointer, page.last_pointer);
            try std.testing.expectEqual(before, bridge.stats().used_bytes);
            page.action = .none;
            _ = try bridge.drain(16);
            try testAck(bridge, 1);
            _ = try bridge.drain(16);
        } else if (index == 1) {
            try std.testing.expectError(error.TransportContractViolation, bridge.drain(16));
        } else {
            try std.testing.expectError(error.Closed, bridge.drain(16));
        }
        writer.deinit();
        _ = bridge.close();
        try std.testing.expectEqual(0, bridge.stats().physical_streams);
        try std.testing.expectEqual(0, page.pins);
    }
}

const FaultAllocator = struct {
    bridge: ?*TestBridge = null,
    page: ?*TestPage = null,
    offer: ?*TestBridge.Offer = null,
    action: enum { nested, cancel, close_bind, quit } = .nested,
    allocations: usize = 0,
    trigger_at: usize = 0,
    trigger_free: bool = false,
    fired: bool = false,
    checked: usize = 0,
    fn allocator(self: *FaultAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn trigger(self: *FaultAllocator) void {
        self.fired = true;
        const bridge = self.bridge.?;
        switch (self.action) {
            .nested => {
                std.testing.expectError(error.Busy, bridge.accept(self.offer.?, .{ .length = 0 }, .{})) catch unreachable;
                std.testing.expectError(error.Busy, bridge.reject(self.offer.?, .denied, "nested")) catch unreachable;
                std.testing.expectError(error.Busy, self.offer.?.deinit()) catch unreachable;
                self.checked += 3;
            },
            .cancel => {
                const packet = ipc.protocol.encode(std.testing.allocator, .{ .v = 1, .session = &test_session.bytes, .slot = 0, .id = 1, .kind = "cancel" }, 65536) catch unreachable;
                defer std.testing.allocator.free(packet);
                _ = bridge.receive(packet) catch unreachable;
                self.checked += 1;
            },
            .close_bind => {
                _ = bridge.close();
                const replacement = ipc.Session.init("22222222222222222222222222222222") catch unreachable;
                std.testing.expectError(error.Busy, bridge.bind(self.page.?.id(), replacement)) catch unreachable;
                std.testing.expectError(error.Busy, bridge.deinit()) catch unreachable;
                // The old operation is still on the stack. Close may cancel
                // producers, but must not mutate its Router's Pending storage.
                std.testing.expect(bridge.router.active == 1) catch unreachable;
                self.checked += 3;
            },
            .quit => bridge.app.quit(),
        }
    }
    fn allocate(context: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        if (self.trigger_at != 0 and self.allocations == self.trigger_at) {
            self.trigger_at = 0;
            self.trigger();
        }
        return std.testing.allocator.rawAlloc(size, alignment, address);
    }
    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, size: usize, address: usize) bool {
        return std.testing.allocator.rawResize(memory, alignment, size, address);
    }
    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, size: usize, address: usize) ?[*]u8 {
        return std.testing.allocator.rawRemap(memory, alignment, size, address);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *FaultAllocator = @ptrCast(@alignCast(context));
        if (self.trigger_free) {
            self.trigger_free = false;
            self.trigger();
        }
        std.testing.allocator.rawFree(memory, alignment, address);
    }
};

test "accept reserves Offer across every allocation and cancellation cannot publish a producer" {
    for (0..2) |action| for (1..5) |point| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var page: TestPage = .{ .app = app };
        defer page.deinit();
        var fault: FaultAllocator = .{ .page = &page, .action = if (action == 0) .nested else .cancel };
        const bridge = try TestBridge.create(fault.allocator(), app, .{});
        defer bridge.deinit() catch unreachable;
        fault.bridge = bridge;
        page.bridge = bridge;
        try bridge.bind(page.id(), test_session);
        var offer = try testOffer(bridge, 1);
        defer offer.deinit() catch unreachable;
        fault.offer = &offer;
        fault.allocations = 0;
        fault.trigger_at = point;
        if (action == 0) {
            var writer = try bridge.accept(&offer, .{ .length = 0 }, .{});
            try std.testing.expect(offer.answered and !offer.busy);
            writer.deinit();
        } else {
            try std.testing.expectError(error.StaleOffer, bridge.accept(&offer, .{ .length = 0 }, .{}));
            try std.testing.expect(!offer.answered and !offer.busy and !bridge.router.contains(offer.token));
            try std.testing.expectEqual(0, bridge.stats().physical_streams);
        }
        try std.testing.expect(fault.fired and fault.checked == if (action == 0) @as(usize, 3) else 1);
        try std.testing.expectEqual(0, page.packets.items.len);
    };
}

test "allocator close and bind cannot flush an old encoding or packet-free callback" {
    for (0..2) |mode| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var page: TestPage = .{ .app = app };
        defer page.deinit();
        var fault: FaultAllocator = .{ .page = &page, .action = .close_bind };
        const bridge = try TestBridge.create(fault.allocator(), app, .{});
        defer bridge.deinit() catch unreachable;
        fault.bridge = bridge;
        page.bridge = bridge;
        try bridge.bind(page.id(), test_session);
        var offer = try testOffer(bridge, 1);
        var writer = try bridge.accept(&offer, .{ .length = 0 }, .{});
        try offer.deinit();
        if (mode == 0) {
            fault.allocations = 0;
            fault.trigger_at = 1;
        } else fault.trigger_free = true;
        try std.testing.expectError(error.Closed, bridge.drain(16));
        try std.testing.expect(fault.fired and fault.checked == 3 and bridge.closed and bridge.router.active == 0);
        try std.testing.expectEqual(@as(usize, mode), page.packets.items.len);
        writer.deinit();
        try std.testing.expectEqual(TestBridge.CloseResult.closed, bridge.close());
    }
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var page: TestPage = .{ .app = app, .auto_ack = true };
    defer page.deinit();
    const bridge = try TestBridge.create(allocator, app, .{ .in_flight = 1 });
    defer bridge.deinit() catch unreachable;
    page.bridge = bridge;
    try bridge.bind(page.id(), test_session);
    var ready: TestReady = .{ .app = app };
    const task = try bridge.createDeliveryTask(&ready, TestReady.call);
    defer task.deinit();
    var offer = try testOffer(bridge, 1);
    defer offer.deinit() catch unreachable;
    var writer = try bridge.accept(&offer, .{ .length = 1 }, .{});
    defer writer.deinit();
    try offer.deinit();
    _ = try writer.tryWrite("x");
    try writer.finish();
    try std.testing.expectEqual(3, (try bridge.drain(16)).sent);
    try std.testing.expectEqual(0, bridge.router.active);
    try std.testing.expect(bridge.stats().peak_bytes <= bridge.options.max_memory_bytes);
}
test "allocation failures preserve owners throughout receive accept encoding and wake creation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}

const TestReady = struct {
    app: *z.App,
    task: ?*TestBridge.DeliveryTask = null,
    calls: usize = 0,
    repost: bool = false,
    fn call(context: *anyopaque, _: *TestBridge) void {
        const self: *TestReady = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.repost and self.calls == 1) {
            const task = self.task.?.preparePost() catch unreachable;
            self.app.post(task.?) catch unreachable;
        }
    }
    fn nop(_: *anyopaque) void {}
    fn release(task: *TestBridge.DeliveryTask) void {
        task.deinit();
    }
};
test "explicit wake coalesces without losing a ready callback and keeps accepted task responsibility" {
    for (0..3) |mode| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var page: TestPage = .{ .app = app };
        defer page.deinit();
        const bridge = try TestBridge.create(std.testing.allocator, app, .{});
        defer bridge.deinit() catch unreachable;
        page.bridge = bridge;
        try bridge.bind(page.id(), test_session);
        var ready: TestReady = .{ .app = app, .repost = mode == 0 };
        const task = try bridge.createDeliveryTask(&ready, TestReady.call);
        ready.task = task;
        if (mode == 1) {
            for (0..256) |_| try app.post(.{ .context = &ready, .call = TestReady.nop });
            const owned = (try task.preparePost()).?;
            try std.testing.expectError(error.Full, app.post(owned));
            task.notAccepted();
            try app.dispatch();
            try std.testing.expectEqual(0, ready.calls);
        }
        const owned = (try task.preparePost()).?;
        try std.testing.expect((try task.preparePost()) == null);
        try app.post(owned);
        if (mode == 2) {
            try std.testing.expectEqual(TestBridge.CloseResult.deferred, bridge.close());
            task.deinit(); // Only the accepted queue entry still retains it.
            app.quit();
            try app.dispatch();
            try std.testing.expectEqual(0, ready.calls);
            try std.testing.expectEqual(0, bridge.stats().wakers);
        } else {
            try app.dispatch();
            try std.testing.expectEqual(if (mode == 0) @as(usize, 2) else 1, ready.calls);
            try std.testing.expectEqual(TestBridge.CloseResult.deferred, bridge.close());
            // Its final release is allowed on the explicitly managed worker.
            const thread = try std.Thread.spawn(.{}, TestReady.release, .{task});
            thread.join();
        }
        try std.testing.expectEqual(TestBridge.CloseResult.closed, bridge.close());
        try std.testing.expectEqual(0, page.pins);
    }
}

test "dropped producer and truncated representation terminate with an error after metadata" {
    for (0..2) |mode| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var page: TestPage = .{ .app = app, .auto_ack = true };
        defer page.deinit();
        const bridge = try TestBridge.create(std.testing.allocator, app, .{});
        defer bridge.deinit() catch unreachable;
        page.bridge = bridge;
        try bridge.bind(page.id(), test_session);
        var offer = try testOffer(bridge, 1);
        var writer = try bridge.accept(&offer, .{ .length = 10 }, .{});
        try offer.deinit();
        try std.testing.expectEqual(1, (try bridge.drain(16)).sent);
        if (mode == 1) try writer.finish();
        writer.deinit();
        try std.testing.expectEqual(1, (try bridge.drain(16)).sent);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, page.packets.items[1], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("error", parsed.value.object.get("kind").?.string);
        try std.testing.expectEqualStrings(if (mode == 0) "cancelled" else "failed", parsed.value.object.get("error").?.object.get("code").?.string);
        try std.testing.expectEqual(0, bridge.stats().physical_streams);
    }
}

test "terminal queue retains packets and tokens across conversion budget and encoding failures" {
    for (0..3) |mode| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var page: TestPage = .{ .app = app, .auto_ack = true };
        defer page.deinit();
        const bridge = try TestBridge.create(std.testing.allocator, app, .{ .max_streams = 1 });
        defer bridge.deinit() catch unreachable;
        page.bridge = bridge;
        try bridge.bind(page.id(), test_session);
        var writer: ?bytes.Writer = null;
        defer if (writer) |*value| value.deinit();
        if (mode < 2) {
            var offer = try testOffer(bridge, 1);
            defer offer.deinit() catch unreachable;
            if (mode == 0) {
                try bridge.reject(&offer, .denied, "private");
                try std.testing.expect(offer.answered);
            } else {
                writer = try bridge.accept(&offer, .{ .length = 0 }, .{});
                try writer.?.finish();
                try offer.deinit();
                _ = try bridge.drain(16);
                try std.testing.expectEqual(1, bridge.stats().physical_streams);
                try std.testing.expectEqual(TestBridge.Action.rejected, try bridge.receive("{\"v\":1,\"session\":\"11111111111111111111111111111111\",\"slot\":0,\"id\":2,\"kind\":\"call\",\"method\":\"open\",\"params\":{\"path\":\"/private\"}}"));
                // The physical rejection has not encoded yet; its parsed
                // request remains owned and its token still belongs to Router.
                try std.testing.expectEqual(1, bridge.router.active);
            }
        } else {
            try std.testing.expectEqual(TestBridge.Action.rejected, try bridge.receive("{\"v\":1,\"session\":\"11111111111111111111111111111111\",\"slot\":0,\"id\":1,\"kind\":\"call\",\"method\":\"missing\",\"params\":null}"));
        }
        const before = page.packets.items.len;
        // Keep no allocation/conversion capacity. Neither a pending token nor
        // an already encoded terminal packet may disappear on this failure.
        var hold = try bridge.budget.hold(bridge.options.max_memory_bytes - bridge.stats().used_bytes);
        if (mode == 0) {
            try std.testing.expectError(error.Full, bridge.drain(16));
            try std.testing.expectEqual(0, bridge.router.active);
        } else {
            try std.testing.expectError(error.OutOfMemory, bridge.drain(16));
            try std.testing.expectEqual(if (mode == 1) @as(usize, 1) else 0, bridge.router.active);
        }
        try std.testing.expectEqual(before, page.packets.items.len);
        hold.deinit();
        page.action = .fail_before;
        try std.testing.expectError(error.InjectedSend, bridge.drain(16));
        const packet = page.last_pointer;
        const used = bridge.stats().used_bytes;
        try std.testing.expectError(error.InjectedSend, bridge.drain(16));
        try std.testing.expectEqual(packet, page.last_pointer);
        try std.testing.expectEqual(used, bridge.stats().used_bytes);
        page.action = .none;
        try std.testing.expectEqual(1, (try bridge.drain(16)).sent);
        try std.testing.expectEqual(before + 1, page.packets.items.len);
        try std.testing.expectEqual(0, bridge.router.active);
    }
}

test "full terminal queue takes no ownership and alternating batches serve body streams" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var page: TestPage = .{ .app = app, .auto_ack = true };
    defer page.deinit();
    const bridge = try TestBridge.create(std.testing.allocator, app, .{});
    defer bridge.deinit() catch unreachable;
    page.bridge = bridge;
    try bridge.bind(page.id(), test_session);
    var offer = try testOffer(bridge, 1);
    var writer = try bridge.accept(&offer, .{ .length = 1 }, .{});
    defer writer.deinit();
    try offer.deinit();
    _ = try writer.tryWrite("a");
    try writer.finish();
    for (0..max_streams) |index| {
        const message = try ipc.protocol.encode(std.testing.allocator, .{ .v = 1, .session = &test_session.bytes, .slot = 1, .id = index + 2, .kind = "call", .method = "missing", .params = {} }, 65536);
        defer std.testing.allocator.free(message);
        _ = try bridge.receive(message);
    }
    const retry = "{\"v\":1,\"session\":\"11111111111111111111111111111111\",\"slot\":1,\"id\":10,\"kind\":\"call\",\"method\":\"missing\",\"params\":null}";
    try std.testing.expectError(error.Full, bridge.receive(retry));
    try std.testing.expectEqual(1, bridge.router.active);
    try std.testing.expectEqual(1, (try bridge.drain(1)).sent);
    try std.testing.expectEqual(1, (try bridge.drain(1)).sent);
    // First batch served a terminal; the second must still deliver metadata.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, page.packets.items[1], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("chunk", parsed.value.object.get("kind").?.string);
    _ = try bridge.receive(retry);
    _ = try bridge.drain(32);
    _ = try bridge.drain(32);
    try std.testing.expectEqual(0, bridge.router.active);
}

test "cancel removes queued physical rejection without affecting a replacement token" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var page: TestPage = .{ .app = app, .auto_ack = true };
    defer page.deinit();
    const bridge = try TestBridge.create(std.testing.allocator, app, .{});
    defer bridge.deinit() catch unreachable;
    page.bridge = bridge;
    try bridge.bind(page.id(), test_session);
    var offer = try testOffer(bridge, 1);
    var writer = try bridge.accept(&offer, .{ .length = 0 }, .{});
    defer writer.deinit();
    try offer.deinit();
    try writer.finish();
    _ = try bridge.drain(16);
    for (2..4) |id| {
        const message = try ipc.protocol.encode(std.testing.allocator, .{ .v = 1, .session = &test_session.bytes, .slot = 0, .id = id, .kind = "call", .method = "open", .params = .{ .path = "/physical-full" } }, 65536);
        defer std.testing.allocator.free(message);
        try std.testing.expectEqual(TestBridge.Action.rejected, try bridge.receive(message));
        if (id == 2) {
            const cancel = try ipc.protocol.encode(std.testing.allocator, .{ .v = 1, .session = &test_session.bytes, .slot = 0, .id = id, .kind = "cancel" }, 65536);
            defer std.testing.allocator.free(cancel);
            _ = try bridge.receive(cancel);
            try std.testing.expectEqual(0, bridge.router.active);
            for (bridge.immediate) |entry| try std.testing.expect(entry == null);
        }
    }
    try std.testing.expectEqual(1, bridge.router.active);
    try std.testing.expectEqual(1, (try bridge.drain(16)).sent);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, page.packets.items[2], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(3, parsed.value.object.get("id").?.integer);
    try std.testing.expectEqual(0, bridge.router.active);
}

test "shutdown during transport or message allocation closes producers without reporting page replacement" {
    for (0..2) |mode| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var page: TestPage = .{ .app = app, .action = if (mode == 0) .quit else .none };
        defer page.deinit();
        var fault: FaultAllocator = .{ .page = &page, .action = .quit };
        const bridge = try TestBridge.create(fault.allocator(), app, .{});
        defer bridge.deinit() catch unreachable;
        fault.bridge = bridge;
        page.bridge = bridge;
        try bridge.bind(page.id(), test_session);
        var offer = try testOffer(bridge, 1);
        var writer = try bridge.accept(&offer, .{ .length = 0 }, .{});
        defer writer.deinit();
        try offer.deinit();
        if (mode == 0) {
            try std.testing.expectError(error.Closed, bridge.drain(16));
        } else {
            fault.allocations = 0;
            fault.trigger_at = 1;
            try std.testing.expectError(error.Closed, bridge.receive("{\"v\":1,\"session\":\"11111111111111111111111111111111\",\"slot\":0,\"id\":1,\"kind\":\"cancel\"}"));
        }
        try std.testing.expectEqual(bytes.Reason.closed, writer.control.?.reason());
    }
}
