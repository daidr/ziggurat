const std = @import("std");
const zio = @import("ziggurat_io");

pub const capacity = 4;
pub const origin_capacity = 8;
pub const name_limit = 32;
pub const origin_limit = 1024;

/// Browser-environment registration, separate from navigation, IPC and Cookie
/// authorization. Only authority-bearing schemes are supported.
pub const Registration = struct {
    name: []const u8,
    treat_as_secure: bool = false,
    /// Exact request Origin filter, also supplied to Runtime AllowedOrigins.
    /// A present Origin must occur once and match this list; writes additionally
    /// require Origin. Origin-less GET/HEAD remain allowed without proving their
    /// initiator. Method/header grants and CORS response headers are independent.
    request_origins: []const []const u8 = &.{},
};

pub fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > name_limit or !std.ascii.isAlphabetic(value[0])) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    const reserved = [_][]const u8{ "http", "https", "file", "ftp", "ftps", "ws", "wss", "about", "data", "javascript", "blob", "filesystem", "chrome", "chrome-extension", "chrome-search", "chrome-untrusted", "devtools", "edge", "view-source", "mailto", "tel", "urn" };
    for (reserved) |name| if (std.ascii.eqlIgnoreCase(value, name)) return false;
    return true;
}

fn validDns(value: []const u8) bool {
    if (value.len == 0 or value.len > 253) return false;
    var labels = std.mem.splitScalar(u8, value, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    return true;
}

fn component(value: std.Uri.Component) []const u8 {
    return switch (value) {
        .raw, .percent_encoded => |text| text,
    };
}

/// The 16 bytes of an IPv6 address in RFC 4291 text form, including `::`
/// and a trailing dotted IPv4 part; null for anything else, zones included.
/// Zig 0.17's own parser rejects some valid forms such as `::ffff:7f00:1`.
pub fn parseIp6(text: []const u8) ?[16]u8 {
    var head: [8]u16 = undefined;
    var tail: [8]u16 = undefined;
    var head_len: usize = 0;
    var tail_len: usize = 0;
    var compressed = false;
    var rest = text;
    if (std.mem.startsWith(u8, rest, "::")) {
        compressed = true;
        rest = rest[2..];
    } else if (rest.len == 0) return null;
    while (rest.len != 0) {
        const words = if (compressed) &tail else &head;
        const len = if (compressed) &tail_len else &head_len;
        const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const piece = rest[0..end];
        if (end == rest.len and std.mem.indexOfScalar(u8, piece, '.') != null) {
            const v4 = std.Io.net.Ip4Address.parse(piece, 0) catch return null;
            if (len.* + 2 > 8) return null;
            words[len.*] = std.mem.readInt(u16, v4.bytes[0..2], .big);
            words[len.* + 1] = std.mem.readInt(u16, v4.bytes[2..4], .big);
            len.* += 2;
            rest = rest[end..];
            break;
        }
        if (piece.len == 0 or piece.len > 4 or len.* == 8) return null;
        words[len.*] = std.fmt.parseInt(u16, piece, 16) catch return null;
        len.* += 1;
        rest = rest[end..];
        if (rest.len == 0) break;
        rest = rest[1..];
        if (std.mem.startsWith(u8, rest, ":")) {
            if (compressed) return null;
            compressed = true;
            rest = rest[1..];
        } else if (rest.len == 0) return null;
    }
    const total = head_len + tail_len;
    if (if (compressed) total > 7 else total != 8) return null;
    var words: [8]u16 = @splat(0);
    @memcpy(words[0..head_len], head[0..head_len]);
    @memcpy(words[8 - tail_len ..], tail[0..tail_len]);
    var bytes: [16]u8 = undefined;
    for (words, 0..) |word, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], word, .big);
    return bytes;
}

test "IPv6 text forms" {
    const zero: [16]u8 = @splat(0);
    var loopback = zero;
    loopback[15] = 1;
    var mapped = zero;
    mapped[10..16].* = .{ 255, 255, 127, 0, 0, 1 };
    var documentation = loopback;
    documentation[0..4].* = .{ 0x20, 0x01, 0x0d, 0xb8 };
    try std.testing.expectEqual(loopback, parseIp6("::1").?);
    try std.testing.expectEqual(mapped, parseIp6("::ffff:7f00:1").?);
    try std.testing.expectEqual(mapped, parseIp6("::ffff:127.0.0.1").?);
    try std.testing.expectEqual(documentation, parseIp6("2001:db8::1").?);
    try std.testing.expectEqual(zero, parseIp6("::").?);
    for ([_][]const u8{ "", ":", ":::", "1::2::3", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "fe80::1%eth0", "12345::", "1:", ":1" }) |bad| try std.testing.expectEqual(null, parseIp6(bad));
}

fn ipv6Host(output: []u8, address: std.Io.net.Ip6Address) ![]const u8 {
    var words: [8]u16 = undefined;
    for (&words, 0..) |*word, i| word.* = std.mem.readInt(u16, address.bytes[i * 2 ..][0..2], .big);
    var best_start: usize = 8;
    var best_length: usize = 1;
    var i: usize = 0;
    while (i < words.len) {
        if (words[i] != 0) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < words.len and words[i] == 0) : (i += 1) {}
        if (i - start > best_length) {
            best_start = start;
            best_length = i - start;
        }
    }
    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    i = 0;
    while (i < words.len) {
        if (i == best_start) {
            try writer.writeAll("::");
            i += best_length;
            continue;
        }
        if (i != 0 and (best_start == 8 or i != best_start + best_length)) try writer.writeByte(':');
        try writer.print("{x}", .{words[i]});
        i += 1;
    }
    try writer.writeByte(']');
    return writer.buffered();
}

/// Parses a deliberately narrow authority URI with std.Uri; rejects ambiguous
/// percent-escaped hosts, credentials, wildcard patterns and non-origin suffixes.
/// Custom origins have no port because the Runtime does not isolate that port.
pub fn canonicalOrigin(output: []u8, value: []const u8, registrations: []const Registration) ![]const u8 {
    if (value.len == 0 or value.len > origin_limit) return error.InvalidSchemeOrigin;
    for (value) |byte| if (byte <= 32 or byte >= 127 or byte == '\\' or byte == '%' or byte == '*' or byte == '?') return error.InvalidSchemeOrigin;
    const uri = std.Uri.parse(value) catch return error.InvalidSchemeOrigin;
    const http = std.ascii.eqlIgnoreCase(uri.scheme, "http");
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!http and !https) {
        var found = false;
        for (registrations) |item| if (std.ascii.eqlIgnoreCase(uri.scheme, item.name)) {
            found = true;
            break;
        };
        if (!found or uri.port != null) return error.InvalidSchemeOrigin;
    }
    const host = if (uri.host) |item| component(item) else return error.InvalidSchemeOrigin;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or (!uri.path.isEmpty() and !std.mem.eql(u8, component(uri.path), "/"))) return error.InvalidSchemeOrigin;
    if (uri.port != null and uri.port.? == 0) return error.InvalidSchemeOrigin;
    // IPv6 is accepted only for HTTP(S); custom hosts use the same DNS-label
    // grammar as LocalSite. A-label international domains are explicit ASCII.
    var host_storage: [256]u8 = undefined;
    const canonical_host: []const u8 = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') blk: {
        if (!http and !https) return error.InvalidSchemeOrigin;
        const ip: std.Io.net.Ip6Address = .{ .bytes = parseIp6(host[1 .. host.len - 1]) orelse return error.InvalidSchemeOrigin, .port = 0 };
        // URL origins serialize every piece in hex, including IPv4 mappings.
        // Ip6Address's socket formatter deliberately uses dotted mapped IPv4.
        break :blk try ipv6Host(&host_storage, ip);
    } else blk: {
        if (!validDns(host)) return error.InvalidSchemeOrigin;
        if (std.Io.net.Ip4Address.parse(host, 0)) |ip| {
            var ip_storage: [32]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&ip_storage, "{f}", .{ip});
            const end = std.mem.indexOfScalar(u8, formatted, ':') orelse return error.InvalidSchemeOrigin;
            if (!std.mem.eql(u8, host, formatted[0..end])) return error.InvalidSchemeOrigin;
        } else |_| {
            // A numeric final label triggers browser IPv4 parsing, including
            // mixed decimal/hexadecimal aliases. Only dotted quads pass above.
            const start = if (std.mem.lastIndexOfScalar(u8, host, '.')) |dot| dot + 1 else 0;
            const tail = host[start..];
            var numeric = tail.len != 0;
            for (tail) |byte| if (!std.ascii.isDigit(byte)) {
                numeric = false;
                break;
            };
            if (numeric or std.ascii.startsWithIgnoreCase(tail, "0x")) return error.InvalidSchemeOrigin;
        }
        for (host, 0..) |byte, i| host_storage[i] = std.ascii.toLower(byte);
        break :blk host_storage[0..host.len];
    };
    const port = if (uri.port) |number| if ((https and number == 443) or (http and number == 80)) null else number else null;
    var result = if (port) |number| try std.fmt.bufPrint(output, "{s}://{s}:{d}", .{ uri.scheme, canonical_host, number }) else try std.fmt.bufPrint(output, "{s}://{s}", .{ uri.scheme, canonical_host });
    for (result[0..uri.scheme.len]) |*byte| byte.* = std.ascii.toLower(byte.*);
    return result;
}

/// One allocation owning canonical, sorted registration metadata. Do not copy
/// after init; move by clearing the source. Empty registrations do not allocate.
pub const Owned = struct {
    allocator: std.mem.Allocator,
    storage: ?[]align(@alignOf(Registration)) u8 = null,
    registrations: []const Registration = &.{},

    pub fn init(allocator: std.mem.Allocator, input: []const Registration) !Owned {
        if (input.len > capacity) return error.TooManySchemes;
        var total_origins: usize = 0;
        var bytes: usize = input.len * @sizeOf(Registration);
        var origin_bytes: [capacity][origin_capacity][origin_limit + 1]u8 = undefined;
        var origins: [capacity][origin_capacity][]const u8 = undefined;
        for (input, 0..) |item, i| {
            if (!validName(item.name)) return error.InvalidSchemeName;
            if (item.request_origins.len > origin_capacity) return error.TooManySchemeOrigins;
            for (input[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(item.name, earlier.name)) return error.DuplicateScheme;
            bytes += item.name.len;
            total_origins += item.request_origins.len;
            for (item.request_origins, 0..) |origin, j| {
                origins[i][j] = try canonicalOrigin(&origin_bytes[i][j], origin, input);
                for (origins[i][0..j]) |earlier| if (std.mem.eql(u8, origins[i][j], earlier)) return error.DuplicateSchemeOrigin;
                bytes += origins[i][j].len;
            }
        }
        if (input.len == 0) return .{ .allocator = allocator };
        bytes += total_origins * @sizeOf([]const u8);
        const storage = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(Registration)), bytes);
        const items = @as([*]Registration, @ptrCast(storage.ptr))[0..input.len];
        const lists = @as([*][]const u8, @ptrCast(@alignCast(storage.ptr + input.len * @sizeOf(Registration))))[0..total_origins];
        var offset = input.len * @sizeOf(Registration) + total_origins * @sizeOf([]const u8);
        var origin_index: usize = 0;
        for (items, input, 0..) |*item, source, i| {
            const name = storage[offset..][0..source.name.len];
            for (source.name, 0..) |byte, j| name[j] = std.ascii.toLower(byte);
            offset += name.len;
            const allowed = lists[origin_index..][0..source.request_origins.len];
            origin_index += allowed.len;
            for (allowed, origins[i][0..allowed.len]) |*target, text| {
                const owned = storage[offset..][0..text.len];
                @memcpy(owned, text);
                target.* = owned;
                offset += text.len;
            }
            std.mem.sort([]const u8, allowed, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            item.* = .{ .name = name, .treat_as_secure = source.treat_as_secure, .request_origins = allowed };
        }
        std.mem.sort(Registration, items, {}, struct {
            fn less(_: void, a: Registration, b: Registration) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        std.debug.assert(offset == bytes);
        return .{ .allocator = allocator, .storage = storage, .registrations = items };
    }

    pub fn deinit(self: *Owned) void {
        if (self.storage) |storage| self.allocator.free(storage);
        self.storage = null;
        self.registrations = &.{};
    }
};

/// Compares canonical, sorted metadata produced by Owned.init, without hashing.
pub fn equal(a: []const Registration, b: []const Registration) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or left.treat_as_secure != right.treat_as_secure or left.request_origins.len != right.request_origins.len) return false;
        for (left.request_origins, right.request_origins) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

test "registration metadata is owned canonical and order independent" {
    var temporary = [_]u8{ 'S', 'i', 't', 'e' };
    var first = try Owned.init(std.testing.allocator, &.{ .{ .name = &temporary, .treat_as_secure = true, .request_origins = &.{ "HTTPS://EXAMPLE.TEST:443/", "site://app", "http://127.0.0.1:54321/" } }, .{ .name = "other" } });
    defer first.deinit();
    temporary[0] = 'x';
    var second = try Owned.init(std.testing.allocator, &.{ .{ .name = "OTHER" }, .{ .name = "site", .treat_as_secure = true, .request_origins = &.{ "http://127.0.0.1:54321", "site://app/", "https://example.test" } } });
    defer second.deinit();
    try std.testing.expect(equal(first.registrations, second.registrations));
    try std.testing.expectEqualStrings("other", first.registrations[0].name);
    try std.testing.expectEqualStrings("site", first.registrations[1].name);
}

test "scheme and origin policy rejects ambient or ambiguous authority" {
    for ([_][]const u8{ "", "https", "FILE", "javascript", "1app", "app_name", "app:name", "app/name" }) |name| try std.testing.expectError(error.InvalidSchemeName, Owned.init(std.testing.allocator, &.{.{ .name = name }}));
    try std.testing.expectError(error.DuplicateScheme, Owned.init(std.testing.allocator, &.{ .{ .name = "app" }, .{ .name = "APP" } }));
    const registrations = &[_]Registration{.{ .name = "app" }};
    var output: [origin_limit + 1]u8 = undefined;
    for ([_][]const u8{ "*", "null", "https://*.example.test", "https://example.test?", "https://example.test#", "https://example.test/path", "https://example.test\\path", "https://%65xample.test", "https://@example.test", "https://user:pw@example.test", "https://example.test:0", "app:path", "app:///path", "app://host:80", "app://host.", "app://127.1", "http://2130706433", "http://0x7f000001", "http://0177.0.0.1", "unregistered://host" }) |origin| try std.testing.expectError(error.InvalidSchemeOrigin, canonicalOrigin(&output, origin, registrations));
    try std.testing.expectEqualStrings("https://[::1]", try canonicalOrigin(&output, "HTTPS://[0:0:0:0:0:0:0:1]:443/", registrations));
    try std.testing.expectEqualStrings("https://[::ffff:7f00:1]", try canonicalOrigin(&output, "https://[::ffff:127.0.0.1]/", registrations));
    try std.testing.expectEqualStrings("https://[1::2:0:0:3:4]", try canonicalOrigin(&output, "https://[1:0:0:2:0:0:3:4]/", registrations));
    try std.testing.expectEqualStrings("https://[1:0:2:3:4:5:6:7]", try canonicalOrigin(&output, "https://[1:0:2:3:4:5:6:7]/", registrations));
    for ([_][]const u8{ "https://1.0x10.0.1", "https://host.123", "app://1.2.0x3", "https://1.2.3.999" }) |origin| try std.testing.expectError(error.InvalidSchemeOrigin, canonicalOrigin(&output, origin, registrations));
    try std.testing.expectError(error.DuplicateSchemeOrigin, Owned.init(std.testing.allocator, &.{.{ .name = "app", .request_origins = &.{ "https://example.test", "HTTPS://EXAMPLE.TEST:443/" } }}));
}

test "metadata failure leaves no allocation and empty setup is free" {
    var empty = try Owned.init(std.testing.failing_allocator, &.{});
    defer empty.deinit();
    try std.testing.expect(empty.storage == null);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var owned = try Owned.init(allocator, &.{.{ .name = "app", .request_origins = &.{ "app://host", "https://example.test" } }});
            defer owned.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
    var too_many: [capacity + 1]Registration = @splat(.{ .name = "app" });
    try std.testing.expectError(error.TooManySchemes, Owned.init(std.testing.failing_allocator, &too_many));
    var many_origins: [origin_capacity + 1][]const u8 = @splat("app://host");
    try std.testing.expectError(error.TooManySchemeOrigins, Owned.init(std.testing.failing_allocator, &.{.{ .name = "app", .request_origins = &many_origins }}));
}
