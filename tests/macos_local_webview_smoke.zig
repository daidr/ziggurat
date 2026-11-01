const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);

/// Each document reports its path, its script, a resource read, a missing
/// resource, a read the default policy refuses (a header of the page's own),
/// a load its content security policy refuses and whether it is a secure
/// context.
const page_html =
    \\<!doctype html><title>local</title><script src="/app.js"></script><script>
    \\chrome.webview.addEventListener('message',e=>chrome.webview.postMessage('ack:'+e.data));
    \\addEventListener('DOMContentLoaded',async()=>{const r=[location.pathname,!!window.appLoaded];
    \\try{r.push(await (await fetch('/data.json')).text())}catch(e){r.push('read-failed')}
    \\try{r.push((await fetch('/missing')).status)}catch(e){r.push('missing-failed')}
    \\r.push(await fetch('/data.json',{headers:{'x-test':'1'}}).then(()=>'allowed',()=>'denied'));
    \\r.push(await fetch('https://example.com/').then(()=>'allowed',()=>'denied'));
    \\r.push(isSecureContext);
    \\chrome.webview.postMessage('boot:'+r.join(' '))});
    \\</script>
;
const resources = [_]web.Resource{
    .{ .path = "/app.js", .mime = "text/javascript", .bytes = "window.appLoaded=true" },
    .{ .path = "/data.json", .mime = "application/json", .bytes = "{\"ok\":1}" },
    .{ .path = "/second", .mime = "text/html", .bytes = page_html },
};
const registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true }};
const origin = "asset://app.ziggurat.invalid";

/// A local site through its life: the start document and its resources,
/// a local navigation, back and forward across documents, pushState and
/// back within one document, refresh, IPC both ways, and refusals.
const Probe = struct {
    app: *z.App,
    window: z.Window,
    view: web.View = undefined,
    err: ?anyerror = null,
    stage: u8 = 0,
    queued: bool = false,
    started: u32 = 0,
    completed: u32 = 0,
    boots: u32 = 0,
    sources: u32 = 0,
    acks: u32 = 0,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    generation: u64 = 0,
    boot: [256]u8 = undefined,
    boot_len: usize = 0,
    source: [256]u8 = undefined,
    source_len: usize = 0,

    fn fail(self: *@This(), err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("macOS local site stage={d} started={d} completed={d} boots={d} back={} forward={} boot={s} source={s}: {s}\n", .{ self.stage, self.started, self.completed, self.boots, self.can_go_back, self.can_go_forward, self.boot[0..self.boot_len], self.source[0..self.source_len], @errorName(err) });
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
                if (!std.mem.startsWith(u8, uri, origin ++ "/")) return self.fail(error.WrongStartUri);
            },
            .completed => |info| {
                self.completed += 1;
                if (!info.success) return self.fail(error.LoadFailed);
            },
            .source_changed => |info| {
                self.sources += 1;
                copy(&self.source, &self.source_len, info.uri orelse "") catch |err| return self.fail(err);
            },
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
        return std.mem.eql(u8, self.source[0..self.source_len], path) or
            (std.mem.startsWith(u8, self.source[0..self.source_len], origin) and std.mem.eql(u8, self.source[origin.len..self.source_len], path));
    }
    fn step(self: *@This()) !void {
        switch (self.stage) {
            0 => if (self.booted(1, "/")) {
                const text = self.boot[0..self.boot_len];
                std.debug.print("macOS local site: first document reports \"{s}\"\n", .{text});
                if (!std.mem.startsWith(u8, text, "/ true {\"ok\":1} 404 denied denied ")) return error.WrongSiteBehavior;
                if (!self.at("/")) return error.WrongSource;
                try std.testing.expectError(error.InvalidResourcePath, self.view.navigateLocal("/../escape"));
                try std.testing.expectError(error.NoHistory, self.view.goBack());
                self.stage = 1;
                try self.view.navigateLocal("/second");
                try std.testing.expectError(error.NavigationPending, self.view.navigateLocal("/second"));
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
                _ = try self.view.evaluateJS("history.pushState(null,'','/pushed');1", .{}, .{ .context = self, .complete = script });
            },
            4 => if (self.at("/pushed") and self.can_go_back) {
                self.stage = 5;
                try self.view.goBack();
            },
            5 => if (self.at("/second")) {
                // Within one document: no new start, page or boot.
                if (self.started != 4 or self.boots != 4 or self.view.pageId().?.generation != self.generation) return error.SameDocumentReplaced;
                self.stage = 6;
                try self.view.refresh();
            },
            6 => if (self.booted(5, "/second")) {
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

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app, .window = try app.createWindow(.{ .width = 320, .height = 240 }) };
    probe.view = web.View.init(allocator, &probe, Probe.event);
    const site: web.LocalSite = .{ .scheme = "asset", .scheme_ipc = true, .resources = &resources };
    // File streams are of the Linux backend.
    try std.testing.expectError(error.UnsupportedCapability, probe.view.attach(probe.window, .{ .html = page_html, .storage = .ephemeral, .custom_schemes = &registrations, .file_streams = .{}, .local = site }));
    try probe.view.attach(probe.window, .{ .html = page_html, .storage = .ephemeral, .custom_schemes = &registrations, .local = site, .page_listener = .{ .context = &probe, .event = Probe.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) probe.fail(error.Timeout);
    if (probe.err) |err| return err;
    try std.testing.expect(probe.stage == 8);
}

/// A site whose document and other paths come from the app's handler, with
/// grants beyond the default policy: a request header, POST with the site's
/// Origin, a response header, a deferred answer and a request left
/// unanswered.
const dynamic_html =
    \\<!doctype html><script>
    \\addEventListener('DOMContentLoaded',async()=>{const r=[];
    \\try{const a=await fetch('/api');r.push(a.status,await a.text(),a.headers.get('X-Answer'))}catch(e){r.push('api-failed')}
    \\r.push(await fetch('/api',{headers:{'X-Request-Policy':'yes'}}).then(x=>x.text(),()=>'denied'));
    \\r.push(await fetch('/api',{headers:{'X-Other':'1'}}).then(()=>'allowed',()=>'denied'));
    \\r.push(await fetch('/post',{method:'POST',body:'x'}).then(x=>x.text(),()=>'denied'));
    \\r.push(await fetch('/slow').then(x=>x.text(),()=>'denied'));
    \\r.push(await fetch('/nothing').then(x=>x.status,()=>'denied'));
    \\chrome.webview.postMessage(r.join(' '))});
    \\</script>
;
const dynamic_registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true, .request_origins = &.{origin} }};
const Dynamic = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    window: z.Window,
    view: web.View = undefined,
    err: ?anyerror = null,
    result: [256]u8 = undefined,
    result_len: usize = 0,
    slow: ?web.ResourceRequestId = null,
    documents: u32 = 0,
    fn fail(self: *@This(), err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("macOS dynamic site: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |text| {
                if (text.len > self.result.len) return self.fail(error.TooLong);
                @memcpy(self.result[0..text.len], text);
                self.result_len = text.len;
                _ = self.window.destroy() catch |err| return self.fail(err);
                self.app.quit();
            },
            .failed => self.fail(error.NativeFailure),
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
    }
    fn has(request: web.ResourceRequest, name: []const u8) bool {
        for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
        return false;
    }
    fn handle(ptr: *anyopaque, request: web.ResourceRequest, response: *web.Responder) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const answer = [_]web.resources.Header{.{ .name = "X-Answer", .value = "42" }};
        if (std.mem.eql(u8, request.path, "/document")) {
            self.documents += 1;
            response.respond(.{ .mime = "text/html", .bytes = dynamic_html }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/api")) {
            response.respond(.{ .mime = "text/plain", .headers = &answer, .bytes = if (has(request, "X-Request-Policy")) "granted" else "plain" }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/post")) {
            if (request.method != .post) return self.fail(error.WrongMethod);
            response.respond(.{ .mime = "text/plain", .bytes = "posted" }) catch |err| self.fail(err);
        } else if (std.mem.eql(u8, request.path, "/slow")) {
            self.slow = response.deferResponse(.{}) catch |err| return self.fail(err);
            self.app.post(.{ .context = self, .call = later }) catch |err| self.fail(err);
        }
        // Anything else stays unanswered and fails as a refused load.
    }
    fn later(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var owned = web.resources.OwnedResponse.init(self.allocator, .{ .mime = "text/plain", .bytes = "slow" }, 1024) catch |err| return self.fail(err);
        self.view.respondOwned(self.slow.?, &owned) catch |err| {
            owned.deinit();
            self.fail(err);
        };
    }
};
fn dynamic(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Dynamic = .{ .app = app, .allocator = allocator, .window = try app.createWindow(.{ .width = 320, .height = 240 }) };
    probe.view = web.View.init(allocator, &probe, Dynamic.event);
    try probe.view.attach(probe.window, .{ .html = "", .storage = .ephemeral, .custom_schemes = &dynamic_registrations, .local = .{
        .scheme = "asset",
        .start_path = "/document",
        .scheme_ipc = true,
        .dynamic_document = true,
        .methods = .{ .get = true, .head = true, .post = true },
        .request_headers = &.{.{ .name = "X-Request-Policy" }},
        .on_resource = .{ .context = &probe, .handle = Dynamic.handle },
    } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) probe.fail(error.Timeout);
    if (probe.err) |err| return err;
    const text = probe.result[0..probe.result_len];
    std.debug.print("macOS dynamic site reports \"{s}\"\n", .{text});
    try std.testing.expectEqualStrings("200 plain 42 granted denied posted slow denied", text);
    try std.testing.expectEqual(@as(u32, 1), probe.documents);
}

/// Engine completions of closed pages still arrive after close; waits for
/// them, the pages' native records and the site's budget to drain.
const Drain = struct {
    app: *z.App,
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const counts = web.resourceCounts();
        const local = web.customLocalResourceCounts();
        if (counts.states == 0 and counts.handlers == 0 and counts.controllers == 0 and local.streams == 0 and local.body_bytes == 0) return self.app.quit();
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (!web.backendCapabilities().page_lifecycle) return error.SkipZigTest;
    try run(allocator.allocator());
    try dynamic(allocator.allocator());
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
    std.debug.print("macOS local site: resources, policy refusals, local navigation, history across and within documents, refresh, IPC; app handler with grants, deferral and refusal; native records=0\n", .{});
}
