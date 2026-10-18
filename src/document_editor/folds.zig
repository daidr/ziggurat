const std = @import("std");
const d = @import("ziggurat_document");
const ix = @import("index.zig");
pub const Fold = struct { id: u64, header: usize, end: usize, collapsed: bool = false };
pub const Entry = struct { fold: Fold, first: usize, end: usize, parent: ?usize };
pub const Interval = struct { first: usize, end: usize };
const Id = struct { id: u64, index: usize };
/// Owner-thread immutable derived metadata; it never owns document text.
pub const Set = struct {
    allocator: std.mem.Allocator,
    refs: usize = 1,
    entries: []Entry,
    ids: []Id,
    intervals: []Interval,
    pub fn retain(self: *Set) *Set {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Set) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const a = self.allocator;
        a.free(self.entries);
        a.free(self.ids);
        a.free(self.intervals);
        a.destroy(self);
    }
    pub fn find(self: *const Set, id: u64) ?usize {
        var lo: usize = 0;
        var hi = self.ids.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.ids[mid].id < id) lo = mid + 1 else hi = mid;
        }
        return if (lo < self.ids.len and self.ids[lo].id == id) self.ids[lo].index else null;
    }
    pub fn hidden(self: *const Set, line: usize) bool {
        var lo: usize = 0;
        var hi = self.intervals.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.intervals[mid].first <= line) lo = mid + 1 else hi = mid;
        }
        return lo != 0 and line < self.intervals[lo - 1].end;
    }
    pub fn containing(self: *const Set, byte: usize) ?usize {
        var lo: usize = 0;
        var hi = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].fold.header < byte) lo = mid + 1 else hi = mid;
        }
        var at: ?usize = if (lo == 0) null else lo - 1;
        while (at) |index| {
            const item = self.entries[index];
            if (byte < item.fold.end) return index;
            at = item.parent;
        }
        return null;
    }
};
pub fn retain(value: ?*Set) ?*Set {
    return if (value) |set| set.retain() else null;
}
pub fn release(value: ?*Set) void {
    if (value) |set| set.release();
}
pub fn count(value: ?*const Set) usize {
    return if (value) |set| set.entries.len else 0;
}
pub fn create(allocator: std.mem.Allocator, storage: *ix.Storage, root: *ix.Node, folds: []const Fold, limit: usize) !?*Set {
    if (folds.len > limit) return error.FoldCapacityExceeded;
    if (folds.len == 0) return null;
    const entries = try allocator.alloc(Entry, folds.len);
    errdefer allocator.free(entries);
    const ids = try allocator.alloc(Id, folds.len);
    errdefer allocator.free(ids);
    const intervals = try allocator.alloc(Interval, folds.len);
    errdefer allocator.free(intervals);
    for (folds, entries) |fold, *item| item.* = .{ .fold = fold, .first = 0, .end = 0, .parent = null };
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.fold.header < b.fold.header or (a.fold.header == b.fold.header and a.fold.end > b.fold.end);
        }
    }.less);
    var stack: [64]usize = undefined;
    var depth: usize = 0;
    var effective_count: usize = 0;
    var hidden_end: usize = 0;
    for (entries, 0..) |*item, at| {
        const fold = item.fold;
        if (fold.id == 0 or fold.header >= fold.end or fold.end > root.sum.bytes) return error.InvalidFold;
        if (at != 0 and entries[at - 1].fold.header == fold.header) return error.DuplicateFoldHeader;
        const first = ix.lineAt(storage, root, fold.header);
        if (ix.prefix(storage, root, first).bytes != fold.header) return error.InvalidFoldBoundary;
        var end = ix.lineAt(storage, root, fold.end);
        if (ix.prefix(storage, root, end).bytes != fold.end) {
            if (fold.end != root.sum.bytes) return error.InvalidFoldBoundary;
            end = root.sum.rows;
        }
        if (end <= first + 1) return error.EmptyFold;
        item.first = first + 1;
        item.end = end;
        while (depth != 0 and fold.header >= entries[stack[depth - 1]].fold.end) depth -= 1;
        if (depth != 0) {
            const parent = stack[depth - 1];
            if (fold.end > entries[parent].fold.end) return error.CrossingFolds;
            item.parent = parent;
        }
        if (depth == stack.len) return error.FoldDepthExceeded;
        stack[depth] = at;
        depth += 1;
        ids[at] = .{ .id = fold.id, .index = at };
        if (fold.collapsed and item.first >= hidden_end) {
            intervals[effective_count] = .{ .first = item.first, .end = item.end };
            effective_count += 1;
            hidden_end = item.end;
        }
    }
    std.mem.sort(Id, ids, {}, struct {
        fn less(_: void, a: Id, b: Id) bool {
            return a.id < b.id;
        }
    }.less);
    for (ids[1..], ids[0 .. ids.len - 1]) |a, b| if (a.id == b.id) return error.DuplicateFoldId;
    const set = try allocator.create(Set);
    set.* = .{ .allocator = allocator, .entries = entries, .ids = ids, .intervals = intervals[0..effective_count] };
    // Keep the allocated capacity in the slice: free must receive the original length.
    if (effective_count != intervals.len) {
        const compact = allocator.dupe(Interval, intervals[0..effective_count]) catch |err| {
            allocator.destroy(set);
            return err;
        };
        allocator.free(intervals);
        set.intervals = compact;
    }
    return set;
}
/// Apply only the symmetric difference of effective outer collapsed intervals.
/// Child state beneath a collapsed parent remains in Set but does not touch rows.
pub fn apply(storage: *ix.Storage, root: *ix.Node, before: ?*const Set, after: ?*const Set) !*ix.Node {
    const a: []const Interval = if (before) |s| s.intervals else &.{};
    const b: []const Interval = if (after) |s| s.intervals else &.{};
    var ai: usize = 0;
    var bi: usize = 0;
    var active_a = false;
    var active_b = false;
    var position: usize = 0;
    var candidate = ix.retain(root).?;
    errdefer ix.release(storage, candidate);
    while (true) {
        const ae = if (ai < a.len) (if (active_a) a[ai].end else a[ai].first) else std.math.maxInt(usize);
        const be = if (bi < b.len) (if (active_b) b[bi].end else b[bi].first) else std.math.maxInt(usize);
        const next = @min(ae, be);
        if (next == std.math.maxInt(usize)) break;
        if (position < next and active_a != active_b) {
            const updated = try ix.setHidden(storage, candidate, position, next, active_b);
            ix.release(storage, candidate);
            candidate = updated;
        }
        position = next;
        if (ae == next) {
            if (active_a) {
                ai += 1;
                active_a = false;
            } else active_a = true;
        }
        if (be == next) {
            if (active_b) {
                bi += 1;
                active_b = false;
            } else active_b = true;
        }
    }
    return candidate;
}
pub fn changed(allocator: std.mem.Allocator, storage: *ix.Storage, root: *ix.Node, old: ?*const Set, id: u64, collapsed: bool, selected: []const d.Selection, limit: usize) !?*Set {
    const previous = old orelse return error.FoldNotFound;
    const index = previous.find(id) orelse return error.FoldNotFound;
    const items = try allocator.alloc(Fold, previous.entries.len);
    defer allocator.free(items);
    for (items, previous.entries) |*item, entry| item.* = entry.fold;
    items[index].collapsed = collapsed;
    const candidate = try create(allocator, storage, root, items, limit);
    errdefer release(candidate);
    if (collapsed) for (selected) |selection| if (candidate.?.hidden(ix.lineAt(storage, root, selection.caret))) return error.CaretInsideFold;
    return candidate;
}
pub fn expanded(allocator: std.mem.Allocator, storage: *ix.Storage, root: *ix.Node, old: ?*const Set, byte: usize, limit: usize) !?*Set {
    const previous = old orelse return null;
    var at = previous.containing(byte);
    var needed = false;
    while (at) |index| {
        const item = previous.entries[index];
        if (item.fold.collapsed and ix.lineAt(storage, root, byte) >= item.first) needed = true;
        at = item.parent;
    }
    if (!needed) return @constCast(previous).retain();
    const items = try allocator.alloc(Fold, previous.entries.len);
    defer allocator.free(items);
    for (items, previous.entries) |*item, entry| item.* = entry.fold;
    at = previous.containing(byte);
    while (at) |index| {
        const item = previous.entries[index];
        if (ix.lineAt(storage, root, byte) >= item.first) items[index].collapsed = false;
        at = item.parent;
    }
    return create(allocator, storage, root, items, limit);
}
pub fn merge(allocator: std.mem.Allocator, storage: *ix.Storage, root: *ix.Node, ranges: ?*const Set, states: ?*const Set, limit: usize) !?*Set {
    const source = ranges orelse return null;
    const items = try allocator.alloc(Fold, source.entries.len);
    defer allocator.free(items);
    for (items, source.entries) |*item, entry| {
        item.* = entry.fold;
        if (states) |current| if (current.find(item.id)) |index| {
            item.collapsed = current.entries[index].fold.collapsed;
        };
    }
    return create(allocator, storage, root, items, limit);
}
fn mapPosition(edits: []const d.Replacement, ends: []const usize, byte: usize, after: bool) usize {
    var lo: usize = 0;
    var hi = edits.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (edits[mid].range.start <= byte) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return byte;
    const at = lo - 1;
    const edit = edits[at];
    if (byte <= edit.range.end) return if (after) ends[at] else ends[at] - edit.text.len;
    return ends[at] + byte - edit.range.end;
}
/// Build ranges in the candidate text coordinates; header edits drop that ID.
pub fn mapped(allocator: std.mem.Allocator, storage: *ix.Storage, old_root: *ix.Node, root: *ix.Node, old: ?*const Set, edits: []const d.Replacement, limit: usize) !?*Set {
    const previous = old orelse return null;
    const ends = try allocator.alloc(usize, edits.len);
    defer allocator.free(ends);
    var old_end: usize = 0;
    var new_end: usize = 0;
    for (edits, ends) |edit, *end| {
        new_end = std.math.add(usize, new_end, edit.range.start - old_end) catch return error.CapacityExceeded;
        new_end = std.math.add(usize, new_end, edit.text.len) catch return error.CapacityExceeded;
        end.* = new_end;
        old_end = edit.range.end;
    }
    const items = try allocator.alloc(Fold, previous.entries.len);
    defer allocator.free(items);
    var count_: usize = 0;
    for (previous.entries) |entry| {
        const header_end = ix.prefix(storage, old_root, entry.first).bytes;
        var lo: usize = 0;
        var hi = edits.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (edits[mid].range.end < entry.fold.header) lo = mid + 1 else hi = mid;
        }
        var invalid = false;
        while (lo < edits.len and edits[lo].range.start < header_end) : (lo += 1) {
            if (edits[lo].range.end > entry.fold.header or edits[lo].range.start >= entry.fold.header) {
                invalid = true;
                break;
            }
        }
        if (invalid) continue;
        const header = mapPosition(edits, ends, entry.fold.header, true);
        const end = mapPosition(edits, ends, entry.fold.end, false);
        if (header >= end or end > root.sum.bytes) continue;
        const first_row = ix.lineAt(storage, root, header);
        if (ix.prefix(storage, root, first_row).bytes != header) continue;
        var end_row = ix.lineAt(storage, root, end);
        if (ix.prefix(storage, root, end_row).bytes != end) {
            if (end != root.sum.bytes) continue;
            end_row = root.sum.rows;
        }
        if (end_row <= first_row + 1) continue;
        items[count_] = .{ .id = entry.fold.id, .header = header, .end = end, .collapsed = entry.fold.collapsed };
        count_ += 1;
    }
    return create(allocator, storage, root, items[0..count_], limit);
}
