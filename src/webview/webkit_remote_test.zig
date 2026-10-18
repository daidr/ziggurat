const std = @import("std");
const r = @import("webkit_remote.zig");
const resources = @import("resources.zig");
const Grant = struct { origin: []const u8, navigate: bool = true, requests: bool = true, ipc: bool = false, methods: resources.MethodSet = .{}, request_headers: []const resources.HeaderGrant = &.{} };
const Page = struct { url: []const u8, origins: []const Grant, request_credentials: []const @import("request_credentials.zig").Entry = &.{}, allow_insecure_loopback: bool = false, allow_script_navigation: bool = false, allow_redirects: bool = false };

test "remote staging authority canonicalization rejects ambiguous and implicit local access" {
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.test", try r.canonicalUriOrigin(&buffer, "HTTPS://EXAMPLE.test:443/path?query#fragment", false, false));
    try std.testing.expectEqualStrings("https://[2001:db8::1]:8443", try r.canonicalUriOrigin(&buffer, "https://[2001:0db8:0:0:0:0:0:1]:8443/", true, false));
    for ([_][]const u8{
        "https://user@example.test", "https://@example.test", "https://%65xample.test", "https://example.test:0", "https://127.1", "https://2130706433", "https://127.00.0.1", "https://0x7f000001", "https://example.test.", "file:///private/file", "https://example.test\\@other.test", "https://app.ziggurat.invalid", "http://example.test", "https://localhost", "https://host.localhost", "https://127.0.0.1", "https://[::1]", "https://[::ffff:127.0.0.1]", "https://[::127.0.0.1]",
    }) |input| try std.testing.expectError(error.InvalidRemoteUri, r.canonicalUriOrigin(&buffer, input, false, false));
    for ([_][]const u8{ "https://example.test/path", "https://example.test?query", "https://example.test/#fragment" }) |input| try std.testing.expectError(error.InvalidRemoteUri, r.canonicalUriOrigin(&buffer, input, true, false));
    for ([_][]const u8{ "http://127.0.0.1:1234", "http://localhost", "http://[::1]", "http://[::ffff:127.0.0.1]" }) |input| _ = try r.canonicalUriOrigin(&buffer, input, false, true);
    try std.testing.expectEqualStrings("https://127.example.test", try r.canonicalUriOrigin(&buffer, "https://127.example.test", false, false));
    try std.testing.expectError(error.InvalidRemoteUri, r.canonicalUriOrigin(&buffer, "http://127.example.test", false, true));
}
test "remote staging checks initial navigation request and method grants before allocation" {
    var page: Page = .{ .url = "https://example.test/start", .origins = &.{.{ .origin = "https://example.test" }} };
    try r.validate(page);
    page.origins = &.{};
    try std.testing.expectError(error.InvalidOriginCount, r.validate(page));
    page.origins = &.{ .{ .origin = "https://example.test" }, .{ .origin = "HTTPS://EXAMPLE.test:443/" } };
    try std.testing.expectError(error.DuplicateRemoteOrigin, r.validate(page));
    page.origins = &.{.{ .origin = "https://example.test", .navigate = false }};
    try std.testing.expectError(error.InitialOriginDenied, r.validate(page));
    page.origins = &.{.{ .origin = "https://example.test", .requests = false }};
    try std.testing.expectError(error.InitialOriginDenied, r.validate(page));
    page.origins = &.{.{ .origin = "https://example.test", .methods = .{ .get = false } }};
    try std.testing.expectError(error.InitialOriginDenied, r.validate(page));
    page.origins = &.{.{ .origin = "https://example.test", .request_headers = &.{.{ .name = "Cookie" }} }};
    try std.testing.expectError(error.InvalidHeaderGrant, r.validate(page));
}
fn allocation(allocator: std.mem.Allocator) !void {
    var scratch = try r.Scratch.init(allocator, Page{ .url = "https://example.test/a", .origins = &.{.{ .origin = "https://example.test", .request_headers = &.{ .{ .name = "Content-Type", .exact_value = "application/json" }, .{ .name = "X-Empty", .exact_value = "" }, .{ .name = "X-Any" } } }} }, .{ .directory = "/app/policy" });
    defer scratch.deinit();
    try std.testing.expectEqual(@as(u32, 1), scratch.input.count);
}
test "remote native scratch copies complete owned Z strings and rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocation, .{});
    var name = "X-Test".*;
    var value = "original".*;
    var url = "https://example.test/start".*;
    var origin = "https://example.test".*;
    var directory = "/app/policy".*;
    const headers = [_]resources.HeaderGrant{.{ .name = &name, .exact_value = &value }};
    const grants = [_]Grant{.{ .origin = &origin, .request_headers = &headers, .ipc = true }};
    var scratch = try r.Scratch.init(std.testing.allocator, Page{ .url = &url, .origins = &grants }, .{ .directory = &directory });
    defer scratch.deinit();
    @memset(&name, 'a');
    @memset(&value, 'b');
    @memset(&url, 'c');
    @memset(&origin, 'd');
    @memset(&directory, 'e');
    try std.testing.expectEqualStrings("https://example.test/start", std.mem.span(scratch.input.url));
    try std.testing.expectEqualStrings("https://example.test", std.mem.span(scratch.input.origins[0].origin));
    try std.testing.expectEqualStrings("/app/policy", std.mem.span(scratch.input.directory));
    try std.testing.expectEqualStrings("X-Test", std.mem.span(scratch.input.origins[0].headers[0].name));
    try std.testing.expectEqualStrings("original", std.mem.span(scratch.input.origins[0].headers[0].value.?));
    try std.testing.expectEqual(@as(u32, 7), scratch.input.origins[0].flags);
    try std.testing.expectEqual(@as(u32, 3), scratch.input.origins[0].methods);
    scratch.deinit();
    scratch.deinit();
}
test "native extension deployment is an explicit bounded absolute path and one-shot deadline" {
    try r.validateExtension(.{ .directory = "/app/policy" });
    for ([_][]const u8{ "", "relative", "C:\\policy", "/app\x00policy", "/app\xff" }) |path| try std.testing.expectError(error.InvalidRequestExtensionDirectory, r.validateExtension(.{ .directory = path }));
    try std.testing.expectError(error.InvalidRequestExtensionDeadline, r.validateExtension(.{ .directory = "/app", .handshake_timeout_ms = 0 }));
    try std.testing.expectError(error.InvalidRequestExtensionDeadline, r.validateExtension(.{ .directory = "/app", .handshake_timeout_ms = 60001 }));
}

test "request credentials require distinct exact HTTPS grants and reject Authorization ambiguity" {
    var page: Page = .{ .url = "https://example.test", .origins = &.{.{ .origin = "https://example.test" }}, .request_credentials = &.{.{ .origin = "HTTPS://EXAMPLE.test:443/", .bearer = .{0x5a} ** 32 }} };
    try r.validate(page);
    var scratch = try r.Scratch.init(std.testing.allocator, page, .{ .directory = "/app/policy" });
    defer scratch.deinit();
    try std.testing.expectEqualSlices(u8, &(.{0x5a} ** 32), scratch.input.origins[0].bearer.?);
    page.request_credentials = &.{.{ .origin = "https://other.test", .bearer = .{1} ** 32 }};
    try std.testing.expectError(error.CredentialOriginDenied, r.validate(page));
    page.request_credentials = &.{ .{ .origin = "https://example.test", .bearer = .{1} ** 32 }, .{ .origin = "HTTPS://EXAMPLE.test:443/", .bearer = .{2} ** 32 } };
    try std.testing.expectError(error.DuplicateRequestCredential, r.validate(page));
    page.allow_insecure_loopback = true;
    page.request_credentials = &.{.{ .origin = "http://127.0.0.1", .bearer = .{1} ** 32 }};
    try std.testing.expectError(error.CredentialRequiresHttps, r.validate(page));
    page.request_credentials = &.{.{ .origin = "https://example.test", .bearer = .{1} ** 32 }};
    page.origins = &.{.{ .origin = "https://example.test", .request_headers = &.{.{ .name = "aUtHoRiZaTiOn" }} }};
    try std.testing.expectError(error.ConflictingRequestCredential, r.validate(page));
}
