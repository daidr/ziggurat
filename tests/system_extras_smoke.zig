//! Hidden-window check of the system helpers against the real session: a
//! SIGTERM to this process quits through requestQuit (Linux), the alert
//! sound and pointer position answer, and a worker lists installed apps.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

const Raise = struct {
    fn call(_: *anyopaque) void {
        std.posix.raise(std.posix.SIG.TERM) catch unreachable;
    }
};
const Quit = struct {
    fn call(ptr: *anyopaque) void {
        const app: *z.App = @ptrCast(@alignCast(ptr));
        app.quit();
    }
};

fn listApps(result: *?anyerror, count: *usize) void {
    var worker = system.shell.Worker.init(main_thread) catch |err| {
        result.* = err;
        return;
    };
    defer worker.deinit();
    var apps = worker.installedApps(std.heap.page_allocator) catch |err| {
        result.* = err;
        return;
    };
    defer apps.deinit();
    count.* = apps.items.len;
    for (apps.items, 0..) |app, index| {
        if (app.name.len == 0 or app.id.len == 0 or app.path.len == 0) result.* = error.EmptyField;
        if (index != 0 and std.ascii.orderIgnoreCase(apps.items[index - 1].name, app.name) == .gt) result.* = error.Unsorted;
    }
    const missing = if (builtin.os.tag == .windows) "C:\\does-not-exist\\missing.exe" else "/nonexistent/missing.desktop";
    if (worker.launchApp(missing)) |_| {
        result.* = error.LaunchedMissing;
    } else |_| {}
}
var main_thread: std.Thread.Id = undefined;

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    main_thread = std.Thread.getCurrentId();
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    _ = try app.createWindow(.{ .title = "System extras" });

    try system.desktop.beep(app);
    // Wayland keeps the global pointer position private.
    const cursor: ?z.ScreenPoint = system.desktop.cursorPosition(app) catch |err| if (@as(anyerror, err) == error.UnsupportedCapability) null else return err;

    var list_result: ?anyerror = null;
    var app_count: usize = 0;
    const thread = try std.Thread.spawn(.{}, listApps, .{ &list_result, &app_count });
    thread.join();
    if (list_result) |err| return err;

    var quit: system.signals.QuitOnSignals = .{};
    if (system.signals.capabilities.quit_on_signals) {
        try quit.start(app);
        try app.post(.{ .context = app, .call = Raise.call });
    } else {
        try std.testing.expectError(error.UnsupportedCapability, quit.start(app));
        try app.post(.{ .context = app, .call = Quit.call });
    }
    try app.run();
    if (system.signals.capabilities.quit_on_signals) {
        try std.testing.expectEqual(@as(c_int, std.posix.SIG.TERM), quit.last_signal);
        try std.testing.expectEqual(z.App.QuitResult.accepted, quit.last_result.?);
        try std.testing.expect(!quit.active());
    }
    std.debug.print("system extras passed: signal quit={}, cursor={?}, installed apps={d}\n", .{ system.signals.capabilities.quit_on_signals, cursor, app_count });
}
