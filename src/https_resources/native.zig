pub const Slice = extern struct {
    ptr: ?[*]const u8 = null,
    length: usize = 0,
    pub fn from(value: []const u8) Slice {
        return .{ .ptr = value.ptr, .length = value.len };
    }
    pub fn bytes(self: Slice) []const u8 {
        return if (self.length == 0) "" else self.ptr.?[0..self.length];
    }
};
pub const Header = extern struct { name: Slice, value: Slice };
pub const Request = extern struct {
    scheme: Slice,
    host: Slice,
    path: Slice,
    query: Slice,
    method: Slice,
    headers: ?[*]const Header,
    header_count: usize,
    port: u16,
    local_port: u16,
    local_ip: [4]u8,
    peer_ip: [4]u8,
    flags: u32,
};
pub const Options = extern struct { bytes: usize, pending: u32, port: u32, file_streams: u32, prefix: Slice };
pub const Response = extern struct { status: u32, mime: Slice, headers: ?[*]const Header, header_count: usize, body: Slice, length: u64 };
pub const Target = extern struct { borrow: ?*anyopaque = null, ticket: ?*anyopaque = null };
pub const Stats = extern struct { bytes: usize, peak_bytes: usize, queued_payload_reservation: usize, physical_pending: u32, accepting: u32 };
pub const Counts = extern struct { owners: u32 = 0, gates: u32 = 0, operations: u32 = 0, tickets: u32 = 0, bytes: usize = 0, queued_payload_reservation: usize = 0 };
pub extern fn zhr_server_pin(*anyopaque, *?*anyopaque) c_int;
pub extern fn zhr_server_unpin(*anyopaque) void;
pub extern fn zhr_create(*anyopaque, *const Options, *?*anyopaque) c_int;
pub extern fn zhr_bind(*anyopaque, *anyopaque, *const fn (*anyopaque, *const Request) callconv(.c) c_int, *const fn (*anyopaque, *const Request, *anyopaque) callconv(.c) void) c_int;
pub extern fn zhr_check(*anyopaque) c_int;
pub extern fn zhr_borrow_input(*anyopaque, usize) c_int;
pub extern fn zhr_return_input(*anyopaque) void;
pub extern fn zhr_seal(*anyopaque) void;
pub extern fn zhr_close(*anyopaque) void;
pub extern fn zhr_owner_release(*anyopaque) void;
pub extern fn zhr_owner_size() usize;
pub extern fn zhr_stats(*anyopaque, *Stats) c_int;
pub extern fn zhr_counts(*Counts) void;
pub extern fn zhr_defer(*anyopaque, *?*anyopaque) c_int;
pub extern fn zhr_ticket_owner(*anyopaque, *?*anyopaque) c_int;
pub extern fn zhr_ticket_release(*anyopaque) void;
pub extern fn zhr_ticket_consume(*anyopaque) void;
pub extern fn zhr_ticket_cancel(*anyopaque) c_int;
pub extern fn zhr_prepare_memory(Target, *const Response, *?*anyopaque) c_int;
pub extern fn zhr_prepare_head(Target, *const Response, *?*anyopaque) c_int;
pub extern fn zhr_prepare_file(Target, *const Response, *anyopaque, *?*anyopaque) c_int;
pub extern fn zhr_candidate_check(*anyopaque, *anyopaque) c_int;
pub extern fn zhr_candidate_abort(*anyopaque) void;
pub extern fn zhr_candidate_admit(*anyopaque, c_int, *?*anyopaque) c_int;
pub extern fn zhr_candidate_admit_source(*anyopaque) void;
pub extern fn zhr_candidate_start(*anyopaque) c_int;

pub fn check(status: c_int) !void {
    return switch (status) {
        0 => {},
        1 => error.Closed,
        2 => error.Full,
        3 => error.OutOfMemory,
        4 => error.InvalidEndpoint,
        5 => error.WrongThread,
        6 => error.NativeFailure,
        7 => error.StaleTicket,
        8 => error.CapacityExceeded,
        else => error.NativeFailure,
    };
}
