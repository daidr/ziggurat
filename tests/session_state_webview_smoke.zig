const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);

const linux = builtin.os.tag == .linux;
/// WebKitGTK and WKWebView: explicit ephemeral storage, no WebView2 folder.
const webkit = linux or builtin.os.tag == .macos;
/// Whether some of a page's window shows on screen (WebKit on macOS).
const macos_hooks = if (builtin.os.tag == .macos) struct {
    extern fn zwk_test_on_screen(*anyopaque) c_int;
} else struct {};
const registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true }};
const start = "<!doctype html><title>start</title><p>start</p>";
const long = "<!doctype html><title>long</title><div style=\"height:5000px\">long</div><input id=f>";

/// A page goes from / to /long and scrolls; its session, saved once WebKit
/// noted the scroll position, comes back in a second View in a hidden
/// window: /long again, Back to / included, with its scroll position, which
/// it keeps as the window shows (WebKit on macOS would put it back at the
/// top). Windows saves the URI alone.
const Probe = struct {
    app: *z.App,
    windows: [2]z.Window,
    views: [2]web.View = undefined,
    store: []const u8,
    state: ?[]u8 = null,
    step: enum { first, long, scrolled, saving, restoring, restored, showing, back, done } = .first,
    failure: ?anyerror = null,
    waiter: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Ticks of the step that waits, and a script of it in flight.
    tries: usize = 0,
    busy: bool = false,

    fn fail(self: *Probe, err: anyerror) void {
        self.stop.store(true, .release);
        if (self.failure == null) self.failure = err;
        std.debug.print("session state step {s}: {s}\n", .{ @tagName(self.step), @errorName(err) });
        self.app.quit();
    }
    fn options(self: *Probe, index: usize) web.Options {
        return .{
            .html = start,
            .storage = if (webkit) .ephemeral else .profile,
            .user_data_folder = if (webkit) "" else self.store,
            .custom_schemes = &registrations,
            .local = .{ .scheme = "asset", .resources = &.{.{ .path = "/long", .mime = "text/html", .bytes = long }} },
            .page_listener = .{ .context = self, .event = if (index == 0) first else second },
        };
    }
    fn first(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        const info = switch (input) {
            .completed => |value| value,
            else => return,
        };
        if (!info.success) return self.fail(error.LoadFailed);
        switch (self.step) {
            .first => {
                self.step = .long;
                view.navigateLocal("/long") catch |err| self.fail(err);
            },
            .long => {
                self.step = .scrolled;
                _ = view.evaluateJS("scrollTo(0,1200);document.getElementById('f').value='typed';scrollY", .{}, .{ .context = self, .complete = scrolled }) catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn scrolled(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "1200")) return self.fail(error.ScrollFailed);
        // WebKit saves the scroll position a moment after scrolling stops:
        // the state is saved once it holds it.
        self.step = .saving;
        self.waiter = std.Thread.spawn(.{}, wait, .{self}) catch |err| return self.fail(err);
    }
    /// Ticks the steps that wait, every 100 ms, until the probe ends.
    fn wait(self: *Probe) void {
        while (!self.stop.load(.acquire)) {
            zio.sleep(100 * std.time.ns_per_ms);
            self.app.post(.{ .context = self, .call = tick }) catch return;
        }
    }
    fn tick(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (self.failure != null) return;
        switch (self.step) {
            .saving => self.save(),
            .showing => if (!self.busy) {
                self.busy = true;
                _ = self.views[1].evaluateJS("[document.visibilityState,scrollY].join(' ')", .{}, .{ .context = self, .complete = shown }) catch |err| self.fail(err);
            },
            else => {},
        }
    }
    /// Whether a session state holds the scroll position (x, y), as WebKit
    /// encodes it on macOS and in WebKitGTK: two 32-bit integers in a row,
    /// little-endian on the machines this runs on.
    fn holdsScroll(native: []const u8, x: i32, y: i32) bool {
        var pair: [8]u8 = undefined;
        std.mem.writeInt(i32, pair[0..4], x, .little);
        std.mem.writeInt(i32, pair[4..8], y, .little);
        return std.mem.indexOf(u8, native, &pair) != null;
    }
    fn save(self: *Probe) void {
        if (self.state) |value| std.heap.page_allocator.free(value);
        self.state = self.views[0].sessionState(std.heap.page_allocator) catch |err| return self.fail(err);
        const parsed = web.session_state.parse(self.state.?) catch |err| return self.fail(err);
        if (!std.mem.eql(u8, parsed.uri, "asset://app.ziggurat.invalid/long") or (webkit and parsed.native.len == 0)) {
            std.debug.print("saved {s} with {d} bytes\n", .{ parsed.uri, parsed.native.len });
            return self.fail(error.WrongState);
        }
        if (webkit and !holdsScroll(parsed.native, 0, 1200)) {
            self.tries += 1;
            if (self.tries == 100) return self.fail(error.ScrollNotSaved);
            return;
        }
        self.tries = 0;
        self.step = .restoring;
        self.views[1].attach(self.windows[1], self.options(1)) catch |err| self.fail(err);
    }
    fn shown(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.busy = false;
        if (result != .json) return self.fail(error.ScriptFailed);
        if (!std.mem.eql(u8, result.json, "\"visible 1200\"")) {
            self.tries += 1;
            if (self.tries == 100) {
                std.debug.print("shown {s}\n", .{result.json});
                // WebKit reports a page hidden while the window server
                // says its window is not on screen (covered by another
                // app's windows, or the display asleep, as on an unattended
                // runner); the place it keeps is still checked.
                if (builtin.os.tag == .macos and std.mem.eql(u8, result.json, "\"hidden 1200\"") and
                    macos_hooks.zwk_test_on_screen(self.views[1].native.?) == 0)
                {
                    std.debug.print("session state: the window is not on screen, so its page stays hidden; scroll position kept\n", .{});
                } else return self.fail(error.WrongRestore);
            } else return;
        }
        self.step = .back;
        self.views[1].goBack() catch |err| self.fail(err);
    }
    fn second(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        const info = switch (input) {
            .completed => |value| value,
            else => return,
        };
        if (!info.success) return self.fail(error.LoadFailed);
        switch (self.step) {
            .restoring => {
                self.step = .restored;
                view.restoreSessionState(self.state.?) catch |err| self.fail(err);
            },
            .restored => _ = view.evaluateJS("[location.pathname,scrollY,history.length].join(' ')", .{}, .{ .context = self, .complete = restored }) catch |err| self.fail(err),
            .back => _ = view.evaluateJS("location.pathname", .{}, .{ .context = self, .complete = back }) catch |err| self.fail(err),
            else => {},
        }
    }
    fn restored(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        std.debug.print("restored {s}\n", .{result.json});
        const expected = if (webkit) "\"/long 1200 2\"" else "\"/long 0 2\"";
        if (!std.mem.eql(u8, result.json, expected)) return self.fail(error.WrongRestore);
        if (!webkit) {
            self.finish();
            return;
        }
        // Restored in a hidden window, the page keeps its place as the
        // window shows.
        self.step = .showing;
        self.windows[1].show();
    }
    fn finish(self: *Probe) void {
        self.step = .done;
        self.stop.store(true, .release);
        self.app.quit();
    }
    fn back(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "\"/\"")) return self.fail(error.WrongBack);
        self.finish();
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        _ = ptr;
        switch (input) {
            .failed, .process_failed => std.debug.print("native page failed\n", .{}),
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const store = if (webkit) try allocator.dupe(u8, "") else blk: {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        break :blk try std.fs.path.join(allocator, &.{ local, "Ziggurat", "SessionStateSmoke" });
    };
    defer allocator.free(store);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const windows = [2]z.Window{ try app.createWindow(.{ .width = 320, .height = 200 }), try app.createWindow(.{ .width = 320, .height = 200 }) };
    defer for (windows) |window| {
        _ = window.destroy() catch {};
    };
    var probe: Probe = .{ .app = app, .windows = windows, .store = store };
    defer if (probe.state) |value| std.heap.page_allocator.free(value);
    for (&probe.views) |*view| view.* = web.View.init(allocator, &probe, Probe.event);
    try probe.views[0].attach(windows[0], probe.options(0));
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    probe.stop.store(true, .release);
    if (probe.waiter) |thread| thread.join();
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.step == .done);
    std.debug.print("session state: saved and restored with its scroll position, kept as a hidden window shows (WebKit), and Back\n", .{});
}
