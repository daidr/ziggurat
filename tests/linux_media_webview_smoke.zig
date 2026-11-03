//! A local page asks for the camera and the microphone through WebKitGTK's
//! mock devices: the app's handler defers the camera, allows it, and then
//! mutes and stops the capture; the microphone, which no grant names, is
//! denied without reaching the handler.
const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zwm_mock_devices(*anyopaque) c_int;

const document =
    \\<!doctype html><script>
    \\chrome.webview.addEventListener('message',async e=>{
    \\if(e.data==='video'){try{const s=await navigator.mediaDevices.getUserMedia({video:true});window.stream=s;
    \\s.getVideoTracks()[0].addEventListener('ended',()=>chrome.webview.postMessage('ended'));
    \\chrome.webview.postMessage('video:'+s.getVideoTracks().length)}catch(x){chrome.webview.postMessage('video-denied:'+x.name)}}
    \\if(e.data==='audio'){try{await navigator.mediaDevices.getUserMedia({audio:true});chrome.webview.postMessage('audio:granted')}catch(x){chrome.webview.postMessage('audio-denied:'+x.name)}}
    \\});
    \\addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('loaded'));
    \\</script>
;
const registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true }};
const grants = [_]web.permissions.Grant{.{ .origin = "asset://app.ziggurat.invalid", .kinds = .{ .camera = true } }};

const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    err: ?anyerror = null,
    offers: u32 = 0,
    decided: u32 = 0,
    pending: ?web.PermissionId = null,
    states: [8]web.CaptureState = undefined,
    state_count: usize = 0,
    ended: bool = false,
    step: enum { load, video, mute, stop, audio, done } = .load,
    fn fail(self: *Probe, err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("Linux media WebView: {s} at {s}\n", .{ @errorName(err), @tagName(self.step) });
        self.app.quit();
    }
    fn config(self: *Probe) web.Options {
        return .{
            .storage = .ephemeral,
            .html = document,
            .custom_schemes = &registrations,
            .local = .{ .scheme = "asset", .scheme_ipc = true },
            .permissions = .{ .grants = &grants, .handler = .{ .context = self, .handle = offer }, .require_user_gesture = false },
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn offer(ptr: *anyopaque, value: web.PermissionOffer, responder: *web.PermissionResponder) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.offers += 1;
        if (value.kind != .camera or !std.mem.eql(u8, value.origin, "asset://app.ziggurat.invalid") or value.user_initiated) return self.fail(error.WrongOffer);
        self.pending = responder.deferDecision(.{ .timeout_ms = 10_000, .completion = .{ .context = self, .complete = complete } }) catch |err| return self.fail(err);
        // The decision crosses a turn of the loop, as an app's prompt does.
        self.app.post(.{ .context = self, .call = allow }) catch |err| self.fail(err);
    }
    fn allow(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.view.decidePermission(self.pending orelse return self.fail(error.NoPending), .allow_ephemeral) catch |err| self.fail(err);
        self.pending = null;
    }
    fn complete(ptr: *anyopaque, result: web.permissions.Result) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .decided or result.decided != .allow_ephemeral) return self.fail(error.WrongPermissionResult);
        self.decided += 1;
    }
    fn page(ptr: *anyopaque, view: *web.View, value: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .capture_changed => |change| {
                // The denied microphone may tell that it captures nothing.
                if (change.device != .camera) return if (change.state != .none) self.fail(error.WrongDevice);
                if (self.state_count < self.states.len) self.states[self.state_count] = change.state;
                self.state_count += 1;
                const now = view.captureState(.camera) catch |err| return self.fail(err);
                if (now != change.state) return self.fail(error.StateMismatch);
                switch (change.state) {
                    .active => if (self.step == .video) {
                        self.step = .mute;
                        view.setCaptureState(.camera, .muted) catch |err| self.fail(err);
                    },
                    .muted => if (self.step == .mute) {
                        self.step = .stop;
                        view.setCaptureState(.camera, .none) catch |err| self.fail(err);
                    },
                    .none => if (self.step == .stop) {
                        std.testing.expectError(error.NotCapturing, view.setCaptureState(.camera, .active)) catch |err| return self.fail(err);
                        self.step = .audio;
                        view.postFor(view.pageId().?, "audio") catch |err| self.fail(err);
                    },
                }
            },
            else => {},
        }
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |text| {
                if (std.mem.eql(u8, text, "loaded")) {
                    if (zwm_mock_devices(self.window.nativeHandle().?) == 0) return self.fail(error.NoWebView);
                    self.step = .video;
                    view.postFor(view.pageId().?, "video") catch |err| self.fail(err);
                } else if (std.mem.eql(u8, text, "video:1")) {
                    if (self.offers != 1 or self.decided != 1) self.fail(error.WrongOfferCount);
                } else if (std.mem.eql(u8, text, "ended")) {
                    self.ended = true;
                    if (self.step == .done) self.app.quit();
                } else if (std.mem.startsWith(u8, text, "audio-denied:")) {
                    if (self.step != .audio or self.offers != 1) return self.fail(error.MicrophoneOffered);
                    self.step = .done;
                    if (self.ended) self.app.quit();
                } else {
                    std.debug.print("page: {s}\n", .{text});
                    self.fail(error.UnexpectedMessage);
                }
            },
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app };
    probe.window = try app.createWindow(.{ .width = 320, .height = 240 });
    probe.window.show();
    probe.view = web.View.init(allocator, &probe, Probe.event);
    try probe.view.attach(probe.window, probe.config());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (probe.err) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.step == .done);
    try std.testing.expectEqual(@as(u32, 1), probe.offers);
    try std.testing.expectEqualSlices(web.CaptureState, &.{ .active, .muted, .none }, probe.states[0..@min(probe.state_count, probe.states.len)]);
    try std.testing.expect(probe.ended);
    _ = try probe.window.destroy();
    std.debug.print("Linux media WebView: deferred camera grant, capture active/muted/stopped, ungranted microphone denied\n", .{});
}
