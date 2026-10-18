const std = @import("std");

pub const leaf_bytes = 4096;
pub const max_depth = 64;
pub const Counts = struct {
    bytes: usize = 0,
    scalars: usize = 0,
    utf16: usize = 0,
    lf: usize = 0,

    fn add(a: Counts, b: Counts) !Counts {
        return .{
            .bytes = std.math.add(usize, a.bytes, b.bytes) catch return error.CapacityExceeded,
            .scalars = std.math.add(usize, a.scalars, b.scalars) catch return error.CapacityExceeded,
            .utf16 = std.math.add(usize, a.utf16, b.utf16) catch return error.CapacityExceeded,
            .lf = std.math.add(usize, a.lf, b.lf) catch return error.CapacityExceeded,
        };
    }
};
pub const Node = struct {
    refs: usize = 1,
    height: u8,
    counts: Counts,
    value: union(enum) { leaf: []u8, branch: struct { left: *Node, right: *Node } },
};
pub const Limits = struct { live_bytes: usize, nodes: usize, candidate_bytes: usize };
pub const Stats = struct {
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    live_nodes: usize = 0,
    copied_bytes: u64 = 0,
    visited_nodes: u64 = 0,
    reclaimed_nodes: u64 = 0,
    last_candidate_peak: usize = 0,
};
pub const Memory = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    stats: Stats = .{},
    candidate_base: ?usize = null,
    candidate_peak: usize = 0,

    pub fn begin(self: *Memory) void {
        std.debug.assert(self.candidate_base == null);
        self.candidate_base = self.stats.live_bytes;
        self.candidate_peak = self.stats.live_bytes;
    }
    pub fn end(self: *Memory) void {
        self.stats.last_candidate_peak = self.candidate_peak - self.candidate_base.?;
        self.candidate_base = null;
    }
    fn reserve(self: *Memory, bytes: usize) !void {
        const next = std.math.add(usize, self.stats.live_bytes, bytes) catch return error.CapacityExceeded;
        if (next > self.limits.live_bytes) return error.CapacityExceeded;
        if (self.candidate_base) |base| if (next > base and next - base > self.limits.candidate_bytes) return error.CapacityExceeded;
    }
    fn account(self: *Memory, bytes: usize) void {
        self.stats.live_bytes += bytes;
        self.stats.peak_bytes = @max(self.stats.peak_bytes, self.stats.live_bytes);
        if (self.candidate_base != null) self.candidate_peak = @max(self.candidate_peak, self.stats.live_bytes);
    }
    pub fn create(self: *Memory, comptime T: type) !*T {
        try self.reserve(@sizeOf(T));
        const value = try self.allocator.create(T);
        self.account(@sizeOf(T));
        return value;
    }
    pub fn destroy(self: *Memory, comptime T: type, value: *T) void {
        self.allocator.destroy(value);
        self.stats.live_bytes -= @sizeOf(T);
    }
    pub fn alloc(self: *Memory, comptime T: type, count: usize) ![]T {
        const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.CapacityExceeded;
        try self.reserve(bytes);
        const value = try self.allocator.alloc(T, count);
        self.account(bytes);
        return value;
    }
    pub fn free(self: *Memory, comptime T: type, values: []T) void {
        self.allocator.free(values);
        self.stats.live_bytes -= values.len * @sizeOf(T);
    }
    fn node(self: *Memory) !*Node {
        if (self.stats.live_nodes == self.limits.nodes) return error.CapacityExceeded;
        const result = try self.create(Node);
        self.stats.live_nodes += 1;
        return result;
    }
};

pub fn counts(node: ?*const Node) Counts {
    return if (node) |n| n.counts else .{};
}
fn height(node: ?*const Node) u8 {
    return if (node) |n| n.height else 0;
}
pub fn retain(node: ?*Node) ?*Node {
    if (node) |n| {
        // Nodes and snapshot/history references are all independently bounded;
        // reaching the address-space refcount limit is therefore impossible.
        std.debug.assert(n.refs < std.math.maxInt(usize));
        n.refs += 1;
    }
    return node;
}
/// AVL height is capped at 64, independent of document line or node count.
/// Releasing a root visits only the nodes whose final reference is removed.
pub fn release(memory: *Memory, node: ?*Node) void {
    const n = node orelse return;
    std.debug.assert(n.refs > 0 and n.height <= max_depth);
    n.refs -= 1;
    if (n.refs != 0) return;
    switch (n.value) {
        .leaf => |bytes| memory.free(u8, bytes),
        .branch => |children| {
            release(memory, children.left);
            release(memory, children.right);
        },
    }
    memory.stats.live_nodes -= 1;
    memory.stats.reclaimed_nodes +|= 1;
    memory.destroy(Node, n);
}
fn leaf(memory: *Memory, bytes: []const u8) !*Node {
    std.debug.assert(bytes.len != 0 and bytes.len <= leaf_bytes);
    const storage = try memory.alloc(u8, bytes.len);
    errdefer memory.free(u8, storage);
    const result = try memory.node();
    @memcpy(storage, bytes);
    memory.stats.copied_bytes +|= bytes.len;
    var sum: Counts = .{ .bytes = bytes.len };
    var iterator = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (iterator.nextCodepoint()) |cp| {
        sum.scalars += 1;
        sum.utf16 += if (cp > 0xffff) @as(usize, 2) else 1;
        sum.lf += @intFromBool(cp == '\n');
    }
    result.* = .{ .height = 1, .counts = sum, .value = .{ .leaf = storage } };
    return result;
}
fn branch(memory: *Memory, left: *Node, right: *Node) !*Node {
    const depth = @max(left.height, right.height);
    if (depth == max_depth) return error.CapacityExceeded;
    const sum = try Counts.add(left.counts, right.counts);
    const result = try memory.node();
    result.* = .{ .height = depth + 1, .counts = sum, .value = .{ .branch = .{ .left = retain(left).?, .right = retain(right).? } } };
    return result;
}
fn balance(memory: *Memory, left: *Node, right: *Node) !*Node {
    if (height(left) > height(right) + 1) {
        const l = left.value.branch;
        if (height(l.left) >= height(l.right)) {
            const r = try branch(memory, l.right, right);
            defer release(memory, r);
            return branch(memory, l.left, r);
        }
        const pivot = l.right.value.branch;
        const a = try branch(memory, l.left, pivot.left);
        defer release(memory, a);
        const b = try branch(memory, pivot.right, right);
        defer release(memory, b);
        return branch(memory, a, b);
    }
    if (height(right) > height(left) + 1) {
        const r = right.value.branch;
        if (height(r.right) >= height(r.left)) {
            const l = try branch(memory, left, r.left);
            defer release(memory, l);
            return branch(memory, l, r.right);
        }
        const pivot = r.left.value.branch;
        const a = try branch(memory, left, pivot.left);
        defer release(memory, a);
        const b = try branch(memory, pivot.right, r.right);
        defer release(memory, b);
        return branch(memory, a, b);
    }
    return branch(memory, left, right);
}
/// Both arguments are borrowed; the returned root owns one reference.
pub fn concat(memory: *Memory, left: ?*Node, right: ?*Node) error{ OutOfMemory, CapacityExceeded }!?*Node {
    const a = left orelse return retain(right);
    const b = right orelse return retain(left);
    if (a.value == .leaf and b.value == .leaf and a.counts.bytes + b.counts.bytes <= leaf_bytes) {
        var scratch: [leaf_bytes]u8 = undefined;
        @memcpy(scratch[0..a.counts.bytes], a.value.leaf);
        @memcpy(scratch[a.counts.bytes..][0..b.counts.bytes], b.value.leaf);
        return try leaf(memory, scratch[0 .. a.counts.bytes + b.counts.bytes]);
    }
    if (a.height > b.height + 1) {
        const part = try concat(memory, a.value.branch.right, b);
        defer release(memory, part);
        return try balance(memory, a.value.branch.left, part.?);
    }
    if (b.height > a.height + 1) {
        const part = try concat(memory, a, b.value.branch.left);
        defer release(memory, part);
        return try balance(memory, part.?, b.value.branch.right);
    }
    return try branch(memory, a, b);
}
pub fn build(memory: *Memory, bytes: []const u8) error{ OutOfMemory, CapacityExceeded }!?*Node {
    if (bytes.len == 0) return null;
    if (bytes.len <= leaf_bytes) return try leaf(memory, bytes);
    var middle = bytes.len / 2;
    while (bytes[middle] & 0xc0 == 0x80) middle -= 1;
    const left = try build(memory, bytes[0..middle]);
    defer release(memory, left);
    const right = try build(memory, bytes[middle..]);
    defer release(memory, right);
    return try balance(memory, left.?, right.?);
}
pub const Split = struct { left: ?*Node, right: ?*Node };
pub fn split(memory: *Memory, node: ?*Node, at: usize) error{ OutOfMemory, CapacityExceeded }!Split {
    const n = node orelse return .{ .left = null, .right = null };
    if (at == 0) return .{ .left = null, .right = retain(n) };
    if (at == n.counts.bytes) return .{ .left = retain(n), .right = null };
    memory.stats.visited_nodes +|= 1;
    switch (n.value) {
        .leaf => |bytes| {
            const left = try leaf(memory, bytes[0..at]);
            errdefer release(memory, left);
            return .{ .left = left, .right = try leaf(memory, bytes[at..]) };
        },
        .branch => |children| {
            if (at < children.left.counts.bytes) {
                const halves = try split(memory, children.left, at);
                errdefer release(memory, halves.left);
                defer release(memory, halves.right);
                return .{ .left = halves.left, .right = try concat(memory, halves.right, children.right) };
            }
            const halves = try split(memory, children.right, at - children.left.counts.bytes);
            errdefer release(memory, halves.right);
            defer release(memory, halves.left);
            return .{ .left = try concat(memory, children.left, halves.left), .right = halves.right };
        },
    }
}

pub fn byteAt(memory: *Memory, root: *const Node, position: usize) u8 {
    var node = root;
    var at = position;
    while (true) {
        memory.stats.visited_nodes +|= 1;
        switch (node.value) {
            .leaf => |bytes| return bytes[at],
            .branch => |children| if (at < children.left.counts.bytes) {
                node = children.left;
            } else {
                at -= children.left.counts.bytes;
                node = children.right;
            },
        }
    }
}
pub fn prefix(memory: *Memory, root: ?*const Node, position: usize) Counts {
    const n = root orelse return .{};
    memory.stats.visited_nodes +|= 1;
    if (position == n.counts.bytes) return n.counts;
    switch (n.value) {
        .leaf => |bytes| {
            var result: Counts = .{ .bytes = position };
            var iterator = std.unicode.Utf8View.initUnchecked(bytes[0..position]).iterator();
            while (iterator.nextCodepoint()) |cp| {
                result.scalars += 1;
                result.utf16 += if (cp > 0xffff) @as(usize, 2) else 1;
                result.lf += @intFromBool(cp == '\n');
            }
            return result;
        },
        .branch => |children| {
            if (position < children.left.counts.bytes) return prefix(memory, children.left, position);
            return Counts.add(children.left.counts, prefix(memory, children.right, position - children.left.counts.bytes)) catch unreachable;
        },
    }
}
pub fn fromUtf16(memory: *Memory, root: ?*const Node, wanted: usize) !usize {
    const n = root orelse return if (wanted == 0) 0 else error.InvalidRange;
    if (wanted > n.counts.utf16) return error.InvalidRange;
    memory.stats.visited_nodes +|= 1;
    switch (n.value) {
        .leaf => |bytes| {
            var iterator = std.unicode.Utf8View.initUnchecked(bytes).iterator();
            var units: usize = 0;
            while (units < wanted) {
                const cp = iterator.nextCodepoint().?;
                units += if (cp > 0xffff) @as(usize, 2) else 1;
            }
            if (units > wanted) return error.InvalidBoundary;
            return iterator.i;
        },
        .branch => |children| {
            if (wanted < children.left.counts.utf16) return fromUtf16(memory, children.left, wanted);
            return children.left.counts.bytes + try fromUtf16(memory, children.right, wanted - children.left.counts.utf16);
        },
    }
}
pub fn newline(memory: *Memory, root: *const Node, index: usize) usize {
    memory.stats.visited_nodes +|= 1;
    switch (root.value) {
        .leaf => |bytes| {
            var remaining = index;
            for (bytes, 0..) |byte, position| if (byte == '\n') {
                if (remaining == 0) return position;
                remaining -= 1;
            };
            unreachable;
        },
        .branch => |children| return if (index < children.left.counts.lf) newline(memory, children.left, index) else children.left.counts.bytes + newline(memory, children.right, index - children.left.counts.lf),
    }
}
pub fn read(memory: *Memory, root: ?*const Node, start: usize, destination: []u8) void {
    const n = root orelse return;
    if (destination.len == 0) return;
    memory.stats.visited_nodes +|= 1;
    switch (n.value) {
        .leaf => |bytes| @memcpy(destination, bytes[start..][0..destination.len]),
        .branch => |children| {
            if (start >= children.left.counts.bytes) return read(memory, children.right, start - children.left.counts.bytes, destination);
            const first = @min(destination.len, children.left.counts.bytes - start);
            read(memory, children.left, start, destination[0..first]);
            if (first < destination.len) read(memory, children.right, 0, destination[first..]);
        },
    }
}
