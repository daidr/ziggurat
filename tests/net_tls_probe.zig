//! Real TLS check for `ziggurat_net` against a loopback peer that a script
//! starts with a disposable certificate: HTTPS fetch, a WSS echo with a
//! message larger than one TLS record, and certificate rejection.
const std = @import("std");
const zio = @import("ziggurat_io");
const net = @import("ziggurat_net");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("leak");
    const allocator = gpa.allocator();
    var args = try init.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.Usage, 10);
    const trusted = args.next() orelse return error.Usage;
    const untrusted = args.next() orelse return error.Usage;

    var client: std.http.Client = .{ .allocator = allocator, .io = zio.io() };
    defer client.deinit();
    try client.ca_bundle.addCertsFromFilePathAbsolute(allocator, zio.io(), std.Io.Clock.real.now(zio.io()), trusted);
    // A set clock tells the client its bundle is ready; it will not rescan.
    client.now = std.Io.Clock.real.now(zio.io());
    var url_buffer: [64]u8 = undefined;

    var response = try net.fetch(allocator, &client, .{ .url = try std.fmt.bufPrint(&url_buffer, "https://localhost:{d}/", .{port}) }, .{}, null);
    defer response.deinit(allocator);
    if (response.head.status != .ok or response.body.len != 100_000) return error.UnexpectedResponse;

    const socket = try net.WebSocket.connect(allocator, &client, try std.fmt.bufPrint(&url_buffer, "wss://localhost:{d}/echo", .{port}), .{}, null);
    defer socket.deinit();
    const large = try allocator.alloc(u8, 100_000);
    defer allocator.free(large);
    for (large, 0..) |*byte, index| byte.* = @truncate(index *% 7);
    try socket.send(.text, "over tls");
    try socket.send(.binary, large);
    const Echo = struct {
        socket: *net.WebSocket,
        expected: []const u8,
        count: usize = 0,
        fn on(context: ?*anyopaque, message: net.websocket.Message) net.websocket.Flow {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
            const ok = switch (self.count) {
                1 => message.kind == .text and std.mem.eql(u8, message.bytes, "over tls"),
                2 => message.kind == .binary and std.mem.eql(u8, message.bytes, self.expected),
                else => false,
            };
            if (!ok) @panic("unexpected echo");
            if (self.count == 2) self.socket.close(net.websocket.close_code.normal, "done") catch unreachable;
            return .proceed;
        }
    };
    var echo: Echo = .{ .socket = socket, .expected = large };
    const closed = try socket.run(.{ .context = &echo, .on_message = Echo.on });
    if (echo.count != 2 or closed.remote or closed.code != 1000 or !std.mem.eql(u8, closed.reason, "done")) return error.UnexpectedClose;

    var other: std.http.Client = .{ .allocator = allocator, .io = zio.io() };
    defer other.deinit();
    try other.ca_bundle.addCertsFromFilePathAbsolute(allocator, zio.io(), std.Io.Clock.real.now(zio.io()), untrusted);
    other.now = std.Io.Clock.real.now(zio.io());
    if (net.fetch(allocator, &other, .{ .url = try std.fmt.bufPrint(&url_buffer, "https://localhost:{d}/", .{port}) }, .{}, null)) |unexpected| {
        var copy = unexpected;
        copy.deinit(allocator);
        return error.UntrustedCertificateAccepted;
    } else |err| if (err != error.TlsFailed) return err;
    std.debug.print("net TLS probe passed\n", .{});
}
