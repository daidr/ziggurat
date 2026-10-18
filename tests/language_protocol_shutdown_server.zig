const std = @import("std");
const protocol = @import("ziggurat_language_protocol");
const codec = protocol.codec;
const allocator = std.heap.page_allocator;

fn emit(value: anytype) !void {
    var packet = try codec.Packet.json(allocator, value, .{});
    defer packet.deinit();
    const bytes = packet.bytes.?;
    try std.fs.File.stdout().writeAll(bytes[0..@min(7, bytes.len)]);
    try std.fs.File.stdout().writeAll(bytes[@min(7, bytes.len)..]);
}
pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedMode;
    const silent = std.mem.eql(u8, args[1], "silent");
    const remote_error = std.mem.eql(u8, args[1], "remote_error");
    var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
    defer decoder.deinit();
    var initialized = false;
    var shutdown_id: ?i32 = null;
    var replied = false;
    var chunk: [83]u8 = undefined;
    while (true) {
        const count = try std.fs.File.stdin().read(&chunk);
        if (count == 0) return error.UnexpectedEof;
        var offset: usize = 0;
        while (offset < count) {
            const progress = try decoder.push(chunk[offset..count]);
            offset += progress.consumed;
            const bytes = progress.body orelse continue;
            const message = try codec.Message.parse(allocator, bytes, .{});
            defer message.close() catch unreachable;
            switch (try message.value()) {
                .request => |request| {
                    if (request.id != .number or shutdown_id != null) return error.InvalidRequestOrder;
                    if (std.mem.eql(u8, request.method, "initialize")) {
                        if (initialized or request.params == null) return error.InvalidInitialize;
                        try emit(.{ .jsonrpc = "2.0", .id = request.id.number, .result = .{ .capabilities = .{ .positionEncoding = "utf-16", .textDocumentSync = .{ .openClose = true, .change = 2 }, .workspace = .{ .workspaceFolders = .{ .supported = true, .changeNotifications = true } } } } });
                    } else if (std.mem.eql(u8, request.method, "shutdown")) {
                        if (!initialized or request.params != null) return error.InvalidShutdown;
                        shutdown_id = request.id.number;
                        try emit(.{ .jsonrpc = "2.0", .method = "fixture/shutdownSeen" });
                        if (!silent) try emit(.{ .jsonrpc = "2.0", .id = "closing/pull", .method = "workspace/configuration", .params = .{ .items = .{.{ .section = "close" }} } });
                    } else return error.UnexpectedRequest;
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "exit")) {
                        if (shutdown_id == null or !replied or notification.params != null) return error.PrematureExit;
                        return;
                    }
                    if (shutdown_id != null) return error.NotificationAfterShutdown;
                    if (!std.mem.eql(u8, notification.method, "initialized") or initialized) return error.UnexpectedNotification;
                    initialized = true;
                },
                .response => |response| {
                    if (shutdown_id == null or silent or replied or response.id != .text or !std.mem.eql(u8, response.id.text, "closing/pull")) return error.UnexpectedResponse;
                    if (response.result != .array or response.result.array.items.len != 1 or response.result.array.items[0] != .integer or response.result.array.items[0].integer != 7) return error.WrongConfiguration;
                    if (remote_error) {
                        try emit(.{ .jsonrpc = "2.0", .id = shutdown_id.?, .@"error" = .{ .code = -32001, .message = "cleanup failure" } });
                    } else try emit(.{ .jsonrpc = "2.0", .id = shutdown_id.?, .result = null });
                    replied = true;
                },
                else => return error.UnexpectedResponse,
            }
        }
    }
}
