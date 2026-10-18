//! Private allocation-free protocol callbacks shared by the explicit reactor
//! and its isolated native oracle. No App, caller allocator or platform policy.
const http = @import("ziggurat_http_response");
const head = @import("http1_head.zig");
pub const native = @import("native.zig");
pub const policy = @import("policy.zig");

extern fn zhtw_envelope_head(*anyopaque) native.Slice;
extern fn zhtw_envelope_port(*anyopaque) u16;
extern fn zhtw_dispatch(*anyopaque, *const native.Request) void;
extern fn zhtw_reject(*anyopaque, c_uint) void;

pub fn dispatch(envelope: *anyopaque) callconv(.c) void {
    const raw = zhtw_envelope_head(envelope);
    const parsed = head.parse(raw.bytes()) catch {
        zhtw_reject(envelope, 400);
        return;
    };
    var rows: [head.header_capacity]native.Header = undefined;
    for (parsed.headers(), 0..) |row, i| rows[i] = .{ .name = native.Slice.from(row.name), .value = native.Slice.from(row.value) };
    const port = zhtw_envelope_port(envelope);
    const request: native.Request = .{
        .scheme = native.Slice.from("https"),
        .host = native.Slice.from("127.0.0.1"),
        .path = native.Slice.from(parsed.path),
        .query = native.Slice.from(parsed.query orelse ""),
        .method = native.Slice.from(parsed.method),
        .headers = &rows,
        .header_count = parsed.count,
        .port = port,
        .local_port = port,
        .local_ip = .{ 127, 0, 0, 1 },
        .peer_ip = .{ 127, 0, 0, 1 },
        .flags = 1 | @as(u32, if (parsed.query != null) 8 else 0),
    };
    // The native listener verified real local/peer IPv4 addresses. Its URI is
    // origin-form; the observed Host is still independently validated by Policy.
    zhtw_dispatch(envelope, &request);
}

pub fn format(response: *const native.Response, representation_length: u64, buffer: [*]u8, capacity: usize, written: *usize) callconv(.c) c_int {
    written.* = 0;
    if (response.status > 65535 or response.header_count > 16 or response.mime.ptr == null or (response.header_count != 0 and response.headers == null)) return 1;
    var headers: [16]http.Header = undefined;
    for (0..response.header_count) |i| {
        const row = response.headers.?[i];
        if (row.name.ptr == null or (row.value.length != 0 and row.value.ptr == null)) return 1;
        headers[i] = .{ .name = row.name.bytes(), .value = row.value.bytes() };
    }
    const bytes = head.responseHead(buffer[0..capacity], .{ .status = @intCast(response.status), .mime = response.mime.bytes(), .headers = headers[0..response.header_count] }, representation_length) catch return 1;
    written.* = bytes.len;
    return 0;
}

test {
    _ = head;
}
