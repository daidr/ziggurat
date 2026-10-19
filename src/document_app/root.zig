//! Document application model: identity and duplicate-open detection, one
//! window per document, recent documents, dirty state in close and quit
//! preflight, atomic saving, autosave scheduling, external-modification
//! conflicts and crash recovery. Owner-thread state lives in `Registry`;
//! blocking file work lives in `Files` and `recovery.Session` for host workers.
const identity = @import("identity.zig");
const registry = @import("registry.zig");
pub const recovery = @import("recovery.zig");

pub const max_path = identity.max_path;
pub const Path = identity.Path;
pub const FileKey = identity.FileKey;
pub const Stamp = identity.Stamp;
pub const Identity = identity.Identity;
pub const Files = @import("files.zig").Files;
pub const Loaded = @import("files.zig").Loaded;
pub const Probe = @import("files.zig").Probe;
pub const SaveOptions = @import("files.zig").SaveOptions;
pub const SaveResult = @import("files.zig").SaveResult;
pub const Recent = @import("recent.zig").Recent;
pub const DocumentId = registry.DocumentId;
pub const Kind = registry.Kind;
pub const RecoveryName = registry.RecoveryName;
pub const Policy = registry.Policy;
pub const Handlers = registry.Handlers;
pub const Released = registry.Released;
pub const Slot = registry.Slot;
pub const Claim = registry.Claim;
pub const Info = registry.Info;
pub const SaveTicket = registry.SaveTicket;
pub const SaveOutcome = registry.SaveOutcome;
pub const SnapshotTicket = registry.SnapshotTicket;
pub const SnapshotOutcome = registry.SnapshotOutcome;
pub const Registry = registry.Registry;
pub const Snapshot = recovery.Snapshot;
pub const Session = recovery.Session;

test {
    _ = @import("tests.zig");
}
