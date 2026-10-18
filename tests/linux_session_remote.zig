const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

extern fn ztest_remote_fixture_new() ?*anyopaque;
extern fn ztest_remote_fixture_origin(*anyopaque) [*:0]const u8;
extern fn ztest_remote_fixture_counts(*anyopaque, *c_uint, *c_uint) void;
extern fn ztest_remote_fixture_free(*anyopaque) void;
extern fn zlg_region_count() c_uint;
extern fn zlg_resource_count() c_uint;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;

const Stage = enum { first, mounted_a, parked, mounted_b, fragment, remounted_a, second, back, refreshed };
const Observation = struct { marker: u32, href: []const u8 };

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    fixture: *anyopaque,
    origin: []const u8,
    extension: []const u8,
    missing: bool,
    hosts: [2]z.Window = undefined,
    owners: [2]*z.composition.Owner = undefined,
    session: ?*web.PageSession = null,
    region: ?z.composition.Region = null,
    original: ?web.PageId = null,
    previous_document: ?web.PageId = null,
    stage: Stage = .first,
    ready: u32 = 0,
    completed: u32 = 0,
    first_messages: u32 = 0,
    second_messages: u32 = 0,
    failures: u32 = 0,
    evaluations: u32 = 0,
    closed: u32 = 0,
    fragment_seen: bool = false,
    queued: bool = false,
    evaluating: bool = false,
    closing: bool = false,
    done: bool = false,
    source: [256]u8 = undefined,
    source_len: usize = 0,
    source_page: ?web.PageId = null,
    timer: c_uint = 0,
    failure: ?anyerror = null,

    fn fail(self: *State, failure: anyerror) void {
        self.failure = self.failure orelse failure;
        std.debug.print("Linux remote Session {s}: {s}\n", .{ @tagName(self.stage), @errorName(failure) });
        self.app.quit();
    }
    fn counts(self: *State) !u32 {
        var requests: c_uint = 0;
        var forbidden: c_uint = 0;
        ztest_remote_fixture_counts(self.fixture, &requests, &forbidden);
        if (forbidden != 0) return error.UnexpectedRemoteRequest;
        return requests;
    }
    fn options(self: *State, grants: []const web.OriginGrant) web.Options {
        return .{
            .html = "",
            .storage = .ephemeral,
            .remote = .{ .url = self.origin, .origins = grants, .credentials = .ephemeral, .allow_insecure_loopback = true },
            .request_policy_extension = .{ .directory = self.extension, .handshake_timeout_ms = if (self.missing) 300 else 5000 },
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.ready += 1;
                if (self.missing or self.ready != 1) return self.fail(error.UnverifiedPolicyReady);
                if ((self.counts() catch |err| return self.fail(err)) != 0) return self.fail(error.RequestBeforeVerifiedStartup);
                // Policy readiness precedes the initial business document.
                std.testing.expectError(error.NotReady, view.post("before-document")) catch |err| return self.fail(err);
                if (view.pageId() != null) return self.fail(error.BusinessPageBeforeInitialNavigation);
            },
            .failed => {
                self.failures += 1;
                if (!self.missing or self.failures != 1 or self.ready != 0 or self.completed != 0 or view.nativeFailure() == null or view.nativeFailure().? != .glib) return self.fail(error.UnexpectedRemoteFailure);
                if ((self.counts() catch |err| return self.fail(err)) != 0) return self.fail(error.UnverifiedPolicyRequestedNetwork);
                self.close() catch |err| self.fail(err);
            },
            .message => |message| {
                if (self.missing or self.ready != 1) return self.fail(error.BusinessMessageBeforeVerifiedStartup);
                if (std.mem.eql(u8, message, "first")) self.first_messages += 1 else if (std.mem.eql(u8, message, "second")) self.second_messages += 1 else return self.fail(error.UnexpectedRemoteMessage);
            },
            .process_failed => self.fail(error.RemoteProcessFailed),
            else => {},
        }
    }
    fn expectedUri(self: *State, output: []u8) ![]const u8 {
        const suffix: []const u8 = switch (self.stage) {
            .first, .mounted_a, .parked, .mounted_b => "/",
            .fragment, .remounted_a, .back, .refreshed => "/#anchor",
            .second => "/second",
        };
        return std.fmt.bufPrint(output, "{s}{s}", .{ self.origin, suffix });
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .source_changed => |source| {
                const uri = source.uri orelse return self.fail(error.MissingRemoteSource);
                if (uri.len > self.source.len) return self.fail(error.RemoteSourceTooLong);
                @memcpy(self.source[0..uri.len], uri);
                self.source_len = uri.len;
                self.source_page = source.id;
                if (self.stage != .fragment or self.fragment_seen or !std.mem.endsWith(u8, uri, "#anchor")) return;
                if (!std.meta.eql(self.original.?, source.id) or self.completed != 1) return self.fail(error.FragmentReplacedDocument);
                self.fragment_seen = true;
                self.evaluate() catch |err| self.fail(err);
            },
            .completed => |result| {
                if (self.missing or !result.success or self.ready != 1) return self.fail(error.RemoteNavigationFailed);
                self.completed += 1;
                const expected: u32 = switch (self.stage) {
                    .first => 1,
                    .second => 2,
                    .back => 3,
                    .refreshed => 4,
                    else => return self.fail(error.AttachmentReloadedDocument),
                };
                if (self.completed != expected) return self.fail(error.UnexpectedRemoteCompletion);
                const current = view.pageId() orelse return self.fail(error.MissingRemotePage);
                if (!std.meta.eql(current, result.id)) return self.fail(error.WrongCompletionPage);
                if (self.stage == .first) {
                    self.original = current;
                } else {
                    if (std.meta.eql(current, self.previous_document.?)) return self.fail(error.NavigationRetainedOldPage);
                    std.testing.expectError(error.StalePage, view.postFor(self.previous_document.?, "old-document")) catch |err| return self.fail(err);
                    std.testing.expectError(error.StalePage, view.postFor(self.original.?, "original-document")) catch |err| return self.fail(err);
                }
                self.previous_document = current;
                self.evaluate() catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn evaluate(self: *State) !void {
        if (self.evaluating) return error.DuplicateRemoteEvaluation;
        self.evaluating = true;
        errdefer self.evaluating = false;
        _ = try self.session.?.page.evaluateJS("window.marker=(window.marker||0)+1;({marker:window.marker,href:location.href})", .{}, .{ .context = self, .complete = evaluated });
    }
    fn evaluated(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.evaluating = false;
        if (result != .json) return self.fail(error.RemoteScriptFailed);
        const parsed = std.json.parseFromSlice(Observation, self.allocator, result.json, .{}) catch |err| return self.fail(err);
        defer parsed.deinit();
        var uri: [256]u8 = undefined;
        const expected = self.expectedUri(&uri) catch |err| return self.fail(err);
        if (!std.mem.eql(u8, expected, parsed.value.href) or !std.mem.eql(u8, expected, self.source[0..self.source_len])) return self.fail(error.WrongRemoteSource);
        const current = self.session.?.page.pageId() orelse return self.fail(error.MissingRemotePage);
        if (self.source_page == null or !std.meta.eql(current, self.source_page.?)) return self.fail(error.StaleSourceMetadata);
        const marker: ?u32 = switch (self.stage) {
            .first => 1,
            .mounted_a => 2,
            .parked => 3,
            .mounted_b => 4,
            .fragment => 5,
            .remounted_a => 6,
            .second, .refreshed => 1,
            // Back may restore a cached DOM or request a fresh document. Its
            // real URI and logical generation, rather than cache policy, matter.
            .back => null,
        };
        if (marker) |number| if (parsed.value.marker != number) return self.fail(error.RemoteDOMWasReplaced);
        if (parsed.value.marker == 0) return self.fail(error.MissingDOMMarker);
        self.evaluations += 1;
        if (self.completed == 1) {
            if (!std.meta.eql(current, self.original.?) or (self.counts() catch |err| return self.fail(err)) != 1) return self.fail(error.AttachmentChangedDocument);
            self.session.?.page.postFor(self.original.?, "same-document") catch |err| return self.fail(err);
        }
        self.queue();
    }
    fn queue(self: *State) void {
        if (self.queued or self.failure != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.failure != null) return;
        self.step() catch |err| self.fail(err);
    }
    fn attach(self: *State, host: usize) !void {
        self.region = try self.owners[host].reserve(.{ .bounds = .{ .x = 12, .y = 16, .width = 240, .height = 140 } });
        try self.session.?.attachRegion(self.region.?);
        try std.testing.expect(std.meta.eql(self.hosts[host], self.session.?.page.window.?));
    }
    fn park(self: *State) !void {
        const old = self.region.?;
        try self.session.?.park();
        try std.testing.expect(self.session.?.currentRegion() == null and self.session.?.page.window == null);
        try std.testing.expectError(error.Closed, old.snapshot());
        self.region = null;
    }
    fn step(self: *State) !void {
        const session = self.session.?;
        switch (self.stage) {
            .first => {
                try std.testing.expectError(error.OriginDenied, session.page.navigateRemote("https://denied.test/"));
                try self.attach(0);
                self.stage = .mounted_a;
            },
            .mounted_a => {
                try self.park();
                self.stage = .parked;
            },
            .parked => {
                try self.attach(1);
                self.stage = .mounted_b;
            },
            .mounted_b => {
                self.stage = .fragment;
                var uri: [256]u8 = undefined;
                try session.page.navigateRemote(try self.expectedUri(&uri));
                return;
            },
            .fragment => {
                try self.park();
                try self.attach(0);
                self.stage = .remounted_a;
            },
            .remounted_a => {
                self.stage = .second;
                var uri: [256]u8 = undefined;
                try session.page.navigateRemote(try self.expectedUri(&uri));
                return;
            },
            .second => {
                try std.testing.expect(session.page.can_go_back);
                self.stage = .back;
                try session.page.goBack();
                return;
            },
            .back => {
                try std.testing.expect(session.page.can_go_forward);
                self.stage = .refreshed;
                try session.page.refresh();
                return;
            },
            .refreshed => {
                const requests = try self.counts();
                try std.testing.expect(self.fragment_seen and self.completed == 4 and self.evaluations == 9 and requests >= 3 and requests <= 4);
                try std.testing.expect(self.first_messages >= 2 and self.second_messages == 1);
                try self.close();
                return;
            },
        }
        try self.evaluate();
    }
    fn close(self: *State) !void {
        self.closing = true;
        _ = try self.session.?.close();
    }
    fn closedSession(ptr: *anyopaque, _: *web.PageSession) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        self.session = null;
        if (!self.closing) return;
        self.timer = g_timeout_add(10, drained, self);
        if (self.timer == 0) self.fail(error.TestDrainFailed);
    }
    // An explicit test-only drain retains the hidden hosts until WebKit's late
    // finish callbacks release physical references. Production close never waits.
    fn drained(ptr: *anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!std.meta.eql(web.resourceCounts(), web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 })) return 1;
        self.timer = 0;
        self.done = true;
        self.app.quit();
        return 0;
    }
};

fn runMode(allocator: std.mem.Allocator, directory: []const u8, missing: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const fixture = ztest_remote_fixture_new() orelse return error.RemoteFixtureFailed;
    defer ztest_remote_fixture_free(fixture);
    var state: State = .{ .allocator = allocator, .app = app, .fixture = fixture, .origin = std.mem.span(ztest_remote_fixture_origin(fixture)), .extension = directory, .missing = missing };
    state.hosts[0] = try app.createWindow(.{ .width = 420, .height = 280 });
    state.hosts[1] = try app.createWindow(.{ .width = 420, .height = 280 });
    state.owners[0] = try z.composition.Owner.create(allocator, state.hosts[0], .{ .capacity = 2 });
    defer {
        state.owners[0].detach() catch {};
        state.owners[0].close() catch unreachable;
    }
    state.owners[1] = try z.composition.Owner.create(allocator, state.hosts[1], .{ .capacity = 2 });
    defer {
        state.owners[1].detach() catch {};
        state.owners[1].close() catch unreachable;
    }
    var session = web.PageSession.init(allocator, &state, State.event);
    state.session = &session;
    defer if (state.session) |page| {
        _ = page.close() catch unreachable;
    };
    defer if (state.timer != 0) {
        _ = g_source_remove(state.timer);
    };
    const grants = [_]web.OriginGrant{.{ .origin = state.origin, .ipc = true }};
    try session.open(app, .{ .page = state.options(&grants), .initial_size = .{ .width = 240, .height = 140 }, .on_closed = .{ .context = &state, .notify = State.closedSession } });
    try std.testing.expect(session.page.window == null and session.native_host == null and app.resourceStats().allocated_records == 2);
    try std.testing.expectError(error.NotReady, session.page.post("before-policy-ack"));
    try std.testing.expectEqual(@as(u32, 0), try state.counts());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |failure| return failure;
    try std.testing.expect(!watchdog.expired and state.done and state.closed == 1 and state.session == null);
    try std.testing.expect(app.resourceStats().allocated_records == 0 and app.resourceStats().stop_participants == 0 and zlg_region_count() == 0);
    if (missing) {
        try std.testing.expect(state.ready == 0 and state.completed == 0 and state.first_messages == 0 and state.second_messages == 0 and state.failures == 1);
        try std.testing.expectEqual(@as(u32, 0), try state.counts());
    } else try std.testing.expect(state.ready == 1 and state.failures == 0);
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, web.resourceCounts());
    try std.testing.expect(web.deferredResourceCount() == 0);
}

pub fn run(allocator: std.mem.Allocator, directory: []const u8) !void {
    try runMode(allocator, "/ziggurat-missing-request-policy", true);
    try runMode(allocator, directory, false);
    try std.testing.expectEqual(@as(c_uint, 0), zlg_resource_count());
    std.debug.print("Linux remote Session: verified request-policy startup, zero requests without ACK, two hosts/park/rehost same DOM/PageId, fragment and cross-document back/refresh source, late references=0\n", .{});
}
