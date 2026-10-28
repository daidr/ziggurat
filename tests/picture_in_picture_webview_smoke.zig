const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

/// A video playing a canvas's stream goes out into picture in picture and
/// back, from the host, which the page's events tell.
const document =
    \\<!doctype html><title>pip</title><canvas id=c width=64 height=48></canvas><video id=v muted playsinline></video>
    \\<script>window.events=[];const c=document.getElementById('c'),x=c.getContext('2d'),v=document.getElementById('v');
    \\let n=0;setInterval(()=>{x.fillStyle=(n++&1)?'#c33':'#33c';x.fillRect(0,0,64,48)},50);
    \\v.srcObject=c.captureStream(20);v.addEventListener('enterpictureinpicture',()=>events.push('enter'));
    \\v.addEventListener('leavepictureinpicture',()=>events.push('leave'));v.play();</script>
;

const Probe = struct {
    app: *z.App,
    store: []const u8,
    view: web.View = undefined,
    step: enum { load, entering, leaving, done } = .load,
    polls: u32 = 0,
    failure: ?anyerror = null,
    waiter: ?std.Thread = null,

    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("picture in picture step {s}: {s}\n", .{ @tagName(self.step), @errorName(err) });
        self.app.quit();
    }
    fn page(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .completed => |info| {
                if (!info.success) return self.fail(error.LoadFailed);
                if (self.step != .load) return;
                _ = view.evaluateJS("v.readyState>=1&&!v.paused", .{}, .{ .context = self, .complete = playing }) catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn playing(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        if (!std.mem.eql(u8, result.json, "true")) return self.later();
        self.step = .entering;
        self.polls = 0;
        self.view.togglePictureInPicture() catch |err| return self.fail(err);
        self.later();
    }
    fn later(self: *Probe) void {
        self.polls += 1;
        if (self.polls > 40) return self.fail(error.Timeout);
        if (self.waiter) |thread| thread.join();
        self.waiter = std.Thread.spawn(.{}, wait, .{self}) catch |err| return self.fail(err);
    }
    fn wait(self: *Probe) void {
        zio.sleep(100 * std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = poll }) catch {};
    }
    fn poll(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        const script = if (self.step == .load) "v.readyState>=1&&!v.paused" else "(document.pictureInPictureElement?'out ':'in ')+events.join(',')";
        _ = self.view.evaluateJS(script, .{}, .{ .context = self, .complete = if (self.step == .load) playing else polled }) catch |err| self.fail(err);
    }
    fn polled(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        switch (self.step) {
            .entering => {
                if (!std.mem.eql(u8, result.json, "\"out enter\"")) return self.later();
                self.step = .leaving;
                self.polls = 0;
                self.view.togglePictureInPicture() catch |err| return self.fail(err);
                self.later();
            },
            .leaving => {
                if (!std.mem.eql(u8, result.json, "\"in enter,leave\"")) return self.later();
                self.step = .done;
                self.app.quit();
            },
            else => {},
        }
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const store = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PictureInPictureSmoke" });
    defer allocator.free(store);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 200 });
    defer _ = window.destroy() catch {};
    var probe: Probe = .{ .app = app, .store = store };
    probe.view = web.View.init(allocator, &probe, Probe.event);
    window.show();
    try probe.view.attach(window, .{ .html = document, .user_data_folder = store, .page_listener = .{ .context = &probe, .event = Probe.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (probe.waiter) |thread| thread.join();
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.step == .done);
    std.debug.print("picture in picture: a playing video out and back from the host\n", .{});
}
