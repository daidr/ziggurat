//! macOS system services without a window: the login Keychain, sleep
//! assertions, desktop snapshots, the app's appearance and its change
//! notification, user folders, shell hand-offs and installed applications.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const system = @import("ziggurat_system");

pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };

const secrets = system.secrets;
const desktop = system.desktop;
const theme = system.theme;

fn checkSecrets() !void {
    const service = "dev.ziggurat.smoke.macos-services";
    const key = "token \u{79d8}\u{5bc6}";
    var buffer: [secrets.max_secret_bytes]u8 = undefined;
    try secrets.delete(service, key);
    try std.testing.expectError(error.SecretNotFound, secrets.get(service, key, &buffer));
    try secrets.set(service, key, "first");
    try std.testing.expectEqualStrings("first", try secrets.get(service, key, &buffer));
    // Replacing keeps one item.
    try secrets.set(service, key, "second \u{1f511}");
    try std.testing.expectEqualStrings("second \u{1f511}", try secrets.get(service, key, &buffer));
    var small: [3]u8 = undefined;
    try std.testing.expectError(error.SecretTooLarge, secrets.get(service, key, &small));
    try secrets.set(service, key, "");
    try std.testing.expectEqual(@as(usize, 0), (try secrets.get(service, key, &buffer)).len);
    try secrets.delete(service, key);
    try std.testing.expectError(error.SecretNotFound, secrets.get(service, key, &buffer));
    // Deleting nothing succeeds.
    try secrets.delete(service, key);
}

fn checkPower() !void {
    var system_sleep = try system.power.Assertion.acquire(.{ .reason = "ziggurat smoke" });
    var display_sleep = try system.power.Assertion.acquire(.{ .kind = .display, .reason = "ziggurat smoke display" });
    display_sleep.release();
    display_sleep.release();
    system_sleep.release();
}

fn checkDirectories() !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = zio.getenv("HOME").?;
    const support = try system.identity.applicationDirectory(.data, "dev.ziggurat.smoke", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, support, home));
    try std.testing.expect(std.mem.endsWith(u8, support, "/Library/Application Support/dev.ziggurat.smoke"));
    try std.testing.expect((try system.identity.directory(.temp, &buffer)).len > 1);
}

fn checkShell(allocator: std.mem.Allocator) !void {
    var worker = try system.shell.Worker.init(main_thread);
    defer worker.deinit();
    var apps = try worker.installedApps(allocator);
    defer apps.deinit();
    var finder = false;
    for (apps.items) |app| {
        if (std.mem.eql(u8, app.id, "com.apple.finder")) finder = std.mem.endsWith(u8, app.path, "/Finder.app");
    }
    try std.testing.expect(finder);
    // A file moved to the Trash leaves its folder.
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try system.identity.directory(.temp, &path_buffer);
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buffer, "{s}/ziggurat-trash-smoke-{d}.txt", .{ temp, std.c.getpid() });
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = path, .data = "trash" });
    try worker.trash(path, .{});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(zio.io(), path, .{}));
    try std.testing.expectError(error.FileNotFound, worker.openPath(path, .{}));
    try std.testing.expectError(error.FileNotFound, worker.reveal(path, .{}));
    // A scheme no application handles is refused before anything opens.
    try std.testing.expectError(error.NoAssociation, worker.openUrl("ziggurat-smoke-none://x", .{ .extra_schemes = &.{"ziggurat-smoke-none"} }));
}

var main_thread: std.Thread.Id = undefined;

/// Forcing the app's appearance changes its effective appearance, which a
/// preferences watch reports on the main thread once per burst.
const Flip = struct {
    app: *z.App,
    watch: desktop.Watch = undefined,
    step: u8 = 0,
    failure: ?anyerror = null,

    fn changed(ptr: *anyopaque, change: desktop.Change) void {
        const self: *Flip = @ptrCast(@alignCast(ptr));
        self.check(change) catch |err| {
            self.failure = err;
            self.finish();
        };
    }
    fn check(self: *Flip, change: desktop.Change) !void {
        try std.testing.expect(change.preferences);
        const scheme = (try desktop.preferences(self.app)).color_scheme;
        switch (self.step) {
            0 => {
                if (scheme != .dark) return;
                self.step = 1;
                theme.apply(self.app, .light, false);
            },
            1 => {
                if (scheme != .light) return;
                self.step = 2;
                self.finish();
            },
            else => {},
        }
    }
    fn finish(self: *Flip) void {
        theme.apply(self.app, .system, false);
        self.watch.stop();
        self.app.quit();
    }
};

fn watchdog() void {
    zio.sleep(20 * std.time.ns_per_s);
    std.debug.print("macOS services smoke timed out waiting for appearance changes\n", .{});
    std.process.exit(1);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    main_thread = std.Thread.getCurrentId();

    try checkSecrets();
    try checkPower();
    try checkDirectories();
    try checkShell(allocator);

    const app = try z.App.init(allocator);
    defer app.deinit();
    var monitors: [desktop.max_monitors]desktop.Monitor = undefined;
    const count = try desktop.monitors(app, &monitors);
    try std.testing.expect(count >= 1);
    try std.testing.expect(monitors[0].primary and monitors[0].bounds.x == 0 and monitors[0].bounds.y == 0);
    try std.testing.expect(monitors[0].scale >= 1 and monitors[0].bounds.width > 0);
    try std.testing.expect(monitors[0].work_area.height <= monitors[0].bounds.height);
    const prefs = try desktop.preferences(app);
    try std.testing.expect(prefs.color_scheme != .unknown and prefs.accent != null and prefs.reduce_transparency != null);
    const power = try desktop.power(app);
    try std.testing.expect(power.source != .unknown and power.saver != null);
    const network = try desktop.network(app);
    try std.testing.expect(network.state != .unknown);
    _ = try desktop.cursorPosition(app);

    // A Follower applies a forced source and reads it back at once.
    var follower: theme.Follower = .{};
    try follower.start(app, .{ .source = .dark });
    try std.testing.expect(follower.isDark());
    follower.setSource(.light);
    try std.testing.expect(!follower.isDark());
    follower.stop();
    theme.apply(app, .system, false);

    var flip: Flip = .{ .app = app };
    flip.watch = desktop.Watch.init(&flip, Flip.changed);
    try flip.watch.start(app, .{ .preferences = true });
    try std.testing.expectEqual(@as(usize, 1), desktop.resourceCount());
    theme.apply(app, .dark, true);
    const guard = try std.Thread.spawn(.{}, watchdog, .{});
    guard.detach();
    try app.run();
    if (flip.failure) |err| return err;
    try std.testing.expectEqual(@as(u8, 2), flip.step);
    try std.testing.expectEqual(@as(usize, 0), desktop.resourceCount());
    std.debug.print("macOS services smoke passed\n", .{});
}
