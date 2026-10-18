pub const Failure = extern struct { domain: u32 = 0, code: i32 = 0 };
pub const Options = extern struct { bytes: usize, zig_bytes: usize, temporary_bytes: usize, pem: [*]const u8, length: usize };
pub const Stats = extern struct { bytes: usize, peak_bytes: usize, accepting: u32, port: u32 };
pub const Counts = extern struct { owners: u32 = 0, servers: u32 = 0, bytes: usize = 0 };
pub const Lease = extern struct { owner: ?*anyopaque = null, server: ?*anyopaque = null, port: u32 = 0 };
pub extern fn zht_create(*const Options, *?*anyopaque, *Failure) c_int;
pub extern fn zht_ref(*anyopaque) void;
pub extern fn zht_unref(*anyopaque) void;
pub extern fn zht_seal(*anyopaque) c_int;
pub extern fn zht_close(*anyopaque) void;
pub extern fn zht_stats(*anyopaque, *Stats) c_int;
pub extern fn zht_lease_begin(*anyopaque, *Lease) c_int;
pub extern fn zht_lease_finish(*Lease) c_int;
pub extern fn zht_counts(*Counts) void;
pub extern fn zht_owner_size() usize;

pub fn check(status: c_int) !void {
    return switch (status) {
        0 => {},
        1 => error.Closed,
        2 => error.Full,
        3 => error.OutOfMemory,
        4 => error.InvalidTransport,
        5 => error.WrongThread,
        6 => error.NativeFailure,
        8 => error.TransportBudgetExceeded,
        else => error.NativeFailure,
    };
}
