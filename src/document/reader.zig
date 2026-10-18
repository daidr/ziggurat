const std = @import("std");
const tree = @import("tree.zig");
const selection = @import("selections.zig");
pub const Range = selection.Range;
pub const Slot = struct {
    state: std.atomic.Value(u64) = .init(0),
    active: *std.atomic.Value(usize),
    root: ?*const tree.Node,
    revision: u64,
    text_version: u64,
    pub fn borrow(self: *Slot) ?Reader {
        const generation = self.state.load(.acquire);
        if (generation & 1 != 0 or generation > std.math.maxInt(u64) - 3) return null;
        _ = self.active.fetchAdd(1, .monotonic);
        self.state.store(generation + 1, .release);
        return .{ .slot = self, .generation = generation + 1 };
    }
};
/// A single explicit read lease, transferred by the host to at most one worker.
/// Queries borrow it; release follows all queries/cursors and never frees a root.
/// After Snapshot.close every copy, including release, is invalid to call.
pub const Reader = struct {
    slot: *Slot,
    generation: u64,
    fn checked(self: Reader) !*const Slot {
        if (self.slot.state.load(.acquire) != self.generation) return error.ReaderClosed;
        return self.slot;
    }
    pub fn release(self: Reader) !void {
        const active = self.slot.active;
        if (self.slot.state.cmpxchgStrong(self.generation, self.generation + 1, .acq_rel, .acquire) != null) return error.ReaderClosed;
        // This is the last access to snapshot-owned memory. The owner may
        // acquire zero and reclaim this slot immediately after fetchSub.
        _ = active.fetchSub(1, .release);
    }
    pub fn version(self: Reader) !u64 {
        return (try self.checked()).revision;
    }
    pub fn committedTextVersion(self: Reader) !u64 {
        return (try self.checked()).text_version;
    }
    pub fn byteLength(self: Reader) !usize {
        return tree.counts((try self.checked()).root).bytes;
    }
    pub fn utf16Length(self: Reader) !usize {
        return tree.counts((try self.checked()).root).utf16;
    }
    pub fn scalarLength(self: Reader) !usize {
        return tree.counts((try self.checked()).root).scalars;
    }
    pub fn lineCount(self: Reader) !usize {
        return tree.counts((try self.checked()).root).lf + 1;
    }
    pub fn cursor(self: Reader, range: Range) !Cursor {
        const root = (try self.checked()).root;
        try validRange(root, range);
        var result: Cursor = .{ .reader = self, .position = range.start, .end = range.end };
        if (range.start != range.end) result.seek(root.?, 0, range.start);
        return result;
    }
    pub fn read(self: Reader, range: Range, destination: []u8) !usize {
        var iterator = try self.cursor(range);
        const count = range.end - range.start;
        if (destination.len < count) return error.CapacityExceeded;
        var at: usize = 0;
        while (try iterator.next()) |part| {
            @memcpy(destination[at..][0..part.bytes.len], part.bytes);
            at += part.bytes.len;
        }
        return count;
    }
    pub fn utf16Offset(self: Reader, byte: usize) !usize {
        const root = (try self.checked()).root;
        try validRange(root, .{ .start = byte, .end = byte });
        return prefix(root, byte).utf16;
    }
    pub fn byteOffsetFromUtf16(self: Reader, units: usize) !usize {
        const root = (try self.checked()).root;
        if (units > tree.counts(root).utf16) return error.InvalidRange;
        return fromUtf16(root, units);
    }
    pub fn lineAt(self: Reader, byte: usize) !usize {
        const root = (try self.checked()).root;
        try validRange(root, .{ .start = byte, .end = byte });
        return prefix(root, byte).lf;
    }
    pub fn line(self: Reader, index: usize) !Range {
        const root = (try self.checked()).root;
        const sum = tree.counts(root);
        if (index > sum.lf) return error.InvalidRange;
        return .{ .start = if (index == 0) 0 else newline(root.?, index - 1) + 1, .end = if (index == sum.lf) sum.bytes else newline(root.?, index) };
    }
};
pub const Segment = struct { start: usize, bytes: []const u8 };
const Pending = struct { node: *const tree.Node, base: usize };
pub const Cursor = struct {
    reader: Reader,
    position: usize,
    end: usize,
    pending: [tree.max_depth]Pending = undefined,
    count: usize = 0,
    leaf: ?*const tree.Node = null,
    base: usize = 0,
    fn seek(self: *Cursor, root: *const tree.Node, base: usize, offset: usize) void {
        var node = root;
        var at = offset;
        var start = base;
        while (node.value == .branch) {
            const children = node.value.branch;
            if (at < children.left.counts.bytes) {
                self.pending[self.count] = .{ .node = children.right, .base = start + children.left.counts.bytes };
                self.count += 1;
                node = children.left;
            } else {
                at -= children.left.counts.bytes;
                start += children.left.counts.bytes;
                node = children.right;
            }
        }
        self.leaf = node;
        self.base = start;
    }
    pub fn next(self: *Cursor) !?Segment {
        _ = try self.reader.checked();
        if (self.position == self.end) return null;
        if (self.leaf == null) {
            std.debug.assert(self.count != 0);
            self.count -= 1;
            const part = self.pending[self.count];
            self.seek(part.node, part.base, 0);
        }
        const node = self.leaf.?;
        const offset = self.position - self.base;
        const count = @min(node.counts.bytes - offset, self.end - self.position);
        const result: Segment = .{ .start = self.position, .bytes = node.value.leaf[offset..][0..count] };
        self.position += count;
        self.leaf = null;
        return result;
    }
};
fn byteAt(root: *const tree.Node, position: usize) u8 {
    var node = root;
    var at = position;
    while (node.value == .branch) {
        const children = node.value.branch;
        if (at < children.left.counts.bytes) node = children.left else {
            at -= children.left.counts.bytes;
            node = children.right;
        }
    }
    return node.value.leaf[at];
}
fn validRange(root: ?*const tree.Node, range: Range) !void {
    const length = tree.counts(root).bytes;
    if (range.start > range.end or range.end > length) return error.InvalidRange;
    for ([_]usize{ range.start, range.end }) |at| if (at < length and byteAt(root.?, at) & 0xc0 == 0x80) return error.InvalidBoundary;
}
fn prefix(root: ?*const tree.Node, position: usize) tree.Counts {
    const node = root orelse return .{};
    if (position == node.counts.bytes) return node.counts;
    switch (node.value) {
        .leaf => |bytes| {
            var result: tree.Counts = .{ .bytes = position };
            var iterator = std.unicode.Utf8View.initUnchecked(bytes[0..position]).iterator();
            while (iterator.nextCodepoint()) |cp| {
                result.scalars += 1;
                result.utf16 += if (cp > 0xffff) @as(usize, 2) else 1;
                result.lf += @intFromBool(cp == '\n');
            }
            return result;
        },
        .branch => |children| {
            if (position < children.left.counts.bytes) return prefix(children.left, position);
            const rest = prefix(children.right, position - children.left.counts.bytes);
            return .{ .bytes = children.left.counts.bytes + rest.bytes, .scalars = children.left.counts.scalars + rest.scalars, .utf16 = children.left.counts.utf16 + rest.utf16, .lf = children.left.counts.lf + rest.lf };
        },
    }
}
fn fromUtf16(root: ?*const tree.Node, units: usize) !usize {
    const node = root orelse return 0;
    switch (node.value) {
        .leaf => |bytes| {
            var iterator = std.unicode.Utf8View.initUnchecked(bytes).iterator();
            var used: usize = 0;
            while (used < units) {
                const cp = iterator.nextCodepoint().?;
                used += if (cp > 0xffff) @as(usize, 2) else 1;
            }
            if (used > units) return error.InvalidBoundary;
            return iterator.i;
        },
        .branch => |children| {
            if (units < children.left.counts.utf16) return fromUtf16(children.left, units);
            return children.left.counts.bytes + try fromUtf16(children.right, units - children.left.counts.utf16);
        },
    }
}
fn newline(node: *const tree.Node, index: usize) usize {
    switch (node.value) {
        .leaf => |bytes| {
            var remaining = index;
            for (bytes, 0..) |byte, at| if (byte == '\n') {
                if (remaining == 0) return at;
                remaining -= 1;
            };
            unreachable;
        },
        .branch => |children| return if (index < children.left.counts.lf) newline(children.left, index) else children.left.counts.bytes + newline(children.right, index - children.left.counts.lf),
    }
}
