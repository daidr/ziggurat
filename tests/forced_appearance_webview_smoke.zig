//! A page loads in the appearance the app forces (theme Source), never in
//! the system's first: its theme color, which the page picks with
//! prefers-color-scheme, is the forced appearance's from the first one the
//! View tells, through a dark load and then a light one.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

const windows = builtin.os.tag == .windows;
const document =
    \\<!doctype html><html><head><title>appearance</title>
    \\<meta name="color-scheme" content="light dark">
    \\<meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
    \\<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
    \\</head><body>appearance</body></html>
;
const black: web.Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
const white: web.Rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

const Probe = struct {
    app: *z.App,
    store: []const u8,
    view: web.View = undefined,
    step: enum { dark, light, done } = .dark,
    loaded: bool = false,
    colors: u32 = 0,
    failure: ?anyerror = null,

    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("forced appearance step {s}: {s}\n", .{ @tagName(self.step), @errorName(err) });
        self.app.quit();
    }
    fn options(self: *Probe) web.Options {
        return .{
            .html = document,
            .storage = if (windows) .profile else .ephemeral,
            .user_data_folder = self.store,
            .theme_color = true,
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn wanted(self: *const Probe) web.Rgba {
        return if (self.step == .dark) black else white;
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, input: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .theme_color_changed => |change| {
                const color = change.color orelse return;
                if (self.step == .done) return;
                // The other appearance's color, even for a moment, is the
                // system's showing through before the forced one.
                if (!std.meta.eql(color, self.wanted())) {
                    std.debug.print("theme color {d},{d},{d} in the {s} appearance\n", .{ color.r, color.g, color.b, @tagName(self.step) });
                    return self.fail(error.SystemAppearanceShown);
                }
                self.colors += 1;
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
    fn check(self: *Probe) void {
        if (!self.loaded or !std.meta.eql(self.view.themeColor(), self.wanted())) return;
        switch (self.step) {
            .dark => {
                self.step = .light;
                self.loaded = false;
                system.theme.apply(self.app, .light, false);
                self.view.reload(self.options()) catch |err| self.fail(err);
            },
            .light => {
                self.step = .done;
                self.app.quit();
            },
            .done => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const store = if (!windows) try allocator.dupe(u8, "") else blk: {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        break :blk try std.fs.path.join(allocator, &.{ local, "Ziggurat", "ForcedAppearanceSmoke" });
    };
    defer allocator.free(store);
    const app = try z.App.init(allocator);
    defer app.deinit();
    // Forced before the page exists: it loads dark from its first document.
    system.theme.apply(app, .dark, true);
    const window = try app.createWindow(.{ .width = 240, .height = 160 });
    defer _ = window.destroy() catch {};
    var probe: Probe = .{ .app = app, .store = store };
    probe.view = web.View.init(allocator, &probe, Probe.event);
    try probe.view.attach(window, probe.options());
    var watchdog: Watchdog = .{ .app = app, .seconds = 30 };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    system.theme.apply(app, .system, false);
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.step == .done and probe.colors >= 2);
    std.debug.print("forced appearance: pages load dark, then light, in the app's forced appearance and never the system's first\n", .{});
}
