const std = @import("std");
const d = @import("ziggurat_document");

/// Semantic operations on the original Document. Replacement bytes are
/// borrowed, immutable, and valid through the entire synchronous command.
pub const Command = union(enum) {
    undo,
    redo,
    select_all,
    set_selection: d.Selection,
    replace_selections: []const u8,
};

/// The owner keeps context stable. Validation is allocation-free and may run
/// while the target Document/Adapter is busy: do not query either from it.
/// The Adapter checks expected_revision immediately before entering Document;
/// Document's single final guard then combines this policy and native input.
pub const Gate = struct {
    expected_revision: u64,
    context: *anyopaque,
    validate: *const fn (*anyopaque) anyerror!void,
};

pub const Outcome = struct {
    /// A committed text version advanced, including identical-byte replacement.
    /// This does not perform a full-document byte equality scan.
    text_changed: bool = false,
    /// Exact canonical selection values, direction, order or primary changed.
    selection_changed: bool = false,
    changed: bool = false,
    committed_revision: ?u64 = null,
    observed_revision: u64,
    index_required: bool = false,
    stale_after_commit: bool = false,
    post_commit_error: ?anyerror = null,
};

/// Private synchronous capture. Storage is caller-owned and exclusive; its two
/// disjoint halves each hold the original canonical selection count. A command
/// that restores a different count needs no larger post-commit scratch.
pub const Capture = struct {
    gate: Gate,
    text_version: u64,
    before: d.SelectionList,
    after: []d.Selection,
    committed_revision: ?u64 = null,
    text_changed: bool = false,
    selection_changed: bool = false,

    pub fn init(document: *d.Document, gate: Gate, scratch: []d.Selection) !Capture {
        if (try document.version() != gate.expected_revision) return error.StaleRevision;
        if (try document.composition() != null) return error.CompositionActive;
        const count = try document.selectionCount();
        const needed = std.math.mul(usize, count, 2) catch return error.SelectionCapacityExceeded;
        if (scratch.len < needed) return error.SelectionCapacityExceeded;
        return .{ .gate = gate, .text_version = try document.committedTextVersion(), .before = try document.selections(scratch[0..count]), .after = scratch[count..needed] };
    }
    pub fn beforeMutation(self: *const Capture, document: *d.Document) !void {
        if (self.committed_revision != null) return error.CommandAlreadyCommitted;
        try self.gate.validate(self.gate.context);
        if (try document.version() != self.gate.expected_revision) return error.StaleRevision;
    }
    pub fn validateCommit(self: *const Capture) !void {
        try self.gate.validate(self.gate.context);
    }
    /// Called immediately after the Document mutator returns, before any
    /// Adapter receipt/fold/index resource reclamation or other foreign call.
    pub fn record(self: *Capture, document: *d.Document) void {
        const revision = document.version() catch unreachable;
        if (revision == self.gate.expected_revision) return;
        self.committed_revision = revision;
        self.text_changed = (document.committedTextVersion() catch unreachable) != self.text_version;
        if ((document.selectionCount() catch unreachable) != self.before.items.len) {
            self.selection_changed = true;
            return;
        }
        const selected = document.selections(self.after) catch unreachable;
        self.selection_changed = !sameSelections(self.before, selected);
    }
    pub fn outcome(self: *const Capture, observed_revision: u64, index_required: bool) Outcome {
        const stale = if (self.committed_revision) |revision| observed_revision != revision else observed_revision != self.gate.expected_revision;
        return .{
            .text_changed = self.text_changed,
            .selection_changed = self.selection_changed,
            .changed = self.text_changed or self.selection_changed,
            .committed_revision = self.committed_revision,
            .observed_revision = observed_revision,
            .index_required = index_required or stale,
            .stale_after_commit = self.committed_revision != null and stale,
        };
    }
};

fn sameSelections(a: d.SelectionList, b: d.SelectionList) bool {
    if (a.primary != b.primary or a.items.len != b.items.len) return false;
    for (a.items, b.items) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

const Policy = struct {
    enabled: bool = true,
    fn validate(ptr: *anyopaque) !void {
        const self: *Policy = @ptrCast(@alignCast(ptr));
        if (!self.enabled) return error.Disabled;
    }
    fn gate(self: *Policy, document: *d.Document) !Gate {
        return .{ .expected_revision = try document.version(), .context = self, .validate = validate };
    }
};

test "command capture preflights actual caller capacity and exact primary direction" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abcdef", .{});
    defer document.close() catch unreachable;
    _ = try document.setSelections(&.{ .{ .anchor = 1, .caret = 0 }, .{ .anchor = 4, .caret = 5 } }, 1);
    var policy: Policy = .{};
    var scratch: [4]d.Selection = undefined;
    const revision = try document.version();
    const stats = try document.stats();
    try std.testing.expectError(error.SelectionCapacityExceeded, Capture.init(document, try policy.gate(document), scratch[0..3]));
    try std.testing.expectEqual(revision, try document.version());
    try std.testing.expectEqual(stats.owned_bytes, (try document.stats()).owned_bytes);
    var capture = try Capture.init(document, try policy.gate(document), &scratch);
    _ = try document.setSelections(&.{ .{ .anchor = 0, .caret = 1 }, .{ .anchor = 5, .caret = 4 } }, 0);
    capture.record(document);
    const result = capture.outcome(try document.version(), false);
    try std.testing.expect(result.changed and result.selection_changed and !result.text_changed);
    try std.testing.expectEqual(@as(?u64, revision + 1), result.committed_revision);
    try std.testing.expect(!result.stale_after_commit);
}

test "command capture distinguishes no op text generation and later external edits" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    _ = try document.setSelection(.{ .anchor = 1, .caret = 1 });
    var policy: Policy = .{};
    var scratch: [2]d.Selection = undefined;
    var capture = try Capture.init(document, try policy.gate(document), &scratch);
    _ = try document.setSelection(try document.selection());
    capture.record(document);
    try std.testing.expect(!capture.outcome(try document.version(), false).changed);
    try std.testing.expect(capture.committed_revision == null);
    // Equal bytes still publish a real committed text version.
    try document.replace(.{ .start = 0, .end = 1 }, "a");
    capture.record(document);
    const committed = capture.committed_revision.?;
    const first = capture.outcome(try document.version(), false);
    try std.testing.expect(first.text_changed and !first.selection_changed);
    try document.replace(.{ .start = 0, .end = 0 }, "later");
    const stale = capture.outcome(try document.version(), false);
    try std.testing.expect(stale.changed and stale.stale_after_commit and stale.index_required);
    try std.testing.expectEqual(@as(?u64, committed), stale.committed_revision);
}

test "command capture accommodates restored selection counts beyond old scratch" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abcdef", .{});
    defer document.close() catch unreachable;
    var policy: Policy = .{};
    var scratch: [2]d.Selection = undefined;
    var capture = try Capture.init(document, try policy.gate(document), &scratch);
    _ = try document.setSelections(&.{ .{ .anchor = 0, .caret = 0 }, .{ .anchor = 2, .caret = 2 }, .{ .anchor = 4, .caret = 4 } }, 2);
    capture.record(document);
    try std.testing.expect(capture.selection_changed and !capture.text_changed);
    try std.testing.expectError(error.CommandAlreadyCommitted, capture.beforeMutation(document));
}

test "command policy and revision are checked at distinct transaction boundaries" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var policy: Policy = .{};
    var scratch: [2]d.Selection = undefined;
    const capture = try Capture.init(document, try policy.gate(document), &scratch);
    try capture.beforeMutation(document);
    policy.enabled = false;
    try std.testing.expectError(error.Disabled, capture.validateCommit());
    policy.enabled = true;
    _ = try document.setSelection(.{ .anchor = 0, .caret = 0 });
    try std.testing.expectError(error.StaleRevision, capture.beforeMutation(document));
}

test "command scratch follows configured Document selection capacity" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), &@as([128 * "ab".len]u8, @bitCast(@as([128]["ab".len]u8, @splat("ab".*)))), .{ .selections = 128 });
    defer document.close() catch unreachable;
    var selections: [97]d.Selection = undefined;
    for (&selections, 0..) |*selected, at| selected.* = .{ .anchor = at * 2, .caret = at * 2 };
    _ = try document.setSelections(&selections, selections.len - 1);
    var policy: Policy = .{};
    var scratch: [194]d.Selection = undefined;
    try std.testing.expectError(error.SelectionCapacityExceeded, Capture.init(document, try policy.gate(document), scratch[0 .. scratch.len - 1]));
    var capture = try Capture.init(document, try policy.gate(document), &scratch);
    _ = try document.setSelection(.{ .anchor = 0, .caret = 0 });
    capture.record(document);
    try std.testing.expect(capture.selection_changed and !capture.text_changed);
}
