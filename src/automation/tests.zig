const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const view = @import("ziggurat_view");
const automation = @import("root.zig");
const protocol = automation.protocol;

const Failure = protocol.Failure;
const Error = protocol.Error;
const fail = protocol.fail;

/// An app of one window with a counter, as the protocol sees it.
const Fake = struct {
    count: u32 = 0,
    name: []const u8 = "Ada",
    events: std.ArrayList(protocol.InputEvent) = .empty,
    texts: [8][]const u8 = undefined,
    menus: usize = 0,
    acted: ?protocol.Act = null,
    quit: bool = false,
    allocator: std.mem.Allocator,

    fn driver(self: *Fake) protocol.Driver {
        return .{ .context = self, .vtable = &.{ .windows = windows, .tree = tree, .act = act, .input = input, .menu = menu, .capture = capture, .eval = eval, .idle = idle } };
    }
    fn of(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }
    fn check(window: u64, arena: std.mem.Allocator, failure: *Failure) Error!void {
        if (window > 1) return fail(failure, arena, .no_window, "no window {d}", .{window});
    }
    fn windows(context: *anyopaque, arena: std.mem.Allocator, _: *Failure) Error![]const protocol.WindowInfo {
        if (of(context).quit) return error.Quit;
        const list = try arena.alloc(protocol.WindowInfo, 1);
        const rect: protocol.Rect = .{ .x = 10, .y = 20, .width = 400, .height = 300 };
        list[0] = .{ .id = 1, .title = "Counter", .kind = "content", .bounds = rect, .contentBounds = rect, .focused = true, .visible = true };
        return list;
    }
    fn tree(context: *anyopaque, arena: std.mem.Allocator, window: u64, failure: *Failure) Error!protocol.Tree {
        const self = of(context);
        try check(window, arena, failure);
        const nodes = try arena.alloc(protocol.Node, 3);
        nodes[0] = .{ .id = .{ .value = 15956256791619451359 }, .role = "text", .label = try std.fmt.allocPrint(arena, "Count: {d}", .{self.count}), .bounds = .{ .x = 20, .y = 20, .width = 360, .height = 18 } };
        nodes[1] = .{ .id = .{ .value = 7 }, .parent = .{ .value = 15956256791619451359 }, .role = "button", .key = .{ .value = view.key("add") }, .label = "Add", .bounds = .{ .x = 20, .y = 48, .width = 360, .height = 32 }, .states = &.{"focusable"}, .actions = &.{ "press", "focus" } };
        nodes[2] = .{ .id = .{ .value = 9 }, .role = "button", .key = .{ .value = view.key("twin") }, .label = "Twin", .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 } };
        return .{ .window = 1, .focus = .{ .value = 7 }, .nodes = nodes };
    }
    fn act(context: *anyopaque, arena: std.mem.Allocator, window: u64, request: protocol.Act, failure: *Failure) Error!void {
        const self = of(context);
        try check(window, arena, failure);
        if (request.id != 7 and request.id != 9) return fail(failure, arena, .no_element, "window 1 shows no element {d}", .{request.id});
        // The request's strings last until the next one; keep the text.
        if (self.acted) |old| self.allocator.free(old.text);
        self.acted = request;
        self.acted.?.text = self.allocator.dupe(u8, request.text) catch return error.OutOfMemory;
        if (request.action == .press) self.count += 1;
    }
    fn input(context: *anyopaque, arena: std.mem.Allocator, window: u64, events: []const protocol.InputEvent, failure: *Failure) Error!void {
        const self = of(context);
        try check(window, arena, failure);
        for (events) |event| {
            var copy = event;
            if (event == .text) {
                copy = .{ .text = self.allocator.dupe(u8, event.text) catch return error.OutOfMemory };
            }
            self.events.append(self.allocator, copy) catch return error.OutOfMemory;
        }
    }
    fn menu(context: *anyopaque, arena: std.mem.Allocator, window: u64, path: []const []const u8, failure: *Failure) Error!void {
        try check(window, arena, failure);
        if (!std.mem.eql(u8, path[0], "File")) return fail(failure, arena, .failed, "the menu has no item", .{});
        of(context).menus += 1;
    }
    fn capture(_: *anyopaque, arena: std.mem.Allocator, window: u64, failure: *Failure) Error!protocol.Capture {
        try check(window, arena, failure);
        return .{ .png = "PNG", .width = 2, .height = 1 };
    }
    fn eval(_: *anyopaque, arena: std.mem.Allocator, window: u64, script: []const u8, failure: *Failure) Error![]const u8 {
        try check(window, arena, failure);
        if (std.mem.eql(u8, script, "throw 1")) return fail(failure, arena, .failed, "the script threw", .{});
        return "\"Todo\"";
    }
    fn idle(_: *anyopaque, arena: std.mem.Allocator, window: u64, timeout: u64, failure: *Failure) Error!void {
        try check(window, arena, failure);
        if (timeout == 1) return fail(failure, arena, .timeout, "window 1 still draws after 1 ms", .{});
    }
    fn deinit(self: *Fake) void {
        for (self.events.items) |event| if (event == .text) self.allocator.free(event.text);
        self.events.deinit(self.allocator);
        if (self.acted) |acted| self.allocator.free(acted.text);
    }
};

/// Answers `requests`, one per line, and returns the answers.
fn exchange(fake: *Fake, requests: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(requests);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try automation.serveLines(std.testing.allocator, fake.driver(), &in, &out.writer);
    return out.toOwnedSlice();
}
fn expectAnswer(fake: *Fake, request: []const u8, expected: []const u8) !void {
    const line = try std.mem.concat(std.testing.allocator, u8, &.{ request, "\n" });
    defer std.testing.allocator.free(line);
    const answer = try exchange(fake, line);
    defer std.testing.allocator.free(answer);
    const wanted = try std.mem.concat(std.testing.allocator, u8, &.{ expected, "\n" });
    defer std.testing.allocator.free(wanted);
    try std.testing.expectEqualStrings(wanted, answer);
}

test "windows lists the app's windows" {
    var fake: Fake = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    try expectAnswer(&fake, "{\"id\": 1, \"method\": \"windows\"}",
        \\{"id":1,"result":{"windows":[{"id":1,"title":"Counter","kind":"content","bounds":{"x":10,"y":20,"width":400,"height":300},"contentBounds":{"x":10,"y":20,"width":400,"height":300},"focused":true,"visible":true}]}}
    );
}

test "tree gives IDs and keys as strings of digits" {
    var fake: Fake = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    const answer = try exchange(&fake, "{\"id\":\"t\",\"method\":\"tree\",\"params\":{\"window\":1}}\n");
    defer std.testing.allocator.free(answer);
    try std.testing.expect(std.mem.startsWith(u8, answer, "{\"id\":\"t\",\"result\":{\"window\":1,\"focus\":\"7\",\"nodes\":[{\"id\":\"15956256791619451359\",\"role\":\"text\",\"label\":\"Count: 0\""));
    var key: [32]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, answer, try std.fmt.bufPrint(&key, "\"key\":\"{d}\"", .{view.key("add")})) != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"parent\":\"15956256791619451359\"") != null);
    // Fields the element lacks are left out.
    try std.testing.expect(std.mem.indexOf(u8, answer, "null") == null);
}

test "act finds an element by its ID or its key" {
    var fake: Fake = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    try expectAnswer(&fake, "{\"id\":3,\"method\":\"act\",\"params\":{\"key\":\"add\",\"action\":\"press\"}}", "{\"id\":3,\"result\":{}}");
    try std.testing.expectEqual(@as(u32, 1), fake.count);
    try expectAnswer(&fake, "{\"id\":4,\"method\":\"act\",\"params\":{\"id\":\"7\",\"action\":\"setValue\",\"text\":\"Grace\"}}", "{\"id\":4,\"result\":{}}");
    try std.testing.expectEqualStrings("Grace", fake.acted.?.text);
    try std.testing.expectEqual(protocol.Action.setValue, fake.acted.?.action);
    // The key's value, as tree lists it, finds it too.
    var request: [160]u8 = undefined;
    try expectAnswer(&fake, try std.fmt.bufPrint(&request, "{{\"id\":5,\"method\":\"act\",\"params\":{{\"key\":\"{d}\",\"action\":\"focus\"}}}}", .{view.key("twin")}), "{\"id\":5,\"result\":{}}");
    try std.testing.expectEqual(@as(u64, 9), fake.acted.?.id);
    try expectAnswer(&fake, "{\"id\":6,\"method\":\"act\",\"params\":{\"key\":\"none\",\"action\":\"press\"}}",
        \\{"id":6,"error":{"code":"no_element","message":"no element has the key \"none\""}}
    );
    try expectAnswer(&fake, "{\"id\":7,\"method\":\"act\",\"params\":{\"id\":\"8\",\"action\":\"press\"}}",
        \\{"id":7,"error":{"code":"no_element","message":"window 1 shows no element 8"}}
    );
    try expectAnswer(&fake, "{\"id\":8,\"method\":\"act\",\"params\":{\"action\":\"press\"}}",
        \\{"id":8,"error":{"code":"invalid_request","message":"act needs the id or the key of an element"}}
    );
    try expectAnswer(&fake, "{\"id\":9,\"method\":\"act\",\"params\":{\"id\":\"7\",\"key\":\"add\",\"action\":\"press\"}}",
        \\{"id":9,"error":{"code":"invalid_request","message":"act takes an id or a key, not both"}}
    );
    try expectAnswer(&fake, "{\"id\":10,\"method\":\"act\",\"params\":{\"id\":\"7\",\"action\":\"jump\"}}",
        \\{"id":10,"error":{"code":"invalid_request","message":"no action \"jump\""}}
    );
}

test "input turns clicks and keys into the events a platform sends" {
    var fake: Fake = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    try expectAnswer(&fake,
        \\{"id":5,"method":"input","params":{"window":1,"events":[{"type":"click","x":200,"y":99,"clicks":2},{"type":"text","text":"Grace"},{"type":"key","key":"CmdOrCtrl+A"},{"type":"wheel","x":1,"y":2,"dy":48},{"type":"pointerDown","x":3,"y":4,"button":"right","mods":["shift"]}]}}
    , "{\"id\":5,\"result\":{}}");
    const events = fake.events.items;
    try std.testing.expectEqual(@as(usize, 10), events.len);
    try std.testing.expect(events[0] == .pointer_move);
    try std.testing.expect(events[1] == .pointer_down and events[2] == .pointer_up and events[3] == .pointer_down and events[4] == .pointer_up);
    try std.testing.expectEqual(@as(f32, 99), events[1].pointer_down.y);
    try std.testing.expectEqualStrings("Grace", events[5].text);
    try std.testing.expect(events[6] == .key_down and events[7] == .key_up);
    try std.testing.expectEqual(@import("ziggurat").KeyCode.a, events[6].key_down.key);
    try std.testing.expectEqual(@as(f32, 48), events[8].wheel.dy);
    try std.testing.expect(events[9].pointer_down.button == .secondary and events[9].pointer_down.modifiers.shift);
    try expectAnswer(&fake, "{\"id\":6,\"method\":\"input\",\"params\":{\"events\":[{\"type\":\"fly\"}]}}",
        \\{"id":6,"error":{"code":"invalid_request","message":"event 0: no event type \"fly\""}}
    );
    try expectAnswer(&fake, "{\"id\":7,\"method\":\"input\",\"params\":{\"events\":[{\"type\":\"key\",\"key\":\"Hyper+Q\"}]}}",
        \\{"id":7,"error":{"code":"invalid_request","message":"event 0: no modifier in \"Hyper+Q\""}}
    );
    try expectAnswer(&fake, "{\"id\":8,\"method\":\"input\",\"params\":{\"events\":[{\"type\":\"text\",\"text\":\"a\",\"x\":1}]}}",
        \\{"id":8,"error":{"code":"invalid_request","message":"event 0: text takes no field \"x\""}}
    );
}

test "errors name their code, and the line's id when it has one" {
    var fake: Fake = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    try expectAnswer(&fake, "not json", "{\"id\":null,\"error\":{\"code\":\"parse_error\",\"message\":\"the line is not JSON: SyntaxError\"}}");
    try expectAnswer(&fake, "[1]", "{\"id\":null,\"error\":{\"code\":\"parse_error\",\"message\":\"a request is a JSON object\"}}");
    try expectAnswer(&fake, "{\"id\":2}", "{\"id\":2,\"error\":{\"code\":\"invalid_request\",\"message\":\"the request has no method\"}}");
    try expectAnswer(&fake, "{\"id\":2,\"method\":\"fly\"}", "{\"id\":2,\"error\":{\"code\":\"unknown_method\",\"message\":\"no method \\\"fly\\\"\"}}");
    try expectAnswer(&fake, "{\"id\":[1,2],\"method\":\"tree\",\"params\":{\"window\":7}}", "{\"id\":[1,2],\"error\":{\"code\":\"no_window\",\"message\":\"no window 7\"}}");
    try expectAnswer(&fake, "{\"id\":2,\"method\":\"tree\",\"params\":{\"windw\":1}}", "{\"id\":2,\"error\":{\"code\":\"invalid_request\",\"message\":\"params of tree: unknown field \\\"windw\\\"\"}}");
    try expectAnswer(&fake, "{\"id\":2,\"method\":\"idle\",\"params\":{\"timeout\":-1}}", "{\"id\":2,\"error\":{\"code\":\"invalid_request\",\"message\":\"timeout is negative\"}}");
    try expectAnswer(&fake, "{\"id\":2,\"method\":\"idle\",\"params\":{\"timeout\":1}}", "{\"id\":2,\"error\":{\"code\":\"timeout\",\"message\":\"window 1 still draws after 1 ms\"}}");
    try expectAnswer(&fake, "{\"id\":2,\"method\":\"menu\",\"params\":{\"path\":[]}}", "{\"id\":2,\"error\":{\"code\":\"invalid_request\",\"message\":\"menu needs the path of the item, as [\\\"File\\\", \\\"New\\\"]\"}}");
    try expectAnswer(&fake, "{\"id\":2,\"method\":\"eval\",\"params\":{\"script\":\"throw 1\"}}", "{\"id\":2,\"error\":{\"code\":\"failed\",\"message\":\"the script threw\"}}");
}

test "requests on a connection are answered in order" {
    var fake: Fake = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    const answers = try exchange(&fake,
        \\{"id":1,"method":"eval","params":{"window":1,"script":"document.title"}}
        \\
        \\{"id":2,"method":"capture"}
        \\{"id":3,"method":"menu","params":{"path":["File","New Window"]}}
        \\{"id":4,"method":"idle","params":{"window":1,"timeout":5000}}
    );
    defer std.testing.allocator.free(answers);
    try std.testing.expectEqualStrings(
        \\{"id":1,"result":{"value":"Todo"}}
        \\{"id":2,"result":{"png":"UE5H","width":2,"height":1}}
        \\{"id":3,"result":{}}
        \\{"id":4,"result":{}}
        \\
    , answers);
    try std.testing.expectEqual(@as(usize, 1), fake.menus);
}

test "a quitting app closes the connection without an answer" {
    var fake: Fake = .{ .allocator = std.testing.allocator, .quit = true };
    defer fake.deinit();
    const answers = try exchange(&fake, "{\"id\":1,\"method\":\"windows\"}\n{\"id\":2,\"method\":\"windows\"}\n");
    defer std.testing.allocator.free(answers);
    try std.testing.expectEqualStrings("", answers);
}

test "a line longer than the limit is refused" {
    var fake: Fake = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    const long = try std.testing.allocator.alloc(u8, protocol.max_line + 10);
    defer std.testing.allocator.free(long);
    @memset(long, ' ');
    const answers = try exchange(&fake, long);
    defer std.testing.allocator.free(answers);
    try std.testing.expect(std.mem.indexOf(u8, answers, "\"code\":\"parse_error\"") != null);
}

test "the socket is the user's alone and replaces only a stale one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = zio.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try zio.realpath(tmp.dir, ".", &dir_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/app.sock", .{dir});
    if (path.len > std.Io.net.UnixAddress.max_len) return error.SkipZigTest;

    var server = try automation.listen(path);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.unix_domain_socket, stat.kind);
    try std.testing.expectEqual(@as(u32, 0o600), zio.modeOf(stat.permissions) & 0o777);
    // Another app listens there: it is left alone.
    try std.testing.expectError(error.AddressInUse, automation.listen(path));
    // Ended without closing: the socket is replaced.
    server.deinit(io);
    var again = try automation.listen(path);
    again.deinit(io);
    try std.Io.Dir.cwd().deleteFile(io, path);
    // A file that is no socket is left alone.
    try tmp.dir.writeFile(io, .{ .sub_path = "app.sock", .data = "keep" });
    try std.testing.expectError(error.NotSocket, automation.listen(path));
}
