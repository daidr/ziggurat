const ipc = @import("ziggurat_ipc");

/// The SQLite plugin's wire service. The page package's generated client is
/// made from this schema and must use `limits`.
pub const Service = struct {
    pub const name = "sqlite";
    /// Query rows larger than one message arrive in several parts.
    pub const limits: ipc.Limits = .{ .max_pending = 32, .max_in_flight = 8, .max_message_bytes = 64 * 1024 };

    /// Every cell carries its storage class: JSON alone cannot tell a BLOB
    /// from text, or carry a 64-bit integer exactly.
    pub const Type = enum { null, integer, real, text, blob };
    pub const Special = enum { Infinity, @"-Infinity", NaN };
    pub const Value = struct {
        type: Type,
        /// Decimal, for `integer`.
        integer: ?[]const u8,
        real: ?f64,
        /// A `real` JSON cannot hold.
        special: ?Special,
        text: ?[]const u8,
        /// Base64, for `blob`.
        blob: ?[]const u8,
    };
    pub const Open = struct {
        /// A file name in the plugin's directory, or ":memory:".
        name: []const u8,
        readOnly: bool,
    };
    pub const Connection = struct { connection: u32 };
    pub const Statement = struct {
        connection: u32,
        sql: []const u8,
        params: []const Value,
    };
    pub const Item = struct {
        sql: []const u8,
        params: []const Value,
    };
    pub const Batch = struct {
        connection: u32,
        statements: []const Item,
    };
    pub const Result = struct {
        changes: i53,
        /// Decimal.
        lastInsertId: []const u8,
    };
    /// The columns first, then the rows.
    pub const Rows = struct {
        columns: ?[]const []const u8,
        rows: []const []const Value,
    };
    pub const Code = enum { invalid, denied, closed, limit, unsupported, sqlite };

    pub const methods = .{
        .open = ipc.Method(Open, u32, Code, void),
        .execute = ipc.Method(Statement, Result, Code, void),
        .query = ipc.Method(Statement, void, Code, Rows),
        .transaction = ipc.Method(Batch, []const Result, Code, void),
        .closeDatabase = ipc.Method(Connection, void, Code, void),
    };
};
