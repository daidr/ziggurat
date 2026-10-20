//! Optional embedded SQLite: connections, prepared statements, typed binding,
//! row-by-row reads, transactions with savepoints and versioned migrations.
//! The module holds no App, Window, thread or global state. A `Database` is
//! confined to one thread at a time; hosts run queries on their own worker and
//! hand results back with `App.post`. Only `Database.interrupt` may be called
//! from another thread while the connection is open.
const std = @import("std");
const c = @import("c.zig");

pub const Error = error{
    OutOfMemory,
    /// The database file is locked by another connection past the busy timeout.
    Busy,
    /// A table is locked by another statement on the same connection.
    Locked,
    ReadOnly,
    Interrupted,
    Aborted,
    PermissionDenied,
    IoFailure,
    Corrupt,
    NotADatabase,
    DiskFull,
    CannotOpen,
    SchemaChanged,
    TooBig,
    Constraint,
    TypeMismatch,
    Misuse,
    Unauthorized,
    OutOfRange,
    /// Any other SQLite failure, including SQL syntax errors.
    SqlError,
    /// The path contains a NUL byte.
    InvalidPath,
    /// The SQL text holds no statement.
    EmptyStatement,
    /// `prepare` accepts one statement; use `Database.exec` for scripts.
    MultipleStatements,
    UnknownParameter,
    ParameterCount,
    ColumnCount,
    UnexpectedNull,
    IntegerOverflow,
    /// `begin` was called while a transaction is already open; use `savepoint`.
    TransactionActive,
    /// Migration versions must be positive and strictly increasing.
    InvalidMigrations,
    /// The stored schema version is newer than every known migration.
    SchemaTooNew,
    /// A blocking call ran on the thread named by `Options.ui_thread`.
    UiThreadIo,
};

/// Last failure reported on a connection. `message` is borrowed from SQLite
/// and stays valid until the next call on the same connection.
pub const Failure = struct {
    /// Extended SQLite result code, for example 2067 for a UNIQUE violation.
    code: i32,
    message: []const u8,
};

pub const ColumnType = enum { integer, float, text, blob, null };

/// A dynamically typed SQL value. Text and blob slices are borrowed.
pub const Value = union(ColumnType) {
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    null,
};

/// Binds bytes as a BLOB; plain byte slices bind as TEXT.
pub const Blob = struct { bytes: []const u8 };
/// Binds a zero-filled BLOB of `len` bytes without a caller buffer.
pub const ZeroBlob = struct { len: u64 };

pub fn blob(bytes: []const u8) Blob {
    return .{ .bytes = bytes };
}

pub const Mode = enum { read_only, read_write, read_write_create };
pub const Journal = enum { default, wal };

pub const Options = struct {
    mode: Mode = .read_write_create,
    /// How long a statement waits for another connection's lock before `Busy`.
    busy_timeout_ms: u31 = 5000,
    foreign_keys: bool = true,
    journal: Journal = .default,
    /// Refuse to open a database path whose final component is a symlink.
    no_follow: bool = false,
    /// The App owner thread. Every call that may block on disk or locks then
    /// returns `UiThreadIo` there instead of stalling the event loop. Pass
    /// null only for tools and work after `App.run` returns.
    ui_thread: ?std.Thread.Id = null,
};

pub const Behavior = enum { deferred, immediate, exclusive };

/// The linked SQLite release, for diagnostics.
pub fn version() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

fn fail(code: c_int) Error {
    return switch (code & 0xff) {
        c.NOMEM => error.OutOfMemory,
        c.BUSY => error.Busy,
        c.LOCKED => error.Locked,
        c.READONLY => error.ReadOnly,
        c.INTERRUPT => error.Interrupted,
        c.ABORT => error.Aborted,
        c.PERM => error.PermissionDenied,
        c.IOERR, c.PROTOCOL, c.NOLFS => error.IoFailure,
        c.CORRUPT => error.Corrupt,
        c.NOTADB => error.NotADatabase,
        c.FULL => error.DiskFull,
        c.CANTOPEN => error.CannotOpen,
        c.SCHEMA => error.SchemaChanged,
        c.TOOBIG => error.TooBig,
        c.CONSTRAINT => error.Constraint,
        c.MISMATCH => error.TypeMismatch,
        c.MISUSE => error.Misuse,
        c.AUTH => error.Unauthorized,
        c.RANGE => error.OutOfRange,
        else => error.SqlError,
    };
}

fn guard(ui_thread: ?std.Thread.Id) Error!void {
    if (ui_thread) |ui| if (std.Thread.getCurrentId() == ui) return error.UiThreadIo;
}

fn check(code: c_int) Error!void {
    if (code != c.OK) return fail(code);
}

fn sqlLength(sql: []const u8) Error!c_int {
    return std.math.cast(c_int, sql.len) orelse error.TooBig;
}

fn runToEnd(stmt: *c.sqlite3_stmt) Error!void {
    while (true) switch (c.sqlite3_step(stmt)) {
        c.ROW => {},
        c.DONE => return,
        else => |code| return fail(code),
    };
}

fn execScript(db: *c.sqlite3, sql: []const u8) Error!void {
    var rest = sql;
    while (rest.len > 0) {
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*]const u8 = rest.ptr;
        try check(c.sqlite3_prepare_v3(db, rest.ptr, try sqlLength(rest), 0, &stmt, &tail));
        const consumed = @intFromPtr(tail) - @intFromPtr(rest.ptr);
        rest = rest[consumed..];
        const prepared = stmt orelse {
            if (consumed == 0) return;
            continue; // whitespace or a comment
        };
        defer _ = c.sqlite3_finalize(prepared);
        try runToEnd(prepared);
    }
}

pub const Database = struct {
    handle: *c.sqlite3,
    ui_thread: ?std.Thread.Id,

    /// Opens a database file. `allocator` holds only a temporary NUL-terminated
    /// copy of `path`; SQLite's own page cache and statement memory come from
    /// the engine's system allocator and are released by `close`.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, options: Options) Error!Database {
        try guard(options.ui_thread);
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const terminated = try allocator.dupeZ(u8, path);
        defer allocator.free(terminated);
        var flags: c_int = switch (options.mode) {
            .read_only => c.OPEN_READONLY,
            .read_write => c.OPEN_READWRITE,
            .read_write_create => c.OPEN_READWRITE | c.OPEN_CREATE,
        };
        if (options.no_follow) flags |= c.OPEN_NOFOLLOW;
        return openRaw(terminated, flags, options);
    }

    /// Opens a private in-memory database that disappears on `close`.
    pub fn openMemory(options: Options) Error!Database {
        try guard(options.ui_thread);
        return openRaw(":memory:", c.OPEN_READWRITE | c.OPEN_CREATE | c.OPEN_MEMORY, options);
    }

    fn openRaw(path: [*:0]const u8, mode_flags: c_int, options: Options) Error!Database {
        var handle: ?*c.sqlite3 = null;
        // Connections are never shared concurrently, so SQLite needs no
        // per-connection mutex; each connection owns a private page cache.
        const flags = mode_flags | c.OPEN_NOMUTEX | c.OPEN_PRIVATECACHE | c.OPEN_EXRESCODE;
        const code = c.sqlite3_open_v2(path, &handle, flags, null);
        if (code != c.OK) {
            _ = c.sqlite3_close(handle);
            return fail(code);
        }
        var db: Database = .{ .handle = handle.?, .ui_thread = options.ui_thread };
        errdefer db.close();
        try check(c.sqlite3_busy_timeout(db.handle, options.busy_timeout_ms));
        if (options.foreign_keys) try db.exec("PRAGMA foreign_keys = ON");
        if (options.journal == .wal and options.mode != .read_only) try db.exec("PRAGMA journal_mode = WAL");
        return db;
    }

    /// Every statement must be finalized first. An open transaction rolls back.
    /// Closing may checkpoint a WAL file, so it also belongs on the worker.
    pub fn close(self: *Database) void {
        std.debug.assert(c.sqlite3_next_stmt(self.handle, null) == null);
        if (self.ui_thread) |ui| std.debug.assert(std.Thread.getCurrentId() != ui);
        _ = c.sqlite3_close_v2(self.handle);
        self.* = undefined;
    }

    /// Runs zero or more `;`-separated statements, discarding result rows.
    pub fn exec(self: *Database, sql: []const u8) Error!void {
        try guard(self.ui_thread);
        return execScript(self.handle, sql);
    }

    /// Compiles exactly one statement. Finalize it before closing.
    pub fn prepare(self: *Database, sql: []const u8) Error!Statement {
        return self.prepareFlags(sql, 0);
    }

    /// Like `prepare`, hinting that the statement is cached and reused for a long time.
    pub fn preparePersistent(self: *Database, sql: []const u8) Error!Statement {
        return self.prepareFlags(sql, c.PREPARE_PERSISTENT);
    }

    fn prepareFlags(self: *Database, sql: []const u8, flags: c_uint) Error!Statement {
        // Compiling reads the schema, which may wait on another connection's lock.
        try guard(self.ui_thread);
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*]const u8 = sql.ptr;
        try check(c.sqlite3_prepare_v3(self.handle, sql.ptr, try sqlLength(sql), flags, &stmt, &tail));
        const prepared = stmt orelse return error.EmptyStatement;
        errdefer _ = c.sqlite3_finalize(prepared);
        const rest = sql[@intFromPtr(tail) - @intFromPtr(sql.ptr) ..];
        if (rest.len > 0) {
            // Comments and whitespace compile to no statement.
            var extra: ?*c.sqlite3_stmt = null;
            try check(c.sqlite3_prepare_v3(self.handle, rest.ptr, try sqlLength(rest), 0, &extra, null));
            if (extra) |unexpected| {
                _ = c.sqlite3_finalize(unexpected);
                return error.MultipleStatements;
            }
        }
        return .{ .handle = prepared, .ui_thread = self.ui_thread };
    }

    pub fn lastError(self: *const Database) Failure {
        return .{ .code = c.sqlite3_extended_errcode(self.handle), .message = std.mem.span(c.sqlite3_errmsg(self.handle)) };
    }

    pub fn lastInsertRowId(self: *const Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    pub fn changes(self: *const Database) i64 {
        return c.sqlite3_changes64(self.handle);
    }

    pub fn totalChanges(self: *const Database) i64 {
        return c.sqlite3_total_changes64(self.handle);
    }

    pub fn setBusyTimeout(self: *Database, ms: u31) Error!void {
        return check(c.sqlite3_busy_timeout(self.handle, ms));
    }

    /// True while an explicit transaction is open.
    pub fn inTransaction(self: *const Database) bool {
        return c.sqlite3_get_autocommit(self.handle) == 0;
    }

    /// Makes the running and next pending statements fail with `Interrupted`.
    /// Safe from any thread while the connection is open; the caller keeps
    /// the connection from being closed concurrently.
    pub fn interrupt(self: *const Database) void {
        c.sqlite3_interrupt(self.handle);
    }

    pub fn begin(self: *Database, behavior: Behavior) Error!Transaction {
        if (self.inTransaction()) return error.TransactionActive;
        try self.exec(switch (behavior) {
            .deferred => "BEGIN DEFERRED",
            .immediate => "BEGIN IMMEDIATE",
            .exclusive => "BEGIN EXCLUSIVE",
        });
        return .{ .db = self.handle, .ui_thread = self.ui_thread, .kind = .transaction };
    }

    /// Opens a nested unit of work inside or outside a transaction. Savepoints
    /// must be committed or rolled back in reverse order of creation.
    pub fn savepoint(self: *Database) Error!Transaction {
        try self.exec("SAVEPOINT ziggurat_savepoint");
        return .{ .db = self.handle, .ui_thread = self.ui_thread, .kind = .savepoint };
    }

    pub fn userVersion(self: *Database) Error!u31 {
        var stmt = try self.prepare("PRAGMA user_version");
        defer stmt.finalize();
        const row = (try stmt.next()) orelse return error.SqlError;
        return std.math.cast(u31, try row.get(i64, 0)) orelse error.OutOfRange;
    }

    pub fn setUserVersion(self: *Database, value: u31) Error!void {
        var buffer: [48]u8 = undefined;
        try self.exec(std.fmt.bufPrint(&buffer, "PRAGMA user_version = {d}", .{value}) catch unreachable);
    }

    /// Applies pending migrations in order, each in its own IMMEDIATE
    /// transaction together with its `user_version` update, so a failure
    /// keeps every earlier migration and leaves the failed one unapplied.
    pub fn migrate(self: *Database, migrations: []const Migration) Error!MigrationReport {
        var previous: u31 = 0;
        for (migrations) |migration| {
            if (migration.version <= previous) return error.InvalidMigrations;
            previous = migration.version;
        }
        if (self.inTransaction()) return error.TransactionActive;
        const from = try self.userVersion();
        if (from > previous) return error.SchemaTooNew;
        var current = from;
        for (migrations) |migration| {
            if (migration.version <= current) continue;
            var transaction = try self.begin(.immediate);
            errdefer transaction.rollback();
            // Another connection may have migrated while this one waited.
            const stored = try self.userVersion();
            if (stored > previous) return error.SchemaTooNew;
            if (stored < migration.version) {
                try self.exec(migration.sql);
                if (migration.run) |run| try run(self);
                try self.setUserVersion(migration.version);
            }
            try transaction.commit();
            current = @max(stored, migration.version);
        }
        return .{ .from = from, .to = current };
    }
};

pub const Migration = struct {
    /// Schema version after this step; stored in `PRAGMA user_version`.
    version: u31,
    sql: []const u8 = "",
    /// Optional data step run after `sql` in the same transaction.
    run: ?*const fn (db: *Database) Error!void = null,
};

pub const MigrationReport = struct { from: u31, to: u31 };

/// A transaction or savepoint. Pair `errdefer tx.rollback()` with `try tx.commit()`.
pub const Transaction = struct {
    db: *c.sqlite3,
    ui_thread: ?std.Thread.Id,
    kind: enum { transaction, savepoint },
    active: bool = true,

    /// On failure the work stays open (for example after `Busy`) unless SQLite
    /// already rolled it back; retry `commit` or call `rollback`.
    pub fn commit(self: *Transaction) Error!void {
        std.debug.assert(self.active);
        try guard(self.ui_thread);
        switch (self.kind) {
            .transaction => {
                execScript(self.db, "COMMIT") catch |err| {
                    self.active = c.sqlite3_get_autocommit(self.db) == 0;
                    return err;
                };
            },
            .savepoint => try execScript(self.db, "RELEASE ziggurat_savepoint"),
        }
        self.active = false;
    }

    /// Idempotent and infallible, for use in `errdefer`.
    pub fn rollback(self: *Transaction) void {
        if (!self.active) return;
        if (self.ui_thread) |ui| std.debug.assert(std.Thread.getCurrentId() != ui);
        self.active = false;
        switch (self.kind) {
            .transaction => if (c.sqlite3_get_autocommit(self.db) == 0) {
                execScript(self.db, "ROLLBACK") catch {};
            },
            .savepoint => {
                execScript(self.db, "ROLLBACK TO ziggurat_savepoint") catch {};
                execScript(self.db, "RELEASE ziggurat_savepoint") catch {};
            },
        }
    }
};

/// A compiled statement owned by the thread that owns its Database.
pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    ui_thread: ?std.Thread.Id,

    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    /// Rewinds to the first row; bindings are kept.
    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.handle);
    }

    pub fn clearBindings(self: *Statement) void {
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    pub fn sql(self: *const Statement) []const u8 {
        return if (c.sqlite3_sql(self.handle)) |text| std.mem.span(text) else "";
    }

    pub fn readOnly(self: *const Statement) bool {
        return c.sqlite3_stmt_readonly(self.handle) != 0;
    }

    pub fn parameterCount(self: *const Statement) u16 {
        return @intCast(c.sqlite3_bind_parameter_count(self.handle));
    }

    /// Index of a named parameter including its prefix, such as ":name".
    pub fn parameterIndex(self: *const Statement, name: [:0]const u8) ?u16 {
        const index = c.sqlite3_bind_parameter_index(self.handle, name.ptr);
        return if (index == 0) null else @intCast(index);
    }

    pub fn columnCount(self: *const Statement) u16 {
        return @intCast(c.sqlite3_column_count(self.handle));
    }

    pub fn columnName(self: *const Statement, index: u16) []const u8 {
        return if (c.sqlite3_column_name(self.handle, index)) |name| std.mem.span(name) else "";
    }

    /// Binds one parameter (1-based). Accepts null, optionals, bool, integers,
    /// enums, floats, text slices, `Blob`, `ZeroBlob` and `Value`. Text and
    /// blob bytes are copied, so the argument need not outlive the call.
    pub fn bind(self: *Statement, index: u16, value: anytype) Error!void {
        if (index == 0) return error.OutOfRange;
        return check(try bindValue(self.handle, index, value));
    }

    pub fn bindNamed(self: *Statement, name: [:0]const u8, value: anytype) Error!void {
        return self.bind(self.parameterIndex(name) orelse return error.UnknownParameter, value);
    }

    /// Binds a tuple positionally from parameter 1; its length must match.
    pub fn bindAll(self: *Statement, args: anytype) Error!void {
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        if (fields.len != self.parameterCount()) return error.ParameterCount;
        inline for (fields, 1..) |field, index| try self.bind(index, @field(args, field.name));
    }

    /// Resets, clears old bindings and binds `args` for a fresh execution.
    pub fn rebind(self: *Statement, args: anytype) Error!void {
        self.reset();
        self.clearBindings();
        try self.bindAll(args);
    }

    /// Advances one row. Returns false once the statement is done.
    pub fn step(self: *Statement) Error!bool {
        try guard(self.ui_thread);
        return switch (c.sqlite3_step(self.handle)) {
            c.ROW => true,
            c.DONE => false,
            else => |code| fail(code),
        };
    }

    /// The next row, valid until the next `step`, `next`, `reset` or `finalize`.
    pub fn next(self: *Statement) Error!?Row {
        return if (try self.step()) .{ .handle = self.handle } else null;
    }

    /// Runs the statement to completion with `args`, then resets it for reuse.
    pub fn exec(self: *Statement, args: anytype) Error!void {
        try guard(self.ui_thread);
        try self.rebind(args);
        defer self.reset();
        try runToEnd(self.handle);
    }
};

fn bindValue(stmt: *c.sqlite3_stmt, index: c_int, value: anytype) Error!c_int {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .null => return c.sqlite3_bind_null(stmt, index),
        .optional => return if (value) |inner| bindValue(stmt, index, inner) else c.sqlite3_bind_null(stmt, index),
        .bool => return c.sqlite3_bind_int64(stmt, index, @intFromBool(value)),
        .comptime_int => return c.sqlite3_bind_int64(stmt, index, value),
        .int => return c.sqlite3_bind_int64(stmt, index, std.math.cast(i64, value) orelse return error.IntegerOverflow),
        .@"enum" => return bindValue(stmt, index, @intFromEnum(value)),
        .comptime_float, .float => return c.sqlite3_bind_double(stmt, index, @floatCast(value)),
        .pointer => {
            const text = textSlice(value);
            return c.sqlite3_bind_text64(stmt, index, text.ptr, text.len, c.TRANSIENT, c.UTF8);
        },
        .@"union" => if (T == Value) return switch (value) {
            .integer => |integer| c.sqlite3_bind_int64(stmt, index, integer),
            .float => |float| c.sqlite3_bind_double(stmt, index, float),
            .text => |text| c.sqlite3_bind_text64(stmt, index, text.ptr, text.len, c.TRANSIENT, c.UTF8),
            .blob => |bytes| c.sqlite3_bind_blob64(stmt, index, bytes.ptr, bytes.len, c.TRANSIENT),
            .null => c.sqlite3_bind_null(stmt, index),
        },
        .@"struct" => {
            // A non-null pointer keeps an empty blob distinct from NULL.
            if (T == Blob) return c.sqlite3_bind_blob64(stmt, index, value.bytes.ptr, value.bytes.len, c.TRANSIENT);
            if (T == ZeroBlob) return c.sqlite3_bind_zeroblob64(stmt, index, value.len);
        },
        else => {},
    }
    @compileError("unsupported SQLite parameter type " ++ @typeName(T));
}

fn textSlice(value: anytype) []const u8 {
    const pointer = @typeInfo(@TypeOf(value)).pointer;
    switch (pointer.size) {
        .slice => if (pointer.child == u8) return value,
        .one => switch (@typeInfo(pointer.child)) {
            .array => |array| if (array.child == u8) return value,
            else => {},
        },
        .many => if (pointer.child == u8 and pointer.sentinel() != null) return std.mem.span(value),
        .c => {},
    }
    @compileError("unsupported SQLite parameter type " ++ @typeName(@TypeOf(value)));
}

/// A borrowed view of the current row. Text and blob slices stay valid until
/// the statement steps, resets or finalizes; copy what must outlive that.
pub const Row = struct {
    handle: *c.sqlite3_stmt,

    pub fn count(self: Row) u16 {
        return @intCast(c.sqlite3_column_count(self.handle));
    }

    pub fn name(self: Row, index: u16) []const u8 {
        return if (c.sqlite3_column_name(self.handle, index)) |text| std.mem.span(text) else "";
    }

    pub fn columnType(self: Row, index: u16) ColumnType {
        return switch (c.sqlite3_column_type(self.handle, index)) {
            c.INTEGER => .integer,
            c.FLOAT => .float,
            c.TEXT => .text,
            c.BLOB => .blob,
            else => .null,
        };
    }

    fn bytes(self: Row, index: u16, kind: ColumnType) Error![]const u8 {
        const pointer = if (kind == .text) c.sqlite3_column_text(self.handle, index) else c.sqlite3_column_blob(self.handle, index);
        const length: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        if (pointer) |data| return data[0..length];
        // SQLite reports an empty blob as a null pointer; text is null only on OOM.
        return if (kind == .blob and length == 0) "" else error.OutOfMemory;
    }

    pub fn value(self: Row, index: u16) Error!Value {
        return switch (self.columnType(index)) {
            .integer => .{ .integer = c.sqlite3_column_int64(self.handle, index) },
            .float => .{ .float = c.sqlite3_column_double(self.handle, index) },
            .text => .{ .text = try self.bytes(index, .text) },
            .blob => .{ .blob = try self.bytes(index, .blob) },
            .null => .null,
        };
    }

    /// Reads a column (0-based) as `T` without silent conversion: optionals
    /// accept NULL, integers, enums and bool require INTEGER storage, floats
    /// accept INTEGER or REAL, and `[]const u8` accepts TEXT or BLOB.
    pub fn get(self: Row, comptime T: type, index: u16) Error!T {
        if (index >= self.count()) return error.OutOfRange;
        const kind = self.columnType(index);
        if (T == Value) return self.value(index);
        if (@typeInfo(T) == .optional) return if (kind == .null) null else try self.get(@typeInfo(T).optional.child, index);
        if (kind == .null) return error.UnexpectedNull;
        switch (@typeInfo(T)) {
            .bool, .int, .@"enum" => {
                if (kind != .integer) return error.TypeMismatch;
                const integer = c.sqlite3_column_int64(self.handle, index);
                return switch (@typeInfo(T)) {
                    .bool => integer != 0,
                    .int => std.math.cast(T, integer) orelse error.IntegerOverflow,
                    .@"enum" => |info| std.enums.fromInt(T, std.math.cast(info.tag_type, integer) orelse return error.TypeMismatch) orelse error.TypeMismatch,
                    else => unreachable,
                };
            },
            .float => return switch (kind) {
                .integer, .float => @floatCast(c.sqlite3_column_double(self.handle, index)),
                else => error.TypeMismatch,
            },
            .pointer => if (T == []const u8) return switch (kind) {
                .text, .blob => self.bytes(index, kind),
                else => error.TypeMismatch,
            },
            else => {},
        }
        @compileError("unsupported SQLite column type " ++ @typeName(T));
    }

    /// Reads all columns into a struct whose fields follow column order.
    pub fn decode(self: Row, comptime T: type) Error!T {
        const fields = @typeInfo(T).@"struct".fields;
        if (fields.len != self.count()) return error.ColumnCount;
        var result: T = undefined;
        inline for (fields, 0..) |field, index| @field(result, field.name) = try self.get(field.type, index);
        return result;
    }

    /// Copies a TEXT or BLOB column into memory owned by `allocator`.
    pub fn dupe(self: Row, allocator: std.mem.Allocator, index: u16) Error![]u8 {
        return allocator.dupe(u8, try self.get([]const u8, index));
    }
};

test {
    _ = @import("tests.zig");
}
