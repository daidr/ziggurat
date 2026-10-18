const std = @import("std");

/// Lexical file identities only. No filesystem lookup, drive mapping, symlink
/// resolution or case inference is performed. Paths and decoded URI segments
/// are UTF-8; only ASCII drive letters/authority are case folded.
pub const Style = enum { posix, windows };
pub const Case = enum { sensitive, ascii_insensitive };
const maximum = 4096;

fn text(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > maximum or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidFileUri;
}
fn safe(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~/:", byte) != null;
}
fn hex(byte: u8) !u8 {
    return std.fmt.charToDigit(byte, 16) catch error.InvalidFileUri;
}
fn equal(a: []const u8, b: []const u8, policy: Case) bool {
    return switch (policy) {
        .sensitive => std.mem.eql(u8, a, b),
        .ascii_insensitive => std.ascii.eqlIgnoreCase(a, b),
    };
}
/// Validates the supported, deliberately unambiguous absolute file-URI subset.
/// Percent-encoded '/' and '\\', dot segments, userinfo/ports, query/fragment,
/// repeated separators, and escaped NUL are rejected rather than normalized.
pub fn validate(uri: []const u8) !void {
    try text(uri);
    if (!std.mem.startsWith(u8, uri, "file://")) return error.UnsupportedUriScheme;
    const slash = std.mem.indexOfScalarPos(u8, uri, 7, '/') orelse return error.InvalidFileUri;
    const authority = uri[7..slash];
    for (authority) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') return error.InvalidFileUri;
    var decoded: [maximum]u8 = undefined;
    var len: usize = 0;
    var at = slash;
    while (at < uri.len) {
        var byte = uri[at];
        if (byte == '%') {
            if (uri.len - at < 3) return error.InvalidFileUri;
            byte = (try hex(uri[at + 1])) * 16 + try hex(uri[at + 2]);
            if (byte == '/' or byte == '\\') return error.AmbiguousFileUri;
            at += 3;
        } else {
            if (byte == '\\' or byte == '?' or byte == '#' or byte <= 32 or byte == 127 or byte >= 128) return error.InvalidFileUri;
            at += 1;
        }
        if (byte == 0) return error.InvalidFileUri;
        decoded[len] = byte;
        len += 1;
    }
    if (!std.unicode.utf8ValidateSlice(decoded[0..len])) return error.InvalidFileUri;
    var segments = std.mem.splitScalar(u8, decoded[1..len], '/');
    var offset: usize = 1;
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.AmbiguousFileUri;
        if (segment.len == 0 and offset != len) return error.AmbiguousFileUri;
        offset += segment.len + 1;
    }
}
/// Caller-owned output. Capacity is checked before any destination byte changes.
pub fn fromPath(path: []const u8, style: Style, output: []u8) ![]const u8 {
    try text(path);
    var normalized: [maximum]u8 = undefined;
    @memcpy(normalized[0..path.len], path);
    var authority: []const u8 = "";
    var local = normalized[0..path.len];
    if (style == .windows) {
        for (local) |*byte| if (byte.* == '\\') {
            byte.* = '/';
        };
        if (std.mem.startsWith(u8, local, "//")) {
            const end = std.mem.indexOfScalarPos(u8, local, 2, '/') orelse return error.InvalidPath;
            authority = local[2..end];
            local = local[end..];
        } else {
            if (local.len < 3 or !std.ascii.isAlphabetic(local[0]) or local[1] != ':' or local[2] != '/') return error.InvalidPath;
            local[0] = std.ascii.toUpper(local[0]);
        }
    } else if (local[0] != '/' or std.mem.indexOfScalar(u8, local, '\\') != null) return error.InvalidPath;
    var candidate: [maximum]u8 = undefined;
    const prefix = "file://";
    @memcpy(candidate[0..prefix.len], prefix);
    var len: usize = prefix.len;
    if (authority.len > candidate.len - len) return error.UriCapacityExceeded;
    for (authority) |byte| {
        candidate[len] = std.ascii.toLower(byte);
        len += 1;
    }
    if (style == .windows and authority.len == 0) {
        candidate[len] = '/';
        len += 1;
    }
    const digits = "0123456789ABCDEF";
    for (local) |byte| {
        const count: usize = if (safe(byte)) 1 else 3;
        if (count > candidate.len - len) return error.UriCapacityExceeded;
        if (count == 1) candidate[len] = byte else {
            candidate[len] = '%';
            candidate[len + 1] = digits[byte >> 4];
            candidate[len + 2] = digits[byte & 15];
        }
        len += count;
    }
    try validate(candidate[0..len]);
    if (len > output.len) return error.UriCapacityExceeded;
    @memcpy(output[0..len], candidate[0..len]);
    return output[0..len];
}
pub fn toPath(uri: []const u8, style: Style, output: []u8) ![]const u8 {
    try validate(uri);
    const slash = std.mem.indexOfScalarPos(u8, uri, 7, '/').?;
    const authority = uri[7..slash];
    if (style == .posix and authority.len != 0) return error.UnsupportedAuthority;
    var candidate: [maximum]u8 = undefined;
    var len: usize = 0;
    var at = slash;
    if (style == .windows) {
        if (authority.len != 0) {
            candidate[0] = '\\';
            candidate[1] = '\\';
            len = 2;
            @memcpy(candidate[len..][0..authority.len], authority);
            len += authority.len;
        } else {
            if (uri.len - slash < 4 or !std.ascii.isAlphabetic(uri[slash + 1]) or uri[slash + 2] != ':' or uri[slash + 3] != '/') return error.InvalidPath;
            at += 1;
        }
    }
    while (at < uri.len) {
        var byte = uri[at];
        if (byte == '%') {
            byte = (try hex(uri[at + 1])) * 16 + try hex(uri[at + 2]);
            at += 3;
        } else at += 1;
        if (style == .windows and byte == '/') byte = '\\';
        candidate[len] = byte;
        len += 1;
    }
    if (len > output.len) return error.UriCapacityExceeded;
    @memcpy(output[0..len], candidate[0..len]);
    return output[0..len];
}
/// Full decoded path-segment ancestry. A root trailing slash is insignificant;
/// authority is ASCII case-insensitive, path comparison uses caller policy.
pub fn contains(root: []const u8, uri: []const u8, policy: Case) !bool {
    try validate(root);
    try validate(uri);
    const root_slash = std.mem.indexOfScalarPos(u8, root, 7, '/').?;
    const uri_slash = std.mem.indexOfScalarPos(u8, uri, 7, '/').?;
    if (!std.ascii.eqlIgnoreCase(root[7..root_slash], uri[7..uri_slash])) return false;
    var root_path: [maximum]u8 = undefined;
    var uri_path: [maximum]u8 = undefined;
    const a = try toPathLocal(root[root_slash..], &root_path);
    const b = try toPathLocal(uri[uri_slash..], &uri_path);
    const len = if (a.len > 1 and a[a.len - 1] == '/') a.len - 1 else a.len;
    return b.len >= len and equal(a[0..len], b[0..len], policy) and (len == 1 or b.len == len or b[len] == '/');
}
pub fn decodedPathLength(uri: []const u8) !usize {
    try validate(uri);
    const slash = std.mem.indexOfScalarPos(u8, uri, 7, '/').?;
    var scratch: [maximum]u8 = undefined;
    const path = try toPathLocal(uri[slash..], &scratch);
    return if (path.len > 1 and path[path.len - 1] == '/') path.len - 1 else path.len;
}
fn toPathLocal(uri: []const u8, output: []u8) ![]const u8 {
    var at: usize = 0;
    var len: usize = 0;
    while (at < uri.len) {
        if (uri[at] == '%') {
            output[len] = (try hex(uri[at + 1])) * 16 + try hex(uri[at + 2]);
            at += 3;
        } else {
            output[len] = uri[at];
            at += 1;
        }
        len += 1;
    }
    return output[0..len];
}
test "lexical file URI conversion and full segment ownership" {
    var out: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("file:///D:/a%20b/%E4%B8%AD%23.zig", try fromPath("d:\\a b\\中#.zig", .windows, &out));
    try std.testing.expectEqualStrings("D:\\a b\\中#.zig", try toPath("file:///D:/a%20b/%E4%B8%AD%23.zig", .windows, &out));
    try std.testing.expectEqualStrings("file://host/share/a", try fromPath("\\\\HOST\\share\\a", .windows, &out));
    try std.testing.expect(try contains("file:///project", "file:///project/a", .sensitive));
    try std.testing.expect(!try contains("file:///project", "file:///project-a", .sensitive));
    try std.testing.expect(try contains("file:///a%20b/", "file:///a%20b/c", .sensitive));
    try std.testing.expect(!try contains("file:///A", "file:///a/b", .sensitive));
    try std.testing.expect(try contains("file:///A", "file:///a/b", .ascii_insensitive));
    try std.testing.expectError(error.AmbiguousFileUri, validate("file:///a/%2e%2e/b"));
    try std.testing.expectError(error.AmbiguousFileUri, validate("file:///a%2fb"));
    try std.testing.expectError(error.InvalidFileUri, validate("file:///a?q"));
    var short: [1]u8 = .{99};
    try std.testing.expectError(error.UriCapacityExceeded, fromPath("/ab", .posix, &short));
    try std.testing.expectEqual(@as(u8, 99), short[0]);
}
