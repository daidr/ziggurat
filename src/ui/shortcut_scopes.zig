const std = @import("std");
const z = @import("ziggurat");

pub const max_scopes = 32;
pub const max_depth = 16;
pub const Kind = enum { focused, overlay };
pub const ScopeOptions = struct {
    enabled: bool = true,
    kind: Kind = .focused,
    overlay_order: u32 = 0,
    /// Isolate registered shortcuts; this does not create a modal window.
    keyboard_barrier: bool = false,
};
pub const Authority = struct {
    window: z.Window,
    installation: u64,
    routing: u64,
    text: ?z.TextClientToken,
    mode: z.TextInputStamp,
    focused: ?u64,
};
pub const EnteredKey = struct { key: z.KeyInput, authority: Authority };
pub const Request = struct {
    id: u64,
    authority: Authority,
    origin: u64,
    state: enum { waiting, ready, queued } = .waiting,
    target: u64 = 0,
};
pub const Unhandled = struct { context: *anyopaque, call: *const fn (*anyopaque, z.Window, z.KeyInput) void };
pub const Options = struct {
    capacity: u8 = max_scopes,
    depth: u8 = max_depth,
    unhandled: ?Unhandled = null,

    pub fn validate(self: Options) !void {
        if (self.capacity < 2 or self.capacity > max_scopes or self.depth == 0 or self.depth > max_depth) return error.InvalidShortcutLimits;
    }
};
pub const Node = struct {
    id: u64 = 0,
    ancestors: u32 = 1,
    order: u32 = 0,
    parent: u8 = 0,
    depth: u8 = 0,
    kind: Kind = .focused,
    enabled: bool = true,
    barrier: bool = false,
};
const Bank = struct {
    nodes: [max_scopes]Node = undefined,
    members: [128]u8 = undefined,
    len: u8 = 1,
    visible: u32 = 1,

    fn reset(self: *Bank) void {
        self.len = 1;
        self.visible = 1;
        self.nodes[0] = .{};
    }
};

/// A single optional owner contains both transactional scope banks. No node
/// owns a control, chord, focus, text document or coordinate mapping.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    options: Options,
    refs: usize = 1,
    closed: bool = false,
    entry: ?*anyopaque = null,
    window: ?z.Window = null,
    text_token: ?z.TextClientToken = null,
    text_scope: ?u64 = null,
    routing_epoch: u64 = 0,
    banks: [2]Bank = .{ .{}, .{} },
    front: u1 = 0,
    stack: [max_depth]u8 = undefined,
    stack_len: u8 = 0,
    current: u8 = 0,
    candidate: u64 = 0,
    serial: u64 = 0,
    hit_len: usize = 0,
    failure: ?anyerror = null,
    key_busy: bool = false,
    entered_key: ?EnteredKey = null,
    request: ?Request = null,
    next_request: u64 = 0,
    frame_request: ?u64 = null,
    attempt_request: ?u64 = null,
    post_accepted: bool = false,
    last_error: ?anyerror = null,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Workspace {
        try options.validate();
        const self = try allocator.create(Workspace);
        self.* = .{ .allocator = allocator, .options = options };
        self.banks[0].reset();
        self.banks[1].reset();
        return self;
    }
    pub fn retain(self: *Workspace) void {
        std.debug.assert(self.refs != 0);
        self.refs += 1;
    }
    pub fn release(self: *Workspace) void {
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs == 0) {
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    }
    pub fn close(self: *Workspace) void {
        self.entry = null;
        self.closed = true;
        self.text_token = null;
        self.text_scope = null;
        self.request = null;
        self.entered_key = null;
        self.options.unhandled = null;
        self.attempt_request = null;
    }
    pub fn advanceRouting(self: *Workspace) bool {
        if (self.routing_epoch == std.math.maxInt(u64)) {
            self.close();
            return false;
        }
        self.routing_epoch += 1;
        return true;
    }
    pub fn pending(self: *Workspace) *Bank {
        return &self.banks[self.front ^ 1];
    }
    pub fn accepted(self: *const Workspace) *const Bank {
        return &self.banks[self.front];
    }
    pub fn beginFrame(self: *Workspace) void {
        self.pending().reset();
        self.current = 0;
        self.stack_len = 0;
        self.failure = null;
        self.frame_request = null;
        if (self.candidate == std.math.maxInt(u64)) {
            self.failure = error.ShortcutGenerationExhausted;
        } else self.candidate += 1;
    }
    pub fn cancelFrame(self: *Workspace) void {
        self.current = 0;
        self.stack_len = 0;
    }
    pub fn beginScope(self: *Workspace, id: u64, options: ScopeOptions) anyerror!void {
        return self.beginScopeBody(id, options) catch |err| {
            self.failure = self.failure orelse err;
            return err;
        };
    }
    fn beginScopeBody(self: *Workspace, id: u64, options: ScopeOptions) anyerror!void {
        if (self.closed) return error.ShortcutScopesClosed;
        if (self.failure) |err| return @as(anyerror!void, err);
        if (id == 0) return error.ReservedShortcutScope;
        const bank = self.pending();
        if (bank.len == self.options.capacity) return error.TooManyShortcutScopes;
        if (self.stack_len == self.options.depth) return error.ShortcutScopeDepthExceeded;
        for (bank.nodes[0..bank.len]) |node| if (node.id == id) return error.DuplicateShortcutScope;
        if (options.kind == .focused and (options.overlay_order != 0 or options.keyboard_barrier)) return error.InvalidShortcutScope;
        if (options.kind == .overlay) {
            if (options.overlay_order == 0) return error.InvalidShortcutScope;
            for (bank.nodes[0..bank.len]) |node| if (node.kind == .overlay and node.order == options.overlay_order) return error.DuplicateOverlayOrder;
        }
        const index = bank.len;
        const parent = bank.nodes[self.current];
        const bit = @as(u32, 1) << @as(u5, @intCast(index));
        bank.nodes[index] = .{ .id = id, .parent = self.current, .depth = parent.depth + 1, .ancestors = parent.ancestors | bit, .enabled = parent.enabled and options.enabled, .kind = options.kind, .order = options.overlay_order, .barrier = options.keyboard_barrier };
        bank.len += 1;
        self.stack[self.stack_len] = self.current;
        self.stack_len += 1;
        self.current = index;
    }
    pub fn endScope(self: *Workspace) !void {
        return self.endScopeBody() catch |err| {
            self.failure = self.failure orelse err;
            return err;
        };
    }
    fn endScopeBody(self: *Workspace) !void {
        if (self.closed) return error.ShortcutScopesClosed;
        if (self.stack_len == 0) return error.UnbalancedShortcutScopes;
        self.stack_len -= 1;
        self.current = self.stack[self.stack_len];
    }
    pub fn frameValid(self: *const Workspace, hits: usize) bool {
        if (self.failure != null or self.stack_len != 0 or self.current != 0) return false;
        const bank = &self.banks[self.front ^ 1];
        for (bank.members[0..hits]) |member| if (member >= bank.len) return false;
        return true;
    }
    pub fn validateCandidate(self: *const Workspace, hits: anytype, mapped: anytype) anyerror!void {
        if (self.failure) |err| return @as(anyerror!void, err);
        if (!self.frameValid(hits.len)) return error.InvalidShortcutFrame;
        const bank = &self.banks[self.front ^ 1];
        if (bank.len == 0 or bank.len > self.options.capacity or !std.meta.eql(bank.nodes[0], Node{})) return error.InvalidShortcutFrame;
        for (bank.nodes[1..bank.len], 1..) |node, i| {
            if (node.id == 0 or node.parent >= i) return error.InvalidShortcutFrame;
            const parent = bank.nodes[node.parent];
            const bit = @as(u32, 1) << @as(u5, @intCast(i));
            if (node.depth != parent.depth + 1 or node.depth > self.options.depth or node.ancestors != parent.ancestors | bit or (node.enabled and !parent.enabled)) return error.InvalidShortcutFrame;
            for (bank.nodes[1..i]) |previous| {
                if (previous.id == node.id) return error.DuplicateShortcutScope;
                if (node.kind == .overlay and previous.kind == .overlay and node.order == previous.order) return error.DuplicateOverlayOrder;
            }
            if (node.kind == .focused and (node.order != 0 or node.barrier)) return error.InvalidShortcutScope;
            if (node.kind == .overlay) {
                if (node.order == 0) return error.InvalidShortcutScope;
                var cursor = node.parent;
                while (cursor != 0) : (cursor = bank.nodes[cursor].parent) {
                    const ancestor = bank.nodes[cursor];
                    if (ancestor.kind == .overlay and ancestor.order >= node.order) return error.InvalidOverlayOrder;
                }
            }
        }
        const visible = self.visibility(hits, mapped);
        var barrier: ?u8 = null;
        for (bank.nodes[1..bank.len], 1..) |node, i| if (node.barrier and node.enabled and visible & (@as(u32, 1) << @as(u5, @intCast(i))) != 0) {
            if (barrier == null or node.order > bank.nodes[barrier.?].order) barrier = @intCast(i);
        };
        if (barrier) |b| for (bank.nodes[1..bank.len], 1..) |node, i| {
            if (node.kind != .overlay or !node.enabled or node.order <= bank.nodes[b].order or visible & (@as(u32, 1) << @as(u5, @intCast(i))) == 0) continue;
            if (node.ancestors & (@as(u32, 1) << @as(u5, @intCast(b))) == 0) return error.ConflictingOverlayScope;
        };
    }
    fn visibility(self: *const Workspace, hits: anytype, mapped: anytype) u32 {
        const bank = &self.banks[self.front ^ 1];
        var result: u32 = 1;
        for (hits, 0..) |hit, i| {
            const visible = if (mapped) |snapshot| snapshot.hits[i].visible else hit.rect.width > 0 and hit.rect.height > 0;
            if (visible) result |= bank.nodes[bank.members[i]].ancestors;
        }
        return result;
    }
    pub fn commit(self: *Workspace, hits: anytype, mapped: anytype) void {
        std.debug.assert(self.frameValid(hits.len));
        const bank = self.pending();
        bank.visible = self.visibility(hits, mapped);
        self.front ^= 1;
        self.serial = self.candidate;
        self.hit_len = hits.len;
        if (self.text_scope) |id| if (self.scope(id) == null) {
            self.text_scope = null;
            self.text_token = null;
            _ = self.advanceRouting();
        };
    }
    pub fn scope(self: *const Workspace, id: u64) ?u8 {
        const bank = self.accepted();
        for (bank.nodes[0..bank.len], 0..) |node, index| if (node.id == id) return @intCast(index);
        return null;
    }
    pub fn enabled(self: *const Workspace, member: u8) bool {
        const bank = self.accepted();
        return !self.closed and member < bank.len and bank.nodes[member].enabled;
    }
    pub fn ranks(self: *const Workspace, focused: ?u8) [max_scopes]u8 {
        var result: [max_scopes]u8 = @splat(255);
        if (self.closed) return result;
        const bank = self.accepted();
        var barrier: ?u8 = null;
        var overlay: ?u8 = null;
        for (bank.nodes[1..bank.len], 1..) |node, index| {
            if (!node.enabled or bank.visible & (@as(u32, 1) << @as(u5, @intCast(index))) == 0) continue;
            if (node.barrier and (barrier == null or node.order > bank.nodes[barrier.?].order)) barrier = @intCast(index);
        }
        for (bank.nodes[1..bank.len], 1..) |node, index| {
            if (node.kind != .overlay or !node.enabled or bank.visible & (@as(u32, 1) << @as(u5, @intCast(index))) == 0) continue;
            if (barrier) |b| if (node.ancestors & (@as(u32, 1) << @as(u5, @intCast(b))) == 0) continue;
            if (overlay == null or node.order > bank.nodes[overlay.?].order) overlay = @intCast(index);
        }
        var next: u8 = 0;
        if (focused) |f| self.rankChain(f, barrier, &result, &next);
        if (overlay) |o| self.rankChain(o, barrier, &result, &next);
        if (barrier == null) result[0] = next;
        return result;
    }
    fn rankChain(self: *const Workspace, start: u8, barrier: ?u8, result: *[max_scopes]u8, next: *u8) void {
        const bank = self.accepted();
        if (start >= bank.len or !bank.nodes[start].enabled) return;
        if (barrier) |b| if (bank.nodes[start].ancestors & (@as(u32, 1) << @as(u5, @intCast(b))) == 0) return;
        var current = start;
        while (current != 0) {
            if (result[current] == 255) {
                result[current] = next.*;
                next.* += 1;
            }
            if (barrier == current) break;
            current = bank.nodes[current].parent;
        }
    }
};
