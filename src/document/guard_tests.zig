const std = @import("std");
const d = @import("root.zig");
const a = std.testing.allocator;
const Probe = struct {
    document: *d.Document,
    valid: bool = false,
    calls: usize = 0,
    fn validate(ptr: *anyopaque) !void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        try std.testing.expectError(error.Busy, self.document.version());
        try std.testing.expectError(error.Busy, self.document.close());
        try std.testing.expectError(error.Busy, self.document.beginCommitGuard(.{ .context = self, .validate = validate }));
        if (!self.valid) return error.GuardRejected;
    }
};
fn text(document: *d.Document, expected: []const u8) !void {
    var bytes: [64]u8 = undefined;
    const length = try document.byteLength();
    try std.testing.expectEqualStrings(expected, bytes[0..try document.read(.{ .start = 0, .end = length }, &bytes)]);
}
test "transient guard gates all mutation families and rejects nested or stale scope reuse" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const saved = try document.snapshot();
    defer saved.close() catch unreachable;
    try document.replace(.{ .start = 0, .end = 1 }, "x");
    const revision = try document.version();
    var probe: Probe = .{ .document = document };
    const scope = try document.beginCommitGuard(.{ .context = &probe, .validate = Probe.validate });
    defer scope.end();
    try std.testing.expectError(error.CommitGuardActive, document.close());
    try std.testing.expectError(error.CommitGuardActive, document.beginCommitGuard(.{ .context = &probe, .validate = Probe.validate }));
    try std.testing.expectError(error.GuardRejected, document.replace(.{ .start = 0, .end = 1 }, "z"));
    try std.testing.expectError(error.GuardRejected, document.replaceMany(revision, &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "z" }}));
    try std.testing.expectError(error.GuardRejected, document.replaceManyWithSelections(revision, &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "z" }}, &.{.{ .anchor = 0, .caret = 1 }}, 0));
    try std.testing.expectError(error.GuardRejected, document.setSelection(.{}));
    try std.testing.expectError(error.GuardRejected, document.setSelections(&.{ .{ .anchor = 0, .caret = 0 }, .{ .anchor = 2, .caret = 2 } }, 0));
    try std.testing.expectError(error.GuardRejected, document.undo());
    try std.testing.expectError(error.GuardRejected, document.restore(saved));
    try std.testing.expectError(error.GuardRejected, document.setComposition("m", .{}));
    try std.testing.expectEqual(revision, try document.version());
    try text(document, "xbc");
    probe.valid = true;
    try document.setComposition("m", .{});
    probe.valid = false;
    const composing = try document.version();
    try std.testing.expectError(error.GuardRejected, document.cancelComposition());
    try std.testing.expectError(error.GuardRejected, document.commitComposition(null));
    try std.testing.expectEqual(composing, try document.version());
    try std.testing.expectEqualStrings("m", (try document.composition()).?.text);
    probe.valid = true;
    _ = try document.cancelComposition();
    _ = try document.undo();
    probe.valid = false;
    try std.testing.expectError(error.GuardRejected, document.redo());
    probe.valid = true;
    _ = try document.redo();
    scope.end();
    const later = try document.beginCommitGuard(.{ .context = &probe, .validate = Probe.validate });
    scope.end(); // An ended generation cannot remove this later owner.
    try std.testing.expectError(error.CommitGuardActive, document.close());
    later.end();
    try std.testing.expect(probe.calls >= 13);
}
fn candidate(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const revision = try document.version();
    const before = try document.stats();
    var probe: Probe = .{ .document = document };
    const scope = try document.beginCommitGuard(.{ .context = &probe, .validate = Probe.validate });
    defer scope.end();
    document.replaceManyWithSelections(revision, &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "xy" }}, &.{ .{ .anchor = 0, .caret = 1 }, .{ .anchor = 1, .caret = 2 } }, 0) catch |err| {
        try std.testing.expectEqual(revision, try document.version());
        try std.testing.expectEqual(before.owned_bytes, (try document.stats()).owned_bytes);
        try text(document, "abc");
        if (err == error.GuardRejected) return;
        return err;
    };
    return error.MissingGuard;
}
test "rejected guard releases every candidate allocation without publishing history or selection" {
    try std.testing.checkAllAllocationFailures(a, candidate, .{});
}
