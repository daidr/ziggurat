const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Fixture = @import("file_stream_probe.zig").Fixture;
const Watchdog = @import("watchdog.zig").Watchdog;
const w = @import("ziggurat_c_win32");
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
const size = 4 * 1024 * 1024;
const enabled_document =
    \\<!doctype html><script>
    \\(async()=>{try{
    \\let r=await fetch('/head',{method:'HEAD'});if(r.headers.get('Content-Length')!=='4194304'||(await r.arrayBuffer()).byteLength!==0)throw Error('HEAD');
    \\for(const path of ['/payload','/async']){r=await fetch(path);const bytes=new Uint8Array(await r.arrayBuffer());
    \\if(r.status!==200||bytes.length!==4194304)throw Error(path+':length');
    \\for(let i=0;i<bytes.length;i++)if(bytes[i]!==i%251)throw Error(path+':content');}
    \\chrome.webview.postMessage('complete');}catch(e){chrome.webview.postMessage('error:'+e.message)}})();
    \\</script>
;
const denied_document =
    \\<!doctype html><script>fetch('/payload').then(async r=>{
    \\chrome.webview.postMessage(r.status===403?'complete':'error:default')
    \\}).catch(e=>chrome.webview.postMessage('error:'+e.message));</script>
;
const Prepared = struct {
    fixture: *Fixture,
    main_thread: std.Thread.Id,
    owned: [3]?web.OwnedFileResponse = @splat(null),
    cleanup: bool = false,
    err: ?anyerror = null,
    fn run(self: *Prepared) void {
        self.work() catch |err| {
            self.err = err;
        };
    }
    fn work(self: *Prepared) !void {
        if (self.cleanup) {
            for (&self.owned) |*owned| if (owned.*) |*value| value.deinit();
            self.owned = @splat(null);
            self.fixture.cleanup = true;
            self.fixture.run();
            if (self.fixture.err) |err| return err;
            return;
        }
        self.fixture.run();
        if (self.fixture.err) |err| return err;
        const file = self.fixture.file.?;
        try zio.posix.seekTo(file.handle, 3);
        var native_failure: ?i32 = null;
        try std.testing.expectError(error.FileTooLarge, web.OwnedFileResponse.prepareWithFailure(self.fixture.allocator, self.main_thread, file, .{}, 1, &native_failure));
        try std.testing.expectEqual(@as(u32, 0x800700df), @as(u32, @bitCast(native_failure.?)));
        const invalid: std.Io.File = .{ .handle = w.INVALID_HANDLE_VALUE.?, .flags = .{ .nonblocking = false } };
        try std.testing.expectError(error.FilePrepareFailed, web.OwnedFileResponse.prepareWithFailure(self.fixture.allocator, self.main_thread, invalid, .{}, size, &native_failure));
        try std.testing.expectEqual(@as(u32, 0x80070006), @as(u32, @bitCast(native_failure.?)));
        try std.testing.expectError(error.InvalidFileStreamLimit, web.OwnedFileResponse.prepareWithFailure(self.fixture.allocator, self.main_thread, file, .{}, web.file_responses.hard_max_file_bytes + 1, &native_failure));
        try std.testing.expect(native_failure == null);
        try std.testing.expectError(error.UnexpectedResponseBody, web.OwnedFileResponse.prepare(self.fixture.allocator, self.main_thread, file, .{ .status = 204 }, size));
        try std.testing.expectError(error.OutOfMemory, web.OwnedFileResponse.prepare(std.testing.failing_allocator, self.main_thread, file, .{}, size));
        for (&self.owned) |*owned| owned.* = try web.OwnedFileResponse.prepare(self.fixture.allocator, self.main_thread, file, .{ .headers = &.{.{ .name = "X-File", .value = "private" }} }, size);
        try std.testing.expectEqual(@as(u64, 3), try zio.posix.position(file.handle));
    }
};
const State = struct {
    app: *z.App,
    view: *web.View,
    prepared: *Prepared,
    enabled: bool,
    close_in_completion: bool,
    late_ticket: *?web.StreamTicket,
    ticket: ?web.StreamTicket = null,
    delivery: ?std.Thread = null,
    request: ?web.ResourceRequestId = null,
    completions: u32 = 0,
    consumed: u32 = 0,
    denied: u32 = 0,
    done: bool = false,
    failure: ?anyerror = null,
    worker_error: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("file response smoke: {s}\n", .{@errorName(err)});
        }
        self.app.quit();
    }
    fn complete(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .responded) return self.fail(error.WrongResourceTerminal);
        self.completions += 1;
        if (self.close_in_completion) {
            self.done = true;
            self.app.quit();
        }
    }
    fn worker(self: *State) void {
        self.app.post(.{ .context = self, .call = deliver }) catch |err| {
            self.worker_error = err;
            self.prepared.owned[2].?.deinit();
        };
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const ticket = self.view.respondFile(self.request.?, &self.prepared.owned[2].?, .{ .ticket = self.close_in_completion }) catch |err| return self.fail(err);
        if ((ticket != null) != self.close_in_completion or self.prepared.owned[2].?.native != null) return self.fail(error.AsyncFileNotConsumed);
        self.late_ticket.* = ticket;
        self.consumed += 1;
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, request.path, "/head")) {
            const ticket = responder.respondFile(&self.prepared.owned[0].?, .{ .ticket = true }) catch |err| return self.fail(err);
            if (ticket != null or web.fileResourceCounts().streams != 0 or self.prepared.owned[0].?.native != null) return self.fail(error.HeadCreatedStream);
            self.consumed += 1;
        } else if (std.mem.eql(u8, request.path, "/payload")) {
            const ticket = responder.respondFile(&self.prepared.owned[1].?, .{ .ticket = true }) catch |err| {
                if (self.enabled or err != error.FileStreamsDenied or self.prepared.owned[1].?.native == null) return self.fail(err);
                const counts = web.fileResourceCounts();
                if (counts.streams + counts.controls + counts.budgets != 0) return self.fail(error.DisabledAllocatedStream);
                self.denied += 1;
                responder.respond(.{ .status = 403 }) catch |response_err| self.fail(response_err);
                return;
            };
            self.ticket = ticket orelse return self.fail(error.MissingStreamTicket);
            if (self.prepared.owned[1].?.native != null) return self.fail(error.FileNotConsumed);
            self.consumed += 1;
        } else if (std.mem.eql(u8, request.path, "/async")) {
            self.request = responder.deferResponse(.{ .timeout_ms = 5000, .completion = .{ .context = self, .complete = complete } }) catch |err| return self.fail(err);
            self.delivery = std.Thread.spawn(.{}, worker, .{self}) catch |err| return self.fail(err);
        }
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                var pid: c_uint = 0;
                if (zwv_browser_process_id(view.native.?, &pid) < 0 or pid == 0) return self.fail(error.BrowserPidUnavailable);
                self.prepared.fixture.browser = w.OpenProcess(w.SYNCHRONIZE, w.FALSE, pid) orelse return self.fail(error.BrowserWaitHandleUnavailable);
            },
            .message => |message| {
                if (!std.mem.eql(u8, message, "complete")) {
                    std.debug.print("file response page: {s}\n", .{message});
                    return self.fail(error.PageFailure);
                }
                self.done = true;
                self.app.quit();
            },
            .failed, .process_failed => self.fail(error.RuntimeFailure),
            else => {},
        }
    }
};
const LateTicket = struct {
    ticket: web.StreamTicket,
    err: ?anyerror = null,
    fn run(self: *LateTicket) void {
        self.ticket.cancel();
        var clone = self.ticket.clone() catch |err| {
            self.err = err;
            self.ticket.deinit();
            return;
        };
        self.ticket.deinit();
        clone.cancel();
        clone.deinit();
    }
};
fn runCycle(enabled: bool, close_in_completion: bool) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var temporary = zio.tmpDir(.{});
    var fixture: Fixture = .{ .allocator = gpa.allocator(), .temporary = &temporary };
    var prepared: Prepared = .{ .fixture = &fixture, .main_thread = std.Thread.getCurrentId() };
    defer {
        if (!fixture.closed) {
            prepared.cleanup = true;
            const thread = std.Thread.spawn(.{}, Prepared.run, .{&prepared}) catch @panic("fixture cleanup worker unavailable");
            thread.join();
            if (prepared.err) |err| std.debug.print("file response cleanup: {s}\n", .{@errorName(err)});
        }
        if (fixture.profile) |profile| gpa.allocator().free(profile);
    }
    const prepare = try std.Thread.spawn(.{}, Prepared.run, .{&prepared});
    prepare.join();
    if (prepared.err) |err| return err;
    try std.testing.expectError(error.UiThreadForbidden, web.OwnedFileResponse.prepare(std.testing.failing_allocator, prepared.main_thread, fixture.file.?, .{}, size));
    var late_ticket: ?web.StreamTicket = null;
    defer if (late_ticket) |*ticket| ticket.deinit();
    {
        const app = try z.App.init(gpa.allocator());
        defer app.deinit();
        var view: web.View = undefined;
        var state: State = .{ .app = app, .view = &view, .prepared = &prepared, .enabled = enabled, .close_in_completion = close_in_completion, .late_ticket = &late_ticket };
        defer if (state.delivery) |thread| thread.join();
        defer if (state.ticket) |*ticket| {
            ticket.cancel();
            ticket.deinit();
        };
        view = web.View.init(gpa.allocator(), &state, State.event);
        const window = try app.createWindow(.{});
        try view.attach(window, .{ .html = if (enabled) enabled_document else denied_document, .user_data_folder = fixture.profile.?, .file_streams = if (enabled) .{} else null, .local = .{ .on_resource = .{ .context = &state, .handle = State.resource } } });
        fixture.runtime_started = true;
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        if (state.delivery) |thread| thread.join();
        state.delivery = null;
        try std.testing.expect(!watchdog.expired and state.failure == null and state.worker_error == null and state.done);
        try std.testing.expectEqual(@as(u32, if (enabled) 3 else 0), state.consumed);
        try std.testing.expectEqual(@as(u32, if (enabled) 1 else 0), state.completions);
        try std.testing.expectEqual(@as(u32, if (enabled) 0 else 1), state.denied);
        const refs = web.resourceCounts();
        try std.testing.expectEqual(@as(u32, 0), refs.states + refs.handlers + refs.controllers);
    }
    if (late_ticket) |ticket| {
        var late: LateTicket = .{ .ticket = ticket };
        late_ticket = null;
        const thread = try std.Thread.spawn(.{}, LateTicket.run, .{&late});
        thread.join();
        if (late.err) |err| return err;
    }
    prepared.cleanup = true;
    prepared.err = null;
    const cleanup = try std.Thread.spawn(.{}, Prepared.run, .{&prepared});
    cleanup.join();
    if (prepared.err) |err| return err;
    const counts = web.fileResourceCounts();
    std.debug.print("file response enabled={} close_in_completion={} refs={any}\n", .{ enabled, close_in_completion, counts });
    try std.testing.expectEqual(@as(u32, 0), counts.streams + counts.controls + counts.budgets);
}
pub fn main() !void {
    try runCycle(false, false);
    try runCycle(true, false);
    try runCycle(true, true);
    std.debug.print("file response smoke passed: default deny/no native objects, worker-only preparation/limits/OOM, cursor preservation, HEAD, complete private file, deferred worker post and independent ticket; native refs=0\n", .{});
}
