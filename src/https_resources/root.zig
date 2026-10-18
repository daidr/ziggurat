const builtin = @import("builtin");
pub const available = (builtin.os.tag == .linux or builtin.os.tag == .windows) and @import("ziggurat_https_resources_options").enabled;
const native = @import("native.zig");
const types = @import("types.zig");
pub const policy = @import("policy.zig");
pub const Endpoint = @import("endpoint.zig").Endpoint;
pub const Site = @import("site.zig").Site;
pub const Transport = @import("transport.zig").Transport;
pub const TransportNativeCounts = @import("transport.zig").Counts;
pub const transportNativeCounts = @import("transport.zig").nativeCounts;
pub const FileRequest = @import("file_response.zig").FileRequest;
pub const PreparedFileResponse = @import("file_response.zig").PreparedFileResponse;
pub const PreparedFile = @import("file_response.zig").Prepared;
pub const site_routes = @import("site_routes.zig");
pub const Limits = types.Limits;
pub const Head = types.Head;
pub const Receipt = types.Receipt;
pub const Acceptance = types.Acceptance;
pub const ResponseOptions = types.ResponseOptions;
pub const CloseResult = types.CloseResult;
pub const NativeServer = types.NativeServer;
pub const Stats = types.Stats;
pub const NativeCounts = types.NativeCounts;
pub const http = @import("ziggurat_http_response");
pub const files = @import("ziggurat_file_stream");

/// Can be queried after Endpoint/App close. Counts retained C-only physical
/// work; a closed Zig owner is not a native/network quiescence barrier.
pub fn nativeCounts() NativeCounts {
    var out: native.Counts = .{};
    if (available) native.zhr_counts(&out);
    return .{ .owners = out.owners, .gates = out.gates, .operations = out.operations, .tickets = out.tickets, .requested_bytes = out.bytes, .queued_payload_reservation = out.queued_payload_reservation };
}

test {
    _ = policy;
    _ = types;
    _ = @import("endpoint.zig");
    _ = @import("site.zig");
    _ = @import("file_response.zig");
    _ = @import("transport.zig");
}

test "disabled endpoint is cold unsupported before App server or input access" {
    if (available) return;
    const std = @import("std");
    const z = @import("ziggurat");
    const Callback = struct {
        fn request(_: *anyopaque, _: *Endpoint, _: Endpoint.Request, _: Endpoint.Offer) void {
            unreachable;
        }
    };
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const app: *z.App = @ptrFromInt(@alignOf(z.App));
    const server: *NativeServer = @ptrFromInt(8);
    const invalid: [*]const u8 = @ptrFromInt(1);
    try std.testing.expectError(error.UnsupportedCapability, Endpoint.create(allocator.allocator(), app, server, .{ .port = 0, .mount_prefix = invalid[0..1], .bearer = @splat(0), .context = @ptrFromInt(8), .on_request = Callback.request, .limits = .{ .bytes = 0 } }));
    try std.testing.expectEqual(@as(usize, 0), allocator.alloc_index);
    try std.testing.expectEqualDeep(NativeCounts{}, nativeCounts());
}
