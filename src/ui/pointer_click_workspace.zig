const std = @import("std");
const z = @import("ziggurat");
const Context = @import("root.zig").Context;
pub const kernel = @import("pointer_clicks.zig");

pub const Outcome = enum { accepted, rejected };
pub const Click = struct { id: u64, count: u8, button: z.PointerButton, press: z.PointerPress, position: z.Point };
pub const Registration = struct {
    context: *anyopaque,
    on_input: ?*const fn (*anyopaque, *Context, z.Event) bool = null,
    on_click: *const fn (*anyopaque, z.Window, Click) Outcome,
};
/// Borrows this stable Context. It does not retain the Context or its owner.
pub const Target = struct { context: *Context, installation: u64, registration: u64, serial: u64, id: u64 };

/// One optional allocation. Final release has no Context dependency. Its
/// allocator and allocator context must outlive all captured event references.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    refs: usize = 1,
    state: kernel.State,
    registration: ?Registration,
    last_up: z.PointerPress = .{},
    frame_failure: ?anyerror = null,

    pub fn create(allocator: std.mem.Allocator, epoch: u64, window: kernel.Window, attachment: kernel.Attachment, registration: Registration, hits: usize) !*Workspace {
        comptime std.debug.assert(@sizeOf(Workspace) <= 4096);
        if (hits > kernel.capacity) return error.CapacityExceeded;
        const self = try allocator.create(Workspace);
        self.* = .{ .allocator = allocator, .state = kernel.State.init(epoch), .registration = registration };
        errdefer allocator.destroy(self);
        try self.state.install(window, attachment);
        // Existing ordinary controls predate this owner. Their association is
        // explicitly zero; preparing never registers an already displayed hit.
        try self.state.beginFrame();
        for (0..hits) |_| _ = try self.state.append();
        try self.state.commitFrame(hits, .{});
        return self;
    }
    pub fn retain(self: *Workspace) bool {
        std.debug.assert(self.refs != 0);
        self.refs = std.math.add(usize, self.refs, 1) catch return false;
        return true;
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
        self.state.close();
        self.registration = null;
        self.last_up = .{};
    }
    pub fn revoke(self: *Workspace) void {
        self.last_up = .{};
        self.state.changeRoute() catch {};
    }
    pub fn beginFrame(self: *Workspace) void {
        self.frame_failure = null;
        self.state.beginFrame() catch |err| {
            self.frame_failure = err;
        };
    }
    pub fn pendingMark(self: *const Workspace, index: usize) ?u64 {
        if (!self.state.building) return null;
        const bank = &self.state.banks[self.state.front ^ 1];
        if (index >= bank.len) return null;
        return bank.serials[index];
    }
    pub fn current(self: *const Workspace, guard: kernel.Guard) bool {
        const state = &self.state;
        if (guard.owner != state or state.closed or state.retired or guard.installation != state.installation or guard.registration != state.registration or guard.routing != state.routing) return false;
        const entered = state.entered orelse return false;
        return std.meta.eql(entered.guard, guard);
    }
};
