const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

const linux = builtin.os.tag == .linux;
const document =
    \\<!doctype html><html><head><title>facts</title>
    \\<meta name="theme-color" content="#111111" media="(max-width: 1px)">
    \\<meta name="theme-color" content="dodgerblue">
    \\<style>body{margin:8px}#box{width:250px;height:120px}</style></head>
    \\<body><div id="box"></div>
    \\<script>
    \\chrome.webview.postMessage('hello');
    \\const tone='data:audio/wav;base64,UklGRiwAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQgAAAAAAP9//3//fw==';
    \\window.autoplayResult='pending';
    \\try{new Audio(tone).play().then(()=>window.autoplayResult='played',e=>window.autoplayResult=e.name)}catch(e){window.autoplayResult=e.name}
    \\</script></body></html>
;
const initializers = [_]web.DocumentInitializer{.{ .body = "window.__everywhere=(window.__everywhere||0)+1;", .origins = &.{web.document_initializers.any_origin}, .frames = .all }};

/// A page with a theme color and a box of known size: the View tells the
/// color and changes, resizes its window to the content, lets audible
/// media play without a gesture, runs an all-frame initializer, reports
/// whether a script's window.open had a gesture, and with untrusted drops
/// the page's messages while still telling its facts.
const Probe = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window,
    store: []const u8,
    view: web.View = undefined,
    step: enum { load, recolor, popup, untrusted, done } = .load,
    untrusted: bool = false,
    messages: u32 = 0,
    colors: u32 = 0,
    sizes: u32 = 0,
    loaded: bool = false,
    popup_gesture: ?bool = null,
    failure: ?anyerror = null,

    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("page facts step {s}: {s}\n", .{ @tagName(self.step), @errorName(err) });
        self.app.quit();
    }
    fn options(self: *Probe) web.Options {
        return .{
            .html = document,
            .storage = if (linux) .ephemeral else .profile,
            .user_data_folder = if (linux) "" else self.store,
            .theme_color = true,
            .fit_content = .{ .max_width = 400, .max_height = 300 },
            .autoplay = .allow,
            .untrusted = self.untrusted,
            .document_initializers = &initializers,
            .policy = .{ .new_window = .notify },
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            .message => |text| {
                if (!std.mem.eql(u8, text, "hello")) return self.fail(error.WrongMessage);
                if (self.untrusted) return self.fail(error.UntrustedMessageDelivered);
                self.messages += 1;
            },
            .policy_request => |request| {
                if (request.kind != .new_window or self.step != .popup) return;
                self.popup_gesture = request.user_gesture orelse return self.fail(error.GestureUnknown);
                self.check();
            },
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .theme_color_changed => |change| {
                self.colors += 1;
                const color = change.color orelse return self.fail(error.ThemeColorLost);
                if (!web.Rgba.eql(view.themeColor(), color)) return self.fail(error.ThemeColorMismatch);
                if (self.step == .recolor) {
                    if (!std.meta.eql(color, web.Rgba{ .r = 255, .g = 0, .b = 0, .a = 128 })) return self.fail(error.WrongThemeColor);
                    self.step = .popup;
                    _ = view.evaluateJS("window.open('https://example.test/popup');1", .{}, .{ .context = self, .complete = ignored }) catch |err| self.fail(err);
                } else if (!std.meta.eql(color, web.Rgba{ .r = 0x1e, .g = 0x90, .b = 0xff, .a = 255 })) return self.fail(error.WrongThemeColor);
                self.check();
            },
            .content_size_changed => |change| {
                self.sizes += 1;
                if (change.size.width != 266 or change.size.height != 136) {
                    std.debug.print("content size {d}x{d}\n", .{ change.size.width, change.size.height });
                    return self.fail(error.WrongContentSize);
                }
                self.check();
            },
            .completed => |info| {
                if (!info.success) return self.fail(error.LoadFailed);
                self.loaded = true;
                self.check();
            },
            else => {},
        }
    }
    fn ignored(_: *anyopaque, _: web.ScriptResult) void {}
    fn check(self: *Probe) void {
        switch (self.step) {
            .load, .untrusted => {
                if (!self.loaded or self.view.themeColor() == null or self.view.contentSize() == null) return;
                _ = self.view.evaluateJS("(()=>{const f=document.createElement('iframe');document.body.append(f);f.style.display='none';return [window.autoplayResult,window.__everywhere,f.contentWindow.__everywhere].join(' ')})()", .{}, .{ .context = self, .complete = checked }) catch |err| self.fail(err);
            },
            .popup => {
                const gesture = self.popup_gesture orelse return;
                // WebKit and WebView2 both run the app's own script as a
                // user's gesture.
                if (!gesture) return self.fail(error.WrongGesture);
                self.step = .untrusted;
                self.untrusted = true;
                self.loaded = false;
                self.view.reload(self.options()) catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn checked(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        // Media the engine cannot decode may fail otherwise, but never for
        // the lack of a gesture.
        if (std.mem.indexOf(u8, result.json, "NotAllowedError") != null or std.mem.indexOf(u8, result.json, "pending") != null) {
            std.debug.print("autoplay {s}\n", .{result.json});
            return self.fail(error.AutoplayBlocked);
        }
        if (!std.mem.endsWith(u8, result.json, " 1 1\"")) {
            std.debug.print("initializer runs {s}\n", .{result.json});
            return self.fail(error.InitializerFrames);
        }
        const bounds = self.window.clientBounds() catch |err| return self.fail(err);
        if (bounds.width != 266 or bounds.height != 136) {
            std.debug.print("window {d}x{d}\n", .{ bounds.width, bounds.height });
            return self.fail(error.WindowNotFitted);
        }
        const pid = self.view.processId() catch |err| return self.fail(err);
        if ((pid != null) == linux) return self.fail(error.WrongProcessId);
        if (self.step == .untrusted) {
            if (self.messages != 1) return self.fail(error.TrustedMessageMissing);
            self.step = .done;
            self.app.quit();
            return;
        }
        self.step = .recolor;
        _ = self.view.evaluateJS("document.querySelector('meta[content=dodgerblue]').content='rgb(255 0 0 / 50%)';1", .{}, .{ .context = self, .complete = ignored }) catch |err| self.fail(err);
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const store = if (linux) try allocator.dupe(u8, "") else blk: {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        break :blk try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PageFactsSmoke" });
    };
    defer allocator.free(store);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 200, .height = 150 });
    defer _ = window.destroy() catch {};
    var probe: Probe = .{ .allocator = allocator, .app = app, .window = window, .store = store };
    probe.view = web.View.init(allocator, &probe, Probe.event);
    try probe.view.attach(window, probe.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.step == .done and probe.colors >= 3 and probe.sizes >= 2);
    std.debug.print("page facts: theme color and its change, window fitted to content, autoplay, all-frame initializer, popup gesture, untrusted messages dropped\n", .{});
}
