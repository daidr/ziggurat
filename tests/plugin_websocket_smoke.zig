const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const runtime = @import("ziggurat_page_runtime");
const websocket_plugin = @import("ziggurat_plugin_websocket");
const Watchdog = @import("watchdog.zig").Watchdog;

const html = "<!doctype html><meta charset=utf-8><title>WebSocket plugin</title><script>" ++ @embedFile("plugin_websocket_page") ++ "</script>";

/// An echo server for one connection; it checks the opening handshake.
const Server = struct {
    server: std.Io.net.Server,
    failure: ?anyerror = null,

    fn serve(self: *Server) void {
        self.one() catch |err| {
            self.failure = err;
        };
    }

    fn one(self: *Server) !void {
        const connection = try self.server.accept(zio.io());
        defer connection.close(zio.io());
        var receive_buffer: [512 * 1024]u8 = undefined;
        var send_buffer: [4096]u8 = undefined;
        var reader = connection.reader(zio.io(), &receive_buffer);
        var writer = connection.writer(zio.io(), &send_buffer);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try http.receiveHead();
        if (!std.mem.eql(u8, request.head.target, "/live?room=1")) return error.WrongTarget;
        const key = switch (request.upgradeRequested()) {
            .websocket => |value| value orelse return error.MissingKey,
            else => return error.NotUpgrade,
        };
        var authorized = false;
        var origin = false;
        var offered = false;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) authorized = std.mem.eql(u8, header.value, "Bearer token");
            if (std.ascii.eqlIgnoreCase(header.name, "origin")) origin = std.mem.eql(u8, header.value, "https://app.example");
            if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) offered = std.mem.indexOf(u8, header.value, "chat.v2") != null;
        }
        if (!authorized or !origin or !offered) return error.MissingHeaders;
        var socket = try request.respondWebSocket(.{ .key = key, .extra_headers = &.{.{ .name = "sec-websocket-protocol", .value = "chat.v2" }} });
        try socket.flush();
        while (true) {
            const header = try socket.input.takeArray(2);
            const opcode: u4 = @truncate(header[0]);
            const len: usize = switch (header[1] & 0x7F) {
                126 => try socket.input.takeInt(u16, .big),
                127 => @intCast(try socket.input.takeInt(u64, .big)),
                else => |value| value,
            };
            const mask = (try socket.input.takeArray(4)).*;
            const data = try socket.input.take(len);
            for (data, 0..) |*byte, index| byte.* ^= mask[index % 4];
            switch (opcode) {
                0x1 => try socket.writeMessage(data, .text),
                0x2 => try socket.writeMessage(data, .binary),
                0x8 => {
                    if (std.mem.readInt(u16, data[0..2], .big) != 4000 or !std.mem.eql(u8, data[2..], "done")) return error.WrongClose;
                    try socket.writeMessage(&.{ 0x0F, 0xA0, 'b', 'y', 'e' }, .connection_close);
                    return;
                },
                else => return error.UnexpectedFrame,
            }
        }
    }
};

const State = struct {
    app: *z.App,
    port: u16,
    view: web.View = undefined,
    host: runtime.Host = undefined,
    done: bool = false,
    failure: ?anyerror = null,

    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("websocket plugin smoke: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn send(context: *anyopaque, bytes: []const u8) !void {
        const self: *State = @ptrCast(@alignCast(context));
        try self.view.post(bytes);
    }
    fn event(context: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (value) {
            .message => |text| {
                if (self.host.receive(text) == .handled) return;
                self.message(text) catch |err| self.fail(err);
            },
            .failed => self.fail(error.WebViewFailed),
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
    }
    fn message(self: *State, text: []const u8) !void {
        if (std.mem.startsWith(u8, text, "pw-failed:")) {
            std.debug.print("{s}\n", .{text});
            return error.PageFailed;
        }
        if (std.mem.eql(u8, text, "pw-ready")) {
            var buffer: [32]u8 = undefined;
            return self.view.post(try std.fmt.bufPrint(&buffer, "pw-host:port:{d}", .{self.port}));
        }
        if (std.mem.eql(u8, text, "pw-done")) {
            self.done = true;
            self.app.quit();
            return;
        }
        return error.UnexpectedMessage;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: Server = .{ .server = try address.listen(zio.io(), .{ .reuse_address = true }) };
    defer server.server.deinit(zio.io());
    const serving = try std.Thread.spawn(.{}, Server.serve, .{&server});
    // A failed page leaves the server waiting for its connection.
    var served = false;
    defer if (!served) {
        (server.server.socket.address.connect(zio.io(), .{ .mode = .stream }) catch unreachable).close(zio.io());
        serving.join();
    };

    const app = try z.App.init(allocator);
    defer app.deinit();
    var plugin: websocket_plugin.Plugin = undefined;
    try plugin.init(allocator, .{ .post = .app(app), .connections = 2 });
    var state: State = .{ .app = app, .port = server.server.socket.address.getPort() };
    const window = try app.createWindow(.{ .title = "WebSocket plugin smoke" });
    var controls: runtime.WindowControls = .{ .window = window };
    state.host = .init(allocator, .{ .transport = .{ .context = &state, .send = State.send }, .controls = controls.controls() });
    try state.host.use(plugin.plugin());
    state.view = web.View.init(allocator, &state, State.event);

    var profile: []u8 = &.{};
    defer allocator.free(profile);
    if (builtin.os.tag == .windows) {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "WebSocketPluginSmoke" });
        try state.view.attach(window, .{ .html = html, .user_data_folder = profile });
    } else {
        try state.view.attach(window, .{ .html = html, .storage = .ephemeral });
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    state.host.detach();
    plugin.deinit();
    try std.testing.expect(!watchdog.expired);
    if (state.failure) |err| return err;
    try std.testing.expect(state.done);
    serving.join();
    served = true;
    if (server.failure) |err| return err;
    std.debug.print("websocket plugin WebView smoke passed: handshake headers and subprotocol, text echo, 300 KB binary echo in pieces, bufferedAmount, clean close, refused connection\n", .{});
}
