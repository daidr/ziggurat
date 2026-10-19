const std = @import("std");
const sqlite = @import("root.zig");
const c = @import("c.zig");

const testing = std.testing;

test "pinned engine is built for per-thread connections" {
    try testing.expectEqualStrings("3.54.1", sqlite.version());
    try testing.expectEqual(@as(c_int, 2), c.sqlite3_threadsafe());
}

test "bind, step and typed reads" {
    var db = try sqlite.Database.openMemory(.{});
    defer db.close();
    try db.exec(
        \\CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT NOT NULL, score REAL, body BLOB, pinned INTEGER NOT NULL);
        \\-- trailing comment
    );
    var insert = try db.prepare("INSERT INTO note (title, score, body, pinned) VALUES (?, ?, ?, ?)");
    defer insert.finalize();
    try testing.expectEqual(@as(u16, 4), insert.parameterCount());
    try insert.exec(.{ "first", 1.5, sqlite.blob(&.{ 0, 1, 2 }), true });
    try testing.expectEqual(@as(i64, 1), db.lastInsertRowId());
    try testing.expectEqual(@as(i64, 1), db.changes());
    var title_buffer = [_]u8{ 's', 'e', 'c', 'o', 'n', 'd' };
    const title: []u8 = &title_buffer;
    try insert.exec(.{ title, null, sqlite.blob(""), false });
    title_buffer[0] = 'X'; // bindings were copied
    try insert.exec(.{ "third", @as(?f64, 3), @as(?sqlite.Blob, null), 0 });
    try testing.expectError(error.ParameterCount, insert.exec(.{"too few"}));

    var query = try db.prepare("SELECT id, title, score, body, pinned FROM note ORDER BY id");
    defer query.finalize();
    try testing.expectEqual(@as(u16, 5), query.columnCount());
    try testing.expectEqualStrings("title", query.columnName(1));
    try testing.expect(query.readOnly());

    const first = (try query.next()).?;
    try testing.expectEqual(@as(i64, 1), try first.get(i64, 0));
    try testing.expectEqualStrings("first", try first.get([]const u8, 1));
    try testing.expectEqual(@as(f64, 1.5), try first.get(f64, 2));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, try first.get([]const u8, 3));
    try testing.expect(try first.get(bool, 4));
    try testing.expectEqual(sqlite.ColumnType.blob, first.columnType(3));
    try testing.expectError(error.TypeMismatch, first.get(i64, 1));
    try testing.expectError(error.OutOfRange, first.get(i64, 9));

    const second = (try query.next()).?;
    try testing.expectEqualStrings("second", try second.get([]const u8, 1));
    try testing.expectEqual(@as(?f64, null), try second.get(?f64, 2));
    try testing.expectError(error.UnexpectedNull, second.get(f64, 2));
    try testing.expectEqualStrings("", try second.get([]const u8, 3));
    try testing.expectEqual(sqlite.ColumnType.blob, second.columnType(3));

    const Note = struct { id: u8, title: []const u8, score: ?f32, body: ?[]const u8, pinned: bool };
    const third = try (try query.next()).?.decode(Note);
    try testing.expectEqual(@as(u8, 3), third.id);
    try testing.expectEqualStrings("third", third.title);
    try testing.expectEqual(@as(?f32, 3), third.score);
    try testing.expectEqual(@as(?[]const u8, null), third.body);
    try testing.expect(!third.pinned);
    try testing.expectEqual(@as(?sqlite.Row, null), try query.next());

    query.reset();
    const again = (try query.next()).?;
    const copy = try again.dupe(testing.allocator, 1);
    defer testing.allocator.free(copy);
    query.reset();
    try testing.expectEqualStrings("first", copy);
    try testing.expectError(error.ColumnCount, (try query.next()).?.decode(struct { id: i64 }));
}

test "named parameters, values, enums and integer bounds" {
    var db = try sqlite.Database.openMemory(.{});
    defer db.close();
    try db.exec("CREATE TABLE item (kind INTEGER, label TEXT, payload)");
    const Kind = enum(u8) { file = 1, folder = 2 };
    var insert = try db.prepare("INSERT INTO item VALUES (:kind, :label, :payload)");
    defer insert.finalize();
    try insert.bindNamed(":kind", Kind.folder);
    try insert.bindNamed(":label", @as([:0]const u8, "docs"));
    try insert.bindNamed(":payload", sqlite.Value{ .integer = std.math.maxInt(i64) });
    try testing.expectError(error.UnknownParameter, insert.bindNamed(":missing", 1));
    try testing.expectError(error.IntegerOverflow, insert.bind(1, @as(u64, std.math.maxInt(u64))));
    try testing.expectError(error.OutOfRange, insert.bind(0, 1));
    try testing.expect(!try insert.step());
    insert.reset();
    insert.clearBindings();
    try insert.bind(1, 7);
    try insert.bind(3, sqlite.ZeroBlob{ .len = 4 });
    try testing.expect(!try insert.step());

    var query = try db.prepare("SELECT kind, label, payload FROM item ORDER BY rowid");
    defer query.finalize();
    const row = (try query.next()).?;
    try testing.expectEqual(Kind.folder, try row.get(Kind, 0));
    try testing.expectEqualStrings("docs", (try row.get(sqlite.Value, 1)).text);
    try testing.expectError(error.IntegerOverflow, row.get(i32, 2));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), (try row.get(sqlite.Value, 2)).integer);
    const cleared = (try query.next()).?;
    try testing.expectError(error.TypeMismatch, cleared.get(Kind, 0));
    try testing.expectEqual(@as(?[]const u8, null), try cleared.get(?[]const u8, 1));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, (try cleared.get(sqlite.Value, 2)).blob);
}

test "statement errors are mapped and diagnosable" {
    var db = try sqlite.Database.openMemory(.{});
    defer db.close();
    try db.exec("CREATE TABLE tag (name TEXT UNIQUE NOT NULL)");
    try testing.expectError(error.EmptyStatement, db.prepare("  -- nothing\n"));
    try testing.expectError(error.MultipleStatements, db.prepare("SELECT 1; SELECT 2"));
    var single = try db.prepare("SELECT 1; -- note");
    single.finalize();
    try testing.expectError(error.SqlError, db.prepare("SELEC 1"));
    try testing.expect(std.mem.indexOf(u8, db.lastError().message, "syntax error") != null);

    var insert = try db.prepare("INSERT INTO tag VALUES (?)");
    defer insert.finalize();
    try insert.exec(.{"a"});
    try testing.expectError(error.Constraint, insert.exec(.{"a"}));
    try testing.expectEqual(@as(i32, 2067), db.lastError().code); // SQLITE_CONSTRAINT_UNIQUE
    try testing.expectError(error.Constraint, insert.exec(.{null}));
    try insert.exec(.{"b"}); // reusable after failures
    try testing.expectError(error.SqlError, db.exec("INSERT INTO tag VALUES ('c'); SELECT * FROM missing"));
    var count = try db.prepare("SELECT count(*) FROM tag");
    defer count.finalize();
    try testing.expectEqual(@as(i64, 3), try (try count.next()).?.get(i64, 0));
}

test "foreign keys are enforced by default" {
    var db = try sqlite.Database.openMemory(.{});
    defer db.close();
    try db.exec("CREATE TABLE parent (id INTEGER PRIMARY KEY); CREATE TABLE child (parent INTEGER REFERENCES parent(id))");
    try testing.expectError(error.Constraint, db.exec("INSERT INTO child VALUES (1)"));
    var loose = try sqlite.Database.openMemory(.{ .foreign_keys = false });
    defer loose.close();
    try loose.exec("CREATE TABLE parent (id INTEGER PRIMARY KEY); CREATE TABLE child (parent INTEGER REFERENCES parent(id))");
    try loose.exec("INSERT INTO child VALUES (1)");
}

fn countRows(db: *sqlite.Database) !i64 {
    var stmt = try db.prepare("SELECT count(*) FROM entry");
    defer stmt.finalize();
    return (try stmt.next()).?.get(i64, 0);
}

test "transactions and nested savepoints" {
    var db = try sqlite.Database.openMemory(.{});
    defer db.close();
    try db.exec("CREATE TABLE entry (value INTEGER)");

    var rolled = try db.begin(.deferred);
    try db.exec("INSERT INTO entry VALUES (1)");
    try testing.expect(db.inTransaction());
    try testing.expectError(error.TransactionActive, db.begin(.immediate));
    rolled.rollback();
    rolled.rollback();
    try testing.expect(!db.inTransaction());
    try testing.expectEqual(@as(i64, 0), try countRows(&db));

    var outer = try db.begin(.immediate);
    try db.exec("INSERT INTO entry VALUES (1)");
    var kept = try db.savepoint();
    try db.exec("INSERT INTO entry VALUES (2)");
    var dropped = try db.savepoint();
    try db.exec("INSERT INTO entry VALUES (3)");
    dropped.rollback();
    try kept.commit();
    try testing.expect(db.inTransaction());
    try outer.commit();
    outer.rollback(); // no-op after commit
    try testing.expectEqual(@as(i64, 2), try countRows(&db));

    var standalone = try db.savepoint();
    try db.exec("INSERT INTO entry VALUES (4)");
    try testing.expect(db.inTransaction());
    try standalone.commit();
    try testing.expect(!db.inTransaction());

    var exclusive = try db.begin(.exclusive);
    errdefer exclusive.rollback();
    try db.exec("DELETE FROM entry");
    try exclusive.commit();
    try testing.expectEqual(@as(i64, 0), try countRows(&db));
}

var data_step_calls: usize = 0;

fn seedDefaults(db: *sqlite.Database) sqlite.Error!void {
    data_step_calls += 1;
    try db.exec("INSERT INTO setting VALUES ('theme', 'light')");
}

test "migrations apply in order, once, and stop at the failed step" {
    var db = try sqlite.Database.openMemory(.{});
    defer db.close();
    data_step_calls = 0;
    const v1 = [_]sqlite.Migration{
        .{ .version = 1, .sql = "CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT)", .run = seedDefaults },
    };
    try testing.expectEqual(sqlite.MigrationReport{ .from = 0, .to = 1 }, try db.migrate(&v1));
    try testing.expectEqual(sqlite.MigrationReport{ .from = 1, .to = 1 }, try db.migrate(&v1));
    try testing.expectEqual(@as(usize, 1), data_step_calls);

    const broken = v1 ++ [_]sqlite.Migration{
        .{ .version = 2, .sql = "ALTER TABLE setting ADD COLUMN updated INTEGER" },
        .{ .version = 5, .sql = "CREATE TABLE extra (id INTEGER); INSERT INTO missing VALUES (1)" },
    };
    try testing.expectError(error.SqlError, db.migrate(&broken));
    try testing.expectEqual(@as(u31, 2), try db.userVersion());
    try testing.expect(!db.inTransaction());
    try testing.expectError(error.SqlError, db.exec("SELECT * FROM extra"));

    const fixed = v1 ++ [_]sqlite.Migration{
        .{ .version = 2, .sql = "ALTER TABLE setting ADD COLUMN updated INTEGER" },
        .{ .version = 5, .sql = "CREATE TABLE extra (id INTEGER)" },
    };
    try testing.expectEqual(sqlite.MigrationReport{ .from = 2, .to = 5 }, try db.migrate(&fixed));
    try testing.expectError(error.SchemaTooNew, db.migrate(&v1));
    try testing.expectError(error.InvalidMigrations, db.migrate(&.{ .{ .version = 2 }, .{ .version = 2 } }));
    try testing.expectError(error.InvalidMigrations, db.migrate(&.{.{ .version = 0 }}));

    var transaction = try db.begin(.deferred);
    defer transaction.rollback();
    try testing.expectError(error.TransactionActive, db.migrate(&fixed));
}

test "file databases use the caller allocator, persist and honor read-only mode" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(directory);
    const path = try std.fs.path.join(testing.allocator, &.{ directory, "app.db" });
    defer testing.allocator.free(path);

    try testing.expectError(error.CannotOpen, sqlite.Database.open(testing.allocator, path, .{ .mode = .read_write }));
    try testing.expectError(error.InvalidPath, sqlite.Database.open(testing.allocator, "bad\x00path", .{}));
    try testing.expectError(error.OutOfMemory, sqlite.Database.open(testing.failing_allocator, path, .{}));
    {
        var db = try sqlite.Database.open(testing.allocator, path, .{ .journal = .wal });
        defer db.close();
        var mode = try db.prepare("PRAGMA journal_mode");
        defer mode.finalize();
        try testing.expectEqualStrings("wal", try (try mode.next()).?.get([]const u8, 0));
        // An unfinished read keeps its snapshot, so COMMIT would report Busy.
        mode.reset();
        _ = try db.migrate(&.{.{ .version = 1, .sql = "CREATE TABLE entry (value INTEGER); INSERT INTO entry VALUES (42)" }});
    }
    var reader = try sqlite.Database.open(testing.allocator, path, .{ .mode = .read_only });
    defer reader.close();
    try testing.expectEqual(@as(u31, 1), try reader.userVersion());
    try testing.expectEqual(@as(i64, 1), try countRows(&reader));
    try testing.expectError(error.ReadOnly, reader.exec("INSERT INTO entry VALUES (1)"));
}

test "a second connection waits on the lock and then reports Busy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(directory);
    const path = try std.fs.path.join(testing.allocator, &.{ directory, "lock.db" });
    defer testing.allocator.free(path);

    var writer = try sqlite.Database.open(testing.allocator, path, .{});
    defer writer.close();
    try writer.exec("CREATE TABLE entry (value INTEGER)");
    var other = try sqlite.Database.open(testing.allocator, path, .{ .busy_timeout_ms = 20 });
    defer other.close();
    var hold = try writer.begin(.exclusive);
    defer hold.rollback();
    try testing.expectError(error.Busy, other.exec("INSERT INTO entry VALUES (1)"));
}

const Handoff = struct {
    mutex: std.Thread.Mutex = .{},
    done: std.Thread.Condition = .{},
    finished: bool = false,
    started: std.atomic.Value(bool) = .init(false),
    result: anyerror!i64 = 0,

    fn publish(self: *Handoff, result: anyerror!i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.result = result;
        self.finished = true;
        self.done.signal();
    }

    fn wait(self: *Handoff) anyerror!i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.finished) self.done.wait(&self.mutex);
        return self.result;
    }
};

fn sumOnWorker(db: *sqlite.Database, handoff: *Handoff) void {
    handoff.publish(blk: {
        db.exec("INSERT INTO entry VALUES (1); DELETE FROM entry") catch |err| break :blk err;
        var stmt = db.prepare("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1000) SELECT sum(x) FROM n") catch |err| break :blk err;
        defer stmt.finalize();
        const row = (stmt.next() catch |err| break :blk err) orelse break :blk error.NoRow;
        break :blk row.get(i64, 0);
    });
}

fn spinOnWorker(db: *sqlite.Database, handoff: *Handoff) void {
    handoff.publish(blk: {
        var stmt = db.prepare("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT count(*) FROM n") catch |err| break :blk err;
        defer stmt.finalize();
        handoff.started.store(true, .release);
        _ = stmt.next() catch |err| break :blk err;
        break :blk error.NotInterrupted;
    });
}

fn openOnWorker(ui_thread: std.Thread.Id, out: *sqlite.Error!sqlite.Database) void {
    out.* = sqlite.Database.openMemory(.{ .ui_thread = ui_thread });
}

fn closeOnWorker(db: *sqlite.Database) void {
    db.close();
}

test "connections bound to a UI thread refuse blocking calls there" {
    const ui = std.Thread.getCurrentId();
    try testing.expectError(error.UiThreadIo, sqlite.Database.openMemory(.{ .ui_thread = ui }));
    try testing.expectError(error.UiThreadIo, sqlite.Database.open(testing.allocator, "unused.db", .{ .ui_thread = ui }));
    var opened: sqlite.Error!sqlite.Database = error.Misuse;
    const opener = try std.Thread.spawn(.{}, openOnWorker, .{ ui, &opened });
    opener.join();
    var db = try opened;
    try testing.expectError(error.UiThreadIo, db.exec("CREATE TABLE entry (value INTEGER)"));
    try testing.expectError(error.UiThreadIo, db.prepare("SELECT 1"));
    try testing.expectError(error.UiThreadIo, db.begin(.deferred));
    db.interrupt(); // nonblocking and allowed from any thread
    const closer = try std.Thread.spawn(.{}, closeOnWorker, .{&db});
    closer.join();
}

test "a worker owns the connection and another thread can interrupt it" {
    var db = try sqlite.Database.openMemory(.{});
    defer db.close();
    try db.exec("CREATE TABLE entry (value INTEGER)");

    // Ownership moves to the worker for the whole job, then back on join;
    // in an App the worker would hand its result to App.post instead.
    var sum: Handoff = .{};
    const worker = try std.Thread.spawn(.{}, sumOnWorker, .{ &db, &sum });
    const total = sum.wait();
    worker.join();
    try testing.expectEqual(@as(i64, 500500), try total);

    var spin: Handoff = .{};
    const spinner = try std.Thread.spawn(.{}, spinOnWorker, .{ &db, &spin });
    while (!spin.started.load(.acquire)) std.Thread.yield() catch {};
    while (true) {
        db.interrupt();
        spin.mutex.lock();
        const finished = spin.finished;
        spin.mutex.unlock();
        if (finished) break;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    spinner.join();
    try testing.expectError(error.Interrupted, spin.result);
    // The connection stays usable after an interrupted statement.
    try testing.expectEqual(@as(i64, 0), try countRows(&db));
}
