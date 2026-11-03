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
const registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true }};
const start = "<!doctype html><title>start</title><p>start</p>";
const long = "<!doctype html><title>long</title><div style=\"height:5000px\">long</div><input id=f>";

/// A page goes from / to /long and scrolls; its session, saved, comes back
/// in a second View: /long again, Back to / included on Linux, with its
/// scroll position. Windows and macOS save the URI alone.
const Probe = struct {
    app: *z.App,
    windows: [2]z.Window,
    views: [2]web.View = undefined,
    store: []const u8,
    state: ?[]u8 = null,
    step: enum { first, long, scrolled, restoring, restored, back, done } = .first,
    failure: ?anyerror = null,
    waiter: ?std.Thread = null,

    fn fail(self: *Probe, err: anyerror) void {
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
        // WebKit saves the scroll position a moment after scrolling stops.
        self.waiter = std.Thread.spawn(.{}, wait, .{self}) catch |err| return self.fail(err);
    }
    fn wait(self: *Probe) void {
        zio.sleep(1000 * std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = save }) catch {};
    }
    fn save(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.state = self.views[0].sessionState(std.heap.page_allocator) catch |err| return self.fail(err);
        const parsed = web.session_state.parse(self.state.?) catch |err| return self.fail(err);
        if (!std.mem.eql(u8, parsed.uri, "asset://app.ziggurat.invalid/long") or (linux and parsed.native.len == 0)) {
            std.debug.print("saved {s} with {d} bytes\n", .{ parsed.uri, parsed.native.len });
            return self.fail(error.WrongState);
        }
        self.step = .restoring;
        self.views[1].attach(self.windows[1], self.options(1)) catch |err| self.fail(err);
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
        const expected = if (linux) "\"/long 1200 2\"" else "\"/long 0 2\"";
        if (!std.mem.eql(u8, result.json, expected)) return self.fail(error.WrongRestore);
        if (!linux) {
            self.step = .done;
            return self.app.quit();
        }
        self.step = .back;
        self.views[1].goBack() catch |err| self.fail(err);
    }
    fn back(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "\"/\"")) return self.fail(error.WrongBack);
        self.step = .done;
        self.app.quit();
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
    if (probe.waiter) |thread| thread.join();
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.step == .done);
    std.debug.print("session state: saved and restored with its scroll position (Linux) and Back\n", .{});
}
