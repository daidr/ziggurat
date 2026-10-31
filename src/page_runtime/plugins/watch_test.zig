const std = @import("std");
const zio = @import("ziggurat_io");
const runtime = @import("ziggurat_page_runtime");
const watch = @import("watch.zig");
const allocator = std.testing.allocator;
const service = "plugin:watch";

const Fixture = struct {
    page: runtime.testing.Page = undefined,
    plugin: watch.Plugin = undefined,

    fn init(self: *Fixture, options: struct { roots: []const watch.Root = &.{}, resolve: ?watch.Resolve = null, quota: ?*watch.Quota = null }) !void {
        self.page.init(allocator);
        try self.plugin.init(allocator, .{ .post = self.page.queue.poster(), .roots = options.roots, .resolve = options.resolve, .quota = options.quota });
        try self.page.host.use(self.plugin.plugin());
        try self.page.connect();
        // The configuration.
        var configuration = try self.page.next(1000);
        configuration.deinit();
    }

    fn deinit(self: *Fixture) void {
        self.page.host.detach();
        self.plugin.deinit();
        self.page.deinit();
    }

    fn start(self: *Fixture, id: u32, root: []const u8, extra: struct { path: []const u8 = ".", recursive: bool = false, debounce: i32 = 30 }) !void {
        try self.page.call(service, @intCast(id % 8), id, "watch", watch.Service.Request{ .root = root, .path = extra.path, .recursive = extra.recursive, .debounceMs = extra.debounce });
    }

    /// Waits for the watch to be ready, or returns the code it failed with.
    fn ready(self: *Fixture, id: u32) !?watch.Service.Code {
        var packet = try self.page.next(5000);
        defer packet.deinit();
        const object = packet.value.object;
        if (object.get("id").?.integer != id) return error.UnexpectedCall;
        const kind = object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "error")) return std.meta.stringToEnum(watch.Service.Code, object.get("error").?.object.get("code").?.string).?;
        if (!std.mem.eql(u8, kind, "chunk")) return error.UnexpectedKind;
        if (!object.get("value").?.object.get("ready").?.bool) return error.NotReady;
        try self.page.ack(service, @intCast(id % 8), id, @intCast(object.get("sequence").?.integer));
        return null;
    }

    /// Reads batches until every event in `expected` arrived, failing on any
    /// other but those in `optional`. Each event is "op path" or "rename old
    /// path". Returns how the call ended, if it did.
    fn expectSome(self: *Fixture, id: u32, expected: []const []const u8, optional: []const []const u8) !Ending {
        var seen: std.ArrayList([]u8) = .empty;
        defer {
            for (seen.items) |item| allocator.free(item);
            seen.deinit(allocator);
        }
        var outcome: Ending = .running;
        while (!all(seen.items, expected)) {
            var packet = try self.page.next(5000);
            defer packet.deinit();
            const object = packet.value.object;
            if (object.get("id").?.integer != id) return error.UnexpectedCall;
            const kind = object.get("kind").?.string;
            if (std.mem.eql(u8, kind, "result")) {
                outcome = .complete;
                break;
            }
            if (std.mem.eql(u8, kind, "error")) {
                outcome = .failed;
                break;
            }
            const events = object.get("value").?.object.get("events").?.array.items;
            for (events) |event| {
                const item = event.object;
                const op = item.get("op").?.string;
                const text = if (std.mem.eql(u8, op, "rename"))
                    try std.fmt.allocPrint(allocator, "rename {s} {s}", .{ item.get("oldPath").?.string, item.get("path").?.string })
                else
                    try std.fmt.allocPrint(allocator, "{s} {s}", .{ op, item.get("path").?.string });
                errdefer allocator.free(text);
                if (!has(expected, text) and !has(optional, text)) {
                    std.debug.print("unexpected event: {s}\n", .{text});
                    return error.UnexpectedEvent;
                }
                try seen.append(allocator, text);
            }
            try self.page.ack(service, @intCast(id % 8), id, @intCast(object.get("sequence").?.integer));
        }
        for (expected) |want| if (!has(seen.items, want)) {
            std.debug.print("missing event: {s}\n", .{want});
            return error.MissingEvent;
        };
        return outcome;
    }

    fn expect(self: *Fixture, id: u32, expected: []const []const u8) !Ending {
        return self.expectSome(id, expected, &.{});
    }

    /// The call's end: its result or error.
    fn end(self: *Fixture, id: u32) !Ending {
        var packet = try self.page.next(5000);
        defer packet.deinit();
        const object = packet.value.object;
        if (object.get("id").?.integer != id) return error.UnexpectedCall;
        const kind = object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "result")) return .complete;
        if (std.mem.eql(u8, kind, "error")) return .failed;
        return error.UnexpectedKind;
    }

    fn idle(self: *Fixture) !void {
        var waited: usize = 0;
        while (!self.free()) : (waited += 1) {
            if (waited == 500) return error.WatchesLeft;
            self.page.queue.runOne(10) catch {};
        }
    }

    fn free(self: *Fixture) bool {
        for (&self.plugin.watches) |*item| if (item.phase != .free) return false;
        return true;
    }
};

const Ending = enum { running, complete, failed };

fn has(items: anytype, text: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, text)) return true;
    return false;
}

fn all(seen: []const []u8, expected: []const []const u8) bool {
    for (expected) |want| if (!has(seen, want)) return false;
    return true;
}

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(zio.io(), .{ .sub_path = path, .data = data });
}

test "a recursive watch reports what changed, pairs renames and ends when its directory goes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(zio.io(), "project/src");
    try write(tmp.dir, "project/a.txt", "a");
    try write(tmp.dir, "project/src/x.txt", "x");
    const base = try zio.realPathAlloc(tmp.dir, ".", allocator);
    defer allocator.free(base);
    const project = try std.fs.path.join(allocator, &.{ base, "project" });
    defer allocator.free(project);
    var f: Fixture = .{};
    try f.init(.{ .roots = &.{.{ .name = "project", .path = project, .recursive = true }} });
    defer f.deinit();
    try f.start(1, "project", .{ .recursive = true });
    try std.testing.expectEqual(null, try f.ready(1));

    var dir = try tmp.dir.openDir(zio.io(), "project", .{});
    defer dir.close(zio.io());
    try write(dir, "b.txt", "b");
    try write(dir, "a.txt", "longer");
    try dir.rename("src", dir, "lib", zio.io());
    try dir.createDirPath(zio.io(), "new");
    try write(dir, "new/n.txt", "n");
    try std.testing.expectEqual(.running, try f.expect(1, &.{ "create b.txt", "write a.txt", "rename src lib", "create new", "create new/n.txt" }));

    try write(dir, "lib/x.txt", "changed");
    try dir.deleteFile(zio.io(), "b.txt");
    try std.testing.expectEqual(.running, try f.expect(1, &.{ "write lib/x.txt", "remove b.txt" }));

    // What is watched going away ends the watch.
    dir.close(zio.io());
    dir = try tmp.dir.openDir(zio.io(), ".", .{});
    try tmp.dir.deleteTree(zio.io(), "project");
    // Changes seen before the directory went are reported first.
    const last = try f.expectSome(1, &.{"remove ."}, &.{ "remove a.txt", "remove lib", "remove lib/x.txt", "remove new", "remove new/n.txt" });
    if (last == .running) try std.testing.expectEqual(.complete, try f.end(1));
    try f.idle();
}

test "a watched file reports writes, replacement, removal and return" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "settings.json", "{}");
    const base = try zio.realPathAlloc(tmp.dir, ".", allocator);
    defer allocator.free(base);
    const settings = try std.fs.path.join(allocator, &.{ base, "settings.json" });
    defer allocator.free(settings);
    var f: Fixture = .{};
    try f.init(.{ .roots = &.{.{ .name = "settings", .path = settings }} });
    defer f.deinit();
    try f.start(1, "settings", .{});
    try std.testing.expectEqual(null, try f.ready(1));

    try write(tmp.dir, "settings.json", "{\"a\":1}");
    _ = try f.expect(1, &.{"write ."});
    // Editors save by replacing the file.
    try write(tmp.dir, "settings.tmp", "{\"a\":2}");
    try tmp.dir.rename("settings.tmp", tmp.dir, "settings.json", zio.io());
    _ = try f.expect(1, &.{"write ."});
    // Other files in its directory are not its concern.
    try write(tmp.dir, "other.txt", "x");
    try tmp.dir.deleteFile(zio.io(), "settings.json");
    _ = try f.expect(1, &.{"remove ."});
    try write(tmp.dir, "settings.json", "{}");
    _ = try f.expect(1, &.{"create ."});
    try f.page.cancel(service, 1, 1);
    try f.idle();
}

test "requests outside what the app allows are refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(zio.io(), "flat/sub");
    try write(tmp.dir, "flat/file.txt", "x");
    const base = try zio.realPathAlloc(tmp.dir, ".", allocator);
    defer allocator.free(base);
    const flat = try std.fs.path.join(allocator, &.{ base, "flat" });
    defer allocator.free(flat);
    const Granted = struct {
        path: []const u8,
        fn resolve(context: *anyopaque, name: []const u8) ?watch.Root {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, name, "picked-1")) return null;
            return .{ .name = name, .path = self.path, .recursive = true };
        }
    };
    var granted: Granted = .{ .path = flat };
    var f: Fixture = .{};
    try f.init(.{ .roots = &.{.{ .name = "flat", .path = flat }}, .resolve = .{ .context = &granted, .resolve = Granted.resolve } });
    defer f.deinit();
    const cases = [_]struct { root: []const u8, path: []const u8 = ".", recursive: bool = false, debounce: i32 = 0, code: watch.Service.Code }{
        .{ .root = "flat", .recursive = true, .code = .denied },
        .{ .root = "flat", .path = "sub", .code = .denied },
        .{ .root = "flat", .path = "../flat", .code = .denied },
        .{ .root = "flat", .path = "/etc", .code = .denied },
        .{ .root = "flat", .path = "missing.txt", .code = .@"not-found" },
        .{ .root = "unknown", .code = .denied },
        .{ .root = "Flat", .code = .denied },
        .{ .root = "flat", .debounce = 60001, .code = .limit },
    };
    for (cases, 1..) |case, id| {
        try f.start(@intCast(id), case.root, .{ .path = case.path, .recursive = case.recursive, .debounce = case.debounce });
        try std.testing.expectEqual(case.code, (try f.ready(@intCast(id))).?);
    }
    // A file in a flat root, and a root the app granted while it runs.
    try f.start(20, "flat", .{ .path = "file.txt" });
    try std.testing.expectEqual(null, try f.ready(20));
    try f.start(21, "picked-1", .{ .path = "sub", .recursive = true });
    try std.testing.expectEqual(null, try f.ready(21));
    try f.page.cancel(service, 20 % 8, 20);
    try f.page.cancel(service, 21 % 8, 21);
    try f.idle();
}

test "a shared quota bounds watches and a new document stops the old one's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try zio.realPathAlloc(tmp.dir, ".", allocator);
    defer allocator.free(base);
    var quota: watch.Quota = .{ .max = 1 };
    var f: Fixture = .{};
    try f.init(.{ .roots = &.{.{ .name = "base", .path = base }}, .quota = &quota });
    defer f.deinit();
    try f.start(1, "base", .{});
    try std.testing.expectEqual(null, try f.ready(1));
    try f.start(2, "base", .{});
    try std.testing.expectEqual(watch.Service.Code.limit, (try f.ready(2)).?);
    // The page changed: the old document's watch stops and frees the quota.
    try f.page.connect();
    var configuration = try f.page.next(1000);
    configuration.deinit();
    try f.idle();
    try std.testing.expectEqual(0, quota.used);
    try f.start(1, "base", .{});
    try std.testing.expectEqual(null, try f.ready(1));
}

test "roots are checked when the plugin starts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try zio.realPathAlloc(tmp.dir, ".", allocator);
    defer allocator.free(base);
    var queue: runtime.testing.Queue = .{};
    var plugin: watch.Plugin = undefined;
    try std.testing.expectError(error.InvalidRoot, plugin.init(allocator, .{ .post = queue.poster(), .roots = &.{.{ .name = "a", .path = "relative" }} }));
    try std.testing.expectError(error.InvalidRoot, plugin.init(allocator, .{ .post = queue.poster(), .roots = &.{.{ .name = "9a", .path = base }} }));
    try std.testing.expectError(error.InvalidRoot, plugin.init(allocator, .{ .post = queue.poster(), .roots = &.{ .{ .name = "a", .path = base }, .{ .name = "a", .path = base } } }));
    const missing = try std.fs.path.join(allocator, &.{ base, "missing" });
    defer allocator.free(missing);
    try std.testing.expectError(error.InvalidRoot, plugin.init(allocator, .{ .post = queue.poster(), .roots = &.{.{ .name = "a", .path = missing }} }));
}
