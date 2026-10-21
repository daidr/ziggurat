const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const net = @import("ziggurat_net");
const runtime = @import("ziggurat_page_runtime");
const fetch_plugin = @import("ziggurat_plugin_fetch");
const Watchdog = @import("watchdog.zig").Watchdog;
const TestServer = net.fetch_api.TestServer;

const html = "<!doctype html><meta charset=utf-8><title>Fetch plugin</title><script>" ++ @embedFile("plugin_fetch_page") ++ "</script>";
const big_bytes = 3_000_000;
/// json, post, upload, redirect (two), manual, stream, big, stall.
const connections = 9;

/// What the page has read, which lets the server write on.
var parts: std.Thread.Semaphore = .{};

fn serve(server: *TestServer, request: *std.http.Server.Request) anyerror!void {
    const target = request.head.target;
    if (std.mem.eql(u8, target, "/json")) {
        var seen: [256]u8 = undefined;
        var origin: []const u8 = "";
        var agent: []const u8 = "";
        var agents: usize = 0;
        var iterator = request.iterateHeaders();
        while (iterator.next()) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, "origin")) origin = item.value;
            if (std.ascii.eqlIgnoreCase(item.name, "user-agent")) {
                agent = item.value;
                agents += 1;
            }
        }
        if (agents > 1) agent = "repeated";
        return request.respond("{\"items\":[1,2,3]}", .{ .keep_alive = false, .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-seen", .value = try std.fmt.bufPrint(&seen, "{s} {s}", .{ origin, agent }) },
            .{ .name = "set-cookie", .value = "session=1" },
        } });
    }
    if (std.mem.eql(u8, target, "/echo")) {
        var buffer: [64]u8 = undefined;
        const body = try (try request.readerExpectContinue(&buffer)).allocRemaining(std.heap.page_allocator, .limited(1024 * 1024));
        defer std.heap.page_allocator.free(body);
        return request.respond(body, .{ .status = .created, .keep_alive = false });
    }
    if (std.mem.eql(u8, target, "/hop")) {
        return request.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = "/json" }} });
    }
    var buffer: [4096]u8 = undefined;
    if (std.mem.eql(u8, target, "/stream")) {
        var writer = try request.respondStreaming(&buffer, .{ .respond_options = .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} } });
        for ([_][]const u8{ "one ", "two ", "three " }) |part| {
            try writer.writer.writeAll(part);
            try writer.writer.flush();
            try writer.flush();
            try parts.timedWait(10 * std.time.ns_per_s);
        }
        return writer.end();
    }
    if (std.mem.eql(u8, target, "/big")) {
        var writer = try request.respondStreaming(&buffer, .{ .content_length = big_bytes, .respond_options = .{ .keep_alive = false } });
        var block: [65536]u8 = undefined;
        var offset: usize = 0;
        while (offset < big_bytes) {
            const n = @min(block.len, big_bytes - offset);
            for (block[0..n], offset..) |*byte, index| byte.* = @intCast((index * 31) % 251);
            try writer.writer.writeAll(block[0..n]);
            offset += n;
        }
        return writer.end();
    }
    // The stalled request: a head and a little body, then nothing until done.
    var writer = try request.respondStreaming(&buffer, .{ .content_length = 100, .respond_options = .{ .keep_alive = false } });
    try writer.writer.writeAll("partial");
    try writer.writer.flush();
    try writer.flush();
    server.release.wait();
}

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    server: *TestServer,
    window: z.Window = undefined,
    view: web.View = undefined,
    controls: runtime.WindowControls = undefined,
    host: runtime.Host = undefined,
    parts: usize = 0,
    done: bool = false,
    failure: ?anyerror = null,

    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("fetch plugin smoke: {s}\n", .{@errorName(err)});
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
        if (std.mem.startsWith(u8, text, "pf-failed:")) {
            std.debug.print("{s}\n", .{text});
            return error.PageFailed;
        }
        if (std.mem.eql(u8, text, "pf-ready")) {
            var buffer: [32]u8 = undefined;
            return self.view.post(try std.fmt.bufPrint(&buffer, "pf-host:port:{d}", .{self.server.port()}));
        }
        if (std.mem.startsWith(u8, text, "pf-part:")) {
            self.parts += 1;
            parts.post();
            return;
        }
        if (std.mem.eql(u8, text, "pf-done")) {
            self.done = true;
            self.server.release.set();
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
    var server = try TestServer.init(serve);
    defer server.deinit();
    const serving = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, connections });
    // A failed page leaves the server waiting: each extra connection ends one wait.
    defer {
        server.release.set();
        parts.post();
        parts.post();
        parts.post();
        const address = std.net.Address.parseIp("127.0.0.1", server.port()) catch unreachable;
        for (0..connections) |_| (std.net.tcpConnectToAddress(address) catch break).close();
        serving.join();
    }

    const app = try z.App.init(allocator);
    defer app.deinit();
    var plugin: fetch_plugin.Plugin = undefined;
    try plugin.init(allocator, .{ .post = .app(app), .workers = 2 });
    var state: State = .{ .allocator = allocator, .app = app, .server = &server };
    state.window = try app.createWindow(.{ .title = "Fetch plugin smoke" });
    state.controls = .{ .window = state.window };
    state.host = .init(allocator, .{ .transport = .{ .context = &state, .send = State.send }, .controls = state.controls.controls() });
    try state.host.use(plugin.plugin());
    state.view = web.View.init(allocator, &state, State.event);

    var profile: []u8 = &.{};
    defer allocator.free(profile);
    if (builtin.os.tag == .windows) {
        const local = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "FetchPluginSmoke" });
        try state.view.attach(state.window, .{ .html = html, .user_data_folder = profile });
    } else {
        try state.view.attach(state.window, .{ .html = html, .storage = .ephemeral });
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
    try std.testing.expectEqual(3, state.parts);
    std.debug.print("fetch plugin WebView smoke passed: forbidden headers, JSON, POST, uploaded 300 KB body, redirects, streamed parts, 3 MB body, network failure, abort\n", .{});
}
