//! What a session keeps between commands, in a file of its own: the
//! socket, the window commands target, and the elements of each window as
//! the last snapshot or diff showed them, with their refs.
const std = @import("std");
const zio = @import("ziggurat_io");
const model = @import("model.zig");
const Problem = @import("problem.zig").Problem;

const Node = model.Node;
const Tree = model.Tree;

/// A window's elements as a snapshot or a diff last showed them.
pub const Seen = struct {
    focus: ?[]const u8 = null,
    nodes: []const Node = &.{},
    /// The elements' refs, by element ID.
    refs: std.json.ArrayHashMap(u64) = .{},

    pub fn refOf(self: *const Seen, id: []const u8) u64 {
        return self.refs.map.get(id) orelse 0;
    }
};

pub const Session = struct {
    socket: []const u8 = "",
    /// The window commands target unless they name one, 0 for the focused
    /// window.
    window: u64 = 0,
    /// The number of the next ref. Numbers are never given twice in a
    /// session, so that a stale ref can't name another element.
    next: u64 = 1,
    /// The windows' elements as last shown, by window ID.
    seen: std.json.ArrayHashMap(Seen) = .{},

    /// Takes the elements of a window as they are now: elements seen
    /// before keep their refs, new ones get new refs, and the refs of
    /// elements gone become stale. Returns what the window showed before.
    pub fn observe(self: *Session, arena: std.mem.Allocator, tree: Tree) !?Seen {
        if (self.next < 1) self.next = 1;
        const key = try std.fmt.allocPrint(arena, "{d}", .{tree.window});
        const old = self.seen.map.get(key);
        var now: Seen = .{ .focus = tree.focus, .nodes = tree.nodes };
        for (tree.nodes) |node| {
            if (now.refs.map.contains(node.id)) continue;
            if (old) |before| if (before.refs.map.get(node.id)) |ref| {
                try now.refs.map.put(arena, node.id, ref);
                continue;
            };
            try now.refs.map.put(arena, node.id, self.next);
            self.next += 1;
        }
        try self.seen.map.put(arena, key, now);
        return old;
    }

    pub fn shown(self: *const Session, window: u64) ?*Seen {
        var buffer: [24]u8 = undefined;
        return self.seen.map.getPtr(std.fmt.bufPrint(&buffer, "{d}", .{window}) catch unreachable);
    }

    /// Drops what a window showed, as when it closed.
    pub fn forget(self: *Session, window: u64) void {
        var buffer: [24]u8 = undefined;
        _ = self.seen.map.orderedRemove(std.fmt.bufPrint(&buffer, "{d}", .{window}) catch unreachable);
    }

    pub const Found = struct { window: u64, id: []const u8 };

    /// The window and the element of ref number `n`. A ref lasts while its
    /// element is in what the last snapshot or diff of its window saw.
    pub fn lookup(self: *const Session, n: u64, problem: *Problem) error{Failed}!Found {
        var windows = self.seen.map.iterator();
        while (windows.next()) |entry| {
            var refs = entry.value_ptr.refs.map.iterator();
            while (refs.next()) |ref| if (ref.value_ptr.* == n) {
                return .{ .window = std.fmt.parseInt(u64, entry.key_ptr.*, 10) catch 0, .id = ref.key_ptr.* };
            };
        }
        if (n < self.next) return stale(problem, n, "its element is gone", .{});
        return stale(problem, n, "no snapshot or diff of this session gave it", .{});
    }
};

/// Refuses a ref that names no element now. The command never takes it
/// for another element.
pub fn stale(problem: *Problem, n: u64, comptime why: []const u8, args: anytype) error{Failed} {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, why, args) catch why;
    return problem.fail("stale ref @e{d}: {s}; use a ref from the latest snapshot or diff (run snapshot)", .{ n, text });
}

/// The number of a ref, written `@e7` or `e7`.
pub fn parseRef(text: []const u8) ?u64 {
    const rest = if (std.mem.startsWith(u8, text, "@")) text[1..] else text;
    if (rest.len < 2 or rest[0] != 'e') return null;
    const digits = rest[1..];
    if (digits[0] == '0') return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return if (n > 0) n else null;
}

/// A session's name: letters, digits, '.', '_' and '-', at most 64, not
/// starting with a '.', '_' or '-'.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    return true;
}

pub fn path(arena: std.mem.Allocator, dir: []const u8, name: []const u8, problem: *Problem) ![]const u8 {
    if (!validName(name)) return problem.usage("session name \"{s}\": use letters, digits, '.', '_' and '-'", .{name});
    return std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}.json", .{name}) });
}

/// Reads the session `name`, which `open` made.
pub fn load(arena: std.mem.Allocator, dir: []const u8, name: []const u8, problem: *Problem) !Session {
    const file = try path(arena, dir, name, problem);
    const bytes = std.Io.Dir.cwd().readFileAlloc(zio.io(), file, arena, .limited(256 << 20)) catch |err| switch (err) {
        error.FileNotFound => return problem.fail("no session \"{s}\": run ziggurat-automation open --socket <path> first", .{name}),
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Session, arena, bytes, model.parse_options) catch |err|
        problem.fail("session \"{s}\" is damaged ({s}): run ziggurat-automation open again", .{ name, @errorName(err) });
}

/// Writes the session, replacing its file at once, so that a command
/// killed halfway leaves the one before.
pub fn save(arena: std.mem.Allocator, session: *const Session, dir: []const u8, name: []const u8, problem: *Problem) !void {
    const file = try path(arena, dir, name, problem);
    const io = zio.io();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    const bytes = try std.json.Stringify.valueAlloc(arena, session.*, .{ .emit_null_optional_fields = false });
    var suffix: [6]u8 = undefined;
    zio.random.bytes(&suffix);
    const temporary = try std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ file, suffix });
    try cwd.writeFile(io, .{ .sub_path = temporary, .data = bytes });
    cwd.rename(temporary, cwd, file, io) catch |err| {
        cwd.deleteFile(io, temporary) catch {};
        return err;
    };
}

/// Removes the session's file; false when there was none.
pub fn remove(arena: std.mem.Allocator, dir: []const u8, name: []const u8, problem: *Problem) !bool {
    const file = try path(arena, dir, name, problem);
    std.Io.Dir.cwd().deleteFile(zio.io(), file) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn texts(arena: std.mem.Allocator, specs: []const []const u8) ![]Node {
    var out: std.ArrayList(Node) = .empty;
    for (specs) |spec| {
        const at = std.mem.indexOfScalar(u8, spec, ':').?;
        try out.append(arena, .{ .id = spec[0..at], .role = "text", .label = spec[at + 1 ..] });
    }
    return out.items;
}

test "elements keep their refs while windows show them, and refs of elements gone are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problem: Problem = .{};
    var s: Session = .{};
    _ = try s.observe(arena, .{ .window = 1, .nodes = try texts(arena, &.{ "10:a", "11:b", "12:c" }) });
    _ = try s.observe(arena, .{ .window = 2, .nodes = try texts(arena, &.{"10:other window"}) });
    const Want = struct {
        fn ref(session: *const Session, p: *Problem, n: u64, window: u64, id: []const u8) !void {
            const found = try session.lookup(n, p);
            try std.testing.expectEqual(window, found.window);
            try std.testing.expectEqualStrings(id, found.id);
        }
        fn stale(session: *const Session, p: *Problem, n: u64, why: []const u8) !void {
            try std.testing.expectError(error.Failed, session.lookup(n, p));
            try std.testing.expect(std.mem.indexOf(u8, p.message, why) != null);
        }
    };
    try Want.ref(&s, &problem, 1, 1, "10");
    try Want.ref(&s, &problem, 2, 1, "11");
    try Want.ref(&s, &problem, 3, 1, "12");
    try Want.ref(&s, &problem, 4, 2, "10");
    try Want.stale(&s, &problem, 5, "no snapshot or diff");

    // 11 goes, 13 comes; 12 moves before 10.
    const before = (try s.observe(arena, .{ .window = 1, .nodes = try texts(arena, &.{ "12:c", "10:a", "13:d" }) })).?;
    try std.testing.expectEqual(@as(usize, 3), before.nodes.len);
    try Want.ref(&s, &problem, 1, 1, "10");
    try Want.ref(&s, &problem, 3, 1, "12");
    try Want.ref(&s, &problem, 5, 1, "13");
    try Want.stale(&s, &problem, 2, "gone");
    try Want.ref(&s, &problem, 4, 2, "10");

    // 11 coming back is new to the session: its old ref stays stale.
    _ = try s.observe(arena, .{ .window = 1, .nodes = try texts(arena, &.{"11:b"}) });
    try Want.ref(&s, &problem, 6, 1, "11");
    try Want.stale(&s, &problem, 2, "gone");
    try Want.stale(&s, &problem, 1, "gone");

    s.forget(2);
    try Want.stale(&s, &problem, 4, "gone");
    try std.testing.expectEqual(@as(u64, 7), s.next);
}

test "refs are written @e and a number" {
    const cases = [_]struct { []const u8, u64 }{ .{ "@e1", 1 }, .{ "e12", 12 }, .{ "@e0", 0 }, .{ "@e", 0 }, .{ "@x1", 0 }, .{ "@e01", 0 }, .{ "@e-1", 0 }, .{ "e1a", 0 }, .{ "key=a", 0 } };
    for (cases) |case| try std.testing.expectEqual(if (case[1] == 0) null else @as(?u64, case[1]), parseRef(case[0]));
}

test "sessions keep files of their own" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problem: Problem = .{};
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(zio.io(), ".", arena);
    try std.testing.expectError(error.Usage, path(arena, dir, "../x", &problem));
    try std.testing.expectError(error.Failed, load(arena, dir, "a", &problem));
    try std.testing.expect(std.mem.indexOf(u8, problem.message, "open") != null);

    var s: Session = .{ .socket = "/tmp/app.sock", .window = 2 };
    _ = try s.observe(arena, .{ .window = 2, .focus = "10", .nodes = try texts(arena, &.{"10:a"}) });
    try save(arena, &s, dir, "a", &problem);
    var other: Session = .{ .socket = "/tmp/app.sock" };
    _ = try other.observe(arena, .{ .window = 2, .nodes = try texts(arena, &.{ "20:x", "10:a" }) });
    try save(arena, &other, dir, "b", &problem);

    const got = try load(arena, dir, "a", &problem);
    try std.testing.expectEqualStrings(s.socket, got.socket);
    try std.testing.expectEqual(@as(u64, 2), got.window);
    try std.testing.expectEqual(@as(u64, 2), got.next);
    try std.testing.expectEqualStrings("10", got.shown(2).?.focus.?);
    const found = try got.lookup(1, &problem);
    try std.testing.expectEqual(@as(u64, 2), found.window);
    try std.testing.expectEqualStrings("10", found.id);
    try std.testing.expect(try remove(arena, dir, "a", &problem));
    try std.testing.expect(!try remove(arena, dir, "a", &problem));
}
