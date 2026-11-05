//! ziggurat-automation: the command line client of the automation socket
//! (`ziggurat_automation`) made for agents. It prints compact snapshots of
//! a window's elements with short refs, acts on them, and prints diffs of
//! what the window shows once it settled. It speaks the protocol of
//! docs/automation.md over the socket and nothing else: the protocol and
//! the module are unchanged by it.
const std = @import("std");
const zio = @import("ziggurat_io");
const model = @import("model.zig");
const args_module = @import("args.zig");
const session_module = @import("session.zig");
const format = @import("format.zig");
const Client = @import("client.zig").Client;
const Problem = @import("problem.zig").Problem;

pub const Flag = args_module.Flag;
pub const Session = session_module.Session;
pub const Seen = session_module.Seen;
const Writer = std.Io.Writer;
const Node = model.Node;

test {
    _ = args_module;
    _ = session_module;
    _ = format;
    _ = @import("cli_tests.zig");
}

pub const Options = struct {
    /// The SKILL.md that `skills` prints.
    skill: []const u8 = "",
    /// What `version` prints.
    version: []const u8 = "",
    /// Keeps the sessions' files; null is ziggurat/automation in the
    /// user's cache directory.
    dir: ?[]const u8 = null,
    /// Reads an environment variable; null reads the process's.
    getenv: ?*const fn (std.mem.Allocator, []const u8) ?[]const u8 = null,
};

pub const usage =
    \\usage: ziggurat-automation <command> [arguments] [--session name]
    \\
    \\Run "ziggurat-automation skills" for the guide: commands, selectors, refs, --settle.
    \\
    \\  open [--socket path]       attach a session to an app (default: $ZIGGURAT_AUTOMATION)
    \\  close                      end the session (the app keeps running)
    \\  windows | window <w>       list windows | pick the one commands target
    \\  snapshot [-i] [--full] [--json]
    \\  diff                       what changed since the last snapshot or diff
    \\  press | focus <sel>        fill <sel> <text>     act <sel> <action> [args]
    \\  click <sel>|<x> <y>        pointer move|down|up <sel>|<x> <y>
    \\  wheel <sel>|<x> <y> <dx> <dy>
    \\  type <text>                key <key>...          menu <label>...
    \\  eval <script>|-            wait [<sel>] [--text s] [--gone]
    \\  screenshot <file.png>      skills                version
    \\
;

/// How long --settle and wait wait unless --timeout says, in milliseconds.
const default_timeout = 10_000;
/// How often wait reads the window again while what it waits for has not
/// come, in milliseconds.
const poll_every = 50;

const window_flag = [_]Flag{.{ .name = "window", .value = true }};
const act_flags = window_flag ++ [_]Flag{ .{ .name = "settle" }, .{ .name = "timeout", .value = true } };
const pointer_flags = act_flags ++ [_]Flag{ .{ .name = "button", .value = true }, .{ .name = "clicks", .value = true }, .{ .name = "mods", .value = true } };

const Command = struct {
    name: []const u8,
    flags: []const Flag = &.{},
    /// Runs without an open session.
    no_session: bool = false,
    run: *const fn (*Cmd) anyerror!void,
};

pub const commands = [_]Command{
    .{ .name = "open", .flags = &.{.{ .name = "socket", .value = true }}, .no_session = true, .run = Cmd.open },
    .{ .name = "close", .no_session = true, .run = Cmd.close },
    .{ .name = "windows", .flags = &.{.{ .name = "json" }}, .run = Cmd.windows },
    .{ .name = "window", .run = Cmd.window },
    .{ .name = "snapshot", .flags = &(window_flag ++ [_]Flag{ .{ .name = "interactive" }, .{ .name = "full" }, .{ .name = "json" } }), .run = Cmd.snapshot },
    .{ .name = "diff", .flags = &window_flag, .run = Cmd.diff },
    .{ .name = "press", .flags = &act_flags, .run = Cmd.press },
    .{ .name = "focus", .flags = &act_flags, .run = Cmd.focus },
    .{ .name = "fill", .flags = &act_flags, .run = Cmd.fill },
    .{ .name = "act", .flags = &act_flags, .run = Cmd.act },
    .{ .name = "click", .flags = &pointer_flags, .run = Cmd.click },
    .{ .name = "pointer", .flags = &pointer_flags, .run = Cmd.pointer },
    .{ .name = "wheel", .flags = &(act_flags ++ [_]Flag{ .{ .name = "precise" }, .{ .name = "mods", .value = true } }), .run = Cmd.wheel },
    .{ .name = "type", .flags = &act_flags, .run = Cmd.typeText },
    .{ .name = "key", .flags = &(act_flags ++ [_]Flag{ .{ .name = "down" }, .{ .name = "up" } }), .run = Cmd.key },
    .{ .name = "menu", .flags = &act_flags, .run = Cmd.menu },
    .{ .name = "eval", .flags = &(window_flag ++ [_]Flag{.{ .name = "json" }}), .run = Cmd.eval },
    .{ .name = "wait", .flags = &(act_flags ++ [_]Flag{ .{ .name = "text", .value = true }, .{ .name = "gone" } }), .run = Cmd.wait },
    .{ .name = "screenshot", .flags = &window_flag, .run = Cmd.screenshot },
    .{ .name = "skills", .no_session = true, .run = Cmd.skills },
    .{ .name = "version", .no_session = true, .run = Cmd.version },
};

/// Runs a command line, without the program's name, and returns the exit
/// status: 0, 1 when the command failed, 2 when it was used wrong.
pub fn run(gpa: std.mem.Allocator, argv: []const []const u8, stdin: ?*std.Io.Reader, stdout: *Writer, stderr: *Writer, options: Options) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var problem: Problem = .{};
    var cmd: Cmd = .{ .arena = arena_state.allocator(), .stdin = stdin, .out = stdout, .err = stderr, .options = options, .problem = &problem };
    const status: u8 = if (cmd.start(argv)) 0 else |err| switch (err) {
        error.Usage => 2,
        error.Failed => 1,
        else => blk: {
            problem.message = @errorName(err);
            break :blk 1;
        },
    };
    if (status != 0) stderr.print("error: {s}\n", .{problem.message}) catch {};
    if (cmd.client) |*client| client.close();
    stdout.flush() catch {};
    stderr.flush() catch {};
    return status;
}

/// An element a selector names.
const Target = struct {
    window: u64,
    id: []const u8,
    /// The ref's number when the selector is a ref, for errors.
    ref: u64 = 0,
};

/// An event of the input method.
const InputEvent = struct {
    type: []const u8,
    x: ?f64 = null,
    y: ?f64 = null,
    button: ?[]const u8 = null,
    clicks: ?u32 = null,
    dx: ?f64 = null,
    dy: ?f64 = null,
    precise: ?bool = null,
    mods: ?[]const []const u8 = null,
    key: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const Cmd = struct {
    arena: std.mem.Allocator,
    stdin: ?*std.Io.Reader,
    out: *Writer,
    err: *Writer,
    options: Options,
    problem: *Problem,
    a: args_module.Args = undefined,
    s: Session = .{},
    session_name: []const u8 = "default",
    dir: []const u8 = "",
    client: ?Client = null,
    /// How long --settle and wait wait, in milliseconds; 0 waits as long
    /// as it takes.
    timeout: u64 = default_timeout,

    fn start(c: *Cmd, argv: []const []const u8) !void {
        if (argv.len == 0 or eql(argv[0], "help") or eql(argv[0], "-h") or eql(argv[0], "--help")) {
            try c.out.writeAll(usage);
            if (argv.len == 0) return c.problem.usage("no command", .{});
            return;
        }
        const command = for (commands) |command| {
            if (eql(command.name, argv[0])) break command;
        } else return c.problem.usage("no command \"{s}\": run ziggurat-automation help", .{argv[0]});
        try c.startParsed(command, argv[1..]);
    }

    fn startParsed(c: *Cmd, command: Command, rest: []const []const u8) !void {
        var flags: std.ArrayList(Flag) = .empty;
        try flags.appendSlice(c.arena, command.flags);
        try flags.append(c.arena, .{ .name = "session", .value = true });
        c.a = try args_module.parse(c.arena, rest, flags.items, c.problem);
        if (c.a.value("timeout")) |text| c.timeout = try parseTimeout(text, c.problem);
        c.session_name = c.a.value("session") orelse c.env("ZIGGURAT_AUTOMATION_SESSION") orelse "default";
        if (c.session_name.len == 0) c.session_name = "default";
        c.dir = try c.sessionsDir();
        if (command.no_session) return command.run(c);
        c.s = try session_module.load(c.arena, c.dir, c.session_name, c.problem);
        c.client = try Client.connect(c.arena, c.s.socket, c.problem);
        // A request the app never answers, as from a main thread that
        // hangs, fails rather than holding the agent forever.
        if (c.timeout > 0) c.client.?.deadline = zio.milliTimestamp() + @as(i64, @intCast(c.timeout)) + 30_000;
        return command.run(c);
    }

    fn env(c: *Cmd, name: []const u8) ?[]const u8 {
        if (c.options.getenv) |get| return get(c.arena, name);
        const value = zio.getEnvVarOwned(c.arena, name) catch return null;
        return if (value.len == 0) null else value;
    }

    /// The sessions' directory: ziggurat/automation in the user's cache
    /// directory.
    fn sessionsDir(c: *Cmd) ![]const u8 {
        if (c.options.dir) |dir| return dir;
        const builtin = @import("builtin");
        const cache = switch (builtin.os.tag) {
            .windows => c.env("LOCALAPPDATA") orelse return c.problem.fail("no LOCALAPPDATA to keep sessions in", .{}),
            .macos => try std.fs.path.join(c.arena, &.{ c.env("HOME") orelse return c.problem.fail("no HOME to keep sessions in", .{}), "Library", "Caches" }),
            else => c.env("XDG_CACHE_HOME") orelse try std.fs.path.join(c.arena, &.{ c.env("HOME") orelse return c.problem.fail("no HOME to keep sessions in", .{}), ".cache" }),
        };
        return std.fs.path.join(c.arena, &.{ cache, "ziggurat", "automation" });
    }

    fn save(c: *Cmd) !void {
        try session_module.save(c.arena, &c.s, c.dir, c.session_name, c.problem);
    }

    fn want(c: *Cmd, min: usize, max: ?usize, comptime use: []const u8) !void {
        if (c.a.pos.len < min or (max != null and c.a.pos.len > max.?)) return c.problem.usage("usage: ziggurat-automation " ++ use, .{});
    }

    fn ok(c: *Cmd) !void {
        try c.out.writeAll("ok\n");
    }

    fn call(c: *Cmd, method: []const u8, params: anytype) !std.json.Value {
        return c.client.?.call(method, params);
    }

    // ------------------------------------------------------------ sessions

    fn open(c: *Cmd) !void {
        try c.want(0, 0, "open [--socket path] [--session name]");
        const given = c.a.value("socket") orelse c.env("ZIGGURAT_AUTOMATION") orelse
            return c.problem.usage("open needs --socket <path>: the path the app's ZIGGURAT_AUTOMATION names", .{});
        const socket = try std.fs.path.resolve(c.arena, &.{ try currentDir(c.arena), given });
        _ = try session_module.path(c.arena, c.dir, c.session_name, c.problem);
        var client = try Client.connect(c.arena, socket, c.problem);
        defer client.close();
        client.deadline = zio.milliTimestamp() + 60_000;
        const listed = try model.read(struct { windows: []const model.Window = &.{} }, c.arena, try client.call("windows", .{}));
        var fresh: Session = .{ .socket = socket };
        // Opening again forgets what windows showed, and its refs go stale
        // rather than come back for other elements.
        if (session_module.load(c.arena, c.dir, c.session_name, c.problem)) |old| {
            fresh.next = @max(old.next, 1);
        } else |_| {}
        c.s = fresh;
        try c.save();
        try c.out.print("opened {s} (session {s})\n", .{ socket, c.session_name });
        for (listed.windows) |info| {
            try format.window(c.out, info, false);
            try c.out.writeByte('\n');
        }
    }

    fn close(c: *Cmd) !void {
        try c.want(0, 0, "close [--session name]");
        if (try session_module.remove(c.arena, c.dir, c.session_name, c.problem)) {
            try c.out.print("closed session {s}\n", .{c.session_name});
        } else try c.out.print("no session {s}\n", .{c.session_name});
    }

    fn skills(c: *Cmd) !void {
        try c.want(0, 0, "skills");
        try c.out.writeAll(c.options.skill);
    }

    fn version(c: *Cmd) !void {
        try c.want(0, 0, "version");
        try c.out.print("{s}\n", .{c.options.version});
    }

    // ------------------------------------------------------------ windows

    fn listWindows(c: *Cmd) ![]const model.Window {
        return (try model.read(struct { windows: []const model.Window = &.{} }, c.arena, try c.call("windows", .{}))).windows;
    }

    fn windows(c: *Cmd) !void {
        try c.want(0, 0, "windows [--json]");
        const raw = try c.call("windows", .{});
        if (c.a.has("json")) return c.printJson(raw);
        const listed = try model.read(struct { windows: []const model.Window = &.{} }, c.arena, raw);
        if (listed.windows.len == 0) try c.out.writeAll("(no windows)\n");
        for (listed.windows) |info| {
            try format.window(c.out, info, info.id == c.s.window);
            try c.out.writeByte('\n');
        }
    }

    /// Picks the window that commands target unless they name one.
    fn window(c: *Cmd) !void {
        try c.want(1, 1, "window <w1|auto>");
        const id = try parseWindow(c.a.pos[0], c.problem);
        const listed = try c.listWindows();
        if (id == 0) {
            c.s.window = 0;
            try c.out.writeAll("commands target the focused window\n");
            return c.save();
        }
        for (listed) |info| if (info.id == id) {
            c.s.window = id;
            try format.window(c.out, info, true);
            try c.out.writeByte('\n');
            return c.save();
        };
        return c.problem.app("no_window", "no window {d}: run windows", .{id});
    }

    /// The window a command without a ref targets: --window, else the
    /// session's, else 0 for the focused one.
    fn targetWindow(c: *Cmd) !u64 {
        if (c.a.value("window")) |text| return parseWindow(text, c.problem);
        return c.s.window;
    }

    fn printJson(c: *Cmd, raw: std.json.Value) !void {
        try std.json.Stringify.value(raw, .{}, c.out);
        try c.out.writeByte('\n');
    }

    // ------------------------------------------------------------ reading

    const Read = struct { tree: model.Tree, raw: std.json.Value };

    /// Reads the elements of a window, saying how to read a page instead.
    fn tree(c: *Cmd, window_id: u64) !Read {
        const raw = c.call("tree", .{ .window = window_id }) catch |err| {
            if (err == error.Failed and c.problem.is("unsupported")) {
                const what = try c.arena.dupe(u8, before(c.problem.message["unsupported: ".len..], ':'));
                return c.problem.app("unsupported", "{s}, which has no elements here: read it with eval", .{what});
            }
            if (err == error.Failed and c.problem.is("no_window") and window_id != 0) {
                c.s.forget(window_id);
                var problem: Problem = .{};
                session_module.save(c.arena, &c.s, c.dir, c.session_name, &problem) catch {};
            }
            return err;
        };
        return .{ .tree = try model.read(model.Tree, c.arena, raw), .raw = raw };
    }

    fn snapshot(c: *Cmd) !void {
        try c.want(0, 0, "snapshot [-i] [--full] [--json] [--window w]");
        const read = try c.tree(try c.targetWindow());
        _ = try c.s.observe(c.arena, read.tree);
        try c.save();
        if (c.a.has("json")) return c.printJson(read.raw);
        try format.snapshot(c.arena, c.out, c.s.shown(read.tree.window).?, read.tree.announcements orelse &.{}, c.a.has("interactive"), c.a.has("full"));
    }

    fn diff(c: *Cmd) !void {
        try c.want(0, 0, "diff [--window w]");
        try c.printDiff(try c.targetWindow());
    }

    /// Prints what changed in the window since the last snapshot or diff,
    /// and takes what it shows now.
    fn printDiff(c: *Cmd, window_id: u64) !void {
        const read = c.tree(window_id) catch |err| {
            if (err == error.Failed and c.problem.is("unsupported")) {
                // A page settled; it has no elements to compare.
                try c.out.writeAll("ok (a web page: read it with eval)\n");
                return;
            }
            return err;
        };
        const was = try c.s.observe(c.arena, read.tree);
        try c.save();
        const lines = try format.diff(c.arena, was, c.s.shown(read.tree.window).?, 1);
        if (lines.len == 0) try c.out.writeAll("(no changes)\n");
        for (lines) |line| try line.write(c.out);
        try format.writeAnnouncements(c.out, read.tree.announcements orelse &.{});
    }

    /// Ends an action on a window: with --settle it waits for the window
    /// to settle and prints the diff; otherwise it prints ok.
    fn done(c: *Cmd, window_id: u64) !void {
        if (!c.a.has("settle")) return c.ok();
        c.idle(window_id) catch |err| {
            if (err != error.Failed or !c.problem.is("timeout")) return err;
            try c.err.print("warning: the window did not settle in {d}ms; the diff may miss what comes after\n", .{c.timeout});
        };
        try c.printDiff(window_id);
    }

    /// Waits for the window to settle, for --timeout.
    fn idle(c: *Cmd, window_id: u64) !void {
        if (c.timeout == 0) {
            _ = try c.call("idle", .{ .window = window_id });
        } else _ = try c.call("idle", .{ .window = window_id, .timeout = c.timeout });
    }

    // ------------------------------------------------------------ selectors

    /// Finds the element a selector names: `@e7` (a ref), `key=<key>` (the
    /// app's key) or `id=<digits>` (an element ID, as --json shows).
    fn resolve(c: *Cmd, selector: []const u8) !Target {
        if (session_module.parseRef(selector)) |n| {
            const found = try c.s.lookup(n, c.problem);
            return .{ .window = found.window, .id = found.id, .ref = n };
        }
        const window_id = try c.targetWindow();
        if (std.mem.startsWith(u8, selector, "id=")) {
            const id = selector[3..];
            _ = std.fmt.parseInt(u64, id, 10) catch return c.problem.usage("selector \"{s}\": an element ID is a string of digits", .{selector});
            return .{ .window = window_id, .id = id };
        }
        if (!std.mem.startsWith(u8, selector, "key=")) return c.problem.usage("selector \"{s}\": write a ref (@e7), key=<key> or id=<digits>", .{selector});
        const wanted = try keyValue(c.arena, selector[4..]);
        const read = try c.tree(window_id);
        var found: ?[]const u8 = null;
        var count: usize = 0;
        for (read.tree.nodes) |n| if (n.key) |value| if (eql(value, wanted)) {
            found = n.id;
            count += 1;
        };
        if (count == 0) return c.problem.app("no_element", "window {d} shows no element with the key {s}", .{ read.tree.window, selector[4..] });
        if (count > 1) return c.problem.app("invalid_request", "{d} elements of window {d} have the key {s}: use a ref", .{ count, read.tree.window, selector[4..] });
        return .{ .window = read.tree.window, .id = found.? };
    }

    /// Turns the app's answer that a ref's element or window is gone into
    /// a stale ref.
    fn gone(c: *Cmd, target: Target, err: anyerror) anyerror {
        if (target.ref == 0 or err != error.Failed) return err;
        if (c.problem.is("no_element")) return session_module.stale(c.problem, target.ref, "window {d} no longer shows its element", .{target.window});
        if (c.problem.is("no_window")) return session_module.stale(c.problem, target.ref, "its window {d} closed", .{target.window});
        return err;
    }

    // ------------------------------------------------------------ actions

    /// Performs an action of assistive technology on an element.
    fn actOn(c: *Cmd, target: Target, action: []const u8, text: ?[]const u8, from: ?u64, to: ?u64) !void {
        _ = c.call("act", .{ .window = target.window, .id = target.id, .action = action, .text = text, .from = from, .to = to }) catch |err| return c.gone(target, err);
        try c.done(target.window);
    }

    fn press(c: *Cmd) !void {
        try c.want(1, 1, "press <sel> [--settle]");
        try c.actOn(try c.resolve(c.a.pos[0]), "press", null, null, null);
    }

    fn focus(c: *Cmd) !void {
        try c.want(1, 1, "focus <sel> [--settle]");
        try c.actOn(try c.resolve(c.a.pos[0]), "focus", null, null, null);
    }

    fn fill(c: *Cmd) !void {
        try c.want(2, 2, "fill <sel> <text> [--settle]");
        try c.actOn(try c.resolve(c.a.pos[0]), "setValue", c.a.pos[1], null, null);
    }

    /// The protocol's actions, which act takes.
    const actions = [_][]const u8{ "press", "focus", "increment", "decrement", "setValue", "insertText", "selectText", "scrollIntoView", "expand", "collapse" };

    fn act(c: *Cmd) !void {
        try c.want(2, 4, "act <sel> <action> [<text> | <from> <to>] [--settle]");
        const action = c.a.pos[1];
        for (actions) |name| {
            if (eql(name, action)) break;
        } else return c.problem.usage("no action \"{s}\": press, focus, increment, decrement, setValue, insertText, selectText, scrollIntoView, expand, collapse", .{action});
        const rest = c.a.pos[2..];
        var text: ?[]const u8 = null;
        var from: ?u64 = null;
        var to: ?u64 = null;
        if (eql(action, "setValue") or eql(action, "insertText")) {
            if (rest.len != 1) return c.problem.usage("usage: ziggurat-automation act <sel> {s} <text>", .{action});
            text = rest[0];
        } else if (eql(action, "selectText")) {
            if (rest.len != 2) return c.problem.usage("usage: ziggurat-automation act <sel> selectText <from> <to>", .{});
            from = std.fmt.parseInt(u64, rest[0], 10) catch return c.problem.usage("selectText takes offsets, not \"{s}\"", .{rest[0]});
            to = std.fmt.parseInt(u64, rest[1], 10) catch return c.problem.usage("selectText takes offsets, not \"{s}\"", .{rest[1]});
        } else if (rest.len > 0) return c.problem.usage("action {s} takes no arguments", .{action});
        try c.actOn(try c.resolve(c.a.pos[0]), action, text, from, to);
    }

    const Point = struct { window: u64, x: f64, y: f64, used: usize, target: Target };

    /// Where a pointer goes: an element's center, from `pos[0]`, or x and y
    /// from `pos[0..2]`.
    fn point(c: *Cmd, pos: []const []const u8) !Point {
        if (pos.len >= 2) if (std.fmt.parseFloat(f64, pos[0])) |x| {
            const y = std.fmt.parseFloat(f64, pos[1]) catch return c.problem.usage("y \"{s}\" is no number", .{pos[1]});
            return .{ .window = try c.targetWindow(), .x = x, .y = y, .used = 2, .target = .{ .window = 0, .id = "" } };
        } else |_| {};
        if (pos.len == 0) return c.problem.usage("a pointer needs a selector or x and y", .{});
        const target = try c.resolve(pos[0]);
        const read = c.tree(target.window) catch |err| return c.gone(target, err);
        for (read.tree.nodes) |n| if (eql(n.id, target.id)) {
            const b = n.bounds;
            return .{ .window = read.tree.window, .x = b.x + b.width / 2, .y = b.y + b.height / 2, .used = 1, .target = target };
        };
        return c.gone(target, c.problem.app("no_element", "window {d} shows no element {s}", .{ read.tree.window, target.id }));
    }

    fn mods(c: *Cmd) !?[]const []const u8 {
        const text = c.a.value("mods") orelse return null;
        if (text.len == 0) return null;
        var list: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |part| try list.append(c.arena, part);
        return list.items;
    }

    /// An event of the pointer's flags.
    fn pointerEvent(c: *Cmd, kind: []const u8, x: f64, y: f64) !InputEvent {
        var event: InputEvent = .{ .type = kind, .x = x, .y = y, .button = c.a.value("button"), .mods = try c.mods() };
        if (c.a.value("clicks")) |text| {
            const n = std.fmt.parseInt(u32, text, 10) catch 0;
            if (n < 1) return c.problem.usage("--clicks \"{s}\": 1 or more", .{text});
            event.clicks = n;
        }
        return event;
    }

    /// Sends events to a window, then ends as actions do.
    fn input(c: *Cmd, window_id: u64, target: Target, events: []const InputEvent) !void {
        _ = c.call("input", .{ .window = window_id, .events = events }) catch |err| return c.gone(target, err);
        try c.done(window_id);
    }

    fn click(c: *Cmd) !void {
        const use = "click <sel> | <x> <y> [--button left|right|middle] [--clicks n] [--mods shift,ctrl,alt,super,cmdOrCtrl] [--settle]";
        try c.want(1, 2, use);
        const at = try c.point(c.a.pos);
        if (at.used != c.a.pos.len) return c.problem.usage("usage: ziggurat-automation " ++ use, .{});
        try c.input(at.window, at.target, &.{try c.pointerEvent("click", at.x, at.y)});
    }

    fn pointer(c: *Cmd) !void {
        const use = "pointer move|down|up <sel> | <x> <y> [--button b] [--clicks n] [--mods m] [--settle]";
        try c.want(2, 3, use);
        const kind: []const u8 = if (eql(c.a.pos[0], "move")) "pointerMove" else if (eql(c.a.pos[0], "down")) "pointerDown" else if (eql(c.a.pos[0], "up")) "pointerUp" else return c.problem.usage("usage: ziggurat-automation " ++ use, .{});
        const at = try c.point(c.a.pos[1..]);
        if (at.used != c.a.pos.len - 1) return c.problem.usage("usage: ziggurat-automation " ++ use, .{});
        var event = try c.pointerEvent(kind, at.x, at.y);
        if (eql(kind, "pointerMove")) {
            // A move has no button and no clicks.
            if (event.button != null or event.clicks != null) return c.problem.usage("pointer move takes no --button or --clicks", .{});
            event.button = null;
        }
        try c.input(at.window, at.target, &.{event});
    }

    fn wheel(c: *Cmd) !void {
        const use = "wheel <sel> <dx> <dy> | <x> <y> <dx> <dy> [--precise] [--mods m] [--settle]";
        try c.want(3, 4, use);
        const place = c.a.pos[0 .. c.a.pos.len - 2];
        const at = try c.point(place);
        if (at.used != place.len) return c.problem.usage("usage: ziggurat-automation " ++ use, .{});
        var delta: [2]f64 = undefined;
        for (c.a.pos[place.len..], &delta) |text, *d| d.* = std.fmt.parseFloat(f64, text) catch return c.problem.usage("wheel distance \"{s}\" is no number", .{text});
        try c.input(at.window, at.target, &.{.{ .type = "wheel", .x = at.x, .y = at.y, .dx = delta[0], .dy = delta[1], .precise = if (c.a.has("precise")) true else null, .mods = try c.mods() }});
    }

    fn typeText(c: *Cmd) !void {
        try c.want(1, 1, "type <text> [--settle]");
        const window_id = try c.targetWindow();
        if (c.a.pos[0].len == 0) return c.problem.usage("type needs text", .{});
        try c.input(window_id, .{ .window = 0, .id = "" }, &.{.{ .type = "text", .text = c.a.pos[0] }});
    }

    fn key(c: *Cmd) !void {
        try c.want(1, null, "key <key>... [--down|--up] [--settle], as key Enter or key CmdOrCtrl+A Backspace");
        if (c.a.has("down") and c.a.has("up")) return c.problem.usage("key takes --down or --up, not both", .{});
        const kind: []const u8 = if (c.a.has("down")) "keyDown" else if (c.a.has("up")) "keyUp" else "key";
        const window_id = try c.targetWindow();
        const events = try c.arena.alloc(InputEvent, c.a.pos.len);
        for (c.a.pos, events) |name, *event| event.* = .{ .type = kind, .key = name };
        try c.input(window_id, .{ .window = 0, .id = "" }, events);
    }

    fn menu(c: *Cmd) !void {
        try c.want(1, null, "menu <label>... [--settle], as menu File \"New Window\"");
        const window_id = try c.targetWindow();
        _ = try c.call("menu", .{ .window = window_id, .path = c.a.pos });
        try c.done(window_id);
    }

    fn eval(c: *Cmd) !void {
        try c.want(1, 1, "eval <script> | - [--json] [--window w]");
        var script = c.a.pos[0];
        if (eql(script, "-")) {
            const stdin = c.stdin orelse return c.problem.fail("no standard input to read the script from", .{});
            script = try stdin.allocRemaining(c.arena, .limited(16 << 20));
        }
        const window_id = try c.targetWindow();
        const raw = c.call("eval", .{ .window = window_id, .script = script }) catch |err| {
            if (err == error.Failed and c.problem.is("unsupported")) {
                const what = try c.arena.dupe(u8, before(c.problem.message["unsupported: ".len..], ':'));
                return c.problem.app("unsupported", "{s}: read it with snapshot (scripts reach only windows showing a web page, not web views inside native UI)", .{what});
            }
            return err;
        };
        const value: std.json.Value = if (raw == .object) raw.object.get("value") orelse .null else .null;
        if (!c.a.has("json") and value == .string) {
            try c.out.print("{s}\n", .{value.string});
            return;
        }
        try c.printJson(value);
    }

    fn wait(c: *Cmd) !void {
        try c.want(0, 1, "wait [<sel>] [--text s] [--gone] [--timeout d] [--settle]");
        const text = c.a.value("text");
        var window_id = try c.targetWindow();
        if (text == null and c.a.pos.len == 0) {
            if (c.a.has("gone")) return c.problem.usage("wait --gone needs a selector or --text", .{});
            try c.idle(window_id);
            return c.done(window_id);
        }
        if (text != null and c.a.pos.len > 0) return c.problem.usage("wait takes a selector or --text, not both", .{});
        const Match = union(enum) { text: []const u8, id: []const u8, key: []const u8 };
        var match: Match = undefined;
        var what: []const u8 = undefined;
        if (text) |value| {
            match = .{ .text = value };
            what = try std.fmt.allocPrint(c.arena, "text \"{s}\"", .{value});
        } else {
            const selector = c.a.pos[0];
            what = selector;
            if (session_module.parseRef(selector)) |n| {
                const found = try c.s.lookup(n, c.problem);
                window_id = found.window;
                match = .{ .id = found.id };
            } else if (std.mem.startsWith(u8, selector, "id=")) {
                match = .{ .id = selector[3..] };
            } else if (std.mem.startsWith(u8, selector, "key=")) {
                match = .{ .key = try keyValue(c.arena, selector[4..]) };
            } else return c.problem.usage("selector \"{s}\": write a ref (@e7), key=<key> or id=<digits>", .{selector});
        }
        const want_shown = !c.a.has("gone");
        const start_ms = zio.milliTimestamp();
        while (true) {
            // Read the condition even while the window keeps drawing, as
            // with a spinner; only --settle waits for idle, once it is met.
            const read = try c.tree(window_id);
            var found = false;
            for (read.tree.nodes) |n| {
                found = switch (match) {
                    .text => |value| std.mem.indexOf(u8, Node.text(n.label), value) != null or std.mem.indexOf(u8, Node.text(n.value), value) != null,
                    .id => |id| eql(n.id, id),
                    .key => |value| if (n.key) |k| eql(k, value) else false,
                };
                if (found) break;
            }
            if (found == want_shown) return c.done(window_id);
            if (c.timeout > 0 and zio.milliTimestamp() - start_ms > c.timeout) {
                return c.problem.app("timeout", "window {d} {s} {s} after {d}ms", .{ read.tree.window, if (want_shown) "does not show" else "still shows", what, c.timeout });
            }
            zio.sleep(poll_every * std.time.ns_per_ms);
        }
    }

    fn screenshot(c: *Cmd) !void {
        try c.want(1, 1, "screenshot <file.png> [--window w]");
        const window_id = try c.targetWindow();
        const shot = try model.read(struct { png: []const u8, width: u64 = 0, height: u64 = 0 }, c.arena, try c.call("capture", .{ .window = window_id }));
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(shot.png) catch return c.problem.fail("capture: the image is not base64", .{});
        const bytes = try c.arena.alloc(u8, size);
        decoder.decode(bytes, shot.png) catch return c.problem.fail("capture: the image is not base64", .{});
        const file = c.a.pos[0];
        std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = file, .data = bytes }) catch |err| return c.problem.fail("{s}: {s}", .{ file, @errorName(err) });
        try c.out.print("{s} {d}x{d}\n", .{ file, shot.width, shot.height });
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn before(text: []const u8, delimiter: u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, delimiter) orelse text.len];
}

fn currentDir(arena: std.mem.Allocator) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(zio.io(), ".", arena);
}

/// Reads a window, as `w2` or `2`; `auto`, `focused` or 0 is the focused one.
pub fn parseWindow(text: []const u8, problem: *Problem) !u64 {
    if (eql(text, "auto") or eql(text, "focused")) return 0;
    const digits = if (std.mem.startsWith(u8, text, "w")) text[1..] else text;
    return std.fmt.parseInt(u64, digits, 10) catch problem.usage("window \"{s}\": write w1, 1 or auto", .{text});
}

/// Reads a duration in milliseconds, as 5s, 500ms or 1m; a bare number is
/// milliseconds, as the protocol's; 0 waits as long as it takes.
pub fn parseTimeout(text: []const u8, problem: *Problem) !u64 {
    if (std.fmt.parseInt(u64, text, 10)) |ms| return ms else |_| {}
    const units = [_]struct { []const u8, f64 }{ .{ "ms", 1 }, .{ "s", 1000 }, .{ "m", 60_000 }, .{ "h", 3_600_000 } };
    for (units) |unit| if (std.mem.endsWith(u8, text, unit[0])) {
        const amount = std.fmt.parseFloat(f64, text[0 .. text.len - unit[0].len]) catch continue;
        if (!(amount >= 0) or !std.math.isFinite(amount)) break;
        return @intFromFloat(@round(amount * unit[1]));
    };
    return problem.usage("--timeout {s}: write a duration, as 5s or 500ms (0 waits forever)", .{text});
}

/// The key, as the tree writes it (a string of digits), that a key
/// selector names: digits as they are, a JSON string ("7", for keys made
/// of digits) or any other text as `view.key` makes it.
pub fn keyValue(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len > 0) {
        for (text) |ch| {
            if (!std.ascii.isDigit(ch)) break;
        } else if (std.fmt.parseInt(u64, text, 10)) |_| return text else |_| {}
    }
    var name = text;
    if (text.len >= 2 and text[0] == '"') {
        if (std.json.parseFromSliceLeaky([]const u8, arena, text, .{})) |parsed| name = parsed else |_| {}
    }
    return std.fmt.allocPrint(arena, "{d}", .{model.keyOf(name)});
}
