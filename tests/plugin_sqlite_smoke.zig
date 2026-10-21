const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const runtime = @import("ziggurat_page_runtime");
const sqlite_plugin = @import("ziggurat_plugin_sqlite");
const Watchdog = @import("watchdog.zig").Watchdog;

const html = "<!doctype html><meta charset=utf-8><title>SQLite plugin</title><script>" ++ @embedFile("plugin_sqlite_page") ++ "</script>";

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    controls: runtime.WindowControls = undefined,
    host: runtime.Host = undefined,
    done: bool = false,
    failure: ?anyerror = null,

    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("sqlite plugin smoke: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn send(context: *anyopaque, bytes: []const u8) !void {
        const self: *State = @ptrCast(@alignCast(context));
        try self.view.post(bytes);
    }
    fn event(context: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (value) {
            .message => |text| {
                if (self.host.receive(text) == .handled) return;
                self.message(text) catch |err| self.fail(err);
            },
            .failed => self.fail(error.WebViewFailed),
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
    }
    fn message(self: *State, text: []const u8) !void {
        if (std.mem.startsWith(u8, text, "sq-failed:")) {
            std.debug.print("{s}\n", .{text});
            return error.PageFailed;
        }
        if (std.mem.eql(u8, text, "sq-done")) {
            self.done = true;
            self.app.quit();
            return;
        }
        return error.UnexpectedMessage;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const directory = try std.fs.path.join(allocator, &.{ base, "data" });
    defer allocator.free(directory);

    const app = try z.App.init(allocator);
    defer app.deinit();
    var plugin: sqlite_plugin.Plugin = undefined;
    try plugin.init(allocator, .{ .post = .app(app), .directory = directory });
    var state: State = .{ .allocator = allocator, .app = app };
    state.window = try app.createWindow(.{ .title = "SQLite plugin smoke" });
    state.controls = .{ .window = state.window };
    state.host = .init(allocator, .{ .transport = .{ .context = &state, .send = State.send }, .controls = state.controls.controls() });
    try state.host.use(plugin.plugin());
    state.view = web.View.init(allocator, &state, State.event);

    var profile: []u8 = &.{};
    defer allocator.free(profile);
    if (builtin.os.tag == .windows) {
        const local = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "SqlitePluginSmoke" });
        try state.view.attach(state.window, .{ .html = html, .user_data_folder = profile });
    } else {
        try state.view.attach(state.window, .{ .html = html, .storage = .ephemeral });
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    state.host.detach();
    plugin.deinit();
    try std.testing.expect(!watchdog.expired);
    if (state.failure) |err| return err;
    try std.testing.expect(state.done);
    // The database is a file in the plugin's directory.
    try tmp.dir.access("data/notes/app.db", .{});
    std.debug.print("sqlite plugin WebView smoke passed: denied name, nested database, BLOB and bigint values, batched transactions, rollback, multi-part query, read-only reopen\n", .{});
}
