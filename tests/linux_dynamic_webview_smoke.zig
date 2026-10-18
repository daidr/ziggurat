const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn zwk_file_pread_count() u64;

const html =
    \\<!doctype html><script>addEventListener('DOMContentLoaded',async()=>{try{
    \\const a=await fetch('/immediate?q=1'); if(a.status!==201||a.headers.get('X-Test')!=='one'||await a.text()!=='immediate')throw Error('immediate');
    \\const b=await fetch('/deferred'); if(await b.text()!=='worker')throw Error('worker');
    \\const h=await fetch('/head',{method:'HEAD'}); if(h.headers.get('Content-Length')!=='14'||await h.text()!=='')throw Error('HEAD');
    \\const file=await fetch('/file');const data=new Uint8Array(await file.arrayBuffer());if(data.length!==524325||data[0]!==97||data[data.length-1]!==97)throw Error('file');
    \\const fh=await fetch('/file-head',{method:'HEAD'});if(fh.headers.get('Content-Length')!=='524325'||await fh.text()!=='')throw Error('file HEAD');
    \\let truncated=false;try{const r=await fetch('/file-truncated');await r.arrayBuffer()}catch{truncated=true}if(!truncated)throw Error('truncated file accepted');
    \\let cancelled=false;try{const r=await fetch('/file-unstarted');await r.arrayBuffer()}catch{cancelled=true}if(!cancelled)throw Error('unstarted pump cancellation');
    \\const n=await fetch('/missing'); if(n.status!==404)throw Error('404');
    \\for(const path of ['/timeout','/cancel']){let failed=false;try{await fetch(path)}catch{failed=true}if(!failed)throw Error(path)}
    \\chrome.webview.postMessage('done');
    \\}catch(e){chrome.webview.postMessage('error:'+e.message)}})</script>
;
const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    allocator: std.mem.Allocator,
    semaphore: std.Thread.Semaphore = .{},
    accepted: std.Thread.Semaphore = .{},
    stop_worker: std.atomic.Value(bool) = .init(false),
    worker_error: ?anyerror = null,
    owned: ?web.resources.OwnedResponse = null,
    file_response: ?web.OwnedFileResponse = null,
    ticket: ?web.StreamTicket = null,
    file_request: bool = false,
    file_head: bool = false,
    truncate_source: bool = false,
    skip_pump: bool = false,
    head_reads: u64 = 0,
    request: ?web.ResourceRequestId = null,
    err: ?anyerror = null,
    documents: u32 = 0,
    delivered: u32 = 0,
    timed_out: u32 = 0,
    cancelled: u32 = 0,
    messages: u32 = 0,
    closed: u32 = 0,
    fn fail(self: *@This(), err: anyerror) void {
        self.err = err;
        std.debug.print("dynamic WebView: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn close(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        std.debug.assert(self.view.window == null);
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |message| {
                if (!std.mem.eql(u8, message, "done")) {
                    std.debug.print("page: {s}\n", .{message});
                    return self.fail(error.PageAssertion);
                }
                self.messages += 1;
                self.app.quit();
            },
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn completion(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (result) {
            .responded => self.delivered += 1,
            .timed_out => self.timed_out += 1,
            .cancelled => self.cancelled += 1,
            else => self.fail(error.UnexpectedCompletion),
        }
    }
    fn handle(ptr: *anyopaque, request: web.ResourceRequest, response: *web.Responder) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.handleFallible(request, response) catch |err| self.fail(err);
    }
    fn handleFallible(self: *@This(), request: web.ResourceRequest, response: *web.Responder) !void {
        if (std.mem.eql(u8, request.path, "/document")) {
            self.documents += 1;
            return response.respond(.{ .mime = "text/html", .bytes = html });
        }
        if (std.mem.eql(u8, request.path, "/immediate")) {
            try std.testing.expect(std.mem.endsWith(u8, request.uri, "/immediate?q=1"));
            try response.respond(.{ .status = 201, .mime = "text/plain", .bytes = "immediate", .headers = &.{.{ .name = "X-Test", .value = "one" }} });
            return std.testing.expectError(error.AlreadyResponded, response.respond(.{}));
        }
        if (std.mem.eql(u8, request.path, "/head")) {
            try std.testing.expectEqual(web.resources.Method.head, request.method);
            return response.respond(.{ .mime = "text/plain", .bytes = "representation" });
        }
        if (std.mem.eql(u8, request.path, "/deferred") or std.mem.eql(u8, request.path, "/file") or std.mem.eql(u8, request.path, "/file-head") or std.mem.eql(u8, request.path, "/file-truncated") or std.mem.eql(u8, request.path, "/file-unstarted")) {
            self.file_request = !std.mem.eql(u8, request.path, "/deferred");
            self.file_head = std.mem.eql(u8, request.path, "/file-head");
            self.truncate_source = std.mem.eql(u8, request.path, "/file-truncated");
            self.skip_pump = std.mem.eql(u8, request.path, "/file-unstarted");
            self.request = try response.deferResponse(.{ .timeout_ms = 5000, .completion = .{ .context = self, .complete = completion } });
            try std.testing.expectError(error.AlreadyResponded, response.respond(.{}));
            self.semaphore.post();
        } else if (std.mem.eql(u8, request.path, "/timeout")) {
            _ = try response.deferResponse(.{ .timeout_ms = 5, .completion = .{ .context = self, .complete = completion } });
        } else if (std.mem.eql(u8, request.path, "/cancel")) {
            const id = try response.deferResponse(.{ .completion = .{ .context = self, .complete = completion } });
            try std.testing.expect(try id.cancel());
            try std.testing.expect(!try id.cancel());
        }
    }
    fn worker(self: *@This()) void {
        while (true) {
            self.semaphore.wait();
            if (self.stop_worker.load(.acquire)) return;
            if (self.file_request) {
                self.fileWorker() catch |err| {
                    self.worker_error = err;
                    self.app.post(.{ .context = self, .call = deliver }) catch {};
                };
            } else {
                self.owned = web.resources.OwnedResponse.init(self.allocator, .{ .mime = "text/plain", .bytes = "worker" }, 32) catch |err| blk: {
                    self.worker_error = err;
                    break :blk null;
                };
                self.app.post(.{ .context = self, .call = deliver }) catch |err| {
                    self.worker_error = err;
                    if (self.owned) |*owned| owned.deinit();
                    self.owned = null;
                };
            }
        }
    }
    fn fileWorker(self: *@This()) !void {
        const head = self.file_head;
        const truncate_source = self.truncate_source;
        const skip_pump = self.skip_pump;
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        const file = try directory.dir.createFile("private-response", .{ .read = true });
        defer file.close();
        const block: [4096]u8 = @splat('a');
        for (0..128) |_| try file.writeAll(&block);
        try file.writeAll(block[0..37]);
        const original_position = try file.getPos();
        const reads = zwk_file_pread_count();
        var prepared = try web.OwnedFileResponse.preparePumped(self.allocator, self.app.owner, file, .{ .mime = "application/octet-stream" }, 1024 * 1024);
        defer prepared.pump.deinit();
        if (truncate_source) try file.setEndPos(1);
        self.file_response = prepared.response;
        self.app.post(.{ .context = self, .call = deliver }) catch |err| {
            self.file_response.?.deinit();
            self.file_response = null;
            return err;
        };
        if (skip_pump) {
            self.accepted.wait();
            return;
        }
        prepared.pump.pump() catch |err| {
            if (!(head and err == error.Cancelled) and !(truncate_source and err == error.FileSourceChanged)) return err;
        };
        try std.testing.expectEqual(original_position, try file.getPos());
        if (head) self.head_reads = zwk_file_pread_count() - reads;
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.worker_error) |err| return self.fail(err);
        if (self.file_request) {
            if (self.ticket) |*ticket| ticket.deinit();
            self.ticket = self.view.respondFile(self.request.?, &self.file_response.?, .{ .ticket = true }) catch |err| {
                self.file_response.?.deinit();
                if (self.skip_pump) self.accepted.post();
                return self.fail(err);
            };
            if (self.file_response.?.native != null or self.file_response.?.metadata.storage != null) return self.fail(error.ResponseNotConsumed);
            if (self.skip_pump) self.accepted.post();
            return;
        }
        const owned = &self.owned.?;
        self.view.respondOwned(self.request.?, owned) catch |err| return self.fail(err);
        if (owned.storage != null) return self.fail(error.ResponseNotConsumed);
        std.testing.expectError(error.ResponseMoved, self.view.respondOwned(self.request.?, owned)) catch |err| self.fail(err);
    }
};
const Drain = struct {
    app: *z.App,
    timer: c_uint = 0,
    fn tick(ptr: *anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const native = web.resourceCounts();
        const local = web.customLocalResourceCounts();
        if (native.states != 0 or native.handlers != 0 or native.controllers != 0 or local.budgets != 0 or local.streams != 0 or local.body_bytes != 0 or web.deferredResourceCount() != 0) return 1;
        self.timer = 0;
        self.app.quit();
        return 0;
    }
};
fn closeFromResource(allocator: std.mem.Allocator, defer_first: bool) !void {
    const Result = struct { calls: u32 = 0, closed: u32 = 0, detached: u32 = 0, err: ?anyerror = null };
    const Host = struct {
        app: *z.App,
        allocator: std.mem.Allocator,
        result: *Result,
        window: z.Window = undefined,
        view: web.View = undefined,
        defer_first: bool,
        fn completion(ptr: *anyopaque, result: web.resources.Result) void {
            const result_out: *Result = @ptrCast(@alignCast(ptr));
            if (result != .detached) result_out.err = error.WrongCloseCompletion;
            result_out.detached += 1;
        }
        fn resource(ptr: *anyopaque, _: web.ResourceRequest, responder: *web.Responder) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.result.calls += 1;
            if (self.defer_first) {
                _ = responder.deferResponse(.{ .completion = .{ .context = self.result, .complete = completion } }) catch |err| {
                    self.result.err = err;
                    self.app.quit();
                    return;
                };
            }
            self.app.quit();
        }
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {}
        fn close(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.view.window == null and self.view.config == null);
            self.result.closed += 1;
            self.allocator.destroy(self);
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var result: Result = .{};
    const host = try allocator.create(Host);
    host.* = .{ .app = app, .allocator = allocator, .result = &result, .defer_first = defer_first };
    host.view = web.View.init(allocator, host, Host.event);
    host.window = app.createWindow(.{ .on_closed = .{ .context = host, .notify = Host.close } }) catch |err| {
        allocator.destroy(host);
        return err;
    };
    try host.view.attach(host.window, .{ .html = "", .storage = .ephemeral, .local = .{ .scheme = "asset", .dynamic_document = true, .request_headers = &.{.{ .name = "X-Request-Policy" }}, .on_resource = .{ .context = host, .handle = Host.resource } }, .custom_schemes = &.{.{ .name = "asset", .request_origins = &.{"asset://app.ziggurat.invalid"} }} });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (watchdog.expired) return error.CloseDeadline;
    if (result.err) |err| return err;
    try std.testing.expectEqual(@as(u32, 1), result.calls);
    try std.testing.expectEqual(@as(u32, 1), result.closed);
    try std.testing.expectEqual(@as(u32, if (defer_first) 1 else 0), result.detached);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    try @import("linux_custom_request_oracle.zig").run(allocator);
    try @import("linux_custom_request_lifecycle.zig").run(allocator);
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var probe: Probe = .{ .app = app, .allocator = allocator };
        probe.window = try app.createWindow(.{ .width = 320, .height = 200, .on_closed = .{ .context = &probe, .notify = Probe.close } });
        probe.view = web.View.init(allocator, &probe, Probe.event);
        var worker: ?std.Thread = try std.Thread.spawn(.{}, Probe.worker, .{&probe});
        defer {
            probe.stop_worker.store(true, .release);
            probe.semaphore.post();
            probe.accepted.post();
            if (worker) |thread| thread.join();
            if (probe.owned) |*owned| owned.deinit();
            if (probe.file_response) |*response| response.deinit();
            if (probe.ticket) |*ticket| ticket.deinit();
        }
        try probe.view.attach(probe.window, .{ .html = "", .storage = .ephemeral, .file_streams = .{ .max_file_bytes = 1024 * 1024 }, .local = .{ .scheme = "asset", .host = "app.ziggurat.invalid", .start_path = "/document", .scheme_ipc = true, .dynamic_document = true, .request_headers = &.{.{ .name = "X-Request-Policy" }}, .on_resource = .{ .context = &probe, .handle = Probe.handle } }, .custom_schemes = &.{.{ .name = "asset", .treat_as_secure = true, .request_origins = &.{"asset://app.ziggurat.invalid"} }} });
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        probe.stop_worker.store(true, .release);
        probe.semaphore.post();
        worker.?.join();
        worker = null;
        if (watchdog.expired) return error.DeadlineExceeded;
        if (probe.err) |err| return err;
        if (probe.worker_error) |err| return err;
        try std.testing.expectEqual(@as(u32, 1), probe.documents);
        try std.testing.expectEqual(@as(u32, 1), probe.messages);
        try std.testing.expectEqual(@as(u32, 5), probe.delivered);
        try std.testing.expectEqual(@as(u32, 1), probe.timed_out);
        try std.testing.expectEqual(@as(u32, 1), probe.cancelled);
        try std.testing.expectEqual(@as(u32, 1), probe.closed);
        try std.testing.expectEqual(@as(u64, 0), probe.head_reads);
        // EOF and browser completion happen before the next request, but the
        // explicit worker's final cleanup is joined only after the UI loop.
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    try closeFromResource(allocator, false);
    try closeFromResource(allocator, true);
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        _ = try app.createWindow(.{});
        var drain: Drain = .{ .app = app };
        drain.timer = g_timeout_add(1, Drain.tick, &drain);
        defer {
            if (drain.timer != 0) _ = g_source_remove(drain.timer);
        }
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        const native = web.resourceCounts();
        const local = web.customLocalResourceCounts();
        const files = web.fileResourceCounts();
        if (watchdog.expired or native.states != 0 or native.handlers != 0 or native.controllers != 0 or local.budgets != 0 or local.streams != 0 or local.body_bytes != 0 or files.streams != 0 or files.controls != 0 or files.budgets != 0 or web.deferredResourceCount() != 0) {
            std.debug.print("late resources native={any} local={any} files={any} pending={d}\n", .{ native, local, files, web.deferredResourceCount() });
            return error.LateResourcesDidNotDrain;
        }
    }
    std.debug.print("dynamic WebView: explicit worker/post, private file GET/HEAD, truncated stream rejection, accepted unstarted-pump cancellation, timeout/404, resources=0\n", .{});
}
