const std = @import("std");
const zio = @import("ziggurat_io");
const protocol = @import("ziggurat_language_protocol");
const codec = protocol.codec;
const allocator = std.heap.page_allocator;
fn emit(value: anytype) !void {
    var packet = try codec.Packet.json(allocator, value, .{});
    defer packet.deinit();
    const bytes = packet.bytes.?;
    // Fragment frames deliberately; no assumptions about pipe message sizes.
    try std.Io.File.stdout().writeStreamingAll(zio.io(), bytes[0..@min(7, bytes.len)]);
    try std.Io.File.stdout().writeStreamingAll(zio.io(), bytes[@min(7, bytes.len)..]);
}
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.ExpectedObject;
    return value.object.get(name) orelse error.MissingField;
}
fn eq(value: std.json.Value, expected: []const u8) !void {
    if (value != .string or !std.mem.eql(u8, value.string, expected)) return error.InvalidRequest;
}
pub fn main(init: std.process.Init.Minimal) !void {
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--workspace")) return workspaceServer();
    if (args.len == 2 and std.mem.eql(u8, args[1], "--configuration")) return configurationServer();
    if (args.len == 2 and std.mem.eql(u8, args[1], "--resolve")) return resolveServer();
    var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
    defer decoder.deinit();
    var initialized = false;
    var version: i32 = 0;
    var pending: ?i32 = null;
    var chunk: [113]u8 = undefined;
    while (true) {
        const count = try std.Io.File.stdin().readStreaming(zio.io(), &.{&chunk});
        if (count == 0) return error.UnexpectedEof;
        var offset: usize = 0;
        while (offset < count) {
            const progress = try decoder.push(chunk[offset..count]);
            offset += progress.consumed;
            const body = progress.body orelse continue;
            const message = try codec.Message.parse(allocator, body, .{});
            defer message.close() catch unreachable;
            switch (try message.value()) {
                .request => |request| {
                    if (request.id != .number) return error.InvalidIdentifier;
                    const id = request.id.number;
                    const params = request.params orelse return error.MissingParams;
                    if (std.mem.eql(u8, request.method, "initialize")) {
                        const caps = try field(params, "capabilities");
                        const encodings = try field(try field(caps, "general"), "positionEncodings");
                        if (encodings != .array or encodings.array.items.len != 1) return error.InvalidEncoding;
                        try eq(encodings.array.items[0], "utf-16");
                        try emit(.{ .jsonrpc = "2.0", .id = id, .result = .{ .capabilities = .{ .positionEncoding = "utf-16", .textDocumentSync = .{ .openClose = true, .change = 2 }, .completionProvider = struct {}{}, .hoverProvider = true } } });
                    } else {
                        if (!initialized or version == 0) return error.NotInitialized;
                        try eq(try field(try field(params, "textDocument"), "uri"), "file:///fixture.zig");
                        const position = try field(params, "position");
                        const character = try field(position, "character");
                        if (std.mem.eql(u8, request.method, "textDocument/completion")) {
                            if (character.integer == 1) {
                                pending = id;
                            } else {
                                if (character.integer != 3) return error.NotUtf16;
                                try emit(.{ .jsonrpc = "2.0", .id = id, .result = .{ .isIncomplete = false, .items = .{.{ .label = "owned completion", .insertText = "${1:done}$0", .insertTextFormat = 2 }} } });
                            }
                        } else if (std.mem.eql(u8, request.method, "textDocument/hover")) {
                            try emit(.{ .jsonrpc = "2.0", .id = id, .result = .{ .contents = .{ .kind = "markdown", .value = "worker hover" } } });
                        } else return error.UnexpectedMethod;
                    }
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "exit")) return;
                    if (std.mem.eql(u8, notification.method, "initialized")) {
                        initialized = true;
                        continue;
                    }
                    const params = notification.params orelse return error.MissingParams;
                    if (std.mem.eql(u8, notification.method, "$/cancelRequest")) {
                        const id = (try field(params, "id")).integer;
                        if (pending == null or pending.? != id) return error.UnknownCancellation;
                        try emit(.{ .jsonrpc = "2.0", .id = id, .result = .{.{ .label = "late cancelled", .insertText = "late" }} });
                        pending = null;
                    } else if (std.mem.eql(u8, notification.method, "textDocument/didOpen") or std.mem.eql(u8, notification.method, "textDocument/didChange")) {
                        const document = try field(params, "textDocument");
                        try eq(try field(document, "uri"), "file:///fixture.zig");
                        const current = (try field(document, "version")).integer;
                        if (current <= version) return error.NonmonotonicVersion;
                        if (std.mem.eql(u8, notification.method, "textDocument/didOpen")) {
                            const text = try field(document, "text");
                            if (text != .string or (!std.mem.eql(u8, text.string, "a😀\r\nxyz") and !std.mem.eql(u8, text.string, "a中\r\nxyz"))) return error.WrongText;
                        } else {
                            const changes = try field(params, "contentChanges");
                            if (changes != .array or changes.array.items.len != 1) return error.NotIncremental;
                            const change = changes.array.items[0];
                            try eq(try field(change, "text"), "中");
                            const range = try field(change, "range");
                            if ((try field(try field(range, "start"), "character")).integer != 1 or (try field(try field(range, "end"), "character")).integer != 3) return error.NotUtf16;
                        }
                        version = @intCast(current);
                        try emit(.{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = "file:///fixture.zig", .version = version, .diagnostics = .{.{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 1 } }, .message = "server versioned", .severity = 2 }} } });
                    } else return error.UnexpectedNotification;
                },
                else => return error.UnexpectedResponse,
            }
        }
    }
}

fn resolveServer() !void {
    var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
    defer decoder.deinit();
    var chunk: [83]u8 = undefined;
    var resolved: usize = 0;
    while (true) {
        const count = try std.Io.File.stdin().readStreaming(zio.io(), &.{&chunk});
        if (count == 0) return error.UnexpectedEof;
        var offset: usize = 0;
        while (offset < count) {
            const progress = try decoder.push(chunk[offset..count]);
            offset += progress.consumed;
            const message = try codec.Message.parseLossless(allocator, progress.body orelse continue, .{});
            defer message.close() catch unreachable;
            switch (try message.value()) {
                .request => |request| {
                    if (request.id != .number) return error.InvalidIdentifier;
                    if (std.mem.eql(u8, request.method, "initialize")) {
                        const item = try field(try field(try field(request.params.?, "capabilities"), "textDocument"), "completion");
                        const properties = try field(try field(try field(item, "completionItem"), "resolveSupport"), "properties");
                        if (properties != .array or properties.array.items.len != 2) return error.FalseAdvertisement;
                        try eq(properties.array.items[0], "detail");
                        try eq(properties.array.items[1], "documentation");
                        try emit(.{ .jsonrpc = "2.0", .id = request.id.number, .result = .{ .capabilities = .{ .positionEncoding = "utf-16", .textDocumentSync = .{ .openClose = true, .change = 2 }, .completionProvider = .{ .resolveProvider = true } } } });
                    } else if (std.mem.eql(u8, request.method, "textDocument/completion")) {
                        try emit(.{ .jsonrpc = "2.0", .id = request.id.number, .result = .{ .{ .label = "a", .insertText = "${1:item}-$1$0", .insertTextFormat = 2, .data = protocol.configuration.Raw{ .bytes = "{\"huge\":123456789012345678901234567890}" }, .unknown = .{ true, "opaque" } }, .{ .label = "b" } } });
                    } else if (std.mem.eql(u8, request.method, "completionItem/resolve")) {
                        const params = request.params.?;
                        try eq(try field(params, "label"), "a");
                        try eq(try field(params, "insertText"), "${1:item}-$1$0");
                        const number = try field(try field(params, "data"), "huge");
                        if (number != .number_string or !std.mem.eql(u8, number.number_string, "123456789012345678901234567890")) return error.RoundedData;
                        const unknown = try field(params, "unknown");
                        if (unknown != .array or unknown.array.items.len != 2 or !unknown.array.items[0].bool) return error.LostOpaqueFields;
                        resolved += 1;
                        if (resolved == 6) try emit(.{ .jsonrpc = "2.0", .id = request.id.number, .result = .{ .label = "a", .insertText = "unapproved edit" } }) else try emit(.{ .jsonrpc = "2.0", .id = request.id.number, .result = .{ .label = "a", .detail = "resolved type", .documentation = .{ .kind = "markdown", .value = "owned documentation" } } });
                    } else return error.UnexpectedMethod;
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "exit")) {
                        if (resolved != 8) return error.IncompleteScenario;
                        return;
                    }
                    if (!std.mem.eql(u8, notification.method, "initialized") and !std.mem.eql(u8, notification.method, "textDocument/didOpen") and !std.mem.eql(u8, notification.method, "textDocument/didChange")) return error.UnexpectedNotification;
                },
                else => return error.UnexpectedResponse,
            }
        }
    }
}

fn workspaceServer() !void {
    var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
    defer decoder.deinit();
    var initialized = false;
    var changed = false;
    var replies: usize = 0;
    var pending = false;
    var chunk: [83]u8 = undefined;
    while (true) {
        const count = try std.Io.File.stdin().readStreaming(zio.io(), &.{&chunk});
        if (count == 0) return error.UnexpectedEof;
        var offset: usize = 0;
        while (offset < count) {
            const progress = try decoder.push(chunk[offset..count]);
            offset += progress.consumed;
            const message = try codec.Message.parse(allocator, progress.body orelse continue, .{});
            defer message.close() catch unreachable;
            switch (try message.value()) {
                .request => |request| {
                    if (!std.mem.eql(u8, request.method, "initialize") or initialized) return error.InvalidRequest;
                    const params = request.params orelse return error.MissingParams;
                    try eq(try field(params, "rootUri"), "file:///a");
                    const caps = try field(params, "capabilities");
                    const workspace = try field(caps, "workspace");
                    if (!(try field(workspace, "workspaceFolders")).bool or workspace.object.get("configuration") != null or workspace.object.get("applyEdit") != null) return error.FalseAdvertisement;
                    const folders = try field(params, "workspaceFolders");
                    if (folders != .array or folders.array.items.len != 2) return error.InvalidFolders;
                    try eq(try field(folders.array.items[0], "uri"), "file:///a");
                    const other = try field(folders.array.items[1], "uri");
                    changed = other == .string and std.mem.eql(u8, other.string, "file:///c");
                    if (!changed) try eq(other, "file:///b");
                    try emit(.{ .jsonrpc = "2.0", .id = request.id.number, .result = .{ .capabilities = .{ .positionEncoding = "utf-16", .workspace = .{ .workspaceFolders = .{ .supported = true, .changeNotifications = "fixture-workspace-registration" } } } } });
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "exit")) {
                        if (replies == 0 or pending) return error.MissingWorkspaceReply;
                        return;
                    }
                    if (std.mem.eql(u8, notification.method, "initialized")) {
                        initialized = true;
                    } else if (std.mem.eql(u8, notification.method, "workspace/didChangeWorkspaceFolders")) {
                        if (!initialized or changed or pending or replies == 0) return error.InvalidPhase;
                        const event = try field(notification.params.?, "event");
                        const added = try field(event, "added");
                        const removed = try field(event, "removed");
                        if (added.array.items.len != 1 or removed.array.items.len != 1) return error.InvalidChange;
                        try eq(try field(added.array.items[0], "uri"), "file:///c");
                        try eq(try field(removed.array.items[0], "uri"), "file:///b");
                        changed = true;
                    } else return error.UnexpectedNotification;
                    pending = true;
                    try emit(.{ .jsonrpc = "2.0", .id = "server-folders", .method = "workspace/workspaceFolders" });
                },
                .response => |response| {
                    if (!initialized or !pending) return error.UnexpectedResponse;
                    if (response.id != .text or !std.mem.eql(u8, response.id.text, "server-folders")) return error.InvalidIdentifier;
                    const folders = response.result;
                    if (folders != .array or folders.array.items.len != 2) return error.InvalidFolders;
                    try eq(try field(folders.array.items[0], "uri"), "file:///a");
                    try eq(try field(folders.array.items[1], "uri"), if (changed) "file:///c" else "file:///b");
                    replies += 1;
                    pending = false;
                },
                else => return error.UnexpectedResponse,
            }
        }
    }
}

fn configurationQuery() !void {
    try emit(.{ .jsonrpc = "2.0", .id = "configuration-query", .method = "workspace/configuration", .params = .{ .items = .{ .{ .section = "language" }, .{ .scopeUri = "file:///a/doc", .section = "language" }, .{ .scopeUri = "file:///a/other", .section = "language" }, .{ .section = "" }, struct {}{} } } });
}
fn configurationDiagnostic(version: i32, text: []const u8) !void {
    try emit(.{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = "file:///a/doc", .version = version, .diagnostics = .{.{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .message = text }} } });
}
fn configurationServer() !void {
    var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
    defer decoder.deinit();
    var initialized = false;
    var config_version: i64 = 0;
    var document_version: i32 = 0;
    var pending = false;
    var changed = false;
    var rejected = false;
    var error_pending = false;
    var chunk: [71]u8 = undefined;
    while (true) {
        const count = try std.Io.File.stdin().readStreaming(zio.io(), &.{&chunk});
        if (count == 0) return error.UnexpectedEof;
        var offset: usize = 0;
        while (offset < count) {
            const progress = try decoder.push(chunk[offset..count]);
            offset += progress.consumed;
            const message = try codec.Message.parse(allocator, progress.body orelse continue, .{});
            defer message.close() catch unreachable;
            switch (try message.value()) {
                .request => |request| {
                    if (!std.mem.eql(u8, request.method, "initialize") or initialized) return error.UnexpectedRequest;
                    const workspace = try field(try field(request.params.?, "capabilities"), "workspace");
                    if (!(try field(workspace, "configuration")).bool or (try field(try field(workspace, "didChangeConfiguration"), "dynamicRegistration")).bool) return error.FalseAdvertisement;
                    try emit(.{ .jsonrpc = "2.0", .id = request.id.number, .result = .{ .capabilities = .{ .positionEncoding = "utf-16", .textDocumentSync = .{ .openClose = true, .change = 2 }, .hoverProvider = true } } });
                },
                .response => |response| {
                    if (!pending or response.id != .text or !std.mem.eql(u8, response.id.text, "configuration-query")) return error.UnexpectedResponse;
                    const items = response.result;
                    if (items != .array or items.array.items.len != 5) return error.InvalidConfiguration;
                    const values = items.array.items;
                    if (values[0] != .integer or (values[0].integer != 1 and values[0].integer != 2)) return error.InvalidConfiguration;
                    if (changed and values[0].integer != 2) return error.StaleConfiguration;
                    if (values[1] != .array or values[1].array.items.len != 2 or values[1].array.items[0].integer != 3 or values[1].array.items[1].integer != 4 or values[2] != .null or values[3] != .bool or values[3].bool or values[4] != .null) return error.ScopeOrDefaultMismatch;
                    config_version = values[0].integer;
                    pending = false;
                    if (config_version == 1 and !changed) {
                        pending = true;
                        error_pending = true;
                        try emit(.{ .jsonrpc = "2.0", .id = "quota-query", .method = "workspace/configuration", .params = .{ .items = .{ .{ .section = "large" }, .{ .section = "large" } } } });
                    }
                },
                .failure => |failure| {
                    if (!pending or !error_pending or rejected or failure.id != .text or !std.mem.eql(u8, failure.id.text, "quota-query") or failure.code != -32603) return error.UnexpectedResponse;
                    pending = false;
                    error_pending = false;
                    rejected = true;
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "exit")) {
                        if (pending or document_version == 0 or config_version == 0 or (changed and !rejected)) return error.IncompleteScenario;
                        return;
                    }
                    if (std.mem.eql(u8, notification.method, "initialized")) {
                        initialized = true;
                        pending = true;
                        try configurationQuery();
                    } else if (std.mem.eql(u8, notification.method, "workspace/didChangeConfiguration")) {
                        if (!initialized or pending or config_version != 1 or document_version != 1) return error.InvalidPhase;
                        const settings = try field(notification.params.?, "settings");
                        if ((try field(settings, "version")).integer != 2) return error.InvalidConfiguration;
                        changed = true;
                        pending = true;
                        // This version alone cannot identify its configuration.
                        try configurationDiagnostic(document_version, "old configuration");
                        try configurationQuery();
                    } else if (std.mem.eql(u8, notification.method, "textDocument/didOpen") or std.mem.eql(u8, notification.method, "textDocument/didChange")) {
                        if (!initialized or pending or config_version == 0) return error.InvalidPhase;
                        const document = try field(notification.params.?, "textDocument");
                        try eq(try field(document, "uri"), "file:///a/doc");
                        const next = (try field(document, "version")).integer;
                        if (next <= document_version or (changed and next <= 1)) return error.StaleVersion;
                        document_version = @intCast(next);
                        try configurationDiagnostic(document_version, if (config_version == 1) "configuration 1" else "configuration 2");
                    } else return error.UnexpectedNotification;
                },
            }
        }
    }
}
