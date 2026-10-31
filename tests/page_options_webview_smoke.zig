const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

const linux = builtin.os.tag == .linux;
const document = "<!doctype html><title>ticks</title><script>window.ticks=0;setInterval(()=>ticks++,10)</script>";

extern fn zpo_gestures(window: *anyopaque, swipe: *c_int, pinch: *c_int) c_int;
extern fn zwv_test_gestures(native: *anyopaque, swipe: *i32, pinch: *i32) i32;

/// Two pages in windows that never show: one that swipes between pages and
/// keeps running hidden, one with the options' defaults. The first page's
/// 10 ms timer keeps its rate; the second's slows down where its page is
/// hidden, as WebKitGTK's is.
const Page = struct {
    probe: *Probe,
    window: z.Window,
    store: []const u8,
    unthrottled: bool,
    view: web.View = undefined,
    loaded: bool = false,
    ticks: ?u32 = null,
    hidden: bool = false,

    fn options(self: *Page) web.Options {
        return .{
            .html = document,
            .storage = if (linux) .ephemeral else .profile,
            .user_data_folder = if (linux) "" else self.store,
            .swipe_navigation = self.unthrottled,
            .background_throttling = !self.unthrottled,
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn gestures(self: *Page) !void {
        var swipe: c_int = -1;
        var pinch: c_int = -1;
        if (linux) {
            if (zpo_gestures(self.window.nativeHandle().?, &swipe, &pinch) == 0) return error.GesturesUnknown;
        } else if (zwv_test_gestures(self.view.native.?, &swipe, &pinch) < 0) return error.GesturesUnknown;
        if (swipe != @intFromBool(self.unthrottled) or pinch != 0) {
            std.debug.print("swipe {d} pinch {d}\n", .{ swipe, pinch });
            return error.WrongGestures;
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, input: web.PageEvent) void {
        const self: *Page = @ptrCast(@alignCast(ptr));
        switch (input) {
            .completed => |info| {
                if (!info.success) return self.probe.fail(error.LoadFailed);
                if (self.loaded) return;
                self.loaded = true;
                self.gestures() catch |err| return self.probe.fail(err);
                self.probe.loaded();
            },
            else => {},
        }
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *Page = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.probe.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn measure(self: *Page) void {
        _ = self.view.evaluateJS("[ticks,document.visibilityState]", .{}, .{ .context = self, .complete = measured }) catch |err| self.probe.fail(err);
    }
    fn measured(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Page = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.probe.fail(error.ScriptFailed);
        var line = std.mem.tokenizeAny(u8, result.json, "[],\"");
        self.ticks = std.fmt.parseInt(u32, line.next() orelse "", 10) catch return self.probe.fail(error.WrongTicks);
        self.hidden = std.mem.eql(u8, line.next() orelse "", "hidden");
        self.probe.measured();
    }
};

const Probe = struct {
    app: *z.App,
    pages: [2]*Page = undefined,
    failure: ?anyerror = null,
    waiter: ?std.Thread = null,
    done: bool = false,

    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("page options: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn loaded(self: *Probe) void {
        for (self.pages) |item| if (!item.loaded) return;
        // The timers run for a while on their own, hidden.
        self.waiter = std.Thread.spawn(.{}, wait, .{self}) catch |err| return self.fail(err);
    }
    fn wait(self: *Probe) void {
        zio.sleep(1500 * std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = measure }) catch {};
    }
    fn measure(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        for (self.pages) |item| item.measure();
    }
    fn measured(self: *Probe) void {
        for (self.pages) |item| if (item.ticks == null) return;
        const free = self.pages[0];
        const kept = self.pages[1];
        std.debug.print("ticks: unthrottled {d} ({s}), default {d} ({s})\n", .{ free.ticks.?, if (free.hidden) "hidden" else "visible", kept.ticks.?, if (kept.hidden) "hidden" else "visible" });
        // At most once a second when throttled, a hundred times without.
        if (free.ticks.? < 40) return self.fail(error.Throttled);
        if (linux and (!kept.hidden or kept.ticks.? >= 40)) return self.fail(error.DefaultNotThrottled);
        self.done = true;
        self.app.quit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    // The environments' arguments differ, so their user data folders do.
    var stores: [2][]const u8 = .{ "", "" };
    if (!linux) {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        stores[0] = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PageOptionsSmoke" });
        stores[1] = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PageOptionsSmokeDefault" });
    }
    defer if (!linux) for (stores) |store| allocator.free(store);
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app };
    var pages: [2]Page = undefined;
    var windows: [2]z.Window = undefined;
    for (&pages, &windows, 0..) |*item, *window, i| {
        window.* = try app.createWindow(.{ .width = 320, .height = 200 });
        item.* = .{ .probe = &probe, .window = window.*, .store = stores[i], .unthrottled = i == 0 };
        probe.pages[i] = item;
    }
    defer for (windows) |window| {
        _ = window.destroy() catch {};
    };
    for (&pages) |*item| {
        item.view = web.View.init(allocator, item, Page.event);
        try item.view.attach(item.window, item.options());
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (probe.waiter) |thread| thread.join();
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.done);
    std.debug.print("page options: swipe and pinch as asked, a hidden page unthrottled\n", .{});
}
