const std = @import("std");
const d = @import("ziggurat_document");

pub const units: f64 = 4294967296;
pub const Row = struct { id: u64, epoch: u64, bytes: usize, ticks: u128, measured: bool = false, metric_generation: u64 = 0, terminated: bool, hidden: bool = false };
pub const Sum = struct {
    rows: usize = 0,
    bytes: usize = 0,
    ticks: u128 = 0,
    raw_ticks: u128 = 0,
    visible_rows: usize = 0,
    fn add(a: Sum, b: Sum) !Sum {
        return .{ .rows = std.math.add(usize, a.rows, b.rows) catch return error.CapacityExceeded, .bytes = std.math.add(usize, a.bytes, b.bytes) catch return error.CapacityExceeded, .ticks = std.math.add(u128, a.ticks, b.ticks) catch return error.CapacityExceeded, .raw_ticks = std.math.add(u128, a.raw_ticks, b.raw_ticks) catch return error.CapacityExceeded, .visible_rows = std.math.add(usize, a.visible_rows, b.visible_rows) catch return error.CapacityExceeded };
    }
};
pub const chunk_rows = 32;
pub const Node = struct { refs: usize = 1, height: u8, sum: Sum, hide_override: ?bool = null, value: union(enum) { rows: []Row, branch: struct { left: *Node, right: *Node } } };
pub const Storage = struct {
    allocator: std.mem.Allocator,
    node_limit: usize,
    nodes: usize = 0,
    visited: u64 = 0,
    reclaimed: u64 = 0,
    scanned: u64 = 0,
    fn node(self: *Storage) !*Node {
        if (self.nodes == self.node_limit) return error.CapacityExceeded;
        const result = try self.allocator.create(Node);
        self.nodes += 1;
        return result;
    }
};
pub fn sum(node: ?*const Node) Sum {
    return if (node) |value| value.sum else .{};
}
pub fn retain(node: ?*Node) ?*Node {
    if (node) |value| value.refs += 1;
    return node;
}
pub fn release(storage: *Storage, node: ?*Node) void {
    const value = node orelse return;
    std.debug.assert(value.refs != 0 and value.height <= 64);
    value.refs -= 1;
    if (value.refs != 0) return;
    if (value.value == .branch) {
        release(storage, value.value.branch.left);
        release(storage, value.value.branch.right);
    } else storage.allocator.free(value.value.rows);
    storage.nodes -= 1;
    storage.reclaimed +|= 1;
    storage.allocator.destroy(value);
}
fn rowSum(storage: *Storage, rows: []const Row) !Sum {
    var total: Sum = .{};
    for (rows) |row| {
        storage.scanned +|= 1;
        total = try Sum.add(total, .{ .rows = 1, .bytes = row.bytes, .ticks = if (row.hidden) 0 else row.ticks, .raw_ticks = row.ticks, .visible_rows = @intFromBool(!row.hidden) });
    }
    return total;
}
fn leaf(storage: *Storage, rows: []const Row) !*Node {
    std.debug.assert(rows.len > 0 and rows.len <= chunk_rows);
    const total = try rowSum(storage, rows);
    const owned = try storage.allocator.dupe(Row, rows);
    errdefer storage.allocator.free(owned);
    const value = try storage.node();
    value.* = .{ .height = 1, .sum = total, .value = .{ .rows = owned } };
    return value;
}
fn branch(storage: *Storage, left: *Node, right: *Node) !*Node {
    const depth = @max(left.height, right.height);
    if (depth == 64) return error.CapacityExceeded;
    const total = try Sum.add(left.sum, right.sum);
    const value = try storage.node();
    value.* = .{ .height = depth + 1, .sum = total, .value = .{ .branch = .{ .left = retain(left).?, .right = retain(right).? } } };
    return value;
}
/// Balanced metadata construction, also used by optional derived projections.
/// The input is borrowed only for this call; zero-height metadata is allowed.
pub fn fromRows(storage: *Storage, rows: []const Row) !?*Node {
    if (rows.len == 0) return null;
    if (rows.len <= chunk_rows) return try leaf(storage, rows);
    const at = rows.len / 2;
    const left = (try fromRows(storage, rows[0..at])).?;
    defer release(storage, left);
    const right = (try fromRows(storage, rows[at..])).?;
    defer release(storage, right);
    return try branch(storage, left, right);
}
fn effective(total: Sum, hidden: ?bool) Sum {
    var result = total;
    if (hidden) |value| {
        result.ticks = if (value) 0 else result.raw_ticks;
        result.visible_rows = if (value) 0 else result.rows;
    }
    return result;
}
fn rowsOf(node: *const Node, buffer: *[chunk_rows]Row, inherited: ?bool) []Row {
    @memcpy(buffer[0..node.sum.rows], node.value.rows);
    if (inherited orelse node.hide_override) |hidden| for (buffer[0..node.sum.rows]) |*row| {
        row.hidden = hidden;
    };
    return buffer[0..node.sum.rows];
}
fn override(storage: *Storage, node: *Node, hidden: bool) !*Node {
    if (node.hide_override != null and node.hide_override.? == hidden) return retain(node).?;
    const result = if (node.value == .rows) try leaf(storage, node.value.rows) else try branch(storage, node.value.branch.left, node.value.branch.right);
    result.hide_override = hidden;
    result.sum = effective(node.sum, hidden);
    return result;
}
const Children = struct {
    left: *Node,
    right: *Node,
    fn close(self: Children, storage: *Storage) void {
        release(storage, self.left);
        release(storage, self.right);
    }
};
fn children(storage: *Storage, node: *Node) !Children {
    const pair = node.value.branch;
    if (node.hide_override) |hidden| {
        const left = try override(storage, pair.left, hidden);
        errdefer release(storage, left);
        return .{ .left = left, .right = try override(storage, pair.right, hidden) };
    }
    return .{ .left = retain(pair.left).?, .right = retain(pair.right).? };
}
fn balance(storage: *Storage, left: *Node, right: *Node) !*Node {
    if (left.height > right.height + 1) {
        const l = try children(storage, left);
        defer l.close(storage);
        if (l.left.height >= l.right.height) {
            const r = try branch(storage, l.right, right);
            defer release(storage, r);
            return branch(storage, l.left, r);
        }
        const p = try children(storage, l.right);
        defer p.close(storage);
        const a = try branch(storage, l.left, p.left);
        defer release(storage, a);
        const b = try branch(storage, p.right, right);
        defer release(storage, b);
        return branch(storage, a, b);
    }
    if (right.height > left.height + 1) {
        const r = try children(storage, right);
        defer r.close(storage);
        if (r.right.height >= r.left.height) {
            const l = try branch(storage, left, r.left);
            defer release(storage, l);
            return branch(storage, l, r.right);
        }
        const p = try children(storage, r.left);
        defer p.close(storage);
        const a = try branch(storage, left, p.left);
        defer release(storage, a);
        const b = try branch(storage, p.right, r.right);
        defer release(storage, b);
        return branch(storage, a, b);
    }
    return branch(storage, left, right);
}
pub fn concat(storage: *Storage, a: ?*Node, b: ?*Node) error{ OutOfMemory, CapacityExceeded }!?*Node {
    const left = a orelse return retain(b);
    const right = b orelse return retain(a);
    if (left.value == .rows and right.value == .rows and left.sum.rows + right.sum.rows <= chunk_rows) {
        var rows: [chunk_rows]Row = undefined;
        var a_rows: [chunk_rows]Row = undefined;
        var b_rows: [chunk_rows]Row = undefined;
        @memcpy(rows[0..left.sum.rows], rowsOf(left, &a_rows, null));
        @memcpy(rows[left.sum.rows..][0..right.sum.rows], rowsOf(right, &b_rows, null));
        return try leaf(storage, rows[0 .. left.sum.rows + right.sum.rows]);
    }
    if (left.height > right.height + 1) {
        const pair = try children(storage, left);
        defer pair.close(storage);
        const part = try concat(storage, pair.right, right);
        defer release(storage, part);
        return balance(storage, pair.left, part.?);
    }
    if (right.height > left.height + 1) {
        const pair = try children(storage, right);
        defer pair.close(storage);
        const part = try concat(storage, left, pair.left);
        defer release(storage, part);
        return balance(storage, part.?, pair.right);
    }
    return branch(storage, left, right);
}
pub fn build(storage: *Storage, rows: []const Row) error{ OutOfMemory, CapacityExceeded }!?*Node {
    if (rows.len == 0) return null;
    if (rows.len <= chunk_rows) return leaf(storage, rows);
    const middle = rows.len / 2;
    const left = try build(storage, rows[0..middle]);
    defer release(storage, left);
    const right = try build(storage, rows[middle..]);
    defer release(storage, right);
    return branch(storage, left.?, right.?);
}
const Halves = struct { left: ?*Node, right: ?*Node };
fn split(storage: *Storage, root: ?*Node, at: usize) error{ OutOfMemory, CapacityExceeded }!Halves {
    const value = root orelse return .{ .left = null, .right = null };
    if (at == 0) return .{ .left = null, .right = retain(value) };
    if (at == value.sum.rows) return .{ .left = retain(value), .right = null };
    if (value.value == .rows) {
        var scratch: [chunk_rows]Row = undefined;
        const rows = rowsOf(value, &scratch, null);
        const left = try leaf(storage, rows[0..at]);
        errdefer release(storage, left);
        return .{ .left = left, .right = try leaf(storage, rows[at..]) };
    }
    const pair = try children(storage, value);
    defer pair.close(storage);
    if (at < pair.left.sum.rows) {
        const part = try split(storage, pair.left, at);
        errdefer release(storage, part.left);
        defer release(storage, part.right);
        return .{ .left = part.left, .right = try concat(storage, part.right, pair.right) };
    }
    const part = try split(storage, pair.right, at - pair.left.sum.rows);
    errdefer release(storage, part.right);
    defer release(storage, part.left);
    return .{ .left = try concat(storage, pair.left, part.left), .right = part.right };
}
pub fn splice(storage: *Storage, root: *Node, at: usize, removed: usize, rows: []const Row) !*Node {
    const a = try split(storage, root, at);
    defer release(storage, a.left);
    defer release(storage, a.right);
    const b = try split(storage, a.right, removed);
    defer release(storage, b.left);
    defer release(storage, b.right);
    const middle = try build(storage, rows);
    defer release(storage, middle);
    const first = try concat(storage, a.left, middle);
    defer release(storage, first);
    return (try concat(storage, first, b.right)).?;
}
pub fn get(storage: *Storage, root: *const Node, index: usize) Row {
    var node = root;
    var offset = index;
    var hidden: ?bool = null;
    while (true) {
        storage.visited +|= 1;
        if (hidden == null) hidden = node.hide_override;
        switch (node.value) {
            .rows => |rows| {
                storage.scanned +|= 1;
                var row = rows[offset];
                if (hidden) |value| row.hidden = value;
                return row;
            },
            .branch => |pair| if (offset < pair.left.sum.rows) {
                node = pair.left;
            } else {
                offset -= pair.left.sum.rows;
                node = pair.right;
            },
        }
    }
}
pub fn prefix(storage: *Storage, root: *const Node, rows: usize) Sum {
    return prefixInner(storage, root, rows, null);
}
fn prefixInner(storage: *Storage, root: *const Node, rows: usize, inherited: ?bool) Sum {
    storage.visited +|= 1;
    const hidden = inherited orelse root.hide_override;
    if (rows == root.sum.rows) return effective(root.sum, hidden);
    switch (root.value) {
        .rows => {
            var scratch: [chunk_rows]Row = undefined;
            return rowSum(storage, rowsOf(root, &scratch, inherited)[0..rows]) catch unreachable;
        },
        .branch => |pair| {
            if (rows < pair.left.sum.rows) return prefixInner(storage, pair.left, rows, hidden);
            return Sum.add(effective(pair.left.sum, hidden), prefixInner(storage, pair.right, rows - pair.left.sum.rows, hidden)) catch unreachable;
        },
    }
}
pub fn lineAt(storage: *Storage, root: *const Node, byte: usize) usize {
    storage.visited +|= 1;
    switch (root.value) {
        .rows => |rows| {
            var at: usize = 0;
            var remaining = byte;
            while (at + 1 < rows.len) : (at += 1) {
                storage.scanned +|= 1;
                if (remaining < rows[at].bytes) break;
                remaining -= rows[at].bytes;
            }
            return at;
        },
        .branch => |pair| return if (byte < pair.left.sum.bytes) lineAt(storage, pair.left, byte) else pair.left.sum.rows + lineAt(storage, pair.right, byte - pair.left.sum.bytes),
    }
}
pub fn atTick(storage: *Storage, root: *const Node, tick: u128) usize {
    return atTickInner(storage, root, tick, null);
}
fn atTickInner(storage: *Storage, root: *const Node, tick: u128, inherited: ?bool) usize {
    storage.visited +|= 1;
    const hidden = inherited orelse root.hide_override;
    switch (root.value) {
        .rows => |rows| {
            var at: usize = 0;
            var remaining = tick;
            while (at + 1 < rows.len) : (at += 1) {
                storage.scanned +|= 1;
                const size = if (hidden orelse rows[at].hidden) @as(u128, 0) else rows[at].ticks;
                if (remaining < size) break;
                remaining -= size;
            }
            return at;
        },
        .branch => |pair| {
            const size = effective(pair.left.sum, hidden).ticks;
            return if (tick < size) atTickInner(storage, pair.left, tick, hidden) else pair.left.sum.rows + atTickInner(storage, pair.right, tick - size, hidden);
        },
    }
}
fn atVisible(storage: *Storage, root: *const Node, ordinal: usize, inherited: ?bool) usize {
    storage.visited +|= 1;
    const hidden = inherited orelse root.hide_override;
    switch (root.value) {
        .rows => |rows| {
            var remaining = ordinal;
            for (rows, 0..) |row, at| {
                storage.scanned +|= 1;
                if (hidden orelse row.hidden) continue;
                if (remaining == 0) return at;
                remaining -= 1;
            }
            unreachable;
        },
        .branch => |pair| {
            const count = effective(pair.left.sum, hidden).visible_rows;
            return if (ordinal < count) atVisible(storage, pair.left, ordinal, hidden) else pair.left.sum.rows + atVisible(storage, pair.right, ordinal - count, hidden);
        },
    }
}
pub fn nextVisible(storage: *Storage, root: *const Node, at: usize) ?usize {
    const before = prefix(storage, root, at).visible_rows;
    return if (before < root.sum.visible_rows) atVisible(storage, root, before, null) else null;
}
pub fn previousVisible(storage: *Storage, root: *const Node, at: usize) ?usize {
    const before = prefix(storage, root, at).visible_rows;
    return if (before == 0) null else atVisible(storage, root, before - 1, null);
}
pub fn height(storage: *Storage, root: *Node, row_index: usize, ticks: u128, generation: u64) !*Node {
    storage.visited +|= 1;
    if (root.value == .rows) {
        var scratch: [chunk_rows]Row = undefined;
        const rows = rowsOf(root, &scratch, null);
        rows[row_index].ticks = ticks;
        rows[row_index].measured = true;
        rows[row_index].metric_generation = generation;
        return leaf(storage, rows);
    }
    const pair = try children(storage, root);
    defer pair.close(storage);
    if (row_index < pair.left.sum.rows) {
        const replacement = try height(storage, pair.left, row_index, ticks, generation);
        defer release(storage, replacement);
        return branch(storage, replacement, pair.right);
    }
    const replacement = try height(storage, pair.right, row_index - pair.left.sum.rows, ticks, generation);
    defer release(storage, replacement);
    return branch(storage, pair.left, replacement);
}
pub fn setHidden(storage: *Storage, root: *Node, first: usize, end: usize, hidden: bool) error{ OutOfMemory, CapacityExceeded }!*Node {
    std.debug.assert(first <= end and end <= root.sum.rows);
    storage.visited +|= 1;
    if (first == end) return retain(root).?;
    if (first == 0 and end == root.sum.rows) return override(storage, root, hidden);
    if (root.value == .rows) {
        var scratch: [chunk_rows]Row = undefined;
        const rows = rowsOf(root, &scratch, null);
        for (rows[first..end]) |*row| row.hidden = hidden;
        return leaf(storage, rows);
    }
    const pair = try children(storage, root);
    defer pair.close(storage);
    const split_at = pair.left.sum.rows;
    const left = if (first < split_at) try setHidden(storage, pair.left, first, @min(end, split_at), hidden) else retain(pair.left).?;
    defer release(storage, left);
    const right = if (end > split_at) try setHidden(storage, pair.right, first -| split_at, end - split_at, hidden) else retain(pair.right).?;
    defer release(storage, right);
    return branch(storage, left, right);
}

pub fn quantize(value: f64) !u128 {
    if (!std.math.isFinite(value) or value <= 0 or value > 16 * 1024 * 1024) return error.InvalidHeight;
    const scaled = value * units;
    if (scaled != @floor(scaled)) return error.UnsupportedMetricPrecision;
    return @intFromFloat(scaled);
}
pub const Edit = struct { root: *Node, first: usize, removed: usize, inserted: usize, next_id: u64 };
pub fn plan(storage: *Storage, root: *Node, range: d.Range, text: []const u8, next_id: u64, epoch: u64, estimate: u128, row_limit: usize) !Edit {
    const first = lineAt(storage, root, range.start);
    const last = lineAt(storage, root, range.end);
    const old = get(storage, root, first);
    const suffix = get(storage, root, last);
    var count: usize = 1;
    for (text) |byte| count += @intFromBool(byte == '\n');
    if (count > row_limit -| (root.sum.rows - (last - first + 1))) return error.ParagraphCapacityExceeded;
    const after_id = std.math.add(u64, next_id, count - 1) catch return error.IdExhausted;
    const rows = try storage.allocator.alloc(Row, count);
    defer storage.allocator.free(rows);
    var index: usize = 0;
    var length = range.start - prefix(storage, root, first).bytes;
    for (text) |byte| {
        length += 1;
        if (byte == '\n') {
            rows[index] = .{ .id = if (index == 0) old.id else next_id + index - 1, .epoch = epoch, .bytes = length, .ticks = estimate, .terminated = true };
            index += 1;
            length = 0;
        }
    }
    length += prefix(storage, root, last + 1).bytes - range.end;
    rows[index] = .{ .id = if (index == 0) old.id else next_id + index - 1, .epoch = epoch, .bytes = length, .ticks = estimate, .terminated = suffix.terminated };
    return .{ .root = try splice(storage, root, first, last - first + 1, rows), .first = first, .removed = last - first + 1, .inserted = count, .next_id = after_id };
}

pub const Builder = struct {
    rows: std.ArrayList(Row) = .empty,
    storage: *Storage,
    row_limit: usize,
    next_id: u64,
    epoch: u64,
    estimate: u128,
    pending: usize = 0,
    failure: ?anyerror = null,
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    pub fn deinit(self: *Builder) void {
        self.rows.deinit(self.storage.allocator);
    }
    fn append(self: *Builder, terminated: bool) !void {
        if (self.rows.items.len == self.row_limit) return error.ParagraphCapacityExceeded;
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        try self.rows.append(self.storage.allocator, .{ .id = self.next_id, .epoch = self.epoch, .bytes = self.pending, .ticks = self.estimate, .terminated = terminated });
        self.next_id += 1;
        self.pending = 0;
    }
    fn bytes(self: *Builder, text: []const u8) !void {
        for (text) |byte| {
            self.pending += 1;
            if (byte == '\n') try self.append(true);
        }
    }
    fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Builder = @alignCast(@fieldParentPtr("writer", writer));
        var total: usize = 0;
        for (parts, 0..) |part, index| for (0..if (index + 1 == parts.len) splat else 1) |_| {
            self.bytes(part) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            total += part.len;
        };
        return total;
    }
    pub fn finish(self: *Builder, document: *const d.Document) !*Node {
        document.writeTo(&self.writer) catch |err| return self.failure orelse err;
        try self.append(false);
        return (try build(self.storage, self.rows.items)).?;
    }
};
