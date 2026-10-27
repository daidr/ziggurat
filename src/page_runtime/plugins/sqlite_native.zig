//! SQLite, loaded when the plugin starts from the system's library or one
//! the app names, so that building needs no SQLite headers or sources. A
//! connection is used by one worker at a time; `interrupt` and `cancel` may
//! come from the main thread.
const std = @import("std");
const builtin = @import("builtin");

const Db = opaque {};
const Stmt = opaque {};
const Busy = *const fn (?*anyopaque, c_int) callconv(.c) c_int;
const Authorizer = *const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int;
// Byte-aligned so the SQLITE_TRANSIENT sentinel (-1) is a valid value on
// targets that require aligned function addresses.
const Destructor = ?*align(1) const fn (?*anyopaque) callconv(.c) void;

pub const ok = 0;
const row = 100;
const done = 101;
const deny = 1;
const open_readonly = 0x1;
const open_readwrite = 0x2;
const open_create = 0x4;
const open_nofollow = 0x01000000;
const open_fullmutex = 0x10000;
const open_memory = 0x80;
const open_uri = 0x40;
/// SQLITE_TRANSIENT: SQLite copies what is bound.
const transient: Destructor = @ptrFromInt(std.math.maxInt(usize));

/// Library names tried, in order, when the app names none.
pub const default_names: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ "winsqlite3.dll", "sqlite3.dll" },
    .macos => &.{"libsqlite3.dylib"},
    else => &.{ "libsqlite3.so.0", "libsqlite3.so" },
};

pub const Library = struct {
    lib: std.DynLib,
    open_v2: *const fn ([*:0]const u8, *?*Db, c_int, ?[*:0]const u8) callconv(.c) c_int,
    close_v2: *const fn (?*Db) callconv(.c) c_int,
    extended_result_codes: *const fn (*Db, c_int) callconv(.c) c_int,
    extended_errcode: *const fn (*Db) callconv(.c) c_int,
    errmsg: *const fn (*Db) callconv(.c) [*:0]const u8,
    errstr: *const fn (c_int) callconv(.c) [*:0]const u8,
    prepare_v2: *const fn (*Db, [*]const u8, c_int, *?*Stmt, *?[*]const u8) callconv(.c) c_int,
    finalize: *const fn (?*Stmt) callconv(.c) c_int,
    bind_parameter_count: *const fn (*Stmt) callconv(.c) c_int,
    bind_null: *const fn (*Stmt, c_int) callconv(.c) c_int,
    bind_int64: *const fn (*Stmt, c_int, i64) callconv(.c) c_int,
    bind_double: *const fn (*Stmt, c_int, f64) callconv(.c) c_int,
    bind_text: *const fn (*Stmt, c_int, [*]const u8, c_int, Destructor) callconv(.c) c_int,
    bind_blob: *const fn (*Stmt, c_int, ?*const anyopaque, c_int, Destructor) callconv(.c) c_int,
    column_count: *const fn (*Stmt) callconv(.c) c_int,
    column_name: *const fn (*Stmt, c_int) callconv(.c) ?[*:0]const u8,
    column_type: *const fn (*Stmt, c_int) callconv(.c) c_int,
    column_int64: *const fn (*Stmt, c_int) callconv(.c) i64,
    column_double: *const fn (*Stmt, c_int) callconv(.c) f64,
    column_text: *const fn (*Stmt, c_int) callconv(.c) ?[*]const u8,
    column_blob: *const fn (*Stmt, c_int) callconv(.c) ?[*]const u8,
    column_bytes: *const fn (*Stmt, c_int) callconv(.c) c_int,
    step: *const fn (*Stmt) callconv(.c) c_int,
    changes: *const fn (*Db) callconv(.c) c_int,
    total_changes: *const fn (*Db) callconv(.c) c_int,
    last_insert_rowid: *const fn (*Db) callconv(.c) i64,
    busy_handler: *const fn (*Db, ?Busy, ?*anyopaque) callconv(.c) c_int,
    set_authorizer: *const fn (*Db, ?Authorizer, ?*anyopaque) callconv(.c) c_int,
    interrupt: *const fn (*Db) callconv(.c) void,
    get_autocommit: *const fn (*Db) callconv(.c) c_int,
    libversion_number: *const fn () callconv(.c) c_int,

    /// Loads `path`, or the first of `default_names` that loads.
    pub fn load(path: ?[]const u8) !Library {
        if (path) |name| return bind(try std.DynLib.open(name));
        for (default_names) |name| {
            const lib = std.DynLib.open(name) catch continue;
            return bind(lib);
        }
        return error.LibraryNotFound;
    }

    fn bind(opened: std.DynLib) !Library {
        var lib = opened;
        errdefer lib.close();
        var self: Library = undefined;
        self.lib = lib;
        inline for (@typeInfo(Library).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "lib")) continue;
            @field(self, field.name) = lib.lookup(field.type, "sqlite3_" ++ field.name) orelse return error.MissingSymbol;
        }
        // prepare_v2 needs 3.7; get_autocommit, close_v2 3.7.14.
        if (self.libversion_number() < 3_007_014) return error.LibraryTooOld;
        return self;
    }

    pub fn unload(self: *Library) void {
        self.lib.close();
    }
};

pub const Failure = struct {
    code: c_int = 0,
    message: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Failure) []const u8 {
        return self.message[0..self.len];
    }

    fn set(self: *Failure, code: c_int, comptime format: []const u8, args: anytype) void {
        self.code = code;
        self.len = (std.fmt.bufPrint(&self.message, format, args) catch self.message[0..self.message.len]).len;
    }
};

pub const Error = error{ Sqlite, Invalid, Denied, OutOfMemory, Canceled };

/// One connection. Stays at its address while open: SQLite's callbacks
/// point at it.
pub const Connection = struct {
    lib: *const Library,
    db: ?*Db = null,
    timeout_ms: u32,
    /// Lets the plugin's own BEGIN, COMMIT and ROLLBACK through.
    control: bool = false,
    canceled: std.atomic.Value(bool) = .init(false),
    failure: Failure = .{},

    /// `path` is NUL-terminated; ":memory:" opens a private database.
    pub fn open(self: *Connection, path: [:0]const u8, read_only: bool) Error!void {
        var flags: c_int = open_fullmutex | open_nofollow;
        flags |= if (read_only) open_readonly else open_readwrite | open_create;
        var db: ?*Db = null;
        const rc = self.lib.open_v2(path.ptr, &db, flags, null);
        if (rc != ok) {
            if (db) |handle| {
                self.failure.set(self.lib.extended_errcode(handle), "{s}", .{std.mem.span(self.lib.errmsg(handle))});
            } else self.failure.set(rc, "{s}", .{std.mem.span(self.lib.errstr(rc))});
            _ = self.lib.close_v2(db);
            return error.Sqlite;
        }
        self.db = db;
        _ = self.lib.extended_result_codes(db.?, 1);
        _ = self.lib.busy_handler(db.?, busy, self);
        _ = self.lib.set_authorizer(db.?, authorize, self);
        self.exec("PRAGMA foreign_keys = ON") catch |err| {
            self.close();
            return err;
        };
    }

    pub fn close(self: *Connection) void {
        _ = self.lib.close_v2(self.db);
        self.db = null;
    }

    /// Any thread: stops what runs now and what waits for a lock.
    pub fn interrupt(self: *Connection) void {
        self.canceled.store(true, .release);
        if (self.db) |db| self.lib.interrupt(db);
    }

    /// Before each operation.
    pub fn begin(self: *Connection) void {
        self.canceled.store(false, .release);
    }

    pub fn isCanceled(self: *Connection) bool {
        return self.canceled.load(.acquire);
    }

    fn sqliteError(self: *Connection, rc: c_int) Error {
        if (self.isCanceled()) return error.Canceled;
        self.failure.set(self.lib.extended_errcode(self.db.?), "{s} (code {d})", .{ std.mem.span(self.lib.errmsg(self.db.?)), self.lib.extended_errcode(self.db.?) });
        if (rc == ok) self.failure.code = 1;
        return error.Sqlite;
    }

    fn invalid(self: *Connection, comptime format: []const u8, args: anytype) Error {
        self.failure.set(0, format, args);
        return error.Invalid;
    }

    /// Prepares exactly one statement; a trailing semicolon and comments may
    /// follow it.
    pub fn prepare(self: *Connection, sql: []const u8) Error!Statement {
        if (sql.len > std.math.maxInt(c_int) - 1 or std.mem.indexOfScalar(u8, sql, 0) != null or !std.unicode.utf8ValidateSlice(sql)) {
            return self.invalid("SQL must be UTF-8 without NUL", .{});
        }
        if (vacuumInto(sql)) {
            self.failure.set(0, "VACUUM INTO is not allowed", .{});
            return error.Denied;
        }
        var stmt: ?*Stmt = null;
        var tail: ?[*]const u8 = null;
        const rc = self.lib.prepare_v2(self.db.?, sql.ptr, @intCast(sql.len), &stmt, &tail);
        if (rc != ok) {
            _ = self.lib.finalize(stmt);
            if (self.lib.extended_errcode(self.db.?) & 0xff == 23) {
                self.failure.set(23, "{s}", .{std.mem.span(self.lib.errmsg(self.db.?))});
                return error.Denied;
            }
            return self.sqliteError(rc);
        }
        const first = stmt orelse return self.invalid("SQL contains no statement", .{});
        var offset = @intFromPtr(tail.?) - @intFromPtr(sql.ptr);
        while (offset < sql.len) {
            var extra: ?*Stmt = null;
            const more = self.lib.prepare_v2(self.db.?, sql.ptr + offset, @intCast(sql.len - offset), &extra, &tail);
            if (more != ok or extra != null) {
                _ = self.lib.finalize(extra);
                _ = self.lib.finalize(first);
                return self.invalid("expected exactly one statement", .{});
            }
            const next = @intFromPtr(tail.?) - @intFromPtr(sql.ptr);
            if (next <= offset) break;
            offset = next;
        }
        return .{ .connection = self, .stmt = first };
    }

    /// Runs one of the plugin's transaction statements.
    pub fn exec(self: *Connection, sql: []const u8) Error!void {
        self.control = true;
        defer self.control = false;
        var statement = try self.prepare(sql);
        defer statement.deinit();
        if (try statement.step()) return self.sqliteError(ok);
    }

    pub fn inTransaction(self: *Connection) bool {
        return self.lib.get_autocommit(self.db.?) == 0;
    }

    pub fn lastInsertId(self: *Connection) i64 {
        return self.lib.last_insert_rowid(self.db.?);
    }

    fn busy(context: ?*anyopaque, count: c_int) callconv(.c) c_int {
        const self: *Connection = @ptrCast(@alignCast(context.?));
        if (self.isCanceled()) return 0;
        const waited: u64 = @as(u64, @intCast(count)) * 5;
        if (waited >= self.timeout_ms) return 0;
        std.Thread.sleep(5 * std.time.ns_per_ms);
        return 1;
    }

    /// Transactions are the plugin's to run, and SQL opens no other file.
    fn authorize(context: ?*anyopaque, action: c_int, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8) callconv(.c) c_int {
        const self: *Connection = @ptrCast(@alignCast(context.?));
        return switch (action) {
            // SQLITE_TRANSACTION, SQLITE_SAVEPOINT
            22, 32 => if (self.control) ok else deny,
            // SQLITE_ATTACH, SQLITE_DETACH
            24, 25 => deny,
            else => ok,
        };
    }
};

pub const Statement = struct {
    connection: *Connection,
    stmt: *Stmt,

    pub fn deinit(self: *Statement) void {
        _ = self.connection.lib.finalize(self.stmt);
    }

    pub fn parameterCount(self: *Statement) usize {
        return @intCast(self.connection.lib.bind_parameter_count(self.stmt));
    }

    pub const Bound = union(enum) {
        null,
        integer: i64,
        real: f64,
        text: []const u8,
        blob: []const u8,
    };

    pub fn bind(self: *Statement, index: usize, value: Bound) Error!void {
        const lib = self.connection.lib;
        const at: c_int = @intCast(index);
        const rc = switch (value) {
            .null => lib.bind_null(self.stmt, at),
            .integer => |n| lib.bind_int64(self.stmt, at, n),
            .real => |f| lib.bind_double(self.stmt, at, f),
            .text => |text| lib.bind_text(self.stmt, at, text.ptr, @intCast(text.len), transient),
            // An empty BLOB is not NULL: it needs a pointer.
            .blob => |bytes| lib.bind_blob(self.stmt, at, if (bytes.len == 0) @ptrCast("") else bytes.ptr, @intCast(bytes.len), transient),
        };
        if (rc != ok) return self.connection.sqliteError(rc);
    }

    /// True while there is a row.
    pub fn step(self: *Statement) Error!bool {
        const rc = self.connection.lib.step(self.stmt);
        if (rc == row) return true;
        if (rc == done) return false;
        return self.connection.sqliteError(rc);
    }

    pub fn columnCount(self: *Statement) usize {
        return @intCast(self.connection.lib.column_count(self.stmt));
    }

    pub fn columnName(self: *Statement, index: usize) []const u8 {
        const name = self.connection.lib.column_name(self.stmt, @intCast(index)) orelse return "";
        return std.mem.span(name);
    }

    pub const Cell = union(enum) {
        null,
        integer: i64,
        real: f64,
        /// Borrowed until the next step.
        text: []const u8,
        blob: []const u8,
    };

    pub fn column(self: *Statement, index: usize) Cell {
        const lib = self.connection.lib;
        const at: c_int = @intCast(index);
        return switch (lib.column_type(self.stmt, at)) {
            1 => .{ .integer = lib.column_int64(self.stmt, at) },
            2 => .{ .real = lib.column_double(self.stmt, at) },
            3 => text: {
                const pointer = lib.column_text(self.stmt, at);
                const len: usize = @intCast(lib.column_bytes(self.stmt, at));
                break :text .{ .text = if (pointer) |p| p[0..len] else "" };
            },
            4 => blob: {
                const pointer = lib.column_blob(self.stmt, at);
                const len: usize = @intCast(lib.column_bytes(self.stmt, at));
                break :blob .{ .blob = if (pointer) |p| p[0..len] else "" };
            },
            else => .null,
        };
    }

    /// Steps to the end and says what it changed.
    pub fn changes(self: *Statement, before: c_int) i64 {
        const lib = self.connection.lib;
        if (lib.total_changes(self.connection.db.?) == before) return 0;
        return lib.changes(self.connection.db.?);
    }

    pub fn totalChanges(self: *Statement) c_int {
        return self.connection.lib.total_changes(self.connection.db.?);
    }
};

/// Whether `sql` is a VACUUM INTO, which would write another file.
pub fn vacuumInto(sql: []const u8) bool {
    var words: Words = .{ .sql = sql };
    const first = words.next() orelse return false;
    if (!std.ascii.eqlIgnoreCase(first, "vacuum")) return false;
    while (words.next()) |word| if (std.ascii.eqlIgnoreCase(word, "into")) return true;
    return false;
}

/// The bare words of SQL, skipping comments, strings and quoted names.
const Words = struct {
    sql: []const u8,
    at: usize = 0,

    fn next(self: *Words) ?[]const u8 {
        const s = self.sql;
        while (self.at < s.len) {
            const c = s[self.at];
            if (std.ascii.isWhitespace(c) or c == ';' or c == ',' or c == '(' or c == ')' or c == '.') {
                self.at += 1;
            } else if (c == '-' and self.at + 1 < s.len and s[self.at + 1] == '-') {
                while (self.at < s.len and s[self.at] != '\n') self.at += 1;
            } else if (c == '/' and self.at + 1 < s.len and s[self.at + 1] == '*') {
                self.at += 2;
                while (self.at + 1 < s.len and !(s[self.at] == '*' and s[self.at + 1] == '/')) self.at += 1;
                self.at = @min(s.len, self.at + 2);
            } else if (c == '\'' or c == '"' or c == '`' or c == '[') {
                const close: u8 = if (c == '[') ']' else c;
                self.at += 1;
                while (self.at < s.len and s[self.at] != close) self.at += 1;
                self.at = @min(s.len, self.at + 1);
            } else if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = self.at;
                while (self.at < s.len and (std.ascii.isAlphanumeric(s[self.at]) or s[self.at] == '_' or s[self.at] >= 0x80)) self.at += 1;
                return s[start..self.at];
            } else {
                self.at += 1;
            }
        }
        return null;
    }
};

test "VACUUM INTO is told apart from VACUUM and from strings" {
    try std.testing.expect(vacuumInto("VACUUM INTO 'copy.db'"));
    try std.testing.expect(vacuumInto("  /* x */ vacuum main into '/tmp/a'"));
    try std.testing.expect(!vacuumInto("VACUUM"));
    try std.testing.expect(!vacuumInto("SELECT 'VACUUM INTO'"));
    try std.testing.expect(!vacuumInto("-- VACUUM INTO\nSELECT 1"));
    try std.testing.expect(!vacuumInto("INSERT INTO t VALUES (1)"));
}
