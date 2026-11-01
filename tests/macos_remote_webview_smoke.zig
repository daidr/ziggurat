const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);

extern fn ztest_remote_fixture_new() ?*anyopaque;
extern fn ztest_remote_fixture_origin(*anyopaque) [*:0]const u8;
extern fn ztest_remote_fixture_other_origin(*anyopaque) [*:0]const u8;
extern fn ztest_remote_fixture_counts(*anyopaque, *c_uint, *c_uint, *c_uint) void;
extern fn ztest_remote_fixture_free(*anyopaque) void;

/// A remote page through its life. Each document reports its path, a script
/// of its origin, a GET and a POST of its own (WKWebView shows the app no
/// script request, so the grant holds by origin), and an image of an origin
/// never granted, which the page's rule list blocks before the network.
/// Then a remote navigation, back and forward, a fragment within the
/// document, a script navigation through a server redirect, refresh, IPC
/// both ways, and refusals.
const Probe = struct {
    app: *z.App,
    window: z.Window,
    origin: []const u8,
    other: []const u8,
    view: web.View = undefined,
    err: ?anyerror = null,
    stage: u8 = 0,
    queued: bool = false,
    started: u32 = 0,
    completed: u32 = 0,
    boots: u32 = 0,
    acks: u32 = 0,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    generation: u64 = 0,
    boot: [256]u8 = undefined,
    boot_len: usize = 0,
    source: [512]u8 = undefined,
    source_len: usize = 0,
    url: [512]u8 = undefined,

    fn fail(self: *@This(), err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("macOS remote page stage={d} started={d} completed={d} boots={d} back={} forward={} boot={s} source={s}: {s}\n", .{ self.stage, self.started, self.completed, self.boots, self.can_go_back, self.can_go_forward, self.boot[0..self.boot_len], self.source[0..self.source_len], @errorName(err) });
        self.app.quit();
    }
    fn enqueue(self: *@This()) void {
        if (self.queued or self.err != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn copy(buffer: []u8, length: *usize, text: []const u8) !void {
        if (text.len > buffer.len) return error.TooLong;
        @memcpy(buffer[0..text.len], text);
        length.* = text.len;
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |text| {
                if (std.mem.startsWith(u8, text, "boot:")) {
                    copy(&self.boot, &self.boot_len, text[5..]) catch |err| return self.fail(err);
                    self.boots += 1;
                } else if (std.mem.eql(u8, text, "ack:ping")) {
                    self.acks += 1;
                } else return self.fail(error.UnexpectedMessage);
            },
            .failed => self.fail(error.NativeFailure),
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
        self.enqueue();
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .started => |info| {
                self.started += 1;
                const uri = info.uri orelse return self.fail(error.MissingStartUri);
                if (!std.mem.startsWith(u8, uri, self.origin) or uri.len <= self.origin.len or uri[self.origin.len] != '/') return self.fail(error.WrongStartUri);
            },
            .completed => |info| {
                self.completed += 1;
                if (!info.success) return self.fail(error.LoadFailed);
            },
            .source_changed => |info| copy(&self.source, &self.source_len, info.uri orelse "") catch |err| return self.fail(err),
            .history_changed => |info| {
                self.can_go_back = info.can_go_back;
                self.can_go_forward = info.can_go_forward;
            },
            else => {},
        }
        self.enqueue();
    }
    fn advance(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.step() catch |err| self.fail(err);
    }
    fn booted(self: *@This(), count: u32, path: []const u8) bool {
        if (self.completed != count or self.boots != count) return false;
        const text = self.boot[0..self.boot_len];
        return std.mem.startsWith(u8, text, path) and text.len > path.len and text[path.len] == ' ';
    }
    fn at(self: *@This(), path: []const u8) bool {
        const source = self.source[0..self.source_len];
        return std.mem.startsWith(u8, source, self.origin) and std.mem.eql(u8, source[self.origin.len..], path);
    }
    fn address(self: *@This(), origin: []const u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&self.url, "{s}{s}", .{ origin, path });
    }
    fn step(self: *@This()) !void {
        switch (self.stage) {
            0 => if (self.booted(1, "/")) {
                const text = self.boot[0..self.boot_len];
                std.debug.print("macOS remote page: first document reports \"{s}\"\n", .{text});
                if (!std.mem.eql(u8, text, "/ true ok posted blocked")) return error.WrongPageBehavior;
                if (!self.at("/")) return error.WrongSource;
                try std.testing.expectError(error.OriginDenied, self.view.navigateRemote(try self.address(self.other, "/")));
                try std.testing.expectError(error.NoHistory, self.view.goBack());
                self.stage = 1;
                try self.view.navigateRemote(try self.address(self.origin, "/second"));
                try std.testing.expectError(error.NavigationPending, self.view.navigateRemote(try self.address(self.origin, "/second")));
            },
            1 => if (self.booted(2, "/second") and self.can_go_back and !self.can_go_forward) {
                if (!self.at("/second")) return error.WrongSource;
                self.stage = 2;
                try self.view.goBack();
            },
            2 => if (self.booted(3, "/") and self.can_go_forward) {
                if (!self.at("/")) return error.WrongSource;
                self.stage = 3;
                try self.view.goForward();
            },
            3 => if (self.booted(4, "/second") and self.can_go_back and !self.can_go_forward) {
                self.generation = self.view.pageId().?.generation;
                self.stage = 4;
                try self.view.navigateRemote(try self.address(self.origin, "/second#part"));
            },
            4 => if (self.at("/second#part")) {
                // Within one document: no new start, page or boot.
                if (self.started != 4 or self.boots != 4 or self.view.pageId().?.generation != self.generation) return error.FragmentReplacedDocument;
                self.stage = 5;
                _ = try self.view.evaluateJS("location.href='/redirect';1", .{}, .{ .context = self, .complete = script });
            },
            5 => if (self.booted(5, "/second") and self.at("/second")) {
                if (self.view.pageId().?.generation == self.generation) return error.ScriptNavigationKeptDocument;
                self.generation = self.view.pageId().?.generation;
                self.stage = 6;
                try self.view.refresh();
            },
            6 => if (self.booted(6, "/second")) {
                if (self.view.pageId().?.generation == self.generation) return error.RefreshKeptDocument;
                self.stage = 7;
                try self.view.postFor(self.view.pageId().?, "ping");
            },
            7 => if (self.acks == 1) {
                self.stage = 8;
                _ = try self.window.destroy();
                self.app.quit();
            },
            else => {},
        }
    }
    fn script(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        self.enqueue();
    }
};

fn run(allocator: std.mem.Allocator, fixture: *anyopaque) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const origin = std.mem.span(ztest_remote_fixture_origin(fixture));
    const other = std.mem.span(ztest_remote_fixture_other_origin(fixture));
    var probe: Probe = .{ .app = app, .window = try app.createWindow(.{ .width = 320, .height = 240 }), .origin = origin, .other = other };
    probe.view = web.View.init(allocator, &probe, Probe.event);
    var start: [128]u8 = undefined;
    const grants = [_]web.OriginGrant{.{ .origin = origin, .ipc = true }};
    const remote: web.RemotePage = .{ .url = try std.fmt.bufPrint(&start, "{s}/", .{origin}), .origins = &grants, .credentials = .ephemeral, .allow_insecure_loopback = true, .allow_script_navigation = true, .allow_redirects = true };
    // WKWebView adds no header of the app's, and has no WebProcess adapter.
    var with_credential = remote;
    with_credential.origins = &.{.{ .origin = "https://example.com" }};
    with_credential.url = "https://example.com/";
    with_credential.request_credentials = &.{.{ .origin = "https://example.com", .bearer = @splat(1) }};
    try std.testing.expectError(error.UnsupportedCapability, probe.view.attach(probe.window, .{ .html = "", .storage = .ephemeral, .remote = with_credential }));
    try std.testing.expectError(error.UnsupportedCapability, probe.view.attach(probe.window, .{ .html = "", .storage = .ephemeral, .remote = remote, .request_policy_extension = .{ .directory = "/app/policy" } }));
    try probe.view.attach(probe.window, .{ .html = "", .storage = .ephemeral, .remote = remote, .page_listener = .{ .context = &probe, .event = Probe.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) probe.fail(error.Timeout);
    if (probe.err) |err| return err;
    try std.testing.expect(probe.stage == 8);
}

/// Engine completions of closed pages still arrive after close; waits for
/// them and the pages' native records to drain.
const Drain = struct {
    app: *z.App,
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const counts = web.resourceCounts();
        if (counts.states == 0 and counts.handlers == 0 and counts.controllers == 0) return self.app.quit();
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (!web.backendCapabilities().page_lifecycle) return error.SkipZigTest;
    const fixture = ztest_remote_fixture_new() orelse return error.FixtureUnavailable;
    defer ztest_remote_fixture_free(fixture);
    try run(allocator.allocator(), fixture);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var drain: Drain = .{ .app = app };
    try app.post(.{ .context = &drain, .call = Drain.tick });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired);
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, web.resourceCounts());
    var requests: c_uint = 0;
    var other: c_uint = 0;
    var redirects: c_uint = 0;
    ztest_remote_fixture_counts(fixture, &requests, &other, &redirects);
    // The other origin is never reached; the script navigation went through one redirect.
    try std.testing.expectEqual(@as(c_uint, 0), other);
    try std.testing.expectEqual(@as(c_uint, 1), redirects);
    std.debug.print("macOS remote page: origin grants, blocked origin (requests={d} other={d}), remote navigation, history, fragment, script navigation through a redirect, refresh, IPC; native records=0\n", .{ requests, other });
}
