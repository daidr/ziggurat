const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_container_get_children(*anyopaque) ?*NativeList;
extern fn g_list_free(?*NativeList) void;
extern fn g_type_name_from_instance(*anyopaque) [*:0]const u8;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
extern fn g_signal_connect_data(*anyopaque, [*:0]const u8, *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void, *anyopaque, ?*anyopaque, c_uint) c_ulong;
extern fn g_signal_handler_disconnect(*anyopaque, c_ulong) void;
extern fn g_signal_handler_is_connected(*anyopaque, c_ulong) c_int;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
extern fn webkit_web_view_is_loading(*anyopaque) c_int;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
const NativeList = extern struct { data: ?*anyopaque, next: ?*NativeList, previous: ?*NativeList };

fn nativeView(window: z.Window) !*anyopaque {
    const overlay = gtk_bin_get_child(window.nativeHandle().?) orelse return error.MissingContentHost;
    const children = gtk_container_get_children(overlay);
    defer g_list_free(children);
    var cursor = children;
    while (cursor) |item| : (cursor = item.next) {
        const child = item.data orelse continue;
        if (std.mem.eql(u8, std.mem.span(g_type_name_from_instance(child)), "WebKitWebView")) return child;
    }
    return error.MissingNativeView;
}

const registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true }};
const html =
    \\<!doctype html><script>
    \\chrome.webview.addEventListener('message',e=>chrome.webview.postMessage('ack:'+e.data));
    \\addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('boot:'+location.pathname+location.search+location.hash));
    \\addEventListener('popstate',()=>chrome.webview.postMessage('pop:'+location.pathname+location.search+location.hash));
    \\</script>
;
const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    err: ?anyerror = null,
    stage: u8 = 0,
    queued: bool = false,
    echo_sent: bool = false,
    echo_done: bool = false,
    script_done: bool = false,
    ready: u32 = 0,
    started: u32 = 0,
    completed: u32 = 0,
    boots: u32 = 0,
    closed: u32 = 0,
    histories: u32 = 0,
    denied: u32 = 0,
    forbidden_requests: u32 = 0,
    cancelled: u32 = 0,
    request: ?web.ResourceRequestId = null,
    stop_on_completion: bool = false,
    old: ?web.PageId = null,
    current_generation: u64 = 0,
    fault: *std.testing.FailingAllocator,
    native: *anyopaque = undefined,
    pop: [5000]u8 = undefined,
    pop_len: usize = 0,
    source: [5000]u8 = undefined,
    source_len: usize = 0,
    boot: [5000]u8 = undefined,
    boot_len: usize = 0,

    fn loading(_: *anyopaque, _: *anyopaque, ptr: *anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.enqueue();
    }

    fn fail(self: *@This(), err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("navigation stage={d} started={d} complete={d} boots={d} source={s}: {s}\n", .{ self.stage, self.started, self.completed, self.boots, self.source[0..self.source_len], @errorName(err) });
        self.app.quit();
    }
    fn enqueue(self: *@This()) void {
        if (self.queued or self.err != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        std.debug.assert(self.view.window == null);
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .started => self.started += 1,
            .completed => |info| {
                self.completed += 1;
                if (!info.success) return self.fail(error.LoadFailed);
            },
            .source_changed => |info| if (info.uri) |uri| {
                if (uri.len > self.source.len) return self.fail(error.UriTooLong);
                @memcpy(self.source[0..uri.len], uri);
                self.source_len = uri.len;
            },
            .history_changed => self.histories += 1,
            else => {},
        }
        self.enqueue();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => self.ready += 1,
            .message => |message| {
                if (std.mem.startsWith(u8, message, "boot:")) {
                    const uri = message[5..];
                    if (uri.len > self.boot.len) return self.fail(error.UriTooLong);
                    @memcpy(self.boot[0..uri.len], uri);
                    self.boot_len = uri.len;
                    self.boots += 1;
                } else if (std.mem.startsWith(u8, message, "pop:")) {
                    const uri = message[4..];
                    if (uri.len > self.pop.len) return self.fail(error.UriTooLong);
                    @memcpy(self.pop[0..uri.len], uri);
                    self.pop_len = uri.len;
                } else if (std.mem.eql(u8, message, "ack:ping")) {
                    if (!self.echo_sent or self.echo_done) return self.fail(error.DuplicateEcho);
                    self.echo_done = true;
                } else return self.fail(error.UnexpectedMessage);
            },
            .policy_request => |info| {
                if (info.kind != .navigation) return self.fail(error.UnexpectedPolicy);
                self.denied += 1;
            },
            .failed, .process_failed => return self.fail(error.NativeFailure),
            else => {},
        }
        self.enqueue();
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, response: *web.Responder) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, request.path, "/slow")) {
            self.request = response.deferResponse(.{ .completion = .{ .context = self, .complete = completion } }) catch |err| {
                self.fail(err);
                return;
            };
            self.enqueue();
        } else {
            if (std.mem.eql(u8, request.path, "/forbidden")) self.forbidden_requests += 1;
            response.respond(.{ .mime = "text/html", .bytes = html }) catch |err| self.fail(err);
        }
    }
    fn completion(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .page_changed or !self.stop_on_completion) return self.fail(error.WrongResourceCompletion);
        self.cancelled += 1;
        self.view.stop() catch |err| self.fail(err);
    }
    fn script(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        self.script_done = true;
        self.enqueue();
    }
    fn evaluate(self: *@This(), text: []const u8) !void {
        self.script_done = false;
        _ = try self.view.evaluateJS(text, .{}, .{ .context = self, .complete = script });
    }
    fn next(self: *@This(), stage: u8) void {
        self.stage = stage;
        self.echo_sent = false;
        self.echo_done = false;
    }
    fn full(self: *@This(), count: u32, path: []const u8) bool {
        return self.completed == count and self.boots == count and std.mem.eql(u8, self.boot[0..self.boot_len], path);
    }
    fn at(self: *@This(), path: []const u8) bool {
        return std.mem.endsWith(u8, self.source[0..self.source_len], path);
    }
    fn echo(self: *@This()) !bool {
        if (!self.echo_sent) {
            self.echo_sent = true;
            try self.view.postFor(self.view.pageId() orelse return error.NoPage, "ping");
        }
        return self.echo_done;
    }
    fn sameDocument(self: *@This(), count: u32) !void {
        try std.testing.expectEqual(count, self.started);
        try std.testing.expectEqual(count, self.boots);
        try std.testing.expectEqual(self.current_generation, self.view.pageId().?.generation);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.advanceInner() catch |err| self.fail(err);
    }
    fn advanceInner(self: *@This()) !void {
        switch (self.stage) {
            0 => {
                if (!self.full(1, "/a")) return;
                if (!try self.echo()) return;
                try std.testing.expectError(error.NoHistory, self.view.goBack());
                try std.testing.expectError(error.NoHistory, self.view.goForward());
                try std.testing.expectError(error.InvalidResourcePath, self.view.navigateLocal("/../bad"));
                const before = self.view.pageId().?;
                self.fault.fail_index = self.fault.alloc_index;
                try std.testing.expectError(error.OutOfMemory, self.view.navigateLocal("/allocation-failure"));
                self.fault.fail_index = std.math.maxInt(usize);
                try std.testing.expectEqual(before.generation, self.view.pageId().?.generation);
                try std.testing.expectEqual(1, self.started);
                self.old = self.view.pageId();
                self.next(1);
                try self.view.navigateLocal("/b");
                try std.testing.expectError(error.NavigationPending, self.view.navigateLocal("/another"));
                try std.testing.expectError(error.NavigationPending, self.view.goBack());
            },
            1 => {
                if (!self.full(2, "/b")) return;
                if (!try self.echo()) return;
                try std.testing.expectError(error.StalePage, self.view.postFor(self.old.?, "stale"));
                self.current_generation = self.view.pageId().?.generation;
                self.next(2);
                try self.evaluate("history.pushState({},'', '/b-one');history.pushState({},'', '/b-two?query=1#fragment');null");
            },
            2 => {
                if (!self.script_done or !self.at("/b-two?query=1#fragment")) return;
                try self.sameDocument(2);
                if (!try self.echo()) return;
                self.next(13);
                try self.evaluate("history.back();null");
            },
            3 => {
                if (!self.at("/b-one")) return;
                try self.sameDocument(2);
                if (!try self.echo()) return;
                self.next(4);
                try self.view.goForward();
            },
            4 => {
                if (!self.at("/b-two?query=1#fragment")) return;
                try self.sameDocument(2);
                if (!try self.echo()) return;
                self.old = self.view.pageId();
                self.next(5);
                try self.view.refresh();
            },
            5 => {
                if (!self.full(3, "/b-two?query=1#fragment")) return;
                if (!try self.echo()) return;
                try std.testing.expectError(error.StalePage, self.view.postFor(self.old.?, "stale-refresh"));
                self.current_generation = self.view.pageId().?.generation;
                self.next(6);
                try self.view.goBack();
            },
            6 => {
                if (!self.at("/b-one")) return;
                try self.sameDocument(3);
                if (!try self.echo()) return;
                self.next(7);
                try self.view.goBack();
            },
            7 => {
                if (!self.at("/b")) return;
                try self.sameDocument(3);
                if (!try self.echo()) return;
                self.next(8);
                try self.view.goBack();
            },
            8 => {
                if (!self.full(4, "/a")) return;
                if (!try self.echo()) return;
                self.next(9);
                try self.view.goForward();
            },
            9 => {
                if (!self.full(5, "/b")) return;
                if (!try self.echo()) return;
                self.current_generation = self.view.pageId().?.generation;
                self.next(10);
                try self.evaluate("location.href='/forbidden';null");
            },
            10 => {
                if (!self.script_done or self.denied != 1) return;
                try self.sameDocument(5);
                try std.testing.expectEqual(0, self.forbidden_requests);
                if (!try self.echo()) return;
                self.next(11);
                try self.evaluate("void fetch('/slow').catch(()=>{});null");
            },
            11 => {
                if (self.request == null or !self.script_done) return;
                self.stop_on_completion = true;
                try std.testing.expectError(error.NavigationCancelled, self.view.navigateLocal("/cancelled"));
                try std.testing.expectEqual(1, self.cancelled);
                try std.testing.expectEqual(5, self.started);
                try std.testing.expectEqual(self.current_generation, self.view.page_generation);
                try std.testing.expect(self.view.pageId() == null);
                try std.testing.expectEqual(0, web.deferredResourceCount());
                self.next(12);
                try self.view.navigateLocal("/after-stop");
            },
            12 => {
                if (!self.full(6, "/after-stop")) return;
                if (!try self.echo()) return;
                try std.testing.expect(self.histories >= 8);
                self.app.quit();
            },
            13 => {
                if (!self.script_done or webkit_web_view_is_loading(self.native) != 0 or !std.mem.eql(u8, self.pop[0..self.pop_len], "/b-one")) return;
                try std.testing.expect(self.at("/b-one"));
                try self.sameDocument(2);
                if (!try self.echo()) return;
                self.next(14);
                try self.evaluate("history.forward();null");
            },
            14 => {
                if (!self.script_done or webkit_web_view_is_loading(self.native) != 0 or !std.mem.eql(u8, self.pop[0..self.pop_len], "/b-two?query=1#fragment")) return;
                try std.testing.expect(self.at("/b-two?query=1#fragment"));
                try self.sameDocument(2);
                if (!try self.echo()) return;
                self.next(3);
                try self.view.goBack();
                try std.testing.expectError(error.NavigationPending, self.view.goForward());
            },
            else => unreachable,
        }
    }
};

fn navigation(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var fault = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
    var state: Probe = .{ .app = app, .fault = &fault };
    state.window = try app.createWindow(.{ .on_closed = .{ .context = &state, .notify = Probe.onClosed } });
    state.view = web.View.init(fault.allocator(), &state, Probe.event);
    try state.view.attach(state.window, .{
        .storage = .ephemeral,
        .html = "",
        .custom_schemes = &registrations,
        .local = .{ .scheme = "asset", .scheme_ipc = true, .start_path = "/a", .dynamic_document = true, .on_resource = .{ .context = &state, .handle = Probe.resource } },
        .page_listener = .{ .context = &state, .event = Probe.page },
        .policy = .{ .navigation = .notify },
    });
    state.native = g_object_ref(try nativeView(state.window));
    defer g_object_unref(state.native);
    const signal = g_signal_connect_data(state.native, "notify::is-loading", Probe.loading, &state, null, 0);
    defer if (g_signal_handler_is_connected(state.native, signal) != 0) g_signal_handler_disconnect(state.native, signal);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.err) |err| return err;
    try std.testing.expect(!watchdog.expired and state.stage == 12 and state.closed == 1 and state.ready == 1);
    try std.testing.expectEqual(6, state.started);
    try std.testing.expectEqual(6, state.completed);
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
}

// A prepared, immediately stopped full load has revoked the old private
// transport even when the engine has not yet dispatched LOAD_STARTED.
const StopProbe = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    err: ?anyerror = null,
    stage: u8 = 0,
    started: u32 = 0,
    completed: u32 = 0,
    echoes: u32 = 0,
    queued: bool = false,
    script_done: bool = false,
    native: *anyopaque = undefined,
    inject_started: bool,
    failures: u32 = 0,
    fn loading(view: *anyopaque, _: *anyopaque, ptr: *anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.stage == 2 and webkit_web_view_is_loading(view) == 0) self.enqueue();
    }
    fn fail(self: *@This(), err: anyerror) void {
        self.err = err;
        std.debug.print("stop-before-start stage={d}: {s}\n", .{ self.stage, @errorName(err) });
        self.app.quit();
    }
    fn enqueue(self: *@This()) void {
        if (self.queued or self.err != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .started => self.started += 1,
            .completed => |info| {
                if (!info.success) return self.fail(error.LoadFailed);
                self.completed += 1;
            },
            else => {},
        }
        self.enqueue();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .failed => {
                if (!self.inject_started or self.stage != 1) return self.fail(error.NativeFailure);
                self.failures += 1;
                const failure = self.view.nativeFailure() orelse return self.fail(error.MissingFailureDomain);
                if (failure != .glib or failure.glib.domain == 0 or failure.glib.code != 3) return self.fail(error.WrongFailureDomain);
            },
            .process_failed => return self.fail(error.NativeFailure),
            .message => |message| if (std.mem.eql(u8, message, "ack:ping")) {
                self.echoes += 1;
            },
            else => {},
        }
        self.enqueue();
    }
    fn script(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        self.script_done = true;
        self.enqueue();
    }
    fn advance(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.advanceInner() catch |err| self.fail(err);
    }
    fn advanceInner(self: *@This()) !void {
        switch (self.stage) {
            0 => {
                if (self.completed != 1) return;
                self.stage = 1;
                _ = try self.view.evaluateJS("history.pushState({},'', '/same-one');history.pushState({},'', '/same-two');null", .{}, .{ .context = self, .complete = script });
            },
            1 => {
                if (!self.script_done) return;
                const id = self.view.pageId().?;
                if (self.inject_started) {
                    // A full-load signal with no current authorized transaction
                    // must revoke the old page instead of reusing its scripts.
                    g_signal_emit_by_name(self.native, "load-changed", @as(c_int, 0));
                    try std.testing.expectEqual(1, self.failures);
                } else {
                    try self.view.navigateLocal("/stopped-before-start");
                    try self.view.stop();
                }
                try std.testing.expectEqual(1, self.started);
                try std.testing.expectEqual(id.generation, self.view.page_generation);
                try std.testing.expect(self.view.pageId() == null);
                try std.testing.expectError(error.NotReady, self.view.evaluateJS("42", .{}, .{ .context = self, .complete = script }));
                try std.testing.expectError(error.StalePage, self.view.postFor(id, "old"));
                self.stage = 2;
                self.script_done = false;
                self.enqueue();
            },
            2 => {
                // This is the actual native settled notification, not a timer
                // or a fixed number of event-loop turns after stop().
                if (webkit_web_view_is_loading(self.native) != 0) return;
                // An old same-DOM item cannot restore scripts/IPC that full
                // preparation already revoked. Only an explicit full load can.
                try std.testing.expectError(error.NotReady, self.view.goBack());
                try std.testing.expectError(error.NotReady, self.view.goForward());
                self.stage = 3;
                if (self.inject_started) try self.view.recover() else try self.view.navigateLocal("/restored");
            },
            3 => {
                if (self.completed != 2) return;
                self.stage = 4;
                _ = try self.view.evaluateJS("location.pathname", .{}, .{ .context = self, .complete = script });
                try self.view.postFor(self.view.pageId().?, "ping");
            },
            4 => {
                if (!self.script_done or self.echoes != 1) return;
                self.app.quit();
            },
            else => unreachable,
        }
    }
};

fn stoppedBeforeStarted(allocator: std.mem.Allocator, inject_started: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: StopProbe = .{ .app = app, .inject_started = inject_started };
    state.window = try app.createWindow(.{});
    state.view = web.View.init(allocator, &state, StopProbe.event);
    try state.view.attach(state.window, .{
        .storage = .ephemeral,
        .html = html,
        .custom_schemes = &registrations,
        .local = .{ .scheme = "asset", .scheme_ipc = true, .resources = &.{.{ .path = "/restored", .mime = "text/html", .bytes = html }} },
        .page_listener = .{ .context = &state, .event = StopProbe.page },
    });
    state.native = g_object_ref(try nativeView(state.window));
    defer g_object_unref(state.native);
    const signal = g_signal_connect_data(state.native, "notify::is-loading", StopProbe.loading, &state, null, 0);
    defer if (g_signal_handler_is_connected(state.native, signal) != 0) g_signal_handler_disconnect(state.native, signal);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.err) |err| return err;
    try std.testing.expect(!watchdog.expired and state.stage == 4 and state.started == 2);
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
}

const ClosingMode = enum { completion_destroy, completion_raw, allocator_destroy };
const ClosingResult = struct {
    app: *z.App,
    err: ?anyerror = null,
    closed: u32 = 0,
    completion_calls: u32 = 0,
    started: u32 = 0,
    returned: bool = false,
    timer: c_uint = 0,
    fn drain(ptr: *anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const native = web.resourceCounts();
        if (self.closed == 0 or native.states != 0 or native.handlers != 0 or native.controllers != 0) return 1;
        self.timer = 0;
        self.app.quit();
        return 0;
    }
};
const ClosingAllocator = struct {
    base: std.mem.Allocator,
    window: z.Window = undefined,
    armed: bool = false,
    fired: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const result = self.base.rawAlloc(len, alignment, ret);
        if (self.armed) {
            self.armed = false;
            self.fired = true;
            _ = self.window.destroy() catch unreachable;
        }
        return result;
    }
    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.base.rawResize(memory, alignment, len, ret);
    }
    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.base.rawRemap(memory, alignment, len, ret);
    }
    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.base.rawFree(memory, alignment, ret);
    }
};
const ClosingHost = struct {
    allocator: std.mem.Allocator,
    view_allocator: *ClosingAllocator,
    out: *ClosingResult,
    mode: ClosingMode,
    window: z.Window = undefined,
    view: web.View = undefined,
    queued: bool = false,
    fn fail(self: *@This(), err: anyerror) void {
        self.out.err = err;
        self.out.app.quit();
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.view.window == null);
        self.out.closed += 1;
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (value == .failed or value == .process_failed) self.fail(error.NativeFailure);
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (value == .started) self.out.started += 1;
        if (value != .completed) return;
        if (!value.completed.success) return self.fail(error.LoadFailed);
        if (self.mode == .allocator_destroy) self.enqueue() else {
            _ = self.view.evaluateJS("void fetch('/slow').catch(()=>{});null", .{}, .{ .context = self.out, .complete = script }) catch |err| self.fail(err);
        }
    }
    fn script(ptr: *anyopaque, result: web.ScriptResult) void {
        const out: *ClosingResult = @ptrCast(@alignCast(ptr));
        if (result != .json and result != .page_changed and result != .detached) {
            out.err = error.UnexpectedScriptResult;
            out.app.quit();
        }
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, response: *web.Responder) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, request.path, "/slow")) {
            _ = response.deferResponse(.{ .completion = .{ .context = self, .complete = complete } }) catch |err| return self.fail(err);
            self.enqueue();
        } else response.respond(.{ .mime = "text/html", .bytes = html }) catch |err| self.fail(err);
    }
    fn complete(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.out.completion_calls += 1;
        if (result != .page_changed) return self.fail(error.WrongCloseCompletion);
        if (self.mode == .completion_raw) gtk_widget_destroy(self.window.nativeHandle().?) else {
            _ = self.window.destroy() catch |err| return self.fail(err);
        }
        // The callback, native transaction and public API all still borrow us.
        std.debug.assert(self.view.config != null and self.out.closed == 0);
    }
    fn enqueue(self: *@This()) void {
        if (self.queued) return;
        self.queued = true;
        self.out.app.post(.{ .context = self, .call = navigate }) catch |err| self.fail(err);
    }
    fn navigate(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const out = self.out;
        const mode = self.mode;
        if (mode == .allocator_destroy) self.view_allocator.armed = true;
        self.view.navigateLocal("/closing") catch |err| {
            if (err != error.Closed and (mode == .allocator_destroy or err != error.NavigationCancelled)) out.err = err;
            out.returned = true;
            return;
        };
        out.err = error.ClosedNavigationAccepted;
        out.returned = true;
        out.app.quit();
    }
};

fn closingNavigation(allocator: std.mem.Allocator, mode: ClosingMode) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    // Keep dispatching until late native async cancellation has actually ended.
    _ = try app.createWindow(.{});
    var result: ClosingResult = .{ .app = app };
    var fault: ClosingAllocator = .{ .base = allocator };
    const host = try allocator.create(ClosingHost);
    host.* = .{ .allocator = allocator, .view_allocator = &fault, .out = &result, .mode = mode };
    host.window = try app.createWindow(.{ .on_closed = .{ .context = host, .notify = ClosingHost.closed } });
    fault.window = host.window;
    host.view = web.View.init(fault.allocator(), host, ClosingHost.event);
    try host.view.attach(host.window, .{
        .html = "",
        .storage = .ephemeral,
        .custom_schemes = &registrations,
        .local = .{ .scheme = "asset", .scheme_ipc = true, .dynamic_document = true, .on_resource = .{ .context = host, .handle = ClosingHost.resource } },
        .page_listener = .{ .context = host, .event = ClosingHost.page },
    });
    result.timer = g_timeout_add(5, ClosingResult.drain, &result);
    defer {
        if (result.timer != 0) _ = g_source_remove(result.timer);
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (result.err) |err| return err;
    try std.testing.expect(!watchdog.expired and result.closed == 1 and result.returned);
    try std.testing.expectEqual(1, result.started);
    try std.testing.expectEqual(@as(u32, if (mode == .allocator_destroy) 0 else 1), result.completion_calls);
    try std.testing.expectEqual(mode == .allocator_destroy, fault.fired);
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try navigation(gpa.allocator());
    try stoppedBeforeStarted(gpa.allocator(), false);
    try stoppedBeforeStarted(gpa.allocator(), true);
    for (std.enums.values(ClosingMode)) |mode| try closingNavigation(gpa.allocator(), mode);
    const counts = web.resourceCounts();
    const local = web.customLocalResourceCounts();
    try std.testing.expect(counts.states == 0 and counts.handlers == 0 and counts.controllers == 0);
    try std.testing.expect(local.budgets == 0 and local.streams == 0 and local.body_bytes == 0);
    std.debug.print("Linux navigation: host local/back/forward/current refresh, same-DOM PageId+IPC, denied script, stop during private invalidation; native resources=0\n", .{});
}
