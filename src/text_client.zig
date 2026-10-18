const std = @import("std");
const core = @import("root.zig");

/// Native interop offsets count UTF-16 units in the committed document.
/// Preedit remains a virtual replacement and is not copied into this context.
pub const Range = struct { start: usize, end: usize };
pub const Selection = struct { anchor: usize, caret: usize };
pub const Snapshot = struct {
    range: Range,
    selection: Selection,
    composition: ?Range = null,
    revision: u64,
    bytes: usize,
};
pub const Change = union(enum) {
    select: Selection,
    replace: struct { range: Range, text: []const u8 },
};
/// Only applied acknowledges the original native request. Rejection never
/// requests a retry. Superseded preserves any independent hook edit; it is not
/// a rollback result. Real validation/presentation failures remain errors.
pub const ChangeResult = enum { applied, rejected, superseded };
pub const UnbindReason = enum { replaced, cleared, focus_lost, closed };
pub const Token = struct { window: core.Window, generation: u64 };

/// Borrow a stable context until unbound AND all callbacks using it return.
/// read writes bounded, contiguous committed context containing the selection;
/// range reports its global document offsets, not merely the slice length.
/// change performs validation before mutation, then explicitly updates layout
/// and candidate geometry before returning. Queries must not shape or allocate.
pub const Client = struct {
    context: *anyopaque,
    owner: std.Thread.Id,
    read: *const fn (*anyopaque, core.Window, []u8) anyerror!Snapshot,
    change: *const fn (*anyopaque, core.Window, Change) anyerror!ChangeResult,
    unbound: ?*const fn (*anyopaque, core.Window, UnbindReason) void = null,
};

pub fn utf16Length(text: []const u8) !usize {
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var units: usize = 0;
    while (iterator.nextCodepoint()) |cp| units += if (cp > 0xffff) @as(usize, 2) else 1;
    return units;
}
pub fn byteOffset(text: []const u8, wanted: usize) !usize {
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var units: usize = 0;
    while (units < wanted) {
        const bytes = iterator.nextCodepointSlice() orelse return error.InvalidRange;
        const cp = try std.unicode.utf8Decode(bytes);
        units += if (cp > 0xffff) @as(usize, 2) else 1;
        if (units > wanted) return error.InvalidBoundary;
    }
    return iterator.i;
}
pub fn validate(value: Snapshot, storage: []const u8) !void {
    if (value.bytes > storage.len or value.range.start > value.range.end) return error.InvalidTextContext;
    const text = storage[0..value.bytes];
    if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.InvalidTextContext;
    if (try utf16Length(text) != value.range.end - value.range.start) return error.InvalidTextContext;
    for ([_]usize{ value.selection.anchor, value.selection.caret }) |position| {
        if (position < value.range.start or position > value.range.end) return error.InvalidTextContext;
        _ = byteOffset(text, position - value.range.start) catch return error.InvalidTextContext;
    }
    if (value.composition) |range| {
        if (range.start < value.range.start or range.end > value.range.end or range.start > range.end) return error.InvalidTextContext;
        _ = byteOffset(text, range.start - value.range.start) catch return error.InvalidTextContext;
        _ = byteOffset(text, range.end - value.range.start) catch return error.InvalidTextContext;
    }
}

test "native context validates global ranges, UTF16 boundaries and capacity" {
    const value: Snapshot = .{ .range = .{ .start = 40, .end = 43 }, .selection = .{ .anchor = 42, .caret = 43 }, .revision = 1, .bytes = 5 };
    try validate(value, "😀x");
    var bad = value;
    bad.selection.caret = 41;
    try std.testing.expectError(error.InvalidTextContext, validate(bad, "😀x"));
    bad = value;
    bad.range.end = 5;
    try std.testing.expectError(error.InvalidTextContext, validate(bad, "😀x"));
    bad = value;
    bad.bytes = 6;
    try std.testing.expectError(error.InvalidTextContext, validate(bad, "😀x"));
}
