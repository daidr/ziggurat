const std = @import("std");
const d = @import("ziggurat_document");

pub const Kind = enum { completion, hover, diagnostics };
pub const Severity = enum { err, warning, info, hint };
/// A snippet identifies exactly one template-bearing edit. All other edits
/// remain literal, in the same original document coordinate space.
pub const Insertion = union(enum) { plain, snippet: usize };
/// Producer-defined immutable continuation. The editor owns these bytes but
/// never interprets them or calls a producer. Source/generation are value IDs.
pub const Continuation = struct { source: u64, generation: u64, payload: []const u8 };
pub const Completion = struct {
    label: []const u8,
    detail: []const u8 = "",
    documentation: []const u8 = "",
    /// Strictly ordered, disjoint ORIGINAL document byte ranges. One acceptance
    /// commits the whole item, including additional edits, as one transaction.
    edits: []const d.Replacement,
    insertion: Insertion = .plain,
    continuation: ?Continuation = null,
};
pub const Hover = struct { range: d.Range, text: []const u8 };
pub const Diagnostic = struct { range: d.Range, severity: Severity = .err, message: []const u8, source: []const u8 = "" };
pub const Data = union(Kind) { completion: []const Completion, hover: Hover, diagnostics: []const Diagnostic };
pub const Limits = struct {
    bytes: usize = 256 * 1024,
    completions: usize = 128,
    diagnostics: usize = 256,
    edits_per_completion: usize = 16,
    text_bytes: usize = 65536,
    continuation_bytes: usize = 65536,
    pub fn validate(self: Limits) !void {
        if (self.bytes == 0 or self.bytes > 16 * 1024 * 1024 or self.completions == 0 or self.completions > 4096 or self.diagnostics == 0 or self.diagnostics > 4096 or self.edits_per_completion == 0 or self.edits_per_completion > 64 or self.text_bytes == 0 or self.text_bytes > 1024 * 1024 or self.continuation_bytes > 1024 * 1024) return error.InvalidLimits;
    }
};
const alignment = std.mem.Alignment.fromByteUnits(@alignOf(Completion));

/// Linear owning result. Construction/deinit may run on a caller's worker;
/// neither operation touches a Broker, Document, native layout or UI. Publishing
/// consumes this only on success. The supplied allocator must cover its lifetime
/// and support whichever threads the host uses to allocate/free the result.
pub const OwnedResult = struct {
    allocator: std.mem.Allocator,
    storage: ?[]align(@alignOf(Completion)) u8,
    data: Data,
    pub fn init(allocator: std.mem.Allocator, input: Data, limits: Limits) !OwnedResult {
        const size = try validate(input, limits);
        const storage = try allocator.alignedAlloc(u8, alignment, size);
        errdefer allocator.free(storage);
        var offset: usize = 0;
        const data: Data = switch (input) {
            .completion => |items| blk: {
                const output: []Completion = @as([*]Completion, @ptrCast(storage.ptr))[0..items.len];
                var edit_count: usize = 0;
                for (items) |item| edit_count += item.edits.len;
                const edits: []d.Replacement = @as([*]d.Replacement, @ptrCast(@alignCast(storage.ptr + items.len * @sizeOf(Completion))))[0..edit_count];
                offset = items.len * @sizeOf(Completion) + edit_count * @sizeOf(d.Replacement);
                var at: usize = 0;
                for (output, items) |*target, source| {
                    const selected = edits[at..][0..source.edits.len];
                    at += selected.len;
                    target.* = .{ .label = copy(storage, &offset, source.label), .detail = copy(storage, &offset, source.detail), .documentation = copy(storage, &offset, source.documentation), .edits = selected, .insertion = source.insertion };
                    if (source.continuation) |value| target.continuation = .{ .source = value.source, .generation = value.generation, .payload = copy(storage, &offset, value.payload) };
                    for (selected, source.edits) |*edit, original| edit.* = .{ .range = original.range, .text = copy(storage, &offset, original.text) };
                }
                break :blk .{ .completion = output };
            },
            .hover => |value| .{ .hover = .{ .range = value.range, .text = copy(storage, &offset, value.text) } },
            .diagnostics => |items| blk: {
                const output: []Diagnostic = @as([*]Diagnostic, @ptrCast(storage.ptr))[0..items.len];
                offset = items.len * @sizeOf(Diagnostic);
                for (output, items) |*target, source| target.* = .{ .range = source.range, .severity = source.severity, .message = copy(storage, &offset, source.message), .source = copy(storage, &offset, source.source) };
                break :blk .{ .diagnostics = output };
            },
        };
        std.debug.assert(offset == size);
        return .{ .allocator = allocator, .storage = storage, .data = data };
    }
    pub fn deinit(self: *OwnedResult) void {
        const storage = self.storage orelse return;
        self.storage = null;
        self.data = .{ .completion = &.{} };
        self.allocator.free(storage);
    }
    pub fn byteLength(self: *const OwnedResult) !usize {
        return (self.storage orelse return error.ResultMoved).len;
    }
};

/// Shared allocation-free validation for producer construction and the owner's
/// potentially narrower policy at publication. Returns exact owning byte cost.
pub fn validate(input: Data, limits: Limits) !usize {
    try limits.validate();
    var size: usize = 0;
    switch (input) {
        .completion => |items| {
            if (items.len > limits.completions) return error.CapacityExceeded;
            try add(&size, try mul(items.len, @sizeOf(Completion)), limits.bytes);
            for (items) |item| {
                if (item.label.len == 0 or item.label.len > 512 or item.edits.len == 0) return error.InvalidCompletion;
                if (item.edits.len > limits.edits_per_completion) return error.CapacityExceeded;
                if (item.insertion == .snippet and item.insertion.snippet >= item.edits.len) return error.InvalidSnippetEdit;
                try add(&size, try mul(item.edits.len, @sizeOf(d.Replacement)), limits.bytes);
                try textSize(&size, item.label, limits);
                try textSize(&size, item.detail, limits);
                try textSize(&size, item.documentation, limits);
                if (item.continuation) |value| {
                    if (value.source == 0 or value.generation == 0) return error.InvalidContinuation;
                    if (value.payload.len == 0 or value.payload.len > limits.continuation_bytes) return error.CapacityExceeded;
                    try add(&size, value.payload.len, limits.bytes);
                }
                try validateEdits(item.edits);
                for (item.edits) |edit| try textSize(&size, edit.text, limits);
            }
        },
        .hover => |value| {
            try validRange(value.range);
            try textSize(&size, value.text, limits);
        },
        .diagnostics => |items| {
            if (items.len > limits.diagnostics) return error.CapacityExceeded;
            try add(&size, try mul(items.len, @sizeOf(Diagnostic)), limits.bytes);
            for (items) |item| {
                try validRange(item.range);
                try textSize(&size, item.message, limits);
                try textSize(&size, item.source, limits);
            }
        },
    }
    return size;
}

fn mul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.CapacityExceeded;
}
fn add(size: *usize, bytes: usize, limit: usize) !void {
    if (bytes > limit -| size.*) return error.CapacityExceeded;
    size.* += bytes;
}
fn validRange(range: d.Range) !void {
    if (range.start > range.end) return error.InvalidRange;
}
fn textSize(size: *usize, text: []const u8, limits: Limits) !void {
    if (text.len > limits.text_bytes) return error.CapacityExceeded;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    try add(size, text.len, limits.bytes);
}
fn copy(storage: []u8, offset: *usize, text: []const u8) []const u8 {
    const result = storage[offset.*..][0..text.len];
    @memcpy(result, text);
    offset.* += text.len;
    return result;
}
pub fn validateEdits(edits: []const d.Replacement) !void {
    var previous: ?d.Range = null;
    for (edits) |edit| {
        try validRange(edit.range);
        if (previous) |before| if (edit.range.start <= before.start or edit.range.start < before.end or (edit.range.start == before.end and (edit.range.start == edit.range.end or before.start == before.end))) return error.OverlappingEdits;
        previous = edit.range;
    }
}

fn fixture(allocator: std.mem.Allocator) !void {
    var result = try OwnedResult.init(allocator, .{ .completion = &.{.{ .label = "name", .detail = "type", .documentation = "description", .edits = &.{ .{ .range = .{ .start = 0, .end = 0 }, .text = "import;\n" }, .{ .range = .{ .start = 3, .end = 5 }, .text = "name" } } }} }, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("name", result.data.completion[0].label);
    try std.testing.expectEqualStrings("import;\n", result.data.completion[0].edits[0].text);
    try std.testing.expect((try result.byteLength()) <= 256 * 1024);
}
test "result descriptors and all nested text are owned with transactional OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixture, .{});
    var text = [_]u8{ 'a', 'b', 'c' };
    var result = try OwnedResult.init(std.testing.allocator, .{ .hover = .{ .range = .{ .start = 1, .end = 2 }, .text = &text } }, .{});
    defer result.deinit();
    @memset(&text, 'x');
    try std.testing.expectEqualStrings("abc", result.data.hover.text);
    result.deinit();
    try std.testing.expectError(error.ResultMoved, result.byteLength());
}
test "result budgets text and ambiguous original-coordinate edits fail before ownership" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.CapacityExceeded, OwnedResult.init(allocator, .{ .hover = .{ .range = .{ .start = 0, .end = 0 }, .text = "abcd" } }, .{ .bytes = 3 }));
    try std.testing.expectError(error.InvalidUtf8, OwnedResult.init(allocator, .{ .hover = .{ .range = .{ .start = 0, .end = 0 }, .text = "\xff" } }, .{}));
    try std.testing.expectError(error.EmbeddedNul, OwnedResult.init(allocator, .{ .hover = .{ .range = .{ .start = 0, .end = 0 }, .text = "a\x00b" } }, .{}));
    try std.testing.expectError(error.InvalidRange, OwnedResult.init(allocator, .{ .diagnostics = &.{.{ .range = .{ .start = 2, .end = 1 }, .message = "problem" }} }, .{}));
    try std.testing.expectError(error.OverlappingEdits, OwnedResult.init(allocator, .{ .completion = &.{.{ .label = "x", .edits = &.{ .{ .range = .{ .start = 0, .end = 0 }, .text = "x" }, .{ .range = .{ .start = 0, .end = 0 }, .text = "y" } } }} }, .{}));
}

test "completion insertion format owns its source and validates the unique template edit" {
    var bytes = [_]u8{ '$', '1' };
    var result = try OwnedResult.init(std.testing.allocator, .{ .completion = &.{.{ .label = "snippet", .insertion = .{ .snippet = 1 }, .edits = &.{ .{ .range = .{ .start = 0, .end = 0 }, .text = "import;" }, .{ .range = .{ .start = 1, .end = 2 }, .text = &bytes } } }} }, .{});
    defer result.deinit();
    @memset(&bytes, 'x');
    try std.testing.expectEqual(@as(usize, 1), result.data.completion[0].insertion.snippet);
    try std.testing.expectEqualStrings("$1", result.data.completion[0].edits[1].text);
    try std.testing.expectError(error.InvalidSnippetEdit, OwnedResult.init(std.testing.allocator, .{ .completion = &.{.{ .label = "invalid", .insertion = .{ .snippet = 1 }, .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "x" }} }} }, .{}));
}
