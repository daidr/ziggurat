const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

const document =
    \\<!doctype html><script src="/script.js"></script><script>
    \\chrome.webview.addEventListener('message',e=>{if(e.data==='ping')chrome.webview.postMessage('ack')});
    \\addEventListener('DOMContentLoaded',async()=>{try{
    \\if(window.externalValue!==7)throw Error('script');
    \\const r=await fetch('/value.txt?query=1#fragment');if(await r.text()!=='private snapshot')throw Error('body');
    \\const h=await fetch('/value.txt',{method:'HEAD'});if(await h.text()!==''||h.headers.get('Content-Length')!=='16')throw Error('HEAD');
    \\chrome.webview.postMessage('done');
    \\}catch(e){chrome.webview.postMessage('error:'+e.message)}});
    \\</script>
;
const resources = [_]web.Resource{
    .{ .path = "/script.js", .mime = "text/javascript", .bytes = "window.externalValue=7" },
    .{ .path = "/value.txt", .mime = "text/plain", .bytes = "private snapshot" },
};
const registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true }};
fn options(ipc: bool) web.Options {
    return .{ .storage = .ephemeral, .html = if (ipc) document else "<script>chrome.webview.postMessage('must-not-arrive')</script>", .custom_schemes = &registrations, .local = .{ .scheme = "asset", .scheme_ipc = ipc, .resources = &resources } };
}
const Probe = struct {
    app: *z.App,
    window: z.Window,
    view: web.View = undefined,
    snapshot: ?web.snapshots.FileSnapshot = null,
    err: ?anyerror = null,
    ready: u32 = 0,
    completed: u32 = 0,
    messages: u32 = 0,
    ack: u32 = 0,
    releases: u32 = 0,
    failures: u32 = 0,
    closed: u32 = 0,
    ipc: bool,
    old: ?web.PageId = null,
    budget: ?*anyopaque = null,
    recover_process: bool = false,
    pending_done: bool = false,
    fn ping(self: *@This()) void {
        if (!self.pending_done or self.completed != self.ready) return;
        self.pending_done = false;
        self.view.postFor(self.view.pageId().?, "ping") catch |err| self.fail(err);
    }
    fn config(self: *@This()) web.Options {
        var result = options(self.ipc);
        if (self.snapshot) |snapshot| {
            result.html = snapshot.html;
            result.local.?.resources = snapshot.resources;
        }
        result.page_listener = .{ .context = self, .event = page };
        return result;
    }
    fn fail(self: *@This(), err: anyerror) void {
        self.err = err;
        std.debug.print("Linux custom WebView: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        std.debug.assert(self.view.window == null);
    }
    fn page(ptr: *anyopaque, view: *web.View, page_event: web.PageEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (page_event == .completed) {
            self.completed += 1;
            if (!page_event.completed.success) return self.fail(error.LoadFailed);
            if (self.ipc) self.ping();
            if (!self.ipc) _ = view.evaluateJS("location.protocol+'|'+location.hostname+'|'+location.port", .{}, .{ .context = self, .complete = script }) catch |err| self.fail(err);
        }
    }
    fn script(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "\"asset:|app.ziggurat.invalid|\"")) return self.fail(error.WrongCustomOrigin);
        std.testing.expectError(error.IpcOriginDenied, self.view.postFor(self.view.pageId().?, "denied")) catch |err| return self.fail(err);
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, event_value: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (event_value) {
            .ready => self.ready += 1,
            .resources_released => self.releases += 1,
            .message => |text| {
                self.messages += 1;
                if (!self.ipc) return self.fail(error.DefaultIpcEscaped);
                if (std.mem.eql(u8, text, "done")) {
                    if (self.budget == null) self.budget = view.custom_local_budget;
                    if (self.budget != view.custom_local_budget) return self.fail(error.BudgetOwnerChanged);
                    if (self.old) |old| std.testing.expectError(error.StalePage, view.postFor(old, "old")) catch |err| return self.fail(err);
                    self.pending_done = true;
                    self.ping();
                } else if (std.mem.eql(u8, text, "ack")) {
                    self.ack += 1;
                    if (self.ack == 1) {
                        self.old = view.pageId();
                        if (self.recover_process) {
                            @import("linux_webview_process.zig").stop(self.window) catch |err| self.fail(err);
                        } else view.reload(self.config()) catch |err| self.fail(err);
                    } else self.app.quit();
                } else self.fail(error.UnexpectedMessage);
            },
            .process_failed => {
                self.failures += 1;
                if (!self.recover_process or self.failures != 1) return self.fail(error.NativeFailure);
                view.recover() catch |err| self.fail(err);
            },
            .failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
};
const Prepare = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    probe: *Probe,
    result: ?web.snapshots.FileSnapshot = null,
    err: ?anyerror = null,
    fn prepare(self: *@This()) !web.snapshots.FileSnapshot {
        var temporary = zio.tmpDir(.{});
        defer temporary.cleanup();
        const html = try temporary.dir.createFile(zio.io(), "document.html", .{ .read = true });
        defer html.close(zio.io());
        try html.writeStreamingAll(zio.io(), document);
        const script = try temporary.dir.createFile(zio.io(), "script.js", .{ .read = true });
        defer script.close(zio.io());
        try script.writeStreamingAll(zio.io(), resources[0].bytes);
        const body = try temporary.dir.createFile(zio.io(), "value.txt", .{ .read = true });
        defer body.close(zio.io());
        try body.writeStreamingAll(zio.io(), resources[1].bytes);
        return web.snapshots.FileSnapshot.init(self.allocator, self.main_thread, html, &.{
            .{ .path = "/script.js", .mime = "text/javascript", .file = script },
            .{ .path = "/value.txt", .mime = "text/plain", .file = body },
        }, .{});
    }
    fn worker(self: *@This()) void {
        self.result = self.prepare() catch |err| blk: {
            self.err = err;
            break :blk null;
        };
        self.app.post(.{ .context = self, .call = deliver }) catch |err| {
            self.err = err;
            if (self.result) |*snapshot| snapshot.deinit();
            self.result = null;
        };
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.err) |err| return self.probe.fail(err);
        self.probe.snapshot = self.result;
        self.result = null;
        self.probe.view.attach(self.probe.window, self.probe.config()) catch |err| self.probe.fail(err);
    }
};
fn allocationFailure(allocator: std.mem.Allocator, core_allocator: std.mem.Allocator) !void {
    const app = try z.App.init(core_allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var marker: u8 = 0;
    var view = web.View.init(allocator, &marker, struct {
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {
            @panic("closed custom view callback");
        }
    }.event);
    view.attach(window, options(true)) catch |err| {
        try std.testing.expect(view.config == null and view.native == null and view.window == null and view.custom_local_budget == null);
        return err;
    };
    _ = try window.destroy();
    try std.testing.expect(view.custom_local_budget == null);
}
fn run(allocator: std.mem.Allocator, ipc: bool, recover_process: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app, .window = undefined, .ipc = ipc, .recover_process = recover_process };
    defer if (probe.snapshot) |*snapshot| snapshot.deinit();
    probe.window = try app.createWindow(.{ .on_closed = .{ .context = &probe, .notify = Probe.onClosed } });
    probe.view = web.View.init(allocator, &probe, Probe.event);
    var prepare: Prepare = .{ .app = app, .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .probe = &probe };
    var worker = if (ipc) try std.Thread.spawn(.{}, Prepare.worker, .{&prepare}) else null;
    defer if (worker) |thread| thread.join();
    if (!ipc) try probe.view.attach(probe.window, probe.config());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (worker) |thread| thread.join();
    worker = null;
    try std.testing.expect(!watchdog.expired and probe.closed == 1);
    if (probe.err) |err| return err;
    try std.testing.expect(probe.ready == @as(u32, if (ipc) 2 else 1) and probe.completed == probe.ready and probe.releases == @as(u32, if (ipc and !recover_process) 1 else 0));
    try std.testing.expectEqual(@as(u32, if (recover_process) 1 else 0), probe.failures);
    try std.testing.expect(probe.messages == @as(u32, if (ipc) 4 else 0) and probe.ack == @as(u32, if (ipc) 2 else 0));
    try std.testing.expect(probe.view.custom_local_budget == null);
}
pub fn runAll(allocator: std.mem.Allocator) !void {
    try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{allocator});
    try run(allocator, true, false);
    try run(allocator, false, false);
    try run(allocator, true, true);
    try reentry(allocator);
    std.debug.print("Linux custom WebView: worker snapshot, static GET/HEAD, PageId/reload, opt-in IPC, OOM rollback\n", .{});
}
const Reentry = struct {
    base: std.mem.Allocator,
    window: z.Window,
    view: ?*web.View = null,
    alloc_count: usize = 0,
    free_count: usize = 0,
    target: usize = std.math.maxInt(usize),
    on_free: bool = false,
    fired: bool = false,
    closed: u32 = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn trigger(self: *@This()) void {
        self.fired = true;
        std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
        std.debug.assert(self.view != null and self.closed == 0);
    }
    fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const index = self.alloc_count;
        self.alloc_count += 1;
        if (!self.fired and !self.on_free and index == self.target) self.trigger();
        return self.base.rawAlloc(size, alignment, address);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.base.rawResize(bytes, alignment, size, address);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.base.rawRemap(bytes, alignment, size, address);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const index = self.free_count;
        self.free_count += 1;
        if (!self.fired and self.on_free and index == self.target) self.trigger();
        self.base.rawFree(bytes, alignment, address);
    }
    fn event(_: *anyopaque, _: *web.View, _: web.Event) void {
        @panic("late custom callback reached freed View");
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.view.?.window == null and self.view.?.custom_local_budget == null);
        const view = self.view.?;
        self.view = null;
        self.closed += 1;
        self.base.destroy(view);
    }
};
fn reentryCase(allocator: std.mem.Allocator, target: usize, on_free: bool) !struct { allocs: usize, frees: usize } {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Reentry = .{ .base = allocator, .window = undefined, .target = target, .on_free = on_free };
    state.window = try app.createWindow(.{ .on_closed = .{ .context = &state, .notify = Reentry.onClosed } });
    state.view = try allocator.create(web.View);
    state.view.?.* = web.View.init(state.allocator(), &state, Reentry.event);
    state.view.?.attach(state.window, options(true)) catch |err| {
        if (err != error.Closed) return err;
    };
    const counts = .{ .allocs = state.alloc_count, .frees = state.free_count };
    if (!state.fired) _ = try state.window.destroy();
    // Allocator-triggered destruction is deferred until a normal App safe
    // point. Returning from attach only releases its pin; it does not dispatch.
    try app.dispatch();
    try std.testing.expect(state.closed == 1 and state.view == null);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    if (target != std.math.maxInt(usize)) try std.testing.expect(state.fired);
    return .{ .allocs = counts.allocs, .frees = counts.frees };
}
fn reentry(allocator: std.mem.Allocator) !void {
    const counts = try reentryCase(allocator, std.math.maxInt(usize), false);
    for (0..counts.allocs) |index| _ = try reentryCase(allocator, index, false);
    for (0..counts.frees) |index| _ = try reentryCase(allocator, index, true);
}
