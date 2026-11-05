//! Drives a shown window of views with ziggurat-automation's commands, as
//! an agent does: it opens a session, reads the window's elements with
//! refs, acts on them and reads what changed once the window settled,
//! clicks, sends keys, fills a slider, chooses a menu item, saves a
//! screenshot, sees a ref go stale and closes the session, which leaves
//! the app running. The commands run in this process on another thread,
//! over the socket, as the command does from another process.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");
const automation = @import("ziggurat_automation");
const cli = @import("ziggurat_automation_cli");

// The macOS unwinder cannot walk the driving thread's shallow stack.
pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };

const reset_command = 10;
const quit_command = 11;

const State = struct {
    count: u32 = 0,
    greet: bool = false,
    level: f64 = 2,
    window: ?z.Window = null,
    fn build(self: *State, v: *view.View) anyerror!void {
        var label: [32]u8 = undefined;
        try v.text(try std.fmt.bufPrint(&label, "Count: {d}", .{self.count}), .{ .key = view.key("count") });
        if (try v.button("Add", .{ .key = view.key("add") })) self.count += 1;
        _ = try v.checkbox(&self.greet, "Greet", .{ .key = view.key("greet") });
        if (self.greet) try v.text("Hello, Ada", .{ .key = view.key("greeting") });
        _ = try v.slider(&self.level, .{ .minimum = 0, .maximum = 10, .step = 1 }, .{ .key = view.key("level"), .name = "Level" });
    }
    fn onMenu(context: *anyopaque, _: z.Window, action: system.Action) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (action) {
            .menu => |id| switch (id) {
                reset_command => {
                    self.count = 0;
                    if (self.window) |window| window.invalidate();
                },
                quit_command => _ = (self.window orelse return).app.requestQuit(),
                else => {},
            },
            else => {},
        }
    }
};

const Driver = struct {
    dir: []const u8,
    arena: std.mem.Allocator,

    /// Runs a command line in the session "smoke"; returns its output
    /// and exit status.
    fn run(self: *Driver, argv: []const []const u8) !struct { []const u8, u8 } {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        var all: std.ArrayList([]const u8) = .empty;
        try all.appendSlice(self.arena, argv);
        try all.appendSlice(self.arena, &.{ "--session", "smoke" });
        const code = cli.run(std.heap.page_allocator, all.items, null, &out.writer, &out.writer, .{ .dir = self.dir, .version = "smoke" });
        return .{ out.written(), code };
    }

    /// Runs a command line that succeeds, and checks that its output has
    /// the lines `want`, in order.
    fn must(self: *Driver, want: []const []const u8, argv: []const []const u8) ![]const u8 {
        const out, const code = try self.run(argv);
        if (code != 0) {
            std.debug.print("ziggurat-automation {s}: exit {d}\n{s}\n", .{ argv[0], code, out });
            return error.CommandFailed;
        }
        var rest = out;
        for (want) |line| {
            const needle = try std.fmt.allocPrint(self.arena, "{s}\n", .{line});
            const at = std.mem.indexOf(u8, rest, needle);
            if (at == null or (at.? > 0 and rest[at.? - 1] != '\n')) {
                std.debug.print("ziggurat-automation {s}:\n{s}\nlacks the line, in order: {s}\n", .{ argv[0], out, line });
                return error.MissingLine;
            }
            rest = rest[at.? + needle.len ..];
        }
        return out;
    }

    /// Acts, then reads what changed once the window settled; --timeout 0
    /// lets the machine take its time.
    fn settle(self: *Driver, want: []const []const u8, argv: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.appendSlice(self.arena, argv);
        try all.appendSlice(self.arena, &.{ "--settle", "--timeout", "0" });
        return self.must(want, all.items);
    }

    fn fails(self: *Driver, want: []const u8, argv: []const []const u8) !void {
        const out, const code = try self.run(argv);
        if (code == 0 or std.mem.indexOf(u8, out, want) == null) {
            std.debug.print("ziggurat-automation {s}: exit {d}\n{s}\nwant it to fail saying: {s}\n", .{ argv[0], code, out, want });
            return error.ExpectedFailure;
        }
    }
};

fn drive(path: []const u8, dir: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: Driver = .{ .dir = dir, .arena = arena };
    const add = try std.fmt.allocPrint(arena, "key={d}", .{view.key("add")});

    _ = try d.must(&.{try std.fmt.allocPrint(arena, "opened {s} (session smoke)", .{path})}, &.{ "open", "--socket", path });
    // Focused or not, as the window manager has it.
    if (!std.mem.startsWith(u8, try d.must(&.{}, &.{"windows"}), "w1 [content] \"Automation CLI\"")) return error.Windows;
    _ = try d.must(&.{}, &.{ "wait", "--timeout", "0" });
    _ = try d.must(&.{
        try std.fmt.allocPrint(arena, "@e1 [text] \"Count: 0\" key={d}", .{view.key("count")}),
        try std.fmt.allocPrint(arena, "@e2 [button] \"Add\" {s}", .{add}),
        try std.fmt.allocPrint(arena, "@e3 [checkBox] \"Greet\" key={d}", .{view.key("greet")}),
        try std.fmt.allocPrint(arena, "@e4 [slider] \"Level\" value=2 key={d}", .{view.key("level")}),
    }, &.{"snapshot"});
    const controls = try d.must(&.{}, &.{ "snapshot", "-i" });
    if (std.mem.indexOf(u8, controls, "Count") != null or std.mem.indexOf(u8, controls, "@e2 [button] \"Add\"") == null) {
        std.debug.print("snapshot -i:\n{s}\n", .{controls});
        return error.Interactive;
    }

    // Pressing by ref and by key, as assistive technology does, and the
    // counter's change once the window settled.
    const count = try std.fmt.allocPrint(arena, "key={d}", .{view.key("count")});
    _ = try d.settle(&.{ try std.fmt.allocPrint(arena, "- @e1 [text] \"Count: 0\" {s}", .{count}), try std.fmt.allocPrint(arena, "+ @e1 [text] \"Count: 1\" {s}", .{count}) }, &.{ "press", "@e2" });
    _ = try d.settle(&.{try std.fmt.allocPrint(arena, "+ @e1 [text] \"Count: 2\" {s}", .{count})}, &.{ "press", "key=add" });
    // A click where the tree says the button is.
    _ = try d.settle(&.{try std.fmt.allocPrint(arena, "+ @e1 [text] \"Count: 3\" {s}", .{count})}, &.{ "click", "@e2" });

    // Checking the box shows the greeting, with a ref of its own.
    const greeting = try std.fmt.allocPrint(arena, "key={d}", .{view.key("greeting")});
    _ = try d.settle(&.{try std.fmt.allocPrint(arena, "+ @e5 [text] \"Hello, Ada\" {s}", .{greeting})}, &.{ "press", "@e3" });
    // The greeting goes, and its ref with it: it never names what comes
    // back in its place.
    _ = try d.settle(&.{try std.fmt.allocPrint(arena, "- @e5 [text] \"Hello, Ada\" {s}", .{greeting})}, &.{ "press", "@e3" });
    try d.fails("stale ref @e5", &.{ "click", "@e5" });
    _ = try d.settle(&.{try std.fmt.allocPrint(arena, "+ @e6 [text] \"Hello, Ada\" {s}", .{greeting})}, &.{ "press", "key=greet" });
    _ = try d.must(&.{}, &.{ "wait", "key=greeting" });

    // A slider takes a number and steps; keys move the focus.
    const level = try std.fmt.allocPrint(arena, "key={d}", .{view.key("level")});
    _ = try d.settle(&.{try std.fmt.allocPrint(arena, "+ @e4 [slider] \"Level\" value=7 {s}", .{level})}, &.{ "fill", "@e4", "7" });
    _ = try d.settle(&.{try std.fmt.allocPrint(arena, "+ @e4 [slider] \"Level\" value=8 {s}", .{level})}, &.{ "act", "@e4", "increment" });
    _ = try d.must(&.{"ok"}, &.{ "key", "Shift+Tab" });
    _ = try d.must(&.{"ok"}, &.{ "wait", "--text", "Hello" });
    try d.fails("timeout", &.{ "wait", "--text", "Goodbye", "--timeout", "300ms" });

    // A page's script, in native UI.
    try d.fails("unsupported", &.{ "eval", "1" });

    // The window as an image, in a file.
    const shot = try std.fs.path.join(arena, &.{ dir, "shot.png" });
    _ = try d.must(&.{}, &.{ "screenshot", shot });
    const png = try std.Io.Dir.cwd().readFileAlloc(zio.io(), shot, arena, .limited(64 << 20));
    if (!std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n")) return error.NotPng;

    if (has_menus) {
        _ = try d.settle(&.{try std.fmt.allocPrint(arena, "+ @e1 [text] \"Count: 0\" {s}", .{count})}, &.{ "menu", "File", "Reset" });
    } else try d.fails("unsupported", &.{ "menu", "File", "Reset" });

    // Closing the session leaves the app running.
    _ = try d.must(&.{"closed session smoke"}, &.{"close"});
    try d.fails("no session \"smoke\"", &.{"snapshot"});
    _ = try d.must(&.{try std.fmt.allocPrint(arena, "opened {s} (session smoke)", .{path})}, &.{ "open", "--socket", path });
    _ = try d.must(&.{"closed session smoke"}, &.{"close"});
}

/// Platforms with a native menu bar drive menu items too.
const has_menus = system.capabilities.native_menu;
var quit_app: ?*z.App = null;

fn quitTask(context: *anyopaque) void {
    const app: *z.App = @ptrCast(@alignCast(context));
    _ = app.requestQuit();
}

const Driving = struct {
    path: []const u8,
    dir: []const u8,
    result: anyerror!void = {},
    fn run(self: *Driving) void {
        self.result = drive(self.path, self.dir);
        if (self.result) |_| {} else |err| {
            std.debug.print("automation cli smoke failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        }
        quit_app.?.post(.{ .context = quit_app.?, .call = quitTask }) catch std.process.exit(1);
    }
};

fn temporary(allocator: std.mem.Allocator) ![]u8 {
    const directory = zio.getEnvVarOwned(allocator, if (builtin.os.tag == .windows) "TEMP" else "TMPDIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, if (builtin.os.tag == .windows) "." else "/tmp"),
        else => |other| return other,
    };
    defer allocator.free(directory);
    var suffix: [8]u8 = undefined;
    zio.random.bytes(&suffix);
    // macOS TMPDIR ends with a separator; the CLI reports the resolved path.
    const base = std.mem.trimEnd(u8, directory, "/\\");
    return std.fmt.allocPrint(allocator, "{s}{c}zac-{x}", .{ if (base.len == 0) directory else base, std.fs.path.sep, suffix });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    if (comptime !automation.enabled) {
        std.debug.print("automation cli: this build leaves automation out; skipped\n", .{});
        return;
    }

    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var storage: view.Storage(32, 512) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    var owner = system.Owner.init(&state, State.onMenu);
    const window = try app.createWindow(.{ .title = "Automation CLI", .width = 360, .height = 260 });
    state.window = window;
    try host.attach(window);
    quit_app = app;
    const items = [_]system.Item{
        .{ .id = 1, .kind = .submenu, .label = "&File" },
        .{ .id = reset_command, .parent = 1, .label = "&Reset" },
        .{ .id = quit_command, .parent = 1, .label = "&Quit" },
    };
    if (has_menus) {
        try owner.attach(window);
        try owner.setMenu(&items);
    }
    window.show();

    const dir = try temporary(allocator);
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(zio.io(), dir);
    defer std.Io.Dir.cwd().deleteTree(zio.io(), dir) catch {};
    const path = try std.fs.path.join(allocator, &.{ dir, "app.sock" });
    defer allocator.free(path);
    const sessions = try std.fs.path.join(allocator, &.{ dir, "sessions" });
    defer allocator.free(sessions);
    const server = (try automation.start(allocator, app, .{ .path = path })).?;
    var driving: Driving = .{ .path = path, .dir = sessions };
    const thread = try std.Thread.spawn(.{}, Driving.run, .{&driving});
    try app.run();
    server.stop();
    thread.join();
    try driving.result;
    if (has_menus) owner.detach() catch {};
    std.debug.print("automation cli: open, snapshot, refs, press, click, fill, act, key, wait, settle diffs, stale refs, screenshot, menu and close passed\n", .{});
}
