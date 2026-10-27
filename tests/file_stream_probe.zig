const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const w = @import("ziggurat_c_win32");
extern fn zwv_probe_file_create(*anyopaque, u64, *?*anyopaque) i32;
extern fn zwv_probe_respond(*anyopaque, *anyopaque, u64) i32;
extern fn zwv_probe_marshal(*anyopaque, *?*anyopaque) i32;
extern fn zwv_probe_mta_enter(*anyopaque, *?*anyopaque) i32;
extern fn zwv_probe_mta_finish(*anyopaque) i32;
extern fn zwv_probe_block_read(*anyopaque, *anyopaque) i32;
extern fn zwv_probe_reset() i32;
extern fn zwv_probe_cancel(*anyopaque) void;
extern fn zwv_probe_release(*anyopaque) void;
extern fn zwv_probe_stats(*Stats) void;
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
const Stats = extern struct {
    live: u32,
    reads: u32,
    ui_reads: u32,
    worker_reads: u32,
    max_request: u32,
    max_disk_read: u32,
    bytes: u64,
    last_read_thread: u32,
    last_release_thread: u32,
};
const file_size = 4 * 1024 * 1024;
const document =
    \\<!doctype html><script>
    \\(async()=>{try{const r=await fetch('/payload');const bytes=new Uint8Array(await r.arrayBuffer());
    \\if(r.status!==200||bytes.length!==4194304)throw Error('length');
    \\for(let i=0;i<bytes.length;i++)if(bytes[i]!==i%251)throw Error('content:'+i);
    \\chrome.webview.postMessage('complete');}catch(e){chrome.webview.postMessage('error:'+e.message)}})();
    \\</script>
;
pub const Fixture = struct {
    allocator: std.mem.Allocator,
    temporary: *zio.TmpDir,
    profile: ?[]u8 = null,
    file: ?std.Io.File = null,
    browser: ?*anyopaque = null,
    runtime_started: bool = false,
    cleanup: bool = false,
    closed: bool = false,
    err: ?anyerror = null,
    pub fn run(self: *Fixture) void {
        self.work() catch |err| {
            self.err = err;
        };
    }
    fn work(self: *Fixture) !void {
        if (!self.cleanup) {
            try self.temporary.dir.createDir(zio.io(), "profile", .default_dir);
            self.profile = try zio.realPathAlloc(self.temporary.dir, "profile", self.allocator);
            {
                const file = try self.temporary.dir.createFile(zio.io(), "payload.bin", .{});
                defer file.close(zio.io());
                var chunk: [65536]u8 = undefined;
                var offset: usize = 0;
                while (offset < file_size) {
                    for (&chunk, 0..) |*byte, i| byte.* = @intCast((offset + i) % 251);
                    try file.writeStreamingAll(zio.io(), &chunk);
                    offset += chunk.len;
                }
            }
            // Reopen read-only before transfer so this experiment cannot mutate
            // the available content while the Runtime owns stream references.
            const path = try zio.realPathAlloc(self.temporary.dir, "payload.bin", self.allocator);
            defer self.allocator.free(path);
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, path);
            defer self.allocator.free(wide);
            const handle = w.CreateFileW(wide.ptr, w.GENERIC_READ, w.FILE_SHARE_READ | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
            if (handle == w.INVALID_HANDLE_VALUE) return error.ReadOnlyOpenFailed;
            self.file = .{ .handle = handle.?, .flags = .{ .nonblocking = false } };
            var length: w.LARGE_INTEGER = undefined;
            if (w.GetFileSizeEx(handle, &length) == 0 or length.QuadPart != file_size) return error.PreparedLengthChanged;
            const writer = w.CreateFileW(wide.ptr, w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
            if (writer != w.INVALID_HANDLE_VALUE) {
                _ = w.CloseHandle(writer);
                return error.PreparedFileStillWritable;
            }
            if (w.GetLastError() != w.ERROR_SHARING_VIOLATION) return error.UnexpectedWriteRejection;
        } else {
            var directory_closed = false;
            defer {
                if (!directory_closed) self.temporary.dir.close(zio.io());
                self.temporary.parent_dir.close(zio.io());
                self.closed = true;
            }
            if (self.file) |file| file.close(zio.io());
            self.file = null;
            if (self.runtime_started and self.browser == null) {
                std.debug.print("private stream profile retained: {?s}\n", .{self.profile});
                return error.BrowserShutdownUnconfirmed;
            }
            if (self.browser) |browser| {
                defer _ = w.CloseHandle(browser);
                if (w.WaitForSingleObject(browser, 10_000) != w.WAIT_OBJECT_0) return error.BrowserShutdownUnconfirmed;
                self.browser = null;
            }
            self.temporary.dir.close(zio.io());
            directory_closed = true;
            // The closed directory token is not reused after deleting its root.
            try self.temporary.parent_dir.deleteTree(zio.io(), &self.temporary.sub_path);
        }
    }
};
const Mta = struct {
    packet: *anyopaque,
    ready: *anyopaque,
    gate: zio.ResetEvent = .{},
    entered: std.atomic.Value(i32) = .init(-1),
    finished: i32 = -1,
    thread_id: u32 = 0,
    fn run(self: *Mta) void {
        self.thread_id = w.GetCurrentThreadId();
        var stream: ?*anyopaque = null;
        const hr = zwv_probe_mta_enter(self.packet, &stream);
        self.entered.store(hr, .release);
        _ = w.SetEvent(self.ready);
        if (hr < 0) return;
        self.gate.wait();
        self.finished = zwv_probe_mta_finish(stream.?);
    }
};
const State = struct {
    app: *z.App,
    view: *web.View,
    fixture: *Fixture,
    stream: *anyopaque,
    mta: *Mta,
    mta_ready: bool = false,
    fetched: bool = false,
    read_blocked: bool = false,
    cancel_while_read: bool,
    requests: u32 = 0,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("file stream probe: {s}\n", .{@errorName(err)});
        }
        self.app.quit();
    }
    fn maybeQuit(self: *State) void {
        if (self.mta_ready and (if (self.cancel_while_read) self.read_blocked else self.fetched)) self.app.quit();
    }
    fn readStarted(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.read_blocked = true;
        self.maybeQuit();
    }
    fn mtaReady(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const hr = self.mta.entered.load(.acquire);
        if (hr < 0) {
            std.debug.print("MTA unmarshal HRESULT=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
            return self.fail(error.UnmarshalFailed);
        }
        self.mta_ready = true;
        self.maybeQuit();
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, request.path, "/payload")) return;
        self.requests += 1;
        const hr = zwv_probe_respond(responder.native, self.stream, file_size);
        if (hr < 0) {
            std.debug.print("stream response HRESULT=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
            return self.fail(error.ResponseFailed);
        }
        responder.responded = true;
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                var pid: c_uint = 0;
                if (zwv_browser_process_id(view.native.?, &pid) < 0 or pid == 0) return self.fail(error.BrowserPidUnavailable);
                self.fixture.browser = w.OpenProcess(w.SYNCHRONIZE, w.FALSE, pid) orelse return self.fail(error.BrowserWaitHandleUnavailable);
            },
            .message => |message| {
                if (!std.mem.eql(u8, message, "complete")) {
                    std.debug.print("stream page: {s}\n", .{message});
                    return self.fail(error.FetchFailed);
                }
                self.fetched = true;
                self.maybeQuit();
            },
            .failed, .process_failed => self.fail(error.RuntimeFailed),
            else => {},
        }
    }
};
fn runCycle(cancel_while_read: bool) !void {
    try std.testing.expect(zwv_probe_reset() >= 0);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var temporary = zio.tmpDir(.{});
    var fixture: Fixture = .{ .allocator = allocator, .temporary = &temporary };
    defer {
        if (!fixture.closed) {
            fixture.cleanup = true;
            fixture.err = null;
            const thread = std.Thread.spawn(.{}, Fixture.run, .{&fixture}) catch @panic("fixture cleanup worker unavailable");
            thread.join();
            if (fixture.err) |err| std.debug.print("stream fixture cleanup: {s}\n", .{@errorName(err)});
        }
        if (fixture.profile) |profile| allocator.free(profile);
    }
    const prepare = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    prepare.join();
    if (fixture.err) |err| return err;
    const ready = w.CreateEventW(null, w.TRUE, w.FALSE, null) orelse return error.EventFailed;
    defer _ = w.CloseHandle(ready);
    const read_entered = w.CreateEventW(null, w.TRUE, w.FALSE, null) orelse return error.EventFailed;
    defer _ = w.CloseHandle(read_entered);
    var mta: Mta = .{ .packet = undefined, .ready = ready };
    var mta_thread: ?std.Thread = null;
    defer if (mta_thread) |thread| {
        mta.gate.set();
        thread.join();
    };
    const ui_thread = w.GetCurrentThreadId();
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var stream: ?*anyopaque = null;
        const hr = zwv_probe_file_create(fixture.file.?.handle, file_size, &stream);
        if (hr < 0) return error.StreamCreateFailed;
        fixture.file = null;
        defer {
            zwv_probe_cancel(stream.?);
            zwv_probe_release(stream.?);
        }
        if (cancel_while_read and zwv_probe_block_read(stream.?, read_entered) < 0) return error.BlockReadFailed;
        var packet: ?*anyopaque = null;
        if (zwv_probe_marshal(stream.?, &packet) < 0) return error.MarshalFailed;
        mta.packet = packet.?;
        mta_thread = try std.Thread.spawn(.{}, Mta.run, .{&mta});
        var view: web.View = undefined;
        var state: State = .{ .app = app, .view = &view, .fixture = &fixture, .stream = stream.?, .mta = &mta, .cancel_while_read = cancel_while_read };
        const watch = try app.watchNative(ready, .{ .context = &state, .call = State.mtaReady });
        defer _ = app.unwatchNative(watch);
        const read_watch = if (cancel_while_read) try app.watchNative(read_entered, .{ .context = &state, .call = State.readStarted }) else null;
        defer if (read_watch) |token| {
            _ = app.unwatchNative(token);
        };
        view = web.View.init(allocator, &state, State.event);
        const window = try app.createWindow(.{});
        try view.attach(window, .{ .html = document, .user_data_folder = fixture.profile.?, .local = .{ .on_resource = .{ .context = &state, .handle = State.resource } } });
        fixture.runtime_started = true;
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        var stats: Stats = undefined;
        zwv_probe_stats(&stats);
        std.debug.print("Runtime stream before owner release: {any}; UI thread={d}\n", .{ stats, ui_thread });
        try std.testing.expect(!watchdog.expired and state.failure == null and state.mta_ready);
        try std.testing.expect(if (cancel_while_read) state.read_blocked and !state.fetched else state.fetched);
        try std.testing.expectEqual(@as(u32, 1), state.requests);
        try std.testing.expectEqual(@as(u32, 0), stats.ui_reads);
        try std.testing.expect(stats.worker_reads > 0 and stats.max_disk_read <= 65536);
        try std.testing.expect(if (cancel_while_read) stats.bytes == 0 else stats.bytes >= file_size);
        const refs = web.resourceCounts();
        try std.testing.expectEqual(@as(u32, 0), refs.states + refs.handlers + refs.controllers);
    }
    mta.gate.set();
    mta_thread.?.join();
    mta_thread = null;
    var stats: Stats = undefined;
    zwv_probe_stats(&stats);
    std.debug.print("Runtime stream after MTA release: {any}; MTA thread={d}, terminal=0x{x:0>8}\n", .{ stats, mta.thread_id, @as(u32, @bitCast(mta.finished)) });
    try std.testing.expect(mta.finished >= 0);
    try std.testing.expectEqual(@as(u32, 0), stats.live);
    try std.testing.expect(stats.last_release_thread != ui_thread);
    if (!cancel_while_read) try std.testing.expectEqual(mta.thread_id, stats.last_release_thread);
    fixture.cleanup = true;
    const cleanup = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    cleanup.join();
    if (fixture.err) |err| return err;
    std.debug.print("file stream probe passed: private 4MiB, background bounded reads, FTM and native final release; cancel_during_read={}\n", .{cancel_while_read});
}
pub fn main() !void {
    try runCycle(false);
    try runCycle(true);
}
