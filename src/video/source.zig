//! What a video engine opens: a URL, or bytes in memory.
pub const Source = union(enum) {
    /// A file:, http: or https: URL, or an HLS playlist where the system
    /// streams them.
    url: []const u8,
    /// A video in memory, which stays as it is while the engine is open.
    data: []const u8,
};
