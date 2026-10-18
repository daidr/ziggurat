const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
extern fn zwv_close(*anyopaque) void;
extern fn zwv_test_seed_permission(*anyopaque, [*:0]const u16, *const fn (*anyopaque, i32) callconv(.c) void, *anyopaque) i32;

const html =
    \\<!doctype html><meta charset="utf-8"><script src="/app.js"></script>
;
const script =
    \\(async () => {
    \\ const post = value => chrome.webview.postMessage(value);
    \\ if (await (await fetch('/data.txt')).text() !== 'embedded-ok') throw Error('static resource');
    \\ if (await (await fetch('/dynamic')).text() !== 'stack-ok') throw Error('stream did not copy stack response');
    \\ if ((await fetch('/missing')).status !== 404) throw Error('missing resource');
    \\ try { await fetch('https://outside.invalid/resource'); post('network-allowed'); }
    \\ catch { post('network-denied'); }
    \\ navigator.geolocation.getCurrentPosition(() => post('permission-allowed'), () => post('permission-denied'));
    \\ const frame = document.createElement('iframe'); frame.src = '/frame.html'; document.body.append(frame);
    \\ const inline = document.createElement('iframe'); inline.srcdoc = '<script>chrome.webview.postMessage("frame-leak")<\/script>'; document.body.append(inline);
    \\ window.open('https://outside.invalid/popup');
    \\ const download = document.createElement('a'); download.href = '/file.bin'; download.download = 'ziggurat-policy.bin'; download.click();
    \\ location.href = 'https://outside.invalid/navigation';
    \\ post('assets-ok');
    \\})().catch(error => chrome.webview.postMessage('failure:' + String(error)));
;
const resources: []const web.Resource = &.{
    .{ .path = "/app.js", .mime = "text/javascript; charset=utf-8", .bytes = script },
    .{ .path = "/data.txt", .mime = "text/plain; charset=utf-8", .bytes = "embedded-ok" },
    .{ .path = "/frame.html", .mime = "text/html; charset=utf-8", .bytes = "<script>chrome.webview.postMessage('frame-leak')</script>" },
    .{ .path = "/file.bin", .mime = "application/octet-stream", .bytes = "denied download" },
};

const State = struct {
    app: *z.App,
    view: *web.View = undefined,
    seed_view: *web.View = undefined,
    capacity_view: *web.View = undefined,
    policy_window: z.Window = undefined,
    capacity_window: z.Window = undefined,
    options: web.Options = undefined,
    seeded_allow: bool = false,
    capacity_failed_closed: bool = false,
    ready_count: usize = 0,
    asset_count: usize = 0,
    dynamic_count: usize = 0,
    policy_counts: [5]usize = @splat(0),
    permission_denied: bool = false,
    network_denied: bool = false,
    crash_requested: bool = false,
    recover_requested: bool = false,
    failed: bool = false,

    fn close(self: *State) void {
        if (self.view.window) |window| _ = window.destroy() catch {
            self.app.quit();
            return;
        };
    }
    fn seedEvent(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                const hr = zwv_test_seed_permission(view.native.?, std.unicode.utf8ToUtf16LeStringLiteral("https://app.ziggurat.invalid"), seeded, self);
                if (hr < 0) {
                    self.failed = true;
                    self.app.quit();
                }
            },
            .failed, .process_failed => {
                self.failed = true;
                self.app.quit();
            },
            else => {},
        }
    }
    fn seeded(ptr: *anyopaque, hr: i32) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const window = self.seed_view.window orelse return;
        const scope = window.beginCallback() orelse return;
        defer scope.end();
        if (hr < 0) {
            self.failed = true;
            self.app.quit();
            return;
        }
        self.seeded_allow = true;
        var limited = self.options;
        limited.max_cached_permissions = 0;
        self.capacity_view.attach(self.capacity_window, limited) catch {
            self.failed = true;
            self.app.quit();
            return;
        };
        _ = window.destroy() catch {
            self.failed = true;
            self.app.quit();
        };
    }
    fn capacityEvent(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed => |hr| {
                if (@as(u32, @bitCast(hr)) != 0x8007006f or self.capacity_failed_closed) {
                    self.failed = true;
                    self.app.quit();
                    return;
                }
                self.capacity_failed_closed = true;
                self.view.attach(self.policy_window, self.options) catch {
                    self.failed = true;
                    self.app.quit();
                    return;
                };
                _ = view.window.?.destroy() catch {
                    self.failed = true;
                    self.app.quit();
                };
            },
            else => {
                // No ready, message or policy callback is allowed before the
                // cached grant budget is checked and accepted.
                self.failed = true;
                self.app.quit();
            },
        }
    }
    fn check(self: *State) void {
        if (self.asset_count >= 2 and self.ready_count >= 2 and self.recover_requested) {
            self.close();
            return;
        }
        if (self.crash_requested or self.asset_count != 1 or !self.permission_denied or !self.network_denied) return;
        for (self.policy_counts) |count| if (count == 0) return;
        self.crash_requested = true;
        self.app.post(.{ .context = self, .call = crashBrowser }) catch {
            self.failed = true;
            self.close();
        };
    }
    fn crashBrowser(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var pid: c_uint = 0;
        const hr = zwv_browser_process_id(self.view.native.?, &pid);
        if (hr < 0 or pid == 0) {
            self.failed = true;
            self.close();
            return;
        }
        // This PID comes from this test's own controller and private profile.
        const process = c.OpenProcess(c.PROCESS_TERMINATE, c.FALSE, pid);
        if (process == null) {
            self.failed = true;
            self.close();
            return;
        }
        defer _ = c.CloseHandle(process);
        if (c.TerminateProcess(process, 0x7f) == 0) {
            self.failed = true;
            self.close();
        }
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, request.path, "/dynamic")) return;
        self.dynamic_count += 1;
        var body: [8]u8 = "stack-ok".*;
        responder.respond(.{ .mime = "text/plain; charset=utf-8", .bytes = &body }) catch {
            self.failed = true;
            self.close();
        };
        @memset(&body, 'x');
    }
    fn event(ptr: *anyopaque, view: *web.View, event_value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (event_value) {
            .ready => self.ready_count += 1,
            .resources_released => {},
            .message => |message| {
                if (std.mem.eql(u8, message, "assets-ok")) self.asset_count += 1 else if (std.mem.eql(u8, message, "permission-denied")) self.permission_denied = true else if (std.mem.eql(u8, message, "network-denied")) self.network_denied = true else {
                    std.debug.print("policy smoke unexpected message: {s}\n", .{message});
                    self.failed = true;
                    self.close();
                }
                self.check();
            },
            .policy_request => |request| {
                self.policy_counts[@intFromEnum(request.kind)] += 1;
                self.check();
            },
            .process_failed => |failure| {
                if (!self.crash_requested) {
                    std.debug.print("policy smoke unexpected process failure: {d}\n", .{failure.native_kind});
                    self.failed = true;
                    self.close();
                } else if (!self.recover_requested) {
                    self.recover_requested = true;
                    view.recover() catch {
                        self.failed = true;
                        self.close();
                    };
                    if (view.recover()) |_| {
                        self.failed = true;
                        self.close();
                    } else |err| if (err != error.RecoveryInProgress) {
                        self.failed = true;
                        self.close();
                    }
                }
            },
            .failed => |hr| {
                std.debug.print("policy smoke WebView failure: 0x{x}\n", .{@as(u32, @bitCast(hr))});
                self.failed = true;
                self.close();
            },
        }
    }
};

fn queuedRecoveryClose(allocator: std.mem.Allocator, profile: []const u8) !void {
    const Probe = struct {
        ready: usize = 0,
        messages: usize = 0,
        failed: bool = false,
        fn noop(_: *anyopaque) void {}
        fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (value) {
                .ready => self.ready += 1,
                .message => |message| {
                    self.messages += 1;
                    if (!std.mem.eql(u8, message, "new-epoch")) self.failed = true;
                    _ = view.window.?.destroy() catch unreachable;
                },
                .failed, .process_failed => {
                    self.failed = true;
                    _ = view.window.?.destroy() catch unreachable;
                },
                .policy_request, .resources_released => {},
            }
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = web.View.init(allocator, &probe, Probe.event);
    const old = try app.createWindow(.{});
    const options: web.Options = .{ .html = "<script>chrome.webview.postMessage('new-epoch')</script>", .user_data_folder = profile };
    try view.attach(old, options);
    // Inject the native-null state of a failed synchronous recreation. Its fresh
    // anchor must not revive the old environment's pending callbacks or context.
    zwv_close(view.native.?);
    view.native = null;
    view.failed = true;
    for (0..256) |_| try app.post(.{ .context = &probe, .call = Probe.noop });
    try std.testing.expectError(error.Full, view.recover());
    try std.testing.expect(!view.recovering);
    try app.dispatch();
    try view.recover();
    try std.testing.expect(view.recovering);
    _ = try old.destroy();
    try std.testing.expect(view.window == null and view.native == null and view.config == null);
    const fresh = try app.createWindow(.{});
    try view.attach(fresh, options);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and !probe.failed);
    try std.testing.expectEqual(1, probe.ready);
    try std.testing.expectEqual(1, probe.messages);
    const counts = web.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.states);
    try std.testing.expectEqual(@as(u32, 0), counts.handlers);
    try std.testing.expectEqual(@as(u32, 0), counts.controllers);
}

fn retryAfterAllocationFailure(allocator: std.mem.Allocator, profile: []const u8) !void {
    const Probe = struct {
        allocator: std.mem.Allocator,
        failing: std.testing.FailingAllocator,
        ready_count: usize = 0,
        failure_count: usize = 0,
        messages: usize = 0,
        failed: bool = false,
        fn close(self: *@This(), view: *web.View) void {
            // Always restore the owner allocator before detach frees the config.
            view.allocator = self.allocator;
            _ = view.window.?.destroy() catch unreachable;
        }
        fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (value) {
                .ready => {
                    self.ready_count += 1;
                    if (self.ready_count == 1) {
                        view.failed = true;
                        view.allocator = self.failing.allocator();
                        view.recover() catch {
                            self.failed = true;
                            self.close(view);
                        };
                    }
                },
                .failed => |hr| {
                    self.failure_count += 1;
                    view.allocator = self.allocator;
                    if (self.failure_count != 1 or @as(u32, @bitCast(hr)) != 0x8007000e or view.native != null) {
                        self.failed = true;
                        self.close(view);
                        return;
                    }
                    // This attempt owns a fresh empty anchor; old State remains
                    // closed while its current COM/task references unwind.
                    view.recover() catch {
                        self.failed = true;
                        self.close(view);
                    };
                },
                .message => |message| {
                    if (self.ready_count != 2 or !std.mem.eql(u8, message, "retry-ok")) self.failed = true;
                    self.messages += 1;
                    self.close(view);
                },
                .process_failed => {
                    self.failed = true;
                    self.close(view);
                },
                .policy_request, .resources_released => {},
            }
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .allocator = allocator, .failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 }) };
    var view = web.View.init(allocator, &probe, Probe.event);
    const window = try app.createWindow(.{});
    try view.attach(window, .{ .html = "<script>chrome.webview.postMessage('retry-ok')</script>", .user_data_folder = profile });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and !probe.failed);
    try std.testing.expectEqual(2, probe.ready_count);
    try std.testing.expectEqual(1, probe.failure_count);
    try std.testing.expectEqual(1, probe.messages);
    const counts = web.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.states);
    try std.testing.expectEqual(@as(u32, 0), counts.handlers);
    try std.testing.expectEqual(@as(u32, 0), counts.controllers);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const local = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PolicySmoke" });
    defer allocator.free(profile);
    const queue_profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PolicyQueueSmoke" });
    defer allocator.free(queue_profile);
    try queuedRecoveryClose(allocator, queue_profile);
    const retry_profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PolicyRetrySmoke" });
    defer allocator.free(retry_profile);
    try retryAfterAllocationFailure(allocator, retry_profile);
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    var view = web.View.init(allocator, &state, State.event);
    var seed_view = web.View.init(allocator, &state, State.seedEvent);
    var capacity_view = web.View.init(allocator, &state, State.capacityEvent);
    state.view = &view;
    state.seed_view = &seed_view;
    state.capacity_view = &capacity_view;
    const window = try app.createWindow(.{});
    try std.testing.expectError(error.InvalidLocalHost, view.attach(window, .{ .html = html, .user_data_folder = profile, .local = .{ .host = "outside.invalid/escape" } }));
    try std.testing.expectError(error.InvalidResourcePath, view.attach(window, .{ .html = html, .user_data_folder = profile, .local = .{ .start_path = "/../escape" } }));
    const duplicate: []const web.Resource = &.{
        .{ .path = "/a", .mime = "text/plain", .bytes = "a" },
        .{ .path = "/a", .mime = "text/plain", .bytes = "b" },
    };
    try std.testing.expectError(error.DuplicateResourcePath, view.attach(window, .{ .html = html, .user_data_folder = profile, .local = .{ .resources = duplicate } }));
    try std.testing.expectError(error.InvalidMime, view.attach(window, .{ .html = html, .user_data_folder = profile, .local = .{ .resources = &.{.{ .path = "/a", .mime = "text/plain\r\nInjected: true", .bytes = "a" }} } }));
    state.policy_window = window;
    state.options = .{
        .html = html,
        .user_data_folder = profile,
        .local = .{ .resources = resources, .on_resource = .{ .context = &state, .handle = State.resource } },
        .policy = .{ .navigation = .notify, .new_window = .notify, .download = .notify, .permission = .notify, .frame_navigation = .notify },
    };
    const seed_window = try app.createWindow(.{});
    state.capacity_window = try app.createWindow(.{});
    try seed_view.attach(seed_window, .{ .html = "<!doctype html><meta charset=utf-8>", .user_data_folder = profile });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) std.debug.print("policy timeout: ready={d} assets={d} dynamic={d} policy={any} permission={} network={} crash={} recover={}\n", .{ state.ready_count, state.asset_count, state.dynamic_count, state.policy_counts, state.permission_denied, state.network_denied, state.crash_requested, state.recover_requested });
    try std.testing.expect(!watchdog.expired and !state.failed);
    try std.testing.expectEqual(2, state.ready_count);
    try std.testing.expectEqual(2, state.asset_count);
    try std.testing.expectEqual(2, state.dynamic_count);
    try std.testing.expect(state.recover_requested);
    try std.testing.expect(state.seeded_allow);
    try std.testing.expect(state.capacity_failed_closed);
    const counts = web.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.states);
    try std.testing.expectEqual(@as(u32, 0), counts.handlers);
    try std.testing.expectEqual(@as(u32, 0), counts.controllers);
    std.debug.print("webview policy smoke passed: cached ALLOW reset + budget denial; embedded HTTPS + stack response; network/frame/navigation/popup/download/permission denial; browser crash + explicit/OOM recovery + queued close; COM=0\n", .{});
}
