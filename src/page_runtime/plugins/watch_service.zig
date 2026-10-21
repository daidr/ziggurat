const ipc = @import("ziggurat_ipc");

/// The watch plugin's wire service. The page package's generated client is
/// made from this schema and must use `limits`.
pub const Service = struct {
    pub const name = "watch";
    /// A page watches at most 8 roots at a time. A batch larger than one
    /// message arrives as several parts, the last without `more`.
    pub const limits: ipc.Limits = .{ .max_pending = 8, .max_in_flight = 4, .max_message_bytes = 64 * 1024 };

    pub const Request = struct {
        /// The name the app gave the root.
        root: []const u8,
        /// What to watch in the root, relative to it and separated by
        /// slashes; "." is the root itself.
        path: []const u8,
        recursive: bool,
        /// The quiet before changes are reported: 50 ms when 0, none when
        /// negative.
        debounceMs: i32,
    };
    pub const Op = enum { create, write, remove, rename };
    pub const Event = struct {
        op: Op,
        /// Relative to what is watched, separated by slashes; "." is what
        /// is watched itself.
        path: []const u8,
        /// Where a rename moved from.
        oldPath: ?[]const u8,
        isDir: bool,
    };
    /// `ready` once everything is watched, then the batches of events.
    pub const Part = struct {
        ready: bool,
        events: []const Event,
        /// More parts of the same batch follow.
        more: bool,
    };
    pub const Code = enum { denied, limit, @"not-found", unsupported, @"path-encoding", io };

    pub const methods = .{
        .watch = ipc.Method(Request, void, Code, Part),
    };
};
