//! Explicit disk snapshots and build-time embedding for local WebView content.
//! Snapshots do synchronous I/O: load them in a caller-managed worker, then hand
//! ownership to the main thread with App.post. Resource callbacks only read RAM.
pub const snapshot = @import("snapshot.zig");
pub const Snapshot = snapshot.Snapshot;
pub const Asset = snapshot.Asset;
pub const Limits = snapshot.Limits;
pub const mimeForPath = snapshot.mimeForPath;
pub const DirectoryWatch = @import("watch.zig").DirectoryWatch;
pub const generate = @import("generator.zig").generate;

test {
    _ = @import("snapshot.zig");
    _ = @import("generator.zig");
}
