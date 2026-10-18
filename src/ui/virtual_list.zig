const std = @import("std");
const ui = @import("ziggurat_ui");
const SelectionControl = @import("virtual_list_control.zig").Control(ControlAccess);
pub const Control = @import("virtual_list_mount.zig").Control(MountAccess);

pub const Row = struct { id: u64, height: f32 };
pub const max_rows = 1_000_000;
pub const ticks_per_dip = 64;
pub const Limits = struct {
    rows: usize = 100_000,
    owned_bytes: usize = 64 * 1024 * 1024,
    peak_bytes: usize = 128 * 1024 * 1024,
    fn validate(self: Limits) !void {
        if (self.rows == 0 or self.rows > max_rows or self.owned_bytes < @sizeOf(State) or self.owned_bytes > 64 * 1024 * 1024 or self.peak_bytes < self.owned_bytes or self.peak_bytes > 128 * 1024 * 1024) return error.InvalidLimits;
    }
};
pub const BuildStats = struct { rows: usize, owned_bytes: usize, peak_owned_bytes: usize, fenwick_nodes: usize, elapsed_ns: ?u64 };
pub const Range = struct { first: usize = 0, end: usize = 0 };
pub const Anchor = struct { id: u64 = 0, old_index: usize = 0, intra_offset: f64 = 0, global_end: bool = false };
pub const Alignment = enum { nearest, start, center, end };
pub const DrawOptions = struct { overscan: u8 = 2, max_visible: u16 = 128 };
pub const RowView = struct {
    id: u64,
    index: usize,
    height: f32,
    top: f64,
    /// Coordinates share the caller's Frame offset. Global row offsets are
    /// subtracted in f64 before entering the f32 drawing coordinate space.
    bounds: ui.Rect,
    visible_bounds: ui.Rect,
};
pub const RowRenderer = struct { context: *anyopaque, draw: *const fn (*anyopaque, *ui.Frame, RowView) anyerror!void };

/// One owning pointer; copies are borrows. The supplied process-main-thread
/// identity is mandatory, and all calls (including close) require that owner.
/// No selection, text, estimated measurement, worker or timer is retained.
pub const List = opaque {
    pub fn create(allocator: std.mem.Allocator, process_main_thread: std.Thread.Id, rows: []const Row, limits: Limits) !*List {
        return createFrozen(allocator.ptr, allocator.vtable, process_main_thread, rows.ptr, rows.len, limits.rows, limits.owned_bytes, limits.peak_bytes);
    }
    noinline fn createFrozen(allocator_ptr: *anyopaque, allocator_vtable: *const std.mem.Allocator.VTable, process_main_thread: std.Thread.Id, rows_ptr: [*]const Row, count_: usize, max_rows_: usize, owned_bytes: usize, peak_bytes: usize) !*List {
        const allocator: std.mem.Allocator = .{ .ptr = allocator_ptr, .vtable = allocator_vtable };
        const rows = rows_ptr[0..count_];
        const limits: Limits = .{ .rows = max_rows_, .owned_bytes = owned_bytes, .peak_bytes = peak_bytes };
        try owner(process_main_thread);
        try limits.validate();
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .thread = process_main_thread, .limits = limits };
        state.index = try build(allocator, rows, limits, @sizeOf(State));
        return @ptrCast(state);
    }
    pub fn close(self: *List) !void {
        const state = try checked(self);
        if (state.busy) return error.Busy;
        const allocator = state.allocator;
        state.index.deinit(allocator);
        allocator.destroy(state);
    }
    pub fn replace(self: *List, rows: []const Row) !void {
        const state = try checked(self);
        if (state.busy) return error.Busy;
        const candidate = try build(state.allocator, rows, state.limits, @sizeOf(State) + state.index.bytes());
        const previous = state.index;
        state.index = candidate;
        previous.deinit(state.allocator);
    }
    /// Height is rounded upward to the next 1/64 DIP. Use row() to read the
    /// accepted value. Capture an anchor first to preserve the host's scroll.
    pub fn setHeight(self: *List, id: u64, height: f32) !bool {
        const state = try checked(self);
        if (state.busy) return error.Busy;
        const value = try heightTicks(height);
        const index = state.index.find(id) orelse return error.UnknownRow;
        const old = state.index.rows[index].height;
        if (old == value) return false;
        _ = state.index.update(index, value);
        return true;
    }
    pub fn count(self: *const List) !usize {
        return (try checked(self)).index.rows.len;
    }
    pub fn row(self: *const List, index: usize) !Row {
        const state = try checked(self);
        if (index >= state.index.rows.len) return error.InvalidIndex;
        const value = state.index.rows[index];
        return .{ .id = value.id, .height = @floatCast(dip(value.height)) };
    }
    pub fn indexOf(self: *const List, id: u64) !?usize {
        return (try checked(self)).index.find(id);
    }
    pub fn totalHeight(self: *const List) !f64 {
        return dip((try checked(self)).index.total);
    }
    pub fn rowTop(self: *const List, index: usize) !f64 {
        const state = try checked(self);
        if (index > state.index.rows.len) return error.InvalidIndex;
        return dip(state.index.prefix(index));
    }
    pub fn buildStats(self: *const List) !BuildStats {
        return (try checked(self)).index.stats;
    }
    pub fn clampScroll(self: *const List, scroll: f64, viewport: f64) !f64 {
        const state = try checked(self);
        try validScroll(scroll, viewport);
        return state.index.clamp(scroll, viewport);
    }
    /// Half-open rows intersecting a half-open viewport; no overscan or cap.
    pub fn visibleRange(self: *const List, scroll: f64, viewport: f64) !Range {
        const state = try checked(self);
        try validScroll(scroll, viewport);
        return state.index.visible(state.index.clamp(scroll, viewport), viewport);
    }
    pub fn anchor(self: *const List, scroll: f64, viewport: f64) !Anchor {
        const state = try checked(self);
        try validScroll(scroll, viewport);
        if (state.index.rows.len == 0) return .{ .global_end = viewport == 0 };
        const offset = state.index.clamp(scroll, viewport);
        const index = @min(state.index.locate(@intFromFloat(@floor(offset * ticks_per_dip))).index, state.index.rows.len - 1);
        return .{ .id = state.index.rows[index].id, .old_index = index, .intra_offset = offset - dip(state.index.prefix(index)), .global_end = viewport == 0 and offset == dip(state.index.total) };
    }
    /// Keep the ID when present. A removed ID chooses the same old index's
    /// successor, or the final row. Out-of-row insets clamp to its final tick.
    /// A captured zero-viewport global_end instead follows the new list end.
    pub fn resolve(self: *const List, place: Anchor, viewport: f64) !f64 {
        const state = try checked(self);
        try validScroll(place.intra_offset, viewport);
        if (place.intra_offset < 0) return error.InvalidAnchor;
        if (state.index.rows.len == 0) return 0;
        if (place.global_end) return state.index.clamp(dip(state.index.total), viewport);
        const index = state.index.find(place.id) orelse @min(place.old_index, state.index.rows.len - 1);
        const height = dip(state.index.rows[index].height);
        const inset = if (place.intra_offset < height) place.intra_offset else height - @as(f64, 1) / ticks_per_dip;
        return state.index.clamp(dip(state.index.prefix(index)) + inset, viewport);
    }
    pub fn reveal(self: *const List, id: u64, scroll: f64, viewport: f64, alignment: Alignment) !f64 {
        const state = try checked(self);
        try validScroll(scroll, viewport);
        const index = state.index.find(id) orelse return error.UnknownRow;
        const offset = state.index.clamp(scroll, viewport);
        const top = dip(state.index.prefix(index));
        const height = dip(state.index.rows[index].height);
        const target = switch (alignment) {
            .start => top,
            .center => top + (height - viewport) * 0.5,
            .end => top + height - viewport,
            .nearest => if (height > viewport or top < offset) top else if (top + height > offset + viewport) top + height - viewport else offset,
        };
        return state.index.clamp(target, viewport);
    }
    /// Call only within the host's explicit draw stage. The callback borrows
    /// this List; close/replace/setHeight/nested render fail with Busy until it
    /// returns. Owner/Busy/closed-scope rejection leaves Frame untouched; draw
    /// and parameter errors poison its transaction even if the host catches.
    pub fn render(self: *List, frame: *ui.Frame, bounds: ui.Rect, scroll: f64, options: DrawOptions, renderer: RowRenderer) anyerror!Range {
        const state = try checked(self);
        if (state.busy) return error.Busy;
        if (frame.failure) |failure| return @as(anyerror!Range, failure);
        const window = frame.context.window orelse return error.Closed;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        errdefer |err| frame.failure = frame.failure orelse err;
        if (!ui.layout.validRect(bounds)) return error.InvalidGeometry;
        try validScroll(scroll, bounds.height);
        if (options.overscan > 16 or options.max_visible == 0 or options.max_visible > 128) return error.InvalidDrawOptions;
        const offset = state.index.clamp(scroll, bounds.height);
        const visible = state.index.visible(offset, bounds.height);
        if (bounds.width == 0) return .{};
        if (visible.first == visible.end) return visible;
        const range: Range = .{ .first = visible.first -| options.overscan, .end = @min(state.index.rows.len, visible.end + options.overscan) };
        if (range.end - range.first > options.max_visible) return error.VisibleCapacityExceeded;
        state.busy = true;
        defer state.busy = false;
        const saved = frame.*;
        defer {
            while (frame.clips.len > saved.clips.len) frame.popClip() catch |err| {
                frame.failure = frame.failure orelse err;
                break;
            };
            frame.clips = saved.clips;
            frame.offset = saved.offset;
            frame.offsets = saved.offsets;
            frame.offset_depth = saved.offset_depth;
        }
        try frame.pushClip(bounds);
        var top = state.index.prefix(range.first);
        for (range.first..range.end) |index| {
            const value = state.index.rows[index];
            const y = @as(f64, bounds.y) + (dip(top) - offset);
            const height = dip(value.height);
            const clipped_top = @max(@as(f64, bounds.y), y);
            const clipped_bottom = @min(@as(f64, bounds.y) + bounds.height, y + height);
            try renderer.draw(renderer.context, frame, .{ .id = value.id, .index = index, .top = dip(top), .height = @floatCast(height), .bounds = .{ .x = bounds.x, .y = @floatCast(y), .width = bounds.width, .height = @floatCast(height) }, .visible_bounds = .{ .x = bounds.x, .y = @floatCast(clipped_top), .width = bounds.width, .height = @floatCast(@max(0, clipped_bottom - clipped_top)) } });
            if (frame.failure) |failure| return @as(anyerror!Range, failure);
            if (window.isClosed()) return error.Closed;
            if (frame.clips.len != saved.clips.len + 1 or frame.offset_depth != saved.offset_depth or !std.meta.eql(frame.offset, saved.offset)) return error.UnbalancedRowFrame;
            top += value.height;
        }
        try frame.popClip();
        return range;
    }
};

const Stored = struct { id: u64, height: u64 };
const Identity = struct { id: u64, index: usize };
const Search = struct { index: usize, nodes: usize };
const Index = struct {
    rows: []Stored = &.{},
    tree: []u64 = &.{},
    ids: []Identity = &.{},
    total: u64 = 0,
    stats: BuildStats = undefined,
    fn bytes(self: *const Index) usize {
        return self.rows.len * @sizeOf(Stored) + self.tree.len * @sizeOf(u64) + self.ids.len * @sizeOf(Identity);
    }
    fn deinit(self: *const Index, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        allocator.free(self.tree);
        allocator.free(self.ids);
    }
    fn find(self: *const Index, id: u64) ?usize {
        var lo: usize = 0;
        var hi = self.ids.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.ids[mid].id < id) lo = mid + 1 else hi = mid;
        }
        return if (lo < self.ids.len and self.ids[lo].id == id) self.ids[lo].index else null;
    }
    fn prefix(self: *const Index, count_: usize) u64 {
        var at = count_;
        var value: u64 = 0;
        while (at != 0) : (at -= lowbit(at)) value += self.tree[at];
        return value;
    }
    fn update(self: *Index, index: usize, height: u64) usize {
        const old = self.rows[index].height;
        self.rows[index].height = height;
        var at = index + 1;
        var nodes: usize = 0;
        while (at <= self.rows.len) : (at += lowbit(at)) {
            if (height > old) self.tree[at] += height - old else self.tree[at] -= old - height;
            nodes += 1;
        }
        if (height > old) self.total += height - old else self.total -= old - height;
        return nodes;
    }
    fn locate(self: *const Index, tick: u64) Search {
        var index: usize = 0;
        var sum: u64 = 0;
        var step: usize = 1;
        while (step <= self.rows.len / 2) step *= 2;
        var nodes: usize = 0;
        while (step != 0) : (step /= 2) {
            const next = index + step;
            if (next <= self.rows.len) {
                nodes += 1;
                if (sum + self.tree[next] <= tick) {
                    index = next;
                    sum += self.tree[next];
                }
            }
        }
        return .{ .index = index, .nodes = nodes };
    }
    fn clamp(self: *const Index, offset: f64, viewport: f64) f64 {
        const total = dip(self.total);
        var maximum = @max(0, total - viewport);
        // A positive viewport must not clamp to the terminal point merely
        // because subtraction rounded back to total. Zero viewport may do so.
        if (viewport > 0 and total > 0 and maximum == total) maximum = std.math.nextAfter(f64, total, 0);
        return std.math.clamp(offset, 0, maximum);
    }
    fn locateEnd(self: *const Index, offset: f64, viewport: f64) usize {
        var index: usize = 0;
        var sum: u64 = 0;
        var step: usize = 1;
        while (step <= self.rows.len / 2) step *= 2;
        while (step != 0) : (step /= 2) {
            const next = index + step;
            if (next <= self.rows.len and beforeEnd(dip(sum + self.tree[next]), offset, viewport)) {
                index = next;
                sum += self.tree[next];
            }
        }
        return @min(self.rows.len, index + 1);
    }
    fn visible(self: *const Index, offset: f64, viewport: f64) Range {
        if (viewport == 0 or self.rows.len == 0) return .{};
        const start: u64 = @intFromFloat(@floor(offset * ticks_per_dip));
        return .{ .first = self.locate(start).index, .end = self.locateEnd(offset, viewport) };
    }
};
const State = struct { allocator: std.mem.Allocator, thread: std.Thread.Id, limits: Limits, index: Index = .{}, busy: bool = false };
// Private access to the one existing index implementation. The opt-in control
// owns a List; the ordinary List carries no selection or recipient fields.
const ControlAccess = struct {
    pub const Row = @import("virtual_list.zig").Row;
    pub const List = @import("virtual_list.zig").List;
    pub const Limits = @import("virtual_list.zig").Limits;
    pub const Candidate = Index;
    pub fn create(allocator: std.mem.Allocator, thread: std.Thread.Id, rows: []const @This().Row, limits: @This().Limits) !*@This().List {
        return @This().List.create(allocator, thread, rows, limits);
    }
    pub fn prepare(list: *@This().List, rows: []const @This().Row) !Candidate {
        const state = try checked(list);
        if (state.busy) return error.Busy;
        return build(state.allocator, rows, state.limits, @sizeOf(State) + state.index.bytes());
    }
    pub fn identities(list: *const @This().List) []const Identity {
        return (checked(list) catch unreachable).index.ids;
    }
    pub fn candidateIdentities(candidate: *const Candidate) []const Identity {
        return candidate.ids;
    }
    pub fn publish(list: *@This().List, candidate: Candidate) Candidate {
        const state = checked(list) catch unreachable;
        const old = state.index;
        state.index = candidate;
        return old;
    }
    pub fn release(list: *const @This().List, candidate: *Candidate) void {
        candidate.deinit((checked(list) catch unreachable).allocator);
    }
};
const MountAccess = struct {
    pub const SelectionControl = @import("virtual_list.zig").SelectionControl;
    pub const Row = @import("virtual_list.zig").Row;
    pub const List = @import("virtual_list.zig").List;
    pub const RowView = @import("virtual_list.zig").RowView;
    pub const DrawOptions = @import("virtual_list.zig").DrawOptions;
    pub const Range = @import("virtual_list.zig").Range;
    pub fn heightTicks(list: *const @This().List, index: usize) !u32 {
        const state = try checked(list);
        if (index >= state.index.rows.len) return error.InvalidIndex;
        return @intCast(state.index.rows[index].height);
    }
    pub fn identityAt(list: *const @This().List, index: usize) !Identity {
        const state = try checked(list);
        if (index >= state.index.ids.len) return error.InvalidIndex;
        return state.index.ids[index];
    }
};
fn checked(list: *const List) !*State {
    const state: *State = @ptrCast(@alignCast(@constCast(list)));
    try owner(state.thread);
    return state;
}

test {
    _ = @import("virtual_list_mount_tests.zig").Tests(Control);
    _ = @import("virtual_list_control_tests.zig").Tests(SelectionControl);
    _ = @import("virtual_list_catalog.zig");
    _ = @import("virtual_list_selection.zig");
}
fn owner(thread: std.Thread.Id) !void {
    if (std.Thread.getCurrentId() != thread) return error.WrongThread;
}
fn lowbit(value: usize) usize {
    return value & (~value + 1);
}
fn heightTicks(height: f32) !u64 {
    if (!std.math.isFinite(height) or height <= 0 or height > 1_000_000) return error.InvalidHeight;
    return @intFromFloat(@ceil(@as(f64, height) * ticks_per_dip));
}
fn dip(ticks: u64) f64 {
    return @as(f64, @floatFromInt(ticks)) / ticks_per_dip;
}
fn beforeEnd(prefix: f64, offset: f64, viewport: f64) bool {
    const distance = prefix - offset;
    if (distance != viewport) return distance < viewport;
    // Error-free TwoDiff residual resolves a strict boundary even if a tiny
    // positive offset was swallowed by prefix-offset. The usual large-offset
    // case is exact by subtraction; this equality case handles the converse.
    const virtual_offset = prefix - distance;
    const residual = (prefix - (distance + virtual_offset)) + (virtual_offset - offset);
    return residual < 0;
}
fn validScroll(scroll: f64, viewport: f64) !void {
    if (!std.math.isFinite(scroll) or !std.math.isFinite(viewport) or viewport < 0 or viewport > 1_000_000) return error.InvalidGeometry;
}
fn build(allocator: std.mem.Allocator, source: []const Row, limits: Limits, previous_bytes: usize) !Index {
    var timer = std.time.Timer.start() catch null;
    if (source.len > limits.rows) return error.RowCapacityExceeded;
    const bytes = source.len * (@sizeOf(Stored) + @sizeOf(Identity)) + (source.len + 1) * @sizeOf(u64);
    if (@sizeOf(State) + bytes > limits.owned_bytes or previous_bytes + bytes > limits.peak_bytes) return error.ByteCapacityExceeded;
    // Reject malformed input before allocating a candidate. Duplicate IDs need
    // the sorted candidate index; failure still leaves the old owner untouched.
    for (source) |row_| {
        if (row_.id == 0) return error.InvalidId;
        _ = try heightTicks(row_.height);
    }
    var result: Index = .{};
    result.rows = try allocator.alloc(Stored, source.len);
    errdefer allocator.free(result.rows);
    result.ids = try allocator.alloc(Identity, source.len);
    errdefer allocator.free(result.ids);
    result.tree = try allocator.alloc(u64, source.len + 1);
    errdefer allocator.free(result.tree);
    @memset(result.tree, 0);
    var nodes: usize = 0;
    for (source, 0..) |value, index| {
        const height = try heightTicks(value.height);
        result.rows[index] = .{ .id = value.id, .height = height };
        result.ids[index] = .{ .id = value.id, .index = index };
        result.total += height;
        result.tree[index + 1] += height;
        const next = index + 1 + lowbit(index + 1);
        if (next <= source.len) result.tree[next] += result.tree[index + 1];
        nodes += 1;
    }
    std.mem.sort(Identity, result.ids, {}, struct {
        fn less(_: void, a: Identity, b: Identity) bool {
            return a.id < b.id;
        }
    }.less);
    for (result.ids[0..result.ids.len -| 1], result.ids[@min(1, result.ids.len)..]) |a, b| if (a.id == b.id) return error.DuplicateId;
    result.stats = .{ .rows = source.len, .owned_bytes = @sizeOf(State) + bytes, .peak_owned_bytes = previous_bytes + bytes, .fenwick_nodes = nodes, .elapsed_ns = if (timer) |*clock| clock.read() else null };
    return result;
}

test "quantized heights, half-open fractional visibility, reveal and anchors" {
    const allocator = std.testing.allocator;
    const list = try List.create(allocator, std.Thread.getCurrentId(), &.{ .{ .id = 1, .height = 0.1 }, .{ .id = 2, .height = 20 }, .{ .id = 3, .height = 30 } }, .{});
    defer list.close() catch unreachable;
    try std.testing.expectEqual(@as(f32, 0.109375), (try list.row(0)).height);
    try std.testing.expectEqual(Range{ .first = 0, .end = 1 }, try list.visibleRange(0, 0.109375));
    try std.testing.expectEqual(Range{ .first = 1, .end = 2 }, try list.visibleRange(0.109375, 1));
    try std.testing.expectEqual(Range{ .first = 0, .end = 2 }, try list.visibleRange(0.1, 0.02));
    try std.testing.expectEqual(Range{}, try list.visibleRange(10, 0));
    try std.testing.expectEqual(@as(f64, 40.109375), try list.reveal(3, 0, 10, .end));
    const place = try list.anchor(5.109375, 10);
    try list.replace(&.{ .{ .id = 9, .height = 100 }, .{ .id = 3, .height = 30 }, .{ .id = 2, .height = 20 } });
    try std.testing.expectEqual(@as(f64, 135), try list.resolve(place, 10));
    try std.testing.expect(try list.setHeight(9, 200));
    try std.testing.expectEqual(@as(f64, 235), try list.resolve(place, 10));
    try list.replace(&.{ .{ .id = 9, .height = 200 }, .{ .id = 3, .height = 30 }, .{ .id = 4, .height = 8 } });
    // Missing anchor ID chooses old index 1, retaining its inset.
    try std.testing.expectEqual(@as(f64, 205), try list.resolve(place, 10));
    try std.testing.expectEqual(@as(f64, 188), try list.resolve(place, 50));
    try list.replace(&.{});
    try std.testing.expectEqual(@as(f64, 0), try list.resolve(place, 10));
    try std.testing.expectEqual(@as(usize, 0), try list.count());
}

test "candidate duplicate, malformed and allocation failures preserve the old index" {
    const initial = [_]Row{ .{ .id = 1, .height = 12 }, .{ .id = 2, .height = 13 } };
    for (0..3) |failure| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const list = try List.create(failing.allocator(), std.Thread.getCurrentId(), &initial, .{});
        defer list.close() catch unreachable;
        const before = try list.buildStats();
        failing.fail_index = failing.alloc_index + failure;
        try std.testing.expectError(error.OutOfMemory, list.replace(&.{ .{ .id = 9, .height = 1 }, .{ .id = 8, .height = 2 }, .{ .id = 7, .height = 3 } }));
        try std.testing.expectEqual(before, try list.buildStats());
        try std.testing.expectEqual(initial[1], try list.row(1));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectError(error.DuplicateId, list.replace(&.{ .{ .id = 5, .height = 1 }, .{ .id = 5, .height = 2 } }));
        try std.testing.expectError(error.InvalidId, list.replace(&.{.{ .id = 0, .height = 1 }}));
        try std.testing.expectError(error.InvalidHeight, list.setHeight(1, std.math.nan(f32)));
        try std.testing.expectError(error.InvalidHeight, list.setHeight(1, 0));
        try std.testing.expectError(error.InvalidHeight, list.setHeight(1, 1_000_001));
        try std.testing.expectEqual(before, try list.buildStats());
        try std.testing.expectEqual(@as(f64, 25), try list.totalHeight());
    }
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const list = try List.create(allocator, std.Thread.getCurrentId(), &initial, .{});
            defer list.close() catch unreachable;
            try list.replace(&.{.{ .id = 5, .height = 2 }});
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "row, owned and candidate peak budgets are checked transactionally" {
    const rows = [_]Row{ .{ .id = 1, .height = 1 }, .{ .id = 2, .height = 2 } };
    const bytes = @sizeOf(State) + 2 * (@sizeOf(Stored) + @sizeOf(Identity)) + 3 * @sizeOf(u64);
    try std.testing.expectError(error.RowCapacityExceeded, List.create(std.testing.allocator, std.Thread.getCurrentId(), &rows, .{ .rows = 1 }));
    try std.testing.expectError(error.ByteCapacityExceeded, List.create(std.testing.allocator, std.Thread.getCurrentId(), &rows, .{ .owned_bytes = bytes - 1 }));
    const list = try List.create(std.testing.allocator, std.Thread.getCurrentId(), &rows, .{ .owned_bytes = bytes, .peak_bytes = bytes });
    defer list.close() catch unreachable;
    try std.testing.expectError(error.ByteCapacityExceeded, list.replace(&rows));
    try std.testing.expectEqual(rows[0], try list.row(0));
}

test "Fenwick random update and visibility agree with a linear oracle without height drift" {
    var rows: [257]Row = undefined;
    var heights: [257]u64 = undefined;
    for (&rows, &heights, 0..) |*row_, *height, index| {
        height.* = 1 + index % 127;
        row_.* = .{ .id = index + 1, .height = @as(f32, @floatFromInt(height.*)) / 64 };
    }
    const list = try List.create(std.testing.allocator, std.Thread.getCurrentId(), &rows, .{});
    defer list.close() catch unreachable;
    var random = std.Random.DefaultPrng.init(0x71934ab1);
    const rng = random.random();
    for (0..3000) |_| {
        const at = rng.uintLessThan(usize, rows.len);
        const height = rng.uintLessThan(u64, 5000) + 1;
        heights[at] = height;
        _ = try list.setHeight(at + 1, @as(f32, @floatFromInt(height)) / 64);
        var total: u64 = 0;
        for (heights, 0..) |value, index| {
            try std.testing.expectEqual(dip(total), try list.rowTop(index));
            total += value;
        }
        try std.testing.expectEqual(dip(total), try list.totalHeight());
        const viewport: f64 = 31.1;
        const offset = std.math.clamp(rng.float(f64) * dip(total), 0, @max(0, dip(total) - viewport));
        var first: usize = 0;
        var end: usize = 0;
        var top: f64 = 0;
        var found = false;
        for (heights, 0..) |value, index| {
            const bottom = top + dip(value);
            if (bottom > offset and top < offset + viewport) {
                if (!found) first = index;
                end = index + 1;
                found = true;
            }
            top = bottom;
        }
        try std.testing.expectEqual(Range{ .first = first, .end = end }, try list.visibleRange(offset, viewport));
    }
    const original = try list.totalHeight();
    const previous = try list.row(0);
    for (0..10000) |_| {
        _ = try list.setHeight(1, 0.1);
        _ = try list.setHeight(1, previous.height);
    }
    try std.testing.expectEqual(original, try list.totalHeight());
}

test "one hundred thousand and one million rows use bounded logarithmic height walks" {
    for ([_]usize{ 100_000, 1_000_000 }) |length| {
        const rows = try std.testing.allocator.alloc(Row, length);
        defer std.testing.allocator.free(rows);
        for (rows, 0..) |*row_, index| row_.* = .{ .id = length - index, .height = if (length == 1_000_000) 1_000_000 else if (index % 2 == 0) 17.1 else 21.5 };
        const list = try List.create(std.testing.allocator, std.Thread.getCurrentId(), rows, .{ .rows = length });
        defer list.close() catch unreachable;
        const state = try checked(list);
        const search = state.index.locate(state.index.total / 2);
        try std.testing.expect(search.nodes <= 20);
        if (length == 1_000_000) {
            try std.testing.expectEqual(@as(f64, 1_000_000_000_000), try list.totalHeight());
            try std.testing.expectEqual(Range{ .first = length - 1, .end = length }, try list.visibleRange(999_999_000_000.125, 0.25));
            const boundary: f64 = 999_999_000_000;
            const previous = std.math.nextAfter(f64, boundary, 0);
            const gap = boundary - previous;
            const cases = [_]struct { offset: f64, viewport: f64 }{
                .{ .offset = boundary + 0.125, .viewport = 0.000001 },
                .{ .offset = previous, .viewport = gap },
                .{ .offset = previous, .viewport = gap * 1.25 },
                .{ .offset = boundary, .viewport = 0.000001 },
                .{ .offset = 1_000_000_000_000, .viewport = 0.000001 },
            };
            for (cases) |case| {
                const offset = try list.clampScroll(case.offset, case.viewport);
                var expected: Range = .{};
                var found = false;
                // Independent linear scan with wider arithmetic: no Fenwick
                // lookup, no rounded large-coordinate viewport endpoint.
                var top: u64 = 0;
                for (rows, 0..) |_, index| {
                    const bottom = top + 64_000_000;
                    if (@as(f128, @floatFromInt(bottom)) / 64 > @as(f128, offset) and @as(f128, @floatFromInt(top)) / 64 - @as(f128, offset) < @as(f128, case.viewport)) {
                        if (!found) expected.first = index;
                        expected.end = index + 1;
                        found = true;
                    }
                    top = bottom;
                }
                try std.testing.expectEqual(expected, try list.visibleRange(case.offset, case.viewport));
            }
            try std.testing.expectEqual(Range{ .first = length - 1, .end = length }, try list.visibleRange(boundary + 0.125, 0.000001));
            try std.testing.expectEqual(Range{ .first = length - 2, .end = length }, try list.visibleRange(previous, gap * 1.25));
            try std.testing.expectEqual(Range{ .first = length - 2, .end = length - 1 }, try list.visibleRange(previous, gap));
            const total = try list.totalHeight();
            try std.testing.expectEqual(std.math.nextAfter(f64, total, 0), try list.clampScroll(total, 0.000001));
            try std.testing.expectEqual(total, try list.clampScroll(total, 0));
        }
        try std.testing.expect(state.index.update(length / 3, 600) <= 20);
        try std.testing.expectEqual(@as(?usize, 0), try list.indexOf(length));
        try std.testing.expectEqual(@as(?usize, length - 1), try list.indexOf(1));
        const stats = try list.buildStats();
        try std.testing.expectEqual(length, stats.fenwick_nodes);
        std.debug.print("virtual list construction rows={d} build_ns={?d} owned={d} peak={d} height_search_nodes={d}\n", .{ length, stats.elapsed_ns, stats.owned_bytes, stats.peak_owned_bytes, search.nodes });
    }
}

test "owning and query operations reject a foreign thread" {
    const list = try List.create(std.testing.allocator, std.Thread.getCurrentId(), &.{.{ .id = 1, .height = 10 }}, .{});
    defer list.close() catch unreachable;
    const Worker = struct {
        fn run(value: *List) void {
            std.testing.expectError(error.WrongThread, value.count()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.setHeight(1, 15)) catch unreachable;
            std.testing.expectError(error.WrongThread, value.replace(&.{})) catch unreachable;
            std.testing.expectError(error.WrongThread, value.anchor(0, 1)) catch unreachable;
            std.testing.expectError(error.WrongThread, value.close()) catch unreachable;
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{list});
    worker.join();
    try std.testing.expectEqual(@as(usize, 1), try list.count());
}

test "zero viewport terminal anchor and shrinking last row have explicit clamps" {
    const list = try List.create(std.testing.allocator, std.Thread.getCurrentId(), &.{ .{ .id = 1, .height = 10 }, .{ .id = 2, .height = 20 } }, .{});
    defer list.close() catch unreachable;
    const terminal = try list.anchor(30, 0);
    try std.testing.expectEqual(Anchor{ .id = 2, .old_index = 1, .intra_offset = 20, .global_end = true }, terminal);
    try std.testing.expectEqual(@as(f64, 30), try list.resolve(terminal, 0));
    _ = try list.setHeight(2, 5);
    try std.testing.expectEqual(@as(f64, 15), try list.resolve(terminal, 0));
    try std.testing.expectEqual(@as(f64, 7), try list.resolve(terminal, 8));
    try list.replace(&.{ .{ .id = 2, .height = 3 }, .{ .id = 1, .height = 20 }, .{ .id = 3, .height = 40 } });
    try std.testing.expectEqual(@as(f64, 63), try list.resolve(terminal, 0));
    try std.testing.expectEqual(@as(f64, 53), try list.resolve(terminal, 10));
    try list.replace(&.{});
    const empty_end = try list.anchor(0, 0);
    try std.testing.expect(empty_end.global_end);
    try list.replace(&.{.{ .id = 8, .height = 20 }});
    try std.testing.expectEqual(@as(f64, 15), try list.resolve(empty_end, 5));
    try std.testing.expectError(error.InvalidGeometry, list.visibleRange(0, std.math.inf(f64)));
    try std.testing.expectError(error.InvalidAnchor, list.resolve(.{ .intra_offset = -1 }, 10));
}

test "a retained anchor whose inset equals its shrunken row height stays in that ID" {
    const list = try List.create(std.testing.allocator, std.Thread.getCurrentId(), &.{ .{ .id = 1, .height = 10 }, .{ .id = 2, .height = 10 } }, .{});
    defer list.close() catch unreachable;
    const place = try list.anchor(5, 1);
    try std.testing.expect(!place.global_end);
    _ = try list.setHeight(1, 5);
    const restored = try list.resolve(place, 1);
    try std.testing.expectEqual(@as(f64, 4.984375), restored);
    try std.testing.expectEqual(@as(u64, 1), (try list.anchor(restored, 1)).id);
}

test "positive subnormal viewport and offset retain strict half-open intersections" {
    const list = try List.create(std.testing.allocator, std.Thread.getCurrentId(), &.{ .{ .id = 1, .height = 1 }, .{ .id = 2, .height = 1 } }, .{});
    defer list.close() catch unreachable;
    const tiny: f64 = @bitCast(@as(u64, 1));
    try std.testing.expectEqual(Range{ .first = 0, .end = 1 }, try list.visibleRange(0, tiny));
    // The exact positive offset crosses the unit boundary even though adding
    // it to 1 (or subtracting it from 1) rounds to 1 in f64.
    try std.testing.expectEqual(Range{ .first = 0, .end = 2 }, try list.visibleRange(tiny, 1));
    try std.testing.expectEqual(Range{ .first = 0, .end = 1 }, try list.visibleRange(0, 1));
    try std.testing.expectEqual(Range{ .first = 1, .end = 2 }, try list.visibleRange(1, tiny));
    try std.testing.expectEqual(Range{ .first = 1, .end = 2 }, try list.visibleRange(2, tiny));
    try std.testing.expectEqual(Range{}, try list.visibleRange(2, 0));
}
