const std = @import("std");
const d = @import("ziggurat_document");
const ix = @import("index.zig");

/// Whole-paragraph placements, in the original Document order. A gap belongs
/// before its paragraph; minimum_height pads after its native text. Neither
/// creates document bytes, selectable text or a second input state.
pub const Placement = struct { line: usize, gap_before: f64 = 0, minimum_height: f64 = 0 };
pub const Limits = struct { entries: usize = 4096, bytes: usize = 1024 * 1024 };
const Record = struct { line: usize, gap: u128, minimum: u128 };
pub const Plan = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    document: *d.Document,
    text_version: u64,
    lines: usize,
    records: []Record,
    clients: usize = 0,
    busy: bool = false,
    pub fn create(allocator: std.mem.Allocator, document: *d.Document, placements: []const Placement, limits: Limits) !*Plan {
        if (limits.entries == 0 or limits.entries > 65536 or limits.bytes < @sizeOf(Plan) or limits.bytes > 64 * 1024 * 1024) return error.InvalidLimits;
        if (placements.len > limits.entries or placements.len > (limits.bytes - @sizeOf(Plan)) / @sizeOf(Record)) return error.CapacityExceeded;
        try document.retainClient();
        errdefer document.releaseClient() catch unreachable;
        const stamp = try document.committedTextVersion();
        const lines = try document.lineCount();
        const self = try allocator.create(Plan);
        errdefer allocator.destroy(self);
        const records = try allocator.alloc(Record, placements.len);
        errdefer allocator.free(records);
        for (placements, records, 0..) |placement, *record, at| {
            if (placement.line >= lines or (at != 0 and placement.line <= placements[at - 1].line)) return error.InvalidProjection;
            record.* = .{ .line = placement.line, .gap = try quantize(placement.gap_before, 1e12), .minimum = try quantize(placement.minimum_height, 1e12) };
        }
        if (stamp != try document.committedTextVersion()) return error.StaleRevision;
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .document = document, .text_version = stamp, .lines = lines, .records = records };
        return self;
    }
    fn check(self: *const Plan) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    pub fn close(self: *Plan) !void {
        try self.check();
        if (self.clients != 0) return error.ClientsAlive;
        self.busy = true;
        self.document.releaseClient() catch unreachable;
        const allocator = self.allocator;
        allocator.free(self.records);
        allocator.destroy(self);
    }
    pub fn retainClient(self: *Plan) !void {
        try self.check();
        self.clients = std.math.add(usize, self.clients, 1) catch return error.CapacityExceeded;
    }
    pub fn releaseClient(self: *Plan) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId() and self.clients != 0);
        self.clients -= 1;
    }
    pub fn current(self: *const Plan) !bool {
        try self.check();
        return self.text_version == try self.document.committedTextVersion();
    }
    fn lower(self: *const Plan, line: usize) usize {
        var low: usize = 0;
        var high = self.records.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.records[middle].line < line) low = middle + 1 else high = middle;
        }
        return low;
    }
};
fn quantize(value: f64, limit: f64) !u128 {
    if (!std.math.isFinite(value) or value < 0 or value > limit) return error.InvalidProjection;
    return @as(u128, @intFromFloat(@ceil(value * 64))) << 26;
}
fn extra(record: Record, row: ix.Row) u128 {
    return if (row.hidden) 0 else record.gap + (record.minimum -| row.ticks);
}

/// Persistent sparse extra-height tree. Base paragraph metrics stay untouched.
/// Fork/update is O(log P), prefix lookup O(log P), initial build O(P log R).
/// Metadata allocation is charged to the caller's existing Adapter storage.
pub const Geometry = struct {
    plan: *Plan,
    root: ?*ix.Node,
    pub fn create(storage: *ix.Storage, base: *ix.Node, plan: *Plan) !Geometry {
        if (!try plan.current() or base.sum.rows != plan.lines) return error.StaleRevision;
        try plan.retainClient();
        errdefer plan.releaseClient();
        const rows = try storage.allocator.alloc(ix.Row, plan.records.len);
        defer storage.allocator.free(rows);
        for (rows, plan.records) |*row, record| row.* = .{ .id = @intCast(record.line + 1), .epoch = 1, .bytes = 0, .ticks = extra(record, ix.get(storage, base, record.line)), .terminated = false };
        return .{ .plan = plan, .root = try ix.fromRows(storage, rows) };
    }
    pub fn retain(self: Geometry) Geometry {
        self.plan.retainClient() catch unreachable;
        return .{ .plan = self.plan, .root = ix.retain(self.root) };
    }
    pub fn close(self: *Geometry, storage: *ix.Storage) void {
        ix.release(storage, self.root);
        self.plan.releaseClient();
    }
    pub fn prefix(self: *const Geometry, storage: *ix.Storage, line: usize) u128 {
        const root = self.root orelse return 0;
        return ix.prefix(storage, root, self.plan.lower(line)).ticks;
    }
    pub fn total(self: *const Geometry) u128 {
        return ix.sum(self.root).ticks;
    }
    pub fn gap(self: *const Geometry, line: usize) u128 {
        const at = self.plan.lower(line);
        return if (at < self.plan.records.len and self.plan.records[at].line == line) self.plan.records[at].gap else 0;
    }
    pub fn update(self: *Geometry, storage: *ix.Storage, base: *ix.Node, line: usize) !void {
        const at = self.plan.lower(line);
        if (at == self.plan.records.len or self.plan.records[at].line != line) return;
        const value = extra(self.plan.records[at], ix.get(storage, base, line));
        const root = self.root.?;
        if (ix.get(storage, root, at).ticks == value) return;
        const replacement = try ix.height(storage, root, at, value, 0);
        ix.release(storage, root);
        self.root = replacement;
    }
    pub fn atTick(self: *const Geometry, storage: *ix.Storage, base: *const ix.Node, tick: u128) usize {
        return self.walk(storage, base, tick, 0, null);
    }
    fn walk(self: *const Geometry, storage: *ix.Storage, node: *const ix.Node, tick: u128, first: usize, inherited: ?bool) usize {
        storage.visited +|= 1;
        const hidden = inherited orelse node.hide_override;
        switch (node.value) {
            .rows => |rows| {
                var remaining = tick;
                for (rows, 0..) |row, at| {
                    storage.scanned +|= 1;
                    const native = if (hidden orelse row.hidden) @as(u128, 0) else row.ticks;
                    const addition = self.prefix(storage, first + at + 1) - self.prefix(storage, first + at);
                    const height = native + addition;
                    if (remaining < height or at + 1 == rows.len) return first + at;
                    remaining -= height;
                }
                unreachable;
            },
            .branch => |pair| {
                const end = first + pair.left.sum.rows;
                const native = if (hidden) |value| if (value) 0 else pair.left.sum.raw_ticks else pair.left.sum.ticks;
                const height = native + self.prefix(storage, end) - self.prefix(storage, first);
                return if (tick < height) self.walk(storage, pair.left, tick, first, hidden) else self.walk(storage, pair.right, tick - height, end, hidden);
            },
        }
    }
};

test "projection keeps byte index metrics separate and sparse height updates match a linear oracle" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "a\nb\nc\nd", .{});
    defer document.close() catch unreachable;
    const plan = try Plan.create(std.testing.allocator, document, &.{ .{ .line = 1, .gap_before = 7.001, .minimum_height = 30 }, .{ .line = 3, .minimum_height = 8 } }, .{});
    defer plan.close() catch unreachable;
    var storage: ix.Storage = .{ .allocator = std.testing.allocator, .node_limit = 10000 };
    var builder: ix.Builder = .{ .storage = &storage, .row_limit = 100, .next_id = 1, .epoch = 1, .estimate = try ix.quantize(10) };
    defer builder.deinit();
    var base = try builder.finish(document);
    defer ix.release(&storage, base);
    var geometry = try Geometry.create(&storage, base, plan);
    defer geometry.close(&storage);
    try std.testing.expectError(error.ClientsAlive, plan.close());
    var random = std.Random.DefaultPrng.init(31415);
    for (0..300) |_| {
        const line = random.random().uintLessThan(usize, 4);
        const replacement = try ix.height(&storage, base, line, try ix.quantize(@floatFromInt(random.random().uintLessThan(u32, 40) + 1)), 1);
        ix.release(&storage, base);
        base = replacement;
        try geometry.update(&storage, base, line);
        var sum: u128 = 0;
        for (0..4) |at| {
            try std.testing.expectEqual(sum, ix.prefix(&storage, base, at).ticks + geometry.prefix(&storage, at));
            const native = ix.get(&storage, base, at).ticks;
            const gap = if (at == 1) try quantize(7.001, 1e12) else 0;
            const minimum = if (at == 1) try ix.quantize(30) else if (at == 3) try ix.quantize(8) else 0;
            const height = @max(native, minimum) + gap;
            try std.testing.expectEqual(at, geometry.atTick(&storage, base, sum));
            try std.testing.expectEqual(at, geometry.atTick(&storage, base, sum + height - 1));
            sum += height;
        }
        try std.testing.expectEqual(sum, base.sum.ticks + geometry.total());
    }
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "a\nb\nc", .{});
    defer document.close() catch unreachable;
    const plan = try Plan.create(allocator, document, &.{.{ .line = 1, .gap_before = 50, .minimum_height = 80 }}, .{});
    defer plan.close() catch unreachable;
    var storage: ix.Storage = .{ .allocator = allocator, .node_limit = 1000 };
    var builder: ix.Builder = .{ .storage = &storage, .row_limit = 100, .next_id = 1, .epoch = 1, .estimate = try ix.quantize(20) };
    defer builder.deinit();
    const base = try builder.finish(document);
    defer ix.release(&storage, base);
    var value = try Geometry.create(&storage, base, plan);
    defer value.close(&storage);
    var fork = value.retain();
    defer fork.close(&storage);
    const hidden = try ix.setHidden(&storage, base, 1, 2, true);
    defer ix.release(&storage, hidden);
    try fork.update(&storage, hidden, 1);
    try std.testing.expectEqual(@as(u128, 0), fork.total());
    try std.testing.expectEqual(try ix.quantize(110), value.total());
}
test "projection candidate OOM preserves original sparse geometry and no clients survive cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
test "folded sparse ranges and large gaps agree with a linear height oracle" {
    var bytes: [513]u8 = undefined;
    @memset(&bytes, 'a');
    for (0..256) |line| bytes[line * 2 + 1] = '\n';
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), &bytes, .{});
    defer document.close() catch unreachable;
    var placements: [257]Placement = undefined;
    for (&placements, 0..) |*placement, line| placement.* = .{ .line = line, .gap_before = if (line == 256) 1e12 else @floatFromInt(line % 5), .minimum_height = if (line == 128) 1e12 else 20 + @as(f64, @floatFromInt(line % 4)) };
    const plan = try Plan.create(std.testing.allocator, document, &placements, .{});
    defer plan.close() catch unreachable;
    var storage: ix.Storage = .{ .allocator = std.testing.allocator, .node_limit = 10000 };
    var builder: ix.Builder = .{ .storage = &storage, .row_limit = 1000, .next_id = 1, .epoch = 1, .estimate = try ix.quantize(10) };
    defer builder.deinit();
    const original = try builder.finish(document);
    defer ix.release(&storage, original);
    for ([_]bool{ false, true, false }) |hidden| {
        const base = try ix.setHidden(&storage, original, 16, 245, hidden);
        defer ix.release(&storage, base);
        var geometry = try Geometry.create(&storage, base, plan);
        defer geometry.close(&storage);
        var sum: u128 = 0;
        for (placements) |placement| {
            const line = placement.line;
            try std.testing.expectEqual(sum, ix.prefix(&storage, base, line).ticks + geometry.prefix(&storage, line));
            if (hidden and line >= 16 and line < 245) continue;
            const height = try quantize(placement.gap_before, 1e12) + try quantize(placement.minimum_height, 1e12);
            try std.testing.expectEqual(line, geometry.atTick(&storage, base, sum));
            try std.testing.expectEqual(line, geometry.atTick(&storage, base, sum + height - 1));
            sum += height;
        }
        try std.testing.expectEqual(sum, base.sum.ticks + geometry.total());
    }
    try document.replace(.{ .start = 0, .end = 1 }, "new");
    try std.testing.expect(!try plan.current());
    _ = try document.undo();
    try std.testing.expect(!try plan.current());
    try std.testing.expectError(error.StaleRevision, Geometry.create(&storage, original, plan));
}
