const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const runtime = @import("ziggurat_page_runtime");
const watch_plugin = @import("ziggurat_plugin_watch");
const Watchdog = @import("watchdog.zig").Watchdog;

const html = "<!doctype html><meta charset=utf-8><title>Watch plugin</title><script>" ++ @embedFile("plugin_watch_page") ++ "</script>";

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    project: std.Io.Dir,
    window: z.Window = undefined,
    view: web.View = undefined,
    controls: runtime.WindowControls = undefined,
    host: runtime.Host = undefined,
    done: bool = false,
    failure: ?anyerror = null,

    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("watch plugin smoke: {s}\n", .{@errorName(err)});
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
        if (std.mem.startsWith(u8, text, "pw-failed:")) {
            std.debug.print("{s}\n", .{text});
            return error.PageFailed;
        }
        if (std.mem.eql(u8, text, "pw-ready")) {
            // A create, a rename and a write the page must see.
            try self.project.writeFile(zio.io(), .{ .sub_path = "notes/b.md", .data = "b" });
            try self.project.rename("notes/a.md", self.project, "notes/c.md", zio.io());
            try self.project.writeFile(zio.io(), .{ .sub_path = "notes/d.md", .data = "longer" });
            return self.view.post("pw-host:written");
        }
        if (std.mem.eql(u8, text, "pw-done")) {
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
    var tmp = zio.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(zio.io(), "project/notes");
    var project = try tmp.dir.openDir(zio.io(), "project", .{});
    defer project.close(zio.io());
    try project.writeFile(zio.io(), .{ .sub_path = "notes/a.md", .data = "a" });
    try project.writeFile(zio.io(), .{ .sub_path = "notes/d.md", .data = "d" });
    const path = try zio.realPathAlloc(project, ".", allocator);
    defer allocator.free(path);

    const app = try z.App.init(allocator);
    defer app.deinit();
    var plugin: watch_plugin.Plugin = undefined;
    try plugin.init(allocator, .{ .post = .app(app), .roots = &.{.{ .name = "project", .path = path, .recursive = true }} });
    var state: State = .{ .allocator = allocator, .app = app, .project = project };
    state.window = try app.createWindow(.{ .title = "Watch plugin smoke" });
    state.controls = .{ .window = state.window };
    state.host = .init(allocator, .{ .transport = .{ .context = &state, .send = State.send }, .controls = state.controls.controls() });
    try state.host.use(plugin.plugin());
    state.view = web.View.init(allocator, &state, State.event);

    var profile: []u8 = &.{};
    defer allocator.free(profile);
    if (builtin.os.tag == .windows) {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "WatchPluginSmoke" });
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
    std.debug.print("watch plugin WebView smoke passed: denied root, ready, create, rename pairing, write, close\n", .{});
}
