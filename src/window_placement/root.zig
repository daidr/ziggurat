const std = @import("std");
const z = @import("ziggurat");
const native = @import("native.zig");
pub const model = @import("model.zig");
pub const codec = @import("codec.zig");
pub const Files = @import("files.zig").Files;
pub const Key = model.Key;
pub const Rect = model.Rect;
pub const Monitor = model.Monitor;
pub const Topology = model.Topology;
pub const State = model.State;
pub const Entry = model.Entry;
pub const Store = model.Store;
pub const Constraints = model.Constraints;
pub const Plan = model.Plan;
pub const Reach = model.Reach;

fn owner(window: z.Window, expected: std.Thread.Id) !void {
    if (std.Thread.getCurrentId() != expected or expected != window.app.owner) return error.WrongThread;
}
/// Explicit event/update-stage snapshot. No heap storage, callback registration
/// or implicit DisplayChanged event. Wayland positioning is unsupported.
pub fn refresh(window: z.Window) !Topology {
    try owner(window, window.app.owner);
    const scope = window.beginCallback() orelse return error.Closed;
    defer scope.end();
    if (!(try window.capabilities()).client_position) return error.UnsupportedCapability;
    return native.query(window);
}
fn monitorIndex(topology: *const Topology, key: Key) !u8 {
    for (topology.items(), 0..) |monitor, at| if (monitor.key.eql(key)) return @intCast(at);
    return error.DisplayChanged;
}
fn normal(state: z.WindowState) bool {
    return !state.minimized and !state.maximized and !state.fullscreen and !state.fullscreen_requested;
}
pub const Observation = enum { normal, special, normal_pending };

/// Stable caller-owned owner-thread value. Special states never overwrite the
/// normal rectangle. After a special->normal transition confirmNormal is an
/// explicit host acknowledgement that its WM/layout observations have settled.
/// State and ConfigureNotify are not an atomic geometry snapshot on X11.
pub const Tracker = struct {
    thread: std.Thread.Id,
    value: ?State = null,
    normal_armed: bool = true,
    busy: bool = false,
    pub fn init() Tracker {
        return .{ .thread = std.Thread.getCurrentId() };
    }
    fn checked(self: *const Tracker, window: z.Window) !void {
        try owner(window, self.thread);
        if (self.busy) return error.Busy;
    }
    pub fn observe(self: *Tracker, window: z.Window, topology: *const Topology) !Observation {
        try self.checked(window);
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        const state = try window.state();
        if (!normal(state)) {
            var candidate = self.value orelse return error.NormalBoundsRequired;
            if (!state.minimized) {
                if (!state.fullscreen and !state.fullscreen_requested) candidate.maximized = state.maximized;
                candidate.fullscreen = state.fullscreen or state.fullscreen_requested;
            }
            candidate.always_on_top = state.always_on_top_requested;
            self.value = candidate;
            self.normal_armed = false;
            return .special;
        }
        if (!self.normal_armed) {
            if (self.value) |*value| {
                value.maximized = false;
                value.fullscreen = false;
                value.always_on_top = state.always_on_top_requested;
            }
            return .normal_pending;
        }
        try self.capture(window, topology, state);
        return .normal;
    }
    pub fn confirmNormal(self: *Tracker, window: z.Window, topology: *const Topology) !void {
        try self.checked(window);
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        const state = try window.state();
        if (!normal(state)) return error.InvalidWindowState;
        try self.capture(window, topology, state);
        self.normal_armed = true;
    }
    fn capture(self: *Tracker, window: z.Window, topology: *const Topology, state: z.WindowState) !void {
        const bounds = try window.clientBounds();
        const current = try native.current(window);
        const position = bounds.position orelse return error.UnsupportedCapability;
        if (bounds.width != current.observed.width or bounds.height != current.observed.height or position.x != current.observed.position.x or position.y != current.observed.position.y) return error.GeometryPending;
        const index = try monitorIndex(topology, current.key);
        const candidate: State = .{ .space = topology.space, .normal = current.observed, .work = topology.monitors[index].work, .display = current.key, .units_per_dip = current.metrics.units_per_dip, .always_on_top = state.always_on_top_requested };
        try candidate.validate();
        if (window.isClosed()) return error.Closed;
        self.value = candidate;
    }
    pub fn snapshot(self: *const Tracker) !State {
        if (std.Thread.getCurrentId() != self.thread) return error.WrongThread;
        if (self.busy) return error.Busy;
        return self.value orelse error.NormalBoundsRequired;
    }
};

pub const Displacement = enum { special, contained, partial, offscreen };
/// Classifies the current native frame against a topology refreshed after a
/// display change, such as a system.desktop monitors notification. Query only;
/// relocation is an explicit Restorer started from the Tracker snapshot.
/// Special states report special: the system owns those frames.
pub fn displacement(window: z.Window, topology: *const Topology) !Displacement {
    try owner(window, window.app.owner);
    const scope = window.beginCallback() orelse return error.Closed;
    defer scope.end();
    if (!(try window.capabilities()).client_position) return error.UnsupportedCapability;
    if (!normal(try window.state())) return .special;
    const current = try native.current(window);
    _ = try monitorIndex(topology, current.key);
    return switch (try model.reach(current.frame, topology)) {
        .contained => .contained,
        .partial => .partial,
        .offscreen => .offscreen,
    };
}

pub const Progress = enum { waiting, needs_show, complete };
pub const Phase = enum { normalize, target, fit, geometry, mode, complete, cancelled };
/// An explicit asynchronous WM transaction, not an atomic native rollback.
/// Keep this value stable during advance and invoke it from actual geometry /
/// state events. Waiting never arms a timer or pumps messages. Errors may follow
/// already accepted native steps; phase/plan remain available for inspection.
pub const Restorer = struct {
    const max_refits = 8;
    window: z.Window,
    thread: std.Thread.Id,
    saved: State,
    topology: Topology,
    constraints: Constraints,
    display_index: u8,
    phase: Phase = .normalize,
    plan: ?Plan = null,
    scale: f64 = 0,
    busy: bool = false,
    leave_fullscreen_sent: bool = false,
    normal_required: bool = false,
    restore_sent: bool = false,
    maximize_sent: bool = false,
    fullscreen_sent: bool = false,
    topmost_sent: bool = false,
    refits: u8 = 0,
    pub fn init(window: z.Window, saved: State, topology: Topology, constraints: Constraints) !Restorer {
        try owner(window, window.app.owner);
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const capabilities = try window.capabilities();
        if (!capabilities.client_position or (saved.fullscreen and !capabilities.fullscreen) or (saved.always_on_top and !capabilities.always_on_top)) return error.UnsupportedCapability;
        const index = try model.choose(saved, &topology);
        // Validate constraints before any native state changes. Actual fit uses
        // the target window's observed DPI after crossing monitor boundaries.
        try model.validateConstraints(constraints);
        return .{ .window = window, .thread = std.Thread.getCurrentId(), .saved = saved, .topology = topology, .constraints = constraints, .display_index = index };
    }
    pub fn cancel(self: *Restorer) !void {
        try owner(self.window, self.thread);
        if (self.busy) return error.Busy;
        self.phase = .cancelled;
    }
    pub fn advance(self: *Restorer) !Progress {
        try owner(self.window, self.thread);
        if (self.busy) return error.Busy;
        if (self.phase == .cancelled) return error.Cancelled;
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        // Fixed phase transitions only; no waiting or retries inside this call.
        for (0..7) |_| {
            if (self.window.isClosed() or self.window.app.phase == .stopping or self.window.app.phase == .stopped) return error.Closed;
            const state = try self.window.state();
            switch (self.phase) {
                .normalize => {
                    if (state.fullscreen or state.fullscreen_requested) {
                        if (!self.leave_fullscreen_sent) {
                            try self.window.setFullscreen(false);
                            self.leave_fullscreen_sent = true;
                            self.normal_required = true;
                            // Request normal together with the exit: sent
                            // after it, the asynchronous return to the max/min
                            // mode from before full screen could still be in
                            // flight when the normal geometry is observed.
                            try self.window.perform(.restore);
                            self.restore_sent = true;
                        }
                        return .waiting;
                    }
                    if (!self.restore_sent and (self.normal_required or state.minimized or state.maximized)) {
                        // Each request is submitted once.
                        try self.window.perform(.restore);
                        self.restore_sent = true;
                        continue;
                    }
                    if (!normal(state)) return .waiting;
                    self.phase = .target;
                },
                .target => {
                    if (!normal(state)) return .waiting;
                    const current = try native.current(self.window);
                    if (!current.key.eql(self.topology.monitors[self.display_index].key)) {
                        // Provisional minimum-size move is explicit, and is not
                        // reported as final placement. It makes the target the
                        // actual DPI owner before computing its DIP limits.
                        var small = self.saved;
                        small.normal.width = @min(small.normal.width, @max(64, self.constraints.min_width));
                        small.normal.height = @min(small.normal.height, @max(64, self.constraints.min_height));
                        const provisional = try model.resolveOn(small, &self.topology, self.display_index, current.metrics, self.constraints);
                        try self.setBounds(provisional.bounds);
                    }
                    self.phase = .fit;
                },
                .fit => {
                    if (!normal(state)) return .waiting;
                    const current = try native.current(self.window);
                    if (!current.key.eql(self.topology.monitors[self.display_index].key)) return .waiting;
                    // Insets and limits only come from a settled window: while
                    // the toolkit's view lags the server, a WM change is still
                    // being delivered and the next geometry event retries.
                    const observed = try self.window.clientBounds();
                    if (observed.position == null or observed.width != current.observed.width or observed.height != current.observed.height or observed.position.?.x != current.observed.position.x or observed.position.?.y != current.observed.position.y) return .waiting;
                    const plan = try model.resolveOn(self.saved, &self.topology, self.display_index, current.metrics, self.constraints);
                    try self.setBounds(plan.bounds);
                    if (self.window.isClosed()) return error.Closed;
                    self.plan = plan;
                    self.scale = current.metrics.units_per_dip;
                    self.phase = .geometry;
                },
                .geometry => {
                    if (!normal(state)) return .waiting;
                    const current = try native.current(self.window);
                    if (!current.key.eql(self.topology.monitors[self.display_index].key)) return error.DisplayChanged;
                    if (current.metrics.units_per_dip != self.scale) {
                        self.phase = .fit;
                        return .waiting;
                    }
                    const observed = try self.window.clientBounds();
                    const desired = self.plan.?.bounds;
                    const work = self.topology.monitors[self.display_index].work;
                    const frame = current.frame;
                    const landed = observed.position != null and observed.width == desired.width and observed.height == desired.height and observed.position.?.x == desired.position.x and observed.position.?.y == desired.position.y and std.meta.eql(current.observed, desired);
                    const contained = frame.x >= work.x and frame.y >= work.y and frame.right() <= work.right() and frame.bottom() <= work.bottom();
                    if (landed and self.refits < max_refits) {
                        // Frame insets observed while a mode change settles can
                        // differ from the final decorations, so a plan fitted
                        // against them is wrong once the client lands. No
                        // further geometry event arrives for a client that
                        // already matches; fit again against current insets.
                        const settled = try model.resolveOn(self.saved, &self.topology, self.display_index, current.metrics, self.constraints);
                        if (!std.meta.eql(settled.bounds, desired)) {
                            self.refits += 1;
                            self.phase = .fit;
                            continue;
                        }
                    }
                    if (!landed or !contained) return if (state.visible) .waiting else .needs_show;
                    self.phase = .mode;
                },
                .mode => {
                    const plan = self.plan.?;
                    if ((!plan.fullscreen and (state.fullscreen or state.fullscreen_requested)) or (!plan.maximized and !plan.fullscreen and state.maximized)) {
                        return .waiting;
                    }
                    if (state.always_on_top != plan.always_on_top or state.always_on_top_requested != plan.always_on_top) {
                        if (!self.topmost_sent) {
                            try self.window.setAlwaysOnTop(plan.always_on_top);
                            self.topmost_sent = true;
                        }
                        return .waiting;
                    }
                    if (plan.maximized and !state.fullscreen and !state.fullscreen_requested and !state.maximized) {
                        if (!state.visible) return .needs_show;
                        if (!self.maximize_sent) {
                            try self.window.perform(.maximize);
                            self.maximize_sent = true;
                        }
                        return .waiting;
                    }
                    if (plan.fullscreen and !state.fullscreen_requested) {
                        if (!self.fullscreen_sent) {
                            try self.window.setFullscreen(true);
                            self.fullscreen_sent = true;
                        }
                        return .waiting;
                    }
                    if (plan.fullscreen and !state.fullscreen) return .waiting;
                    self.phase = .complete;
                    return .complete;
                },
                .complete => return .complete,
                .cancelled => return error.Cancelled,
            }
        }
        return .waiting;
    }
    fn setBounds(self: *Restorer, bounds: model.Bounds) !void {
        try self.window.setClientBounds(.{ .position = .{ .x = bounds.position.x, .y = bounds.position.y }, .width = bounds.width, .height = bounds.height });
    }
};

test {
    _ = @import("tests.zig");
}
