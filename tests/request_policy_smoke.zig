const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const template =
    \\<!doctype html><script>
    \\(async()=>{try{
    \\const run=async(path,options,status,body)=>{const r=await fetch(path,options);if(r.status!==status)throw new Error(path+': '+r.status);if(body!==undefined&&(await r.text())!==body)throw new Error(path+' body')};
    \\await run('/post',{method:'POST',headers:{'Content-Type':'text/plain','X-Allowed':'exact'},body:'private-body'},201,'posted');
    \\await run('/options',{method:'OPTIONS'},200,'options');
    \\await run('/auth',{headers:{'Authorization':'Bearer private-fixture'}},200,'authorized');
    \\await run('/wrong-value',{method:'POST',headers:{'Content-Type':'text/plain','X-Allowed':'wrong'},body:'not-forwarded'},403);
    \\await run('/unknown-name',{headers:{'Unlisted-Header':'not-forwarded'}},403);
    \\await run('/range',{headers:{'Range':'bytes=0-1'}},403);
    \\await run('/put',{method:'PUT',headers:{'Content-Type':'text/plain'},body:'not-forwarded'},403);
    \\await fetch('OTHER_ORIGIN/cross',{method:'POST',mode:'no-cors',headers:{'Content-Type':'text/plain'},body:'not-forwarded'}).catch(()=>{});
    \\chrome.webview.postMessage('policy-ok');
    \\}catch(e){chrome.webview.postMessage('policy-error:'+e.message)}})();
    \\</script>
;
const Server = struct {
    listener: std.net.Server,
    html: []const u8 = "",
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    requests: std.atomic.Value(u32) = .init(0),
    post: std.atomic.Value(u32) = .init(0),
    options: std.atomic.Value(u32) = .init(0),
    auth: std.atomic.Value(u32) = .init(0),
    rejected: std.atomic.Value(u32) = .init(0),
    bad: std.atomic.Value(bool) = .init(false),
    fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    fn stop(self: *Server) void {
        if (self.thread) |thread| {
            self.stop_requested.store(true, .release);
            const wake = std.net.tcpConnectToAddress(self.listener.listen_address) catch unreachable;
            wake.close();
            thread.join();
        }
        self.listener.deinit();
    }
    fn run(self: *Server) void {
        while (true) {
            const connection = self.listener.accept() catch return;
            defer connection.stream.close();
            if (self.stop_requested.load(.acquire)) return;
            self.serve(connection.stream) catch {
                self.bad.store(true, .release);
            };
        }
    }
    fn serve(self: *Server, stream: std.net.Stream) !void {
        var buffer: [16384]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n") == null) {
            if (used == buffer.len) return error.RequestTooLarge;
            const n = try std.posix.recv(stream.handle, buffer[used..], 0);
            if (n == 0) return;
            used += n;
        }
        const end = std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n").? + 4;
        var lines = std.mem.splitSequence(u8, buffer[0..end], "\r\n");
        var first = std.mem.splitScalar(u8, lines.next().?, ' ');
        const method = first.next() orelse return error.InvalidRequest;
        const path = first.next() orelse return error.InvalidRequest;
        var length: usize = 0;
        var exact = false;
        var authorized = false;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) length = try std.fmt.parseInt(usize, value, 10);
            if (std.ascii.eqlIgnoreCase(name, "x-allowed")) exact = std.mem.eql(u8, value, "exact");
            if (std.ascii.eqlIgnoreCase(name, "authorization")) authorized = std.mem.eql(u8, value, "Bearer private-fixture");
        }
        if (length > 4096 or end + length > buffer.len) return error.RequestTooLarge;
        while (used < end + length) {
            const n = try std.posix.recv(stream.handle, buffer[used..], 0);
            if (n == 0) return error.TruncatedBody;
            used += n;
        }
        _ = self.requests.fetchAdd(1, .monotonic);
        var status: u16 = 200;
        var body: []const u8 = self.html;
        if (std.mem.eql(u8, path, "/post")) {
            if (!std.mem.eql(u8, method, "POST") or !exact or !std.mem.eql(u8, buffer[end..][0..length], "private-body")) self.bad.store(true, .release);
            _ = self.post.fetchAdd(1, .monotonic);
            status = 201;
            body = "posted";
        } else if (std.mem.eql(u8, path, "/options")) {
            if (!std.mem.eql(u8, method, "OPTIONS")) self.bad.store(true, .release);
            _ = self.options.fetchAdd(1, .monotonic);
            body = "options";
        } else if (std.mem.eql(u8, path, "/auth")) {
            if (!authorized) self.bad.store(true, .release);
            _ = self.auth.fetchAdd(1, .monotonic);
            body = "authorized";
        } else if (std.mem.eql(u8, path, "/favicon.ico")) {
            status = 204;
            body = "";
        } else if (!std.mem.eql(u8, path, "/start")) {
            std.debug.print("unexpected private server request {s} {s}\n", .{ method, path });
            _ = self.rejected.fetchAdd(1, .monotonic);
            body = "unexpected";
        }
        var header: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&header, "HTTP/1.1 {d} Fixture\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len });
        try stream.writeAll(text);
        try stream.writeAll(body);
    }
};
const State = struct {
    app: *z.App,
    done: bool = false,
    failed: bool = false,
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |message| {
                self.done = std.mem.eql(u8, message, "policy-ok");
                if (!self.done) {
                    std.debug.print("request policy message: {s}\n", .{message});
                    self.failed = true;
                }
                self.app.quit();
            },
            .failed, .process_failed => {
                self.failed = true;
                self.app.quit();
            },
            else => {},
        }
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const bind = try std.net.Address.parseIp4("127.0.0.1", 0);
    var allowed: Server = .{ .listener = try bind.listen(.{}) };
    var other: Server = .{ .listener = try bind.listen(.{}) };
    defer other.stop();
    const origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{allowed.listener.listen_address.getPort()});
    defer allocator.free(origin);
    const other_origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{other.listener.listen_address.getPort()});
    defer allocator.free(other_origin);
    const url = try std.fmt.allocPrint(allocator, "{s}/start", .{origin});
    defer allocator.free(url);
    const html = try std.mem.replaceOwned(u8, allocator, template, "OTHER_ORIGIN", other_origin);
    defer allocator.free(html);
    allowed.html = html;
    defer allowed.stop();
    try allowed.start();
    try other.start();
    const local = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "RequestPolicySmoke" });
    defer allocator.free(profile);
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    var view = web.View.init(allocator, &state, State.event);
    const window = try app.createWindow(.{});
    const grants = [_]web.OriginGrant{
        .{ .origin = origin, .ipc = true, .methods = .{ .post = true, .options = true }, .request_headers = &.{ .{ .name = "Content-Type", .exact_value = "text/plain" }, .{ .name = "X-Allowed", .exact_value = "exact" }, .{ .name = "Authorization", .exact_value = "Bearer private-fixture" } } },
        .{ .origin = other_origin, .navigate = false },
    };
    try view.attach(window, .{ .html = "", .user_data_folder = profile, .remote = .{ .url = url, .origins = &grants, .credentials = .profile, .allow_insecure_loopback = true } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    std.debug.print("request policy counts post={d} options={d} auth={d} rejected={d} other={d}\n", .{ allowed.post.load(.acquire), allowed.options.load(.acquire), allowed.auth.load(.acquire), allowed.rejected.load(.acquire), other.requests.load(.acquire) });
    try std.testing.expect(!watchdog.expired and state.done and !state.failed and !allowed.bad.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), allowed.post.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), allowed.options.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), allowed.auth.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), allowed.rejected.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), other.requests.load(.acquire));
    const refs = web.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), refs.states + refs.handlers + refs.controllers);
    std.debug.print("request policy smoke passed: exact origin/port/method/header grants, real POST body/OPTIONS/Authorization, unknown name/value/Range/PUT/cross-port denied; COM=0\n", .{});
}
