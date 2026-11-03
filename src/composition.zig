const std = @import("std");
const z = @import("root.zig");

pub const max_regions = 256;
pub const Options = struct { capacity: u16 = 16 };
pub const Viewport = struct {
    /// The region's box as it shows, in the window's DIPs.
    bounds: z.Rect,
    visible: bool = true,
    /// The size the region's content lays out at, in its own DIPs, such
    /// as a page's box before a scale of the transforms around it: the
    /// content then shows in `bounds` scaled as a picture of it. Zero is
    /// `bounds`' size.
    layout_width: f32 = 0,
    layout_height: f32 = 0,
    /// The radii of the content's corners, in its own DIPs, from its
    /// top-left clockwise: it shows, and takes the pointer, inside them.
    radii: [4]f32 = @splat(0),

    /// The size the content lays out at.
    pub fn layoutSize(self: Viewport) [2]f32 {
        if (self.layout_width <= 0 or self.layout_height <= 0) return .{ self.bounds.width, self.bounds.height };
        return .{ self.layout_width, self.layout_height };
    }
    /// How much `bounds` scales the content: 1, 1 unless a transform
    /// scales it.
    pub fn scale(self: Viewport) [2]f32 {
        const size = self.layoutSize();
        if (size[0] <= 0 or size[1] <= 0) return .{ 1, 1 };
        return .{ self.bounds.width / size[0], self.bounds.height / size[1] };
    }
    pub fn rounded(self: Viewport) bool {
        return !std.mem.allEqual(f32, &self.radii, 0);
    }
    /// Whether a point of the window is the region's: in its box and
    /// inside its corners.
    pub fn contains(self: Viewport, point: z.Point) bool {
        if (!self.bounds.contains(point)) return false;
        if (!self.rounded()) return true;
        const size = self.layoutSize();
        const factor = self.scale();
        if (factor[0] <= 0 or factor[1] <= 0) return false;
        return insideCorners(size[0], size[1], self.radii, (point.x - self.bounds.x) / factor[0], (point.y - self.bounds.y) / factor[1]);
    }
};

/// Whether `x`, `y` is inside the corners of `radii` (from the top-left
/// clockwise) of a box `width` by `height` at the origin.
pub fn insideCorners(width: f32, height: f32, radii: [4]f32, x: f32, y: f32) bool {
    const sides = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    for (radii, sides) |radius, side| {
        if (radius <= 0) continue;
        const cx = radius + side[0] * (width - 2 * radius);
        const cy = radius + side[1] * (height - 2 * radius);
        const dx = x - cx;
        const dy = y - cy;
        // Only the corner's own square is cut.
        if ((side[0] == 0) != (dx < 0) or (side[1] == 0) != (dy < 0)) continue;
        if (dx * dx + dy * dy > radius * radius) return false;
    }
    return true;
}
pub const Kind = enum { native, backdrop };
pub const Snapshot = struct { window: z.Window, viewport: Viewport, kind: Kind, size: z.Size };

/// Every callback runs on the owner thread. Attach/update prepare their own
/// native candidates and roll back on error. A successful attach transfers one
/// detach obligation. Detach receives an already invalid Region; use cached
/// resources/window rather than beginning another callback through that handle.
pub const Participant = struct {
    context: *anyopaque,
    attach: *const fn (*anyopaque, Region) anyerror!void,
    update: *const fn (*anyopaque, Region, Viewport) anyerror!void,
    detach: *const fn (*anyopaque, Region) void,
    event: ?*const fn (*anyopaque, Region, z.Event) void = null,
    key_input: ?*const fn (*anyopaque, Region, z.KeyInput) bool = null,
    accessibility: ?*const fn (*anyopaque, Region, usize, isize) ?isize = null,
    /// Native child evacuation only; no allocation, COM or business callbacks.
    /// Region may already be invalid. Cache native transport at attach time.
    native_parent_destroying: ?*const fn (*anyopaque, Region) void = null,
};
const Key = struct { index: u16, generation: u64 };
const Phase = enum { free, reserved, attaching, attached, removing };
const Entry = struct {
    generation: u64 = 0,
    phase: Phase = .free,
    kind: Kind = .native,
    viewport: Viewport = .{ .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 } },
    participant: ?Participant = null,
    /// The wheel over this region goes to the backdrop (`passWheel`).
    pass_wheel: bool = false,
    pins: usize = 0,
    previous: ?u16 = null,
    next: ?u16 = null,
};
const State = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread.Id,
    window: z.Window,
    size: z.Size,
    entries: []Entry,
    attached: bool = true,
    mutating: bool = false,
    draining: bool = false,
    focusing: bool = false,
    focus_dirty: bool = false,
    callbacks: usize = 0,
    first: ?u16 = null,
    last: ?u16 = null,
    backdrop: ?Key = null,
    focused: ?Key = null,
    captured: ?Key = null,

    fn owner(self: *State) *Owner {
        return @ptrCast(self);
    }
    fn region(self: *State, index: u16) Region {
        return .{ .owner = self.owner(), .index = index, .generation = self.entries[index].generation };
    }
    fn entry(self: *State, key: Key) ?*Entry {
        if (key.index >= self.entries.len) return null;
        const value = &self.entries[key.index];
        if (value.generation != key.generation or value.phase == .free or value.phase == .removing) return null;
        return value;
    }
    fn fullViewport(self: *const State) Viewport {
        return .{ .bounds = .{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(self.size.width)) / self.size.scale, .height = @as(f32, @floatFromInt(self.size.height)) / self.size.scale } };
    }
    fn unlink(self: *State, index: u16) void {
        const value = &self.entries[index];
        if (value.previous) |previous| self.entries[previous].next = value.next else self.first = value.next;
        if (value.next) |next| self.entries[next].previous = value.previous else self.last = value.previous;
        value.previous = null;
        value.next = null;
    }
    fn drain(self: *State) void {
        if (self.callbacks != 0 or self.mutating or self.draining) return;
        self.draining = true;
        defer {
            self.draining = false;
            self.settleFocus();
        }
        // Native regions are detached in reverse reservation order; the full
        // window backdrop remains alive until all native children have gone.
        while (true) {
            var cursor = self.last;
            var selected: ?u16 = null;
            while (cursor) |index| {
                const value = &self.entries[index];
                if (value.phase == .removing and value.kind != .backdrop and value.pins == 0) {
                    selected = index;
                    break;
                }
                cursor = value.previous;
            }
            if (selected == null) if (self.backdrop) |key| {
                const value = &self.entries[key.index];
                if (value.generation == key.generation and value.phase == .removing and value.pins == 0) selected = key.index;
            };
            const index = selected orelse break;
            const value = &self.entries[index];
            const participant = value.participant;
            value.participant = null;
            if (participant) |provider| provider.detach(provider.context, self.region(index));
            self.unlink(index);
            if (same(self.backdrop, .{ .index = index, .generation = value.generation })) self.backdrop = null;
            value.phase = .free;
        }
    }
    fn remove(self: *State, key: Key) bool {
        const value = self.entry(key) orelse return false;
        value.phase = .removing;
        if (same(self.focused, key)) {
            self.focused = null;
            self.focus_dirty = true;
        }
        if (same(self.captured, key)) self.captured = null;
        return true;
    }
    fn stop(self: *State) void {
        self.attached = false;
        var cursor = self.first;
        while (cursor) |index| {
            const value = &self.entries[index];
            value.phase = .removing;
            cursor = value.next;
        }
        self.focused = null;
        self.focus_dirty = false;
        self.captured = null;
        self.drain();
    }
    fn keys(self: *State, buffer: *[max_regions]Key) []const Key {
        var count: usize = 0;
        var cursor = self.first;
        while (cursor) |index| {
            const value = &self.entries[index];
            if (value.phase == .attached) {
                buffer[count] = .{ .index = index, .generation = value.generation };
                count += 1;
            }
            cursor = value.next;
        }
        return buffer[0..count];
    }
    fn deliver(self: *State, key: Key, input: z.Event) void {
        const value = self.entry(key) orelse return;
        if (value.phase != .attached) return;
        const callback = value.participant.?.event orelse return;
        const handle = self.region(key.index);
        const scope = handle.beginCallback() orelse return;
        defer scope.end();
        callback(value.participant.?.context, handle, input);
    }
    fn keyboard(self: *State) ?Key {
        if (self.focused) |key| if (self.entry(key)) |value| {
            if (value.phase == .attached and interactive(value.viewport)) return key;
        };
        if (self.backdrop) |key| if (self.entry(key)) |value| {
            if (value.phase == .attached and interactive(value.viewport)) return key;
        };
        return null;
    }
    // Call only while a Window/Region callback scope protects this Owner.
    fn settleFocus(self: *State) void {
        if (!self.focus_dirty or self.focusing or self.mutating or self.draining) return;
        self.focus_dirty = false;
        if (!self.attached or self.window.isClosed()) return;
        const selected = self.keyboard() orelse return;
        self.focusing = true;
        defer self.focusing = false;
        self.deliver(selected, .{ .focus = true });
    }
    fn hit(self: *State, point: z.Point) ?Key {
        var cursor = self.last;
        while (cursor) |index| {
            const value = &self.entries[index];
            if (value.phase == .attached and value.kind == .native and interactive(value.viewport) and value.viewport.contains(point)) return .{ .index = index, .generation = value.generation };
            cursor = value.previous;
        }
        if (self.backdrop) |key| if (self.entry(key)) |value| {
            if (value.phase == .attached and interactive(value.viewport) and value.viewport.contains(point)) return key;
        };
        return null;
    }
    fn pointerRecipient(self: *State, point: z.Point) ?Key {
        if (self.captured) |key| if (self.entry(key)) |value| {
            if (value.phase == .attached and interactive(value.viewport)) return key;
        };
        self.captured = null;
        return self.hit(point);
    }
    fn event(context: *anyopaque, _: z.Window, input: z.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.callbacks += 1;
        defer {
            self.callbacks -= 1;
            self.drain();
        }
        if (!self.attached) return;
        switch (input) {
            .paint => |paint| self.size = paint.size,
            .resize => |size| self.size = size,
            else => {},
        }
        switch (input) {
            .paint, .resize, .window_state, .window_position, .cancel_input => {
                if (input == .cancel_input) self.captured = null;
                var buffer: [max_regions]Key = undefined;
                const selected = self.keys(&buffer);
                if (self.backdrop) |key| {
                    if (self.entry(key)) |value| value.viewport = self.fullViewport();
                    self.deliver(key, input);
                }
                for (selected) |key| {
                    if (!self.attached or self.window.isClosed()) break;
                    if (!same(self.backdrop, key)) self.deliver(key, input);
                }
            },
            .pointer_down => |pointer| {
                const key = self.hit(pointer.position) orelse return;
                self.captured = key;
                self.deliver(key, input);
            },
            .pointer_up, .pointer_move => {
                const point = if (input == .pointer_up) input.pointer_up.position else input.pointer_move;
                const key = self.pointerRecipient(point) orelse return;
                if (input == .pointer_up) self.captured = null;
                self.deliver(key, input);
            },
            .wheel => |wheel| if (self.hit(wheel.position)) |key| {
                // A region that passes the wheel on gives it to the native
                // UI around it, the backdrop.
                const target = if (self.entry(key)) |value| (if (value.pass_wheel) self.backdrop orelse key else key) else key;
                self.deliver(target, input);
            },
            .focus => |focused| {
                if (!focused) self.captured = null;
                if (self.keyboard()) |key| self.deliver(key, input);
            },
            else => if (self.keyboard()) |key| self.deliver(key, input),
        }
    }
    fn keyInput(context: *anyopaque, _: z.Window, key: z.KeyInput) bool {
        const self: *State = @ptrCast(@alignCast(context));
        const selected = self.keyboard() orelse return false;
        const value = self.entry(selected) orelse return false;
        const callback = value.participant.?.key_input orelse return false;
        const handle = self.region(selected.index);
        const scope = handle.beginCallback() orelse return true;
        defer scope.end();
        return callback(value.participant.?.context, handle, key);
    }
    fn accessibility(context: *anyopaque, _: z.Window, wp: usize, lp: isize) ?isize {
        const self: *State = @ptrCast(@alignCast(context));
        const selected = self.backdrop orelse return null;
        const value = self.entry(selected) orelse return null;
        if (value.phase != .attached) return null;
        const callback = value.participant.?.accessibility orelse return null;
        const handle = self.region(selected.index);
        const scope = handle.beginCallback() orelse return null;
        defer scope.end();
        return callback(value.participant.?.context, handle, wp, lp);
    }
    fn detach(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.stop();
    }
    fn parentDestroying(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        // The record's internal scope pins Window/Content even though ordinary
        // Region callbacks can no longer begin. Include pending detach owners.
        self.callbacks += 1;
        // Ordinary provider detach may call COM. Leave it to the normal
        // teardown/scope safe point, outside this native-only notification.
        defer self.callbacks -= 1;
        var cursor = self.last;
        while (cursor) |index| {
            const item = &self.entries[index];
            cursor = item.previous;
            if (item.participant) |participant| if (participant.native_parent_destroying) |notify| notify(participant.context, self.region(index));
        }
    }
};

fn same(a: ?Key, b: Key) bool {
    return if (a) |key| key.index == b.index and key.generation == b.generation else false;
}
fn interactive(viewport: Viewport) bool {
    return viewport.visible and viewport.bounds.width > 0 and viewport.bounds.height > 0;
}
fn validate(viewport: Viewport) !void {
    const b = viewport.bounds;
    for ([_]f32{ b.x, b.y, b.width, b.height, b.x + b.width, b.y + b.height }) |value| if (!std.math.isFinite(value) or @abs(value) > 1000000) return error.InvalidViewport;
    if (b.width < 0 or b.height < 0) return error.InvalidViewport;
    for ([_]f32{ viewport.layout_width, viewport.layout_height } ++ viewport.radii) |value| if (!std.math.isFinite(value) or value < 0 or value > 1000000) return error.InvalidViewport;
}

/// Sole Window.Content owner. App and Owner outlive all copied Region handles.
/// Slots are allocated once; dispatch, geometry changes and removals allocate
/// no framework memory. The optional modules own their native resources.
pub const Owner = opaque {
    fn state(self: *Owner) !*State {
        const value: *State = @ptrCast(@alignCast(self));
        if (value.thread != std.Thread.getCurrentId()) return error.WrongThread;
        return value;
    }
    pub fn create(allocator: std.mem.Allocator, target: z.Window, options: Options) !*Owner {
        target.app.assertOwner();
        if (options.capacity == 0 or options.capacity > max_regions) return error.InvalidLimits;
        const scope = target.beginCallback() orelse return error.Closed;
        defer scope.end();
        const size = try target.contentSize();
        const value = try allocator.create(State);
        errdefer allocator.destroy(value);
        const entries = try allocator.alloc(Entry, options.capacity);
        errdefer allocator.free(entries);
        @memset(entries, .{});
        value.* = .{ .allocator = allocator, .thread = std.Thread.getCurrentId(), .window = target, .size = size, .entries = entries };
        try target.setContent(.{ .context = value, .event = State.event, .detach = State.detach, .key_input = State.keyInput, .accessibility = State.accessibility, .native_parent_destroying = State.parentDestroying });
        return value.owner();
    }
    pub fn window(self: *Owner) !z.Window {
        const value = try self.state();
        if (!value.attached or value.window.isClosed()) return error.Closed;
        return value.window;
    }
    pub fn reserve(self: *Owner, viewport: Viewport) !Region {
        try validate(viewport);
        return self.reserveKind(.native, viewport);
    }
    pub fn reserveBackdrop(self: *Owner) !Region {
        const value = try self.state();
        if (value.backdrop != null) return error.BackdropAlreadyReserved;
        return self.reserveKind(.backdrop, value.fullViewport());
    }
    fn reserveKind(self: *Owner, kind: Kind, viewport: Viewport) !Region {
        const value = try self.state();
        if (!value.attached or value.window.isClosed()) return error.Closed;
        if (value.mutating or value.draining) return error.Busy;
        for (value.entries, 0..) |*item, index| {
            if (item.phase != .free or item.generation == std.math.maxInt(u64)) continue;
            item.generation += 1;
            item.phase = .reserved;
            item.viewport = viewport;
            item.kind = kind;
            item.pass_wheel = false;
            item.previous = value.last;
            item.next = null;
            if (value.last) |last| value.entries[last].next = @intCast(index) else value.first = @intCast(index);
            value.last = @intCast(index);
            const result = value.region(@intCast(index));
            if (kind == .backdrop) value.backdrop = result.key();
            return result;
        }
        return error.RegionCapacityExceeded;
    }
    /// Explicit keyboard recipient; native focus/Tab integration is separate.
    pub fn focus(self: *Owner, region: ?Region) !void {
        const value = try self.state();
        if (!value.attached or value.window.isClosed()) return error.Closed;
        if (value.focusing or value.mutating or value.draining) return error.Busy;
        const next: ?Key = if (region) |handle| blk: {
            if (handle.owner != self) return error.ForeignOwner;
            const item = value.entry(handle.key()) orelse return error.Closed;
            if (item.phase != .attached or !interactive(item.viewport)) return error.NotAttached;
            break :blk handle.key();
        } else null;
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.callbacks += 1;
        value.focusing = true;
        defer {
            value.focusing = false;
            value.settleFocus();
            value.callbacks -= 1;
            value.drain();
        }
        const old = value.keyboard();
        value.focused = next;
        const current = value.keyboard();
        const blurred = if (old) |key| current == null or !same(current, key) else false;
        if (old) |key| if (blurred) value.deliver(key, .{ .focus = false });
        if (value.window.isClosed()) return;
        value.focus_dirty = false;
        if (value.keyboard()) |key| if (old == null or blurred or !same(old, key)) value.deliver(key, .{ .focus = true });
    }
    /// Detaches all participants synchronously outside callbacks. Window close
    /// performs the same teardown after Window/Region callback pins unwind.
    pub fn detach(self: *Owner) !void {
        const value = try self.state();
        if (!value.attached) return;
        if (value.callbacks != 0 or value.mutating or value.draining) return error.Busy;
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.window.cancelContent(value);
        value.stop();
    }
    pub fn close(self: *Owner) !void {
        const value = try self.state();
        if (value.attached) return error.ContentAttached;
        if (value.callbacks != 0 or value.mutating or value.draining or value.first != null) return error.Busy;
        const allocator = value.allocator;
        allocator.free(value.entries);
        allocator.destroy(value);
    }
};

/// Copyable generation handle. Owner must outlive every use, including stale
/// checks. Removing it blocks new callbacks immediately; native cleanup waits
/// until the last acquired Scope and outer composition dispatch have ended.
pub const Region = struct {
    owner: *Owner,
    index: u16,
    generation: u64,
    fn key(self: Region) Key {
        return .{ .index = self.index, .generation = self.generation };
    }
    fn state(self: Region) !*State {
        const value = try self.owner.state();
        if (!value.attached or value.window.isClosed() or value.entry(self.key()) == null) return error.Closed;
        return value;
    }
    pub fn snapshot(self: Region) !Snapshot {
        const value = try self.state();
        const item = value.entry(self.key()).?;
        return .{ .window = value.window, .viewport = item.viewport, .kind = item.kind, .size = value.size };
    }
    pub fn attach(self: Region, participant: Participant) !void {
        const value = try self.state();
        if (value.mutating or value.draining) return error.Busy;
        const item = value.entry(self.key()).?;
        if (item.phase != .reserved) return error.AlreadyAttached;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        item.phase = .attaching;
        // Early parent destruction can occur inside provider attach. The
        // provisional table participates only in native evacuation, never in
        // ordinary dispatch, and does not transfer detach responsibility yet.
        item.participant = participant;
        value.mutating = true;
        defer {
            value.mutating = false;
            value.settleFocus();
        }
        participant.attach(participant.context, self) catch |err| {
            item.participant = null;
            if (item.phase != .removing) item.phase = .reserved;
            return err;
        };
        if (item.phase != .removing) item.phase = .attached;
    }
    /// Give the wheel over this region to the backdrop, the native UI around
    /// it, as a web view in a scroll container does: its native child sends
    /// the wheel to the window, which delivers it here.
    pub fn passWheel(self: Region, on: bool) !void {
        const value = try self.state();
        const item = value.entry(self.key()) orelse return error.Closed;
        item.pass_wheel = on;
    }
    pub fn update(self: Region, viewport: Viewport) !void {
        try validate(viewport);
        const value = try self.state();
        const item = value.entry(self.key()).?;
        if (item.kind == .backdrop) return error.AutomaticViewport;
        if (value.mutating or value.draining) return error.Busy;
        if (std.meta.eql(item.viewport, viewport)) return;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.mutating = true;
        defer {
            value.mutating = false;
            value.settleFocus();
        }
        if (item.participant) |participant| try participant.update(participant.context, self, viewport);
        if (value.entry(self.key()) == null or value.window.isClosed()) return error.Closed;
        const hiding = interactive(item.viewport) and !interactive(viewport);
        item.viewport = viewport;
        if (hiding) {
            const focused = same(value.focused, self.key());
            if (same(value.captured, self.key())) value.captured = null;
            if (focused) {
                value.focused = null;
                value.focus_dirty = true;
            }
            value.deliver(self.key(), .cancel_input);
            if (focused) {
                value.deliver(self.key(), .{ .focus = false });
            }
        }
    }
    pub fn remove(self: Region) !bool {
        const value = try self.owner.state();
        if (!value.attached or value.window.isClosed()) return false;
        const scope = value.window.beginCallback() orelse return false;
        defer scope.end();
        value.callbacks += 1;
        defer {
            value.settleFocus();
            value.callbacks -= 1;
            value.drain();
        }
        const changed = value.remove(self.key());
        return changed;
    }
    pub fn beginCallback(self: Region) ?Scope {
        const value = self.state() catch return null;
        if (value.draining) return null;
        const window_scope = value.window.beginCallback() orelse return null;
        value.entries[self.index].pins += 1;
        value.callbacks += 1;
        return .{ .window = value.window, .window_scope = window_scope, .state = value, .index = self.index };
    }
};

/// Linear callback guard: call end exactly once; do not copy or retain it.
pub const Scope = struct {
    window: z.Window,
    window_scope: z.CallbackScope,
    state: *State,
    index: u16,
    pub fn end(self: Scope) void {
        self.state.entries[self.index].pins -= 1;
        self.state.callbacks -= 1;
        self.state.drain();
        self.window_scope.end();
    }
};

test {
    _ = @import("composition_test.zig");
}
