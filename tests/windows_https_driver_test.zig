const std = @import("std");
const protocol = @import("ziggurat_https_windows_protocol");
const native = protocol.native;
const policy = protocol.policy;
const http = @import("ziggurat_http_response");

extern fn zhtw_test_reactor(*const fn (*anyopaque) callconv(.c) void, @TypeOf(&protocol.format), *const fn (*anyopaque, *const native.Request) callconv(.c) c_int) c_int;

fn filter(_: *anyopaque, input: *const native.Request) callconv(.c) c_int {
    if (input.header_count > policy.header_capacity) return 0;
    var value: policy.Policy = undefined;
    value.captureInto(input.local_port, "/private/", @splat(0xa7)) catch return 0;
    defer std.crypto.secureZero(u8, &value.bearer);
    var headers: [policy.header_capacity]http.Header = undefined;
    for (0..input.header_count) |i| headers[i] = .{ .name = input.headers.?[i].name.bytes(), .value = input.headers.?[i].value.bytes() };
    _ = value.validate(.{
        .version = if (input.flags & 1 != 0) .http_1_1 else .other,
        .local = .{ .ip = input.local_ip, .port = input.local_port },
        .peer = input.peer_ip,
        .scheme = input.scheme.bytes(),
        .host = input.host.bytes(),
        .port = input.port,
        .has_userinfo = input.flags & 2 != 0,
        .has_fragment = input.flags & 4 != 0,
        .path = input.path.bytes(),
        .query = if (input.flags & 8 != 0) input.query.bytes() else null,
        .headers = headers[0..input.header_count],
        .method = input.method.bytes(),
    }) catch return 0;
    return 1;
}

test "explicit Windows reactor real TLS network with production framing policy and shared source" {
    try std.testing.expectEqual(@as(c_int, 0), zhtw_test_reactor(&protocol.dispatch, &protocol.format, &filter));
}
