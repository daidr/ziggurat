const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn ztest_remote_fixture_new() ?*anyopaque;
extern fn ztest_remote_fixture_origin(*anyopaque) [*:0]const u8;
extern fn ztest_remote_fixture_other(*anyopaque) c_int;
extern fn ztest_remote_fixture_other_origin(*anyopaque) [*:0]const u8;
extern fn ztest_remote_fixture_counts(*anyopaque, *c_uint, *c_uint) void;
extern fn ztest_remote_fixture_free(*anyopaque) void;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;

const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    fixture: *anyopaque,
    origin: []const u8,
    extension: []const u8,
    missing: bool,
    close_on_ready: bool = false,
    grants: [2]web.OriginGrant = undefined,
    ready: usize = 0,
    completed: usize = 0,
    messages: usize = 0,
    failures: usize = 0,
    calls: usize = 0,
    releases: usize = 0,
    process_failures: usize = 0,
    old_page: ?web.PageId = null,
    fragment_page: ?web.PageId = null,
    fragment_pending: bool = false,
    fragment_checked: bool = false,
    timer: c_uint = 0,
    err: ?anyerror = null,
    fn fail(self: *@This(), err: anyerror) void {
        self.err = err;
        std.debug.print("remote View: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn options(self: *@This()) web.Options {
        return .{ .html = "", .storage = .ephemeral, .remote = .{ .url = self.origin, .origins = &self.grants, .credentials = .ephemeral, .allow_insecure_loopback = true }, .request_policy_extension = .{ .directory = self.extension, .handshake_timeout_ms = if (self.missing) 300 else 5000 }, .page_listener = .{ .context = self, .event = page } };
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.ready += 1;
                if (self.missing) return self.fail(error.UnverifiedPolicyReady);
                if (self.close_on_ready) return self.close();
                std.testing.expectError(error.NotReady, view.post("early")) catch |err| return self.fail(err);
            },
            .failed => {
                self.failures += 1;
                if (!self.missing or self.ready != 0 or view.nativeFailure() == null or view.nativeFailure().? != .glib) return self.fail(error.UnexpectedFailure);
                self.close();
            },
            .message => |text| {
                self.messages += 1;
                if (!std.mem.eql(u8, text, if (self.messages == 1 or self.messages >= 4) "first" else "second")) return self.fail(error.WrongDocumentMessage);
                self.advance();
            },
            .resources_released => self.releases += 1,
            .process_failed => {
                self.process_failures += 1;
                if (self.process_failures != 1 or self.calls != 5) return self.fail(error.UnexpectedProcessFailure);
                view.recover() catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .source_changed => |source| {
                if (!self.fragment_pending) return;
                const uri = source.uri orelse return self.fail(error.MissingFragmentUri);
                if (!std.mem.endsWith(u8, uri, "#anchor")) return;
                self.fragment_pending = false;
                const saved = self.fragment_page.?;
                if (!std.meta.eql(saved, source.id)) return self.fail(error.FragmentChangedDocument);
                self.fragment_checked = true;
                self.view.postFor(saved, "same document") catch |err| return self.fail(err);
                _ = self.view.evaluateJS("6*7", .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
            },
            .completed => |result| {
                if (!result.success or self.missing) return self.fail(error.RemoteLoadFailed);
                self.completed += 1;
                self.advance();
            },
            else => {},
        }
    }
    fn advance(self: *@This()) void {
        if (self.calls == self.completed) return;
        if (self.completed != 4 and self.messages != self.completed - @as(usize, if (self.completed > 4) 1 else 0)) return;
        self.calls += 1;
        _ = self.view.evaluateJS("6*7", .{}, .{ .context = self, .complete = evaluated }) catch |err| self.fail(err);
    }
    fn evaluated(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "42")) return self.fail(error.WrongEvaluation);
        std.testing.expectError(error.OriginDenied, self.view.navigateRemote("https://denied.test/")) catch |err| return self.fail(err);
        if (self.calls == 1) {
            var url: [128]u8 = undefined;
            if (!self.fragment_checked) {
                self.fragment_page = self.view.pageId();
                self.fragment_pending = true;
                const fragment = std.fmt.bufPrint(&url, "{s}/#anchor", .{self.origin}) catch |err| return self.fail(err);
                self.view.navigateRemote(fragment) catch |err| self.fail(err);
                return;
            }
            const target = std.fmt.bufPrint(&url, "{s}/second", .{self.origin}) catch |err| return self.fail(err);
            self.view.navigateRemote(target) catch |err| self.fail(err);
        } else if (self.calls == 2) {
            self.view.refresh() catch |err| self.fail(err);
        } else if (self.calls == 3) {
            self.view.navigateRemote(self.grants[1].origin) catch |err| self.fail(err);
        } else if (self.calls == 4) {
            std.testing.expectError(error.IpcOriginDenied, self.view.post("denied")) catch |err| return self.fail(err);
            self.view.reload(self.options()) catch |err| self.fail(err);
        } else if (self.calls == 5) {
            self.old_page = self.view.pageId();
            @import("linux_webview_process.zig").stop(self.window) catch |err| self.fail(err);
        } else {
            std.testing.expectError(error.StalePage, self.view.postFor(self.old_page.?, "old page")) catch |err| return self.fail(err);
            self.close();
        }
    }
    fn close(self: *@This()) void {
        _ = self.window.destroy() catch |err| return self.fail(err);
        self.timer = g_timeout_add(10, drained, self);
    }
    fn drained(ptr: *anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const counts = web.resourceCounts();
        if (counts.states != 0 or counts.handlers != 0 or counts.controllers != 0) return 1;
        self.timer = 0;
        self.app.quit();
        return 0;
    }
};
fn run(allocator: std.mem.Allocator, directory: []const u8, missing: bool, close_on_ready: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const fixture = ztest_remote_fixture_new() orelse return error.FixtureFailed;
    defer ztest_remote_fixture_free(fixture);
    if (ztest_remote_fixture_other(fixture) == 0) return error.FixtureFailed;
    var probe: Probe = .{ .app = app, .fixture = fixture, .origin = std.mem.span(ztest_remote_fixture_origin(fixture)), .extension = directory, .missing = missing, .close_on_ready = close_on_ready };
    probe.grants = .{ .{ .origin = probe.origin, .ipc = true }, .{ .origin = std.mem.span(ztest_remote_fixture_other_origin(fixture)), .ipc = false } };
    probe.window = try app.createWindow(.{ .width = 320, .height = 200 });
    probe.view = web.View.init(allocator, &probe, Probe.event);
    try probe.view.attach(probe.window, probe.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (probe.timer != 0) _ = g_source_remove(probe.timer);
    if (probe.err) |err| return err;
    try std.testing.expect(!watchdog.expired and app.resourceStats().allocated_records == 0);
    var requests: c_uint = 0;
    var forbidden: c_uint = 0;
    ztest_remote_fixture_counts(fixture, &requests, &forbidden);
    try std.testing.expect(forbidden == 0);
    if (missing) {
        try std.testing.expect(probe.failures == 1 and probe.ready == 0 and requests == 0);
    } else if (close_on_ready) {
        try std.testing.expect(probe.ready == 1 and probe.completed == 0 and probe.messages == 0 and requests == 0);
    } else try std.testing.expect(probe.ready == 3 and probe.completed == 6 and probe.messages == 5 and requests == 6 and probe.releases == 1 and probe.process_failures == 1 and probe.fragment_checked);
}
fn attachAllocationFailure(allocator: std.mem.Allocator, core_allocator: std.mem.Allocator, directory: []const u8) !void {
    const app = try z.App.init(core_allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var marker: u8 = 0;
    var view = web.View.init(allocator, &marker, struct {
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {
            @panic("closed remote owner received callback");
        }
    }.event);
    view.attach(window, .{ .html = "", .storage = .ephemeral, .remote = .{ .url = "https://example.test/", .origins = &.{.{ .origin = "https://example.test", .ipc = true, .request_headers = &.{.{ .name = "X-Explicit", .exact_value = "known" }} }}, .credentials = .ephemeral }, .request_policy_extension = .{ .directory = directory } }) catch |err| {
        try std.testing.expect(view.window == null and view.native == null and view.config == null and view.attachment_phase == .detached);
        return err;
    };
    _ = try window.destroy();
    try std.testing.expect(view.window == null and view.native == null and view.config == null);
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const directory = try std.process.getEnvVarOwned(allocator, "ZIGGURAT_REQUEST_POLICY_EXTENSION");
    defer allocator.free(directory);
    try std.testing.checkAllAllocationFailures(allocator, attachAllocationFailure, .{ allocator, directory });
    try run(allocator, "/ziggurat-missing-request-policy", true, false);
    try run(allocator, directory, false, true);
    try run(allocator, directory, false, false);
    std.debug.print("remote View: all allocation failures, verified startup, zero-request failure/close, navigation/refresh, IPC, reload/recover, late refs=0\n", .{});
}
