//! Drives a shown window of views through the automation socket, as a test
//! runner in another process would: windows, idle, tree, act by key and by
//! ID, pointer and key input, capture, errors, and menu items, the last of
//! which quits the app and closes the connection.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");
const automation = @import("ziggurat_automation");

const Value = std.json.Value;

// The macOS unwinder cannot walk the driving thread's shallow stack.
pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };

const reset_command = 10;
const quit_command = 11;
const disabled_command = 12;

const State = struct {
    count: u32 = 0,
    level: f64 = 2,
    agree: bool = false,
    list: view.ScrollModel = .{},
    window: ?z.Window = null,
    fn build(self: *State, v: *view.View) anyerror!void {
        var label: [32]u8 = undefined;
        try v.text(try std.fmt.bufPrint(&label, "Count: {d}", .{self.count}), .{ .key = view.key("count") });
        if (try v.button("Add", .{ .key = view.key("add") })) self.count += 1;
        _ = try v.slider(&self.level, .{ .minimum = 0, .maximum = 10, .step = 1 }, .{ .key = view.key("level"), .name = "Level" });
        _ = try v.checkbox(&self.agree, "Agree", .{ .key = view.key("agree") });
        try v.scroll(&self.list, .{ .height = 40, .self_align = .stretch });
        for (0..12) |row| {
            var name: [16]u8 = undefined;
            const last = row == 11;
            if (try v.button(try std.fmt.bufPrint(&name, "Row {d}", .{row}), .{ .key = if (last) view.key("far") else null })) {
                if (last) self.count += 1;
            }
        }
        try v.end();
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

/// One connection to the app, as a client sees it.
const Client = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    arena: std.mem.Allocator,
    next: u32 = 1,
    read_buffer: [1 << 20]u8 = undefined,
    write_buffer: [4096]u8 = undefined,

    fn connect(self: *Client, path: []const u8, arena: std.mem.Allocator) !void {
        const address = try std.Io.net.UnixAddress.init(path);
        self.arena = arena;
        self.stream = try address.connect(zio.io());
        self.reader = self.stream.reader(zio.io(), &self.read_buffer);
        self.writer = self.stream.writer(zio.io(), &self.write_buffer);
    }

    /// Sends a request and returns its answer, or null when the app closed
    /// the connection instead of answering.
    fn send(self: *Client, method: []const u8, params: []const u8) !?std.json.ObjectMap {
        const id = self.next;
        self.next += 1;
        const w = &self.writer.interface;
        try w.print("{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n", .{ id, method, params });
        try w.flush();
        const whole = self.reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        const line = whole[0 .. whole.len - 1];
        const answer = std.json.parseFromSliceLeaky(Value, self.arena, try self.arena.dupe(u8, line), .{}) catch |err| {
            std.debug.print("{s}: the answer is not JSON: {s}\n", .{ method, line[0..@min(line.len, 300)] });
            return err;
        };
        try std.testing.expectEqual(@as(i64, id), answer.object.get("id").?.integer);
        return answer.object;
    }
    fn result(self: *Client, method: []const u8, params: []const u8) !std.json.ObjectMap {
        const answer = try self.send(method, params) orelse return error.ConnectionClosed;
        if (answer.get("error")) |err| {
            std.debug.print("{s} {s}: {s}: {s}\n", .{ method, params, err.object.get("code").?.string, err.object.get("message").?.string });
            return error.UnexpectedError;
        }
        return answer.get("result").?.object;
    }
    fn expectError(self: *Client, method: []const u8, params: []const u8, code: []const u8) !void {
        const answer = try self.send(method, params) orelse return error.ConnectionClosed;
        const err = answer.get("error") orelse {
            std.debug.print("{s} {s}: expected {s}, got a result\n", .{ method, params, code });
            return error.ExpectedError;
        };
        try std.testing.expectEqualStrings(code, err.object.get("code").?.string);
    }
    fn idle(self: *Client) !void {
        _ = try self.result("idle", "{\"timeout\":5000}");
    }
    fn tree(self: *Client) !std.json.ObjectMap {
        return self.result("tree", "{}");
    }
};

fn nodeOf(tree: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    var digits: [24]u8 = undefined;
    const want = try std.fmt.bufPrint(&digits, "{d}", .{view.key(key)});
    for (tree.get("nodes").?.array.items) |node| {
        if (node.object.get("key")) |value| if (std.mem.eql(u8, value.string, want)) return node.object;
    }
    std.debug.print("no element has the key {s}\n", .{key});
    return error.MissingElement;
}

fn hasState(node: std.json.ObjectMap, name: []const u8) bool {
    const states = node.get("states") orelse return false;
    for (states.array.items) |state| if (std.mem.eql(u8, state.string, name)) return true;
    return false;
}

fn hasAction(node: std.json.ObjectMap, name: []const u8) bool {
    const actions = node.get("actions") orelse return false;
    for (actions.array.items) |action| if (std.mem.eql(u8, action.string, name)) return true;
    return false;
}

fn expectCount(client: *Client, count: u32) !void {
    try client.idle();
    var expected: [32]u8 = undefined;
    const node = try nodeOf(try client.tree(), "count");
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Count: {d}", .{count}), node.get("label").?.string);
}

fn center(node: std.json.ObjectMap) [2]f64 {
    const bounds = node.get("bounds").?.object;
    const x = number(bounds.get("x").?) + number(bounds.get("width").?) / 2;
    const y = number(bounds.get("y").?) + number(bounds.get("height").?) / 2;
    return .{ x, y };
}

fn number(value: Value) f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => std.math.nan(f64),
    };
}

fn drive(path: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const client = try arena.create(Client);
    try client.connect(path, arena);
    defer client.stream.close(zio.io());

    const windows = (try client.result("windows", "{}")).get("windows").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings("Automation", windows[0].object.get("title").?.string);
    try std.testing.expectEqualStrings("content", windows[0].object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), windows[0].object.get("id").?.integer);

    try expectCount(client, 0);
    const tree = try client.tree();
    const add = try nodeOf(tree, "add");
    try std.testing.expectEqualStrings("button", add.get("role").?.string);
    try std.testing.expectEqualStrings("Add", add.get("label").?.string);

    // By key, by ID, and by a click where tree says the button is.
    _ = try client.result("act", "{\"key\":\"add\",\"action\":\"press\"}");
    try expectCount(client, 1);
    _ = try client.result("act", try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"action\":\"press\"}}", .{add.get("id").?.string}));
    try expectCount(client, 2);
    const point = center(add);
    _ = try client.result("input", try std.fmt.allocPrint(arena, "{{\"window\":1,\"events\":[{{\"type\":\"click\",\"x\":{d},\"y\":{d}}}]}}", .{ point[0], point[1] }));
    try expectCount(client, 3);

    // A slider takes a value and steps; a checkbox checks.
    _ = try client.result("act", "{\"key\":\"level\",\"action\":\"setValue\",\"text\":\"7\"}");
    try client.idle();
    try std.testing.expectEqual(@as(f64, 7), number((try nodeOf(try client.tree(), "level")).get("now").?));
    _ = try client.result("act", "{\"key\":\"level\",\"action\":\"increment\"}");
    try client.idle();
    const level = try nodeOf(try client.tree(), "level");
    try std.testing.expectEqual(@as(f64, 8), number(level.get("now").?));
    try std.testing.expectEqualStrings("slider", level.get("role").?.string);
    _ = try client.result("act", "{\"key\":\"agree\",\"action\":\"press\"}");
    try client.idle();
    const agree = try nodeOf(try client.tree(), "agree");
    try std.testing.expect(hasState(agree, "checked"));

    // The press focused the checkbox; Shift+Tab moves the focus back.
    const before = (try client.tree()).get("focus").?.string;
    try std.testing.expectEqualStrings(agree.get("id").?.string, before);
    _ = try client.result("input", "{\"events\":[{\"type\":\"key\",\"key\":\"Shift+Tab\"}]}");
    try client.idle();
    const after = (try client.tree()).get("focus") orelse return error.NoFocus;
    try std.testing.expect(!std.mem.eql(u8, before, after.string));

    // The last row of the scroll is out of sight until scrollIntoView, and
    // a press needs it in sight.
    const far = try nodeOf(try client.tree(), "far");
    try std.testing.expect(hasState(far, "offscreen") and hasAction(far, "scrollIntoView"));
    try std.testing.expect(!hasAction(try nodeOf(try client.tree(), "add"), "scrollIntoView"));
    try client.expectError("act", "{\"key\":\"far\",\"action\":\"press\"}", "failed");
    _ = try client.result("act", "{\"key\":\"far\",\"action\":\"scrollIntoView\"}");
    try client.idle();
    try std.testing.expect(!hasState(try nodeOf(try client.tree(), "far"), "offscreen"));
    _ = try client.result("act", "{\"key\":\"far\",\"action\":\"press\"}");
    try expectCount(client, 4);

    const image = try client.result("capture", "{}");
    try std.testing.expect(image.get("width").?.integer > 0 and image.get("height").?.integer > 0);
    // The base64 of PNG's signature.
    try std.testing.expect(std.mem.startsWith(u8, image.get("png").?.string, "iVBORw0KGgo"));

    try client.expectError("act", "{\"key\":\"none\",\"action\":\"press\"}", "no_element");
    try client.expectError("act", "{\"key\":\"add\",\"action\":\"selectText\"}", "unsupported");
    try client.expectError("tree", "{\"window\":9}", "no_window");
    try client.expectError("eval", "{\"script\":\"1\"}", "unsupported");
    try client.expectError("fly", "{}", "unknown_method");

    if (!has_menus) {
        // No menu bar to choose from: the app quits through a task instead.
        try client.expectError("menu", "{\"path\":[\"File\",\"Reset\"]}", "unsupported");
        try quit_app.?.post(.{ .context = quit_app.?, .call = quitTask });
        while ((client.send("windows", "{}") catch null) != null) zio.sleep(10 * std.time.ns_per_ms);
        return;
    }
    try client.expectError("menu", "{\"path\":[\"File\",\"Missing\"]}", "failed");
    try client.expectError("menu", "{\"path\":[\"Edit\",\"Disabled\"]}", "failed");

    _ = try client.result("menu", "{\"path\":[\"File\",\"Reset\"]}");
    try expectCount(client, 0);
    // Quitting answers, then the app ends and closes the connection.
    _ = try client.result("menu", "{\"path\":[\"File\",\"Quit\"]}");
    try std.testing.expect(try client.send("windows", "{}") == null);
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
    result: anyerror!void = {},
    fn run(self: *Driving) void {
        self.result = drive(self.path);
        if (self.result) |_| {} else |err| {
            std.debug.print("automation smoke failed: {s}\n", .{@errorName(err)});
            // Let the app end, so the failure is reported.
            std.process.exit(1);
        }
    }
};

fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    const directory = zio.getEnvVarOwned(allocator, if (builtin.os.tag == .windows) "TEMP" else "TMPDIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, if (builtin.os.tag == .windows) "." else "/tmp"),
        else => |other| return other,
    };
    defer allocator.free(directory);
    var suffix: [8]u8 = undefined;
    zio.random.bytes(&suffix);
    return std.fmt.allocPrint(allocator, "{s}{c}ziggurat-automation-{x}.sock", .{ directory, std.fs.path.sep, suffix });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    if (comptime !automation.enabled) {
        std.debug.print("automation: this build leaves automation out; skipped\n", .{});
        return;
    }

    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var storage: view.Storage(32, 512) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    var owner = system.Owner.init(&state, State.onMenu);
    const window = try app.createWindow(.{ .title = "Automation", .width = 360, .height = 240 });
    state.window = window;
    try host.attach(window);
    quit_app = app;
    const items = [_]system.Item{
        .{ .id = 1, .kind = .submenu, .label = "&File" },
        .{ .id = reset_command, .parent = 1, .label = "&Reset" },
        .{ .parent = 1, .kind = .separator },
        .{ .id = quit_command, .parent = 1, .label = "&Quit" },
        .{ .id = 2, .kind = .submenu, .label = "&Edit" },
        .{ .id = disabled_command, .parent = 2, .label = "&Disabled", .enabled = false },
    };
    if (has_menus) {
        try owner.attach(window);
        try owner.setMenu(&items);
    }
    window.show();

    const path = try socketPath(allocator);
    defer allocator.free(path);
    const server = (try automation.start(allocator, app, .{ .path = path })).?;
    var driving: Driving = .{ .path = path };
    const thread = try std.Thread.spawn(.{}, Driving.run, .{&driving});
    try app.run();
    server.stop();
    thread.join();
    try driving.result;
    if (has_menus) owner.detach() catch {};

    // The socket goes with the server.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(zio.io(), path, .{}));
    std.debug.print("automation: windows, tree, act, input, capture, errors and menus over the socket passed\n", .{});
}
