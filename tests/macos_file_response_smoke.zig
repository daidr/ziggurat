//! A local site answers with private files on macOS: a worker prepares each
//! file and pumps it after the View accepts the response. The page reads a
//! whole file, its HEAD (which reads nothing), a file cut short while it is
//! sent, and one whose pump never starts and is cancelled when released.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_file_pread_count() u64;
extern fn zwk_file_counts(*u32, *u32, *u32, *u32) void;

const html =
    \\<!doctype html><script>addEventListener('DOMContentLoaded',async()=>{try{
    \\chrome.webview.postMessage('step:file');const file=await fetch('/file');chrome.webview.postMessage('step:file-head '+file.status);const data=new Uint8Array(await file.arrayBuffer());if(file.headers.get('X-File')!=='yes'||data.length!==524325||data[0]!==97||data[data.length-1]!==97)throw Error('file '+data.length);
    \\chrome.webview.postMessage('step:head');const fh=await fetch('/file-head',{method:'HEAD'});chrome.webview.postMessage('step:truncated');if(fh.headers.get('Content-Length')!=='524325'||await fh.text()!=='')throw Error('file HEAD');
    \\let truncated=false;try{const r=await fetch('/file-truncated');await r.arrayBuffer()}catch{truncated=true}if(!truncated)throw Error('truncated file accepted');
    \\chrome.webview.postMessage('step:unstarted');let cancelled=false;try{const r=await fetch('/file-unstarted');await r.arrayBuffer()}catch{cancelled=true}if(!cancelled)throw Error('unstarted pump cancellation');
    \\chrome.webview.postMessage('done');
    \\}catch(e){chrome.webview.postMessage('error:'+e.message)}})</script>
;
const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    allocator: std.mem.Allocator,
    semaphore: zio.Semaphore = .{},
    accepted: zio.Semaphore = .{},
    stop_worker: std.atomic.Value(bool) = .init(false),
    worker_error: ?anyerror = null,
    file_response: ?web.OwnedFileResponse = null,
    ticket: ?web.StreamTicket = null,
    file_head: bool = false,
    truncate_source: bool = false,
    skip_pump: bool = false,
    head_reads: u64 = 0,
    request: ?web.ResourceRequestId = null,
    err: ?anyerror = null,
    documents: u32 = 0,
    delivered: u32 = 0,
    messages: u32 = 0,
    fn fail(self: *@This(), err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("macOS file responses: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |message| {
                if (std.mem.startsWith(u8, message, "step:")) return std.debug.print("page {s} delivered={d}\n", .{ message, self.delivered });
                if (!std.mem.eql(u8, message, "done")) {
                    std.debug.print("page: {s}\n", .{message});
                    return self.fail(error.PageAssertion);
                }
                self.messages += 1;
                _ = self.window.destroy() catch |err| return self.fail(err);
                self.app.quit();
            },
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn completion(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .responded) return self.fail(error.UnexpectedCompletion);
        self.delivered += 1;
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
        if (std.mem.eql(u8, request.path, "/file") or std.mem.eql(u8, request.path, "/file-head") or std.mem.eql(u8, request.path, "/file-truncated") or std.mem.eql(u8, request.path, "/file-unstarted")) {
            self.file_head = std.mem.eql(u8, request.path, "/file-head");
            if (self.file_head) try std.testing.expectEqual(web.resources.Method.head, request.method);
            self.truncate_source = std.mem.eql(u8, request.path, "/file-truncated");
            self.skip_pump = std.mem.eql(u8, request.path, "/file-unstarted");
            self.request = try response.deferResponse(.{ .timeout_ms = 5000, .completion = .{ .context = self, .complete = completion } });
            self.semaphore.post();
        }
    }
    fn worker(self: *@This()) void {
        while (true) {
            self.semaphore.wait();
            if (self.stop_worker.load(.acquire)) return;
            self.fileWorker() catch |err| {
                self.worker_error = err;
                self.app.post(.{ .context = self, .call = deliver }) catch {};
            };
        }
    }
    fn fileWorker(self: *@This()) !void {
        const head = self.file_head;
        const truncate_source = self.truncate_source;
        const skip_pump = self.skip_pump;
        var directory = zio.tmpDir(.{});
        defer directory.cleanup();
        const file = try directory.dir.createFile(zio.io(), "private-response", .{ .read = true });
        defer file.close(zio.io());
        const block: [4096]u8 = @splat('a');
        for (0..128) |_| try file.writeStreamingAll(zio.io(), &block);
        try file.writeStreamingAll(zio.io(), block[0..37]);
        const original_position = try zio.posix.position(file.handle);
        const reads = zwk_file_pread_count();
        var prepared = try web.OwnedFileResponse.preparePumped(self.allocator, self.app.owner, file, .{ .mime = "application/octet-stream", .headers = &.{.{ .name = "X-File", .value = "yes" }} }, 1024 * 1024);
        defer prepared.pump.deinit();
        if (truncate_source) try file.setLength(zio.io(), 1);
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
        try std.testing.expectEqual(original_position, try zio.posix.position(file.handle));
        if (head) self.head_reads = zwk_file_pread_count() - reads;
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.worker_error) |err| return self.fail(err);
        if (self.ticket) |*ticket| ticket.deinit();
        self.ticket = null;
        self.ticket = self.view.respondFile(self.request.?, &self.file_response.?, .{ .ticket = true }) catch |err| {
            self.file_response.?.deinit();
            if (self.skip_pump) self.accepted.post();
            return self.fail(err);
        };
        if (self.file_response.?.native != null or self.file_response.?.metadata.storage != null) return self.fail(error.ResponseNotConsumed);
        if (self.skip_pump) self.accepted.post();
    }
};

/// The page's records and every file stream record, controls included, end
/// once the engine lets go of the closed view.
const Drain = struct {
    app: *z.App,
    rounds: usize = 0,
    fn clean() bool {
        var physical: u32 = 0;
        var controls: u32 = 0;
        var budgets: u32 = 0;
        var candidates: u32 = 0;
        zwk_file_counts(&physical, &controls, &budgets, &candidates);
        const native = web.resourceCounts();
        return physical == 0 and controls == 0 and budgets == 0 and candidates == 0 and native.states == 0 and native.handlers == 0 and native.controllers == 0 and web.deferredResourceCount() == 0;
    }
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.rounds += 1;
        if (clean() or self.rounds == 3000) return self.app.quit();
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var probe: Probe = .{ .app = app, .allocator = allocator };
        probe.window = try app.createWindow(.{ .width = 320, .height = 200 });
        probe.view = web.View.init(allocator, &probe, Probe.event);
        var worker: ?std.Thread = try std.Thread.spawn(.{}, Probe.worker, .{&probe});
        defer {
            probe.stop_worker.store(true, .release);
            probe.semaphore.post();
            probe.accepted.post();
            if (worker) |thread| thread.join();
            if (probe.file_response) |*response| response.deinit();
            if (probe.ticket) |*ticket| ticket.deinit();
        }
        try probe.view.attach(probe.window, .{ .html = "", .storage = .ephemeral, .file_streams = .{ .max_file_bytes = 1024 * 1024 }, .local = .{ .scheme = "asset", .host = "app.ziggurat.invalid", .start_path = "/document", .scheme_ipc = true, .dynamic_document = true, .on_resource = .{ .context = &probe, .handle = Probe.handle } }, .custom_schemes = &.{.{ .name = "asset", .treat_as_secure = true }} });
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        probe.stop_worker.store(true, .release);
        probe.semaphore.post();
        worker.?.join();
        worker = null;
        if (watchdog.expired) {
            std.debug.print("expired: documents={d} delivered={d} messages={d} err={?}\n", .{ probe.documents, probe.delivered, probe.messages, probe.err });
            return error.DeadlineExceeded;
        }
        if (probe.err) |err| return err;
        if (probe.worker_error) |err| return err;
        try std.testing.expectEqual(@as(u32, 1), probe.documents);
        try std.testing.expectEqual(@as(u32, 1), probe.messages);
        try std.testing.expectEqual(@as(u32, 4), probe.delivered);
        try std.testing.expectEqual(@as(u64, 0), probe.head_reads);
    }
    {
        // A stopped App takes no posts, so a fresh one turns the run loop.
        const app = try z.App.init(allocator);
        defer app.deinit();
        var drain: Drain = .{ .app = app };
        try app.post(.{ .context = &drain, .call = Drain.tick });
        try app.run();
        if (!Drain.clean()) return error.FileRecordsRemain;
    }
    std.debug.print("macOS file responses: whole file, HEAD without reads, short source fails, a released pump cancels its transfer; file records=0\n", .{});
}
