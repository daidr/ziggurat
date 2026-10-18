const implementation = if (@import("builtin").os.tag == .windows) @import("profile_storage_windows.zig") else @import("profile_storage_linux.zig");
pub const max_path_bytes = implementation.max_path_bytes;
pub const max_leases = implementation.max_leases;
pub const max_owned_bytes = implementation.max_owned_bytes;
pub const Limits = implementation.Limits;
pub const Paths = implementation.Paths;
pub const Stats = implementation.Stats;
pub const Lease = implementation.Lease;
pub const NativeClaim = implementation.NativeClaim;
pub const Prepared = implementation.Prepared;
/// Windows only; Linux preparation has no browser-process retirement driver.
pub const RetirementDriver = if (@import("builtin").os.tag == .windows) implementation.RetirementDriver else void;
test {
    _ = implementation;
}
