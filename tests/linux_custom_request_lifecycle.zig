const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn gtk_widget_destroy(*anyopaque) void;

const Mode = enum { navigation, reload, recover, raw_close };
const html =
    \\<!doctype html><script>chrome.webview.addEventListener('message',async e=>{try{
    \\if(e.data==='start-pending'){fetch('/pending').catch(()=>{});}
    \\else if(e.data==='pending-accepted'){let r=await fetch('/full');if(await r.text()!=='full')throw Error('Full response');chrome.webview.postMessage('full-ready');}
    \\else if(e.data==='check-policy'){let r=await fetch('/verify',{headers:{'X-Lifecycle':'owned'}});if(await r.text()!=='verified')throw Error('restored grant');let rejected=false;try{await fetch('/verify',{headers:{'X-Lifecycle':'wrong'}})}catch{rejected=true}if(!rejected)throw Error('restored exact gate');chrome.webview.postMessage('done');}
    \\}catch(e){chrome.webview.postMessage('error:'+e.message)}});addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('boot'))</script>
;
const Probe = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    window: z.Window = undefined,
    view: web.View = undefined,
    mode: Mode,
    replacing: bool = false,
    action_queued: bool = false,
    full_ready: bool = false,
    completed: bool = false,
    id: ?web.ResourceRequestId = null,
    failure: ?anyerror = null,
    ready: usize = 0,
    boots: usize = 0,
    full: usize = 0,
    callbacks: usize = 0,
    verified: usize = 0,
    stale_retained: usize = 0,
    process_failures: usize = 0,
    done: usize = 0,
    closed: usize = 0,
    fn options(self: *Probe) web.Options {
        return .{
            .html = html,
            .storage = .ephemeral,
            .page_listener = .{ .context = self, .event = page },
            .resource_limits = .{ .max_pending = 1 },
            .local = .{
                .scheme = "asset",
                .start_path = "/document",
                .scheme_ipc = true,
                .request_headers = &.{.{ .name = "X-Lifecycle", .exact_value = "owned" }},
                .on_resource = .{ .context = self, .handle = request },
            },
            .custom_schemes = &.{.{ .name = "asset", .treat_as_secure = true, .request_origins = &.{"asset://app.ziggurat.invalid"} }},
        };
    }
    fn fail(self: *Probe, failure: anyerror) void {
        if (self.failure == null) self.failure = failure;
        std.debug.print("custom_request_lifecycle mode={s} failure={s}\n", .{ @tagName(self.mode), @errorName(failure) });
        self.app.quit();
    }
    fn event(context: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.onEvent(value) catch |failure| self.fail(failure);
    }
    fn onEvent(self: *Probe, value: web.Event) !void {
        switch (value) {
            .ready => self.ready += 1,
            .message => |message| {
                if (std.mem.eql(u8, message, "boot")) {
                    self.boots += 1;
                    if (!self.replacing) return self.view.post("start-pending");
                    var owned = try web.resources.OwnedResponse.init(self.allocator, .{ .bytes = "late response must stay owned" }, 100);
                    defer owned.deinit();
                    try std.testing.expectError(error.StaleRequest, self.view.respondOwned(self.id.?, &owned));
                    try std.testing.expect(owned.storage != null);
                    self.stale_retained += 1;
                    try self.view.post("check-policy");
                } else if (std.mem.eql(u8, message, "full-ready")) {
                    self.full_ready = true;
                    try self.queue();
                } else if (std.mem.eql(u8, message, "done")) {
                    self.done += 1;
                    self.app.quit();
                } else return error.LifecyclePageFailed;
            },
            .process_failed => {
                self.process_failures += 1;
                if (self.mode != .recover or !self.replacing or self.process_failures != 1) return error.UnexpectedProcessFailure;
                try self.view.recover();
            },
            .failed => return error.UnexpectedLoadFailure,
            else => {},
        }
    }
    fn page(context: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        if (value != .completed or self.replacing) return;
        if (!value.completed.success) return self.fail(error.InitialLoadFailed);
        self.completed = true;
        self.queue() catch |failure| self.fail(failure);
    }
    fn queue(self: *Probe) !void {
        if (!self.completed or !self.full_ready or self.action_queued) return;
        self.action_queued = true;
        try self.app.post(.{ .context = self, .call = advance });
    }
    fn advance(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.replacing = true;
        switch (self.mode) {
            .navigation => self.view.navigateLocal("/document") catch |failure| self.fail(failure),
            .reload => self.view.reload(self.options()) catch |failure| self.fail(failure),
            .recover => @import("linux_webview_process.zig").stop(self.window) catch |failure| self.fail(failure),
            .raw_close => {
                gtk_widget_destroy(self.window.nativeHandle().?);
                self.app.quit();
            },
        }
    }
    fn completion(context: *anyopaque, result: web.resources.Result) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.callbacks += 1;
        const expected: web.resources.Result = switch (self.mode) {
            .navigation, .reload => .page_changed,
            .recover => .unavailable,
            .raw_close => .detached,
        };
        if (std.meta.activeTag(result) != std.meta.activeTag(expected) or self.callbacks != 1) self.fail(error.WrongTerminalResult);
    }
    fn request(context: *anyopaque, input: web.ResourceRequest, responder: *web.Responder) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.onRequest(input, responder) catch |failure| self.fail(failure);
    }
    fn onRequest(self: *Probe, input: web.ResourceRequest, responder: *web.Responder) !void {
        try std.testing.expectEqual(web.resources.Method.get, input.method);
        if (std.mem.eql(u8, input.path, "/pending")) {
            if (self.id != null) return error.DuplicatePendingRequest;
            self.id = try responder.deferResponse(.{ .completion = .{ .context = self, .complete = completion } });
            try self.view.post("pending-accepted");
        } else if (std.mem.eql(u8, input.path, "/full")) {
            try std.testing.expectError(error.Full, responder.deferResponse(.{}));
            try responder.respond(.{ .mime = "text/plain", .bytes = "full" });
            self.full += 1;
        } else if (std.mem.eql(u8, input.path, "/verify")) {
            var grant = false;
            for (input.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "X-Lifecycle")) {
                try std.testing.expectEqualStrings("owned", header.value);
                grant = true;
            };
            if (!grant or !self.replacing) return error.PolicyDidNotSurviveReplacement;
            try responder.respond(.{ .mime = "text/plain", .bytes = "verified" });
            self.verified += 1;
        } else return error.UnexpectedLifecycleRequest;
    }
    fn close(context: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.closed += 1;
        if (self.view.window != null or self.view.config != null) self.fail(error.OwnerNotDetached);
    }
};

pub fn run(allocator: std.mem.Allocator) !void {
    inline for (std.meta.tags(Mode)) |mode| {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var probe: Probe = .{ .app = app, .allocator = allocator, .mode = mode };
        probe.window = try app.createWindow(.{ .on_closed = .{ .context = &probe, .notify = Probe.close } });
        probe.view = web.View.init(allocator, &probe, Probe.event);
        try probe.view.attach(probe.window, probe.options());
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        if (probe.failure) |failure| return failure;
        if (watchdog.expired) return error.LifecycleDeadline;
        try std.testing.expect(probe.full == 1 and probe.callbacks == 1 and probe.closed == 1);
        if (mode == .raw_close) {
            var owned = try web.resources.OwnedResponse.init(allocator, .{ .bytes = "closed request must stay owned" }, 100);
            defer owned.deinit();
            try std.testing.expectError(error.Closed, probe.view.respondOwned(probe.id.?, &owned));
            try std.testing.expect(owned.storage != null and probe.boots == 1 and probe.verified == 0);
        } else {
            try std.testing.expect(probe.boots == 2 and probe.stale_retained == 1 and probe.verified == 1 and probe.done == 1);
            try std.testing.expectEqual(@as(usize, if (mode == .navigation) 1 else 2), probe.ready);
        }
        try std.testing.expectEqual(@as(usize, if (mode == .recover) 1 else 0), probe.process_failures);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        std.debug.print("custom_request_lifecycle mode={s}: Full, exactly-once terminal, old-id retains response, policy_replayed={}, window0\n", .{ @tagName(mode), mode != .raw_close });
    }
}
