const ipc = @import("ziggurat_ipc");

/// The WebSocket plugin's wire service. The page package's generated client
/// is made from this schema and must use `limits`.
pub const Service = struct {
    pub const name = "websocket";
    /// Every connection holds one `connect` call for its life and sends its
    /// messages one piece at a time, so 16 connections take at most 32
    /// pending calls. Pieces carry 32 KiB of message bytes as Base64.
    pub const limits: ipc.Limits = .{ .max_pending = 32, .max_in_flight = 16, .max_message_bytes = 64 * 1024 };

    pub const Header = struct { name: []const u8, value: []const u8 };
    pub const Connect = struct {
        /// Chosen by the page; unique among its open connections.
        id: u32,
        /// An absolute ws or wss URL.
        url: []const u8,
        protocols: []const []const u8,
        headers: []const Header,
    };
    pub const Kind = enum { open, text, binary, close };
    /// What happens to a connection: `open` once, then the messages, in
    /// pieces, then `close`, after which the call completes.
    pub const Event = struct {
        kind: Kind,
        /// The subprotocol the server chose, on `open`.
        protocol: ?[]const u8,
        /// A piece of a message, as Base64.
        data: ?[]const u8,
        /// The piece ends its message.
        last: bool,
        /// On `close`: the code, its reason, and whether the closing
        /// handshake completed.
        code: u16,
        reason: ?[]const u8,
        clean: bool,
        /// Why the connection failed, on an unclean `close`.
        @"error": ?[]const u8,
    };
    pub const Outgoing = enum { text, binary, close };
    /// A piece of a message the page sends on connection `id`, after the
    /// pieces before it; or, `close`, the start of the closing handshake.
    pub const Message = struct {
        id: u32,
        kind: Outgoing,
        /// Base64.
        data: ?[]const u8,
        last: bool,
        code: u16,
        reason: ?[]const u8,
    };
    pub const Code = enum { invalid, denied, busy, closed, failed };

    pub const methods = .{
        .connect = ipc.Method(Connect, void, Code, Event),
        .send = ipc.Method(Message, void, Code, void),
    };
};
