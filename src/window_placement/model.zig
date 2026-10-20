const std = @import("std");

pub const max_monitors = 64;
pub const max_entries = 256;
pub const Space = enum(u8) { win32_physical = 1, x11_logical = 2 };
pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    pub fn validate(self: Rect) !void {
        if (self.width == 0 or self.height == 0 or self.width > std.math.maxInt(i32) or self.height > std.math.maxInt(i32) or self.right() > std.math.maxInt(i32) or self.bottom() > std.math.maxInt(i32)) return error.InvalidRectangle;
    }
    pub fn right(self: Rect) i64 {
        return @as(i64, self.x) + self.width;
    }
    pub fn bottom(self: Rect) i64 {
        return @as(i64, self.y) + self.height;
    }
};
/// Application and display keys are UTF-8 values, never runtime Window IDs.
/// A display key is advisory: connectors, names and enumeration can change.
pub const Key = struct {
    bytes: [96]u8 = @splat(0),
    len: u8 = 0,
    pub fn init(value: []const u8) !Key {
        if (value.len == 0 or value.len > 96 or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidKey;
        var result: Key = .{ .len = @intCast(value.len) };
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }
    pub fn slice(self: *const Key) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn eql(a: Key, b: Key) bool {
        return a.len == b.len and std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }
    pub fn validate(self: Key) !void {
        _ = try init(self.bytes[0..@min(self.len, 96)]);
        if (self.len > 96) return error.InvalidKey;
    }
};
pub const Monitor = struct { key: Key, bounds: Rect, work: Rect, primary: bool = false };
pub const Topology = struct {
    space: Space,
    monitors: [max_monitors]Monitor = undefined,
    count: u8 = 0,
    pub fn init(space: Space, input: []const Monitor) !Topology {
        if (input.len == 0) return error.NoDisplays;
        if (input.len > max_monitors) return error.CapacityExceeded;
        for (input, 0..) |monitor, at| {
            try monitor.key.validate();
            try monitor.bounds.validate();
            try monitor.work.validate();
            if (monitor.work.x < monitor.bounds.x or monitor.work.y < monitor.bounds.y or monitor.work.right() > monitor.bounds.right() or monitor.work.bottom() > monitor.bounds.bottom()) return error.InvalidWorkarea;
            for (input[0..at]) |old| if (old.key.eql(monitor.key)) return error.DuplicateDisplay;
        }
        var result: Topology = .{ .space = space, .count = @intCast(input.len) };
        @memcpy(result.monitors[0..input.len], input);
        return result;
    }
    pub fn items(self: *const Topology) []const Monitor {
        return self.monitors[0..self.count];
    }
};
pub const Bounds = struct { position: Point, width: u32, height: u32 };
pub const State = struct {
    space: Space,
    normal: Bounds,
    work: Rect,
    display: Key,
    /// Native desktop units per DIP, not framebuffer pixels per DIP on X11.
    units_per_dip: f64 = 1,
    maximized: bool = false,
    fullscreen: bool = false,
    always_on_top: bool = false,
    pub fn validate(self: State) !void {
        try self.display.validate();
        try self.work.validate();
        try validScale(self.units_per_dip);
        if (self.normal.width == 0 or self.normal.height == 0 or self.normal.width > 32768 or self.normal.height > 32768) return error.InvalidSize;
    }
};
pub const Insets = struct { left: u32 = 0, top: u32 = 0, right: u32 = 0, bottom: u32 = 0 };
pub const Metrics = struct { units_per_dip: f64 = 1, insets: Insets = .{} };
pub const Constraints = struct { min_width: u32 = 1, min_height: u32 = 1, max_width: u32 = 32768, max_height: u32 = 32768 };
pub const Plan = struct { bounds: Bounds, display_index: u8, maximized: bool, fullscreen: bool, always_on_top: bool, recovered: bool };

pub fn validScale(scale: f64) !void {
    if (!std.math.isFinite(scale) or scale < 0.125 or scale > 16) return error.InvalidScale;
}
fn overlap(a: Rect, b: Rect) u64 {
    const width = @max(0, @min(a.right(), b.right()) - @max(@as(i64, a.x), b.x));
    const height = @max(0, @min(a.bottom(), b.bottom()) - @max(@as(i64, a.y), b.y));
    return @as(u64, @intCast(width)) * @as(u64, @intCast(height));
}
fn distance(a: Point, b: Rect) f64 {
    const dx: f64 = @floatFromInt(if (a.x < b.x) @as(i64, b.x) - a.x else @max(0, @as(i64, a.x) - b.right()));
    const dy: f64 = @floatFromInt(if (a.y < b.y) @as(i64, b.y) - a.y else @max(0, @as(i64, a.y) - b.bottom()));
    return dx * dx + dy * dy;
}
/// Prefer the advisory connector, then overlap, then nearest workarea. Ties
/// prefer primary and finally native enumeration order. Cross-space restores
/// deliberately discard persisted positions.
pub fn choose(state: State, topology: *const Topology) !u8 {
    try state.validate();
    if (topology.count == 0 or topology.count > max_monitors) return error.NoDisplays;
    if (state.space != topology.space) {
        for (topology.items(), 0..) |monitor, at| if (monitor.primary) return @intCast(at);
        return 0;
    }
    for (topology.items(), 0..) |monitor, at| if (monitor.key.eql(state.display)) return @intCast(at);
    const width: u32 = @intFromFloat(@min(@as(f64, std.math.maxInt(i32)), @ceil(@as(f64, @floatFromInt(state.normal.width)) * state.units_per_dip)));
    const height: u32 = @intFromFloat(@min(@as(f64, std.math.maxInt(i32)), @ceil(@as(f64, @floatFromInt(state.normal.height)) * state.units_per_dip)));
    const old: Rect = .{ .x = state.normal.position.x, .y = state.normal.position.y, .width = width, .height = height };
    var best: u8 = 0;
    var area: u64 = 0;
    var nearest = std.math.inf(f64);
    for (topology.items(), 0..) |monitor, at| {
        const next = overlap(old, monitor.work);
        const dist = distance(state.normal.position, monitor.work);
        if (next > area or (next == area and (dist < nearest or (dist == nearest and monitor.primary and !topology.monitors[best].primary)))) {
            best = @intCast(at);
            area = next;
            nearest = dist;
        }
    }
    return best;
}
pub fn resolve(state: State, topology: *const Topology, metrics: Metrics, constraints: Constraints) !Plan {
    const index = try choose(state, topology);
    return resolveOn(state, topology, index, metrics, constraints);
}
pub fn validateConstraints(constraints: Constraints) !void {
    if (constraints.min_width == 0 or constraints.min_height == 0 or constraints.max_width > 32768 or constraints.max_height > 32768 or constraints.min_width > constraints.max_width or constraints.min_height > constraints.max_height) return error.InvalidConstraints;
}
pub fn resolveOn(state: State, topology: *const Topology, index: u8, metrics: Metrics, constraints: Constraints) !Plan {
    try state.validate();
    try validScale(metrics.units_per_dip);
    if (index >= topology.count) return error.InvalidDisplay;
    try validateConstraints(constraints);
    const monitor = topology.monitors[index];
    const insets = metrics.insets;
    const available_width = @as(i64, monitor.work.width) - insets.left - insets.right;
    const available_height = @as(i64, monitor.work.height) - insets.top - insets.bottom;
    if (available_width <= 0 or available_height <= 0) return error.ConstraintsUnsatisfiable;
    const max_width: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(constraints.max_width)), @floor(@as(f64, @floatFromInt(available_width)) / metrics.units_per_dip)));
    const max_height: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(constraints.max_height)), @floor(@as(f64, @floatFromInt(available_height)) / metrics.units_per_dip)));
    if (max_width < constraints.min_width or max_height < constraints.min_height) return error.ConstraintsUnsatisfiable;
    const width = std.math.clamp(state.normal.width, constraints.min_width, max_width);
    const height = std.math.clamp(state.normal.height, constraints.min_height, max_height);
    const native_width: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(width)) * metrics.units_per_dip));
    const native_height: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(height)) * metrics.units_per_dip));
    const left = @as(i64, monitor.work.x) + insets.left;
    const top = @as(i64, monitor.work.y) + insets.top;
    const right = monitor.work.right() - insets.right - native_width;
    const bottom = monitor.work.bottom() - insets.bottom - native_height;
    const same = state.space == topology.space and state.display.eql(monitor.key);
    const x: f64 = if (same) @as(f64, @floatFromInt(monitor.work.x)) + @as(f64, @floatFromInt(@as(i64, state.normal.position.x) - state.work.x)) / state.units_per_dip * metrics.units_per_dip else @as(f64, @floatFromInt(left)) + @as(f64, @floatFromInt(right - left)) / 2;
    const y: f64 = if (same) @as(f64, @floatFromInt(monitor.work.y)) + @as(f64, @floatFromInt(@as(i64, state.normal.position.y) - state.work.y)) / state.units_per_dip * metrics.units_per_dip else @as(f64, @floatFromInt(top)) + @as(f64, @floatFromInt(bottom - top)) / 2;
    const position: Point = .{ .x = @intFromFloat(std.math.clamp(@round(x), @as(f64, @floatFromInt(left)), @as(f64, @floatFromInt(right)))), .y = @intFromFloat(std.math.clamp(@round(y), @as(f64, @floatFromInt(top)), @as(f64, @floatFromInt(bottom)))) };
    return .{ .bounds = .{ .position = position, .width = width, .height = height }, .display_index = index, .maximized = state.maximized, .fullscreen = state.fullscreen, .always_on_top = state.always_on_top, .recovered = !same or width != state.normal.width or height != state.normal.height or !std.meta.eql(position, state.normal.position) or state.units_per_dip != metrics.units_per_dip };
}

/// Smallest frame overlap, in native desktop units per axis, that keeps a
/// window reachable with a pointer. Smaller frames must overlap entirely.
pub const min_reachable = 48;
pub const Reach = enum { contained, partial, offscreen };
/// Classifies a native frame against current workareas. A frame that no single
/// workarea overlaps by min_reachable on both axes is offscreen.
pub fn reach(frame: Rect, topology: *const Topology) !Reach {
    try frame.validate();
    if (topology.count == 0 or topology.count > max_monitors) return error.NoDisplays;
    const need_width = @min(frame.width, min_reachable);
    const need_height = @min(frame.height, min_reachable);
    var result: Reach = .offscreen;
    for (topology.items()) |monitor| {
        const work = monitor.work;
        if (frame.x >= work.x and frame.y >= work.y and frame.right() <= work.right() and frame.bottom() <= work.bottom()) return .contained;
        const width = @min(frame.right(), work.right()) - @max(@as(i64, frame.x), work.x);
        const height = @min(frame.bottom(), work.bottom()) - @max(@as(i64, frame.y), work.y);
        if (width >= need_width and height >= need_height) result = .partial;
    }
    return result;
}

pub const Entry = struct { key: Key, state: State };
/// Caller storage; no allocator, callbacks, filesystem, hidden cache or Window.
/// The caller serializes access and keeps storage alive through every use.
pub const Store = struct {
    storage: []Entry,
    count: usize = 0,
    pub fn init(storage: []Entry) !Store {
        if (storage.len == 0 or storage.len > max_entries) return error.InvalidCapacity;
        return .{ .storage = storage };
    }
    pub fn items(self: *const Store) []const Entry {
        return self.storage[0..self.count];
    }
    pub fn get(self: *const Store, key: Key) ?State {
        for (self.items()) |entry| if (entry.key.eql(key)) return entry.state;
        return null;
    }
    pub fn put(self: *Store, key: Key, state: State) !void {
        try key.validate();
        try state.validate();
        for (self.storage[0..self.count]) |*entry| if (entry.key.eql(key)) {
            entry.state = state;
            return;
        };
        if (self.count == self.storage.len) return error.CapacityExceeded;
        self.storage[self.count] = .{ .key = key, .state = state };
        self.count += 1;
    }
    pub fn remove(self: *Store, key: Key) bool {
        for (self.items(), 0..) |entry, at| if (entry.key.eql(key)) {
            std.mem.copyForwards(Entry, self.storage[at .. self.count - 1], self.storage[at + 1 .. self.count]);
            self.count -= 1;
            return true;
        };
        return false;
    }
};
