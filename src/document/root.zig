const std = @import("std");
const z = @import("ziggurat");
const tree = @import("tree.zig");
const reader = @import("reader.zig");
pub const Reader = reader.Reader;
pub const Cursor = reader.Cursor;
pub const search = @import("search.zig");
pub const ClientBinding = @import("client.zig").Binding;
pub const leaf_bytes = tree.leaf_bytes;
pub const Position = usize;
const selection_state = @import("selections.zig");
pub const Range = selection_state.Range;
pub const Selection = selection_state.Selection;
pub const SelectionList = selection_state.View;
pub const Replacement = selection_state.Replacement;
/// Transient publication gate. validate runs owner-thread with Document Busy,
/// after candidate preparation and immediately before the no-foreign commit.
/// It must not allocate, mutate this Document, end its scope, or free context.
pub const CommitGuard = struct { context: *anyopaque, validate: *const fn (*anyopaque) anyerror!void };
/// Stable, linear owner borrow. end is idempotent; an old generation cannot
/// revoke a later guard. Document/context storage covers the entire scope.
pub const CommitGuardScope = struct {
    document: *Document,
    generation: u64,
    pub fn end(self: CommitGuardScope) void {
        const value: *State = @ptrCast(@alignCast(self.document));
        checkOwner(value.arena) catch unreachable;
        std.debug.assert(!value.busy);
        if (value.guard_generation == self.generation) value.commit_guard = null;
    }
};
pub const Limits = struct {
    document_bytes: usize = 64 * 1024 * 1024,
    nodes: usize = 131072,
    /// All live allocations, including snapshots, history and edit candidates.
    live_bytes: usize = 256 * 1024 * 1024,
    /// Additional simultaneous live bytes above an edit's starting footprint.
    candidate_bytes: usize = 32 * 1024 * 1024,
    history_entries: usize = 128,
    snapshots: usize = 128,
    composition_bytes: usize = 4096,
    selections: usize = 64,
    batch_edits: usize = 4096,
    readers_per_snapshot: usize = 8,
};
pub const Stats = struct {
    owned_bytes: usize,
    peak_bytes: usize,
    nodes: usize,
    snapshots: usize,
    height: u8,
    copied_bytes: u64,
    visited_nodes: u64,
    reclaimed_nodes: u64,
    candidate_peak_bytes: usize,
};
pub const Composition = struct { range: Range, text: []const u8, selection: Selection };
const Arena = struct {
    memory: tree.Memory,
    owner: std.Thread.Id,
    limits: Limits,
    refs: usize = 1,
    snapshots: usize = 0,
};
const Version = struct { root: ?*tree.Node, selected: selection_state.Set };
const Edit = struct { before: Version, after: Version };
const State = struct {
    arena: *Arena,
    root: ?*tree.Node = null,
    selected: selection_state.Set = .{ .single = .{} },
    revision: u64 = 0,
    text_version: u64 = 0,
    busy: bool = false,
    commit_guard: ?CommitGuard = null,
    guard_generation: u64 = 0,
    bindings: usize = 0,
    history: []Edit,
    history_start: usize = 0,
    history_len: usize = 0,
    history_cursor: usize = 0,
    preedit: []u8,
    preedit_len: usize = 0,
    preedit_range: ?Range = null,
    preedit_selection: Selection = .{},

    fn historyAt(self: *State, index: usize) *Edit {
        return &self.history[(self.history_start + index) % self.history.len];
    }
    fn dropEdit(self: *State, value: Edit) void {
        tree.release(&self.arena.memory, value.before.root);
        tree.release(&self.arena.memory, value.after.root);
        value.before.selected.release(&self.arena.memory);
        value.after.selected.release(&self.arena.memory);
    }
    fn validateCommit(self: *State) !void {
        std.debug.assert(self.busy);
        if (self.commit_guard) |guard| try guard.validate(guard.context);
    }
    fn publish(self: *State, candidate: ?*tree.Node, selected: selection_state.Set) !void {
        // No allocation/free/native call occurs between this final gate and
        // root/selection/version publication. Foreign reclamation follows it.
        try self.validateCommit();
        const entry: ?Edit = if (self.history.len != 0) .{ .before = .{ .root = tree.retain(self.root), .selected = self.selected.retain() }, .after = .{ .root = tree.retain(candidate), .selected = selected.retain() } } else null;
        const old = self.root;
        const old_selected = self.selected;
        self.root = candidate;
        self.selected = selected;
        self.revision += 1;
        self.text_version += 1;
        self.preedit_range = null;
        self.preedit_len = 0;
        if (entry) |history_entry| {
            while (self.history_len > self.history_cursor) {
                self.history_len -= 1;
                self.dropEdit(self.historyAt(self.history_len).*);
            }
            if (self.history_len == self.history.len) {
                self.dropEdit(self.historyAt(0).*);
                self.history_start = (self.history_start + 1) % self.history.len;
                self.history_len -= 1;
                self.history_cursor -= 1;
            }
            self.historyAt(self.history_len).* = history_entry;
            self.history_len += 1;
            self.history_cursor = self.history_len;
        }
        tree.release(&self.arena.memory, old);
        old_selected.release(&self.arena.memory);
    }
    fn checkRevision(self: *State) !void {
        if (self.revision == std.math.maxInt(u64)) return error.IdExhausted;
    }
    fn checkTextRevision(self: *State) !void {
        try self.checkRevision();
        if (self.text_version == std.math.maxInt(u64)) return error.IdExhausted;
    }
    fn replace(self: *State, range: Range, inserted: []const u8) !void {
        try validateRange(self.arena, self.root, range);
        if (!std.unicode.utf8ValidateSlice(inserted)) return error.InvalidUtf8;
        try self.checkTextRevision();
        const retained = tree.counts(self.root).bytes - (range.end - range.start);
        if (inserted.len > self.arena.limits.document_bytes - retained) return error.CapacityExceeded;
        self.arena.memory.begin();
        defer self.arena.memory.end();
        const first = try tree.split(&self.arena.memory, self.root, range.start);
        defer tree.release(&self.arena.memory, first.left);
        defer tree.release(&self.arena.memory, first.right);
        const second = try tree.split(&self.arena.memory, first.right, range.end - range.start);
        defer tree.release(&self.arena.memory, second.left);
        defer tree.release(&self.arena.memory, second.right);
        const middle = try tree.build(&self.arena.memory, inserted);
        defer tree.release(&self.arena.memory, middle);
        const left = try tree.concat(&self.arena.memory, first.left, middle);
        defer tree.release(&self.arena.memory, left);
        const candidate = try tree.concat(&self.arena.memory, left, second.right);
        errdefer tree.release(&self.arena.memory, candidate);
        const after = range.start + inserted.len;
        try self.publish(candidate, .{ .single = .{ .anchor = after, .caret = after } });
    }
    fn splice(self: *State, root: ?*tree.Node, range: Range, inserted: []const u8) !?*tree.Node {
        const a = try tree.split(&self.arena.memory, root, range.start);
        defer tree.release(&self.arena.memory, a.left);
        defer tree.release(&self.arena.memory, a.right);
        const b = try tree.split(&self.arena.memory, a.right, range.end - range.start);
        defer tree.release(&self.arena.memory, b.left);
        defer tree.release(&self.arena.memory, b.right);
        const middle = try tree.build(&self.arena.memory, inserted);
        defer tree.release(&self.arena.memory, middle);
        const prefix_root = try tree.concat(&self.arena.memory, a.left, middle);
        defer tree.release(&self.arena.memory, prefix_root);
        return tree.concat(&self.arena.memory, prefix_root, b.right);
    }
    fn mapped(position: usize, edits: []const Replacement, new_ends: []const usize, affinity: selection_state.Affinity) usize {
        var low: usize = 0;
        var high = edits.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (edits[middle].range.start < position or (edits[middle].range.start == position and affinity == .after)) low = middle + 1 else high = middle;
        }
        if (low == 0) return position;
        const at = low - 1;
        return new_ends[at] + (position -| edits[at].range.end);
    }
    fn replaceBatch(self: *State, edits: []const Replacement, collapse: bool) !void {
        return self.replaceBatchSelected(edits, collapse, null);
    }
    fn replaceBatchSelected(self: *State, edits: []const Replacement, collapse: bool, explicit: ?SelectionList) !void {
        if (edits.len == 0) return;
        if (edits.len > self.arena.limits.batch_edits) return error.CapacityExceeded;
        try self.checkTextRevision();
        var retained = tree.counts(self.root).bytes;
        var inserted: usize = 0;
        var previous: ?Range = null;
        for (edits) |edit| {
            try validateRange(self.arena, self.root, edit.range);
            if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
            if (previous) |before| if (edit.range.start <= before.start or edit.range.start < before.end or (edit.range.start == before.end and (edit.range.start == edit.range.end or before.start == before.end))) return error.OverlappingEdits;
            previous = edit.range;
            retained -= edit.range.end - edit.range.start;
            inserted = std.math.add(usize, inserted, edit.text.len) catch return error.CapacityExceeded;
        }
        if (inserted > self.arena.limits.document_bytes - retained) return error.CapacityExceeded;
        const ends = try self.arena.memory.alloc(usize, edits.len);
        defer self.arena.memory.free(usize, ends);
        var old_end: usize = 0;
        var new_end: usize = 0;
        for (edits, 0..) |edit, at| {
            new_end += edit.range.start - old_end + edit.text.len;
            ends[at] = new_end;
            old_end = edit.range.end;
        }
        var candidate = tree.retain(self.root);
        errdefer tree.release(&self.arena.memory, candidate);
        var at = edits.len;
        while (at != 0) {
            at -= 1;
            const next = try self.splice(candidate, edits[at].range, edits[at].text);
            tree.release(&self.arena.memory, candidate);
            candidate = next;
        }
        if (explicit) |selection| {
            for (selection.items) |item| try validateSelection(self.arena, candidate, item);
            const selected = try selection_state.normalized(&self.arena.memory, selection.items, selection.primary, self.arena.limits.selections);
            errdefer selected.release(&self.arena.memory);
            try self.publish(candidate, selected);
            return;
        }
        const count = if (collapse) edits.len else self.selected.count();
        const output = try self.arena.memory.alloc(Selection, count);
        defer self.arena.memory.free(Selection, output);
        if (collapse) {
            for (output, ends) |*selected, end| selected.* = .{ .anchor = end, .caret = end };
        } else for (output, 0..) |*selected, index| {
            const old = self.selected.at(index);
            selected.* = .{
                .anchor = mapped(old.anchor, edits, ends, if (old.anchor < old.caret) .before else .after),
                .caret = mapped(old.caret, edits, ends, if (old.caret < old.anchor) .before else .after),
            };
        }
        const selected = try selection_state.normalized(&self.arena.memory, output, self.selected.primaryIndex(), self.arena.limits.selections);
        errdefer selected.release(&self.arena.memory);
        try self.publish(candidate, selected);
    }
    fn replaceSelections(self: *State, inserted: []const u8) !void {
        if (self.selected == .single) return self.replace(self.selected.single.range(), inserted);
        self.arena.memory.begin();
        defer self.arena.memory.end();
        const edits = try self.arena.memory.alloc(Replacement, self.selected.count());
        defer self.arena.memory.free(Replacement, edits);
        for (edits, 0..) |*edit, index| edit.* = .{ .range = self.selected.at(index).range(), .text = inserted };
        try self.replaceBatch(edits, true);
    }
};
const SnapshotState = struct { arena: *Arena, root: ?*tree.Node, selected: selection_state.Set, revision: u64, text_version: u64, busy: bool = false, reader_slots: []reader.Slot = &.{}, active_readers: std.atomic.Value(usize) = .init(0) };

fn releaseArena(arena: *Arena) void {
    arena.refs -= 1;
    if (arena.refs == 0) {
        std.debug.assert(arena.memory.stats.live_nodes == 0 and arena.memory.stats.live_bytes == @sizeOf(Arena));
        const allocator = arena.memory.allocator;
        allocator.destroy(arena);
    }
}
fn checkOwner(arena: *const Arena) !void {
    if (std.Thread.getCurrentId() != arena.owner) return error.WrongThread;
}
fn boundary(arena: *Arena, root: ?*tree.Node, at: usize) bool {
    const length = tree.counts(root).bytes;
    return at <= length and (at == length or tree.byteAt(&arena.memory, root.?, at) & 0xc0 != 0x80);
}
fn validateRange(arena: *Arena, root: ?*tree.Node, range: Range) !void {
    if (range.start > range.end or range.end > tree.counts(root).bytes) return error.InvalidRange;
    if (!boundary(arena, root, range.start) or !boundary(arena, root, range.end)) return error.InvalidBoundary;
}
fn validateSelection(arena: *Arena, root: ?*tree.Node, selected: Selection) !void {
    try validateRange(arena, root, selected.range());
}
fn readRange(arena: *Arena, root: ?*tree.Node, range: Range, destination: []u8) !usize {
    try validateRange(arena, root, range);
    const length = range.end - range.start;
    if (length > destination.len) return error.CapacityExceeded;
    tree.read(&arena.memory, root, range.start, destination[0..length]);
    return length;
}
fn utf16(arena: *Arena, root: ?*tree.Node, at: usize) !usize {
    if (at > tree.counts(root).bytes) return error.InvalidRange;
    if (!boundary(arena, root, at)) return error.InvalidBoundary;
    return tree.prefix(&arena.memory, root, at).utf16;
}
fn lineRange(arena: *Arena, root: ?*tree.Node, index: usize) !Range {
    const sum = tree.counts(root);
    if (index > sum.lf) return error.InvalidRange;
    return .{ .start = if (index == 0) 0 else tree.newline(&arena.memory, root.?, index - 1) + 1, .end = if (index == sum.lf) sum.bytes else tree.newline(&arena.memory, root.?, index) };
}
fn writeNode(root: ?*tree.Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = root orelse return;
    switch (n.value) {
        .leaf => |bytes| try writer.writeAll(bytes),
        .branch => |children| {
            try writeNode(children.left, writer);
            try writeNode(children.right, writer);
        },
    }
}
fn capture(arena: *Arena, root: ?*tree.Node, selected: selection_state.Set, revision: u64, text_version: u64) !*Snapshot {
    if (arena.snapshots == arena.limits.snapshots) return error.CapacityExceeded;
    const state = try arena.memory.create(SnapshotState);
    state.* = .{ .arena = arena, .root = tree.retain(root), .selected = selected.retain(), .revision = revision, .text_version = text_version };
    arena.snapshots += 1;
    arena.refs += 1;
    return @ptrCast(state);
}

/// Stable owner. Allocator outlives Document and every owning Snapshot. All
/// operations, including immutable queries/close, use the supplied owner thread.
/// Positions/ranges are UTF-8 byte offsets at scalar boundaries. Explicit UTF16
/// queries reject the interior of a surrogate pair; no implicit snapping occurs.
pub const Document = opaque {
    fn state(self: *const Document) !*State {
        const value: *State = @ptrCast(@alignCast(@constCast(self)));
        try checkOwner(value.arena);
        if (value.busy) return error.Busy;
        return value;
    }
    pub fn create(allocator: std.mem.Allocator, owner: std.Thread.Id, initial: []const u8, limits: Limits) !*Document {
        if (std.Thread.getCurrentId() != owner) return error.WrongThread;
        if (limits.document_bytes == 0 or limits.document_bytes > 1024 * 1024 * 1024 or limits.nodes == 0 or limits.nodes > 1024 * 1024 or limits.live_bytes > std.math.maxInt(usize) / 2 or limits.candidate_bytes > limits.live_bytes or limits.history_entries > 4096 or limits.snapshots > 4096 or limits.composition_bytes > 64 * 1024 or limits.selections == 0 or limits.selections > 4096 or limits.batch_edits == 0 or limits.batch_edits > 65536 or limits.readers_per_snapshot > 64) return error.InvalidLimits;
        if (initial.len > limits.document_bytes) return error.CapacityExceeded;
        if (!std.unicode.utf8ValidateSlice(initial)) return error.InvalidUtf8;
        if (limits.live_bytes < @sizeOf(Arena)) return error.CapacityExceeded;
        const arena = try allocator.create(Arena);
        errdefer allocator.destroy(arena);
        arena.* = .{ .owner = owner, .limits = limits, .memory = .{ .allocator = allocator, .limits = .{ .live_bytes = limits.live_bytes, .nodes = limits.nodes, .candidate_bytes = limits.candidate_bytes }, .stats = .{ .live_bytes = @sizeOf(Arena), .peak_bytes = @sizeOf(Arena) } } };
        const value = try arena.memory.create(State);
        errdefer arena.memory.destroy(State, value);
        const history = try arena.memory.alloc(Edit, limits.history_entries);
        errdefer arena.memory.free(Edit, history);
        const preedit = try arena.memory.alloc(u8, limits.composition_bytes);
        errdefer arena.memory.free(u8, preedit);
        // Initial construction is an explicit full-document allocation. The
        // candidate allowance applies to later edits above their current size.
        const root = try tree.build(&arena.memory, initial);
        value.* = .{ .arena = arena, .root = root, .history = history, .preedit = preedit, .selected = .{ .single = .{ .anchor = initial.len, .caret = initial.len } } };
        return @ptrCast(value);
    }
    pub fn close(self: *Document) !void {
        const value = try self.state();
        if (value.bindings != 0) return error.ClientAttached;
        if (value.commit_guard != null) return error.CommitGuardActive;
        value.busy = true;
        const arena = value.arena;
        tree.release(&arena.memory, value.root);
        value.selected.release(&arena.memory);
        for (0..value.history_len) |index| value.dropEdit(value.historyAt(index).*);
        arena.memory.free(Edit, value.history);
        arena.memory.free(u8, value.preedit);
        arena.memory.destroy(State, value);
        releaseArena(arena);
    }
    /// One explicit transient gate; no allocation or UI dependency. Host keeps
    /// its context alive, invokes a mutator, then ends this scope exactly once.
    pub fn beginCommitGuard(self: *Document, guard: CommitGuard) !CommitGuardScope {
        const value = try self.state();
        if (value.commit_guard != null) return error.CommitGuardActive;
        if (value.guard_generation == std.math.maxInt(u64)) return error.IdExhausted;
        value.guard_generation += 1;
        value.commit_guard = guard;
        return .{ .document = self, .generation = value.guard_generation };
    }
    pub fn byteLength(self: *const Document) !usize {
        return tree.counts((try self.state()).root).bytes;
    }
    pub fn utf16Length(self: *const Document) !usize {
        return tree.counts((try self.state()).root).utf16;
    }
    pub fn scalarLength(self: *const Document) !usize {
        return tree.counts((try self.state()).root).scalars;
    }
    pub fn lineCount(self: *const Document) !usize {
        return tree.counts((try self.state()).root).lf + 1;
    }
    pub fn version(self: *const Document) !u64 {
        return (try self.state()).revision;
    }
    /// Monotonic committed-text publication stamp. Selection and IME preview
    /// do not change it; replacement, restore, undo and redo do, even when the
    /// resulting bytes happen to be equal. Exhaustion rejects text mutations.
    pub fn committedTextVersion(self: *const Document) !u64 {
        return (try self.state()).text_version;
    }
    pub fn read(self: *const Document, range: Range, destination: []u8) !usize {
        const value = try self.state();
        return readRange(value.arena, value.root, range, destination);
    }
    pub fn utf16Offset(self: *const Document, byte_offset: usize) !usize {
        const value = try self.state();
        return utf16(value.arena, value.root, byte_offset);
    }
    pub fn byteOffsetFromUtf16(self: *const Document, units: usize) !usize {
        const value = try self.state();
        return tree.fromUtf16(&value.arena.memory, value.root, units);
    }
    /// LF terminates a line. A preceding CR stays in the returned byte range;
    /// loading never silently normalizes the source document. Terminal LF adds
    /// a final empty line. Invalid line indices are rejected rather than clamped.
    pub fn line(self: *const Document, index: usize) !Range {
        const value = try self.state();
        return lineRange(value.arena, value.root, index);
    }
    pub fn lineAt(self: *const Document, byte_offset: usize) !usize {
        const value = try self.state();
        _ = try utf16(value.arena, value.root, byte_offset);
        return tree.prefix(&value.arena.memory, value.root, byte_offset).lf;
    }
    pub fn writeTo(self: *const Document, writer: *std.Io.Writer) !void {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        try writeNode(value.root, writer);
    }
    pub fn selection(self: *const Document) !Selection {
        return (try self.state()).selected.primary();
    }
    pub fn setSelection(self: *Document, selected: Selection) !bool {
        const value = try self.state();
        if (value.preedit_range != null) return error.CompositionActive;
        try validateSelection(value.arena, value.root, selected);
        if (value.selected == .single and std.meta.eql(selected, value.selected.single)) return false;
        try value.checkRevision();
        const old_selected = value.selected;
        value.busy = true;
        defer value.busy = false;
        try value.validateCommit();
        value.selected = .{ .single = selected };
        value.revision += 1;
        old_selected.release(&value.arena.memory);
        return true;
    }
    pub fn selectionCount(self: *const Document) !usize {
        return (try self.state()).selected.count();
    }
    pub fn selections(self: *const Document, destination: []Selection) !SelectionList {
        return (try self.state()).selected.copy(destination);
    }
    /// Canonicalizes document order, duplicate carets and overlapping ranges.
    /// The merged primary retains the primary input's direction.
    pub fn setSelections(self: *Document, input: []const Selection, primary: usize) !bool {
        const value = try self.state();
        if (value.preedit_range != null) return error.CompositionActive;
        if (input.len == 0 or primary >= input.len) return error.InvalidSelections;
        if (input.len > value.arena.limits.selections) return error.CapacityExceeded;
        for (input) |selected| try validateSelection(value.arena, value.root, selected);
        try value.checkRevision();
        value.busy = true;
        defer value.busy = false;
        value.arena.memory.begin();
        defer value.arena.memory.end();
        const candidate = try selection_state.normalized(&value.arena.memory, input, primary, value.arena.limits.selections);
        if (candidate.eql(value.selected)) {
            candidate.release(&value.arena.memory);
            return false;
        }
        errdefer candidate.release(&value.arena.memory);
        try value.validateCommit();
        const old = value.selected;
        value.selected = candidate;
        value.revision += 1;
        old.release(&value.arena.memory);
        return true;
    }
    /// All edits use the supplied revision's original byte coordinates.
    /// Sorted disjoint edits publish one text/selection version and one undo.
    pub fn replaceMany(self: *Document, expected_revision: u64, edits: []const Replacement) !void {
        const value = try self.state();
        if (value.revision != expected_revision) return error.StaleRevision;
        if (value.preedit_range != null) return error.CompositionActive;
        value.busy = true;
        defer value.busy = false;
        value.arena.memory.begin();
        defer value.arena.memory.end();
        try value.replaceBatch(edits, false);
    }
    /// Edits use original byte coordinates; selections use the resulting text.
    /// Candidate validation/normalization precede one text/selection commit.
    /// Undo restores the original selections; redo restores these selections.
    pub fn replaceManyWithSelections(self: *Document, expected_revision: u64, edits: []const Replacement, final_selections: []const Selection, primary: usize) !void {
        const value = try self.state();
        if (value.revision != expected_revision) return error.StaleRevision;
        if (value.preedit_range != null) return error.CompositionActive;
        if (edits.len == 0) return error.EmptyEdits;
        if (final_selections.len == 0 or primary >= final_selections.len) return error.InvalidSelections;
        if (final_selections.len > value.arena.limits.selections) return error.CapacityExceeded;
        value.busy = true;
        defer value.busy = false;
        value.arena.memory.begin();
        defer value.arena.memory.end();
        try value.replaceBatchSelected(edits, false, .{ .items = final_selections, .primary = primary });
    }
    pub fn replaceSelections(self: *Document, inserted: []const u8) !void {
        const value = try self.state();
        if (value.preedit_range != null) return error.CompositionActive;
        value.busy = true;
        defer value.busy = false;
        try value.replaceSelections(inserted);
    }
    pub fn replace(self: *Document, range: Range, inserted: []const u8) !void {
        const value = try self.state();
        if (value.preedit_range != null) return error.CompositionActive;
        value.busy = true;
        defer value.busy = false;
        try value.replace(range, inserted);
    }
    pub fn replaceSelection(self: *Document, inserted: []const u8) !void {
        try self.replace((try self.selection()).range(), inserted);
    }
    pub fn canUndo(self: *const Document) !bool {
        return (try self.state()).history_cursor != 0;
    }
    pub fn canRedo(self: *const Document) !bool {
        const value = try self.state();
        return value.history_cursor < value.history_len;
    }
    pub fn undo(self: *Document) !bool {
        const value = try self.state();
        if (value.preedit_range != null) return error.CompositionActive;
        if (value.history_cursor == 0) return false;
        try value.checkTextRevision();
        value.busy = true;
        defer value.busy = false;
        try value.validateCommit();
        const before = value.historyAt(value.history_cursor - 1).before;
        const old = value.root;
        value.root = tree.retain(before.root);
        const old_selected = value.selected;
        value.selected = before.selected.retain();
        value.history_cursor -= 1;
        value.revision += 1;
        value.text_version += 1;
        old_selected.release(&value.arena.memory);
        tree.release(&value.arena.memory, old);
        return true;
    }
    pub fn redo(self: *Document) !bool {
        const value = try self.state();
        if (value.preedit_range != null) return error.CompositionActive;
        if (value.history_cursor == value.history_len) return false;
        try value.checkTextRevision();
        value.busy = true;
        defer value.busy = false;
        try value.validateCommit();
        const after = value.historyAt(value.history_cursor).after;
        const old = value.root;
        value.root = tree.retain(after.root);
        const old_selected = value.selected;
        value.selected = after.selected.retain();
        value.history_cursor += 1;
        value.revision += 1;
        value.text_version += 1;
        old_selected.release(&value.arena.memory);
        tree.release(&value.arena.memory, old);
        return true;
    }
    pub fn snapshot(self: *const Document) !*Snapshot {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return capture(value.arena, value.root, value.selected, value.revision, value.text_version);
    }
    pub fn restore(self: *Document, snapshot_value: *const Snapshot) !void {
        const value = try self.state();
        const saved = try snapshot_value.state();
        if (saved.arena != value.arena) return error.ForeignSnapshot;
        try value.checkTextRevision();
        value.busy = true;
        defer value.busy = false;
        const candidate = tree.retain(saved.root);
        errdefer tree.release(&value.arena.memory, candidate);
        const selected = saved.selected.retain();
        errdefer selected.release(&value.arena.memory);
        try value.publish(candidate, selected);
    }
    pub fn setComposition(self: *Document, text: []const u8, selected: Selection) !void {
        const value = try self.state();
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (selected.anchor > text.len or selected.caret > text.len) return error.InvalidRange;
        for ([_]usize{ selected.anchor, selected.caret }) |at| if (at < text.len and text[at] & 0xc0 == 0x80) return error.InvalidBoundary;
        const range = value.preedit_range orelse value.selected.primary().range();
        const retained = tree.counts(value.root).bytes - (range.end - range.start);
        if (text.len > value.preedit.len or text.len > value.arena.limits.document_bytes - retained) return error.CapacityExceeded;
        try value.checkRevision();
        value.busy = true;
        defer value.busy = false;
        try value.validateCommit();
        std.mem.copyForwards(u8, value.preedit[0..text.len], text);
        value.preedit_len = text.len;
        value.preedit_range = range;
        value.preedit_selection = selected;
        value.revision += 1;
    }
    pub fn composition(self: *const Document) !?Composition {
        const value = try self.state();
        const range = value.preedit_range orelse return null;
        return .{ .range = range, .text = value.preedit[0..value.preedit_len], .selection = value.preedit_selection };
    }
    pub fn cancelComposition(self: *Document) !bool {
        const value = try self.state();
        if (value.preedit_range == null) return false;
        try value.checkRevision();
        value.busy = true;
        defer value.busy = false;
        try value.validateCommit();
        value.preedit_range = null;
        value.preedit_len = 0;
        value.revision += 1;
        return true;
    }
    pub fn commitComposition(self: *Document, result: ?[]const u8) !void {
        const value = try self.state();
        _ = value.preedit_range orelse return error.NoComposition;
        value.busy = true;
        defer value.busy = false;
        try value.replaceSelections(result orelse value.preedit[0..value.preedit_len]);
    }
    pub fn stats(self: *const Document) !Stats {
        const value = try self.state();
        const counts_value = value.arena.memory.stats;
        return .{ .owned_bytes = counts_value.live_bytes, .peak_bytes = counts_value.peak_bytes, .nodes = counts_value.live_nodes, .snapshots = value.arena.snapshots, .height = if (value.root) |root| root.height else 0, .copied_bytes = counts_value.copied_bytes, .visited_nodes = counts_value.visited_nodes, .reclaimed_nodes = counts_value.reclaimed_nodes, .candidate_peak_bytes = counts_value.last_candidate_peak };
    }
    /// Bridge-only ownership pin. No native/API operation is performed here.
    pub fn retainClient(self: *Document) !void {
        const value = try self.state();
        value.bindings = std.math.add(usize, value.bindings, 1) catch return error.CapacityExceeded;
    }
    pub fn releaseClient(self: *Document) !void {
        const value: *State = @ptrCast(@alignCast(self));
        try checkOwner(value.arena);
        std.debug.assert(value.bindings != 0);
        value.bindings -= 1;
    }
    pub fn nativeContext(self: *const Document, destination: []u8) !z.text.Snapshot {
        const value = try self.state();
        const selected = value.selected.primary().range();
        if (selected.end - selected.start > destination.len) return error.CapacityExceeded;
        var start = selected.start - @min(selected.start, (destination.len - (selected.end - selected.start)) / 2);
        while (!boundary(value.arena, value.root, start)) start += 1;
        var end = start + @min(tree.counts(value.root).bytes - start, destination.len);
        while (!boundary(value.arena, value.root, end)) end -= 1;
        if (end < selected.end) return error.CapacityExceeded;
        const bytes = try readRange(value.arena, value.root, .{ .start = start, .end = end }, destination);
        if (std.mem.indexOfScalar(u8, destination[0..bytes], 0) != null) return error.EmbeddedNul;
        return .{ .range = .{ .start = try utf16(value.arena, value.root, start), .end = try utf16(value.arena, value.root, end) }, .selection = .{ .anchor = try utf16(value.arena, value.root, value.selected.primary().anchor), .caret = try utf16(value.arena, value.root, value.selected.primary().caret) }, .composition = if (value.preedit_range) |range| .{ .start = try utf16(value.arena, value.root, range.start), .end = try utf16(value.arena, value.root, range.end) } else null, .revision = value.revision, .bytes = bytes };
    }
};

/// Owning immutable committed-text version. Never copy this owner or use it
/// after close; clone explicitly. It remains usable after its Document closes.
/// Retaining is O(1) plus one bounded allocation; final release costs the actual
/// number of newly unreferenced nodes, with traversal depth capped at 64.
pub const Snapshot = opaque {
    fn state(self: *const Snapshot) !*SnapshotState {
        const value: *SnapshotState = @ptrCast(@alignCast(@constCast(self)));
        try checkOwner(value.arena);
        if (value.busy) return error.Busy;
        return value;
    }
    pub fn close(self: *Snapshot) !void {
        const value = try self.state();
        if (value.active_readers.load(.acquire) != 0) return error.ReadersAlive;
        value.busy = true;
        const arena = value.arena;
        tree.release(&arena.memory, value.root);
        value.selected.release(&arena.memory);
        arena.snapshots -= 1;
        arena.memory.free(reader.Slot, value.reader_slots);
        arena.memory.destroy(SnapshotState, value);
        releaseArena(arena);
    }
    /// Owner creates the lease; its sole reader may run on an explicit worker.
    /// The Snapshot must remain alive until release, and stale copies cannot be
    /// used after Snapshot.close, including a repeated release.
    pub fn borrowReader(self: *Snapshot) !Reader {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        if (value.reader_slots.len == 0) {
            if (value.arena.limits.readers_per_snapshot == 0) return error.CapacityExceeded;
            const slots = try value.arena.memory.alloc(reader.Slot, value.arena.limits.readers_per_snapshot);
            for (slots) |*slot| slot.* = .{ .active = &value.active_readers, .root = value.root, .revision = value.revision, .text_version = value.text_version };
            value.reader_slots = slots;
        }
        for (value.reader_slots) |*slot| if (slot.borrow()) |result| return result;
        return error.ReadersFull;
    }
    pub fn clone(self: *const Snapshot) !*Snapshot {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return capture(value.arena, value.root, value.selected, value.revision, value.text_version);
    }
    pub fn byteLength(self: *const Snapshot) !usize {
        return tree.counts((try self.state()).root).bytes;
    }
    pub fn utf16Length(self: *const Snapshot) !usize {
        return tree.counts((try self.state()).root).utf16;
    }
    pub fn scalarLength(self: *const Snapshot) !usize {
        return tree.counts((try self.state()).root).scalars;
    }
    pub fn lineCount(self: *const Snapshot) !usize {
        return tree.counts((try self.state()).root).lf + 1;
    }
    pub fn read(self: *const Snapshot, range: Range, destination: []u8) !usize {
        const value = try self.state();
        return readRange(value.arena, value.root, range, destination);
    }
    pub fn utf16Offset(self: *const Snapshot, position: usize) !usize {
        const value = try self.state();
        return utf16(value.arena, value.root, position);
    }
    pub fn byteOffsetFromUtf16(self: *const Snapshot, units: usize) !usize {
        const value = try self.state();
        return tree.fromUtf16(&value.arena.memory, value.root, units);
    }
    pub fn line(self: *const Snapshot, index: usize) !Range {
        const value = try self.state();
        return lineRange(value.arena, value.root, index);
    }
    pub fn lineAt(self: *const Snapshot, byte_offset: usize) !usize {
        const value = try self.state();
        _ = try utf16(value.arena, value.root, byte_offset);
        return tree.prefix(&value.arena.memory, value.root, byte_offset).lf;
    }
    pub fn version(self: *const Snapshot) !u64 {
        return (try self.state()).revision;
    }
    pub fn committedTextVersion(self: *const Snapshot) !u64 {
        return (try self.state()).text_version;
    }
    pub fn selectionCount(self: *const Snapshot) !usize {
        return (try self.state()).selected.count();
    }
    pub fn selections(self: *const Snapshot, destination: []Selection) !SelectionList {
        return (try self.state()).selected.copy(destination);
    }
    pub fn selection(self: *const Snapshot) !Selection {
        return (try self.state()).selected.primary();
    }
    pub fn writeTo(self: *const Snapshot, writer: *std.Io.Writer) !void {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        try writeNode(value.root, writer);
    }
};

test {
    _ = @import("tests.zig");
    _ = @import("multi_tests.zig");
    _ = @import("reader_tests.zig");
    _ = @import("search_tests.zig");
    _ = @import("guard_tests.zig");
}

test "publication switches version before foreign history reclamation after final guard" {
    const Probe = struct {
        child: std.mem.Allocator,
        document: ?*Document = null,
        armed: bool = false,
        valid: bool = true,
        gate_calls: usize = 0,
        observed: bool = false,
        expected: u64 = 0,
        fn validate(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.gate_calls += 1;
            if (!self.valid) return error.GuardRejected;
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.child.rawAlloc(length, alignment, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.armed and !self.observed and self.gate_calls != 0) {
                self.observed = true;
                const value: *State = @ptrCast(@alignCast(self.document.?));
                // Internal test observation only: public reads must be Busy.
                std.testing.expectEqual(self.expected, value.revision) catch unreachable;
                std.testing.expectEqual(self.expected, value.text_version) catch unreachable;
                std.testing.expectEqual(@as(usize, 3), value.selected.primary().caret) catch unreachable;
                std.testing.expectError(error.Busy, self.document.?.version()) catch unreachable;
                self.valid = false;
            }
            self.child.rawFree(bytes, alignment, ret);
        }
    };
    var probe: Probe = .{ .child = std.testing.allocator };
    const document = try Document.create(probe.allocator(), std.Thread.getCurrentId(), "abc", .{ .history_entries = 1 });
    defer document.close() catch unreachable;
    probe.document = document;
    try document.replace(.{ .start = 0, .end = 3 }, "old");
    const scope = try document.beginCommitGuard(.{ .context = &probe, .validate = Probe.validate });
    defer scope.end();
    probe.expected = try document.version() + 1;
    probe.armed = true;
    try document.replace(.{ .start = 0, .end = 3 }, "new");
    probe.armed = false;
    try std.testing.expect(probe.observed and !probe.valid);
    try std.testing.expectEqual(@as(usize, 1), probe.gate_calls);
    try std.testing.expectEqual(probe.expected, try document.version());
    try std.testing.expectError(error.GuardRejected, document.undo());
    scope.end();
    try std.testing.expect(try document.undo());
}

test "revision exhaustion rejects every mutation without wrapping or dropping redo" {
    const document = try Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    try document.replace(.{ .start = 0, .end = 1 }, "x");
    _ = try document.undo();
    const saved = try document.snapshot();
    defer saved.close() catch unreachable;
    const value = try document.state();
    value.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, document.replace(.{ .start = 0, .end = 1 }, "y"));
    try std.testing.expectError(error.IdExhausted, document.setSelection(.{}));
    try std.testing.expectError(error.IdExhausted, document.redo());
    try std.testing.expectError(error.IdExhausted, document.restore(saved));
    try std.testing.expectError(error.IdExhausted, document.setComposition("a", .{}));
    try std.testing.expect(try document.canRedo());
    try std.testing.expectEqual(std.math.maxInt(u64), try document.version());
}

test "committed text stamp excludes selection and composition but never rewinds with undo" {
    const doc = try Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    try std.testing.expectEqual(0, try doc.committedTextVersion());
    _ = try doc.setSelection(.{ .anchor = 1, .caret = 2 });
    try doc.setComposition("候选", .{ .anchor = 0, .caret = 0 });
    _ = try doc.cancelComposition();
    try std.testing.expectEqual(0, try doc.committedTextVersion());
    try doc.setComposition("x", .{ .anchor = 1, .caret = 1 });
    try doc.commitComposition(null);
    try std.testing.expectEqual(1, try doc.committedTextVersion());
    const saved = try doc.snapshot();
    defer saved.close() catch unreachable;
    const input = try saved.borrowReader();
    defer input.release() catch unreachable;
    _ = try doc.undo();
    _ = try doc.redo();
    try doc.restore(saved);
    try std.testing.expectEqual(4, try doc.committedTextVersion());
    try std.testing.expectEqual(1, try saved.committedTextVersion());
    try std.testing.expectEqual(1, try input.committedTextVersion());
    const value = try doc.state();
    value.text_version = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, doc.replace(.{ .start = 0, .end = 0 }, "z"));
    try std.testing.expectError(error.IdExhausted, doc.undo());
    try std.testing.expectError(error.IdExhausted, doc.restore(saved));
    _ = try doc.setSelection(.{ .anchor = 0, .caret = 0 });
    try doc.setComposition("z", .{});
    try std.testing.expectError(error.IdExhausted, doc.commitComposition(null));
    try std.testing.expect(try doc.cancelComposition());
    try std.testing.expectEqual(std.math.maxInt(u64), try doc.committedTextVersion());
}

test "exhausted virtual composition cannot prevent native revoke or final document release" {
    const document = try Document.create(std.testing.allocator, std.Thread.getCurrentId(), "x", .{});
    defer document.close() catch unreachable;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var binding = ClientBinding.init(document, std.Thread.getCurrentId());
    try binding.bind(window);
    const value = try document.state();
    value.revision = std.math.maxInt(u64) - 1;
    try document.setComposition("文", .{ .anchor = 3, .caret = 3 });
    try binding.unbind();
    try std.testing.expect(binding.token == null and window.textClientToken() == null);
    try std.testing.expectEqual(std.math.maxInt(u64), try document.version());
    try std.testing.expectEqualStrings("文", (try document.composition()).?.text);
    // The defer succeeds: cancellation failure never leaves a lifetime pin.
}
