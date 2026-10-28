const std = @import("std");
const zio = @import("ziggurat_io");
const runtime = @import("ziggurat_page_runtime");
const sqlite = @import("sqlite.zig");
const Service = sqlite.Service;
const allocator = std.testing.allocator;
const service = "plugin:sqlite";

const Fixture = struct {
    page: runtime.testing.Page = undefined,
    plugin: sqlite.Plugin = undefined,
    tmp: std.testing.TmpDir = undefined,
    directory: []u8 = &.{},
    next_id: u32 = 1,

    fn init(self: *Fixture, options: struct { library: ?[]const u8 = null, max_result_bytes: usize = 64 * 1024 * 1024 }) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const base = try zio.realPathAlloc(self.tmp.dir, ".", allocator);
        defer allocator.free(base);
        self.directory = try std.fs.path.join(allocator, &.{ base, "data" });
        errdefer allocator.free(self.directory);
        self.page.init(allocator);
        try self.plugin.init(allocator, .{ .post = self.page.queue.poster(), .directory = self.directory, .library = options.library, .busy_timeout_ms = 200, .max_result_bytes = options.max_result_bytes });
        try self.page.host.use(self.plugin.plugin());
        try self.page.connect();
        var configuration = try self.page.next(1000);
        configuration.deinit();
    }

    fn deinit(self: *Fixture) void {
        self.page.host.detach();
        self.plugin.deinit();
        self.page.deinit();
        allocator.free(self.directory);
        self.tmp.cleanup();
    }

    fn send(self: *Fixture, method: []const u8, params: anytype) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        try self.page.call(service, @intCast(id % 32), id, method, params);
        return id;
    }

    /// Reads one call to its end, acknowledging chunks as the page would.
    fn outcome(self: *Fixture, id: u32) !Outcome {
        var result: Outcome = .{ .arena = .init(allocator) };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        var rows: std.ArrayList(std.json.Value) = .empty;
        while (true) {
            var packet = try self.page.next(5000);
            defer packet.deinit();
            const object = packet.value.object;
            if (object.get("id").?.integer != id) return error.UnexpectedCall;
            const kind = object.get("kind").?.string;
            if (std.mem.eql(u8, kind, "chunk")) {
                const value = try clone(arena, object.get("value").?);
                if (value.object.get("columns").? != .null) result.columns = value.object.get("columns").?;
                try rows.appendSlice(arena, value.object.get("rows").?.array.items);
                result.parts += 1;
                try self.page.ack(service, @intCast(id % 32), id, @intCast(object.get("sequence").?.integer));
            } else if (std.mem.eql(u8, kind, "result")) {
                if (object.get("value")) |value| result.value = try clone(arena, value);
                result.rows = rows.items;
                return result;
            } else if (std.mem.eql(u8, kind, "error")) {
                const failure = object.get("error").?.object;
                result.code = std.meta.stringToEnum(Service.Code, failure.get("code").?.string);
                result.message = try arena.dupe(u8, failure.get("message").?.string);
                return result;
            } else return error.UnexpectedKind;
        }
    }

    fn call(self: *Fixture, method: []const u8, params: anytype) !Outcome {
        return self.outcome(try self.send(method, params));
    }

    fn open(self: *Fixture, name: []const u8, read_only: bool) !u32 {
        var result = try self.call("open", Service.Open{ .name = name, .readOnly = read_only });
        defer result.deinit();
        if (result.code) |code| {
            std.debug.print("open {s}: {s} {s}\n", .{ name, @tagName(code), result.message });
            return error.OpenFailed;
        }
        return @intCast(result.value.integer);
    }

    fn execute(self: *Fixture, connection: u32, sql: []const u8, params: []const Service.Value) !Outcome {
        return self.call("execute", Service.Statement{ .connection = connection, .sql = sql, .params = params });
    }

    fn query(self: *Fixture, connection: u32, sql: []const u8, params: []const Service.Value) !Outcome {
        return self.call("query", Service.Statement{ .connection = connection, .sql = sql, .params = params });
    }

    fn ok(self: *Fixture, connection: u32, sql: []const u8, params: []const Service.Value) !void {
        var result = try self.execute(connection, sql, params);
        defer result.deinit();
        if (result.code) |code| {
            std.debug.print("{s}: {s} {s}\n", .{ sql, @tagName(code), result.message });
            return error.StatementFailed;
        }
    }

    fn idle(self: *Fixture) !void {
        var waited: usize = 0;
        while (!self.free()) : (waited += 1) {
            if (waited == 500) return error.JobsLeft;
            self.page.queue.runOne(10) catch {};
        }
    }

    fn free(self: *Fixture) bool {
        for (&self.plugin.jobs) |*job| if (job.phase != .free) return false;
        return true;
    }
};

const Outcome = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value = .null,
    columns: std.json.Value = .null,
    rows: []const std.json.Value = &.{},
    parts: usize = 0,
    code: ?Service.Code = null,
    message: []const u8 = "",

    fn deinit(self: *Outcome) void {
        self.arena.deinit();
    }
};

fn clone(arena: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    const json = try std.json.Stringify.valueAlloc(arena, value, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

const none: Service.Value = .{ .type = .null, .integer = null, .real = null, .special = null, .text = null, .blob = null };
fn integer(digits: []const u8) Service.Value {
    var value = none;
    value.type = .integer;
    value.integer = digits;
    return value;
}
fn real(number: f64) Service.Value {
    var value = none;
    value.type = .real;
    value.real = number;
    return value;
}
fn text(string: []const u8) Service.Value {
    var value = none;
    value.type = .text;
    value.text = string;
    return value;
}
fn blob(base64: []const u8) Service.Value {
    var value = none;
    value.type = .blob;
    value.blob = base64;
    return value;
}

fn field(cell: std.json.Value, name: []const u8) std.json.Value {
    return cell.object.get(name).?;
}

test "values keep their storage class through execute and query" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const db = try f.open(":memory:", false);
    try f.ok(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, big INTEGER, r REAL, s TEXT, b BLOB, n)", &.{});
    var inserted = try f.execute(db, "INSERT INTO t (big, r, s, b, n) VALUES (?, ?, ?, ?, ?)", &.{ integer("9007199254740993"), real(1.5), text("héllo"), blob("AAEC/w=="), none });
    defer inserted.deinit();
    try std.testing.expectEqual(null, inserted.code);
    try std.testing.expectEqual(1, field(inserted.value, "changes").integer);
    try std.testing.expectEqualStrings("1", field(inserted.value, "lastInsertId").string);
    try f.ok(db, "INSERT INTO t (big, r, s) VALUES (-9223372036854775808, 1e999, CAST(x'61ff62' AS TEXT))", &.{});
    try f.ok(db, "INSERT INTO t (r, b) VALUES (-1e999, x'')", &.{});

    var rows = try f.query(db, "SELECT id, big, r, s, b, n FROM t ORDER BY id", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(null, rows.code);
    try std.testing.expectEqual(1, rows.parts);
    try std.testing.expectEqual(6, rows.columns.array.items.len);
    try std.testing.expectEqualStrings("big", rows.columns.array.items[1].string);
    try std.testing.expectEqual(3, rows.rows.len);
    const first = rows.rows[0].array.items;
    try std.testing.expectEqualStrings("integer", field(first[1], "type").string);
    try std.testing.expectEqualStrings("9007199254740993", field(first[1], "integer").string);
    try std.testing.expectEqual(1.5, field(first[2], "real").float);
    try std.testing.expectEqualStrings("héllo", field(first[3], "text").string);
    try std.testing.expectEqualStrings("AAEC/w==", field(first[4], "blob").string);
    try std.testing.expectEqualStrings("null", field(first[5], "type").string);
    const second = rows.rows[1].array.items;
    try std.testing.expectEqualStrings("-9223372036854775808", field(second[1], "integer").string);
    try std.testing.expectEqualStrings("Infinity", field(second[2], "special").string);
    try std.testing.expectEqualStrings("a\u{FFFD}b", field(second[3], "text").string);
    const third = rows.rows[2].array.items;
    try std.testing.expectEqualStrings("-Infinity", field(third[2], "special").string);
    try std.testing.expectEqualStrings("blob", field(third[4], "type").string);
    try std.testing.expectEqualStrings("", field(third[4], "blob").string);

    // RETURNING rows of an execute are consumed; changes count the statement.
    // RETURNING needs SQLite 3.35; Windows' own library may be older.
    const returning = f.plugin.library.?.libversion_number() >= 3_035_000;
    var updated = try f.execute(db, if (returning) "UPDATE t SET n = 1 WHERE id > ? RETURNING id" else "UPDATE t SET n = 1 WHERE id > ?", &.{integer("1")});
    defer updated.deinit();
    try std.testing.expectEqual(2, field(updated.value, "changes").integer);

    var closed = try f.call("closeDatabase", Service.Connection{ .connection = db });
    defer closed.deinit();
    try std.testing.expectEqual(null, closed.code);
    var again = try f.call("closeDatabase", Service.Connection{ .connection = db });
    defer again.deinit();
    try std.testing.expectEqual(null, again.code);
    var after = try f.query(db, "SELECT 1", &.{});
    defer after.deinit();
    try std.testing.expectEqual(.closed, after.code.?);
    try f.idle();
}

test "statements are checked before they run" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const db = try f.open(":memory:", false);
    const cases = [_]struct { sql: []const u8, params: []const Service.Value, code: Service.Code }{
        .{ .sql = "SELECT ?", .params = &.{}, .code = .invalid },
        .{ .sql = "SELECT ?", .params = &.{integer("12x")}, .code = .invalid },
        .{ .sql = "SELECT ?", .params = &.{integer("9223372036854775808")}, .code = .invalid },
        .{ .sql = "SELECT ?", .params = &.{blob("***")}, .code = .invalid },
        .{ .sql = "SELECT 1; SELECT 2", .params = &.{}, .code = .invalid },
        .{ .sql = "", .params = &.{}, .code = .invalid },
        .{ .sql = "SELEC 1", .params = &.{}, .code = .sqlite },
        .{ .sql = "ATTACH DATABASE 'x.db' AS x", .params = &.{}, .code = .denied },
        .{ .sql = "BEGIN", .params = &.{}, .code = .denied },
        .{ .sql = "VACUUM INTO '/tmp/x.db'", .params = &.{}, .code = .denied },
    };
    for (cases) |case| {
        var result = try f.execute(db, case.sql, case.params);
        defer result.deinit();
        std.testing.expectEqual(case.code, result.code.?) catch |err| {
            std.debug.print("{s}: {s}\n", .{ case.sql, result.message });
            return err;
        };
    }
    // The connection still works.
    var rows = try f.query(db, "SELECT ? + 1 AS n", &.{integer("41")});
    defer rows.deinit();
    try std.testing.expectEqualStrings("42", field(rows.rows[0].array.items[0], "integer").string);
    try f.idle();
}

test "large results arrive in parts and a result over the limit fails" {
    var f: Fixture = .{};
    try f.init(.{ .max_result_bytes = 4 * 1024 * 1024 });
    defer f.deinit();
    const db = try f.open(":memory:", false);
    try f.ok(db, "CREATE TABLE t (n INTEGER, s TEXT)", &.{});
    try f.ok(db, "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 5000) INSERT INTO t SELECT n, printf('%.*c', 100, 'x') FROM c", &.{});
    var rows = try f.query(db, "SELECT n, s FROM t ORDER BY n", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(null, rows.code);
    try std.testing.expect(rows.parts > 8);
    try std.testing.expectEqual(5000, rows.rows.len);
    for (rows.rows, 1..) |row, n| {
        var buffer: [16]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "{d}", .{n}), field(row.array.items[0], "integer").string);
    }
    var big = try f.query(db, "SELECT a.s FROM t a, t b LIMIT 100000", &.{});
    defer big.deinit();
    try std.testing.expectEqual(.limit, big.code.?);
    try f.idle();
}

test "transactions commit together or not at all" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const db = try f.open("app.db", false);
    try f.ok(db, "CREATE TABLE t (n INTEGER UNIQUE)", &.{});
    var committed = try f.call("transaction", Service.Batch{ .connection = db, .statements = &.{
        .{ .sql = "INSERT INTO t VALUES (?)", .params = &.{integer("1")} },
        .{ .sql = "INSERT INTO t VALUES (?), (?)", .params = &.{ integer("2"), integer("3") } },
    } });
    defer committed.deinit();
    try std.testing.expectEqual(null, committed.code);
    try std.testing.expectEqual(2, committed.value.array.items.len);
    try std.testing.expectEqual(2, field(committed.value.array.items[1], "changes").integer);
    try std.testing.expectEqualStrings("3", field(committed.value.array.items[1], "lastInsertId").string);

    var failed = try f.call("transaction", Service.Batch{ .connection = db, .statements = &.{
        .{ .sql = "INSERT INTO t VALUES (4)", .params = &.{} },
        .{ .sql = "INSERT INTO t VALUES (1)", .params = &.{} },
    } });
    defer failed.deinit();
    try std.testing.expectEqual(.sqlite, failed.code.?);
    try std.testing.expect(std.mem.indexOf(u8, failed.message, "statement 2") != null);
    var count = try f.query(db, "SELECT count(*) FROM t", &.{});
    defer count.deinit();
    try std.testing.expectEqualStrings("3", field(count.rows[0].array.items[0], "integer").string);

    // A second connection sees the committed rows; a read-only one cannot write.
    const reader = try f.open("app.db", true);
    var seen = try f.query(reader, "SELECT max(n) FROM t", &.{});
    defer seen.deinit();
    try std.testing.expectEqualStrings("3", field(seen.rows[0].array.items[0], "integer").string);
    var write = try f.execute(reader, "INSERT INTO t VALUES (9)", &.{});
    defer write.deinit();
    try std.testing.expectEqual(.sqlite, write.code.?);
    try f.idle();
}

test "names stay in the directory, connections are limited and close with the page" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    for ([_][]const u8{ "../x.db", "/etc/x.db", "a//b.db", "nul", "file:x.db?mode=memory" }) |name| {
        var result = try f.call("open", Service.Open{ .name = name, .readOnly = false });
        defer result.deinit();
        try std.testing.expectEqual(.denied, result.code.?);
    }
    // A read-only open does not create the database.
    var missing = try f.call("open", Service.Open{ .name = "missing.db", .readOnly = true });
    defer missing.deinit();
    try std.testing.expectEqual(.sqlite, missing.code.?);

    // Nested names make their directories; a symlink is refused.
    const nested = try f.open("nested/deeper/app.db", false);
    _ = nested;
    var data = try std.Io.Dir.openDirAbsolute(zio.io(), f.directory, .{});
    defer data.close(zio.io());
    try data.access(zio.io(), "nested/deeper/app.db", .{});
    // Windows needs a privilege to make symlinks.
    if (@import("builtin").os.tag != .windows) try symlinks(&f, data);

    for (1..16) |_| _ = try f.open(":memory:", false);
    var over = try f.call("open", Service.Open{ .name = ":memory:", .readOnly = false });
    defer over.deinit();
    try std.testing.expectEqual(.limit, over.code.?);

    // A new document closes the old one's connections.
    try f.page.connect();
    var configuration = try f.page.next(1000);
    configuration.deinit();
    try f.idle();
    var waited: usize = 0;
    while (true) : (waited += 1) {
        var open: usize = 0;
        for (&f.plugin.connections) |*connection| {
            if (connection.phase != .free) open += 1;
        }
        if (open == 0) break;
        if (waited == 500) return error.ConnectionsLeft;
        f.page.queue.runOne(10) catch {};
    }
    _ = try f.open(":memory:", false);
    try f.idle();
}

fn symlinks(f: *Fixture, data: std.Io.Dir) !void {
    try data.symLink(zio.io(), "nested/deeper/app.db", "link.db", .{});
    try data.symLink(zio.io(), "nested", "dir", .{ .is_directory = true });
    for ([_][]const u8{ "link.db", "dir/deeper/app.db" }) |name| {
        var linked = try f.call("open", Service.Open{ .name = name, .readOnly = false });
        defer linked.deinit();
        try std.testing.expectEqual(.denied, linked.code.?);
    }
}

test "a canceled query is interrupted and the connection stays usable" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const db = try f.open(":memory:", false);
    const id = try f.send("query", Service.Statement{ .connection = db, .sql = "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT count(*) FROM c", .params = &.{} });
    zio.sleep(50 * std.time.ns_per_ms);
    try f.page.cancel(service, @intCast(id % 32), id);
    try f.idle();
    var rows = try f.query(db, "SELECT 7", &.{});
    defer rows.deinit();
    try std.testing.expectEqualStrings("7", field(rows.rows[0].array.items[0], "integer").string);
    try f.idle();
}

test "a missing library leaves the plugin unsupported" {
    var f: Fixture = .{};
    try f.init(.{ .library = "/nonexistent/libsqlite3.so" });
    defer f.deinit();
    var result = try f.call("open", Service.Open{ .name = ":memory:", .readOnly = false });
    defer result.deinit();
    try std.testing.expectEqual(.unsupported, result.code.?);
}
