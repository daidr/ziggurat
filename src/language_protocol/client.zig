const std = @import("std");
const d = @import("ziggurat_document");
const code = @import("ziggurat_code_editor");
const codec = @import("codec.zig");
const positions = @import("positions.zig");
const wire = @import("wire.zig");
const convert = @import("convert.zig");
const workspace = @import("workspace.zig");
const configuration = @import("configuration.zig");
const resolving = @import("completion_resolve.zig");
const shutdown = @import("shutdown.zig");
pub const ShutdownOptions = shutdown.Options;
pub const ShutdownLimits = shutdown.Limits;

pub const Limits = struct {
    pending: usize = 8,
    syncs: usize = 2,
    diagnostics: usize = 4,
    /// Conservative sum of all simultaneously allowed preparation reservations.
    /// Document Snapshot/Reader memory and host transport buffers are separate.
    bytes: usize = 256 * 1024 * 1024,
    framing: codec.Limits = .{},
    map: positions.Limits = .{},
    sync: wire.PreparationLimits = .{},
    conversion: convert.Limits = .{},
};
pub const Phase = enum { cold, initializing, awaiting_initialize, negotiated, ready, awaiting_shutdown, shutdown_replied, stopped };
pub const Stats = struct { epoch: u64, phase: Phase, requests: usize, syncs: usize, diagnostics: usize, transports: usize, reservation_bytes: usize, server_version: ?i32, text_version: ?u64, workspace_version: ?u64, configuration_version: ?u64, workspace_products: usize, workspace_incoming: usize };
pub const Handshake = struct { client: *Client, epoch: u64, id: i32 };
pub const Negotiated = struct { token: Handshake, capabilities: wire.Capabilities };
pub const Request = struct { client: *Client, epoch: u64, index: u8, serial: u64, id: i32 };
pub const Commit = struct { accepted: bool = true, stale: bool, cancellation_error: ?anyerror = null };
pub const Adopt = struct { published: bool = false, rejected: ?anyerror = null, remote_code: ?i32 = null, incomplete: bool = false };
const SyncControl = struct { live: bool = false, cancellation: positions.Cancellation = .{} };
const Slot = struct {
    role: enum { request, resolve } = .request,
    serial: u64 = 0,
    epoch: u64 = 0,
    id: i32 = 0,
    ticket: code.Ticket = undefined,
    workspace_version: ?u64 = null,
    configuration_version: ?u64 = null,
    /// 0 idle, 1 worker preparation, 2 prepared, 3 accepted send, 4 delivery.
    stage: std.atomic.Value(u8) = .init(0),
    cancellation: positions.Cancellation = .{},
};

/// Owner-only protocol policy. This creates no process, thread, socket, pipe,
/// queue or timer. Stable Client/Broker addresses cover every linear lease.
/// Worker allocators support all threads on which their products are released.
pub const Client = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    broker: *code.Broker,
    uri: []u8,
    language: []u8,
    limits: Limits,
    slots: []Slot,
    epoch: u64 = 1,
    serial: u64 = 0,
    next_id: i32 = 1,
    handshake_id: i32 = 0,
    phase: Phase = .cold,
    caps: wire.Capabilities = .{},
    accepted_version: ?i32 = null,
    accepted_text: ?u64 = null,
    sync_inflight: bool = false,
    live_requests: usize = 0,
    live_syncs: usize = 0,
    sync_controls: [8]SyncControl = @splat(.{}),
    transports: std.atomic.Value(usize) = .init(0),
    diagnostic_leases: std.atomic.Value(usize) = .init(0),
    reservation: usize,
    workspace_state: ?*WorkspaceState = null,
    resolve_options: ?struct { source: u64, limits: resolving.Limits } = null,
    shutdown_control: shutdown.Control = .{},
    busy: bool = false,

    pub fn create(allocator: std.mem.Allocator, broker: *code.Broker, uri: []const u8, language: []const u8, limits: Limits) !*Client {
        if (broker.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (limits.pending == 0 or limits.pending > 32 or limits.syncs == 0 or limits.syncs > 8 or limits.diagnostics == 0 or limits.diagnostics > 32 or limits.bytes > 1024 * 1024 * 1024) return error.InvalidLimits;
        if (limits.conversion.continuation != null or limits.map.cancellation != null or limits.sync.positions.cancellation != null or limits.conversion.request_position != null) return error.InvalidLimits;
        try limits.framing.validate();
        try limits.map.validate();
        try limits.sync.validate();
        try convert.validate(limits.conversion);
        try limits.conversion.result.validate();
        try validString(uri, 4096);
        try validString(language, 128);
        // Reservations cover product metadata plus every enabled sub-budget.
        // Native/Document/host I/O allocations are not charged to this account.
        var request_bytes: usize = 0;
        for ([_]usize{ @sizeOf(Work), @sizeOf(Delivery), limits.map.bytes, limits.framing.body_bytes, 64, limits.framing.json_bytes, limits.conversion.bytes }) |bytes| try charge(&request_bytes, 1, bytes, limits.bytes);
        var diagnostic_bytes: usize = 0;
        for ([_]usize{ @sizeOf(DiagnosticDelivery), limits.framing.json_bytes, limits.conversion.bytes }) |bytes| try charge(&diagnostic_bytes, 1, bytes, limits.bytes);
        var sync_bytes: usize = 0;
        try charge(&sync_bytes, 1, @sizeOf(SyncWork), limits.bytes);
        try charge(&sync_bytes, 1, limits.sync.bytes, limits.bytes);
        var reservation: usize = 0;
        try charge(&reservation, 1, @sizeOf(Client), limits.bytes);
        try charge(&reservation, limits.pending, @sizeOf(Slot), limits.bytes);
        try charge(&reservation, 1, uri.len, limits.bytes);
        try charge(&reservation, 1, language.len, limits.bytes);
        try charge(&reservation, limits.pending, request_bytes, limits.bytes);
        try charge(&reservation, limits.syncs, sync_bytes, limits.bytes);
        try charge(&reservation, limits.diagnostics, diagnostic_bytes, limits.bytes);
        try broker.retainClient();
        errdefer broker.releaseClient() catch unreachable;
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, limits.pending);
        errdefer allocator.free(slots);
        const uri_copy = try allocator.dupe(u8, uri);
        errdefer allocator.free(uri_copy);
        const language_copy = try allocator.dupe(u8, language);
        errdefer allocator.free(language_copy);
        for (slots) |*value| value.* = .{};
        if (broker.stopping) return error.Closed;
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .broker = broker, .uri = uri_copy, .language = language_copy, .limits = limits, .slots = slots, .reservation = reservation };
        return self;
    }
    fn check(self: *const Client) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    fn enter(self: *Client) !void {
        try self.check();
        self.busy = true;
    }
    fn ready(self: *const Client) !void {
        if (self.phase == .stopped or self.broker.stopping) return error.Closed;
        if (self.phase != .ready) return error.NotReady;
    }
    fn responding(self: *const Client) !void {
        switch (self.phase) {
            .awaiting_shutdown, .shutdown_replied => {},
            else => try self.ready(),
        }
    }
    fn canRespond(self: *const Client) bool {
        return self.phase == .ready or self.phase == .awaiting_shutdown or self.phase == .shutdown_replied;
    }
    fn slot(self: *Client, token: Request) !*Slot {
        if (token.client != self or token.index >= self.slots.len) return error.ForeignRequest;
        const value = &self.slots[token.index];
        if (value.serial != token.serial or token.serial == 0 or value.epoch != token.epoch or value.id != token.id) return error.StaleRequest;
        return value;
    }
    fn id(self: *Client) !i32 {
        if (self.next_id == std.math.maxInt(i32)) return error.IdExhausted;
        const result = self.next_id;
        self.next_id += 1;
        return result;
    }
    pub fn stats(self: *const Client) !Stats {
        try self.check();
        return .{ .epoch = self.epoch, .phase = self.phase, .requests = self.live_requests, .syncs = self.live_syncs, .diagnostics = self.diagnostic_leases.load(.acquire), .transports = self.transports.load(.acquire), .reservation_bytes = self.reservation, .server_version = self.accepted_version, .text_version = self.accepted_text, .workspace_version = self.workspaceVersion(), .configuration_version = self.configurationVersion(), .workspace_products = if (self.workspace_state) |state| state.live_products else 0, .workspace_incoming = if (self.workspace_state) |state| state.incoming.load(.acquire) else 0 };
    }
    fn workspaceVersion(self: *const Client) ?u64 {
        return if (self.workspace_state) |state| state.accepted else null;
    }
    fn configurationVersion(self: *const Client) ?u64 {
        if (self.workspace_state) |state| if (state.configuration) |config| return config.accepted;
        return null;
    }
    /// One-time opt-in with no Transport or physical request alive. Restart
    /// retains these immutable options; it never reconfigures worker policy.
    /// Resolution shares pending slots and never creates a second Broker Job.
    pub fn enableCompletionResolve(self: *Client, limits: resolving.Limits) !void {
        try self.enter();
        defer self.busy = false;
        if (self.broker.stopping or self.phase == .stopped) return error.Closed;
        if (self.phase != .cold or self.resolve_options != null) return error.InvalidPhase;
        if (self.transports.load(.acquire) != 0 or self.live_requests != 0) return error.ClientsAlive;
        try limits.validate();
        const result = resultLimits(self.limits.conversion.result, self.broker.limits.results);
        var required: usize = 0;
        for ([_]usize{ @sizeOf(ResolveWork), @sizeOf(ResolveDelivery), result.bytes, result.bytes, self.limits.framing.json_bytes, limits.source_json_bytes, self.limits.framing.body_bytes, 64 }) |bytes| try charge(&required, 1, bytes, limits.bytes);
        try charge(&required, result.completions, @sizeOf(code.Completion), limits.bytes);
        var ordinary: usize = 0;
        for ([_]usize{ @sizeOf(Work), @sizeOf(Delivery), self.limits.map.bytes, self.limits.framing.body_bytes, 64, self.limits.framing.json_bytes, self.limits.conversion.bytes }) |bytes| try charge(&ordinary, 1, bytes, self.limits.bytes);
        var reservation = self.reservation;
        try charge(&reservation, self.limits.pending, required -| ordinary, self.limits.bytes);
        self.resolve_options = .{ .source = try resolving.sourceIdentity(), .limits = limits };
        self.reservation = reservation;
    }
    /// Copies one bounded immutable list on the owner; no document scan, native
    /// layout or async Presenter pointer escapes. Allocator covers worker use
    /// and any published result's last free after Client/Presenter closure.
    pub fn beginResolve(self: *Client, allocator: std.mem.Allocator, choice: code.CompletionChoice) !ResolveWork {
        try self.enter();
        defer self.busy = false;
        try self.ready();
        const options = self.resolve_options orelse return error.ResolveDisabled;
        if (!self.caps.completion_resolve) return error.UnsupportedMethod;
        const index = for (self.slots, 0..) |value, at| {
            if (value.serial == 0) break at;
        } else return error.Full;
        if (self.serial == std.math.maxInt(u64) or self.next_id == std.math.maxInt(i32)) return error.IdExhausted;
        if (choice.ticket.broker != self.broker) return error.ForeignChoice;
        const borrow = try self.broker.borrow();
        defer borrow.end();
        const display = try borrow.display(.completion) orelse return error.StaleChoice;
        if (!std.meta.eql(display.ticket, choice.ticket) or self.broker.display_generation != choice.display_generation or choice.index >= display.data.completion.len) return error.StaleChoice;
        const continuation = display.data.completion[choice.index].continuation orelse return error.ContinuationRequired;
        if (continuation.source != options.source or continuation.generation != self.epoch) return error.ForeignContinuation;
        if (self.sync_inflight or self.accepted_text != display.ticket.text_version) return error.SynchronizationRequired;
        const selected = resultLimits(self.limits.conversion.result, self.broker.limits.results);
        var input = try code.OwnedResult.init(allocator, display.data, selected);
        errdefer input.deinit();
        try self.ready();
        if (choice.ticket.revision != try self.broker.document.version() or try self.broker.document.composition() != null) return error.StaleRevision;
        self.serial += 1;
        const identifier = try self.id();
        const value = &self.slots[index];
        value.role = .resolve;
        value.serial = self.serial;
        value.id = identifier;
        value.epoch = self.epoch;
        value.ticket = choice.ticket;
        value.workspace_version = self.workspaceVersion();
        value.configuration_version = self.configurationVersion();
        value.cancellation.requested.store(false, .monotonic);
        value.stage.store(1, .release);
        self.live_requests += 1;
        return .{ .token = .{ .client = self, .epoch = self.epoch, .index = @intCast(index), .serial = self.serial, .id = identifier }, .choice = choice, .input = input, .limits = options.limits, .result_limits = selected };
    }
    /// Opt-in before initialize. Copies only lexical file-URI identities; it
    /// never discovers roots or accesses the filesystem.
    pub fn enableWorkspace(self: *Client, options: workspace.Options, limits: workspace.Limits) !void {
        try self.enter();
        defer self.busy = false;
        if (self.broker.stopping) return error.Closed;
        if (self.transports.load(.acquire) != 0) return error.TransportsAlive;
        if (self.phase != .cold or self.workspace_state != null) return error.InvalidPhase;
        try limits.validate();
        var reservation = self.reservation;
        try charge(&reservation, 1, @sizeOf(WorkspaceState), self.limits.bytes);
        try charge(&reservation, 2 + 2 * limits.products + limits.incoming, limits.bytes, self.limits.bytes);
        try charge(&reservation, limits.products, @sizeOf(WorkspaceWork) + self.limits.framing.body_bytes + 64, self.limits.bytes);
        try charge(&reservation, limits.incoming, @sizeOf(WorkspaceIncoming), self.limits.bytes);
        try charge(&reservation, limits.incoming, self.limits.framing.json_bytes, self.limits.bytes);
        try charge(&reservation, limits.incoming, self.limits.framing.body_bytes + 64 + 256, self.limits.bytes);
        const state = try self.allocator.create(WorkspaceState);
        errdefer self.allocator.destroy(state);
        const snapshot = try workspace.Snapshot.create(self.allocator, options, limits);
        errdefer snapshot.release();
        if (self.broker.stopping) return error.Closed;
        state.* = .{ .limits = limits, .current = snapshot, .incoming_epoch = .init(self.epoch) };
        self.workspace_state = state;
        self.reservation = reservation;
    }
    /// Before any transport opens, explicitly move an independently prepared
    /// configuration into this Client. Failed adoption retains the original.
    pub fn enableConfiguration(self: *Client, prepared: *configuration.Prepared, limits: configuration.Limits) !void {
        try self.enter();
        defer self.busy = false;
        if (self.broker.stopping) return error.Closed;
        if (self.phase != .cold) return error.InvalidPhase;
        if (self.transports.load(.acquire) != 0 or self.live_requests != 0 or self.live_syncs != 0) return error.ClientsAlive;
        const state = self.workspace_state orelse return error.WorkspaceRequired;
        if (state.configuration != null or state.live_products != 0 or state.incoming.load(.acquire) != 0) return error.InvalidPhase;
        try limits.validate();
        const snapshot = try prepared.check();
        try snapshot.fits(limits, self.limits.framing);
        var reservation = self.reservation;
        try charge(&reservation, 1, @sizeOf(ConfigurationState), self.limits.bytes);
        try charge(&reservation, 2 + 2 * state.limits.products + state.limits.incoming, limits.bytes, self.limits.bytes);
        try charge(&reservation, state.limits.products, @sizeOf(ConfigurationWork), self.limits.bytes);
        try charge(&reservation, state.limits.incoming, limits.query_bytes, self.limits.bytes);
        prepared.busy = true;
        defer prepared.busy = false;
        const config = try self.allocator.create(ConfigurationState);
        errdefer self.allocator.destroy(config);
        try workspace.cancelled(prepared.cancellation);
        if (self.broker.stopping) return error.Closed;
        config.* = .{ .limits = limits, .current = snapshot };
        state.configuration = config;
        prepared.snapshot = null;
        self.reservation = reservation;
    }
    pub fn reconfigureConfiguration(self: *Client, prepared: *configuration.Prepared) !void {
        try self.enter();
        defer self.busy = false;
        if (self.broker.stopping) return error.Closed;
        if (self.phase != .cold) return error.InvalidPhase;
        const config = (self.workspace_state orelse return error.WorkspaceRequired).configuration orelse return error.ConfigurationRequired;
        if (config.version == std.math.maxInt(u64)) return error.IdExhausted;
        const snapshot = try prepared.check();
        try snapshot.fits(config.limits, self.limits.framing);
        prepared.busy = true;
        defer prepared.busy = false;
        const previous = config.current;
        config.current = snapshot;
        config.version += 1;
        prepared.snapshot = null;
        previous.release();
    }
    pub fn captureConfigurationChange(self: *Client, prepared: *configuration.Prepared) !ConfigurationWork {
        try self.enter();
        defer self.busy = false;
        try self.ready();
        const state = self.workspace_state orelse return error.WorkspaceRequired;
        const config = state.configuration orelse return error.ConfigurationRequired;
        if (state.pending) return error.WorkspacePending;
        if (config.version == std.math.maxInt(u64)) return error.IdExhausted;
        const candidate = try prepared.check();
        try candidate.fits(config.limits, self.limits.framing);
        const control = try state.reserve();
        errdefer state.unreserve(control);
        try config.current.retain();
        const result: ConfigurationWork = .{ .client = self, .epoch = self.epoch, .version = config.version + 1, .base_version = config.accepted.?, .workspace_version = state.accepted.?, .base = config.current, .candidate = candidate, .control = control };
        state.pending = true;
        prepared.snapshot = null;
        return result;
    }
    /// Explicit cold-epoch replacement, including rootUri/single-file mode.
    /// Call restart first for a running service. Old products retain immutable
    /// snapshots; a failed candidate leaves the configured snapshot unchanged.
    pub fn reconfigureWorkspace(self: *Client, options: workspace.Options) !void {
        try self.enter();
        defer self.busy = false;
        if (self.broker.stopping) return error.Closed;
        if (self.phase != .cold) return error.InvalidPhase;
        const state = self.workspace_state orelse return error.WorkspaceRequired;
        if (state.version == std.math.maxInt(u64)) return error.IdExhausted;
        const candidate = try workspace.Snapshot.create(self.allocator, options, state.limits);
        errdefer candidate.release();
        if (self.broker.stopping) return error.Closed;
        const previous = state.current;
        state.current = candidate;
        state.version += 1;
        previous.release();
    }
    pub fn captureWorkspaceInitialize(self: *Client, token: Handshake) !WorkspaceWork {
        try self.enter();
        defer self.busy = false;
        try self.handshake(token);
        if (self.phase != .initializing) return error.InvalidPhase;
        const state = self.workspace_state orelse return error.WorkspaceRequired;
        if (state.pending) return error.WorkspacePending;
        const control = try state.reserve();
        errdefer state.unreserve(control);
        try state.current.retain();
        state.pending = true;
        return .{ .client = self, .epoch = self.epoch, .version = state.version, .candidate = state.current, .control = control, .handshake = token, .configuration_support = state.configuration != null, .completion_resolve = self.resolve_options != null };
    }
    pub fn captureWorkspaceChange(self: *Client, options: workspace.Options) !WorkspaceWork {
        try self.enter();
        defer self.busy = false;
        try self.ready();
        const state = self.workspace_state orelse return error.WorkspaceRequired;
        if (!self.caps.workspace_folders or !self.caps.workspace_changes) return error.WorkspaceRestartRequired;
        if (state.pending) return error.WorkspacePending;
        if (state.version == std.math.maxInt(u64)) return error.IdExhausted;
        // rootUri and single-file/open-workspace mode have no live-change wire
        // representation. Changing either needs an explicit process restart.
        if (!optionalTextEqual(options.root_uri, state.current.root_uri) or (options.folders == null) != (state.current.folders == null) or options.path_case != state.current.path_case) return error.WorkspaceRestartRequired;
        const control = try state.reserve();
        errdefer state.unreserve(control);
        const candidate = try workspace.Snapshot.create(self.allocator, options, state.limits);
        errdefer candidate.release();
        if (self.broker.stopping) return error.Closed;
        try state.current.retain();
        state.pending = true;
        return .{ .client = self, .epoch = self.epoch, .version = state.version + 1, .base_version = state.version, .base = state.current, .candidate = candidate, .control = control };
    }
    /// Linear transport lease, explicitly moved to/joined from the host worker.
    /// Old transports can finish old work after restart, never publish new work.
    pub fn openTransport(self: *Client) !Transport {
        try self.check();
        if (self.phase == .stopped) return error.Closed;
        if (self.transports.load(.acquire) >= 32) return error.Full;
        _ = self.transports.fetchAdd(1, .monotonic);
        return .{ .client = self, .epoch = self.epoch };
    }
    /// Capture one control product without starting IO or withdrawing service.
    /// Only an accepted ShutdownSend commits the logical shutdown boundary.
    pub fn captureShutdown(self: *Client, options: ShutdownOptions) !ShutdownWork {
        try self.enter();
        defer self.busy = false;
        if (self.phase == .stopped) return error.Closed;
        if (self.phase != .ready) return error.NotReady;
        try options.limits.validate();
        const control = &self.shutdown_control;
        if (control.active()) return error.Full;
        if (control.serial == shutdown.max_serial or self.next_id == std.math.maxInt(i32)) return error.IdExhausted;
        var reservation = self.reservation;
        for ([_]usize{ @sizeOf(ShutdownWork), @sizeOf(ShutdownReply), @sizeOf(ShutdownSend), @sizeOf(ControlSend), 128 + 64, options.limits.json_bytes }) |bytes| try charge(&reservation, 1, bytes, self.limits.bytes);
        const identifier = try self.id();
        control.serial += 1;
        control.reservation_bytes = reservation - self.reservation;
        control.cancelled.store(false, .monotonic);
        self.reservation = reservation;
        control.word.store(shutdown.stamp(control.serial, .captured), .release);
        return .{ .client = self, .epoch = self.epoch, .serial = control.serial, .id = identifier, .options = options };
    }
    /// A short owner-only FIFO admission scope, never a write or IO wait.
    /// Pure Transport encoders alone do not authorize a later send.
    pub fn beginControlSend(self: *Client, message: ControlMessage) !ControlSend {
        try self.enter();
        errdefer self.busy = false;
        switch (message) {
            .initialize => |token| {
                try self.handshake(token);
                if (self.phase != .initializing) return error.InvalidPhase;
            },
            .initialized => |token| {
                try self.handshake(token);
                if (self.phase != .negotiated) return error.InvalidPhase;
            },
            .cancellation => |token| {
                try self.ready();
                if (token.epoch != self.epoch) return error.StaleEpoch;
                const value = try self.slot(token);
                if (value.stage.load(.acquire) != 3) return error.NotSent;
            },
        }
        return .{ .client = self, .message = message };
    }
    pub fn beginInitialize(self: *Client) !Handshake {
        try self.enter();
        defer self.busy = false;
        if (self.phase == .stopped) return error.Closed;
        if (self.phase != .cold) return error.InvalidPhase;
        const identifier = try self.id();
        self.handshake_id = identifier;
        self.phase = .initializing;
        return .{ .client = self, .epoch = self.epoch, .id = identifier };
    }
    fn handshake(self: *Client, token: Handshake) !void {
        if (token.client != self or token.epoch != self.epoch or token.id != self.handshake_id) return error.StaleEpoch;
    }
    pub fn commitInitialize(self: *Client, token: Handshake) !void {
        try self.check();
        try self.handshake(token);
        if (self.phase != .initializing) return error.InvalidPhase;
        self.phase = .awaiting_initialize;
    }
    pub fn adoptInitialize(self: *Client, negotiated: Negotiated) !void {
        try self.check();
        try self.handshake(negotiated.token);
        if (self.phase != .awaiting_initialize) return error.InvalidPhase;
        self.caps = negotiated.capabilities;
        self.phase = .negotiated;
    }
    /// Call only after the host accepts responsibility for initialized packet.
    pub fn commitReady(self: *Client, token: Handshake) !void {
        try self.check();
        try self.handshake(token);
        if (self.phase != .negotiated) return error.InvalidPhase;
        self.publishReady();
    }
    fn publishReady(self: *Client) void {
        self.phase = .ready;
        if (self.workspace_state) |state| state.accepted = state.version;
        if (self.workspace_state) |state| if (state.configuration) |config| {
            config.accepted = config.version;
        };
    }
    /// Restart invalidates logical state immediately, not physical work. Epoch
    /// never wraps; old worker/queued deliveries keep their fixed slots/leases.
    pub fn restart(self: *Client) !void {
        try self.enter();
        defer self.busy = false;
        if (self.phase == .stopped) return error.Closed;
        const epoch = std.math.add(u64, self.epoch, 1) catch return error.IdExhausted;
        try self.broker.invalidateAll();
        if (self.shutdown_control.active()) self.shutdown_control.cancelled.store(true, .release);
        for (self.slots) |*value| if (value.serial != 0) value.cancellation.request();
        for (&self.sync_controls) |*control| if (control.live) control.cancellation.request();
        self.epoch = epoch;
        self.phase = .cold;
        self.caps = .{};
        self.accepted_version = null;
        self.accepted_text = null;
        self.sync_inflight = false;
        if (self.workspace_state) |state| state.reset(self.epoch);
    }
    pub fn stop(self: *Client) !void {
        try self.enter();
        defer self.busy = false;
        if (self.phase == .stopped) return;
        if (!self.broker.stopping) try self.broker.invalidateAll();
        if (self.shutdown_control.active()) self.shutdown_control.cancelled.store(true, .release);
        self.phase = .stopped;
        for (self.slots) |*value| if (value.serial != 0) value.cancellation.request();
        for (&self.sync_controls) |*control| if (control.live) control.cancellation.request();
        self.accepted_version = null;
        self.accepted_text = null;
        self.sync_inflight = false;
        if (self.workspace_state) |state| state.reset(0);
    }
    pub fn captureSync(self: *Client, version: i32) !SyncWork {
        try self.enter();
        defer self.busy = false;
        try self.ready();
        if (!self.caps.open_close or self.caps.sync == .none) return error.UnsupportedSynchronization;
        if (version < 0 or (self.accepted_version != null and version <= self.accepted_version.?)) return error.StaleVersion;
        if (self.sync_inflight) return error.SyncPending;
        if (self.live_syncs == self.limits.syncs) return error.Full;
        const snapshot = try self.broker.document.snapshot();
        errdefer snapshot.close() catch unreachable;
        const reader = try snapshot.borrowReader();
        errdefer reader.release() catch unreachable;
        const revision = try reader.version();
        const text = try reader.committedTextVersion();
        if (revision != try self.broker.document.version()) return error.StaleRevision;
        const sync_index = for (self.sync_controls[0..self.limits.syncs], 0..) |control, i| {
            if (!control.live) break i;
        } else unreachable;
        self.sync_controls[sync_index].live = true;
        self.sync_controls[sync_index].cancellation.requested.store(false, .release);
        self.sync_inflight = true;
        self.live_syncs += 1;
        return .{ .client = self, .epoch = self.epoch, .version = version, .reader = reader, .snapshot = snapshot, .revision = revision, .text_version = text, .workspace_version = self.workspaceVersion(), .configuration_version = self.configurationVersion(), .sync_kind = self.caps.sync, .opening = self.accepted_version == null, .base_version = self.accepted_version, .base_text = self.accepted_text, .control_index = @intCast(sync_index) };
    }
    pub fn begin(self: *Client, kind: code.Kind, position: usize, fallback: d.Range) !Work {
        try self.enter();
        defer self.busy = false;
        try self.ready();
        if (kind == .diagnostics) return error.NotificationOnly;
        if (self.workspace_state) |state| if (state.configuration) |config| {
            if (config.synchronized != config.accepted) return error.ConfigurationSynchronizationRequired;
        };
        if ((kind == .completion and !self.caps.completion) or (kind == .hover and !self.caps.hover)) return error.UnsupportedMethod;
        const text = try self.broker.document.committedTextVersion();
        if (self.accepted_text == null or self.accepted_text.? != text or self.sync_inflight) return error.SynchronizationRequired;
        const index = for (self.slots, 0..) |value, at| {
            if (value.serial == 0) break at;
        } else return error.Full;
        if (self.serial == std.math.maxInt(u64)) return error.IdExhausted;
        // Check ID availability before begin; no abandoned Broker Job on failure.
        if (self.next_id == std.math.maxInt(i32)) return error.IdExhausted;
        if (fallback.start > fallback.end or (kind == .completion and (position < fallback.start or position > fallback.end))) return error.InvalidRange;
        _ = try self.broker.document.utf16Offset(fallback.start);
        _ = try self.broker.document.utf16Offset(fallback.end);
        const job = try self.broker.begin(kind, position);
        errdefer {
            job.release() catch unreachable;
            _ = self.broker.finish(job.ticket) catch unreachable;
        }
        _ = try job.reader.utf16Offset(fallback.start);
        _ = try job.reader.utf16Offset(fallback.end);
        if (fallback.start > fallback.end) return error.InvalidRange;
        if (job.ticket.text_version != self.accepted_text.?) return error.SynchronizationRequired;
        const identifier = try self.id();
        self.serial += 1;
        const value = &self.slots[index];
        value.serial = self.serial;
        value.id = identifier;
        value.epoch = self.epoch;
        value.ticket = job.ticket;
        value.role = .request;
        value.workspace_version = self.workspaceVersion();
        value.configuration_version = self.configurationVersion();
        value.cancellation.requested.store(false, .monotonic);
        value.stage.store(1, .release);
        self.live_requests += 1;
        // Negotiated capabilities are owner state and can change on restart
        // while this worker is still parsing. Capture the immutable policy now.
        const continuation: ?convert.Origin = if (kind == .completion and self.caps.completion_resolve and self.resolve_options != null) .{ .source = self.resolve_options.?.source, .generation = self.epoch } else null;
        return .{ .token = .{ .client = self, .epoch = self.epoch, .index = @intCast(index), .serial = self.serial, .id = identifier }, .job = job, .fallback = fallback, .continuation = continuation };
    }
    fn freshRequest(self: *Client, value: *const Slot) !bool {
        if (value.workspace_version != self.workspaceVersion()) return false;
        if (value.configuration_version != self.configurationVersion()) return false;
        return if (value.ticket.kind == .completion) value.ticket.revision == try self.broker.document.version() else value.ticket.text_version == try self.broker.document.committedTextVersion();
    }
    /// Check immediately before handing a prepared packet to the host's send
    /// queue. A rejected/Full queue keeps Work, packet and this request intact.
    pub fn validateSend(self: *Client, token: Request) !void {
        try self.check();
        try self.ready();
        const value = try self.slot(token);
        if (token.epoch != self.epoch) return error.StaleEpoch;
        if (value.stage.load(.acquire) != 2) return error.InvalidPhase;
        if (value.cancellation.requested.load(.acquire)) return error.Cancelled;
        if (self.sync_inflight or self.accepted_text != value.ticket.text_version or !try self.freshRequest(value)) return error.StaleRevision;
    }
    /// Host already accepted the packet: always record this responsibility,
    /// even if its acceptance callback edited/stopped/restarted the document.
    pub fn commitSend(self: *Client, token: Request) !Commit {
        try self.enter();
        defer self.busy = false;
        const value = try self.slot(token);
        if (value.stage.load(.acquire) != 2) return error.InvalidPhase;
        value.stage.store(3, .release);
        const stale = self.phase != .ready or token.epoch != self.epoch or !try self.freshRequest(value) or self.accepted_text != value.ticket.text_version;
        var cancellation_error: ?anyerror = null;
        if (stale) {
            value.cancellation.request();
            _ = if (value.role == .request) self.broker.cancel(value.ticket) catch |err| blk: {
                cancellation_error = err;
                break :blk false;
            } else false;
        }
        return .{ .stale = stale, .cancellation_error = cancellation_error };
    }
    pub fn cancel(self: *Client, token: Request) !void {
        try self.enter();
        defer self.busy = false;
        const value = try self.slot(token);
        if (value.role == .request) _ = try self.broker.cancel(value.ticket);
        value.cancellation.request();
    }
    pub fn close(self: *Client) !void {
        try self.check();
        if (self.shutdown_control.active()) return error.ShutdownAlive;
        if (self.live_requests != 0) return error.RequestsAlive;
        if (self.live_syncs != 0) return error.ReadersAlive;
        if (self.diagnostic_leases.load(.acquire) != 0) return error.DeliveriesAlive;
        if (self.transports.load(.acquire) != 0) return error.TransportsAlive;
        if (self.workspace_state) |state| {
            if (state.live_products != 0 or state.incoming.load(.acquire) != 0) return error.WorkspacesAlive;
        }
        if (self.phase != .stopped) try self.stop();
        const borrow = try self.broker.borrowForTeardown();
        defer borrow.end();
        self.busy = true;
        borrow.releaseClient() catch unreachable;
        const allocator = self.allocator;
        if (self.workspace_state) |state| {
            self.workspace_state = null;
            if (state.configuration) |config| {
                config.current.release();
                allocator.destroy(config);
            }
            state.current.release();
            allocator.destroy(state);
        }
        allocator.free(self.uri);
        allocator.free(self.language);
        allocator.free(self.slots);
        allocator.destroy(self);
    }
};
pub const ControlMessage = union(enum) { initialize: Handshake, initialized: Handshake, cancellation: Request };
pub const ControlSend = struct {
    client: *Client,
    message: ControlMessage,
    live: bool = true,

    /// Commit only the host's accepted FIFO responsibility, before handing the
    /// product back to a worker. A pure encoder is not this authorization.
    pub fn commit(self: *ControlSend) !void {
        if (self.client.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.ScopeClosed;
        switch (self.message) {
            .initialize => self.client.phase = .awaiting_initialize,
            .initialized => self.client.publishReady(),
            .cancellation => {},
        }
        self.end();
    }
    pub fn end(self: *ControlSend) void {
        std.debug.assert(self.client.owner == std.Thread.getCurrentId());
        if (!self.live) return;
        self.live = false;
        self.client.busy = false;
    }
};

pub const ShutdownKind = enum { request, exit };
pub const ShutdownStatus = struct { stage: shutdown.Stage, deadline_expired: bool };
pub const ShutdownAdopt = struct { acknowledged: bool = false, rejected: ?anyerror = null, remote_code: ?i32 = null };

/// One linear physical control product. The host moves it exclusively between
/// owner and explicit worker; stop/restart only touch its atomic control.
/// Client/Broker outlive it, its queued Reply and every external Packet owner.
pub const ShutdownWork = struct {
    client: *Client,
    epoch: u64,
    serial: u64,
    id: i32,
    options: ShutdownOptions,
    packet: ?codec.Packet = null,
    work_spent: usize = 0,

    fn control(self: *const ShutdownWork) *shutdown.Control {
        return &self.client.shutdown_control;
    }
    fn cancellation(self: *const ShutdownWork) !void {
        _ = try self.control().check(self.serial);
        if (self.control().cancelled.load(.acquire)) return error.Cancelled;
    }
    fn chargeWork(self: *ShutdownWork, amount: usize) !void {
        if (amount > self.options.limits.work_bytes - self.work_spent) return error.ShutdownWorkExceeded;
        self.work_spent += amount;
    }
    fn dropPacket(self: *ShutdownWork) void {
        if (self.packet) |packet| {
            self.packet = null;
            var owned = packet;
            owned.deinit();
        }
    }
    pub fn status(self: *const ShutdownWork, now_ns: u64) !ShutdownStatus {
        try self.client.check();
        const stage = try self.control().check(self.serial);
        return .{ .stage = stage, .deadline_expired = stage != .exit_accepted and now_ns >= self.options.deadline_ns };
    }
    /// Explicit worker encoding; no clock, IO, Reader or Document scan.
    pub fn prepare(self: *ShutdownWork, allocator: std.mem.Allocator) !void {
        const slot_value = self.control();
        try slot_value.claim(self.serial, .captured, .preparing);
        var success = false;
        defer if (!success) slot_value.publish(self.serial, .captured);
        try self.cancellation();
        try self.chargeWork(512);
        var packet = wire.shutdownRequest(allocator, self.id, self.options.limits.encoding()) catch |err| {
            try self.cancellation(); // All encoder failure cleanup has returned.
            return err;
        };
        errdefer packet.deinit();
        try self.cancellation();
        self.packet = packet;
        success = true;
        slot_value.publish(self.serial, .prepared);
    }
    /// Short owner queue-decision scope. Full/Closed does not consume Packet,
    /// revoke displays or withdraw readiness. Accepted commit is irreversible.
    pub fn beginSend(self: *ShutdownWork, kind: ShutdownKind, now_ns: u64) !ShutdownSend {
        const client = self.client;
        try client.enter();
        errdefer client.busy = false;
        const slot_value = self.control();
        _ = try slot_value.check(self.serial);
        if (self.epoch != client.epoch) return error.StaleEpoch;
        try self.cancellation();
        if (now_ns >= self.options.deadline_ns) return error.ShutdownDeadlineExpired;
        switch (kind) {
            .request => if (client.phase != .ready) return if (client.phase == .stopped) error.Closed else error.InvalidPhase,
            .exit => if (client.phase != .shutdown_replied) return if (client.phase == .stopped) error.Closed else error.InvalidPhase,
        }
        var reservation: ?code.Broker.Invalidation = null;
        errdefer if (reservation) |*value| value.end();
        if (kind == .request and !client.broker.stopping) reservation = try client.broker.beginInvalidation();
        const previous: shutdown.Stage = if (kind == .request) .prepared else .exit_prepared;
        try slot_value.claim(self.serial, previous, .sending);
        // Only the successful CAS authorizes reading worker-owned fields.
        if (self.packet == null) {
            slot_value.publish(self.serial, previous);
            return error.PacketMoved;
        }
        return .{ .work = self, .kind = kind, .previous = previous, .reservation = reservation };
    }
    /// Explicit worker: reject another response without consuming this Work.
    /// JSON and Packet cleanup finish before release-publishing one Reply.
    pub fn receive(self: *ShutdownWork, transport: *const Transport, allocator: std.mem.Allocator, body: []const u8) !ShutdownReply {
        try transport.check(self.epoch);
        if (transport.client != self.client) return error.ForeignTransport;
        const slot_value = self.control();
        try slot_value.claim(self.serial, .sent, .receiving);
        var success = false;
        defer if (!success) slot_value.publish(self.serial, .sent);
        try self.cancellation();
        if (body.len > self.options.limits.body_bytes) return error.BodyCapacityExceeded;
        try self.chargeWork(128);
        if (body.len > (self.options.limits.work_bytes - self.work_spent) / 3) return error.ShutdownWorkExceeded;
        try self.chargeWork(body.len * 3);
        const remote = shutdownResponse(allocator, body, self.options.limits.framing(), self.id) catch |err| {
            try self.cancellation(); // Includes the final Message allocator free.
            return err;
        };
        self.dropPacket();
        try self.cancellation();
        success = true;
        slot_value.publish(self.serial, .reply_pending);
        return .{ .client = self.client, .epoch = self.epoch, .serial = self.serial, .remote_code = remote, .responded = true };
    }
    /// Local IO/worker failure still produces one owner-finished obligation.
    /// It never authorizes exit without an actual valid shutdown response.
    pub fn abort(self: *ShutdownWork, failure: anyerror) !ShutdownReply {
        const slot_value = self.control();
        const previous = try slot_value.check(self.serial);
        switch (previous) {
            .captured, .prepared, .sent => {},
            .preparing, .receiving, .preparing_exit, .closing, .reply_finishing, .sending => return error.Busy,
            else => return error.InvalidPhase,
        }
        try slot_value.claim(self.serial, previous, .receiving);
        self.dropPacket();
        slot_value.publish(self.serial, .reply_pending);
        return .{ .client = self.client, .epoch = self.epoch, .serial = self.serial, .failure = failure };
    }
    pub fn prepareExit(self: *ShutdownWork, allocator: std.mem.Allocator) !void {
        const slot_value = self.control();
        try slot_value.claim(self.serial, .replied, .preparing_exit);
        var success = false;
        defer if (!success) slot_value.publish(self.serial, .replied);
        try self.cancellation();
        try self.chargeWork(512);
        var packet = wire.exitNotification(allocator, self.options.limits.encoding()) catch |err| {
            try self.cancellation();
            return err;
        };
        errdefer packet.deinit();
        try self.cancellation();
        self.packet = packet;
        success = true;
        slot_value.publish(self.serial, .exit_prepared);
    }
    /// Nonblocking local seal only. Host terminates IO/processes on its worker.
    pub fn forceStop(self: *const ShutdownWork) !void {
        try self.client.check();
        _ = try self.control().check(self.serial);
        if (self.epoch != self.client.epoch) return error.StaleEpoch;
        try self.client.stop();
    }
    /// Explicit host monotonic deadline; creates no timer or polling source.
    pub fn expire(self: *const ShutdownWork, now_ns: u64) !bool {
        const value = try self.status(now_ns);
        if (!value.deadline_expired) return false;
        try self.forceStop();
        return true;
    }
    /// Owner-only after exclusive worker use/queued Reply retirement. A failed
    /// close retains the complete physical responsibility and is retryable.
    pub fn close(self: *ShutdownWork) !void {
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        const slot_value = self.control();
        const previous = try slot_value.check(self.serial);
        switch (previous) {
            .preparing, .receiving, .preparing_exit, .closing, .reply_finishing, .sending => return error.WorkerRunning,
            .reply_pending => return error.ShutdownReplyPending,
            else => {},
        }
        if (self.epoch == client.epoch and (client.phase == .awaiting_shutdown or client.phase == .shutdown_replied)) return error.ShutdownInProgress;
        try slot_value.claim(self.serial, previous, .closing);
        self.dropPacket();
        client.reservation -= slot_value.reservation_bytes;
        slot_value.reservation_bytes = 0;
        // No foreign work or Work field access after this physical release.
        slot_value.publish(self.serial, .idle);
    }
};

pub const ShutdownSend = struct {
    work: *ShutdownWork,
    kind: ShutdownKind,
    previous: shutdown.Stage,
    reservation: ?code.Broker.Invalidation,
    live: bool = true,

    pub fn takePacket(self: *ShutdownSend) !codec.Packet {
        if (self.work.client.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.ScopeClosed;
        const packet = self.work.packet orelse return error.PacketMoved;
        self.work.packet = null;
        return packet;
    }
    /// Already accepted: neither later cancellation nor deadline may deny the
    /// FIFO responsibility. Gate cleanup follows the last foreign destructor.
    pub fn commit(self: *ShutdownSend) !void {
        if (self.work.client.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.ScopeClosed;
        self.live = false;
        const client = self.work.client;
        defer {
            if (self.reservation) |*value| value.end();
            client.busy = false;
        }
        switch (self.kind) {
            .request => {
                client.phase = .awaiting_shutdown;
                for (client.slots) |*value| if (value.serial != 0) value.cancellation.request();
                for (&client.sync_controls) |*value| if (value.live) value.cancellation.request();
                if (client.workspace_state) |state| for (&state.controls) |*value| if (value.live) value.cancellation.request();
                if (self.reservation) |*value| value.commitRetained() catch unreachable;
                self.work.control().publish(self.work.serial, .sent);
            },
            .exit => {
                client.phase = .stopped;
                client.accepted_version = null;
                client.accepted_text = null;
                client.sync_inflight = false;
                if (client.workspace_state) |state| state.reset(0);
                self.work.control().publish(self.work.serial, .exit_accepted);
            },
        }
    }
    pub fn end(self: *ShutdownSend) void {
        std.debug.assert(self.work.client.owner == std.Thread.getCurrentId());
        if (!self.live) return;
        self.live = false;
        self.work.control().publish(self.work.serial, self.previous);
        if (self.reservation) |*value| value.end();
        self.work.client.busy = false;
    }
};

/// Independent fixed metadata; a pending Reply pins the same control slot.
/// Full/Closed App.post does not consume it; successful posts execute it once.
pub const ShutdownReply = struct {
    client: *Client,
    epoch: u64,
    serial: u64,
    remote_code: ?i32 = null,
    failure: ?anyerror = null,
    responded: bool = false,
    live: bool = true,

    pub fn finish(self: *ShutdownReply) !ShutdownAdopt {
        if (!self.live) return error.DeliveryClosed;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        const slot_value = &client.shutdown_control;
        try slot_value.claim(self.serial, .reply_pending, .reply_finishing);
        var result: ShutdownAdopt = .{ .rejected = self.failure, .remote_code = self.remote_code };
        if (self.epoch != client.epoch) {
            result.rejected = error.StaleEpoch;
        } else if (client.phase == .stopped) {
            result.rejected = error.Closed;
        } else if (slot_value.cancelled.load(.acquire)) {
            result.rejected = error.Cancelled;
        } else if (self.responded and client.phase == .awaiting_shutdown) {
            result.acknowledged = true;
            client.phase = .shutdown_replied;
        } else if (result.rejected == null) result.rejected = error.InvalidPhase;
        self.live = false;
        slot_value.publish(self.serial, if (result.acknowledged) .replied else .failed);
        return result;
    }
};
fn shutdownResponse(allocator: std.mem.Allocator, body: []const u8, limits: codec.Limits, id: i32) !?i32 {
    const message = try codec.Message.parse(allocator, body, limits);
    defer message.close() catch unreachable;
    return switch (try message.value()) {
        .response => |response| blk: {
            if (response.id != .number or response.id.number != id) return error.UnexpectedResponse;
            if (response.result != .null) return error.InvalidShutdownResult;
            break :blk null;
        },
        .failure => |failure| blk: {
            if (failure.id != .number or failure.id.number != id) return error.UnexpectedResponse;
            break :blk failure.code;
        },
        else => error.UnexpectedResponse,
    };
}

// Monotone deduction before multiplication: total always remains <= the
// validated <=1GiB limit, so no intermediate needs a wider usize, even on 32bit.
fn charge(total: *usize, count: usize, bytes: usize, limit: usize) !void {
    if (count != 0 and bytes > (limit - total.*) / count) return error.CapacityExceeded;
    total.* += count * bytes;
}
fn resultLimits(left: code.ResultLimits, right: code.ResultLimits) code.ResultLimits {
    var result: code.ResultLimits = undefined;
    inline for (std.meta.fields(code.ResultLimits)) |field| @field(result, field.name) = @min(@field(left, field.name), @field(right, field.name));
    return result;
}
fn validString(text: []const u8, max: usize) !void {
    if (text.len == 0 or text.len > max or std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.InvalidString;
}

/// Exclusive, linear, host-owned transport token. It does not itself perform IO.
pub const Transport = struct {
    client: *Client,
    epoch: u64,
    live: bool = true,
    busy: bool = false,
    pub fn close(self: *Transport) !void {
        if (!self.live) return error.TransportClosed;
        if (self.busy) return error.Busy;
        self.live = false;
        _ = self.client.transports.fetchSub(1, .release); // last shared access
    }
    fn check(self: *const Transport, epoch: u64) !void {
        if (!self.live) return error.TransportClosed;
        if (self.epoch != epoch) return error.ForeignTransport;
    }
    pub fn initialize(self: *Transport, allocator: std.mem.Allocator, token: Handshake, options: wire.Initialize) !codec.Packet {
        try self.check(token.epoch);
        if (token.client != self.client) return error.ForeignTransport;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        if (options.snippets != self.client.limits.conversion.snippets) return error.ConflictingCapabilities;
        if (self.client.workspace_state != null or options.workspace_support or options.workspace_folders != null or options.configuration_support) return error.WorkspaceRequired;
        if (options.completion_resolve) return error.ConflictingCapabilities;
        var selected = options;
        selected.completion_resolve = self.client.resolve_options != null;
        return wire.initialize(allocator, token.id, selected, self.client.limits.framing);
    }
    pub fn negotiate(self: *Transport, allocator: std.mem.Allocator, token: Handshake, body: []const u8) !Negotiated {
        try self.check(token.epoch);
        if (token.client != self.client) return error.ForeignTransport;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        const message = try codec.Message.parse(allocator, body, self.client.limits.framing);
        defer message.close() catch unreachable;
        const envelope = try message.value();
        if (envelope != .response or envelope.response.id != .number or envelope.response.id.number != token.id) return error.UnexpectedResponse;
        return .{ .token = token, .capabilities = try wire.capabilities(envelope.response.result) };
    }
    pub fn initialized(self: *Transport, allocator: std.mem.Allocator) !codec.Packet {
        if (!self.live) return error.TransportClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        return wire.notification(allocator, "initialized", struct {}{}, self.client.limits.framing);
    }
    pub fn cancellation(self: *Transport, allocator: std.mem.Allocator, token: Request) !codec.Packet {
        try self.check(token.epoch);
        if (token.client != self.client) return error.ForeignTransport;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        return wire.cancel(allocator, token.id, self.client.limits.framing);
    }
    /// Parse on the explicit transport worker. The Message is destroyed here;
    /// only bounded by-value request metadata crosses to the owner thread.
    pub fn workspaceRequest(self: *Transport, allocator: std.mem.Allocator, body: []const u8) !WorkspaceIncoming {
        if (!self.live) return error.TransportClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        const state = self.client.workspace_state orelse return error.WorkspaceRequired;
        if (state.incoming_epoch.load(.acquire) != self.epoch) return error.StaleEpoch;
        var count = state.incoming.load(.acquire);
        while (true) {
            if (count >= state.limits.incoming) return error.Full;
            count = state.incoming.cmpxchgWeak(count, count + 1, .acq_rel, .acquire) orelse break;
        }
        errdefer _ = state.incoming.fetchSub(1, .release);
        const message = try codec.Message.parse(allocator, body, self.client.limits.framing);
        var message_live = true;
        defer if (message_live) message.close() catch unreachable;
        const envelope = try message.value();
        if (envelope != .request or envelope.request.id == .none) return error.UnexpectedRequest;
        var result: WorkspaceIncoming = .{ .client = self.client, .epoch = self.epoch };
        switch (envelope.request.id) {
            .number => |number| result.number = number,
            .text => |string| {
                if (string.len > result.identifier.len) return error.IdentifierCapacityExceeded;
                @memcpy(result.identifier[0..string.len], string);
                result.identifier_len = @intCast(string.len);
            },
            .none => unreachable,
        }
        const request = envelope.request;
        errdefer if (result.query) |query| query.close();
        if (std.mem.eql(u8, request.method, "workspace/workspaceFolders")) {
            result.kind = .folders;
            if (request.params) |params| {
                if (params != .null) result.kind = .invalid;
            }
        } else if (std.mem.eql(u8, request.method, "workspace/configuration") and state.configuration != null) {
            result.query = configuration.Query.create(allocator, request.params, state.configuration.?.limits) catch |err| switch (err) {
                error.InvalidParams, error.InvalidConfigurationKey, error.ConfigurationCapacityExceeded => null,
                else => return err,
            };
            result.kind = if (result.query != null) .configuration else .invalid;
        } else if (std.mem.eql(u8, request.method, "client/unregisterCapability")) {
            result.kind = .invalid;
            if (request.params) |params| if (params == .object) {
                // The spelling is the protocol's established wire field.
                if (params.object.get("unregisterations")) |entries| if (entries == .array and entries.array.items.len == 1) {
                    const entry = entries.array.items[0];
                    if (entry == .object) {
                        const id = entry.object.get("id");
                        const method = entry.object.get("method");
                        if (id != null and id.? == .string and id.?.string.len > 0 and id.?.string.len <= 128 and method != null and method.? == .string and std.mem.eql(u8, method.?.string, "workspace/didChangeWorkspaceFolders")) {
                            result.kind = .unregister;
                            @memcpy(result.registration.bytes[0..id.?.string.len], id.?.string);
                            result.registration.len = @intCast(id.?.string.len);
                        }
                    }
                };
            };
        }
        try message.close();
        message_live = false;
        if (state.incoming_epoch.load(.acquire) != self.epoch) return error.StaleEpoch;
        return result;
    }
};

/// Exclusive worker product. Reader belongs to Job, Map borrows that Reader.
/// No copying, concurrent access, or use after finish/abort. Host sends Packet,
/// commits on owner, then explicitly moves this same Work back to its worker.
pub const Work = struct {
    token: Request,
    job: code.Job,
    fallback: d.Range,
    continuation: ?convert.Origin = null,
    map: ?*positions.Map = null,
    packet: ?codec.Packet = null,
    live: bool = true,
    busy: bool = false,
    fn slot(self: *const Work) *Slot {
        return &self.token.client.slots[self.token.index];
    }
    pub fn isCancelled(self: *const Work) !bool {
        if (!self.live) return error.WorkClosed;
        return self.slot().cancellation.requested.load(.acquire) or try self.job.isCancelled();
    }
    pub fn prepare(self: *Work, allocator: std.mem.Allocator) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        if (self.map != null or self.packet != null) return error.AlreadyPrepared;
        if (try self.isCancelled()) return error.Cancelled;
        const client = self.token.client;
        var map_limits = client.limits.map;
        map_limits.cancellation = &self.slot().cancellation;
        const map = try positions.Map.create(allocator, self.job.reader, map_limits);
        errdefer map.close() catch unreachable;
        const position = try map.toPosition(self.job.position);
        const packet = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = self.token.id, .method = if (self.job.ticket.kind == .completion) "textDocument/completion" else "textDocument/hover", .params = .{ .textDocument = .{ .uri = client.uri }, .position = position } }, client.limits.framing);
        errdefer {
            var owned = packet;
            owned.deinit();
        }
        if (try self.isCancelled()) return error.Cancelled;
        self.map = map;
        self.packet = packet;
        self.slot().stage.store(2, .release);
    }
    /// Move only after the host accepts queue ownership. Full leaves this
    /// packet in Work. Its new owner frees it after its IO responsibility ends.
    pub fn takePacket(self: *Work) !codec.Packet {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        const packet = self.packet orelse return error.PacketMoved;
        self.packet = null;
        return packet;
    }
    pub fn receive(self: *Work, transport: *const Transport, allocator: std.mem.Allocator, body: []const u8) !Delivery {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        try transport.check(self.token.epoch);
        if (transport.client != self.token.client) return error.ForeignTransport;
        if (self.slot().stage.load(.acquire) != 3) return error.NotSent;
        const preserve = self.continuation != null;
        const message = if (preserve) try codec.Message.parseLossless(allocator, body, self.token.client.limits.framing) else try codec.Message.parse(allocator, body, self.token.client.limits.framing);
        defer message.close() catch unreachable;
        const envelope = try message.value();
        const identifier = switch (envelope) {
            .response => |response| response.id,
            .failure => |failure| failure.id,
            else => return error.UnexpectedResponse,
        };
        if (identifier != .number or identifier.number != self.token.id) return error.UnexpectedResponse;
        if (try self.isCancelled()) return self.complete(null, error.Cancelled, null, false);
        if (envelope == .failure) return self.complete(null, error.RemoteFailure, envelope.failure.code, false);
        var owned: code.OwnedResult = undefined;
        var incomplete = false;
        switch (self.job.ticket.kind) {
            .completion => {
                var limits = self.token.client.limits.conversion;
                limits.result = resultLimits(limits.result, self.job.limits);
                limits.request_position = self.job.position;
                limits.continuation = self.continuation;
                const converted = try convert.completion(allocator, envelope.response.result, self.job.reader, self.map.?, self.fallback, limits);
                owned = converted.owned;
                incomplete = converted.is_incomplete;
            },
            .hover => {
                var limits = self.token.client.limits.conversion;
                limits.result = resultLimits(limits.result, self.job.limits);
                owned = try convert.hover(allocator, envelope.response.result, self.job.reader, self.map.?, self.fallback, limits);
            },
            .diagnostics => unreachable,
        }
        return self.complete(owned, null, null, incomplete);
    }
    fn complete(self: *Work, owned: ?code.OwnedResult, failure: ?anyerror, remote: ?i32, incomplete: bool) Delivery {
        const token = self.token;
        if (self.map) |map| {
            self.map = null;
            map.close() catch unreachable;
        }
        if (self.packet) |*packet| {
            packet.deinit();
            self.packet = null;
        }
        self.live = false;
        self.job.release() catch unreachable;
        self.slot().stage.store(4, .release);
        return .{ .token = token, .owned = owned, .failure = failure, .remote_code = remote, .incomplete = incomplete };
    }
    /// After IO error, local cancellation, or failed queue + worker join.
    /// The returned Delivery STILL needs exactly one owner-thread finish.
    pub fn abort(self: *Work, failure: anyerror) !Delivery {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        return self.complete(null, failure, null, false);
    }
};
pub const Delivery = struct {
    token: Request,
    owned: ?code.OwnedResult,
    failure: ?anyerror,
    remote_code: ?i32,
    incomplete: bool,
    live: bool = true,
    /// Consumes this physical responsibility even when publication is stale.
    /// App.post Full/Closed does not call this: host retains it until owner use.
    pub fn finish(self: *Delivery) !Adopt {
        if (!self.live) return error.DeliveryClosed;
        const client = self.token.client;
        try client.enter();
        defer client.busy = false;
        const value = try client.slot(self.token);
        if (value.stage.load(.acquire) != 4) return error.WorkerRunning;
        var outcome: Adopt = .{ .rejected = self.failure, .remote_code = self.remote_code, .incomplete = self.incomplete };
        if (self.failure == null) {
            if (client.phase != .ready or self.token.epoch != client.epoch) {
                outcome.rejected = error.StaleEpoch;
            } else if (value.workspace_version != client.workspaceVersion()) {
                outcome.rejected = error.StaleWorkspace;
            } else if (value.configuration_version != client.configurationVersion()) {
                outcome.rejected = error.StaleConfiguration;
            } else if (self.owned) |*owned| {
                if (client.broker.publish(value.ticket, owned)) |_| outcome.published = true else |err| outcome.rejected = err;
            }
        }
        if (self.owned) |*owned| {
            owned.deinit();
            self.owned = null;
        }
        _ = try client.broker.finish(value.ticket);
        value.serial = 0;
        value.stage.store(0, .release);
        client.live_requests -= 1;
        self.live = false;
        return outcome;
    }
};

/// Linear independent continuation, explicitly moved to a host worker. It has
/// no Broker Job/Reader and cannot remove or accept the source completion.
pub const ResolveWork = struct {
    token: Request,
    choice: code.CompletionChoice,
    input: code.OwnedResult,
    limits: resolving.Limits,
    result_limits: code.ResultLimits,
    packet: ?codec.Packet = null,
    live: bool = true,
    busy: bool = false,
    fn slot(self: *const ResolveWork) *Slot {
        return &self.token.client.slots[self.token.index];
    }
    fn checkCancellation(self: *const ResolveWork) !void {
        if (self.slot().cancellation.requested.load(.acquire)) return error.Cancelled;
    }
    pub fn prepare(self: *ResolveWork) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        if (self.packet != null or self.slot().stage.load(.acquire) != 1) return error.InvalidPhase;
        try self.checkCancellation();
        const payload = self.input.data.completion[self.choice.index].continuation.?.payload;
        var packet = try codec.Packet.json(self.input.allocator, .{ .jsonrpc = "2.0", .id = self.token.id, .method = "completionItem/resolve", .params = configuration.Raw{ .bytes = payload } }, self.token.client.limits.framing);
        errdefer packet.deinit();
        try self.checkCancellation();
        self.packet = packet;
        self.slot().stage.store(2, .release);
    }
    pub fn takePacket(self: *ResolveWork) !codec.Packet {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        const packet = self.packet orelse return error.PacketMoved;
        self.packet = null;
        return packet;
    }
    pub fn receive(self: *ResolveWork, transport: *const Transport, body: []const u8) !ResolveDelivery {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        try transport.check(self.token.epoch);
        if (transport.client != self.token.client) return error.ForeignTransport;
        if (self.slot().stage.load(.acquire) != 3) return error.NotSent;
        try self.checkCancellation();
        const message = try codec.Message.parseLossless(self.input.allocator, body, self.token.client.limits.framing);
        var message_live = true;
        defer if (message_live) message.close() catch unreachable;
        const envelope = try message.value();
        const identifier = switch (envelope) {
            .response => envelope.response.id,
            .failure => envelope.failure.id,
            else => return error.UnexpectedResponse,
        };
        if (identifier != .number or identifier.number != self.token.id) return error.UnexpectedResponse;
        if (envelope == .failure) {
            const remote = envelope.failure.code;
            try message.close();
            message_live = false;
            try self.checkCancellation();
            return self.complete(null, error.RemoteFailure, remote);
        }
        var work: resolving.Work = .{ .remaining = self.limits.work_bytes, .cancellation = &self.slot().cancellation };
        var owned = try resolving.candidate(self.input.allocator, &self.input, self.choice.index, envelope.response.result, self.token.client.limits.framing, self.limits, self.result_limits, &work);
        errdefer owned.deinit();
        try message.close();
        message_live = false;
        try self.checkCancellation();
        return self.complete(owned, null, null);
    }
    fn complete(self: *ResolveWork, owned: ?code.OwnedResult, failure: ?anyerror, remote: ?i32) ResolveDelivery {
        self.input.deinit();
        if (self.packet) |*packet| packet.deinit();
        self.packet = null;
        self.live = false;
        self.slot().stage.store(4, .release);
        return .{ .token = self.token, .choice = self.choice, .owned = owned, .failure = failure, .remote_code = remote };
    }
    pub fn abort(self: *ResolveWork, failure: anyerror) !ResolveDelivery {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        return self.complete(null, failure, null);
    }
};
pub const ResolveAdopt = struct { published: bool = false, stale_after_commit: bool = false, rejected: ?anyerror = null, remote_code: ?i32 = null };
pub const ResolveDelivery = struct {
    token: Request,
    choice: code.CompletionChoice,
    owned: ?code.OwnedResult,
    failure: ?anyerror,
    remote_code: ?i32,
    live: bool = true,
    /// A current Presenter is borrowed only in this owner call. Pass null after
    /// its host entry was withdrawn: no asynchronous Presenter pointer exists.
    /// Full/Closed App.post keeps this delivery's entire physical responsibility.
    pub fn finish(self: *ResolveDelivery, presenter: ?*code.Presenter) !ResolveAdopt {
        if (!self.live) return error.DeliveryClosed;
        var refinement: ?code.CompletionRefinement = null;
        defer if (refinement) |*scope| scope.end();
        const client = self.token.client;
        try client.enter();
        defer client.busy = false;
        const value = try client.slot(self.token);
        if (value.stage.load(.acquire) != 4 or value.role != .resolve) return error.WorkerRunning;
        var outcome: ResolveAdopt = .{ .rejected = self.failure, .remote_code = self.remote_code };
        if (self.failure == null) check: {
            if (client.phase != .ready or self.token.epoch != client.epoch or client.broker.stopping) {
                outcome.rejected = error.StaleEpoch;
                break :check;
            }
            if (value.workspace_version != client.workspaceVersion()) {
                outcome.rejected = error.StaleWorkspace;
                break :check;
            }
            if (value.configuration_version != client.configurationVersion()) {
                outcome.rejected = error.StaleConfiguration;
                break :check;
            }
            if (value.cancellation.requested.load(.acquire)) {
                outcome.rejected = error.Cancelled;
                break :check;
            }
            const current = presenter orelse {
                outcome.rejected = error.Closed;
                break :check;
            };
            refinement = current.beginCompletionRefinement(self.choice) catch |err| {
                if (err == error.Busy) return err; // Retain the complete delivery for an explicit retry.
                outcome.rejected = err;
                break :check;
            };
            const adopted = refinement.?.apply(&self.owned.?) catch |err| {
                outcome.rejected = err;
                break :check;
            };
            outcome.published = adopted.published;
            outcome.stale_after_commit = adopted.stale_after_commit;
        }
        if (self.owned) |*owned| owned.deinit();
        self.owned = null;
        value.serial = 0;
        value.stage.store(0, .release);
        client.live_requests -= 1;
        self.live = false;
        return outcome;
    }
};

/// Independent Snapshot/Reader for explicit worker sync and diagnostics. Keep
/// the old accepted product while preparing its successor's original ranges.
/// close is owner-only after the worker is joined; all prepared bytes are owned.
pub const SyncWork = struct {
    client: *Client,
    epoch: u64,
    version: i32,
    reader: d.Reader,
    snapshot: *d.Snapshot,
    revision: u64,
    text_version: u64,
    workspace_version: ?u64 = null,
    configuration_version: ?u64 = null,
    sync_kind: wire.SyncKind,
    opening: bool,
    base_version: ?i32,
    base_text: ?u64,
    control_index: u8,
    prepared: ?wire.PreparedSync = null,
    committed: bool = false,
    live: bool = true,
    busy: bool = false,
    closing: bool = false,
    reader_live: bool = true,
    pub fn prepare(self: *SyncWork, allocator: std.mem.Allocator, previous: ?*SyncWork, edits: []const d.Replacement) !void {
        return self.prepareSelected(allocator, previous, edits, false);
    }
    /// Explicit whole-content resynchronization, also valid for incremental
    /// servers. No owner receive/request path invokes this scanning operation.
    pub fn prepareFull(self: *SyncWork, allocator: std.mem.Allocator) !void {
        return self.prepareSelected(allocator, null, &.{}, true);
    }
    fn prepareSelected(self: *SyncWork, allocator: std.mem.Allocator, previous: ?*SyncWork, edits: []const d.Replacement, force_full: bool) !void {
        if (!self.live or self.closing) return error.WorkClosed;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        if (self.prepared != null) return error.AlreadyPrepared;
        const client = self.client;
        var sync_limits = client.limits.sync;
        sync_limits.positions.cancellation = &client.sync_controls[self.control_index].cancellation;
        var locked: ?*SyncWork = null;
        defer if (locked) |before| {
            before.busy = false;
        };
        if (!self.opening and self.sync_kind == .incremental and !force_full) {
            const before = previous orelse return error.PreviousSyncRequired;
            if (before == self or before.busy) return error.Busy;
            if (!before.live or before.closing or !before.committed or before.epoch != self.epoch or before.client != client or before.version != self.base_version or before.text_version != self.base_text) return error.StaleVersion;
            before.busy = true;
            locked = before;
        }
        self.prepared = if (self.opening) try wire.prepareOpen(allocator, self.reader, client.uri, client.language, self.version, sync_limits) else if (self.sync_kind == .full or force_full) try wire.prepareFullChange(allocator, self.reader, client.uri, self.version, sync_limits) else blk: {
            const before = previous orelse return error.PreviousSyncRequired;
            if (!before.live or before.closing or !before.committed or before.epoch != self.epoch or before.client != client or before.version != self.base_version or before.text_version != self.base_text) return error.StaleVersion;
            break :blk try wire.prepareIncremental(allocator, before.reader, before.prepared.?.map.?, self.reader, client.uri, self.version, edits, sync_limits);
        };
    }
    pub fn takePacket(self: *SyncWork) !codec.Packet {
        if (!self.live or self.closing) return error.WorkClosed;
        if (self.busy) return error.Busy;
        if (self.prepared == null) return error.NotPrepared;
        const packet = self.prepared.?.packet orelse return error.PacketMoved;
        self.prepared.?.packet = null;
        return packet;
    }
    pub fn validateSend(self: *const SyncWork) !void {
        if (!self.live or self.closing) return error.WorkClosed;
        if (self.busy) return error.Busy;
        try self.client.check();
        try self.client.ready();
        if (self.epoch != self.client.epoch) return error.StaleEpoch;
        if (self.prepared == null or self.committed) return error.InvalidPhase;
        if (self.workspace_version != self.client.workspaceVersion()) return error.StaleWorkspace;
        if (self.configuration_version != self.client.configurationVersion()) return error.StaleConfiguration;
        if (self.revision != try self.client.broker.document.version()) return error.StaleRevision;
    }
    /// Commit only after host accepts send responsibility. A raced document
    /// edit marks stale; the accepted server stamp still reflects what was sent.
    pub fn commit(self: *SyncWork) !Commit {
        if (!self.live or self.closing) return error.WorkClosed;
        if (self.busy) return error.Busy;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        if (self.prepared == null or self.committed) return error.InvalidPhase;
        self.committed = true;
        const stale = self.epoch != client.epoch or client.phase != .ready or self.workspace_version != client.workspaceVersion() or self.configuration_version != client.configurationVersion() or self.revision != try client.broker.document.version();
        if (self.epoch == client.epoch and client.phase == .ready) {
            client.accepted_version = self.version;
            client.accepted_text = self.text_version;
            client.sync_inflight = false;
            if (self.configuration_version == client.configurationVersion()) {
                if (client.workspace_state) |state| if (state.configuration) |config| {
                    config.synchronized = self.configuration_version;
                };
            }
        }
        return .{ .stale = stale };
    }
    pub fn diagnostics(self: *SyncWork, transport: *const Transport, allocator: std.mem.Allocator, body: []const u8) !DiagnosticDelivery {
        if (!self.live or self.closing) return error.WorkClosed;
        if (!self.committed) return error.InvalidPhase;
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        try transport.check(self.epoch);
        if (transport.client != self.client) return error.ForeignTransport;
        if (self.client.sync_controls[self.control_index].cancellation.requested.load(.acquire)) return error.Cancelled;
        const client = self.client;
        var count = client.diagnostic_leases.load(.acquire);
        while (true) {
            if (count >= client.limits.diagnostics) return error.Full;
            count = client.diagnostic_leases.cmpxchgWeak(count, count + 1, .acq_rel, .acquire) orelse break;
        }
        errdefer _ = client.diagnostic_leases.fetchSub(1, .release);
        const message = try codec.Message.parse(allocator, body, client.limits.framing);
        defer message.close() catch unreachable;
        const envelope = try message.value();
        if (envelope != .notification or !std.mem.eql(u8, envelope.notification.method, "textDocument/publishDiagnostics")) return error.UnexpectedNotification;
        var limits = client.limits.conversion;
        limits.result = resultLimits(limits.result, client.broker.limits.results); // immutable Broker limits
        const owned = try convert.diagnostics(allocator, envelope.notification.params orelse return error.InvalidResult, self.reader, self.prepared.?.map.?, client.uri, self.version, limits);
        return .{ .client = client, .epoch = self.epoch, .version = self.version, .text_version = self.text_version, .workspace_version = self.workspace_version, .configuration_version = self.configuration_version, .owned = owned };
    }
    pub fn close(self: *SyncWork) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        // Withdraw ingress before foreign destruction, but keep the physical
        // Snapshot/account until close succeeds. An independently borrowed
        // Reader can make Snapshot.close return ReadersAlive; retry must not
        // release our original Reader twice or return its slot prematurely.
        self.closing = true;
        if (self.prepared) |*prepared| {
            prepared.deinit();
            self.prepared = null;
        }
        if (self.reader_live) {
            try self.reader.release();
            self.reader_live = false;
        }
        try self.snapshot.close();
        self.live = false;
        if (!self.committed and self.epoch == client.epoch) client.sync_inflight = false;
        client.sync_controls[self.control_index].live = false;
        client.live_syncs -= 1;
    }
};
pub const DiagnosticDelivery = struct {
    client: *Client,
    epoch: u64,
    version: i32,
    text_version: u64,
    workspace_version: ?u64 = null,
    configuration_version: ?u64 = null,
    owned: code.OwnedResult,
    live: bool = true,
    pub fn discard(self: *DiagnosticDelivery) !void {
        if (!self.live) return error.DeliveryClosed;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        self.owned.deinit();
        self.live = false;
        _ = client.diagnostic_leases.fetchSub(1, .release);
    }
    pub fn finish(self: *DiagnosticDelivery) !Adopt {
        if (!self.live) return error.DeliveryClosed;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        var outcome: Adopt = .{};
        if (client.phase != .ready or self.epoch != client.epoch) {
            outcome.rejected = error.StaleEpoch;
        } else if (self.workspace_version != client.workspaceVersion()) {
            outcome.rejected = error.StaleWorkspace;
        } else if (self.configuration_version != client.configurationVersion()) {
            outcome.rejected = error.StaleConfiguration;
        } else if (client.accepted_version != self.version or client.accepted_text != self.text_version or try client.broker.document.committedTextVersion() != self.text_version) {
            outcome.rejected = error.StaleVersion;
        } else {
            const job = try client.broker.begin(.diagnostics, 0);
            try job.release();
            defer _ = client.broker.finish(job.ticket) catch unreachable;
            if (client.broker.publish(job.ticket, &self.owned)) |_| outcome.published = true else |err| outcome.rejected = err;
        }
        self.owned.deinit();
        self.live = false;
        _ = client.diagnostic_leases.fetchSub(1, .release);
        return outcome;
    }
};

const WorkspaceControl = struct { live: bool = false, cancellation: positions.Cancellation = .{} };
const ConfigurationState = struct {
    limits: configuration.Limits,
    current: *configuration.Snapshot,
    version: u64 = 1,
    accepted: ?u64 = null,
    synchronized: ?u64 = null,
};
const WorkspaceState = struct {
    limits: workspace.Limits,
    current: *workspace.Snapshot,
    version: u64 = 1,
    accepted: ?u64 = null,
    pending: bool = false,
    live_products: usize = 0,
    controls: [8]WorkspaceControl = @splat(.{}),
    incoming: std.atomic.Value(usize) = .init(0),
    incoming_epoch: std.atomic.Value(u64),
    configuration: ?*ConfigurationState = null,
    fn reserve(self: *WorkspaceState) !u8 {
        for (self.controls[0..self.limits.products], 0..) |*control, index| {
            if (!control.live) {
                control.live = true;
                control.cancellation.requested.store(false, .release);
                self.live_products += 1;
                return @intCast(index);
            }
        }
        return error.Full;
    }
    fn unreserve(self: *WorkspaceState, index: u8) void {
        self.controls[index].live = false;
        self.live_products -= 1;
    }
    fn reset(self: *WorkspaceState, epoch: u64) void {
        for (&self.controls) |*control| if (control.live) control.cancellation.request();
        self.incoming_epoch.store(epoch, .release);
        self.accepted = null;
        self.pending = false;
        if (self.configuration) |config| {
            config.accepted = null;
            config.synchronized = null;
        }
    }
};
fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}
fn folderEqual(a: workspace.Folder, b: workspace.Folder) bool {
    return std.mem.eql(u8, a.uri, b.uri) and std.mem.eql(u8, a.name, b.name);
}
pub const WorkspaceCommit = struct {
    accepted: bool = true,
    stale: bool,
};
/// Owner captures immutable inputs before a worker prepares bytes. The host
/// accepts send responsibility before commit; notification delivery is not a
/// server ACK. Keep the product until the worker has joined, then close owner.
pub const WorkspaceWork = struct {
    client: *Client,
    epoch: u64,
    version: u64,
    base_version: ?u64 = null,
    base: ?*workspace.Snapshot = null,
    candidate: *workspace.Snapshot,
    control: u8,
    handshake: ?Handshake = null,
    configuration_support: bool = false,
    completion_resolve: bool = false,
    packet: ?codec.Packet = null,
    prepared: bool = false,
    committed: bool = false,
    live: bool = true,
    busy: bool = false,
    fn checkCancellation(self: *const WorkspaceWork) !void {
        try workspace.cancelled(&self.client.workspace_state.?.controls[self.control].cancellation);
    }
    pub fn prepare(self: *WorkspaceWork, allocator: std.mem.Allocator, options: wire.Initialize) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        if (self.prepared) return error.AlreadyPrepared;
        self.busy = true;
        defer self.busy = false;
        try self.checkCancellation();
        var packet: codec.Packet = undefined;
        if (self.handshake) |token| {
            if (options.snippets != self.client.limits.conversion.snippets or options.root_uri != null or options.workspace_support or options.workspace_folders != null or options.configuration_support or options.completion_resolve) return error.ConflictingCapabilities;
            var selected = options;
            selected.root_uri = self.candidate.root_uri;
            selected.workspace_support = true;
            selected.workspace_folders = self.candidate.folders;
            selected.configuration_support = self.configuration_support;
            selected.completion_resolve = self.completion_resolve;
            packet = try wire.initialize(allocator, token.id, selected, self.client.limits.framing);
        } else {
            if (options.root_uri != null or options.process_id != null or options.snippets or options.workspace_support or options.workspace_folders != null or options.configuration_support or options.completion_resolve) return error.InvalidPhase;
            var added: [32]workspace.Folder = undefined;
            var removed: [32]workspace.Folder = undefined;
            var additions: usize = 0;
            var removals: usize = 0;
            var work: usize = 0;
            const old = self.base.?.folders orelse &.{};
            const new = self.candidate.folders orelse &.{};
            for (new) |folder| {
                var found = false;
                for (old) |before| {
                    try self.chargeWork(&work, folder.uri.len + folder.name.len + before.uri.len + before.name.len);
                    if (folderEqual(folder, before)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    added[additions] = folder;
                    additions += 1;
                }
            }
            for (old) |folder| {
                var found = false;
                for (new) |after| {
                    try self.chargeWork(&work, folder.uri.len + folder.name.len + after.uri.len + after.name.len);
                    if (folderEqual(folder, after)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    removed[removals] = folder;
                    removals += 1;
                }
            }
            packet = try wire.notification(allocator, "workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = added[0..additions], .removed = removed[0..removals] } }, self.client.limits.framing);
        }
        errdefer packet.deinit();
        try self.checkCancellation();
        self.packet = packet;
        self.prepared = true;
    }
    fn chargeWork(self: *const WorkspaceWork, total: *usize, amount: usize) !void {
        const limit = self.client.workspace_state.?.limits.work_bytes;
        if (amount > limit - total.*) return error.WorkspaceWorkExceeded;
        total.* += amount;
        try self.checkCancellation();
    }
    pub fn takePacket(self: *WorkspaceWork) !codec.Packet {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        const packet = self.packet orelse return error.PacketMoved;
        self.packet = null;
        return packet;
    }
    pub fn validateSend(self: *const WorkspaceWork) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        try self.client.check();
        if (self.client.broker.stopping) return error.Closed;
        if (self.epoch != self.client.epoch) return error.StaleEpoch;
        if (!self.prepared or self.committed) return error.InvalidPhase;
        try self.checkCancellation();
        if (self.handshake) |token| {
            try self.client.handshake(token);
            if (self.client.phase != .initializing) return error.InvalidPhase;
        } else {
            try self.client.ready();
            if (self.client.workspace_state.?.accepted != self.base_version or !self.client.caps.workspace_changes) return error.StaleWorkspace;
            // Pure, repeatable preflight only. beginSend subsequently retains
            // the invalidation reservation across the host decision, so an
            // accepted commit has no recoverable Busy/generation failure.
            const borrow = try self.client.broker.borrow();
            borrow.end();
        }
    }
    pub fn commit(self: *WorkspaceWork) !WorkspaceCommit {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        if (self.handshake == null) return error.SendScopeRequired;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        if (!self.prepared or self.committed) return error.InvalidPhase;
        self.committed = true;
        const state = client.workspace_state.?;
        var outcome: WorkspaceCommit = .{ .stale = self.epoch != client.epoch or client.phase == .stopped or client.broker.stopping };
        if (outcome.stale) return outcome;
        state.pending = false;
        if (self.handshake) |token| {
            if (client.phase != .initializing or token.id != client.handshake_id) {
                outcome.stale = true;
                return outcome;
            }
            client.phase = .awaiting_initialize;
        }
        return outcome;
    }
    /// Short synchronous host queue-decision scope, never an IO wait. It pins
    /// Client and reserves Broker invalidation until acceptance or cancellation.
    pub fn beginSend(self: *WorkspaceWork) !WorkspaceSend {
        try self.validateSend();
        if (self.handshake != null) return error.InvalidPhase;
        const client = self.client;
        try client.enter();
        errdefer client.busy = false;
        var reservation = try client.broker.beginInvalidation();
        errdefer reservation.end();
        // Preflight the only remaining reference-counter increment before the
        // host can accept. Cancellation returns this provisional reference.
        try self.candidate.retain();
        self.busy = true;
        return .{ .work = self, .reservation = reservation };
    }
    pub fn cancel(self: *WorkspaceWork) !void {
        if (!self.live) return error.WorkClosed;
        if (self.committed) return error.InvalidPhase;
        try self.client.check();
        self.client.workspace_state.?.controls[self.control].cancellation.request();
    }
    pub fn close(self: *WorkspaceWork) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        self.busy = true;
        self.live = false;
        if (self.packet) |*packet| packet.deinit();
        self.packet = null;
        self.candidate.release();
        if (self.base) |base| base.release();
        const state = client.workspace_state.?;
        if (!self.committed and self.epoch == client.epoch) state.pending = false;
        state.unreserve(self.control);
    }
};

pub const WorkspaceSend = struct {
    work: *WorkspaceWork,
    reservation: code.Broker.Invalidation,
    live: bool = true,
    /// Optional ownership move after host acceptance, before commit. A queue
    /// that rejects the send must leave the Work's original Packet untouched.
    pub fn takePacket(self: *WorkspaceSend) !codec.Packet {
        if (self.work.client.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.ScopeClosed;
        const packet = self.work.packet orelse return error.PacketMoved;
        self.work.packet = null;
        return packet;
    }
    /// Call only after the host takes packet responsibility. No recoverable
    /// failure remains after beginSend: publish policy and invalidation together.
    pub fn commit(self: *WorkspaceSend) !WorkspaceCommit {
        if (self.work.client.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.ScopeClosed;
        self.live = false;
        const work = self.work;
        const client = work.client;
        defer {
            work.busy = false;
            self.reservation.end();
            client.busy = false;
        }
        const state = client.workspace_state.?;
        const previous = state.current;
        work.committed = true;
        state.pending = false;
        state.current = work.candidate;
        state.version = work.version;
        state.accepted = work.version;
        for (client.slots) |*slot| if (slot.serial != 0) slot.cancellation.request();
        for (&client.sync_controls) |*control| if (control.live) control.cancellation.request();
        // Both gates remain held through the last foreign result destructor.
        self.reservation.commitRetained() catch unreachable;
        previous.release(); // Work.base still pins it; no foreign free here.
        return .{ .stale = false };
    }
    /// Rejected/Full/Closed host queue: no policy, display or packet mutation.
    /// Same scope is idempotent; copies and out-of-order use are invalid.
    pub fn end(self: *WorkspaceSend) void {
        std.debug.assert(self.work.client.owner == std.Thread.getCurrentId());
        if (!self.live) return;
        self.live = false;
        const work = self.work;
        work.candidate.release(); // Work owns another reference, no foreign free.
        self.reservation.end();
        work.busy = false;
        work.client.busy = false;
    }
};

pub const WorkspaceIncoming = struct {
    client: *Client,
    epoch: u64,
    number: ?i32 = null,
    identifier: [256]u8 = undefined,
    identifier_len: u16 = 0,
    kind: enum { folders, configuration, unregister, unknown, invalid } = .unknown,
    registration: wire.Registration = .{},
    snapshot: ?*workspace.Snapshot = null,
    version: ?u64 = null,
    configuration_version: ?u64 = null,
    config_snapshot: ?*configuration.Snapshot = null,
    query: ?*configuration.Query = null,
    captured: bool = false,
    error_code: ?i32 = null,
    rejected: bool = false,
    packet: ?codec.Packet = null,
    prepared: bool = false,
    prepared_cancellation: bool = false,
    committed: bool = false,
    live: bool = true,
    busy: bool = false,
    cancellation: positions.Cancellation = .{},
    /// Owner capture/recapture preserves the same original request identifier.
    /// Stale prepared bytes are discarded before binding the latest snapshot.
    pub fn capture(self: *WorkspaceIncoming) !void {
        if (!self.live) return error.RequestClosed;
        if (self.busy) return error.Busy;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        if (self.epoch != client.epoch) return error.StaleEpoch;
        try client.responding();
        if (self.committed) return error.InvalidPhase;
        const state = client.workspace_state.?;
        if (state.accepted == null) return error.NotReady;
        self.busy = true;
        defer self.busy = false;
        if (self.packet) |*packet| packet.deinit();
        self.packet = null;
        if (self.snapshot) |snapshot| snapshot.release();
        self.snapshot = null;
        if (self.config_snapshot) |snapshot| snapshot.release();
        self.config_snapshot = null;
        try client.responding(); // Last foreign cleanup may have stopped the Client.
        self.error_code = if (self.rejected) @as(?i32, -32603) else switch (self.kind) {
            .unknown => -32601,
            .invalid => -32602,
            .folders, .configuration => null,
            .unregister => blk: {
                const registration = client.caps.workspace_registration orelse break :blk @as(i32, -32602);
                break :blk if (std.mem.eql(u8, registration.value(), self.registration.value())) null else @as(i32, -32602);
            },
        };
        if (self.kind == .folders) {
            try state.current.retain();
            self.snapshot = state.current;
        }
        if (self.kind == .configuration) {
            const config = state.configuration.?;
            try config.current.retain();
            self.config_snapshot = config.current;
        }
        self.version = state.accepted;
        self.configuration_version = client.configurationVersion();
        self.captured = true;
        self.prepared = false;
    }
    pub fn cancel(self: *WorkspaceIncoming) !void {
        if (!self.live) return error.RequestClosed;
        if (self.committed) return error.InvalidPhase;
        try self.client.check();
        self.cancellation.request();
    }
    /// Explicitly choose a fixed InternalError after preparation failed. The
    /// original failure is still returned by prepare; this never responds or
    /// consumes a new slot automatically. Captured request/id remain owned.
    pub fn reject(self: *WorkspaceIncoming) !void {
        if (!self.live) return error.RequestClosed;
        if (self.busy) return error.Busy;
        if (self.committed or !self.captured) return error.InvalidPhase;
        if (self.prepared and self.packet == null) return error.PacketMoved;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        self.busy = true;
        defer self.busy = false;
        self.rejected = true;
        self.error_code = -32603;
        self.prepared = false;
        const packet = self.packet;
        self.packet = null;
        if (packet) |owned| {
            var discard = owned;
            discard.deinit();
        }
        if (self.epoch != client.epoch) return error.StaleEpoch;
        try client.ready();
        try workspace.cancelled(&self.cancellation);
    }
    pub fn prepare(self: *WorkspaceIncoming, allocator: std.mem.Allocator) !void {
        if (!self.live) return error.RequestClosed;
        if (self.busy) return error.Busy;
        if (!self.captured or self.prepared or self.committed) return error.InvalidPhase;
        self.busy = true;
        defer self.busy = false;
        if (self.client.workspace_state.?.incoming_epoch.load(.acquire) != self.epoch) return error.Cancelled;
        const cancelled_before = self.cancellation.requested.load(.acquire);
        const response_code = if (cancelled_before) @as(?i32, -32800) else self.error_code;
        var packet = if (self.number) |number| try self.encode(allocator, number, response_code) else try self.encode(allocator, self.identifier[0..self.identifier_len], response_code);
        errdefer packet.deinit();
        if (self.client.workspace_state.?.incoming_epoch.load(.acquire) != self.epoch) return error.Cancelled;
        if (!cancelled_before and self.cancellation.requested.load(.acquire)) return error.Cancelled;
        self.packet = packet;
        self.prepared_cancellation = cancelled_before;
        self.prepared = true;
    }
    fn encode(self: *WorkspaceIncoming, allocator: std.mem.Allocator, identifier: anytype, response_code: ?i32) !codec.Packet {
        const limits = self.client.limits.framing;
        if (response_code) |number| return codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = identifier, .@"error" = .{ .code = number, .message = if (number == -32601) "Method not implemented" else if (number == -32800) "Request cancelled" else if (number == -32603) "Request failed" else "Invalid parameters" } }, limits);
        if (self.kind == .folders) return codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = identifier, .result = self.snapshot.?.folders }, limits);
        if (self.kind == .configuration) {
            const config = self.client.workspace_state.?.configuration.?;
            var output: [64]configuration.Raw = undefined;
            const values = try self.query.?.results(self.config_snapshot.?, config.limits, &output);
            var selected = limits;
            selected.body_bytes = @min(selected.body_bytes, config.limits.response_bytes);
            return codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = identifier, .result = values }, selected);
        }
        return codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = identifier, .result = @as(?u8, null) }, limits);
    }
    pub fn takePacket(self: *WorkspaceIncoming) !codec.Packet {
        if (!self.live) return error.RequestClosed;
        if (self.busy) return error.Busy;
        const packet = self.packet orelse return error.PacketMoved;
        self.packet = null;
        return packet;
    }
    pub fn validateSend(self: *const WorkspaceIncoming) !void {
        if (!self.live) return error.RequestClosed;
        if (self.busy) return error.Busy;
        try self.client.check();
        try self.client.responding();
        if (self.epoch != self.client.epoch) return error.StaleEpoch;
        if (!self.prepared or self.committed) return error.InvalidPhase;
        if (self.version != self.client.workspaceVersion()) return error.StaleWorkspace;
        if (self.configuration_version != self.client.configurationVersion()) return error.StaleConfiguration;
        if (!self.prepared_cancellation and self.cancellation.requested.load(.acquire)) return error.Cancelled;
    }
    /// Record an accepted response exactly once, even across stop/restart.
    pub fn commit(self: *WorkspaceIncoming) !Commit {
        if (!self.live) return error.RequestClosed;
        if (self.busy) return error.Busy;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        if (!self.prepared or self.committed) return error.InvalidPhase;
        self.committed = true;
        const stale = self.epoch != client.epoch or !client.canRespond() or self.version != client.workspaceVersion() or self.configuration_version != client.configurationVersion();
        if (!stale and self.kind == .unregister and self.error_code == null and !self.prepared_cancellation) {
            client.caps.workspace_changes = false;
            client.caps.workspace_registration = null;
        }
        return .{ .stale = stale };
    }
    /// Owner-only discard after worker join; failed App.post retains this lease.
    pub fn close(self: *WorkspaceIncoming) !void {
        if (!self.live) return error.RequestClosed;
        if (self.busy) return error.Busy;
        const client = self.client;
        try client.enter();
        defer client.busy = false;
        self.live = false;
        self.busy = true;
        if (self.packet) |*packet| packet.deinit();
        self.packet = null;
        if (self.snapshot) |snapshot| snapshot.release();
        self.snapshot = null;
        if (self.config_snapshot) |snapshot| snapshot.release();
        self.config_snapshot = null;
        if (self.query) |query| query.close();
        self.query = null;
        _ = client.workspace_state.?.incoming.fetchSub(1, .release);
    }
};

/// Explicit worker packet preparation for one immutable configuration change.
/// Shares the workspace product/control capacity; no second queue or pool.
pub const ConfigurationWork = struct {
    client: *Client,
    epoch: u64,
    version: u64,
    base_version: u64,
    workspace_version: u64,
    base: *configuration.Snapshot,
    candidate: *configuration.Snapshot,
    control: u8,
    packet: ?codec.Packet = null,
    prepared: bool = false,
    committed: bool = false,
    live: bool = true,
    busy: bool = false,
    fn checkCancellation(self: *const ConfigurationWork) !void {
        try workspace.cancelled(&self.client.workspace_state.?.controls[self.control].cancellation);
    }
    pub fn prepare(self: *ConfigurationWork, allocator: std.mem.Allocator) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        if (self.prepared) return error.AlreadyPrepared;
        self.busy = true;
        defer self.busy = false;
        try self.checkCancellation();
        const config = self.client.workspace_state.?.configuration.?;
        var limits = self.client.limits.framing;
        limits.body_bytes = @min(limits.body_bytes, config.limits.response_bytes);
        var packet = try wire.notification(allocator, "workspace/didChangeConfiguration", .{ .settings = configuration.Raw{ .bytes = self.candidate.settings } }, limits);
        errdefer packet.deinit();
        try self.checkCancellation();
        self.packet = packet;
        self.prepared = true;
    }
    pub fn takePacket(self: *ConfigurationWork) !codec.Packet {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        const packet = self.packet orelse return error.PacketMoved;
        self.packet = null;
        return packet;
    }
    pub fn validateSend(self: *const ConfigurationWork) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        try self.client.check();
        try self.client.ready();
        if (self.epoch != self.client.epoch) return error.StaleEpoch;
        if (!self.prepared or self.committed) return error.InvalidPhase;
        try self.checkCancellation();
        if (self.workspace_version != self.client.workspaceVersion()) return error.StaleWorkspace;
        if (self.base_version != self.client.configurationVersion()) return error.StaleConfiguration;
    }
    pub fn beginSend(self: *ConfigurationWork) !ConfigurationSend {
        try self.validateSend();
        try self.client.enter();
        errdefer self.client.busy = false;
        var reservation = try self.client.broker.beginInvalidation();
        errdefer reservation.end();
        try self.candidate.retain();
        self.busy = true;
        return .{ .work = self, .reservation = reservation };
    }
    pub fn cancel(self: *ConfigurationWork) !void {
        if (!self.live) return error.WorkClosed;
        try self.client.check();
        if (self.committed) return error.InvalidPhase;
        self.client.workspace_state.?.controls[self.control].cancellation.request();
    }
    pub fn close(self: *ConfigurationWork) !void {
        if (!self.live) return error.WorkClosed;
        if (self.busy) return error.Busy;
        try self.client.enter();
        defer self.client.busy = false;
        self.live = false;
        self.busy = true;
        if (self.packet) |*packet| packet.deinit();
        self.packet = null;
        self.candidate.release();
        self.base.release();
        const state = self.client.workspace_state.?;
        if (!self.committed and self.epoch == self.client.epoch) state.pending = false;
        state.unreserve(self.control);
    }
};
pub const ConfigurationSend = struct {
    work: *ConfigurationWork,
    reservation: code.Broker.Invalidation,
    live: bool = true,
    pub fn takePacket(self: *ConfigurationSend) !codec.Packet {
        if (self.work.client.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.ScopeClosed;
        const packet = self.work.packet orelse return error.PacketMoved;
        self.work.packet = null;
        return packet;
    }
    /// Host accepted responsibility. No failure/cancellation read remains after
    /// beginSend. Document edits do not block an unrelated configuration change.
    pub fn commit(self: *ConfigurationSend) !WorkspaceCommit {
        if (self.work.client.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.ScopeClosed;
        self.live = false;
        const work = self.work;
        const client = work.client;
        defer {
            work.busy = false;
            self.reservation.end();
            client.busy = false;
        }
        const state = client.workspace_state.?;
        const config = state.configuration.?;
        const previous = config.current;
        work.committed = true;
        state.pending = false;
        config.current = work.candidate;
        config.version = work.version;
        config.accepted = work.version;
        // Versionless configuration diagnostics cannot be stamped on arrival.
        // Only a newly accepted, higher-version sync can establish provenance.
        config.synchronized = null;
        for (client.slots) |*slot| if (slot.serial != 0) slot.cancellation.request();
        for (&client.sync_controls) |*control| if (control.live) control.cancellation.request();
        self.reservation.commitRetained() catch unreachable;
        previous.release();
        return .{ .stale = false };
    }
    pub fn end(self: *ConfigurationSend) void {
        std.debug.assert(self.work.client.owner == std.Thread.getCurrentId());
        if (!self.live) return;
        self.live = false;
        self.work.candidate.release();
        self.reservation.end();
        self.work.busy = false;
        self.work.client.busy = false;
    }
};
