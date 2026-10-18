const std = @import("std");

/// All offsets are UTF-8 byte offsets at scalar boundaries, not grapheme indexes.
pub const Range = struct { start: usize, end: usize };
pub const Selection = struct {
    anchor: usize = 0,
    caret: usize = 0,
    pub fn range(self: Selection) Range {
        return .{ .start = @min(self.anchor, self.caret), .end = @max(self.anchor, self.caret) };
    }
};
pub const Direction = enum { backward, forward };
pub const Options = struct {
    max_bytes: usize = 64 * 1024,
    undo_entries: usize = 128,
    undo_bytes: usize = 64 * 1024,
    composition_bytes: usize = 4096,
};
pub const Error = error{ InvalidUtf8, InvalidBoundary, InvalidRange, CapacityExceeded, HistoryCapacityExceeded, CompositionActive, NoComposition, AliasedInput };
pub const Composition = struct {
    /// The committed byte range being virtually replaced by preedit text.
    range: Range,
    text: []const u8,
    /// Byte offsets relative to text, independent of the committed selection.
    selection: Selection,
};

const Edit = struct {
    start: usize,
    removed: usize,
    inserted: usize,
    payload: usize,
    before: Selection,
    after: Selection,
    fn bytes(self: Edit) usize {
        return self.removed + self.inserted;
    }
};

/// Application-owned, bounded UTF-8 editing state. init preallocates document,
/// delta history and preedit storage. Edits, undo and composition do not allocate.
/// Document changes shift the affected tail; this is intended for bounded fields,
/// not a rope or a large-document paragraph index. Scalar navigation does not
/// implement Unicode grapheme segmentation, word breaking, shaping or native IME.
pub const TextBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    len: usize = 0,
    /// Monotonic native document/selection/preedit revision; exhaustion disables native queries.
    revision: u64 = 0,
    selection_state: Selection = .{},
    history: []Edit,
    history_data: []u8,
    history_len: usize = 0,
    history_cursor: usize = 0,
    history_used: usize = 0,
    preedit: []u8,
    preedit_len: usize = 0,
    preedit_range: ?Range = null,
    preedit_selection: Selection = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options, initial: []const u8) !TextBuffer {
        if (!std.unicode.utf8ValidateSlice(initial)) return error.InvalidUtf8;
        if (initial.len > options.max_bytes) return error.CapacityExceeded;
        const storage = try allocator.alloc(u8, options.max_bytes);
        errdefer allocator.free(storage);
        const history = try allocator.alloc(Edit, options.undo_entries);
        errdefer allocator.free(history);
        const history_data = try allocator.alloc(u8, if (options.undo_entries == 0) 0 else options.undo_bytes);
        errdefer allocator.free(history_data);
        const preedit = try allocator.alloc(u8, options.composition_bytes);
        @memcpy(storage[0..initial.len], initial);
        return .{
            .allocator = allocator,
            .storage = storage,
            .len = initial.len,
            .selection_state = .{ .anchor = initial.len, .caret = initial.len },
            .history = history,
            .history_data = history_data,
            .preedit = preedit,
        };
    }
    pub fn deinit(self: *TextBuffer) void {
        self.allocator.free(self.preedit);
        self.allocator.free(self.history_data);
        self.allocator.free(self.history);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
    /// Borrowed until the next document edit or deinit.
    pub fn text(self: *const TextBuffer) []const u8 {
        return self.storage[0..self.len];
    }
    pub fn selection(self: *const TextBuffer) Selection {
        return self.selection_state;
    }
    pub fn selectedText(self: *const TextBuffer) []const u8 {
        const selected = self.selection_state.range();
        return self.storage[selected.start..selected.end];
    }
    pub fn setSelection(self: *TextBuffer, selected: Selection) Error!bool {
        if (self.preedit_range != null) return error.CompositionActive;
        try validateSelection(self.text(), selected);
        const changed = !std.meta.eql(self.selection_state, selected);
        self.selection_state = selected;
        if (changed) self.revision +|= 1;
        return changed;
    }
    pub fn selectAll(self: *TextBuffer) Error!bool {
        return self.setSelection(.{ .anchor = 0, .caret = self.len });
    }
    /// True when text or selection changes. Input must not alias text(): this
    /// prevents shifting a borrowed source while editing without hidden copies.
    pub fn replaceSelection(self: *TextBuffer, inserted: []const u8) Error!bool {
        return self.replaceRange(self.selection_state.range(), inserted);
    }
    pub fn replaceRange(self: *TextBuffer, replaced: Range, inserted: []const u8) Error!bool {
        if (self.preedit_range != null) return error.CompositionActive;
        return self.edit(replaced, inserted);
    }
    fn edit(self: *TextBuffer, replaced: Range, inserted: []const u8) Error!bool {
        try self.validateRange(replaced);
        if (!std.unicode.utf8ValidateSlice(inserted)) return error.InvalidUtf8;
        if (aliases(self.storage, inserted)) return error.AliasedInput;
        const removed = replaced.end - replaced.start;
        const retained = self.len - removed;
        if (inserted.len > self.storage.len - retained) return error.CapacityExceeded;
        const after: Selection = .{ .anchor = replaced.start + inserted.len, .caret = replaced.start + inserted.len };
        if (std.mem.eql(u8, self.storage[replaced.start..replaced.end], inserted)) {
            const changed = !std.meta.eql(self.selection_state, after);
            self.selection_state = after;
            if (changed) self.revision +|= 1;
            return changed;
        }
        const payload_len = std.math.add(usize, removed, inserted.len) catch return error.HistoryCapacityExceeded;
        if (self.history.len != 0) {
            if (payload_len > self.history_data.len) return error.HistoryCapacityExceeded;
            self.record(replaced, inserted, after, payload_len);
        }
        self.replaceRaw(replaced, inserted);
        self.selection_state = after;
        return true;
    }
    fn validateRange(self: *const TextBuffer, range: Range) Error!void {
        if (range.start > range.end or range.end > self.len) return error.InvalidRange;
        if (!isBoundary(self.text(), range.start) or !isBoundary(self.text(), range.end)) return error.InvalidBoundary;
    }
    fn record(self: *TextBuffer, range: Range, inserted: []const u8, after: Selection, payload_len: usize) void {
        // New edits discard redo only after every fallible precondition passed.
        if (self.history_cursor < self.history_len) {
            self.history_used = self.history[self.history_cursor].payload;
            self.history_len = self.history_cursor;
        }
        var evicted: usize = 0;
        var reclaimed: usize = 0;
        while (self.history_len - evicted >= self.history.len or self.history_used - reclaimed > self.history_data.len - payload_len) : (evicted += 1) {
            reclaimed += self.history[evicted].bytes();
        }
        if (evicted != 0) {
            std.mem.copyForwards(u8, self.history_data[0 .. self.history_used - reclaimed], self.history_data[reclaimed..self.history_used]);
            std.mem.copyForwards(Edit, self.history[0 .. self.history_len - evicted], self.history[evicted..self.history_len]);
            self.history_used -= reclaimed;
            self.history_len -= evicted;
            for (self.history[0..self.history_len]) |*entry| entry.payload -= reclaimed;
        }
        const removed = range.end - range.start;
        const payload = self.history_used;
        @memcpy(self.history_data[payload..][0..removed], self.storage[range.start..range.end]);
        @memcpy(self.history_data[payload + removed ..][0..inserted.len], inserted);
        self.history[self.history_len] = .{ .start = range.start, .removed = removed, .inserted = inserted.len, .payload = payload, .before = self.selection_state, .after = after };
        self.history_used += payload_len;
        self.history_len += 1;
        self.history_cursor = self.history_len;
    }
    fn replaceRaw(self: *TextBuffer, range: Range, inserted: []const u8) void {
        self.revision +|= 1;
        const tail_len = self.len - range.end;
        const next_tail = range.start + inserted.len;
        const destination = self.storage[next_tail..][0..tail_len];
        const source = self.storage[range.end..][0..tail_len];
        if (next_tail > range.end) std.mem.copyBackwards(u8, destination, source) else std.mem.copyForwards(u8, destination, source);
        @memcpy(self.storage[range.start..][0..inserted.len], inserted);
        self.len = next_tail + tail_len;
    }
    pub fn canUndo(self: *const TextBuffer) bool {
        return self.history_cursor != 0;
    }
    pub fn canRedo(self: *const TextBuffer) bool {
        return self.history_cursor < self.history_len;
    }
    pub fn undo(self: *TextBuffer) Error!bool {
        if (self.preedit_range != null) return error.CompositionActive;
        if (!self.canUndo()) return false;
        const entry = self.history[self.history_cursor - 1];
        self.replaceRaw(.{ .start = entry.start, .end = entry.start + entry.inserted }, self.history_data[entry.payload..][0..entry.removed]);
        self.selection_state = entry.before;
        self.history_cursor -= 1;
        return true;
    }
    pub fn redo(self: *TextBuffer) Error!bool {
        if (self.preedit_range != null) return error.CompositionActive;
        if (!self.canRedo()) return false;
        const entry = self.history[self.history_cursor];
        self.replaceRaw(.{ .start = entry.start, .end = entry.start + entry.removed }, self.history_data[entry.payload + entry.removed ..][0..entry.inserted]);
        self.selection_state = entry.after;
        self.history_cursor += 1;
        return true;
    }
    pub fn clearHistory(self: *TextBuffer) void {
        self.history_len = 0;
        self.history_cursor = 0;
        self.history_used = 0;
    }
    pub fn moveScalar(self: *TextBuffer, direction: Direction, extend_selection: bool) Error!bool {
        if (self.preedit_range != null) return error.CompositionActive;
        var next = self.selection_state;
        const selected = next.range();
        if (!extend_selection and selected.start != selected.end) {
            next.caret = if (direction == .backward) selected.start else selected.end;
        } else {
            next.caret = if (direction == .backward) previousBoundary(self.text(), next.caret) else nextBoundary(self.text(), next.caret);
        }
        if (!extend_selection) next.anchor = next.caret;
        return self.setSelection(next);
    }
    pub fn deleteBackwardScalar(self: *TextBuffer) Error!bool {
        const selected = self.selection_state.range();
        const range: Range = if (selected.start != selected.end) selected else .{ .start = previousBoundary(self.text(), selected.start), .end = selected.end };
        return self.replaceRange(range, "");
    }
    pub fn deleteForwardScalar(self: *TextBuffer) Error!bool {
        const selected = self.selection_state.range();
        const range: Range = if (selected.start != selected.end) selected else .{ .start = selected.start, .end = nextBoundary(self.text(), selected.end) };
        return self.replaceRange(range, "");
    }
    /// Preedit replaces a committed range virtually. Committed text and selection
    /// stay unchanged until commit; a sequence of updates becomes one undo entry.
    pub fn setComposition(self: *TextBuffer, preedit: []const u8, selected: Selection) Error!bool {
        if (!std.unicode.utf8ValidateSlice(preedit)) return error.InvalidUtf8;
        try validateSelection(preedit, selected);
        const range = self.preedit_range orelse self.selection_state.range();
        if (preedit.len > self.preedit.len or preedit.len > self.storage.len - (self.len - (range.end - range.start))) return error.CapacityExceeded;
        const changed = self.preedit_range == null or !std.mem.eql(u8, self.preedit[0..self.preedit_len], preedit) or !std.meta.eql(self.preedit_selection, selected);
        std.mem.copyForwards(u8, self.preedit[0..preedit.len], preedit);
        self.preedit_len = preedit.len;
        self.preedit_range = range;
        self.preedit_selection = selected;
        if (changed) self.revision +|= 1;
        return changed;
    }
    /// Borrowed preedit and its committed replacement range. Renderers combine
    /// text()[0..range.start], composition.text and text()[range.end..].
    pub fn composition(self: *const TextBuffer) ?Composition {
        const range = self.preedit_range orelse return null;
        return .{ .range = range, .text = self.preedit[0..self.preedit_len], .selection = self.preedit_selection };
    }
    /// Null commits current preedit; a supplied result replaces it. Capacity or
    /// history errors preserve the entire active composition for retry/cancel.
    pub fn commitComposition(self: *TextBuffer, committed: ?[]const u8) Error!bool {
        const range = self.preedit_range orelse return error.NoComposition;
        _ = try self.edit(range, committed orelse self.preedit[0..self.preedit_len]);
        _ = self.cancelComposition();
        return true;
    }
    pub fn cancelComposition(self: *TextBuffer) bool {
        if (self.preedit_range == null) return false;
        self.preedit_range = null;
        self.revision +|= 1;
        self.preedit_len = 0;
        self.preedit_selection = .{};
        return true;
    }
    /// Native UTF-16 conversion is linear in the queried prefix. Splitting a
    /// surrogate pair is rejected rather than silently changing the range.
    pub fn utf16Offset(self: *const TextBuffer, byte_offset: usize) Error!usize {
        if (byte_offset > self.len) return error.InvalidRange;
        if (!isBoundary(self.text(), byte_offset)) return error.InvalidBoundary;
        var iterator = std.unicode.Utf8View.initUnchecked(self.text()[0..byte_offset]).iterator();
        var units: usize = 0;
        while (iterator.nextCodepoint()) |codepoint| units += if (codepoint > 0xffff) @as(usize, 2) else 1;
        return units;
    }
    pub fn byteOffsetFromUtf16(self: *const TextBuffer, requested: usize) Error!usize {
        var offset: usize = 0;
        var units: usize = 0;
        while (offset < self.len and units < requested) {
            const next = nextBoundary(self.text(), offset);
            const codepoint = std.unicode.utf8Decode(self.storage[offset..next]) catch unreachable;
            units += if (codepoint > 0xffff) @as(usize, 2) else 1;
            offset = next;
        }
        if (units > requested) return error.InvalidBoundary;
        if (units < requested) return error.InvalidRange;
        return offset;
    }
};

fn aliases(storage: []u8, text: []const u8) bool {
    if (text.len == 0 or storage.len == 0) return false;
    const a = @intFromPtr(storage.ptr);
    const b = @intFromPtr(text.ptr);
    return if (a <= b) b - a < storage.len else a - b < text.len;
}
pub fn isBoundary(text: []const u8, offset: usize) bool {
    return offset <= text.len and (offset == text.len or text[offset] & 0xc0 != 0x80);
}
fn validateSelection(text: []const u8, selection: Selection) Error!void {
    if (selection.anchor > text.len or selection.caret > text.len) return error.InvalidRange;
    if (!isBoundary(text, selection.anchor) or !isBoundary(text, selection.caret)) return error.InvalidBoundary;
}
fn previousBoundary(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var previous = offset - 1;
    while (!isBoundary(text, previous)) previous -= 1;
    return previous;
}
fn nextBoundary(text: []const u8, offset: usize) usize {
    if (offset == text.len) return offset;
    var next = offset + 1;
    while (!isBoundary(text, next)) next += 1;
    return next;
}

test "UTF-8 edits reject split scalars and preserve selection direction in history" {
    var buffer = try TextBuffer.init(std.testing.allocator, .{}, "A中😀Z");
    defer buffer.deinit();
    try std.testing.expectError(error.InvalidBoundary, buffer.setSelection(.{ .anchor = 2, .caret = 2 }));
    _ = try buffer.setSelection(.{ .anchor = 8, .caret = 1 });
    try std.testing.expectEqualStrings("中😀", buffer.selectedText());
    _ = try buffer.replaceSelection("文");
    try std.testing.expectEqualStrings("A文Z", buffer.text());
    try std.testing.expect(try buffer.undo());
    try std.testing.expectEqualStrings("A中😀Z", buffer.text());
    try std.testing.expectEqual(Selection{ .anchor = 8, .caret = 1 }, buffer.selection());
    try std.testing.expect(try buffer.redo());
    try std.testing.expectEqualStrings("A文Z", buffer.text());
    _ = try buffer.deleteBackwardScalar();
    try std.testing.expectEqualStrings("AZ", buffer.text());
    _ = try buffer.deleteForwardScalar();
    try std.testing.expectEqualStrings("A", buffer.text());
}

test "bounded history evicts old deltas and new edits invalidate redo" {
    var buffer = try TextBuffer.init(std.testing.allocator, .{ .max_bytes = 16, .undo_entries = 2, .undo_bytes = 4 }, "");
    defer buffer.deinit();
    _ = try buffer.replaceSelection("a");
    _ = try buffer.replaceSelection("b");
    _ = try buffer.replaceSelection("c");
    try std.testing.expect(try buffer.undo());
    try std.testing.expect(try buffer.undo());
    try std.testing.expect(!(try buffer.undo()));
    try std.testing.expectEqualStrings("a", buffer.text());
    _ = try buffer.replaceSelection("X");
    try std.testing.expect(!buffer.canRedo());
    try std.testing.expectEqualStrings("aX", buffer.text());
    _ = try buffer.undo();
    _ = try buffer.redo();
    try std.testing.expectEqualStrings("aX", buffer.text());
}

test "capacity failures preserve document selection and redo" {
    var buffer = try TextBuffer.init(std.testing.allocator, .{ .max_bytes = 6, .undo_bytes = 4 }, "ab");
    defer buffer.deinit();
    _ = try buffer.replaceSelection("c");
    _ = try buffer.undo();
    const selection = buffer.selection();
    try std.testing.expectError(error.CapacityExceeded, buffer.replaceSelection("12345"));
    try std.testing.expectError(error.HistoryCapacityExceeded, buffer.replaceRange(.{ .start = 0, .end = 2 }, "XYZ"));
    try std.testing.expectError(error.AliasedInput, buffer.replaceSelection(buffer.text()));
    try std.testing.expectEqualStrings("ab", buffer.text());
    try std.testing.expectEqual(selection, buffer.selection());
    try std.testing.expect(buffer.canRedo());
    _ = try buffer.redo();
    try std.testing.expectEqualStrings("abc", buffer.text());
}

test "composition is virtual cancellable and commits as one undo transaction" {
    var buffer = try TextBuffer.init(std.testing.allocator, .{}, "aXYZb");
    defer buffer.deinit();
    _ = try buffer.setSelection(.{ .anchor = 1, .caret = 4 });
    _ = try buffer.setComposition("中", .{ .anchor = 3, .caret = 3 });
    _ = try buffer.setComposition("中文", .{ .anchor = 6, .caret = 6 });
    try std.testing.expectEqualStrings("aXYZb", buffer.text());
    try std.testing.expectEqual(Range{ .start = 1, .end = 4 }, buffer.composition().?.range);
    try std.testing.expectError(error.CompositionActive, buffer.replaceSelection("x"));
    try std.testing.expectError(error.CompositionActive, buffer.undo());
    try std.testing.expect(buffer.cancelComposition());
    try std.testing.expect(!buffer.canUndo());
    try std.testing.expectEqual(Selection{ .anchor = 1, .caret = 4 }, buffer.selection());
    _ = try buffer.setComposition("中", .{ .anchor = 3, .caret = 3 });
    _ = try buffer.commitComposition("中文");
    try std.testing.expectEqualStrings("a中文b", buffer.text());
    try std.testing.expect(buffer.composition() == null);
    _ = try buffer.undo();
    try std.testing.expectEqualStrings("aXYZb", buffer.text());
    try std.testing.expect(!(try buffer.undo()));
}

test "invalid preedit and failed commit retain the active composition" {
    var buffer = try TextBuffer.init(std.testing.allocator, .{ .max_bytes = 16, .undo_bytes = 2, .composition_bytes = 8 }, "x");
    defer buffer.deinit();
    _ = try buffer.setComposition("中", .{ .anchor = 3, .caret = 3 });
    try std.testing.expectError(error.InvalidBoundary, buffer.setComposition("文", .{ .anchor = 1 }));
    try std.testing.expectError(error.InvalidUtf8, buffer.setComposition("\xff", .{}));
    try std.testing.expectError(error.HistoryCapacityExceeded, buffer.commitComposition(null));
    try std.testing.expectEqualStrings("中", buffer.composition().?.text);
    try std.testing.expectEqualStrings("x", buffer.text());
    _ = buffer.cancelComposition();
    try std.testing.expectError(error.NoComposition, buffer.commitComposition(null));
}

test "UTF-16 bridge preserves surrogate pairs and scalar navigation stays byte based" {
    var buffer = try TextBuffer.init(std.testing.allocator, .{}, "A😀中");
    defer buffer.deinit();
    try std.testing.expectEqual(@as(usize, 3), try buffer.utf16Offset(5));
    try std.testing.expectEqual(@as(usize, 5), try buffer.byteOffsetFromUtf16(3));
    try std.testing.expectError(error.InvalidBoundary, buffer.byteOffsetFromUtf16(2));
    try std.testing.expectError(error.InvalidBoundary, buffer.utf16Offset(2));
    _ = try buffer.moveScalar(.backward, true);
    try std.testing.expectEqual(Selection{ .anchor = 8, .caret = 5 }, buffer.selection());
    _ = try buffer.moveScalar(.backward, true);
    try std.testing.expectEqual(Selection{ .anchor = 8, .caret = 1 }, buffer.selection());
    _ = try buffer.moveScalar(.forward, false);
    try std.testing.expectEqual(Selection{ .anchor = 8, .caret = 8 }, buffer.selection());
}

test "initialization rolls back every allocation failure" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var buffer = try TextBuffer.init(allocator, .{ .max_bytes = 32, .undo_entries = 4, .undo_bytes = 64, .composition_bytes = 16 }, "你好");
            defer buffer.deinit();
            _ = try buffer.replaceSelection("!");
            _ = try buffer.undo();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "editing history and composition reuse only initialization storage" {
    var memory: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var buffer = try TextBuffer.init(fixed.allocator(), .{ .max_bytes = 128, .undo_entries = 4, .undo_bytes = 128, .composition_bytes = 32 }, "");
    defer buffer.deinit();
    const allocated = fixed.end_index;
    for (0..20) |_| {
        _ = try buffer.replaceSelection("a");
        _ = try buffer.undo();
        _ = try buffer.redo();
        _ = try buffer.setComposition("文", .{ .anchor = 3, .caret = 3 });
        _ = try buffer.commitComposition(null);
    }
    try std.testing.expectEqual(allocated, fixed.end_index);
}
