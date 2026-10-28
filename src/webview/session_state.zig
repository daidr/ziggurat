//! A page's saved session (View.sessionState, View.restoreSessionState):
//! the platform that saved it, the page's URI, and the engine's own state,
//! WebKitGTK's serialized back/forward list with its scroll positions and
//! form fields. WebView2 has no such state, so Windows saves the URI alone.
const std = @import("std");

const magic = "ZGSS";
const version: u8 = 1;
const header_bytes = magic.len + 2 + 4;
pub const max_uri_bytes = 16384;
/// The engine's state at most; WebKitGTK's grows with the list.
pub const max_native_bytes = 8 * 1024 * 1024;

pub const Platform = enum(u8) { linux = 'L', windows = 'W', _ };

pub const Parsed = struct {
    platform: Platform,
    uri: []const u8,
    /// Empty where the platform saved none.
    native: []const u8,
};

pub fn encode(allocator: std.mem.Allocator, platform: Platform, uri: []const u8, native: []const u8) ![]u8 {
    if (uri.len == 0 or uri.len > max_uri_bytes) return error.InvalidSessionState;
    if (native.len > max_native_bytes) return error.SessionStateTooLarge;
    const out = try allocator.alloc(u8, header_bytes + uri.len + native.len);
    @memcpy(out[0..magic.len], magic);
    out[magic.len] = version;
    out[magic.len + 1] = @intFromEnum(platform);
    std.mem.writeInt(u32, out[magic.len + 2 ..][0..4], @intCast(uri.len), .little);
    @memcpy(out[header_bytes..][0..uri.len], uri);
    @memcpy(out[header_bytes + uri.len ..], native);
    return out;
}

/// Borrows from bytes.
pub fn parse(bytes: []const u8) !Parsed {
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..magic.len], magic) or bytes[magic.len] != version) return error.InvalidSessionState;
    const length = std.mem.readInt(u32, bytes[magic.len + 2 ..][0..4], .little);
    if (length == 0 or length > max_uri_bytes or length > bytes.len - header_bytes) return error.InvalidSessionState;
    const native = bytes[header_bytes + length ..];
    if (native.len > max_native_bytes) return error.SessionStateTooLarge;
    return .{ .platform = @enumFromInt(bytes[magic.len + 1]), .uri = bytes[header_bytes..][0..length], .native = native };
}

/// The path of a local site's URI, scheme://host/path, or null for another
/// site's.
pub fn localPath(uri: []const u8, scheme: []const u8, host: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(uri, scheme) or !std.mem.startsWith(u8, uri[scheme.len..], "://")) return null;
    const rest = uri[scheme.len + 3 ..];
    if (!std.ascii.startsWithIgnoreCase(rest, host)) return null;
    const path = rest[host.len..];
    if (path.len == 0 or path[0] != '/') return null;
    return path;
}

test "a session state goes and comes back" {
    const bytes = try encode(std.testing.allocator, .linux, "https://example.test/a", "\x00\x01native");
    defer std.testing.allocator.free(bytes);
    const parsed = try parse(bytes);
    try std.testing.expectEqual(Platform.linux, parsed.platform);
    try std.testing.expectEqualStrings("https://example.test/a", parsed.uri);
    try std.testing.expectEqualStrings("\x00\x01native", parsed.native);
    try std.testing.expectError(error.InvalidSessionState, parse(bytes[0..12]));
    try std.testing.expectError(error.InvalidSessionState, parse("ZGSS\x02L\x01\x00\x00\x00a"));
    const other = try parse("ZGSS\x01Q\x01\x00\x00\x00a");
    try std.testing.expect(other.platform != .linux and other.platform != .windows and other.native.len == 0);
}

test "local paths come out of their site's URIs" {
    try std.testing.expectEqualStrings("/docs/a?x", localPath("app://ui/docs/a?x", "app", "ui").?);
    try std.testing.expect(localPath("app://other/docs", "app", "ui") == null);
    try std.testing.expect(localPath("https://ui/docs", "app", "ui") == null);
}
