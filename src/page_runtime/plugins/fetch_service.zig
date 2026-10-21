const ipc = @import("ziggurat_ipc");

/// The fetch plugin's wire service. The page package's generated client is
/// made from this schema and must use `limits`.
pub const Service = struct {
    pub const name = "fetch";
    /// Page messages hold at most 64 KiB. Response chunks carry 32 KiB of
    /// body, so 32 in flight are at most 1 MiB the page has yet to read;
    /// larger request bodies arrive first as `upload` pieces.
    pub const limits: ipc.Limits = .{ .max_pending = 32, .max_in_flight = 32, .max_message_bytes = 64 * 1024 };

    pub const Header = struct { name: []const u8, value: []const u8 };
    pub const Redirect = enum { follow, manual, @"error" };
    pub const Request = struct {
        /// An absolute http or https URL.
        url: []const u8,
        method: []const u8,
        headers: []const Header,
        /// Base64, for bodies that fit in the call.
        body: ?[]const u8,
        /// A body sent before as `upload` pieces, which the request takes.
        upload: ?u32,
        redirect: Redirect,
    };
    /// One piece of a request body, appended to the page's upload `upload`.
    pub const Piece = struct {
        upload: u32,
        /// Base64.
        data: []const u8,
    };
    pub const Head = struct {
        status: u16,
        statusText: []const u8,
        url: []const u8,
        redirected: bool,
        /// Lowercase names, in the order received, without Set-Cookie.
        headers: []const Header,
    };
    /// The response's head first, then chunks of its body.
    pub const Part = struct {
        head: ?Head,
        /// Base64.
        chunk: ?[]const u8,
    };
    pub const Code = enum { invalid, denied, busy, failed };

    pub const methods = .{
        .fetch = ipc.Method(Request, void, Code, Part),
        .upload = ipc.Method(Piece, void, Code, void),
    };
};
