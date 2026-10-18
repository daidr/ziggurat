const std = @import("std");
const code = @import("ziggurat_code_editor");
const codec = @import("codec.zig");
const positions = @import("positions.zig");

pub const Limits = struct {
    /// Conservative live input + candidate + both JSON trees + packet bound.
    bytes: usize = 16 * 1024 * 1024,
    source_json_bytes: usize = 2 * 1024 * 1024,
    work_bytes: usize = 16 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.bytes == 0 or self.bytes > 64 * 1024 * 1024 or self.source_json_bytes < 1024 or self.source_json_bytes > 16 * 1024 * 1024 or self.work_bytes == 0 or self.work_bytes > 256 * 1024 * 1024) return error.InvalidLimits;
    }
};
var next_source: std.atomic.Value(u64) = .init(1);
pub fn sourceIdentity() !u64 {
    var id = next_source.load(.acquire);
    while (true) {
        if (id == std.math.maxInt(u64)) return error.IdExhausted;
        id = next_source.cmpxchgWeak(id, id + 1, .acq_rel, .acquire) orelse return id;
    }
}
pub const Work = struct {
    remaining: usize,
    cancellation: ?*const positions.Cancellation = null,
    pub fn take(self: *Work, amount: usize) !void {
        if (self.cancellation) |flag| if (flag.requested.load(.acquire)) return error.Cancelled;
        if (amount > self.remaining) return error.ResolveWorkExceeded;
        self.remaining -= amount;
    }
};
fn same(a: std.json.Value, b: std.json.Value, work: *Work) anyerror!bool {
    try work.take(1);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string, .number_string => blk: {
            const left = if (a == .string) a.string else a.number_string;
            const right = if (b == .string) b.string else b.number_string;
            try work.take(left.len + right.len);
            break :blk std.mem.eql(u8, left, right);
        },
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |left, right| if (!try same(left, right, work)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var iterator = a.object.iterator();
            while (iterator.next()) |entry| {
                try work.take(entry.key_ptr.len);
                if (!try same(entry.value_ptr.*, b.object.get(entry.key_ptr.*) orelse break :blk false, work)) break :blk false;
            }
            break :blk true;
        },
    };
}
fn metadata(value: std.json.Value, documentation: bool) ![]const u8 {
    if (value == .string) return value.string;
    if (!documentation or value != .object) return error.InvalidResolvedMetadata;
    const kind = value.object.get("kind") orelse return error.InvalidResolvedMetadata;
    if (kind != .string or (!std.mem.eql(u8, kind.string, "plaintext") and !std.mem.eql(u8, kind.string, "markdown"))) return error.InvalidResolvedMetadata;
    const text = value.object.get("value") orelse return error.InvalidResolvedMetadata;
    if (text != .string) return error.InvalidResolvedMetadata;
    return text.string;
}
/// Only detail/documentation may change. Missing readonly fields inherit their
/// original value; every present readonly/unknown field is compared losslessly.
pub fn candidate(allocator: std.mem.Allocator, input: *const code.OwnedResult, index: usize, response: std.json.Value, framing: codec.Limits, limits: Limits, result_limits: code.ResultLimits, work: *Work) !code.OwnedResult {
    try limits.validate();
    if (input.storage == null or input.data != .completion or index >= input.data.completion.len or response != .object) return error.InvalidResult;
    const items = input.data.completion;
    const source = items[index].continuation orelse return error.ContinuationRequired;
    try work.take(source.payload.len + (try input.byteLength()));
    var source_limits = framing;
    source_limits.json_bytes = limits.source_json_bytes;
    const original = try codec.JsonValue.parseLossless(allocator, source.payload, source_limits);
    var original_live = true;
    defer if (original_live) original.close() catch unreachable;
    const before = try original.value();
    if (before != .object) return error.InvalidResult;
    const label = response.object.get("label") orelse return error.InvalidResult;
    if (label != .string or !std.mem.eql(u8, label.string, items[index].label)) return error.UnsupportedResolvedProperty;
    try work.take(0);
    var fields = response.object.iterator();
    while (fields.next()) |field| {
        try work.take(field.key_ptr.len);
        if (std.mem.eql(u8, field.key_ptr.*, "detail") or std.mem.eql(u8, field.key_ptr.*, "documentation")) continue;
        const old = before.object.get(field.key_ptr.*) orelse return error.UnsupportedResolvedProperty;
        if (!try same(old, field.value_ptr.*, work)) return error.UnsupportedResolvedProperty;
    }
    const detail = if (response.object.get("detail")) |value| try metadata(value, false) else items[index].detail;
    const documentation = if (response.object.get("documentation")) |value| try metadata(value, true) else items[index].documentation;
    const size = try std.math.mul(usize, items.len, @sizeOf(code.Completion));
    if (size > limits.bytes) return error.ResolveCapacityExceeded;
    const output = try allocator.dupe(code.Completion, items);
    var output_live = true;
    defer if (output_live) allocator.free(output);
    output[index].detail = detail;
    output[index].documentation = documentation;
    const bytes = try code.results.validate(.{ .completion = output }, result_limits);
    if (bytes > limits.bytes - size) return error.ResolveCapacityExceeded;
    try work.take(bytes);
    var owned = try code.OwnedResult.init(allocator, .{ .completion = output }, result_limits);
    errdefer owned.deinit();
    allocator.free(output);
    output_live = false;
    try original.close();
    original_live = false;
    try work.take(0); // Includes cancellation from the last foreign scratch free.
    return owned;
}

fn fixture(allocator: std.mem.Allocator) !void {
    var input = try code.OwnedResult.init(allocator, .{ .completion = &.{.{ .label = "item", .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "$1" }}, .insertion = .{ .snippet = 0 }, .continuation = .{ .source = 1, .generation = 1, .payload = "{\"label\":\"item\",\"data\":{\"n\":123456789012345678901234567890},\"insertText\":\"$1\",\"insertTextFormat\":2}" } }} }, .{});
    defer input.deinit();
    const message = try codec.JsonValue.parseLossless(allocator, "{\"label\":\"item\",\"detail\":\"resolved\",\"documentation\":{\"kind\":\"markdown\",\"value\":\"owned docs\"}}", .{});
    defer message.close() catch unreachable;
    var work: Work = .{ .remaining = 1024 * 1024 };
    var result = try candidate(allocator, &input, 0, try message.value(), .{}, .{}, .{}, &work);
    defer result.deinit();
    try std.testing.expectEqualStrings("resolved", result.data.completion[0].detail);
    try std.testing.expectEqualStrings(input.data.completion[0].continuation.?.payload, result.data.completion[0].continuation.?.payload);
    const invalid = try codec.JsonValue.parseLossless(allocator, "{\"label\":\"item\",\"insertText\":\"changed\"}", .{});
    defer invalid.close() catch unreachable;
    var unexpected = candidate(allocator, &input, 0, try invalid.value(), .{}, .{}, .{}, &work) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.UnsupportedResolvedProperty, err);
        return;
    };
    unexpected.deinit();
    return error.TestExpectedError;
}
test "metadata-only resolve preserves original fields snippets and candidate ownership under every OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixture, .{});
}

test "resolve readonly comparison preserves numbers null arrays unknown fields and missing metadata" {
    const a = std.testing.allocator;
    var input = try code.OwnedResult.init(a, .{ .completion = &.{.{ .label = "a", .detail = "old", .documentation = "docs", .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "a" }}, .continuation = .{ .source = 1, .generation = 1, .payload = "{\"label\":\"a\",\"data\":{\"n\":1.00,\"v\":[true,null]},\"unknown\":null}" } }} }, .{});
    defer input.deinit();
    const cases = .{
        .{ "{\"label\":\"a\",\"data\":{\"v\":[true,null],\"n\":1.00},\"unknown\":null}", @as(?anyerror, null) },
        .{ "{\"label\":\"a\",\"data\":{\"n\":1,\"v\":[true,null]}}", @as(?anyerror, error.UnsupportedResolvedProperty) },
        .{ "{\"label\":\"a\",\"data\":{\"n\":1.00,\"v\":[null,true]}}", @as(?anyerror, error.UnsupportedResolvedProperty) },
        .{ "{\"label\":\"a\",\"command\":{\"command\":\"run\"}}", @as(?anyerror, error.UnsupportedResolvedProperty) },
        .{ "{\"label\":\"a\",\"detail\":null}", @as(?anyerror, error.InvalidResolvedMetadata) },
        .{ "{\"label\":\"a\",\"documentation\":{\"kind\":\"html\",\"value\":\"x\"}}", @as(?anyerror, error.InvalidResolvedMetadata) },
    };
    inline for (cases) |case| {
        const message = try codec.JsonValue.parseLossless(a, case[0], .{});
        defer message.close() catch unreachable;
        var work: Work = .{ .remaining = 1024 * 1024 };
        if (case[1]) |expected| {
            try std.testing.expectError(expected, candidate(a, &input, 0, try message.value(), .{}, .{}, .{}, &work));
        } else {
            var output = try candidate(a, &input, 0, try message.value(), .{}, .{}, .{}, &work);
            defer output.deinit();
            try std.testing.expectEqualStrings("old", output.data.completion[0].detail);
            try std.testing.expectEqualStrings("docs", output.data.completion[0].documentation);
        }
    }
    var work: Work = .{ .remaining = 1 };
    const message = try codec.JsonValue.parseLossless(a, "{\"label\":\"a\"}", .{});
    defer message.close() catch unreachable;
    try std.testing.expectError(error.ResolveWorkExceeded, candidate(a, &input, 0, try message.value(), .{}, .{}, .{}, &work));
    var cancellation: positions.Cancellation = .{};
    cancellation.request();
    work = .{ .remaining = 1024 * 1024, .cancellation = &cancellation };
    try std.testing.expectError(error.Cancelled, candidate(a, &input, 0, try message.value(), .{}, .{}, .{}, &work));
}

test "resolve cancels at every foreign temporary free including final cleanup" {
    const Probe = struct {
        flag: *positions.Cancellation,
        target: usize,
        frees: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.frees == self.target) self.flag.request();
            self.frees += 1;
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    const a = std.testing.allocator;
    var input = try code.OwnedResult.init(a, .{ .completion = &.{.{ .label = "a", .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "a" }}, .continuation = .{ .source = 1, .generation = 1, .payload = "{\"label\":\"a\",\"data\":[1,2]}" } }} }, .{});
    defer input.deinit();
    const message = try codec.JsonValue.parseLossless(a, "{\"label\":\"a\",\"detail\":\"new\"}", .{});
    defer message.close() catch unreachable;
    var saw_success = false;
    for (0..128) |target| {
        var flag: positions.Cancellation = .{};
        var probe: Probe = .{ .flag = &flag, .target = target };
        var work: Work = .{ .remaining = 1024 * 1024, .cancellation = &flag };
        var result = candidate(probe.allocator(), &input, 0, try message.value(), .{}, .{}, .{}, &work) catch |err| {
            try std.testing.expectEqual(error.Cancelled, err);
            continue;
        };
        try std.testing.expect(!flag.requested.load(.acquire));
        result.deinit();
        saw_success = true;
        break;
    }
    try std.testing.expect(saw_success);
}
