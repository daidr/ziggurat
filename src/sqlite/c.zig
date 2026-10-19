//! Minimal hand-written declarations of the pinned SQLite C API. Only the
//! entry points the Zig wrapper uses are declared; no header translation runs.

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const OK = 0;
pub const ERROR = 1;
pub const INTERNAL = 2;
pub const PERM = 3;
pub const ABORT = 4;
pub const BUSY = 5;
pub const LOCKED = 6;
pub const NOMEM = 7;
pub const READONLY = 8;
pub const INTERRUPT = 9;
pub const IOERR = 10;
pub const CORRUPT = 11;
pub const NOTFOUND = 12;
pub const FULL = 13;
pub const CANTOPEN = 14;
pub const PROTOCOL = 15;
pub const SCHEMA = 17;
pub const TOOBIG = 18;
pub const CONSTRAINT = 19;
pub const MISMATCH = 20;
pub const MISUSE = 21;
pub const NOLFS = 22;
pub const AUTH = 23;
pub const RANGE = 25;
pub const NOTADB = 26;
pub const ROW = 100;
pub const DONE = 101;

pub const OPEN_READONLY = 0x00000001;
pub const OPEN_READWRITE = 0x00000002;
pub const OPEN_CREATE = 0x00000004;
pub const OPEN_MEMORY = 0x00000080;
pub const OPEN_NOMUTEX = 0x00008000;
pub const OPEN_PRIVATECACHE = 0x00040000;
pub const OPEN_NOFOLLOW = 0x01000000;
pub const OPEN_EXRESCODE = 0x02000000;

pub const PREPARE_PERSISTENT = 0x01;

pub const INTEGER = 1;
pub const FLOAT = 2;
pub const TEXT = 3;
pub const BLOB = 4;
pub const NULL = 5;

pub const UTF8 = 1;
/// Destructor sentinels, declared as integers so no misaligned function
/// pointer value is formed in Zig: SQLite copies TRANSIENT bindings itself.
pub const STATIC: isize = 0;
pub const TRANSIENT: isize = -1;

pub extern fn sqlite3_libversion() [*:0]const u8;
pub extern fn sqlite3_threadsafe() c_int;
pub extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern fn sqlite3_close_v2(db: ?*sqlite3) c_int;
pub extern fn sqlite3_extended_errcode(db: *sqlite3) c_int;
pub extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
pub extern fn sqlite3_errstr(code: c_int) [*:0]const u8;
pub extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
pub extern fn sqlite3_interrupt(db: *sqlite3) void;
pub extern fn sqlite3_is_interrupted(db: *sqlite3) c_int;
pub extern fn sqlite3_get_autocommit(db: *sqlite3) c_int;
pub extern fn sqlite3_last_insert_rowid(db: *sqlite3) i64;
pub extern fn sqlite3_changes64(db: *sqlite3) i64;
pub extern fn sqlite3_total_changes64(db: *sqlite3) i64;
pub extern fn sqlite3_next_stmt(db: *sqlite3, stmt: ?*sqlite3_stmt) ?*sqlite3_stmt;

pub extern fn sqlite3_prepare_v3(db: *sqlite3, sql: [*]const u8, bytes: c_int, flags: c_uint, stmt: *?*sqlite3_stmt, tail: ?*[*]const u8) c_int;
pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_clear_bindings(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_sql(stmt: *sqlite3_stmt) ?[*:0]const u8;
pub extern fn sqlite3_stmt_readonly(stmt: *sqlite3_stmt) c_int;

pub extern fn sqlite3_bind_parameter_count(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_bind_parameter_index(stmt: *sqlite3_stmt, name: [*:0]const u8) c_int;
pub extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, index: c_int) c_int;
pub extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, index: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_double(stmt: *sqlite3_stmt, index: c_int, value: f64) c_int;
pub extern fn sqlite3_bind_text64(stmt: *sqlite3_stmt, index: c_int, value: [*]const u8, bytes: u64, destructor: isize, encoding: u8) c_int;
pub extern fn sqlite3_bind_blob64(stmt: *sqlite3_stmt, index: c_int, value: ?*const anyopaque, bytes: u64, destructor: isize) c_int;
pub extern fn sqlite3_bind_zeroblob64(stmt: *sqlite3_stmt, index: c_int, bytes: u64) c_int;

pub extern fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_column_name(stmt: *sqlite3_stmt, index: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_type(stmt: *sqlite3_stmt, index: c_int) c_int;
pub extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, index: c_int) i64;
pub extern fn sqlite3_column_double(stmt: *sqlite3_stmt, index: c_int) f64;
pub extern fn sqlite3_column_text(stmt: *sqlite3_stmt, index: c_int) ?[*]const u8;
pub extern fn sqlite3_column_blob(stmt: *sqlite3_stmt, index: c_int) ?[*]const u8;
pub extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, index: c_int) c_int;
