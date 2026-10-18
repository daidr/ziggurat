const std = @import("std");
const d = @import("ziggurat_document");
const codec = @import("codec.zig");
const positions = @import("positions.zig");

pub const SyncKind = enum { none, full, incremental };
pub const Registration = struct {
    bytes: [128]u8 = undefined,
    len: u8 = 0,
    pub fn value(self: *const Registration) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Capabilities = struct {
    sync: SyncKind = .none,
    open_close: bool = false,
    completion: bool = false,
    completion_resolve: bool = false,
    hover: bool = false,
    workspace_folders: bool = false,
    workspace_changes: bool = false,
    workspace_registration: ?Registration = null,
};
fn field(value: std.json.Value, key: []const u8) !?std.json.Value {
    if (value != .object) return error.InvalidCapabilities;
    return value.object.get(key);
}
fn syncKind(value: std.json.Value) !SyncKind {
    if (value != .integer) return error.InvalidCapabilities;
    return switch (value.integer) {
        0 => .none,
        1 => .full,
        2 => .incremental,
        else => error.UnsupportedSyncKind,
    };
}
pub fn capabilities(result: std.json.Value) !Capabilities {
    const object = try field(result, "capabilities") orelse return error.InvalidCapabilities;
    if (try field(object, "positionEncoding")) |encoding| if (encoding != .string or !std.mem.eql(u8, encoding.string, "utf-16")) return error.UnsupportedPositionEncoding;
    var output: Capabilities = .{};
    if (try field(object, "textDocumentSync")) |sync| {
        if (sync == .integer) {
            output.sync = try syncKind(sync);
            output.open_close = output.sync != .none;
        } else if (sync == .object) {
            if (sync.object.get("openClose")) |open| {
                if (open != .bool) return error.InvalidCapabilities;
                output.open_close = open.bool;
            }
            if (sync.object.get("change")) |change| output.sync = try syncKind(change);
        } else return error.InvalidCapabilities;
    }
    if (try field(object, "completionProvider")) |completion| {
        if (completion != .object) return error.InvalidCapabilities;
        output.completion = true;
        if (completion.object.get("resolveProvider")) |resolve| {
            if (resolve != .bool) return error.InvalidCapabilities;
            output.completion_resolve = resolve.bool;
        }
    }
    if (try field(object, "hoverProvider")) |hover| output.hover = switch (hover) {
        .bool => hover.bool,
        .object => true,
        else => return error.InvalidCapabilities,
    };
    if (try field(object, "workspace")) |workspace| if (try field(workspace, "workspaceFolders")) |folders| {
        if (try field(folders, "supported")) |supported| {
            if (supported != .bool) return error.InvalidCapabilities;
            output.workspace_folders = supported.bool;
        }
        if (try field(folders, "changeNotifications")) |changes| switch (changes) {
            .bool => output.workspace_changes = changes.bool,
            .string => |id| {
                try validText(id, 128);
                var registration: Registration = .{};
                @memcpy(registration.bytes[0..id.len], id);
                registration.len = @intCast(id.len);
                output.workspace_registration = registration;
                output.workspace_changes = true;
            },
            else => return error.InvalidCapabilities,
        };
    };
    return output;
}
pub const Initialize = struct {
    root_uri: ?[]const u8 = null,
    process_id: ?i32 = null,
    snippets: bool = false,
    workspace_support: bool = false,
    workspace_folders: ?[]const @import("workspace.zig").Folder = null,
    configuration_support: bool = false,
    completion_resolve: bool = false,
};
pub fn initialize(allocator: std.mem.Allocator, id: i32, options: Initialize, limits: codec.Limits) !codec.Packet {
    if (id <= 0 or (options.process_id != null and options.process_id.? < 0)) return error.InvalidIdentifier;
    if (options.root_uri) |uri| try validText(uri, 4096);
    if (options.workspace_folders) |folders| {
        if (!options.workspace_support or folders.len > 32) return error.InvalidWorkspace;
        for (folders) |folder| {
            try @import("file_uri.zig").validate(folder.uri);
            try validText(folder.name, 256);
        }
    }
    const item = .{ .snippetSupport = options.snippets, .insertTextModeSupport = .{ .valueSet = [_]u8{1} }, .documentationFormat = [_][]const u8{ "plaintext", "markdown" } };
    if (options.completion_resolve) return initializeItem(allocator, id, options, limits, .{ .snippetSupport = item.snippetSupport, .insertTextModeSupport = item.insertTextModeSupport, .documentationFormat = item.documentationFormat, .resolveSupport = .{ .properties = [_][]const u8{ "detail", "documentation" } } });
    return initializeItem(allocator, id, options, limits, item);
}
fn initializeItem(allocator: std.mem.Allocator, id: i32, options: Initialize, limits: codec.Limits, completion_item: anytype) !codec.Packet {
    const params = .{
        .processId = options.process_id,
        .rootUri = options.root_uri,
        .capabilities = .{
            .general = .{ .positionEncodings = [_][]const u8{"utf-16"} },
            .textDocument = .{
                .synchronization = .{ .dynamicRegistration = false, .willSave = false, .willSaveWaitUntil = false, .didSave = false },
                .completion = .{ .dynamicRegistration = false, .insertTextMode = 1, .completionItem = completion_item },
                .hover = .{ .dynamicRegistration = false, .contentFormat = [_][]const u8{ "plaintext", "markdown" } },
                .publishDiagnostics = .{ .versionSupport = true },
            },
        },
    };
    if (options.configuration_support and !options.workspace_support) return error.WorkspaceRequired;
    if (options.configuration_support) return codec.Packet.json(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = "initialize",
        .params = .{ .processId = params.processId, .rootUri = params.rootUri, .workspaceFolders = options.workspace_folders, .capabilities = .{ .general = params.capabilities.general, .textDocument = params.capabilities.textDocument, .workspace = .{ .workspaceFolders = true, .configuration = true, .didChangeConfiguration = .{ .dynamicRegistration = false } } } },
    }, limits);
    if (options.workspace_support) return codec.Packet.json(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = "initialize",
        .params = .{ .processId = params.processId, .rootUri = params.rootUri, .workspaceFolders = options.workspace_folders, .capabilities = .{ .general = params.capabilities.general, .textDocument = params.capabilities.textDocument, .workspace = .{ .workspaceFolders = true } } },
    }, limits);
    return codec.Packet.json(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = "initialize",
        .params = params,
    }, limits);
}
pub fn notification(allocator: std.mem.Allocator, method: []const u8, params: anytype, limits: codec.Limits) !codec.Packet {
    try validText(method, 256);
    return codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .method = method, .params = params }, limits);
}
pub fn cancel(allocator: std.mem.Allocator, id: i32, limits: codec.Limits) !codec.Packet {
    if (id <= 0) return error.InvalidIdentifier;
    return notification(allocator, "$/cancelRequest", .{ .id = id }, limits);
}
pub fn shutdownRequest(allocator: std.mem.Allocator, id: i32, limits: codec.Limits) !codec.Packet {
    if (id <= 0) return error.InvalidIdentifier;
    return codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = id, .method = "shutdown" }, limits);
}
pub fn exitNotification(allocator: std.mem.Allocator, limits: codec.Limits) !codec.Packet {
    return codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .method = "exit" }, limits);
}
pub const PreparationLimits = struct {
    framing: codec.Limits = .{},
    positions: positions.Limits = .{},
    bytes: usize = 16 * 1024 * 1024,
    work_bytes: usize = 16 * 1024 * 1024,
    edits: usize = 4096,
    pub fn validate(self: PreparationLimits) !void {
        try self.framing.validate();
        try self.positions.validate();
        if (self.bytes == 0 or self.bytes > 256 * 1024 * 1024 or self.work_bytes == 0 or self.work_bytes > 512 * 1024 * 1024 or self.edits == 0 or self.edits > 65536) return error.InvalidLimits;
    }
};
/// Explicit worker-prepared product. Source Reader is borrowed, never released
/// here. Host acceptance/owner commit is separate from successful encoding.
pub const PreparedSync = struct {
    packet: ?codec.Packet,
    map: ?*positions.Map,
    source_revision: u64,
    source_text_version: u64,
    server_version: i32,
    retained_bytes: usize,
    peak_bytes: usize,
    pub fn deinit(self: *PreparedSync) void {
        const map = self.map;
        const packet = self.packet;
        self.map = null;
        self.packet = null;
        if (map) |value| value.close() catch unreachable;
        if (packet) |value| {
            var owned = value;
            owned.deinit();
        }
    }
};
fn validText(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum) return error.InvalidIdentifier;
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidUtf8;
}
fn packetLimits(limits: PreparationLimits, used: usize) !codec.Limits {
    // Every generated decimal Content-Length header fits this explicit reserve.
    if (limits.bytes -| used <= 64) return error.PreparationCapacityExceeded;
    var result = limits.framing;
    result.body_bytes = @min(result.body_bytes, limits.bytes - used - 64);
    return result;
}
fn checkCancellation(limits: PreparationLimits) !void {
    if (limits.positions.cancellation) |cancelled| if (cancelled.requested.load(.acquire)) return error.Cancelled;
}
fn full(allocator: std.mem.Allocator, reader: d.Reader, uri: []const u8, language: ?[]const u8, version: i32, limits: PreparationLimits) !PreparedSync {
    try limits.validate();
    try validText(uri, 4096);
    if (language) |value| try validText(value, 128);
    if (version < 0) return error.InvalidVersion;
    const length = try reader.byteLength();
    if (length > limits.work_bytes / 4) return error.WorkCapacityExceeded;
    var map_limits = limits.positions;
    map_limits.bytes = @min(map_limits.bytes, limits.bytes);
    const map = try positions.Map.create(allocator, reader, map_limits);
    errdefer map.close() catch unreachable;
    const map_bytes = (try map.stats()).bytes;
    if (length > limits.bytes -| map_bytes) return error.PreparationCapacityExceeded;
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    _ = try reader.read(.{ .start = 0, .end = length }, bytes);
    try checkCancellation(limits);
    const framing = try packetLimits(limits, map_bytes + length);
    var packet = if (language) |value| try notification(allocator, "textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = value, .version = version, .text = bytes } }, framing) else try notification(allocator, "textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = .{.{ .text = bytes }} }, framing);
    errdefer packet.deinit();
    try checkCancellation(limits);
    const retained = map_bytes + packet.bytes.?.len;
    return .{ .packet = packet, .map = map, .source_revision = try reader.version(), .source_text_version = try reader.committedTextVersion(), .server_version = version, .retained_bytes = retained, .peak_bytes = retained + length };
}
pub fn prepareOpen(allocator: std.mem.Allocator, reader: d.Reader, uri: []const u8, language: []const u8, version: i32, limits: PreparationLimits) !PreparedSync {
    return full(allocator, reader, uri, language, version, limits);
}
pub fn prepareFullChange(allocator: std.mem.Allocator, reader: d.Reader, uri: []const u8, version: i32, limits: PreparationLimits) !PreparedSync {
    return full(allocator, reader, uri, null, version, limits);
}
const Change = struct { range: positions.Range, text: []const u8 };
/// Edits use original coordinates. Emitting them in reverse order makes those
/// coordinates valid for each successive LSP content change. Before/after byte
/// equality is verified on the worker before a product can be adopted.
pub fn prepareIncremental(allocator: std.mem.Allocator, before: d.Reader, before_map: *const positions.Map, after: d.Reader, uri: []const u8, version: i32, edits: []const d.Replacement, limits: PreparationLimits) !PreparedSync {
    try limits.validate();
    try validText(uri, 4096);
    if (version < 0) return error.InvalidVersion;
    if (edits.len == 0 or edits.len > limits.edits) return error.EditCapacityExceeded;
    if (!try before_map.matches(before)) return error.ForeignPositionMap;
    const old_length = try before.byteLength();
    const new_length = try after.byteLength();
    if (try after.committedTextVersion() <= try before.committedTextVersion()) return error.StaleRevision;
    const work = std.math.add(usize, old_length, std.math.mul(usize, new_length, 5) catch return error.WorkCapacityExceeded) catch return error.WorkCapacityExceeded;
    if (work > limits.work_bytes) return error.WorkCapacityExceeded;
    const old_bytes = (try before_map.stats()).bytes;
    var map_limits = limits.positions;
    map_limits.bytes = @min(map_limits.bytes, limits.bytes -| old_bytes);
    const map = try positions.Map.create(allocator, after, map_limits);
    errdefer map.close() catch unreachable;
    const map_bytes = (try map.stats()).bytes;
    const descriptors = std.math.mul(usize, edits.len, @sizeOf(Change)) catch return error.PreparationCapacityExceeded;
    const base = old_bytes + map_bytes;
    if (new_length > limits.bytes -| base or descriptors > limits.bytes -| (base + new_length)) return error.PreparationCapacityExceeded;
    const text = try allocator.alloc(u8, new_length);
    defer allocator.free(text);
    const changes = try allocator.alloc(Change, edits.len);
    defer allocator.free(changes);
    var old_end: usize = 0;
    var new_end: usize = 0;
    var previous: ?d.Range = null;
    for (edits, 0..) |edit, index| {
        try checkCancellation(limits);
        if (edit.range.start > edit.range.end or edit.range.end > old_length) return error.InvalidRange;
        _ = try before.utf16Offset(edit.range.start);
        _ = try before.utf16Offset(edit.range.end);
        if (previous) |value| if (edit.range.start <= value.start or edit.range.start < value.end or (edit.range.start == value.end and (edit.range.start == edit.range.end or value.start == value.end))) return error.OverlappingEdits;
        previous = edit.range;
        const unchanged = edit.range.start - old_end;
        if (unchanged > new_length -| new_end or edit.text.len > new_length -| (new_end + unchanged)) return error.ContentMismatch;
        if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
        new_end += try before.read(.{ .start = old_end, .end = edit.range.start }, text[new_end..][0..unchanged]);
        @memcpy(text[new_end..][0..edit.text.len], edit.text);
        new_end += edit.text.len;
        old_end = edit.range.end;
        changes[edits.len - index - 1] = .{ .range = try before_map.fromRange(edit.range), .text = edit.text };
    }
    if (old_length - old_end != new_length - new_end) return error.ContentMismatch;
    _ = try before.read(.{ .start = old_end, .end = old_length }, text[new_end..]);
    var cursor = try after.cursor(.{ .start = 0, .end = new_length });
    while (try cursor.next()) |segment| {
        try checkCancellation(limits);
        if (!std.mem.eql(u8, text[segment.start..][0..segment.bytes.len], segment.bytes)) return error.ContentMismatch;
    }
    const framing = try packetLimits(limits, base + new_length + descriptors);
    var packet = try notification(allocator, "textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = changes }, framing);
    errdefer packet.deinit();
    try checkCancellation(limits);
    const retained = map_bytes + packet.bytes.?.len;
    return .{ .packet = packet, .map = map, .source_revision = try after.version(), .source_text_version = try after.committedTextVersion(), .server_version = version, .retained_bytes = retained, .peak_bytes = old_bytes + retained + new_length + descriptors };
}

test "initialize advertises explicit UTF16 and snippet policy with strict server capabilities" {
    const a = std.testing.allocator;
    var packet = try initialize(a, 1, .{ .snippets = true }, .{});
    defer packet.deinit();
    var decoder = try codec.Decoder.init(a, .{});
    defer decoder.deinit();
    const message = try codec.Message.parse(a, (try decoder.push(packet.bytes.?)).body.?, .{});
    defer message.close() catch unreachable;
    const value = (try message.value()).request;
    try std.testing.expectEqualStrings("initialize", value.method);
    try std.testing.expect(value.params.?.object.get("capabilities").?.object.get("textDocument").?.object.get("completion").?.object.get("completionItem").?.object.get("snippetSupport").?.bool);
    try std.testing.expect(value.params.?.object.get("capabilities").?.object.get("textDocument").?.object.get("completion").?.object.get("completionItem").?.object.get("resolveSupport") == null);
    const response = try codec.Message.parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"positionEncoding\":\"utf-16\",\"textDocumentSync\":{\"openClose\":true,\"change\":2},\"completionProvider\":{},\"hoverProvider\":true}}}", .{});
    defer response.close() catch unreachable;
    try std.testing.expectEqual(Capabilities{ .sync = .incremental, .open_close = true, .completion = true, .hover = true }, try capabilities((try response.value()).response.result));
    const wrong = try codec.Message.parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"positionEncoding\":\"utf-8\"}}}", .{});
    defer wrong.close() catch unreachable;
    try std.testing.expectError(error.UnsupportedPositionEncoding, capabilities((try wrong.value()).response.result));
    const invalid = try codec.Message.parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"completionProvider\":{\"resolveProvider\":\"true\"}}}}", .{});
    defer invalid.close() catch unreachable;
    try std.testing.expectError(error.InvalidCapabilities, capabilities((try invalid.value()).response.result));
}
fn syncCase(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "a😀\r\nxyz", .{});
    defer document.close() catch unreachable;
    const first = try document.snapshot();
    defer first.close() catch unreachable;
    const before = try first.borrowReader();
    defer before.release() catch unreachable;
    var open = try prepareOpen(allocator, before, "file:///fixture.zig", "zig", 1, .{});
    defer open.deinit();
    const edits = [_]d.Replacement{ .{ .range = .{ .start = 1, .end = 5 }, .text = "中" }, .{ .range = .{ .start = 8, .end = 9 }, .text = "Z" } };
    try document.replaceMany(try document.version(), &edits);
    const second = try document.snapshot();
    defer second.close() catch unreachable;
    const after = try second.borrowReader();
    defer after.release() catch unreachable;
    var change = try prepareIncremental(allocator, before, open.map.?, after, "file:///fixture.zig", 2, &edits, .{});
    defer change.deinit();
    var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 4096 });
    defer decoder.deinit();
    const message = try codec.Message.parse(allocator, (try decoder.push(change.packet.?.bytes.?)).body.?, .{});
    defer message.close() catch unreachable;
    const changes = (try message.value()).notification.params.?.object.get("contentChanges").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqualStrings("Z", changes[0].object.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 1), changes[0].object.get("range").?.object.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 3), changes[1].object.get("range").?.object.get("end").?.object.get("character").?.integer);
    if (prepareIncremental(allocator, before, open.map.?, after, "file:///fixture.zig", 2, &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "bad" }}, .{})) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.MissingContentMismatch;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.ContentMismatch, err);
    }
    try std.testing.expectError(error.WorkCapacityExceeded, prepareIncremental(allocator, before, open.map.?, after, "file:///fixture.zig", 2, &edits, .{ .work_bytes = 1 }));
    var full_change = try prepareFullChange(allocator, after, "file:///fixture.zig", 2, .{});
    defer full_change.deinit();
    try std.testing.expectEqual(try after.committedTextVersion(), full_change.source_text_version);
}
test "worker sync products verify original edits and reverse incremental ranges transactionally" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, syncCase, .{});
}
