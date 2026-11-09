//! The command against a fake app: a socket that answers as an app does,
//! with a window of native UI (1) and one showing a page (2).
const std = @import("std");
const zio = @import("ziggurat_io");
const cli = @import("cli.zig");
const model = @import("model.zig");

const testing = std.testing;
const Node = model.Node;

const add_id = "11077037771207380721";

const FakeApp = struct {
    gpa: std.mem.Allocator,
    arena_state: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    focus: ?[]const u8 = null,
    /// The params of act, input and menu requests, as JSON.
    acted: std.ArrayList([]const u8) = .empty,
    server: std.Io.net.Server = undefined,
    path: []const u8 = "",
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Each connection has its own thread, so one the server never sees
    /// end cannot keep later commands waiting, and deinit shuts them all
    /// down rather than waiting on a read that never ends.
    lock: zio.Mutex = .{},
    connections: std.ArrayList(Connection) = .empty,
    /// Idle requests answered; a window that keeps drawing never settles.
    idles: u32 = 0,
    drawing: bool = false,
    /// Tree reads before `later` shows, as work changes what the app shows.
    reads_before_later: u32 = 0,
    later: ?Node = null,

    fn arena(self: *FakeApp) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn answer(self: *FakeApp, method: []const u8, params: std.json.Value) ![]const u8 {
        const a = self.arena();
        const window: i64 = if (params == .object) if (params.object.get("window")) |w| w.integer else 0 else 0;
        if (window > 2) return error_line("no_window", "no such window");
        const page = window == 2;
        if (eql(method, "windows")) return
        \\{"windows":[{"id":1,"title":"Contacts","kind":"content","focused":true,"visible":true},{"id":2,"title":"Docs","kind":"page","url":"http://localhost/","visible":true}]}
        ;
        if (eql(method, "tree")) {
            if (page) return error_line("unsupported", "window 2 shows a web page: use eval");
            if (self.later) |node| {
                if (self.reads_before_later == 0) {
                    try self.nodes.append(a, node);
                    self.later = null;
                } else self.reads_before_later -= 1;
            }
            return std.json.Stringify.valueAlloc(a, .{ .window = 1, .focus = self.focus, .nodes = self.nodes.items }, .{ .emit_null_optional_fields = false });
        }
        if (eql(method, "idle")) {
            self.idles += 1;
            if (self.drawing) return error_line("timeout", "window 1 did not settle");
            return "{}";
        }
        if (eql(method, "act")) {
            try self.acted.append(a, try std.json.Stringify.valueAlloc(a, params, .{}));
            const id = params.object.get("id").?.string;
            const action = params.object.get("action").?.string;
            for (self.nodes.items) |*n| if (eql(n.id, id)) {
                if (eql(id, add_id) and eql(action, "press") and self.focus == null) {
                    // Add shows a text field.
                    try self.nodes.append(a, .{ .id = "42", .role = "textField", .label = "First name", .actions = &.{ "focus", "setValue" } });
                }
                if (eql(action, "setValue")) {
                    n.value = try a.dupe(u8, params.object.get("text").?.string);
                    self.focus = n.id;
                }
                return "{}";
            };
            return std.fmt.allocPrint(a, "!no_element:window 1 shows no element {s}", .{id});
        }
        if (eql(method, "input") or eql(method, "menu")) {
            if (page and eql(method, "input")) return error_line("unsupported", "window 2 shows a web page: use eval");
            try self.acted.append(a, try std.json.Stringify.valueAlloc(a, params, .{}));
            return "{}";
        }
        if (eql(method, "eval")) {
            if (!page) return error_line("unsupported", "window 1 shows native UI, not a web page: use tree");
            if (eql(params.object.get("script").?.string, "document.title")) return "{\"value\":\"Docs\"}";
            return "{\"value\":{\"n\":1}}";
        }
        if (eql(method, "capture")) return "{\"png\":\"iVBORw0KZmFrZQ==\",\"width\":2,\"height\":1}";
        return std.fmt.allocPrint(a, "!unknown_method:{s}", .{method});
    }

    fn error_line(comptime code: []const u8, comptime message: []const u8) []const u8 {
        return "!" ++ code ++ ":" ++ message;
    }

    const Connection = struct { stream: std.Io.net.Stream, thread: std.Thread };

    fn serve(self: *FakeApp) void {
        const io = zio.io();
        while (!self.stop.load(.acquire)) {
            const stream = self.server.accept(io) catch continue;
            if (self.stop.load(.acquire)) {
                stream.close(io);
                return;
            }
            self.lock.lock();
            defer self.lock.unlock();
            self.connections.ensureUnusedCapacity(self.gpa, 1) catch {
                stream.close(io);
                continue;
            };
            const thread = std.Thread.spawn(.{}, converse, .{ self, stream }) catch {
                stream.close(io);
                continue;
            };
            self.connections.appendAssumeCapacity(.{ .stream = stream, .thread = thread });
        }
    }

    fn converse(self: *FakeApp, stream: std.Io.net.Stream) void {
        var own = stream;
        var read_buffer: [1 << 16]u8 = undefined;
        var reader = own.reader(zio.io(), &read_buffer);
        while (true) {
            const whole = reader.interface.takeDelimiterInclusive('\n') catch return;
            self.lock.lock();
            defer self.lock.unlock();
            self.handle(&own, whole[0 .. whole.len - 1]) catch return;
        }
    }

    fn handle(self: *FakeApp, stream: *std.Io.net.Stream, line: []const u8) !void {
        const a = self.arena();
        const request = try std.json.parseFromSliceLeaky(std.json.Value, a, try a.dupe(u8, line), .{});
        const id = request.object.get("id").?;
        const params = request.object.get("params") orelse std.json.Value{ .object = .empty };
        const result = try self.answer(request.object.get("method").?.string, params);
        var out: std.Io.Writer.Allocating = .init(a);
        if (result.len > 0 and result[0] == '!') {
            const colon = std.mem.indexOfScalar(u8, result, ':').?;
            try out.writer.print("{{\"id\":{f},\"error\":{{\"code\":\"{s}\",\"message\":{f}}}}}\n", .{ std.json.fmt(id, .{}), result[1..colon], std.json.fmt(result[colon + 1 ..], .{}) });
        } else try out.writer.print("{{\"id\":{f},\"result\":{s}}}\n", .{ std.json.fmt(id, .{}), result });
        try zio.net.sendAll(stream.socket.handle, out.written());
    }

    fn start(self: *FakeApp, dir: []const u8) !void {
        self.path = try std.fs.path.join(self.arena(), &.{ dir, "app.sock" });
        const address = try std.Io.net.UnixAddress.init(self.path);
        self.server = try address.listen(zio.io(), .{});
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn deinit(self: *FakeApp) void {
        self.stop.store(true, .release);
        // Wake the accept.
        if (std.Io.net.UnixAddress.init(self.path)) |address| {
            if (address.connect(zio.io())) |stream| stream.close(zio.io()) else |_| {}
        } else |_| {}
        if (self.thread) |thread| thread.join();
        // Ends every read still waiting, whether or not its command closed.
        for (self.connections.items) |connection| connection.stream.shutdown(zio.io(), .both) catch {};
        for (self.connections.items) |connection| {
            connection.thread.join();
            connection.stream.close(zio.io());
        }
        self.connections.deinit(self.gpa);
        self.server.deinit(zio.io());
        self.arena_state.deinit();
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Runs the command's command lines in one directory of sessions.
const Cli = struct {
    dir: []const u8,
    stdin: []const u8 = "1 + 1",

    fn run(self: Cli, out: *std.Io.Writer.Allocating, argv: []const []const u8) u8 {
        var reader: std.Io.Reader = .fixed(self.stdin);
        return cli.run(testing.allocator, argv, &reader, &out.writer, &out.writer, .{ .dir = self.dir, .skill = "---\nname: ziggurat-automation\n---\nguide\n", .version = "0.1.0-test", .getenv = noEnv });
    }
    fn noEnv(_: std.mem.Allocator, _: []const u8) ?[]const u8 {
        return null;
    }

    /// Runs a command line that succeeds and checks its output.
    fn must(self: Cli, want: []const u8, argv: []const []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const code = self.run(&out, argv);
        if (code != 0 or !eql(out.written(), want)) {
            std.debug.print("ziggurat-automation {s}: exit {d}\n{s}\nwant:\n{s}\n", .{ argv[0], code, out.written(), want });
            return error.TestUnexpectedResult;
        }
    }

    /// Runs a command line that fails, with an output that has `want`.
    fn fails(self: Cli, code: u8, want: []const u8, argv: []const []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const got = self.run(&out, argv);
        if (got != code or std.mem.indexOf(u8, out.written(), want) == null) {
            std.debug.print("ziggurat-automation {s}: exit {d} (want {d})\n{s}\nwant it to say: {s}\n", .{ argv[0], got, code, out.written(), want });
            return error.TestUnexpectedResult;
        }
    }
};

test "commands read the window with refs, act on them and print what changed" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var app: FakeApp = .{ .gpa = testing.allocator, .arena_state = .init(testing.allocator) };
    const a = app.arena();
    const dir = try temp.dir.realPathFileAlloc(zio.io(), ".", a);
    try app.nodes.appendSlice(a, &.{
        .{ .id = "1", .role = "text", .label = "Contacts" },
        .{ .id = add_id, .role = "button", .key = "17487022006909920864", .label = "Add", .states = &.{"focusable"}, .actions = &.{ "press", "focus" } },
        .{ .id = "3", .role = "list", .label = "People" },
        .{ .id = "4", .parent = "3", .role = "listItem", .label = "Ada", .key = "7", .actions = &.{"press"}, .bounds = .{ .x = 10, .y = 20, .width = 100, .height = 30 } },
    });
    try app.start(dir);
    defer app.deinit();
    const path = app.path;
    const c: Cli = .{ .dir = try std.fs.path.join(a, &.{ dir, "sessions" }) };

    try c.fails(1, "no session \"default\": run ziggurat-automation open", &.{"snapshot"});
    try c.fails(2, "open needs --socket", &.{"open"});
    const opened = try std.fmt.allocPrint(a, "opened {s} (session default)\nw1 [content] \"Contacts\" focused\nw2 [page] \"Docs\" url=http://localhost/\n", .{path});
    try c.must(opened, &.{ "open", "--socket", path });
    try c.must("@e2 [button] \"Add\" key=17487022006909920864\n@e4 [listItem] \"Ada\" key=7\n", &.{ "snapshot", "-i" });
    try c.must("@e1 [text] \"Contacts\"\n@e2 [button] \"Add\" key=17487022006909920864\n@e3 [list] \"People\"\n  @e4 [listItem] \"Ada\" key=7\n", &.{"snapshot"});

    // Acting, then what changed once the window settled, with the elements
    // around the change and the new element's ref.
    try c.must("= @e4 [listItem] \"Ada\" key=7\n+ @e5 [textField] \"First name\"\n", &.{ "press", "@e2", "--settle" });
    try c.must("= @e4 [listItem] \"Ada\" key=7\n- @e5 [textField] \"First name\"\n+ @e5 [textField] \"First name\" value=\"Ada\" focused\n", &.{ "fill", "@e5", "Ada", "--settle" });
    try c.must("(no changes)\n", &.{"diff"});
    try c.must("ok\n", &.{ "press", "key=17487022006909920864" });
    try testing.expect(std.mem.indexOf(u8, app.acted.getLast(), "\"window\":1,\"id\":\"" ++ add_id ++ "\"") != null);
    try c.must("ok\n", &.{ "press", "key=7" });
    try c.must("ok\n", &.{ "act", "@e5", "selectText", "0", "2" });
    try testing.expectEqualStrings("{\"window\":1,\"id\":\"42\",\"action\":\"selectText\",\"from\":0,\"to\":2}", app.acted.getLast());

    // Pointers go to an element's center, or to a point.
    const before = app.acted.items.len;
    try c.must("ok\n", &.{ "click", "@e4", "--button", "right", "--mods", "shift" });
    try c.must("ok\n", &.{ "wheel", "@e4", "0", "-120", "--precise" });
    try c.must("ok\n", &.{ "pointer", "down", "5", "6.5" });
    try c.must("ok\n", &.{ "key", "CmdOrCtrl+A", "Backspace" });
    try c.must("ok\n", &.{ "type", "Grace" });
    try c.must("ok\n", &.{ "menu", "File", "New Window" });
    const sent = try std.mem.join(a, "\n", app.acted.items[before..]);
    try testing.expectEqualStrings(
        \\{"window":1,"events":[{"type":"click","x":60,"y":35,"button":"right","mods":["shift"]}]}
        \\{"window":1,"events":[{"type":"wheel","x":60,"y":35,"dx":0,"dy":-120,"precise":true}]}
        \\{"window":0,"events":[{"type":"pointerDown","x":5,"y":6.5}]}
        \\{"window":0,"events":[{"type":"key","key":"CmdOrCtrl+A"},{"type":"key","key":"Backspace"}]}
        \\{"window":0,"events":[{"type":"text","text":"Grace"}]}
        \\{"window":0,"path":["File","New Window"]}
    , sent);

    // A ref whose element is gone is refused, never given to another.
    _ = app.nodes.orderedRemove(3);
    try c.fails(1, "stale ref @e4: window 1 no longer shows its element", &.{ "press", "@e4" });
    try c.fails(1, "stale ref @e4: window 1 no longer shows its element", &.{ "click", "@e4" });
    try c.must("= @e3 [list] \"People\"\n- @e4 [listItem] \"Ada\" key=7\n= @e5 [textField] \"First name\" value=\"Ada\" focused\n", &.{"diff"});
    try c.fails(1, "stale ref @e4: its element is gone", &.{ "press", "@e4" });
    try c.fails(1, "stale ref @e9: no snapshot or diff", &.{ "press", "@e9" });
    try c.fails(1, "no_element: window 1 shows no element with the key 7", &.{ "press", "key=7" });
    try c.fails(2, "selector \"Add\"", &.{ "press", "Add" });

    // Pages are read with eval; native UI is not.
    try c.must("w2 [page] \"Docs\" url=http://localhost/ selected\n", &.{ "window", "w2" });
    try c.must("w1 [content] \"Contacts\" focused\nw2 [page] \"Docs\" url=http://localhost/ selected\n", &.{"windows"});
    try c.fails(1, "window 2 shows a web page, which has no elements here: read it with eval", &.{"snapshot"});
    try c.must("Docs\n", &.{ "eval", "document.title" });
    try c.must("{\"n\":1}\n", &.{ "eval", "-" });
    try c.must("\"Docs\"\n", &.{ "eval", "document.title", "--json" });
    try c.must("ok (a web page: read it with eval)\n", &.{ "wait", "--settle" });
    try c.fails(1, "window 1 shows native UI, not a web page: read it with snapshot", &.{ "eval", "1", "--window", "w1" });
    try c.must("commands target the focused window\n", &.{ "window", "auto" });

    const shot = try std.fs.path.join(a, &.{ dir, "shot.png" });
    try c.must(try std.fmt.allocPrint(a, "{s} 2x1\n", .{shot}), &.{ "screenshot", shot });
    try testing.expectEqualStrings("\x89PNG\r\nfake", try std.Io.Dir.cwd().readFileAlloc(zio.io(), shot, a, .limited(64)));

    // Sessions keep refs of their own.
    const opened_b = try std.fmt.allocPrint(a, "opened {s} (session b)\nw1 [content] \"Contacts\" focused\nw2 [page] \"Docs\" url=http://localhost/\n", .{path});
    try c.must(opened_b, &.{ "open", "--socket", path, "--session", "b" });
    try c.must("@e1 [text] \"Contacts\"\n@e2 [button] \"Add\" key=17487022006909920864\n@e3 [list] \"People\"\n@e4 [textField] \"First name\" value=\"Ada\" focused\n", &.{ "snapshot", "--session", "b" });
    try c.fails(1, "stale ref @e4", &.{ "press", "@e4" });

    // Opening a session again makes its refs stale, never names others
    // with them.
    try c.must(opened_b, &.{ "open", "--socket", path, "--session", "b" });
    try c.fails(1, "stale ref @e1: its element is gone", &.{ "press", "@e1", "--session", "b" });
    try c.must("@e6 [button] \"Add\" key=17487022006909920864\n@e8 [textField] \"First name\" value=\"Ada\" focused\n", &.{ "snapshot", "-i", "--session", "b" });

    try c.must("---\nname: ziggurat-automation\n---\nguide\n", &.{"skills"});
    try c.must("0.1.0-test\n", &.{"version"});
    try c.must("closed session default\n", &.{"close"});
    try c.must("no session default\n", &.{"close"});
    try c.fails(1, "no session \"default\"", &.{"snapshot"});
    try c.fails(2, "no command \"nope\"", &.{"nope"});
    try c.fails(2, "session name", &.{ "close", "--session", "../x" });
}

test "wait waits for text, and for it to go" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var app: FakeApp = .{ .gpa = testing.allocator, .arena_state = .init(testing.allocator) };
    const a = app.arena();
    const dir = try temp.dir.realPathFileAlloc(zio.io(), ".", a);
    try app.nodes.append(a, .{ .id = "1", .role = "text", .label = "Saving…" });
    try app.start(dir);
    defer app.deinit();
    const c: Cli = .{ .dir = try std.fs.path.join(a, &.{ dir, "sessions" }) };
    _ = try std.fmt.allocPrint(a, "", .{});
    try c.must(try std.fmt.allocPrint(a, "opened {s} (session default)\nw1 [content] \"Contacts\" focused\nw2 [page] \"Docs\" url=http://localhost/\n", .{app.path}), &.{ "open", "--socket", app.path });
    try c.must("ok\n", &.{ "wait", "--text", "Saving" });
    try c.fails(1, "timeout: window 1 does not show text \"Saved\" after 1ms", &.{ "wait", "--text", "Saved", "--timeout", "1ms" });
    try c.fails(1, "timeout: window 1 still shows text \"Saving\" after 1ms", &.{ "wait", "--text", "Saving", "--gone", "--timeout", "1" });
    try c.fails(2, "wait --gone needs", &.{ "wait", "--gone" });
}

test "wait checks its condition while the window keeps drawing" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var app: FakeApp = .{ .gpa = testing.allocator, .arena_state = .init(testing.allocator), .drawing = true };
    const a = app.arena();
    const dir = try temp.dir.realPathFileAlloc(zio.io(), ".", a);
    try app.nodes.append(a, .{ .id = "1", .role = "text", .label = "Saving" });
    try app.start(dir);
    defer app.deinit();
    const c: Cli = .{ .dir = try std.fs.path.join(a, &.{ dir, "sessions" }) };
    try c.must(try std.fmt.allocPrint(a, "opened {s} (session default)\nw1 [content] \"Contacts\" focused\nw2 [page] \"Docs\" url=http://localhost/\n", .{app.path}), &.{ "open", "--socket", app.path });
    const before = app.idles;
    // Without a timeout too, the condition shows while it never settles.
    try c.must("ok\n", &.{ "wait", "--text", "Saving", "--timeout", "0" });
    app.later = .{ .id = "2", .role = "textField", .value = "Ready", .key = "77" };
    app.reads_before_later = 2;
    try c.must("ok\n", &.{ "wait", "--text", "Ready", "--timeout", "0" });
    try c.must("ok\n", &.{ "wait", "key=77", "--timeout", "0" });
    try c.fails(1, "timeout: window 1 does not show text \"Done\" after 1ms", &.{ "wait", "--text", "Done", "--timeout", "1ms" });
    try testing.expectEqual(before, app.idles);
}

test "keys are written as the tree writes them, or as view.key makes them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("7", try cli.keyValue(a, "7"));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{model.keyOf("add")}), try cli.keyValue(a, "add"));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{model.keyOf("7")}), try cli.keyValue(a, "\"7\""));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{model.keyOf("a b")}), try cli.keyValue(a, "a b"));
}

test "durations read as milliseconds, seconds and minutes" {
    var problem: @import("problem.zig").Problem = .{};
    try testing.expectEqual(@as(u64, 500), try cli.parseTimeout("500", &problem));
    try testing.expectEqual(@as(u64, 500), try cli.parseTimeout("500ms", &problem));
    try testing.expectEqual(@as(u64, 1500), try cli.parseTimeout("1.5s", &problem));
    try testing.expectEqual(@as(u64, 120_000), try cli.parseTimeout("2m", &problem));
    try testing.expectEqual(@as(u64, 0), try cli.parseTimeout("0", &problem));
    try testing.expectError(error.Usage, cli.parseTimeout("soon", &problem));
    try testing.expectError(error.Usage, cli.parseTimeout("-1s", &problem));
}
