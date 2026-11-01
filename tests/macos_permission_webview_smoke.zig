//! A local page asks for the camera and the microphone through the engine's
//! mock devices. The app's handler denies the camera after a deferral, lets
//! a second deferral time out and allows a third; the microphone, which no
//! grant names, is denied without reaching the handler. Each answer gets a
//! fresh document, since the engine remembers a page's answers.
const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_test_mock_capture(native: *anyopaque) c_int;

const document =
    \\<!doctype html><script>
    \\chrome.webview.addEventListener('message',async e=>{
    \\if(e.data==='video'){try{const s=await navigator.mediaDevices.getUserMedia({video:true});
    \\chrome.webview.postMessage('video:'+s.getVideoTracks().length);s.getTracks().forEach(t=>t.stop())}catch(x){chrome.webview.postMessage('video-denied:'+x.name+':'+x.message+' secure='+isSecureContext+' devices='+typeof navigator.mediaDevices)}}
    \\if(e.data==='audio'){try{await navigator.mediaDevices.getUserMedia({audio:true});chrome.webview.postMessage('audio:granted')}catch(x){chrome.webview.postMessage('audio-denied:'+x.name)}}
    \\});
    \\addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('loaded'));
    \\</script>
;
const origin = "asset://app.ziggurat.invalid";
const registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true }};
const grants = [_]web.permissions.Grant{.{ .origin = origin, .kinds = .{ .camera = true } }};

const Step = enum { deny, audio, timeout, allow, done };

const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    err: ?anyerror = null,
    offers: u32 = 0,
    results: [3]?web.permissions.Result = @splat(null),
    pending: ?web.PermissionId = null,
    step: Step = .deny,
    fn fail(self: *Probe, err: anyerror) void {
        if (self.err == null) self.err = err;
        std.debug.print("macOS permission WebView: {s} at {s}\n", .{ @errorName(err), @tagName(self.step) });
        self.app.quit();
    }
    fn config(self: *Probe) web.Options {
        return .{
            .storage = .ephemeral,
            .html = document,
            .custom_schemes = &registrations,
            .local = .{ .scheme = "asset", .scheme_ipc = true },
            .permissions = .{ .grants = &grants, .handler = .{ .context = self, .handle = offer }, .require_user_gesture = false },
        };
    }
    fn offer(ptr: *anyopaque, value: web.PermissionOffer, responder: *web.PermissionResponder) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.offers += 1;
        if (value.kind != .camera or !std.mem.eql(u8, value.origin, origin) or value.user_initiated) return self.fail(error.WrongOffer);
        const timeout: u32 = if (self.step == .timeout) 50 else 10_000;
        self.pending = responder.deferDecision(.{ .timeout_ms = timeout, .completion = .{ .context = self, .complete = complete } }) catch |err| return self.fail(err);
        // Answer after a turn of the loop, as an app's prompt does.
        if (self.step != .timeout) self.app.post(.{ .context = self, .call = decide }) catch |err| self.fail(err);
    }
    fn decide(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        const id = self.pending orelse return self.fail(error.NoPending);
        self.pending = null;
        self.view.decidePermission(id, if (self.step == .allow) .allow_ephemeral else .deny_ephemeral) catch |err| self.fail(err);
    }
    fn complete(ptr: *anyopaque, result: web.permissions.Result) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        const index: usize = switch (self.step) {
            .deny => 0,
            .timeout => 1,
            .allow => 2,
            else => return self.fail(error.UnexpectedResult),
        };
        if (self.results[index] != null) return self.fail(error.DuplicateResult);
        self.results[index] = result;
        if (self.step == .timeout) self.pending = null;
    }
    fn send(self: *Probe, text: []const u8) void {
        self.view.postFor(self.view.pageId().?, text) catch |err| self.fail(err);
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .message => |text| self.message(view, text) catch |err| self.fail(err),
            .failed, .process_failed => self.fail(error.NativeFailure),
            else => {},
        }
    }
    fn message(self: *Probe, view: *web.View, text: []const u8) !void {
        errdefer std.debug.print("page: {s}\n", .{text});
        if (std.mem.eql(u8, text, "loaded")) {
            if (zwk_test_mock_capture(view.native.?) == 0) return error.NoMockDevices;
            return self.send("video");
        }
        switch (self.step) {
            .deny => {
                if (!std.mem.startsWith(u8, text, "video-denied:NotAllowedError:") or self.offers != 1) return error.WrongDenial;
                self.step = .audio;
                self.send("audio");
            },
            .audio => {
                if (!std.mem.startsWith(u8, text, "audio-denied:") or self.offers != 1) return error.MicrophoneOffered;
                self.step = .timeout;
                try view.refresh();
            },
            .timeout => {
                if (!std.mem.startsWith(u8, text, "video-denied:NotAllowedError:") or self.offers != 2) return error.WrongTimeout;
                self.step = .allow;
                try view.refresh();
            },
            .allow => {
                if (!std.mem.eql(u8, text, "video:1") or self.offers != 3) return error.WrongGrant;
                self.step = .done;
                self.app.quit();
            },
            .done => return error.UnexpectedMessage,
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
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
    try std.testing.expectEqual(@as(u32, 3), probe.offers);
    const expected = [_]web.permissions.Result{ .{ .decided = .deny_ephemeral }, .timed_out, .{ .decided = .allow_ephemeral } };
    for (expected, probe.results) |wanted, actual| try std.testing.expectEqual(wanted, actual orelse return error.MissingResult);
    _ = try probe.window.destroy();
    std.debug.print("macOS permission WebView: deferred camera denied, timed out and allowed; ungranted microphone denied\n", .{});
}
