const std = @import("std");
const d = @import("ziggurat_document");
const code = @import("ziggurat_code_editor");
const positions = @import("positions.zig");
const codec = @import("codec.zig");

pub const Origin = struct { source: u64, generation: u64 };
pub const Limits = struct { continuation: ?Origin = null, raw_bytes: usize = 256 * 1024, result: code.ResultLimits = .{}, bytes: usize = 1024 * 1024, markup_parts: usize = 64, snippets: bool = false, request_position: ?usize = null };
pub const CompletionResult = struct { owned: code.OwnedResult, is_incomplete: bool };
fn get(value: std.json.Value, key: []const u8) !?std.json.Value {
    if (value != .object) return error.InvalidResult;
    return value.object.get(key);
}
fn required(value: std.json.Value, key: []const u8) !std.json.Value {
    return try get(value, key) orelse error.InvalidResult;
}
fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidResult;
    return value.string;
}
fn optionalString(value: std.json.Value, key: []const u8) ![]const u8 {
    return if (try get(value, key)) |part| string(part) else "";
}
fn integer(value: std.json.Value) !u32 {
    const number = codec.integerValue(value) catch return error.InvalidPosition;
    if (number < 0 or number > 0x7fffffff) return error.InvalidPosition;
    return @intCast(number);
}
fn position(value: std.json.Value) !positions.Position {
    return .{ .line = try integer(try required(value, "line")), .character = try integer(try required(value, "character")) };
}
fn range(map: *const positions.Map, value: std.json.Value) !d.Range {
    return map.toRange(.{ .start = try position(try required(value, "start")), .end = try position(try required(value, "end")) });
}
fn textEdit(map: *const positions.Map, value: std.json.Value) !d.Replacement {
    if (try get(value, "insert") != null or try get(value, "replace") != null) return error.UnsupportedInsertReplaceEdit;
    return .{ .range = try range(map, try required(value, "range")), .text = try string(try required(value, "newText")) };
}
fn markup(value: std.json.Value) ![]const u8 {
    if (value == .string) return value.string;
    if (try get(value, "kind")) |kind| {
        const name = try string(kind);
        if (!std.mem.eql(u8, name, "plaintext") and !std.mem.eql(u8, name, "markdown")) return error.UnsupportedMarkupKind;
    } else if (try get(value, "language")) |language| _ = try string(language) else return error.InvalidResult;
    return string(try required(value, "value"));
}
pub fn validate(limits: Limits) !void {
    try limits.result.validate();
    if (limits.bytes == 0 or limits.bytes > 64 * 1024 * 1024 or limits.raw_bytes > 16 * 1024 * 1024 or limits.markup_parts == 0 or limits.markup_parts > 1024) return error.InvalidLimits;
}
fn owned(allocator: std.mem.Allocator, data: code.results.Data, scratch: usize, limits: Limits) !code.OwnedResult {
    const size = try code.results.validate(data, limits.result);
    if (size > limits.bytes -| scratch) return error.ConversionCapacityExceeded;
    return code.OwnedResult.init(allocator, data, limits.result);
}
/// Pure explicit preparation. Input JSON/Reader/Map are immutable borrowed
/// inputs; returned storage is independent and can be posted to the owner.
pub fn completion(allocator: std.mem.Allocator, value: std.json.Value, reader: d.Reader, map: *const positions.Map, fallback: d.Range, limits: Limits) !CompletionResult {
    try validate(limits);
    if (!try map.matches(reader)) return error.ForeignPositionMap;
    _ = try map.fromRange(fallback);
    var incomplete = false;
    const values: []const std.json.Value = switch (value) {
        .null => &.{},
        .array => |items| items.items,
        .object => blk: {
            if (value.object.get("itemDefaults")) |defaults| if (defaults != .object or defaults.object.count() != 0) return error.UnsupportedCompletionDefaults;
            if (value.object.get("isIncomplete")) |flag| {
                if (flag != .bool) return error.InvalidResult;
                incomplete = flag.bool;
            } else return error.InvalidResult;
            const items = try required(value, "items");
            if (items != .array) return error.InvalidResult;
            break :blk items.array.items;
        },
        else => return error.InvalidResult,
    };
    if (values.len > limits.result.completions) return error.CapacityExceeded;
    var edit_count: usize = 0;
    for (values) |item| {
        var count: usize = 1;
        if (try get(item, "additionalTextEdits")) |additional| {
            if (additional != .array) return error.InvalidResult;
            if (additional.array.items.len >= limits.result.edits_per_completion) return error.CapacityExceeded;
            count += additional.array.items.len;
        }
        edit_count += count;
    }
    const Order = struct { item: code.Completion, key: []const u8, ordinal: usize };
    var scratch = values.len * (@sizeOf(Order) + @sizeOf(code.Completion)) + edit_count * @sizeOf(d.Replacement);
    var raw: []u8 = &.{};
    defer allocator.free(raw);
    var raw_sizes: []usize = &.{};
    defer allocator.free(raw_sizes);
    if (limits.continuation != null) {
        const metadata = values.len * @sizeOf(usize);
        if (metadata > limits.bytes -| scratch) return error.ConversionCapacityExceeded;
        scratch += metadata;
        raw_sizes = try allocator.alloc(usize, values.len);
        var total: usize = 0;
        for (values, raw_sizes) |item, *length| {
            length.* = try codec.valueLength(item, limits.result.continuation_bytes);
            if (length.* > limits.raw_bytes -| total) return error.ConversionCapacityExceeded;
            total += length.*;
        }
        if (total > limits.bytes -| scratch) return error.ConversionCapacityExceeded;
        scratch += total;
        raw = try allocator.alloc(u8, total);
    }
    if (scratch > limits.bytes) return error.ConversionCapacityExceeded;
    const order = try allocator.alloc(Order, values.len);
    defer allocator.free(order);
    const output = try allocator.alloc(code.Completion, values.len);
    defer allocator.free(output);
    const edits = try allocator.alloc(d.Replacement, edit_count);
    defer allocator.free(edits);
    var at: usize = 0;
    var raw_at: usize = 0;
    for (values, 0..) |item, index| {
        if (try get(item, "command")) |command| if (command != .null) return error.UnsupportedCompletionCommand;
        if (try get(item, "textEditText") != null) return error.UnsupportedCompletionDefaults;
        if (try get(item, "insertTextMode")) |mode| if ((codec.integerValue(mode) catch return error.UnsupportedInsertTextMode) != 1) return error.UnsupportedInsertTextMode;
        const label = try string(try required(item, "label"));
        if (try get(item, "filterText")) |filter| if (!std.mem.eql(u8, try string(filter), label)) return error.UnsupportedCompletionFiltering;
        const main: d.Replacement = if (try get(item, "textEdit")) |edit| try textEdit(map, edit) else .{ .range = fallback, .text = if (try get(item, "insertText")) |text| try string(text) else label };
        const main_position = try map.fromRange(main.range);
        if (main_position.start.line != main_position.end.line) return error.UnsupportedCompletionRange;
        if (limits.request_position) |position_byte| if (position_byte < main.range.start or position_byte > main.range.end) return error.InvalidCompletionRange;
        var snippet = false;
        if (try get(item, "insertTextFormat")) |format| {
            const number = codec.integerValue(format) catch return error.UnsupportedInsertTextFormat;
            if (number != 1 and number != 2) return error.UnsupportedInsertTextFormat;
            snippet = number == 2;
            if (snippet and !limits.snippets) return error.SnippetsDisabled;
        }
        const first = at;
        edits[at] = main;
        at += 1;
        if (try get(item, "additionalTextEdits")) |additional| for (additional.array.items) |edit| {
            edits[at] = try textEdit(map, edit);
            at += 1;
        };
        const selected = edits[first..at];
        // The primary descriptor remains identifiable after strict range sort.
        var main_index: usize = 0;
        for (selected[1..]) |edit| if (edit.range.start < main.range.start) {
            main_index += 1;
        };
        std.mem.sort(d.Replacement, selected, {}, struct {
            fn less(_: void, left: d.Replacement, right: d.Replacement) bool {
                return left.range.start < right.range.start;
            }
        }.less);
        try code.results.validateEdits(selected);
        order[index] = .{ .key = if (try get(item, "sortText")) |text| try string(text) else label, .ordinal = index, .item = .{ .label = label, .detail = try optionalString(item, "detail"), .documentation = if (try get(item, "documentation")) |docs| try markup(docs) else "", .edits = selected, .insertion = if (snippet) .{ .snippet = main_index } else .plain } };
        if (limits.continuation) |origin| {
            const payload = raw[raw_at..][0..raw_sizes[index]];
            try codec.writeValue(item, payload);
            raw_at += payload.len;
            order[index].item.continuation = .{ .source = origin.source, .generation = origin.generation, .payload = payload };
        }
    }
    std.mem.sort(Order, order, {}, struct {
        fn less(_: void, left: Order, right: Order) bool {
            const comparison = std.mem.order(u8, left.key, right.key);
            return comparison == .lt or (comparison == .eq and left.ordinal < right.ordinal);
        }
    }.less);
    for (output, order) |*item, entry| item.* = entry.item;
    return .{ .owned = try owned(allocator, .{ .completion = output }, scratch, limits), .is_incomplete = incomplete };
}
pub fn hover(allocator: std.mem.Allocator, value: std.json.Value, reader: d.Reader, map: *const positions.Map, fallback: d.Range, limits: Limits) !code.OwnedResult {
    try validate(limits);
    if (!try map.matches(reader)) return error.ForeignPositionMap;
    _ = try map.fromRange(fallback);
    if (value == .null) return owned(allocator, .{ .hover = .{ .range = fallback, .text = "" } }, 0, limits);
    const target = if (try get(value, "range")) |bounds| try range(map, bounds) else fallback;
    const contents = try required(value, "contents");
    if (contents != .array) return owned(allocator, .{ .hover = .{ .range = target, .text = try markup(contents) } }, 0, limits);
    var length: usize = 0;
    if (contents.array.items.len > limits.markup_parts) return error.CapacityExceeded;
    for (contents.array.items, 0..) |item, index| {
        const text = try markup(item);
        if (text.len > limits.result.text_bytes -| length) return error.CapacityExceeded;
        length += text.len;
        if (index != 0) {
            if (length == limits.result.text_bytes) return error.CapacityExceeded;
            length += 1;
        }
    }
    if (length > limits.bytes) return error.ConversionCapacityExceeded;
    const text = try allocator.alloc(u8, length);
    defer allocator.free(text);
    var at: usize = 0;
    for (contents.array.items, 0..) |item, index| {
        if (index != 0) {
            text[at] = '\n';
            at += 1;
        }
        const part = try markup(item);
        @memcpy(text[at..][0..part.len], part);
        at += part.len;
    }
    return owned(allocator, .{ .hover = .{ .range = target, .text = text } }, length, limits);
}
/// Unversioned diagnostics are deliberately rejected. Arrival time is never
/// relabeled as their source version; URI and synchronized server version match.
pub fn diagnostics(allocator: std.mem.Allocator, params: std.json.Value, reader: d.Reader, map: *const positions.Map, expected_uri: []const u8, expected_version: i32, limits: Limits) !code.OwnedResult {
    try validate(limits);
    if (!try map.matches(reader)) return error.ForeignPositionMap;
    if (!std.mem.eql(u8, try string(try required(params, "uri")), expected_uri)) return error.ForeignDocument;
    const version = try get(params, "version") orelse return error.UnversionedDiagnostics;
    if (version != .integer or version.integer != expected_version) return error.StaleVersion;
    const list = try required(params, "diagnostics");
    if (list != .array) return error.InvalidResult;
    if (list.array.items.len > limits.result.diagnostics) return error.CapacityExceeded;
    const scratch = list.array.items.len * @sizeOf(code.Diagnostic);
    if (scratch > limits.bytes) return error.ConversionCapacityExceeded;
    const items = try allocator.alloc(code.Diagnostic, list.array.items.len);
    defer allocator.free(items);
    for (items, list.array.items) |*item, value| {
        var severity: code.Severity = .err;
        if (try get(value, "severity")) |part| {
            if (part != .integer) return error.InvalidResult;
            severity = switch (part.integer) {
                1 => .err,
                2 => .warning,
                3 => .info,
                4 => .hint,
                else => return error.InvalidResult,
            };
        }
        item.* = .{ .range = try range(map, try required(value, "range")), .severity = severity, .message = try string(try required(value, "message")), .source = try optionalString(value, "source") };
    }
    return owned(allocator, .{ .diagnostics = items }, scratch, limits);
}

fn fixture(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "a😀\r\nxyz", .{});
    defer document.close() catch unreachable;
    const snapshot = try document.snapshot();
    defer snapshot.close() catch unreachable;
    const reader = try snapshot.borrowReader();
    defer reader.release() catch unreachable;
    const map = try positions.Map.create(allocator, reader, .{});
    defer map.close() catch unreachable;
    const message = try codec.Message.parse(allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"isIncomplete\":true,\"items\":[{\"label\":\"z\",\"insertText\":\"literal\"},{\"label\":\"a\",\"insertTextFormat\":2,\"textEdit\":{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":3}},\"newText\":\"${1:name}=$1$0\"},\"additionalTextEdits\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"import;\\n\"}]}]}}", .{});
    defer message.close() catch unreachable;
    var result = try completion(allocator, (try message.value()).response.result, reader, map, .{ .start = 1, .end = 5 }, .{ .snippets = true });
    defer result.owned.deinit();
    try std.testing.expect(result.is_incomplete);
    try std.testing.expectEqualStrings("a", result.owned.data.completion[0].label);
    try std.testing.expectEqual(@as(usize, 1), result.owned.data.completion[0].insertion.snippet);
    try std.testing.expectEqual(d.Range{ .start = 1, .end = 5 }, result.owned.data.completion[0].edits[1].range);
    try std.testing.expectEqualStrings("${1:name}=$1$0", result.owned.data.completion[0].edits[1].text);
    const hover_message = try codec.Message.parse(allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"contents\":[\"plain\",{\"language\":\"zig\",\"value\":\"code\"},{\"kind\":\"markdown\",\"value\":\"**raw**\"}]}}", .{});
    defer hover_message.close() catch unreachable;
    var hovered = try hover(allocator, (try hover_message.value()).response.result, reader, map, .{ .start = 1, .end = 5 }, .{});
    defer hovered.deinit();
    try std.testing.expectEqualStrings("plain\ncode\n**raw**", hovered.data.hover.text);
    const diagnostics_message = try codec.Message.parse(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///fixture\",\"version\":7,\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":3}},\"severity\":2,\"message\":\"warning\"}]}}", .{});
    defer diagnostics_message.close() catch unreachable;
    var diagnosed = try diagnostics(allocator, (try diagnostics_message.value()).notification.params.?, reader, map, "file:///fixture", 7, .{});
    defer diagnosed.deinit();
    try std.testing.expectEqual(code.Severity.warning, diagnosed.data.diagnostics[0].severity);
    try std.testing.expectEqual(d.Range{ .start = 1, .end = 5 }, diagnosed.data.diagnostics[0].range);
}
test "worker result conversion owns completion snippets additional edits hover and versioned diagnostics under OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixture, .{});
}

test "unsupported completion semantics surrogate interiors and unversioned diagnostics never publish approximations" {
    const a = std.testing.allocator;
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "a😀\r\nxyz", .{});
    defer document.close() catch unreachable;
    const snapshot = try document.snapshot();
    defer snapshot.close() catch unreachable;
    const reader = try snapshot.borrowReader();
    defer reader.release() catch unreachable;
    const map = try positions.Map.create(a, reader, .{});
    defer map.close() catch unreachable;
    const cases = .{
        .{ "[{\"label\":\"s\",\"insertTextFormat\":2,\"insertText\":\"$1\"}]", error.SnippetsDisabled },
        .{ "[{\"label\":\"s\",\"command\":{\"command\":\"fix\"}}]", error.UnsupportedCompletionCommand },
        .{ "[{\"label\":\"s\",\"insertTextMode\":2}]", error.UnsupportedInsertTextMode },
        .{ "[{\"label\":\"s\",\"filterText\":\"different\"}]", error.UnsupportedCompletionFiltering },
        .{ "{\"isIncomplete\":false,\"itemDefaults\":{\"insertTextFormat\":2},\"items\":[]}", error.UnsupportedCompletionDefaults },
        .{ "[{\"label\":\"s\",\"textEdit\":{\"insert\":{},\"replace\":{},\"newText\":\"s\"}}]", error.UnsupportedInsertReplaceEdit },
        .{ "[{\"label\":\"s\",\"textEdit\":{\"range\":{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":3}},\"newText\":\"s\"}}]", error.InvalidBoundary },
    };
    inline for (cases) |item| {
        const message = try codec.Message.parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":" ++ item[0] ++ "}", .{});
        defer message.close() catch unreachable;
        try std.testing.expectError(item[1], completion(a, (try message.value()).response.result, reader, map, .{ .start = 0, .end = 1 }, .{}));
    }
    const unversioned = try codec.Message.parse(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///fixture\",\"diagnostics\":[]}}", .{});
    defer unversioned.close() catch unreachable;
    try std.testing.expectError(error.UnversionedDiagnostics, diagnostics(a, (try unversioned.value()).notification.params.?, reader, map, "file:///fixture", 1, .{}));
    const stale = try codec.Message.parse(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///fixture\",\"version\":2,\"diagnostics\":[]}}", .{});
    defer stale.close() catch unreachable;
    try std.testing.expectError(error.StaleVersion, diagnostics(a, (try stale.value()).notification.params.?, reader, map, "file:///fixture", 1, .{}));
    try std.testing.expectError(error.ForeignDocument, diagnostics(a, (try stale.value()).notification.params.?, reader, map, "file:///other", 2, .{}));
    const revision = try document.version();
    try std.testing.expectEqual(revision, try snapshot.version());
}

fn continuationFixture(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const snapshot = try document.snapshot();
    defer snapshot.close() catch unreachable;
    const reader = try snapshot.borrowReader();
    defer reader.release() catch unreachable;
    const map = try positions.Map.create(allocator, reader, .{});
    defer map.close() catch unreachable;
    const message = try codec.Message.parseLossless(allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"label\":\"z\",\"data\":{\"huge\":123456789012345678901234567890},\"unknown\":[true,null]},{\"label\":\"a\",\"insertTextFormat\":2,\"insertText\":\"$1\"}]}", .{});
    var message_live = true;
    defer if (message_live) message.close() catch unreachable;
    var result = try completion(allocator, (try message.value()).response.result, reader, map, .{ .start = 0, .end = 1 }, .{ .snippets = true, .continuation = .{ .source = 19, .generation = 3 } });
    defer result.owned.deinit();
    try message.close();
    message_live = false;
    const payload = result.owned.data.completion[1].continuation.?;
    try std.testing.expectEqual(@as(u64, 19), payload.source);
    try std.testing.expect(std.mem.indexOf(u8, payload.payload, "123456789012345678901234567890") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload.payload, "\"unknown\":[true,null]") != null);
    try std.testing.expect(result.owned.data.completion[0].insertion == .snippet);
}
test "explicit lossless raw continuation survives source close sorting and every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, continuationFixture, .{});
}
