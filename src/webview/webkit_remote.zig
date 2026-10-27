const std = @import("std");
const zio = @import("ziggurat_io");
const resources = @import("resources.zig");
const schemes = @import("schemes.zig");
const credentials = @import("request_credentials.zig");

/// Explicit application-owned directory containing the WebProcess adapter.
/// This is a native code deployment path, never a page-provided resource route.
pub const Extension = struct { directory: []const u8, handshake_timeout_ms: u32 = 5000 };
pub const Header = extern struct { name: [*:0]const u8, value: ?[*:0]const u8 };
pub const Origin = extern struct { origin: [*:0]const u8, flags: u32, methods: u32, headers: [*]const Header, header_count: u32, bearer: ?*const [32]u8 };
pub const Input = extern struct {
    url: [*:0]const u8,
    directory: [*:0]const u8,
    origins: [*]const Origin,
    count: u32,
    timeout_ms: u32,
    loopback: c_int,
    script_navigation: c_int,
    redirects: c_int,
};
comptime {
    if (@sizeOf(usize) == 8 and (@sizeOf(Header) != 16 or @sizeOf(Origin) != 40 or @sizeOf(Input) != 48)) @compileError("WebKit remote descriptor ABI mismatch");
}

pub fn validateExtension(extension: Extension) !void {
    if (extension.directory.len == 0 or extension.directory.len > 4096 or extension.directory[0] != '/' or !std.unicode.utf8ValidateSlice(extension.directory) or std.mem.indexOfScalar(u8, extension.directory, 0) != null) return error.InvalidRequestExtensionDirectory;
    if (extension.handshake_timeout_ms == 0 or extension.handshake_timeout_ms > 60000) return error.InvalidRequestExtensionDeadline;
}

/// No resolver, filesystem or native call. Canonical origins use the same
/// authority grammar as the portable scheme configuration; paths stay opaque.
pub fn canonicalUriOrigin(output: []u8, uri: []const u8, origin_only: bool, allow_loopback: bool) ![]const u8 {
    if (uri.len == 0 or uri.len > (if (origin_only) @as(usize, 1024) else 16384)) return error.InvalidRemoteUri;
    for (uri) |byte| if (byte <= 32 or byte >= 127 or byte == '\\') return error.InvalidRemoteUri;
    const authority = std.mem.indexOf(u8, uri, "://") orelse return error.InvalidRemoteUri;
    const end = authority + 3 + (std.mem.indexOfAny(u8, uri[authority + 3 ..], "/?#") orelse (uri.len - authority - 3));
    if (origin_only and !(end == uri.len or std.mem.eql(u8, uri[end..], "/"))) return error.InvalidRemoteUri;
    const canonical = schemes.canonicalOrigin(output, uri[0..end], &.{}) catch return error.InvalidRemoteUri;
    const parsed = std.Uri.parse(canonical) catch return error.InvalidRemoteUri;
    const https = std.mem.eql(u8, parsed.scheme, "https");
    if (!https and !std.mem.eql(u8, parsed.scheme, "http")) return error.InvalidRemoteUri;
    const host = switch (parsed.host.?) {
        .raw, .percent_encoded => |value| value,
    };
    if (std.mem.eql(u8, host, "ziggurat.invalid") or std.mem.endsWith(u8, host, ".ziggurat.invalid")) return error.InvalidRemoteUri;
    const loopback = isLoopback(host);
    if ((loopback and !allow_loopback) or (!https and !loopback)) return error.InvalidRemoteUri;
    return canonical;
}
fn isLoopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost") or std.mem.endsWith(u8, host, ".localhost")) return true;
    if (std.Io.net.Ip4Address.parse(host, 0)) |address| {
        if (address.bytes[0] == 127) return true;
    } else |_| {}
    if (host.len >= 2 and host[0] == '[') {
        const bytes = schemes.parseIp6(host[1 .. host.len - 1]) orelse return false;
        if (std.mem.allEqual(u8, bytes[0..15], 0) and bytes[15] == 1) return true;
        const mapped = std.mem.allEqual(u8, bytes[0..10], 0) and bytes[10] == 255 and bytes[11] == 255;
        const compatible = std.mem.allEqual(u8, bytes[0..12], 0);
        return (mapped or compatible) and bytes[12] == 127;
    }
    return false;
}
pub fn validate(remote: anytype) !void {
    if (remote.origins.len == 0 or remote.origins.len > 32) return error.InvalidOriginCount;
    var canonical: [32][1024]u8 = undefined;
    var origins: [32][]const u8 = undefined;
    var initial_storage: [1024]u8 = undefined;
    const initial = try canonicalUriOrigin(&initial_storage, remote.url, false, remote.allow_insecure_loopback);
    var initial_allowed = false;
    for (remote.origins, 0..) |grant, index| {
        origins[index] = try canonicalUriOrigin(&canonical[index], grant.origin, true, remote.allow_insecure_loopback);
        for (origins[0..index]) |previous| if (std.mem.eql(u8, previous, origins[index])) return error.DuplicateRemoteOrigin;
        if (grant.methods.reserved != 0 or (grant.requests and @as(u8, @bitCast(grant.methods)) == 0)) return error.InvalidMethods;
        try resources.validateGrants(grant.request_headers);
        if (std.mem.eql(u8, initial, origins[index]) and grant.navigate and grant.requests and grant.methods.get) initial_allowed = true;
    }
    if (!initial_allowed) return error.InitialOriginDenied;
    if (remote.request_credentials.len != 0) try validateCredentials(remote, origins[0..remote.origins.len]);
}
noinline fn validateCredentials(remote: anytype, origins: []const []const u8) !void {
    if (remote.request_credentials.len > credentials.max_entries) return error.TooManyRequestCredentials;
    var credential_origins: [credentials.max_entries][1024]u8 = undefined;
    var lengths: [credentials.max_entries]usize = undefined;
    for (remote.request_credentials, 0..) |credential, index| {
        const value = canonicalUriOrigin(&credential_origins[index], credential.origin, true, remote.allow_insecure_loopback) catch return error.InvalidCredentialOrigin;
        if (!std.mem.startsWith(u8, value, "https://")) return error.CredentialRequiresHttps;
        lengths[index] = value.len;
        for (0..index) |prior| if (std.mem.eql(u8, value, credential_origins[prior][0..lengths[prior]])) return error.DuplicateRequestCredential;
        var allowed = false;
        for (remote.origins, 0..) |grant, grant_index| {
            if (grant.requests and std.mem.eql(u8, value, origins[grant_index])) allowed = true;
        }
        if (!allowed) return error.CredentialOriginDenied;
    }
    if (remote.request_credentials.len != 0) for (remote.origins) |grant| {
        for (grant.request_headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) return error.ConflictingRequestCredential;
    };
}

/// One explicit temporary allocation, copied by native create/validate. No
/// native view may retain its descriptors or any original configuration slice.
pub const Scratch = struct {
    allocator: std.mem.Allocator,
    storage: ?[]align(@alignOf(Origin)) u8,
    input: Input,
    has_credentials: bool = false,
    pub fn init(allocator: std.mem.Allocator, remote: anytype, extension: Extension) !Scratch {
        if (remote.request_credentials.len != 0) return initCredential(allocator, remote, extension);
        return initCommon(allocator, remote, extension);
    }
    noinline fn initCredential(allocator: std.mem.Allocator, source_remote: anytype, extension: Extension) !Scratch {
        var capture: credentials.Capture = .{};
        defer capture.deinit();
        try capture.init(source_remote.request_credentials);
        var remote = source_remote;
        remote.request_credentials = capture.entries[0..capture.count];
        return initCommon(allocator, remote, extension);
    }
    fn initCommon(allocator: std.mem.Allocator, remote: anytype, extension: Extension) !Scratch {
        try validateExtension(extension);
        try validate(remote);
        var headers: usize = 0;
        var bytes: usize = remote.origins.len * @sizeOf(Origin) + remote.url.len + extension.directory.len + 2;
        bytes += remote.request_credentials.len * 32;
        for (remote.origins) |grant| {
            bytes += grant.origin.len + 1;
            headers += grant.request_headers.len;
            for (grant.request_headers) |header| bytes += header.name.len + 1 + (if (header.exact_value) |value| value.len + 1 else @as(usize, 0));
        }
        bytes += headers * @sizeOf(Header);
        if (bytes > 1024 * 1024) return error.RemotePolicyTooLarge;
        const storage = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(Origin)), bytes);
        errdefer {
            std.crypto.secureZero(u8, storage);
            allocator.free(storage);
        }
        const rows = @as([*]Origin, @ptrCast(storage.ptr))[0..remote.origins.len];
        const header_rows = @as([*]Header, @ptrCast(@alignCast(storage.ptr + rows.len * @sizeOf(Origin))))[0..headers];
        var offset = rows.len * @sizeOf(Origin) + headers * @sizeOf(Header);
        const url = copy(storage, &offset, remote.url);
        const directory = copy(storage, &offset, extension.directory);
        var next_header: usize = 0;
        for (rows, remote.origins) |*row, grant| {
            const values = header_rows[next_header..][0..grant.request_headers.len];
            for (values, grant.request_headers) |*value, source| value.* = .{ .name = copy(storage, &offset, source.name), .value = if (source.exact_value) |exact| copy(storage, &offset, exact) else null };
            row.* = .{ .origin = copy(storage, &offset, grant.origin), .flags = @as(u32, @intFromBool(grant.navigate)) | @as(u32, @intFromBool(grant.requests)) << 1 | @as(u32, @intFromBool(grant.ipc)) << 2, .methods = @as(u8, @bitCast(grant.methods)), .headers = values.ptr, .header_count = @intCast(values.len), .bearer = null };
            next_header += values.len;
        }
        for (remote.request_credentials) |credential| {
            var credential_storage: [1024]u8 = undefined;
            const target = try canonicalUriOrigin(&credential_storage, credential.origin, true, remote.allow_insecure_loopback);
            for (rows, remote.origins) |*row, grant| {
                var grant_storage: [1024]u8 = undefined;
                const canonical = try canonicalUriOrigin(&grant_storage, grant.origin, true, remote.allow_insecure_loopback);
                if (std.mem.eql(u8, target, canonical)) {
                    const secret: *[32]u8 = @ptrCast(storage.ptr + offset);
                    secret.* = credential.bearer;
                    row.bearer = secret;
                    offset += 32;
                    break;
                }
            }
        }
        std.debug.assert(offset == storage.len);
        return .{ .allocator = allocator, .storage = storage, .has_credentials = remote.request_credentials.len != 0, .input = .{ .url = url, .directory = directory, .origins = rows.ptr, .count = @intCast(rows.len), .timeout_ms = extension.handshake_timeout_ms, .loopback = @intFromBool(remote.allow_insecure_loopback), .script_navigation = @intFromBool(remote.allow_script_navigation), .redirects = @intFromBool(remote.allow_redirects) } };
    }
    pub fn deinit(self: *Scratch) void {
        const storage = self.storage orelse return;
        const allocator = self.allocator;
        self.storage = null;
        if (self.has_credentials) {
            std.crypto.secureZero(u8, storage);
            allocator.rawFree(storage, std.mem.Alignment.fromByteUnits(@alignOf(Origin)), @returnAddress());
            return;
        }
        allocator.free(storage);
    }
};
fn copy(storage: []u8, offset: *usize, input: []const u8) [*:0]const u8 {
    const start = offset.*;
    @memcpy(storage[start..][0..input.len], input);
    storage[start + input.len] = 0;
    offset.* += input.len + 1;
    return @ptrCast(storage.ptr + start);
}

test {
    _ = @import("webkit_remote_test.zig");
}
